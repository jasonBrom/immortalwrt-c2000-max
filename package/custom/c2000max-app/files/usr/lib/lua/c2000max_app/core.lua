local fs = require "nixio.fs"
local nixio = require "nixio"
local json = require "luci.jsonc"
local sys = require "luci.sys"
local uci = require("luci.model.uci").cursor()
local util = require "luci.util"
local identity = require "c2000max_app.identity"

local M = {}

-- This value is deliberately detached from the underlying OpenWrt build.
-- It is the only software version exposed to the NRadio APP, so the APP must
-- never offer or request a firmware update for this privacy-oriented image.
local APP_SOFTWARE_VERSION = "9.9.13.n0.c1"
local DEFAULT_MODEM_CACHE_INTERVAL = 10
local DEFAULT_SELECTOR_CACHE_INTERVAL = 15
local DEFAULT_CACHE_WARM_INTERVAL = 2
local DEFAULT_SIGNAL_NORMAL_INTERVAL = 3
local DEFAULT_SIGNAL_TEST_INTERVAL = 1
local DEFAULT_SIGNAL_CARRIER_INTERVAL = 10
local FAST_SIGNAL_FAILURE_BACKOFF = 5
local MAX_APP_CARRIERS = 8
local STATE_DIR = "/var/run/c2000max-app"
local CACHE_DIR = STATE_DIR .. "/cache"
local MAX_SHARED_CACHE = 1024 * 1024

local function bool_option(name)
	return uci:get("c2000max_app", "main", name) == "1"
end

local function number_option(name, default, minimum, maximum)
	local value = tonumber(uci:get("c2000max_app", "main", name))
	if not value or value <= 0 then
		value = default
	end
	if value < minimum then
		value = minimum
	elseif value > maximum then
		value = maximum
	end
	return value
end

local function precise_time()
	if type(nixio.gettimeofday) == "function" then
		local ok, seconds, microseconds = pcall(nixio.gettimeofday)
		seconds = ok and tonumber(seconds) or nil
		microseconds = ok and tonumber(microseconds) or nil
		if seconds then
			return seconds + (microseconds or 0) / 1000000
		end
	end
	return tonumber(os.time()) or 0
end

local function cache_path(name)
	name = tostring(name or ""):gsub("[^A-Za-z0-9_.%-]", "_")
	if name == "" then
		return nil
	end
	return CACHE_DIR .. "/" .. name .. ".json"
end

local function shared_cache_read(name, maximum_age, allow_stale)
	local path = cache_path(name)
	if not path or type(fs.readfile) ~= "function" then
		return nil, 0
	end
	local raw = fs.readfile(path)
	if not raw or #raw == 0 or #raw > MAX_SHARED_CACHE then
		return nil, 0
	end
	local ok, container = pcall(json.parse, raw)
	if not ok or type(container) ~= "table" or
	   type(container.value) ~= "table" then
		return nil, 0
	end
	local updated = tonumber(container.updated) or 0
	local age = precise_time() - updated
	if age < 0 or (not allow_stale and age >= maximum_age) then
		return nil, updated
	end
	return container.value, updated
end

local function shared_cache_write(name, value)
	local path = cache_path(name)
	if not path or type(value) ~= "table" or
	   type(fs.mkdirr) ~= "function" or
	   type(fs.writefile) ~= "function" then
		return false
	end
	fs.mkdirr(CACHE_DIR)
	if type(fs.chmod) == "function" then
		fs.chmod(STATE_DIR, "0755")
		fs.chmod(CACHE_DIR, "0700")
	end
	local encoded = json.stringify({
		updated = precise_time(),
		value = value
	})
	if type(encoded) ~= "string" or #encoded > MAX_SHARED_CACHE then
		return false
	end
	local pid = type(nixio.getpid) == "function" and nixio.getpid() or 0
	local temporary = path .. ".tmp." .. tostring(pid)
	if not fs.writefile(temporary, encoded) then
		return false
	end
	if type(fs.chmod) == "function" then
		fs.chmod(temporary, "0600")
	end
	local renamed = os.rename(temporary, path)
	if not renamed then
		if type(fs.unlink) == "function" then
			fs.unlink(temporary)
		end
		return false
	end
	return true
end

local function shared_cache_remove(name)
	local path = cache_path(name)
	if path and type(fs.unlink) == "function" then
		fs.unlink(path)
	end
end

local function shared_cache_remove_prefix(prefix)
	if type(fs.dir) ~= "function" then
		return
	end
	local iterator = fs.dir(CACHE_DIR)
	if not iterator then
		return
	end
	for name in iterator do
		if name:sub(1, #prefix) == prefix then
			fs.unlink(CACHE_DIR .. "/" .. name)
		end
	end
end

function M.cache_refresh_policy()
	return {
		modem = number_option("modem_cache_interval",
			DEFAULT_MODEM_CACHE_INTERVAL, 1, 60),
		selector = number_option("selector_cache_interval",
			DEFAULT_SELECTOR_CACHE_INTERVAL, 1, 60),
		warm = number_option("cache_warm_interval",
			DEFAULT_CACHE_WARM_INTERVAL, 1, 60)
	}
end

function M.signal_refresh_policy()
	return {
		normal = number_option("signal_normal_interval",
			DEFAULT_SIGNAL_NORMAL_INTERVAL, 1, 30),
		test = number_option("signal_test_interval",
			DEFAULT_SIGNAL_TEST_INTERVAL, 1, 10),
		carrier = number_option("signal_carrier_interval",
			DEFAULT_SIGNAL_CARRIER_INTERVAL, 2, 120),
		backend = "qmodem-serialized-single-at",
		carrier_backend = "qmodem-serialized-hfreqinfo"
	}
end

local function response(data, code)
	return {
		code = tostring(code or 0),
		trans_id = type(data) == "table" and tostring(data.trans_id or "") or ""
	}
end

local function unsupported(data)
	local rv = response(data, -5)
	rv.message = "unsupported"
	return rv
end

local function safe_ubus(object, method, args)
	local ok, rv = pcall(util.ubus, object, method, args or {})
	if ok and type(rv) == "table" then
		return rv
	end
	return {}
end

local function read_trim(path)
	local value = fs.readfile(path)
	if not value then
		return nil
	end
	return value:match("^%s*(.-)%s*$")
end

local function slot_number(value)
	value = tostring(value or "")
	if value == "external1" or value == "sim1" or value == "1" then
		return 1
	elseif value == "external2" or value == "sim2" or value == "2" then
		return 2
	elseif value == "internal" or value == "embedded1" or value == "3" then
		return 3
	end
	return nil
end

local function normalize_sim_mode(value)
	if type(value) == "table" then
		value = value[1]
	end
	local mode = tonumber(value)
	if mode == 0 or mode == 1 then
		return mode
	end
	return nil
end

local function configured_sim_mode()
	return normalize_sim_mode(
		uci:get("c2000max_app", "main", "sim_mode")) or 1
end

local function persist_sim_mode(mode)
	mode = normalize_sim_mode(mode)
	if mode == nil then return false end
	local set_ok, set_result = pcall(
		uci.set, uci, "c2000max_app", "main", "sim_mode", tostring(mode))
	if not set_ok or set_result == false then return false end
	local commit_ok, commit_result = pcall(uci.commit, uci, "c2000max_app")
	return commit_ok and commit_result ~= false
end

-- The APP uses two different SIM numbering schemes.  `cpesel.cur` is the
-- global hardware slot (external 1, external 2, internal), while the remote
-- CPE detail payload expects `simtype` plus an index within that type.  For
-- C2000-MAX the factory slot schema is 0,0,4.
local function app_remote_sim_slot(value)
	local slot = slot_number(value)
	if slot == 1 then
		return "0", "1"
	elseif slot == 2 then
		return "0", "2"
	elseif slot == 3 then
		return "4", "1"
	end
	return "", ""
end

local function ready_cpin(value)
	value = tostring(value or ""):lower()
	if value == "ready" or value == "0" then
		return "0"
	end
	return value
end

function M.device_id()
	return identity.get().device_id
end

function M.software_version()
	return APP_SOFTWARE_VERSION
end

function M.broker()
	-- Never derive the official cloud hostname from the SD factory fallback.
	-- The fallback is useful for local diagnostics only.
	local id = identity.get().bdinfo_id
	if not id then
		return ""
	end
	return id .. ".dev.nradio.com.cn"
end

function M.identity_status(force)
	return identity.public_status(force)
end

local function first_modem()
	local found
	uci:foreach("qmodem", "modem-device", function(section)
		if not found and section.state ~= "disabled" then
			found = section[".name"]
		end
	end)
	return found
end

local function modem_call(method, args)
	local section = first_modem()
	if not section then
		return {}, nil
	end
	args = args or {}
	args.config_section = section
	return safe_ubus("qmodem", method, args), section
end

local function normalized_field_name(value)
	value = tostring(value or ""):lower()
	value = value:gsub("[^a-z0-9]+", "_")
	return value:gsub("^_+", ""):gsub("_+$", "")
end

local function collect_modem_fields(fields, source)
	if type(source) ~= "table" then
		return
	end

	for key, value in pairs(source) do
		if key ~= "modem_info" and type(value) ~= "table" then
			local normalized = normalized_field_name(key)
			if normalized ~= "" and fields[normalized] == nil and
			   value ~= nil and tostring(value) ~= "" then
				fields[normalized] = value
			end
		end
	end

	local entries = source.modem_info
	if type(entries) ~= "table" then
		return
	end
	for _, item in ipairs(entries) do
		if type(item) == "table" and item.value ~= nil then
			for _, name in ipairs({ item.key, item.full_name }) do
				local normalized = normalized_field_name(name)
				if normalized ~= "" and fields[normalized] == nil and
				   tostring(item.value) ~= "" then
					fields[normalized] = item.value
				end
			end
		end
	end
end

local function first_field(fields, ...)
	for index = 1, select("#", ...) do
		local value = fields[select(index, ...)]
		if value ~= nil and tostring(value) ~= "" then
			return value
		end
	end
	return ""
end

local function digits_only(value)
	return tostring(value or ""):gsub("[^0-9]", "")
end

local function app_operator_plmn(fields, imsi, operator)
	-- APP 2.3.1 resolves the operator from a numeric PLMN.  Passing a display
	-- name such as "中国移动" makes its getSimIspName() helper return an empty
	-- string and the device page consequently shows "运营商未识别".
	for _, name in ipairs({ "plmn", "operator_numeric", "network_operator",
		"mcc_mnc", "mccmnc" }) do
		local numeric = digits_only(fields[name])
		if #numeric == 5 or #numeric == 6 then
			return numeric
		end
	end

	local numeric_operator = digits_only(operator)
	if #numeric_operator == 5 or #numeric_operator == 6 then
		return numeric_operator
	end

	local subscriber = digits_only(imsi)
	if #subscriber >= 5 then
		-- Chinese PLMNs use the three-digit MCC plus a two-digit MNC in the
		-- APP's bundled registry (for example 46002 for China Mobile).
		if subscriber:sub(1, 3) == "460" then
			return subscriber:sub(1, 5)
		end
		-- Outside China, prefer a three-digit MNC when no explicit numeric
		-- operator field is available.  The explicit modem value above always
		-- wins and therefore preserves five-digit PLMNs where applicable.
		if #subscriber >= 6 then
			return subscriber:sub(1, 6)
		end
		return subscriber:sub(1, 5)
	end
	return ""
end

local function modem_online(value)
	value = tostring(value or ""):lower()
	return value == "1" or value == "yes" or value == "true" or
		value == "online" or value == "connected" or value == "up"
end

local function app_network_mode(value)
	local mode = tostring(value or "")
	local upper = mode:upper()
	if upper:find("NR5G%-SA") or upper:find("NR%-SA") or
	   upper == "NR SA" then
		return "NR SA"
	elseif upper:find("EN%-DC") or upper:find("NR5G%-NSA") or
	       upper:find("NR%-NSA") or upper == "NR NSA" then
		return "NR NSA"
	elseif upper:find("LTE", 1, true) then
		return "LTE"
	end
	return mode
end

local function inferred_band(mode, channel)
	local upper = tostring(mode or ""):upper()
	local arfcn = tonumber(channel)
	if not arfcn or
	   (not upper:find("NR", 1, true) and
	    not upper:find("5G", 1, true)) then
		return ""
	end

	-- n41 overlaps n38 between 514000 and 524000.  Infer only the two
	-- unambiguous parts of n41; never guess within an overlapping range.
	if (arfcn >= 499200 and arfcn < 514000) or
	   (arfcn > 524000 and arfcn <= 537999) then
		return "41"
	end
	return ""
end

local function build_modem_status(modem, selector, index)
	local fields = {}
	collect_modem_fields(fields, modem.info)
	collect_modem_fields(fields, modem.network)
	collect_modem_fields(fields, modem.sim)

	local raw_mode = tostring(first_field(fields, "network_mode", "mode"))
	local mode = app_network_mode(raw_mode)
	local rsrp = first_field(fields, "rsrp")
	local rssi = first_field(fields, "rssi")
	local cell = first_field(fields, "cell_id", "cellid", "cell")
	local pci = first_field(fields, "physical_cell_id", "pci", "dl_pci")
	local earfcn = first_field(fields, "arfcn", "earfcn", "dl_fcn")
	local band = first_field(fields, "band", "nr_sa_band", "nr_nsa_band",
		"nr_band", "lte_band")
	if band == "" then
		band = inferred_band(raw_mode, earfcn)
	end
	band = tostring(band):gsub("^[BbNn]", "")
	local dl_fcn = first_field(fields, "dl_fcn", "arfcn", "earfcn")
	local ul_fcn = first_field(fields, "ul_fcn")
	local dlbw = first_field(fields, "dlbw", "dl_bandwidth",
		"downlink_bandwidth")
	local ulbw = first_field(fields, "ulbw", "ul_bandwidth",
		"uplink_bandwidth")
	local cqi = first_field(fields, "cqi", "qci")
	local ambr_dl = first_field(fields, "nr5g_ambr_dl", "ambr_dl")
	local ambr_ul = first_field(fields, "nr5g_ambr_ul", "ambr_ul")
	local iccid = first_field(fields, "iccid")
	local imei = first_field(fields, "imei",
		"international_mobile_equipment_identity")
	local imsi = first_field(fields, "imsi",
		"international_mobile_subscriber_identity")
	local current_slot = type(selector) == "table" and
		(selector.current_slot or selector.configured_slot) or ""
	local connect_status = first_field(fields, "connect_status", "online",
		"status")
	local online = modem_online(connect_status)
	if connect_status == "" and modem.interface and modem.interface ~= "" then
		online = true
	end
	if iccid == "" and type(selector) == "table" then
		iccid = selector.iccid or ""
	end

	local signal = tonumber(rsrp)
	if not signal then
		signal = tonumber(rssi)
	end
	local model = first_field(fields, "name", "model")
	if model == "" then
		model = modem.model or ""
	end
	local manufacturer = first_field(fields, "manufacturer")
	if manufacturer == "" then
		manufacturer = modem.manufacturer or ""
	end
	local operator_name = first_field(fields, "isp", "operator", "carrier")
	if operator_name == "" and type(selector) == "table" then
		operator_name = selector.carrier or ""
	end
	local isp = app_operator_plmn(fields, imsi, operator_name)
	local simtype, simno = app_remote_sim_slot(current_slot)
	local cpin = first_field(fields, "sim_status", "cpin")
	local at_port = type(selector) == "table" and selector.at_port or ""

	local status = {
		name = modem.name or ("cpe" .. tostring(index)),
		control = modem.name or "",
		hwid = modem.model or model,
		real_name = model,
		driver = manufacturer,
		mode = mode,
		isp = isp,
		sim_isp = operator_name,
		operator_name = operator_name,
		imei = imei,
		imsi = imsi,
		iccid = iccid,
		cell = cell,
		cellid = cell,
		lac = first_field(fields, "lac"),
		pci = pci,
		earfcn = earfcn,
		tac = first_field(fields, "tac"),
		band = band,
		band_count = band ~= "" and 1 or 0,
		dl_pci = pci,
		dl_fcn = dl_fcn,
		ul_fcn = ul_fcn,
		dlbw = dlbw,
		ulbw = ulbw,
		DLBW = dlbw,
		ULBW = ulbw,
		CQI = cqi,
		NR5G_AMBR_DL = ambr_dl,
		NR5G_AMBR_UL = ambr_ul,
		rsrp = rsrp,
		sinr = first_field(fields, "sinr"),
		rsrq = first_field(fields, "rsrq"),
		rssi = rssi,
		rscp = first_field(fields, "rscp"),
		model = model,
		revision = first_field(fields, "revision"),
		nrcap = (raw_mode:upper():find("NR", 1, true) or
			raw_mode:upper():find("5G", 1, true)) and "1" or "0",
		model_temp = first_field(fields, "temperature", "model_temp"),
		cpin = cpin,
		CPIN = ready_cpin(cpin),
		simtype = simtype,
		simno = simno,
		simcount = "3",
		switchmode = "1",
		control = at_port ~= "" and at_port or modem.name or "",
		online = online and 1 or 0,
		netlink = online and 1 or 0,
		status = online and 0 or 1,
		gateway_if = index,
		signal = signal or -999,
		signalStrength = signal or "",
		manufacturer = manufacturer,
		interface = modem.interface or ""
	}

	-- The factory schema numbers secondary carriers as 1, 2, ... and may
	-- expose more than two component carriers.  Copy only contiguous,
	-- complete carrier tuples so band_count never advertises phantom CA.
	for carrier = 1, MAX_APP_CARRIERS - 1 do
		local suffix = tostring(carrier)
		local carrier_band = first_field(fields,
			"band" .. suffix, "band_" .. suffix)
		carrier_band = tostring(carrier_band):gsub("^[BbNn]", "")
		local carrier_dl_fcn = first_field(fields,
			"dl_fcn" .. suffix, "dl_fcn_" .. suffix)
		if carrier_band == "" or carrier_dl_fcn == "" then
			break
		end
		local carrier_ul_fcn = first_field(fields,
			"ul_fcn" .. suffix, "ul_fcn_" .. suffix)
		local carrier_dlbw = first_field(fields,
			"dlbw" .. suffix, "dlbw_" .. suffix,
			"dl_bandwidth" .. suffix, "dl_bandwidth_" .. suffix)
		local carrier_ulbw = first_field(fields,
			"ulbw" .. suffix, "ulbw_" .. suffix,
			"ul_bandwidth" .. suffix, "ul_bandwidth_" .. suffix)
		status["band" .. suffix] = carrier_band
		status["dl_fcn" .. suffix] = carrier_dl_fcn
		status["ul_fcn" .. suffix] = carrier_ul_fcn
		status["dlbw" .. suffix] = carrier_dlbw
		status["ulbw" .. suffix] = carrier_ulbw
		status["DLBW" .. suffix] = carrier_dlbw
		status["ULBW" .. suffix] = carrier_ulbw
		status["dl_mode" .. suffix] = first_field(fields,
			"dl_mode" .. suffix, "dl_mode_" .. suffix)
		status.band_count = carrier + 1
	end
	return status
end

local modem_cache
local modem_cache_at = 0
local selector_cache
local selector_cache_at = 0
local fast_signal_cache = {}
local fast_signal_cache_at = {}
local fast_signal_failure_at = {}
local carrier_cache = {}
local carrier_cache_at = {}
local carrier_failure_at = {}

local function cached_sim_status(force)
	local now = precise_time()
	local maximum_age = M.cache_refresh_policy().selector
	if not force and selector_cache and now - selector_cache_at < maximum_age then
		return selector_cache
	end
	if not force then
		local shared, updated = shared_cache_read("selector", maximum_age, false)
		if shared then
			selector_cache = shared
			selector_cache_at = updated
			return shared
		end
	end
	local value = safe_ubus("c2000max", "sim_status", {})
	if next(value) then
		selector_cache = value
		selector_cache_at = now
		shared_cache_write("selector", value)
	elseif force then
		-- A state-changing request must never make a decision from stale
		-- selector data when the serialized SIM service is unavailable.
		return {}
	end
	return selector_cache or value
end

local function list_modems(force)
	local now = precise_time()
	local maximum_age = M.cache_refresh_policy().modem
	if not force and modem_cache and
	   now - modem_cache_at < maximum_age then
		return modem_cache
	end
	if not force then
		local shared, updated = shared_cache_read(
			"modems", maximum_age, false)
		if shared then
			modem_cache = shared
			modem_cache_at = updated
			return shared
		end
	end
	local result = {}
	local selector = cached_sim_status(force)
	uci:foreach("qmodem", "modem-device", function(section)
		if section.state ~= "disabled" then
			local id = section[".name"]
			local info = safe_ubus("qmodem", "info", {
				config_section = id
			})
			local network = safe_ubus("qmodem", "network_info", {
				config_section = id
			})
			local sim = safe_ubus("qmodem", "sim_info", {
				config_section = id
			})
			local modem = {
				name = id,
				model = section.model or section.name or section.platform or "",
				manufacturer = section.manufacturer or "",
				interface = section.network_interface or section.interface or "",
				selector = selector,
				info = info,
				network = network,
				sim = sim
			}
			modem.status = build_modem_status(modem, selector, #result + 1)
			result[#result + 1] = modem
		end
	end)
	modem_cache = result
	modem_cache_at = now
	if #result > 0 then
		shared_cache_write("modems", result)
	end
	return result
end

function M.modems(force)
	return list_modems(force)
end

local function list_wifi()
	local cursor = require("luci.model.uci").cursor()
	local result = {}
	cursor:foreach("wireless", "wifi-iface", function(section)
		if section.mode == "ap" then
			local name = section[".name"]
			local device = section.device or ""
			result[#result + 1] = {
				rule_name = name,
				ssid = section.ssid or "",
				password = section.key or "",
				encryption = section.encryption or "none",
				hidden = section.hidden or "0",
				disabled = section.disabled or "0",
				channel = device ~= "" and
					(cursor:get("wireless", device, "channel") or "auto") or "auto",
				max_link = tonumber(section.maxassoc or section.maxstanum or "0") or 0
			}
		end
	end)
	if #result == 0 then
		result[1] = {}
	end
	return result
end

local function valid_text(value, maximum, allow_empty)
	if type(value) ~= "string" or #value > maximum or value:find("[%z\r\n]") then
		return false
	end
	return allow_empty or #value > 0
end

local function valid_wifi_encryption(value)
	if type(value) ~= "string" or #value == 0 or #value > 64 or
	   value:find("[^a-z0-9+_%-]") then
		return false
	end
	local first = true
	local bases = {
		none = true, psk = true, psk2 = true, ["psk-mixed"] = true,
		["psk2-mixed"] = true, sae = true, ["sae-mixed"] = true,
		["sae-ext"] = true, owe = true, ["owe-transition"] = true
	}
	local ciphers = {
		ccmp = true, ccmp256 = true, gcmp = true, gcmp256 = true,
		tkip = true
	}
	for part in value:gmatch("[^+]+") do
		if (first and not bases[part]) or (not first and not ciphers[part]) then
			return false
		end
		first = false
	end
	return not first
end

local function wifi_ap_sections(cursor)
	local sections = {}
	cursor:foreach("wireless", "wifi-iface", function(section)
		if section.mode == "ap" then
			sections[#sections + 1] = section[".name"]
		end
	end)
	return sections
end

local function wifi_targets(cursor, rule_name)
	local sections = wifi_ap_sections(cursor)
	if rule_name == "" or rule_name == "t0" then
		return sections
	end
	for _, name in ipairs(sections) do
		if name == rule_name then
			return { name }
		end
	end
	-- The official APP reconstructs wlan0/wlan1 names when its dual-band
	-- switch is toggled.  Upstream OpenWrt commonly names those same AP
	-- sections default_radio0/default_radio1, so resolve the APP alias by
	-- stable UCI order instead of silently accepting a no-op update.
	local index = tonumber(rule_name:match("^wlan(%d+)$"))
	if index and sections[index + 1] then
		return { sections[index + 1] }
	end
	return {}
end

local function wifi_flag(value)
	if value == true or value == 1 or value == "1" then
		return "1"
	elseif value == false or value == 0 or value == "0" then
		return "0"
	end
	return nil
end

local function wifi_password(item)
	local value = item.password
	if value == nil then value = item.key end
	if value == nil then value = item.psk end
	if value == nil then value = item.passwd end
	return value
end

local function write_wifi_state(state, message, targets)
	if type(fs.mkdirr) ~= "function" or type(fs.writefile) ~= "function" then
		return
	end
	fs.mkdirr(STATE_DIR)
	if type(fs.chmod) == "function" then
		fs.chmod(STATE_DIR, "0755")
	end
	local path = STATE_DIR .. "/wifi.state"
	fs.writefile(path, json.stringify({
		state = state,
		message = message or "",
		targets = targets or {},
		updated = os.time()
	}))
	if type(fs.chmod) == "function" then
		fs.chmod(path, "0600")
	end
end

local function apply_wifi(items)
	if type(items) ~= "table" then
		return false, "invalid wifi list"
	end

	local writer = require("luci.model.uci").cursor()
	local changed = false
	local changed_targets = {}
	local changed_target_set = {}
	for _, item in pairs(items) do
		if type(item) ~= "table" then
			return false, "invalid wifi entry"
		end
		local rule = tostring(item.rule_name or item.ruleName or "t0")
		if not rule:match("^[A-Za-z0-9_%-]+$") then
			return false, "invalid wifi rule"
		end
		local targets = wifi_targets(writer, rule)
		if #targets == 0 then
			return false, "wifi rule not found"
		end

		for _, target in ipairs(targets) do
			if not changed_target_set[target] then
				changed_target_set[target] = true
				changed_targets[#changed_targets + 1] = target
			end
			if item.ssid ~= nil then
				if not valid_text(item.ssid, 32, false) then
					return false, "invalid ssid"
				end
				writer:set("wireless", target, "ssid", item.ssid)
				changed = true
			end
			if item.encryption ~= nil then
				if not valid_wifi_encryption(item.encryption) then
					return false, "invalid encryption"
				end
				writer:set("wireless", target, "encryption", item.encryption)
				changed = true
			end
			local password = wifi_password(item)
			if password ~= nil then
				if not valid_text(password, 64, true) or
				   (#password == 64 and not password:match("^[0-9A-Fa-f]+$")) then
					return false, "invalid wifi password"
				end
				if password == "" then
					writer:delete("wireless", target, "key")
				elseif #password < 8 then
					return false, "wifi password is too short"
				else
					writer:set("wireless", target, "key", password)
				end
				changed = true
			end
			if item.hidden ~= nil then
				local hidden = wifi_flag(item.hidden)
				if not hidden then
					return false, "invalid hidden flag"
				end
				writer:set("wireless", target, "hidden", hidden)
				changed = true
			end
			if item.disabled ~= nil then
				local disabled = wifi_flag(item.disabled)
				if not disabled then
					return false, "invalid disabled flag"
				end
				writer:set("wireless", target, "disabled", disabled)
				changed = true
			end
			if item.max_link ~= nil then
				local limit = tonumber(item.max_link)
				if not limit or limit < 0 or limit > 512 or limit ~= math.floor(limit) then
					return false, "invalid station limit"
				end
				if limit == 0 then
					writer:delete("wireless", target, "maxassoc")
				else
					writer:set("wireless", target, "maxassoc", tostring(limit))
				end
				changed = true
			end
		end

		if item.channel ~= nil then
			local channel = tostring(item.channel)
			if channel ~= "auto" and not channel:match("^%d+$") then
				return false, "invalid channel"
			end
			for _, target in ipairs(targets) do
				local device = writer:get("wireless", target, "device")
				if device then
					writer:set("wireless", device, "channel", channel)
					changed = true
				end
			end
		end
	end

	if changed then
		if not writer:commit("wireless") then
			writer:revert("wireless")
			write_wifi_state("commit_error", "wireless commit failed",
				changed_targets)
			return false, "wireless commit failed"
		end
		write_wifi_state("committed", "configuration committed; reload queued",
			changed_targets)
		util.exec("/usr/sbin/c2000max-app-wifi-apply >/dev/null 2>&1 &")
	end
	return true
end

local function valid_mac_address(value)
	return type(value) == "string" and
		value:match("^[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:" ..
			"[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:" ..
			"[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]$") ~= nil
end

local function valid_client_mac(value)
	if not valid_mac_address(value) then
		return false
	end
	value = value:upper()
	if value == "00:00:00:00:00:00" or value == "FF:FF:FF:FF:FF:FF" then
		return false
	end
	local first = tonumber(value:sub(1, 2), 16)
	-- Keep locally administered/private phone addresses, but never expose a
	-- multicast address as an APP terminal.
	return first ~= nil and first % 2 == 0
end

local function wireless_band(frequency)
	local value = tonumber(frequency)
	if not value then
		return ""
	elseif value < 3000 then
		return "2.4G"
	elseif value < 5500 then
		return "5.2G"
	elseif value < 6000 then
		return "5.8G"
	end
	return "5G"
end

local function wireless_interfaces()
	local interfaces = {}
	local current
	for line in tostring(util.exec("iw dev 2>/dev/null") or ""):gmatch(
	    "[^\r\n]+") do
		local ifname = line:match("^%s*Interface%s+(%S+)")
		if ifname and ifname:match("^[A-Za-z0-9_.:%-]+$") then
			current = { ifname = ifname, stations = {} }
			interfaces[#interfaces + 1] = current
		elseif current then
			local address = line:match("^%s*addr%s+(%S+)")
			local ssid = line:match("^%s*ssid%s+(.+)$")
			local kind = line:match("^%s*type%s+(%S+)")
			local channel, frequency = line:match(
				"^%s*channel%s+(%d+)%s+%((%d+)%s+MHz%)")
			if address and valid_mac_address(address) then
				current.mac = address:upper()
			elseif ssid then
				current.ssid = ssid
			elseif kind then
				current.type = kind
			elseif channel then
				current.channel = tonumber(channel) or channel
				current.frequency = tonumber(frequency) or frequency
			end
		end
	end

	for _, interface in ipairs(interfaces) do
		if interface.type == "AP" or interface.type == "ap" then
			local command = "iw dev " .. util.shellquote(interface.ifname) ..
				" station dump 2>/dev/null"
			local station
			for line in tostring(util.exec(command) or ""):gmatch(
			    "[^\r\n]+") do
				local mac = line:match("^%s*Station%s+(%S+)")
				if mac and valid_mac_address(mac) then
					station = {
						mac = mac:upper(),
						ifname = interface.ifname,
						ssid = interface.ssid or "",
						channel = interface.channel or "",
						frequency = interface.frequency or ""
					}
					interface.stations[#interface.stations + 1] = station
				elseif station then
					local key, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
					key = tostring(key or ""):lower()
					if key == "rx bytes" then
						station.rxbytes = tonumber(value) or 0
					elseif key == "tx bytes" then
						station.txbytes = tonumber(value) or 0
					elseif key == "signal" then
						station.rssi = tonumber(tostring(value):match("[-+]?%d+")) or 0
					elseif key == "connected time" then
						station.connected = tonumber(tostring(value):match("%d+")) or 0
					elseif key == "rx bitrate" then
						station.rxrate = math.floor((tonumber(tostring(value):match(
							"[%d%.]+")) or 0) * 1000)
					elseif key == "tx bitrate" then
						station.txrate = math.floor((tonumber(tostring(value):match(
							"[%d%.]+")) or 0) * 1000)
					elseif key == "mld address" or key == "mld addr" or
					       key == "mld mac address" then
						local mld = tostring(value or ""):match("([%x][%x]:[%x][%x]:[%x][%x]:[%x][%x]:[%x][%x]:[%x][%x])")
						if valid_client_mac(mld) then
							station.mld_mac = mld:upper()
						end
					end
				end
			end
		end
	end
	return interfaces
end

local function device_internet_allowed(mac)
	mac = tostring(mac or ""):upper()
	if not valid_mac_address(mac) then
		return true
	end
	uci:load("c2000max")
	if tostring(uci:get("c2000max", "access_control", "enabled") or "0") ~= "1" then
		return true
	end
	local mode = tostring(uci:get("c2000max", "access_control", "mode") or
		"blacklist")
	local selected = false
	uci:foreach("c2000max", "access_device", function(section)
		if tostring(section.enabled or "1") ~= "0" and
		   tostring(section.mac or ""):upper() == mac then
			selected = true
		end
	end)
	if mode == "whitelist" then
		return selected
	end
	return not selected
end

local function list_clients()
	local clients = {}
	local live = {}
	local interfaces = wireless_interfaces()
	local local_macs = {}
	local station_aliases = {}
	local function remember_local(value)
		if valid_mac_address(value) then
			local_macs[value:upper()] = true
		end
	end

	for _, interface in ipairs(interfaces) do
		remember_local(interface.mac)
		for _, station in ipairs(interface.stations) do
			local link_mac = tostring(station.mac or ""):upper()
			local device_mac = tostring(station.mld_mac or station.mac or ""):upper()
			if valid_client_mac(link_mac) and valid_client_mac(device_mac) then
				station_aliases[link_mac] = device_mac
			end
		end
	end
	for line in tostring(util.exec("ip -o link show 2>/dev/null") or ""):gmatch(
	    "[^\r\n]+") do
		remember_local(line:match("%slink/ether%s+(%S+)"))
	end

	local function canonical_mac(mac)
		if not valid_client_mac(mac) then
			return nil
		end
		mac = mac:upper()
		return station_aliases[mac] or mac
	end
	local function client_for(mac)
		mac = canonical_mac(mac)
		if not mac or local_macs[mac] then
			return nil
		end
		if not clients[mac] then
			clients[mac] = {
				client = mac, mac = mac, real_mac = mac,
				ip = "", ipaddr = "", hostname = "", name = "",
				switch = 1, switch_off = 0, authed = 1, exsit = 1,
				type = "wired", ifname = "br-lan", rssi = 0,
				rxbytes = 0, txbytes = 0, rxrate = 0, txrate = 0,
				assoctime = "0s"
			}
		end
		return clients[mac]
	end

	local leasefile = uci:get("dhcp", "@dnsmasq[0]", "leasefile") or
		"/tmp/dhcp.leases"
	local file = io.open(leasefile, "r")
	if file then
		for line in file:lines() do
			local expires, mac, ip, hostname =
				line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
			local expiry = tonumber(expires) or 0
			local item
			if expiry == 0 or expiry > math.floor(precise_time()) then
				item = client_for(mac)
			end
			if item and ip then
				item.ip = ip
				item.ipaddr = ip
				item.hostname = hostname == "*" and "" or hostname
				item.name = item.hostname
				item.expires = expiry
			end
		end
		file:close()
	end

	for line in tostring(util.exec(
	    "ip neigh show dev br-lan 2>/dev/null") or ""):gmatch("[^\r\n]+") do
		local ip, mac, state = line:match(
			"^(%S+).-lladdr%s+(%S+)%s+(%S+)%s*$")
		if state ~= "FAILED" and state ~= "INCOMPLETE" then
			local item = client_for(mac)
			if item and ip then
				local canonical = canonical_mac(mac)
				live[canonical] = true
				item.ip = ip
				item.ipaddr = ip
			end
		end
	end

	for _, interface in ipairs(interfaces) do
		for _, station in ipairs(interface.stations) do
			local mac = station.mld_mac or station.mac
			local item = client_for(mac)
			if item then
				local canonical = canonical_mac(mac)
				local was_wireless = item.type == "wireless"
				live[canonical] = true
				item.type = "wireless"
				if not was_wireless then
					item.ifname = station.ifname
				elseif not tostring(item.ifname):find(station.ifname, 1, true) then
					item.ifname = item.ifname .. "," .. station.ifname
				end
				item.ssid = station.ssid
				item.channel = station.channel
				item.frequency = station.frequency
				local band = wireless_band(station.frequency)
				if not was_wireless then
					item.band = band
				elseif item.band ~= band then
					item.band = "MLO"
				end
				local rssi = station.rssi or 0
				if not was_wireless or item.rssi == 0 or rssi > item.rssi then
					item.rssi = rssi
				end
				item.rxbytes = (item.rxbytes or 0) + (station.rxbytes or 0)
				item.txbytes = (item.txbytes or 0) + (station.txbytes or 0)
				item.rxrate = (item.rxrate or 0) + (station.rxrate or 0)
				item.txrate = (item.txrate or 0) + (station.txrate or 0)
				local connected = math.max(tonumber(tostring(item.assoctime or ""):match("%d+")) or 0,
					tonumber(station.connected) or 0)
				item.assoctime = tostring(connected) .. "s"
			end
		end
	end

	local macs, result = {}, {}
	for mac in pairs(clients) do
		if live[mac] and not local_macs[mac] then
			macs[#macs + 1] = mac
		end
	end
	table.sort(macs)
	for _, mac in ipairs(macs) do
		local item = clients[mac]
		local allowed = device_internet_allowed(mac)
		item.switch = allowed and 1 or 0
		item.switch_off = allowed and 0 or 1
		result[#result + 1] = item
	end
	if #result == 0 then
		result[1] = {}
	end
	return result
end

local function denied_station_macs()
	local result, seen = {}, {}
	local function add(value)
		if type(value) == "table" then
			for _, item in pairs(value) do add(item) end
			return
		end
		for mac in tostring(value or ""):gmatch("[^,%s]+") do
			if valid_mac_address(mac) then
				mac = mac:upper()
				if not seen[mac] then
					seen[mac] = true
					result[#result + 1] = mac
				end
			end
		end
	end
	uci:foreach("wireless", "wifi-iface", function(section)
		if tostring(section.macfilter or ""):lower() == "deny" then
			add(section.maclist)
		end
	end)
	for _, config in ipairs({ "access_ctl", "cloudd_cli" }) do
		uci:foreach(config, "client", function(section)
			if tostring(section.switch or "1") == "0" then
				add(section.mac)
			end
		end)
	end
	if tostring(uci:get("c2000max", "access_control", "enabled") or "0") == "1" and
			tostring(uci:get("c2000max", "access_control", "mode") or "blacklist") == "blacklist" then
		uci:foreach("c2000max", "access_device", function(section)
			if tostring(section.enabled or "1") ~= "0" then
				add(section.mac)
			end
		end)
	end
	table.sort(result)
	if #result == 0 then
		result[1] = ""
	end
	return result
end

function M.station_status()
	local list = {}
	for _, interface in ipairs(wireless_interfaces()) do
		if interface.type == "AP" or interface.type == "ap" then
			local stations, seen = {}, {}
			for _, item in ipairs(interface.stations) do
				local mac = tostring(item.mld_mac or item.mac or ""):upper()
				if valid_client_mac(mac) and not seen[mac] then
					seen[mac] = true
					stations[#stations + 1] = mac
				end
			end
			local online = #stations
			if #stations == 0 then stations[1] = "" end
			list[#list + 1] = {
				band = wireless_band(interface.frequency),
				online = online,
				servied = 0,
				list = stations,
				mac = interface.mac or ""
			}
		end
	end
	if #list == 0 then list[1] = "" end
	return { list = list, deny = denied_station_macs() }
end

local function device_internet_request(data)
	data = type(data) == "table" and data or {}
	local item = type(data.client) == "table" and data.client or
		(type(data.station) == "table" and data.station or
		(type(data.terminal) == "table" and data.terminal or data))
	local mac = item.mac or item.client or item.real_mac or item.macaddr
	local allowed
	local requested = false
	if item.switch_off ~= nil then
		allowed = tonumber(item.switch_off) == 0
		requested = true
	elseif item.switch ~= nil then
		allowed = tonumber(item.switch) ~= 0
		requested = true
	elseif item.online ~= nil then
		allowed = tonumber(item.online) ~= 0
		requested = true
	elseif item.deny ~= nil then
		allowed = not (item.deny == true or tonumber(item.deny) == 1)
		requested = true
	end
	if requested and not valid_mac_address(mac) then
		return nil, nil, true
	end
	return mac and tostring(mac):upper() or nil, allowed, requested
end

function M.set_device_internet(mac, allowed)
	if not valid_mac_address(mac) then
		return { code = "2", errcode = "2", message = "invalid mac" }
	end
	mac = tostring(mac):upper()
	uci:load("c2000max")
	if not uci:get("c2000max", "access_control") then
		uci:section("c2000max", "access", "access_control", {
			enabled = "1", mode = "blacklist", lan_device = "auto"
		})
	else
		uci:set("c2000max", "access_control", "enabled", "1")
		uci:set("c2000max", "access_control", "mode", "blacklist")
	end

	local matches = {}
	uci:foreach("c2000max", "access_device", function(section)
		if tostring(section.mac or ""):upper() == mac then
			matches[#matches + 1] = section[".name"]
		end
	end)
	if #matches == 0 and not allowed then
		local name = "app_" .. mac:gsub(":", ""):lower()
		uci:section("c2000max", "access_device", name, {
			mac = mac, enabled = "1", source = "official_app"
		})
	else
		for _, section in ipairs(matches) do
			uci:set("c2000max", section, "enabled", allowed and "0" or "1")
		end
	end
	if not uci:commit("c2000max") then
		return { code = "2", errcode = "2", message = "commit failed" }
	end
	local rc = sys.call("/usr/sbin/c2000max-access apply >/dev/null 2>&1")
	if rc ~= 0 then
		return { code = "2", errcode = "2", message = "apply failed" }
	end
	return {
		code = "0", errcode = "0", mac = mac,
		switch = allowed and 1 or 0, switch_off = allowed and 0 or 1
	}
end

local function apn_info()
	local section = first_modem()
	if not section then
		return { index = 1, enabled = "0" }
	end
	return {
		index = 1,
		config_section = section,
		enabled = (uci:get("qmodem", section, "apn") or "") ~= "" and "1" or "0",
		name = uci:get("qmodem", section, "apn") or "",
		username = uci:get("qmodem", section, "username") or "",
		password = uci:get("qmodem", section, "password") or "",
		auth = uci:get("qmodem", section, "auth") or "none",
		pdptype = uci:get("qmodem", section, "pdp_type") or "ipv4v6"
	}
end

local function apply_apn(data)
	local section = first_modem()
	if not section then
		return false, "modem not found"
	end
	local source = type(data.apn) == "table" and data.apn or data
	local name = source.name or source.apn
	local username = source.username
	local password = source.password
	local auth = source.auth
	local pdptype = source.pdptype or source.pdp_type

	if name ~= nil and not valid_text(name, 100, true) then
		return false, "invalid apn"
	end
	if username ~= nil and not valid_text(username, 128, true) then
		return false, "invalid apn username"
	end
	if password ~= nil and not valid_text(password, 128, true) then
		return false, "invalid apn password"
	end
	if auth ~= nil and auth ~= "none" and auth ~= "pap" and
	   auth ~= "chap" and auth ~= "both" and auth ~= "MsChapV2" then
		return false, "invalid apn authentication"
	end
	if pdptype ~= nil and pdptype ~= "ip" and pdptype ~= "ipv6" and
	   pdptype ~= "ipv4v6" then
		return false, "invalid pdp type"
	end

	local values = {
		apn = name,
		username = username,
		password = password,
		auth = auth,
		pdp_type = pdptype
	}
	for option, value in pairs(values) do
		if value ~= nil then
			if value == "" then
				uci:delete("qmodem", section, option)
			else
				uci:set("qmodem", section, option, tostring(value))
			end
		end
	end
	if not uci:commit("qmodem") then
		uci:revert("qmodem")
		return false, "qmodem commit failed"
	end
	safe_ubus("qmodem", "modem_redial", { config_section = section })
	return true
end

local function valid_ipv4(ip)
	if type(ip) ~= "string" or not ip:match("^%d+%.%d+%.%d+%.%d+$") then
		return false
	end
	local count = 0
	for part in ip:gmatch("%d+") do
		local value = tonumber(part)
		count = count + 1
		if not value or value < 0 or value > 255 then
			return false
		end
	end
	local first = tonumber(ip:match("^(%d+)"))
	return count == 4 and first and first >= 1 and first <= 223
end

local function interface_stats(name)
	if type(name) ~= "string" or not name:match("^[A-Za-z0-9_.:%-]+$") then
		return {}
	end
	local base = "/sys/class/net/" .. name .. "/statistics/"
	return {
		name = name,
		rx_bytes = tonumber(read_trim(base .. "rx_bytes") or "0") or 0,
		tx_bytes = tonumber(read_trim(base .. "tx_bytes") or "0") or 0,
		rx_packets = tonumber(read_trim(base .. "rx_packets") or "0") or 0,
		tx_packets = tonumber(read_trim(base .. "tx_packets") or "0") or 0
	}
end

local function sim_status(force)
	return cached_sim_status(force == true)
end

local function sim_selection(selector)
	selector = type(selector) == "table" and selector or sim_status()
	local current = slot_number(selector.current_slot) or
		slot_number(selector.configured_slot) or 2
	local configured = slot_number(selector.configured_slot) or current
	local iccid = tostring(selector.iccid or "")
	return {
		cur = current,
		default = configured,
		mode = configured_sim_mode(),
		adv_sim = "0",
		gval = "0-2,1-1,1-2",
		max = "3",
		stype = "0,0,4",
		type = "0,0,4",
		iccid = { iccid },
		roaming = "",
		apn_cfg = "",
		ippass = "",
		mobility = "1",
		freq_time = "",
		endtime = "",
		starttime = "",
		peak_hour = "0",
		peaktime = "",
		freqmode = "auto",
		earfreq_mode = "band",
		freq5 = { enabled = "0", earfcn = "", pci = "", band = "" },
		freq4 = { enabled = "0", earfcn = "", pci = "" },
		band = { enabled = "0", freq = "" }
	}
end

local function app_cpecfg()
	local slots = {}
	for index = 1, 3 do
		slots[tostring(index)] = {
			roaming = "",
			ippass = "",
			mobility = "1",
			freq_time = "",
			endtime = "",
			starttime = "",
			peak_hour = "0",
			peaktime = "",
			freqmode = "auto",
			earfreq_mode = "band",
			freq5 = { enabled = "0", earfcn = "", pci = "", band = "" },
			freq4 = { enabled = "0", earfcn = "", pci = "" },
			band = { enabled = "0", freq = "" },
			apn_cfg = "",
			force_ims = "",
			compatibility = "",
			nrrc = "",
			compatible_nr = "",
			fallbackToR16 = "",
			fallbackToLTE = ""
		}
	end
	return { slots }
end

local function app_cellular(modems)
	local result = {}
	for _, modem in ipairs(type(modems) == "table" and modems or {}) do
		local status = type(modem.status) == "table" and modem.status or {}
		local identity_text = table.concat({
			tostring(modem.model or ""),
			tostring(modem.manufacturer or ""),
			tostring(status.real_name or ""),
			tostring(status.driver or "")
		}, " "):lower()
		local mt5700 = identity_text:find("mt5700", 1, true) ~= nil or
			identity_text:find("td tech", 1, true) ~= nil
		result[#result + 1] = {
			automatic = 0,
			blacklist_band = mt5700 and "79" or "",
			command_equal = 0,
			compatibility = mt5700 and 1 or 0,
			earfcn = tostring(status.earfcn or ""),
			earfcn4 = { band = "1", mode = "2", pci = "1" },
			earfcn5 = { band = "1", mode = "2", pci = "1" },
			earfreq_mode = "",
			freq_multi = "1",
			freq_text = "",
			freq_val = mt5700 and
				"nr-78:41:79:28:1:8:5:3,lte-1:3:5:8:34:38:39:40:41" or "",
			mobility = 1,
			nrcap = mt5700 and 1 or
				(tostring(status.nrcap or "0") == "1" and 1 or 0),
			nrrc = 1,
			pci = tostring(status.pci or ""),
			simisolate = 1,
			sms = 1
		}
	end
	if #result == 0 then
		result[1] = {}
	end
	return result
end

local function app_diagnosis(modems)
	local list = {}
	local netlink = 0
	for _, modem in ipairs(type(modems) == "table" and modems or {}) do
		local status = type(modem.status) == "table" and modem.status or {}
		local online = tonumber(status.netlink or 0) == 1
		if online then
			netlink = 1
		end
		list[#list + 1] = {
			isp = tostring(status.isp or ""),
			model = 0,
			nosignal = tonumber(status.signal or -999) <= -200 and 1 or 0,
			register = online and 0 or 1,
			sim = tostring(status.CPIN or "") == "0" and 0 or 1,
			using = #list == 0
		}
	end
	return { list = list, netlink = netlink, speedlimit = 0 }
end

local function empty_app_earfcn(data, selector)
	local index = tostring(data.index or "1")
	local action = tonumber(data.action or 2) or 2
	return {
		action = action,
		index = index,
		sim = tonumber(data.sim) or sim_selection(selector).cur,
		mode = "auto",
		band = { status = "0", freq = "" },
		earfcn = {
			{ MODE = "NR", status = "0", EARFCN = "", PCI = "", BAND = "" },
			{ MODE = "LTE", status = "0", EARFCN = "", PCI = "" }
		}
	}
end

local function trim_field(value)
	value = tostring(value or ""):match("^%s*(.-)%s*$") or ""
	return value:gsub('^"(.*)"$', "%1")
end

local function split_csv(value)
	local result = {}
	for field in (tostring(value or "") .. ","):gmatch("(.-),") do
		result[#result + 1] = trim_field(field)
	end
	return result
end

local function numeric_field(value)
	value = trim_field(value)
	if value:match("^[+-]?%d+%.?%d*$") then
		return value
	end
	return ""
end

local function decimal_hex_field(value)
	value = trim_field(value)
	if not value:match("^[0-9A-Fa-f]+$") then
		return ""
	end
	local number = tonumber(value, 16)
	if not number then
		return ""
	end
	return string.format("%.0f", number)
end

local function parse_huawei_monsc(response)
	local line = tostring(response or ""):match("%^MONSC:%s*([^\r\n]+)")
	if not line then
		return nil
	end
	local fields = split_csv(line)
	local mode = tostring(fields[1] or ""):upper()
	local result = {}
	if mode == "NR" or mode == "NR-5GC" then
		result.earfcn = numeric_field(fields[4])
		result.cell = decimal_hex_field(fields[6])
		result.pci = decimal_hex_field(fields[7])
		result.tac = numeric_field(fields[8])
		result.rsrp = numeric_field(fields[9])
		result.rsrq = numeric_field(fields[10])
		result.sinr = numeric_field(fields[11])
		result.band = inferred_band("NR", result.earfcn)
	elseif mode == "LTE" or mode == "EMTC" or mode == "NB-IOT" then
		result.earfcn = numeric_field(fields[4])
		result.cell = decimal_hex_field(fields[5])
		result.pci = decimal_hex_field(fields[6])
		result.tac = numeric_field(fields[7])
		result.rsrp = numeric_field(fields[8])
		result.rsrq = numeric_field(fields[9])
	else
		return nil
	end
	if result.rsrp == "" and result.rsrq == "" and result.sinr == "" then
		return nil
	end
	return result
end

local function fast_signal_supported(modem)
	local status = type(modem) == "table" and modem.status or {}
	local identity_text = table.concat({
		tostring(type(modem) == "table" and modem.manufacturer or ""),
		tostring(type(modem) == "table" and modem.model or ""),
		tostring(status.driver or ""),
		tostring(status.real_name or "")
	}, " "):lower()
	return identity_text:find("huawei", 1, true) ~= nil or
		identity_text:find("td tech", 1, true) ~= nil or
		identity_text:find("mt5700", 1, true) ~= nil
end

local function modem_at_port(modem)
	local section = type(modem) == "table" and tostring(modem.name or "") or ""
	local status = type(modem) == "table" and modem.status or {}
	local port = section ~= "" and
		(uci:get("qmodem", section, "override_at_port") or
		 uci:get("qmodem", section, "at_port")) or nil
	if not port or port == "" then
		port = status.control
	end
	port = tostring(port or "")
	if not port:match("^/dev/[%w%._:/%-]+$") then
		return nil
	end
	return port
end

local function query_serialized_at(modem, command)
	if not fast_signal_supported(modem) then
		return nil
	end
	local section = tostring(modem.name or "")
	local port = modem_at_port(modem)
	if section == "" or not port then
		return nil
	end
	local reply = safe_ubus("qmodem", "send_at", {
		config_section = section,
		params = {
			at = command,
			port = port,
			use_ubus_flag = "1"
		}
	})
	local at_cfg = type(reply.at_cfg) == "table" and reply.at_cfg or reply
	if tostring(at_cfg.status or "") ~= "1" then
		return nil
	end
	return tostring(at_cfg.res or "")
end

local function inferred_cell_band(mode, channel)
	local value = tonumber(channel)
	local upper = tostring(mode or ""):upper()
	if not value then
		return ""
	end
	if upper == "LTE" then
		for _, item in ipairs({
			{ 0, 599, 1 }, { 1200, 1949, 3 },
			{ 2400, 2649, 5 }, { 3450, 3799, 8 },
			{ 36200, 36349, 34 }, { 37750, 38249, 38 },
			{ 38250, 38649, 39 }, { 38650, 39649, 40 },
			{ 39650, 41589, 41 }
		}) do
			if value >= item[1] and value <= item[2] then
				return tostring(item[3])
			end
		end
	elseif upper == "NR" or upper == "NR5G" then
		for _, item in ipairs({
			{ 422000, 434000, 1 }, { 361000, 376000, 3 },
			{ 173800, 178800, 5 }, { 185000, 192000, 8 },
			{ 151600, 159600, 28 }, { 499200, 537999, 41 },
			{ 620000, 680000, 78 }, { 693334, 733333, 79 }
		}) do
			if value >= item[1] and value <= item[2] then
				return tostring(item[3])
			end
		end
	end
	return ""
end

local function normalized_huawei_metric(value, encoded_threshold)
	local normalized = trim_field(value)
	local number = tonumber(normalized)
	if not number then
		return ""
	end
	if math.abs(number) > encoded_threshold then
		number = number / 8
	end
	if number == math.floor(number) then
		return tostring(math.floor(number))
	end
	return (string.format("%.1f", number):gsub("%.0$", ""))
end

local function parse_huawei_neighbor_cells(response)
	local cells = {}
	for body in tostring(response or ""):gmatch(
		"%^MONNC:%s*([^\r\n]+)") do
		local fields = split_csv(body)
		local mode = tostring(fields[1] or ""):upper()
		if mode == "NR5G" then
			mode = "NR"
		end
		if mode == "NR" or mode == "LTE" then
			local earfcn = numeric_field(fields[2])
			local pci = decimal_hex_field(fields[3])
			if earfcn ~= "" and pci ~= "" then
				local rsrp_threshold = mode == "NR" and 200 or 1000
				local rsrq_threshold = mode == "NR" and 100 or 1000
				local cell = {
					MODE = mode,
					EARFCN = earfcn,
					PCI = pci,
					BAND = inferred_cell_band(mode, earfcn),
					RSRP = normalized_huawei_metric(fields[4],
						rsrp_threshold),
					RSRQ = normalized_huawei_metric(fields[5],
						rsrq_threshold),
					lockneed = {
						MODE = "2", EARFCN = "1", PCI = "1"
					}
				}
				if mode == "NR" then
					cell.SINR = normalized_huawei_metric(fields[6], 100)
					cell.lockneed.BAND = "1"
				else
					cell.RXLEV = numeric_field(fields[6])
				end
				cells[#cells + 1] = cell
			end
		end
	end
	return cells
end

local function table_field(value, ...)
	if type(value) ~= "table" then
		return ""
	end
	for index = 1, select("#", ...) do
		local key = select(index, ...)
		if value[key] ~= nil and tostring(value[key]) ~= "" then
			return tostring(value[key])
		end
	end
	return ""
end

local function qmodem_neighbor_container(value)
	if type(value) ~= "table" then
		return {}
	end
	if type(value.neighborcell) == "table" then
		return value.neighborcell
	end
	if type(value.neighbour) == "table" then
		return value.neighbour
	end
	if type(value.result) == "table" then
		return qmodem_neighbor_container(value.result)
	end
	return {}
end

local function normalize_qmodem_neighbor_cells(value)
	local cells = {}
	local source = qmodem_neighbor_container(value)
	for _, mode in ipairs({ "NR", "LTE" }) do
		for _, item in ipairs(type(source[mode]) == "table" and
		    source[mode] or {}) do
			if type(item) == "table" then
				local earfcn = table_field(item, "EARFCN", "ARFCN", "earfcn",
					"arfcn")
				local pci = table_field(item, "PCI", "pci")
				if earfcn:match("^%d+$") and pci:match("^%d+$") then
					local band = table_field(item, "BAND", "band", "NR BAND")
					band = band:gsub("^[BbNn]", "")
					if band == "" then
						band = inferred_cell_band(mode, earfcn)
					end
					cells[#cells + 1] = {
						MODE = mode,
						EARFCN = earfcn,
						PCI = pci,
						BAND = band,
						RSRP = table_field(item, "RSRP", "rsrp", "ss_rsrp",
							"rxlev"),
						RSRQ = table_field(item, "RSRQ", "rsrq"),
						SINR = table_field(item, "SINR", "sinr", "ss_sinr"),
						lockneed = {
							MODE = "2", EARFCN = "1", PCI = "1",
							BAND = mode == "NR" and "1" or nil
						}
					}
				end
			end
		end
	end
	return cells
end

local function app_neighbour()
	local modem = list_modems(true)[1]
	local cells = {}
	if modem and fast_signal_supported(modem) then
		cells = parse_huawei_neighbor_cells(
			query_serialized_at(modem, "AT^MONNC"))
	end
	if #cells == 0 then
		local raw = modem_call("get_neighborcell")
		cells = normalize_qmodem_neighbor_cells(raw)
	end
	-- APP 2.3.1 expects one array per modem and reads the first non-empty
	-- array.  Returning QModem's native object is what caused the previous
	-- search page exception.
	return { neighbour = { cells } }
end

local function split_quoted_csv(value)
	local result, current = {}, {}
	local quoted = false
	value = tostring(value or "")
	for index = 1, #value do
		local character = value:sub(index, index)
		if character == '"' then
			quoted = not quoted
		elseif character == "," and not quoted then
			result[#result + 1] = trim_field(table.concat(current))
			current = {}
		else
			current[#current + 1] = character
		end
	end
	result[#result + 1] = trim_field(table.concat(current))
	return result
end

local function first_csv_value(value)
	return trim_field(tostring(value or ""):match("^([^,]+)") or "")
end

local function huawei_lock_row(mode, lock_type, fields)
	local row = {
		MODE = mode, status = "1", EARFCN = "", PCI = "", BAND = "",
		lock_type = lock_type
	}
	row.BAND = first_csv_value(fields[1])
	row.EARFCN = first_csv_value(fields[2])
	if lock_type == 2 then
		row.PCI = first_csv_value(fields[mode == "NR" and 4 or 3])
	end
	if row.BAND == "" or row.EARFCN == "" or
	   (lock_type == 2 and row.PCI == "") then
		return nil
	end
	return row
end

local function parse_huawei_lock_response(response, mode)
	local prefix = mode == "NR" and "NRFREQLOCK" or "LTEFREQLOCK"
	local lines = {}
	for line in tostring(response or ""):gmatch("[^\r\n]+") do
		line = trim_field(line)
		if line ~= "" and line ~= "OK" and
		   not line:match("^AT[%+%^]") then
			lines[#lines + 1] = line
		end
	end
	local header_index, header
	for index, line in ipairs(lines) do
		header = line:match("%^" .. prefix .. ":%s*(.*)$")
		if header then
			header_index = index
			break
		end
	end
	if not header_index then
		return nil
	end
	local header_fields = split_quoted_csv(header)
	local lock_type = tonumber(header_fields[1])
	if not lock_type then
		return nil
	end
	local result = {
		MODE = mode,
		-- APP checks cell-lock rows before it checks band.status.  A type-3
		-- Huawei lock is a band lock and must therefore stay status=0 here.
		status = (lock_type == 1 or lock_type == 2) and "1" or "0",
		EARFCN = "", PCI = "", BAND = "",
		lock_type = lock_type
	}
	if lock_type == 0 then
		return result, { result }
	end
	if lock_type == 3 then
		local bands, seen = {}, {}
		for index = header_index + 2, #lines do
			for band in tostring(lines[index] or ""):gmatch("%d+") do
				band = tostring(tonumber(band) or "")
				if band ~= "" and not seen[band] then
					seen[band] = true
					bands[#bands + 1] = band
				end
			end
		end
		if #bands == 0 and #header_fields > 3 then
			for band in table.concat(header_fields, ",", 4):gmatch("%d+") do
				band = tostring(tonumber(band) or "")
				if band ~= "" and not seen[band] then
					seen[band] = true
					bands[#bands + 1] = band
				end
			end
		end
		result.BAND = table.concat(bands, ":")
		return result, { result }
	end

	-- MT5700 returns a header, a mobility/count row, then one data row per
	-- lock.  Return every row so a multi-cell lock survives the APP readback
	-- instead of being collapsed to the first configured cell.
	local rows = {}
	for index = header_index + 2, #lines do
		local row = huawei_lock_row(mode, lock_type,
			split_quoted_csv(lines[index]))
		if row then
			rows[#rows + 1] = row
		end
	end
	if #rows == 0 and #header_fields > 3 then
		local row = huawei_lock_row(mode, lock_type,
			split_quoted_csv(table.concat(header_fields, ",", 4)))
		if row then
			rows[1] = row
		end
	end
	if #rows > 0 then
		return rows[1], rows
	end
	return result, { result }
end

local function qmodem_lock_status(value, mode)
	local source = qmodem_neighbor_container(value)
	local status = type(source.lockcell_status) == "table" and
		source.lockcell_status or {}
	local row = {
		MODE = mode, status = "0", EARFCN = "", PCI = "", BAND = ""
	}
	local rat = table_field(status, "Rat", "rat")
	local generic_status = table_field(status, "Status", "status")
	if generic_status:lower():find("lock", 1, true) and
	   not generic_status:lower():find("unlock", 1, true) and
	   rat:upper():find(mode, 1, true) then
		row.status = "1"
		row.EARFCN = table_field(status, "ARFCN", "arfcn")
		row.PCI = table_field(status, "PCI", "pci")
		row.BAND = table_field(status, "NR BAND", "band")
	elseif table_field(status, mode):lower() == "locked" then
		row.status = "1"
		row.EARFCN = table_field(status, mode .. "_Freq")
		row.PCI = table_field(status, mode .. "_PCI")
		row.BAND = table_field(status, mode .. "_Band")
	end
	return row
end

local function parse_huawei_network_mode(syscfg_response, option_response)
	local acquisition = tostring(syscfg_response or ""):match(
		"%^SYSCFGEX:%s*\"?([0-9A-Fa-f]+)")
	local option = tostring(option_response or ""):match(
		"%^C5GOPTION:%s*([01]%s*,%s*[01]%s*,%s*[01])")
	option = option and option:gsub("%s+", "") or ""
	if acquisition == "03" then
		return "lte"
	elseif acquisition == "08" then
		return "sa_only"
	elseif option == "0,1,0" then
		return "nsa"
	elseif option == "1,0,1" then
		return "sa"
	end
	return "auto"
end

local function read_huawei_network_mode(modem)
	local syscfg = query_serialized_at(modem, "AT^SYSCFGEX?")
	local option = query_serialized_at(modem, "AT^C5GOPTION?")
	return parse_huawei_network_mode(syscfg, option), syscfg, option
end

local function app_earfcn(data, selector)
	local result = empty_app_earfcn(data, selector)
	local modem = list_modems()[tonumber(data.index or 1) or 1]
	if not modem then
		return result
	end
	local nr, lte, nr_rows, lte_rows
	if fast_signal_supported(modem) then
		result.mode = read_huawei_network_mode(modem)
		nr, nr_rows = parse_huawei_lock_response(
			query_serialized_at(modem, "AT^NRFREQLOCK?"), "NR")
		lte, lte_rows = parse_huawei_lock_response(
			query_serialized_at(modem, "AT^LTEFREQLOCK?"), "LTE")
	else
		local raw = modem_call("get_neighborcell")
		nr = qmodem_lock_status(raw, "NR")
		lte = qmodem_lock_status(raw, "LTE")
	end
	nr = nr or result.earfcn[1]
	lte = lte or result.earfcn[2]
	result.earfcn = {}
	for _, row in ipairs(nr_rows or { nr }) do
		result.earfcn[#result.earfcn + 1] = row
	end
	for _, row in ipairs(lte_rows or { lte }) do
		result.earfcn[#result.earfcn + 1] = row
	end
	local band_parts = {}
	for _, row in ipairs({ nr, lte }) do
		if tonumber(row.lock_type) == 3 and row.BAND ~= "" then
			band_parts[#band_parts + 1] = row.MODE:lower() .. "-" .. row.BAND
		end
	end
	if #band_parts > 0 then
		result.band = { status = "1", freq = table.concat(band_parts, ",") }
	end
	return result
end

local function strict_integer(value, minimum, maximum, label, optional)
	local text_value = trim_field(value)
	if optional and text_value == "" then
		return ""
	end
	text_value = text_value:gsub("^[BbNn]", "")
	if not text_value:match("^%d+$") then
		return nil, "invalid " .. label
	end
	local number = tonumber(text_value)
	if not number or number < minimum or number > maximum then
		return nil, "invalid " .. label
	end
	return tostring(math.floor(number))
end

local function nr_scs_for_band(band)
	local value = tonumber(band) or 0
	for _, candidate in ipairs({ 1, 2, 3, 5, 7, 8, 12, 20, 25, 28,
		66, 71, 75, 76 }) do
		if value == candidate then
			return "0"
		end
	end
	for _, candidate in ipairs({ 38, 40, 41, 48, 77, 78, 79 }) do
		if value == candidate then
			return "1"
		end
	end
	if value == 257 or value == 258 or value == 260 or value == 261 then
		return "3"
	end
	return "0"
end

local function huawei_row_mode(row)
	local mode = type(row) == "table" and
		tostring(row.MODE or row.mode or ""):upper() or ""
	if mode:find("NR", 1, true) then
		return "NR"
	elseif mode == "LTE" then
		return "LTE"
	end
	return nil
end

local function huawei_row_enabled(row)
	local value = type(row) == "table" and row.enabled or nil
	if value == nil then value = "1" end
	value = tostring(value):lower()
	return value ~= "0" and value ~= "false"
end

local function quoted_values(values)
	return '"' .. table.concat(values, ",") .. '"'
end

local function huawei_cell_commands(rows)
	local grouped = {
		NR = { present = false, items = {}, seen = {} },
		LTE = { present = false, items = {}, seen = {} }
	}
	for _, row in ipairs(rows) do
		if type(row) ~= "table" then
			return nil, "invalid cell lock row"
		end
		local mode = huawei_row_mode(row)
		if not mode then
			return nil, "invalid radio mode"
		end
		local group = grouped[mode]
		group.present = true
		if huawei_row_enabled(row) then
			local earfcn, message = strict_integer(row.EARFCN or row.earfcn,
				0, 3279165, "EARFCN")
			if not earfcn then return nil, message end
			local band
			band, message = strict_integer(row.BAND or row.band,
				1, 1024, "band")
			if not band then return nil, message end
			local pci
			pci, message = strict_integer(row.PCI or row.pci, 0,
				mode == "NR" and 1007 or 503, "PCI", true)
			if pci == nil then return nil, message end
			local lock_type = pci == "" and 1 or 2
			if group.lock_type and group.lock_type ~= lock_type then
				return nil, "cannot mix frequency and cell locks for " .. mode
			end
			group.lock_type = lock_type
			local item = {
				band = band, earfcn = earfcn, pci = pci,
				scs = mode == "NR" and nr_scs_for_band(band) or ""
			}
			local key = table.concat({ item.band, item.earfcn,
				item.scs, item.pci }, ":")
			if not group.seen[key] then
				group.seen[key] = true
				group.items[#group.items + 1] = item
			end
		end
	end

	local commands = {}
	for _, mode in ipairs({ "NR", "LTE" }) do
		local group = grouped[mode]
		if group.present then
			local prefix = mode == "NR" and "AT^NRFREQLOCK=" or
				"AT^LTEFREQLOCK="
			if #group.items == 0 then
				commands[#commands + 1] = prefix .. "0"
			else
				local bands, earfcns, scs, pcis = {}, {}, {}, {}
				for _, item in ipairs(group.items) do
					bands[#bands + 1] = item.band
					earfcns[#earfcns + 1] = item.earfcn
					if mode == "NR" then scs[#scs + 1] = item.scs end
					if group.lock_type == 2 then pcis[#pcis + 1] = item.pci end
				end
				local parts = { tostring(group.lock_type), "0",
					tostring(#group.items), quoted_values(bands),
					quoted_values(earfcns) }
				if mode == "NR" then parts[#parts + 1] = quoted_values(scs) end
				if group.lock_type == 2 then
					parts[#parts + 1] = quoted_values(pcis)
				end
				commands[#commands + 1] = prefix .. table.concat(parts, ",")
			end
		end
	end
	if #commands == 0 then
		return nil, "cell lock data is empty"
	end
	return commands
end

local function huawei_band_commands(band)
	if type(band) ~= "table" then
		return nil, "invalid band lock"
	end
	if not huawei_row_enabled(band) then
		return { "AT^NRFREQLOCK=0", "AT^LTEFREQLOCK=0" }
	end
	local grouped = {
		NR = { values = {}, seen = {}, present = false },
		LTE = { values = {}, seen = {}, present = false }
	}
	for token in tostring(band.freq or ""):gmatch("[^,]+") do
		local label, values = token:match("^%s*([^%-]+)%-(.-)%s*$")
		label = tostring(label or ""):lower()
		local mode = label:find("lte", 1, true) and "LTE" or
			((label:find("nr", 1, true) or label:find("sa", 1, true) or
			  label:find("5g", 1, true)) and "NR" or nil)
		if mode then
			local group = grouped[mode]
			group.present = true
			for value in tostring(values or ""):gmatch("[^:;/%s]+") do
				local normalized, message = strict_integer(value, 1, 1024, "band")
				if not normalized then return nil, message end
				if not group.seen[normalized] then
					group.seen[normalized] = true
					group.values[#group.values + 1] = normalized
				end
			end
		end
	end
	local commands = {}
	for _, mode in ipairs({ "NR", "LTE" }) do
		local group = grouped[mode]
		local values = group.values
		if #values > 0 then
			commands[#commands + 1] = "AT^" ..
				(mode == "NR" and "NRFREQLOCK" or "LTEFREQLOCK") ..
				'=3,0,' .. tostring(#values) .. ',"' ..
				table.concat(values, ",") .. '"'
		elseif group.present then
			commands[#commands + 1] = "AT^" ..
				(mode == "NR" and "NRFREQLOCK" or "LTEFREQLOCK") .. "=0"
		end
	end
	if #commands == 0 then
		return nil, "invalid band selection"
	end
	return commands
end

local function huawei_lock_commands(data)
	local action = tonumber(data.action)
	if action == 0 then
		return { "AT^NRFREQLOCK=0", "AT^LTEFREQLOCK=0" }
	end
	local rows = type(data.earfcns) == "table" and data.earfcns or nil
	if not rows and type(data.earfcn) == "table" then
		rows = { data.earfcn }
	end
	local band_enabled = type(data.band) == "table" and
		huawei_row_enabled(data.band) and
		trim_field(data.band.freq) ~= ""
	local has_rows = rows and #rows > 0
	if type(data.band) == "table" and (band_enabled or not has_rows) then
		return huawei_band_commands(data.band)
	end
	if not has_rows then
		return nil, "cell lock data is missing"
	end
	return huawei_cell_commands(rows)
end

local function at_command_ok(response)
	local upper = tostring(response or ""):upper()
	return upper ~= "" and not upper:find("ERROR", 1, true) and
		not upper:find("+CME ERROR", 1, true) and
		upper:find("OK", 1, true) ~= nil
end

local function huawei_syscfg_command(response, acquisition)
	local body = tostring(response or ""):match(
		"%^SYSCFGEX:%s*([^\r\n]+)")
	local comma = body and body:find(",", 1, true) or nil
	local remainder = comma and body:sub(comma + 1) or
		"40000000,1,2,40000000,,"
	return 'AT^SYSCFGEX="' .. acquisition .. '",' .. remainder
end

local function huawei_network_mode_commands(mode, syscfg)
	local acquisition = (mode == "lte" and "03") or
		(mode == "sa_only" and "08") or "080302"
	local option = (mode == "nsa" or mode == "nsa_only") and "0,1,0" or
		(mode == "sa" and "1,0,1" or "1,1,1")
	local syscfg_command = huawei_syscfg_command(syscfg, acquisition)
	if mode == "sa_only" then
		return { "AT^C5GOPTION=" .. option, syscfg_command }
	elseif mode == "lte" then
		return { syscfg_command }
	end
	return { syscfg_command, "AT^C5GOPTION=" .. option }
end

local function invalidate_radio_cache()
	modem_cache = nil
	modem_cache_at = 0
	fast_signal_cache = {}
	fast_signal_cache_at = {}
	fast_signal_failure_at = {}
	carrier_cache = {}
	carrier_cache_at = {}
	carrier_failure_at = {}
	shared_cache_remove("modems")
	shared_cache_remove("selector")
	shared_cache_remove_prefix("fast_")
	shared_cache_remove_prefix("carrier_")
end

local function apply_huawei_lock(modem, data)
	local commands, message = huawei_lock_commands(data)
	if not commands then
		return false, message
	end
	if not at_command_ok(query_serialized_at(modem, "AT+CFUN=0")) then
		return false, "failed to enter airplane mode"
	end
	if type(nixio.nanosleep) == "function" then
		nixio.nanosleep(2)
	end
	for _, command in ipairs(commands) do
		if not at_command_ok(query_serialized_at(modem, command)) then
			query_serialized_at(modem, "AT+CFUN=1")
			return false, "modem rejected cell lock"
		end
	end
	if type(nixio.nanosleep) == "function" then
		nixio.nanosleep(1)
	end
	if not at_command_ok(query_serialized_at(modem, "AT+CFUN=1")) then
		return false, "cell lock applied but modem did not leave airplane mode"
	end
	invalidate_radio_cache()
	return true
end

local function apply_huawei_network_mode(modem, mode)
	if mode ~= "auto" and mode ~= "lte" and mode ~= "nsa" and
	   mode ~= "nsa_only" and mode ~= "sa" and mode ~= "sa_only" then
		return false, "invalid network mode"
	end
	local current, syscfg, option = read_huawei_network_mode(modem)
	if current == mode and syscfg and option then
		return true
	end
	local commands = huawei_network_mode_commands(mode, syscfg)
	if not at_command_ok(query_serialized_at(modem, "AT+CFUN=0")) then
		return false, "failed to enter airplane mode"
	end
	if type(nixio.nanosleep) == "function" then nixio.nanosleep(2) end
	for _, command in ipairs(commands) do
		if not at_command_ok(query_serialized_at(modem, command)) then
			query_serialized_at(modem, "AT+CFUN=1")
			return false, "modem rejected network mode"
		end
	end
	if type(nixio.nanosleep) == "function" then nixio.nanosleep(1) end
	if not at_command_ok(query_serialized_at(modem, "AT+CFUN=1")) then
		return false, "network mode changed but modem stayed offline"
	end
	invalidate_radio_cache()
	return true
end

local function apply_generic_lock(modem, data)
	if type(data.band) == "table" then
		return false, "band lock is unsupported by this modem adapter"
	end
	local rows = type(data.earfcns) == "table" and data.earfcns or nil
	if tonumber(data.action) == 0 then
		rows = { { MODE = "LTE", enabled = "0" } }
	elseif not rows and type(data.earfcn) == "table" then
		rows = { data.earfcn }
	end
	if not rows or #rows == 0 then
		return false, "cell lock data is missing"
	end
	for _, row in ipairs(rows) do
		local mode = tostring(row.MODE or row.mode or ""):upper()
		local enabled = tostring(row.enabled or "1") ~= "0"
		local params = { rat = mode:find("NR", 1, true) and 1 or 0,
			pci = "", arfcn = "", band = "", scs = "" }
		if enabled then
			local message
			params.arfcn, message = strict_integer(row.EARFCN or row.earfcn,
				0, 3279165, "EARFCN")
			if not params.arfcn then return false, message end
			params.pci, message = strict_integer(row.PCI or row.pci, 0,
				params.rat == 1 and 1007 or 503, "PCI", true)
			if params.pci == nil then return false, message end
			params.band, message = strict_integer(row.BAND or row.band,
				1, 1024, "band")
			if not params.band then return false, message end
			params.scs = params.rat == 1 and nr_scs_for_band(params.band) or ""
		end
		local reply = safe_ubus("qmodem", "set_neighborcell", {
			config_section = modem.name, params = params
		})
		if type(reply) ~= "table" or not next(reply) then
			return false, "QModem cell lock failed"
		end
	end
	invalidate_radio_cache()
	return true
end

local function apply_earfcn(data)
	local modem = list_modems(true)[tonumber(data.index or 1) or 1]
	if not modem then
		return false, "modem is unavailable"
	end
	if fast_signal_supported(modem) then
		return apply_huawei_lock(modem, data)
	end
	return apply_generic_lock(modem, data)
end

local function apply_network_mode(data)
	local modem = list_modems(true)[tonumber(data.index or 1) or 1]
	if not modem then
		return false, "modem is unavailable"
	end
	if not fast_signal_supported(modem) then
		return false, "network mode is unsupported by this modem adapter"
	end
	return apply_huawei_network_mode(modem, tostring(data.mode or ""))
end

local function earfcn_lock_write(data)
	if data.band ~= nil or data.earfcn ~= nil or data.earfcns ~= nil then
		return true
	end
	local action = tonumber(data.action)
	return data.mode == nil and (action == 0 or action == 1)
end

local function earfcn_query_only(data)
	return not earfcn_lock_write(data) and data.mode == nil and
		data.adv == nil
end

local function query_fast_signal(modem)
	return parse_huawei_monsc(query_serialized_at(modem, "AT^MONSC"))
end

local function cached_fast_signal(modem, maximum_age)
	local key = type(modem) == "table" and tostring(modem.name or "") or ""
	if key == "" then
		return {}
	end
	local now = precise_time()
	local previous = fast_signal_cache[key]
	local previous_at = tonumber(fast_signal_cache_at[key]) or 0
	if not previous then
		previous, previous_at = shared_cache_read(
			"fast_" .. key, maximum_age, false)
		if previous then
			fast_signal_cache[key] = previous
			fast_signal_cache_at[key] = previous_at
		end
	end
	local age = now - previous_at
	if previous and age >= 0 and age < maximum_age then
		return previous
	end
	local last_failure = tonumber(fast_signal_failure_at[key]) or 0
	local failure_age = now - last_failure
	if last_failure > 0 and failure_age >= 0 and
	   failure_age < FAST_SIGNAL_FAILURE_BACKOFF then
		return previous or {}
	end
	local current = query_fast_signal(modem)
	if type(current) == "table" and next(current) then
		fast_signal_cache[key] = current
		fast_signal_cache_at[key] = now
		fast_signal_failure_at[key] = nil
		shared_cache_write("fast_" .. key, current)
		return current
	end
	fast_signal_failure_at[key] = now
	return previous or {}
end

local function append_carriers(target, source)
	for _, carrier in ipairs(source) do
		if #target >= MAX_APP_CARRIERS then
			break
		end
		target[#target + 1] = carrier
	end
end

local function hfreq_carriers_for_rat(response, wanted_rat)
	local carriers = {}
	for line in tostring(response or ""):gmatch(
		"%^HFREQINFO:%s*([^\r\n]+)") do
		local fields = split_csv(line)
		if numeric_field(fields[2]) == tostring(wanted_rat) then
			local offset = 3
			while offset + 6 <= #fields and
			      #carriers < MAX_APP_CARRIERS do
				local band = numeric_field(fields[offset])
				local dl_fcn = numeric_field(fields[offset + 1])
				local dlbw = numeric_field(fields[offset + 3])
				if band == "" or dl_fcn == "" or dlbw == "" then
					break
				end
				carriers[#carriers + 1] = {
					band = band,
					dl_fcn = dl_fcn,
					dlbw = dlbw,
					ul_fcn = numeric_field(fields[offset + 4]),
					ulbw = numeric_field(fields[offset + 6]),
					dl_mode = tostring(wanted_rat) == "7" and
						"NR" or "LTE"
				}
				offset = offset + 7
			end
		end
	end
	return carriers
end

local function parse_huawei_hfreqinfo(response, mode)
	local nr = hfreq_carriers_for_rat(response, 7)
	local lte = hfreq_carriers_for_rat(response, 6)
	local upper = tostring(mode or ""):upper()
	local carriers = {}
	if upper:find("NSA", 1, true) or upper:find("EN-DC", 1, true) then
		-- Match the factory API: NR component first, LTE anchor second.
		append_carriers(carriers, nr)
		append_carriers(carriers, lte)
	elseif upper:find("NR", 1, true) or upper:find("5G", 1, true) then
		append_carriers(carriers, nr)
	elseif upper:find("LTE", 1, true) then
		append_carriers(carriers, lte)
	elseif #nr > 0 then
		append_carriers(carriers, nr)
	else
		append_carriers(carriers, lte)
	end
	if #carriers == 0 then
		return nil
	end

	local result = { band_count = #carriers }
	for index, carrier in ipairs(carriers) do
		local suffix = index == 1 and "" or tostring(index - 1)
		result["band" .. suffix] = carrier.band
		result["dl_fcn" .. suffix] = carrier.dl_fcn
		result["ul_fcn" .. suffix] = carrier.ul_fcn
		result["dlbw" .. suffix] = carrier.dlbw
		result["ulbw" .. suffix] = carrier.ulbw
		result["DLBW" .. suffix] = carrier.dlbw
		result["ULBW" .. suffix] = carrier.ulbw
		result["dl_mode" .. suffix] = carrier.dl_mode
	end
	return result
end

local function query_carrier_topology(modem)
	local response = query_serialized_at(modem, "AT^HFREQINFO?")
	local status = type(modem) == "table" and modem.status or {}
	return parse_huawei_hfreqinfo(response, status.mode)
end

local function cached_carrier_topology(modem, maximum_age)
	local key = type(modem) == "table" and tostring(modem.name or "") or ""
	if key == "" then
		return {}
	end
	local now = precise_time()
	local previous = carrier_cache[key]
	local previous_at = tonumber(carrier_cache_at[key]) or 0
	if not previous then
		previous, previous_at = shared_cache_read(
			"carrier_" .. key, maximum_age, false)
		if previous then
			carrier_cache[key] = previous
			carrier_cache_at[key] = previous_at
		end
	end
	local age = now - previous_at
	if previous and age >= 0 and age < maximum_age then
		return previous
	end
	local last_failure = tonumber(carrier_failure_at[key]) or 0
	local failure_age = now - last_failure
	if last_failure > 0 and failure_age >= 0 and
	   failure_age < FAST_SIGNAL_FAILURE_BACKOFF then
		return previous or {}
	end
	local current = query_carrier_topology(modem)
	if type(current) == "table" and next(current) then
		carrier_cache[key] = current
		carrier_cache_at[key] = now
		carrier_failure_at[key] = nil
		shared_cache_write("carrier_" .. key, current)
		return current
	end
	carrier_failure_at[key] = now
	return previous or {}
end

local function apply_carrier_topology(status, topology)
	if type(topology) ~= "table" or not next(topology) then
		return status
	end
	for carrier = 1, MAX_APP_CARRIERS - 1 do
		local suffix = tostring(carrier)
		for _, prefix in ipairs({ "band", "dl_fcn", "ul_fcn", "dlbw",
			"ulbw", "DLBW", "ULBW", "dl_mode", "dl_pci" }) do
			status[prefix .. suffix] = nil
		end
	end
	for key, value in pairs(topology) do
		status[key] = value
	end
	return status
end

local function current_signal_status(modem, maximum_age)
	local original = type(modem) == "table" and modem.status or {}
	local status = {}
	for key, value in pairs(type(original) == "table" and original or {}) do
		status[key] = value
	end
	local current = cached_fast_signal(modem, maximum_age)
	for _, key in ipairs({ "band", "cell", "earfcn", "pci", "rsrp",
		"rsrq", "sinr", "tac" }) do
		if current[key] ~= nil and tostring(current[key]) ~= "" then
			status[key] = current[key]
		end
	end
	if current.cell ~= nil and tostring(current.cell) ~= "" then
		status.cellid = current.cell
	end
	local signal = tonumber(status.rsrp) or tonumber(status.rssi)
	if signal then
		status.signal = signal
		status.signalStrength = tostring(signal)
	end
	return status
end

local function app_at_signal(modems, index, maximum_age)
	local modem = type(modems) == "table" and
		modems[tonumber(index or 1) or 1] or nil
	local status = current_signal_status(modem, maximum_age)
	local key = type(modem) == "table" and tostring(modem.name or "") or ""
	-- Measurement mode stays a one-command fast path.  Reuse, but do not
	-- refresh, the last verified HFREQINFO topology so its primary band agrees
	-- with the normal CA view without adding another AT command per sample.
	local topology = carrier_cache[key]
	if not topology then
		topology = shared_cache_read("carrier_" .. key,
			DEFAULT_SIGNAL_CARRIER_INTERVAL * 6, false)
	end
	apply_carrier_topology(status, topology or {})
	return {
		band = tostring(status.band or ""),
		cell = tostring(status.cell or status.cellid or ""),
		earfcn = tostring(status.earfcn or status.dl_fcn or ""),
		pci = tostring(status.pci or ""),
		rsrp = tostring(status.rsrp or ""),
		rsrq = tostring(status.rsrq or ""),
		sinr = tostring(status.sinr or ""),
		tac = tostring(status.tac or "")
	}
end

local function sim_switch(data)
	local requested = data.sim or data.slot or data.index
	if type(data.cur) == "table" then
		requested = data.cur[1]
	elseif data.cur ~= nil then
		requested = data.cur
	end
	local raw = tostring(requested or "")
	local slot
	if raw == "1" or raw == "external1" then
		slot = "external1"
	elseif raw == "2" or raw == "external2" then
		slot = "external2"
	elseif raw == "3" or raw == "internal" then
		slot = "internal"
	else
		return false, "invalid sim slot"
	end
	local rv = safe_ubus("c2000max", "sim_switch", { slot = slot })
	if type(rv) == "table" and next(rv) then
		selector_cache = rv
		selector_cache_at = os.time()
		invalidate_radio_cache()
		-- invalidate_radio_cache also clears the selector cache.  Keep the
		-- serialized worker's authoritative post-switch result in memory while
		-- forcing every cross-process reader to refresh its shared snapshot.
		selector_cache = rv
		selector_cache_at = os.time()
	end
	return rv.success == true or rv.success == 1, rv.message, rv
end

local function sms_capabilities(value, requested_type)
	local capabilities = type(value) == "table" and
		value.sms_capabilities or nil
	if type(capabilities) ~= "table" and type(value) == "table" and
	   type(value.result) == "table" then
		capabilities = value.result.sms_capabilities
	end
	capabilities = type(capabilities) == "table" and capabilities or {}
	local kind = tostring(requested_type or capabilities.mem1 or "ME")
	local selected = type(capabilities[kind]) == "table" and
		capabilities[kind] or capabilities.ME or capabilities.SM or {}
	return kind, selected
end

local function sms_raw_messages(value)
	if type(value) ~= "table" then return {} end
	if type(value.msg) == "table" then return value.msg end
	if type(value.result) == "table" then
		return sms_raw_messages(value.result)
	end
	return {}
end

local function normalize_sms_read(value, requested_type)
	local official = type(value) == "table" and value.smslist and value or
		(type(value) == "table" and type(value.result) == "table" and
		 value.result.smslist and value.result or nil)
	if official then
		official.code = tonumber(official.code or 0) or 0
		official.ready = tonumber(official.ready or 1) or 1
		if type(official.smslist) ~= "table" or #official.smslist == 0 then
			official.smslist = { {} }
		end
		return official
	end

	local groups, order, flat, count = {}, {}, {}, 0
	for _, message in ipairs(sms_raw_messages(value)) do
		if type(message) == "table" then
			local contact = tostring(message.contact or message.sender or "")
			if contact ~= "" then
				if not groups[contact] then
					groups[contact] = { contact = contact, undeal = 0, list = {} }
					order[#order + 1] = contact
				end
				local part = tonumber(message.part or message.segment or 0) or 0
				local item = {
					index = tonumber(message.index) or tostring(message.index or ""),
					multi_sms_index = part,
					timestamp = tonumber(message.timestamp) or 0,
					content = tostring(message.content or message.msg or ""),
					stat = tonumber(message.stat or 1) or 1,
					role = tonumber(message.role or 0) or 0
				}
				if message.reference ~= nil then item.reference = message.reference end
				if message.total ~= nil then item.total = message.total end
				groups[contact].list[#groups[contact].list + 1] = item
				local new_item = {}
				for key, field in pairs(item) do new_item[key] = field end
				new_item.contact = contact
				flat[#flat + 1] = new_item
				count = count + 1
			end
		end
	end
	for _, contact in ipairs(order) do
		table.sort(groups[contact].list, function(left, right)
			return tonumber(left.timestamp or 0) < tonumber(right.timestamp or 0)
		end)
	end
	table.sort(order, function(left, right)
		local l = groups[left].list[#groups[left].list] or {}
		local r = groups[right].list[#groups[right].list] or {}
		return tonumber(l.timestamp or 0) > tonumber(r.timestamp or 0)
	end)
	local smslist = {}
	if tostring(requested_type or "") == "new" then
		table.sort(flat, function(left, right)
			return tonumber(left.timestamp or 0) > tonumber(right.timestamp or 0)
		end)
		smslist = flat
	else
		for _, contact in ipairs(order) do
			smslist[#smslist + 1] = groups[contact]
		end
	end
	if #smslist == 0 then smslist[1] = {} end
	local kind, capabilities = sms_capabilities(value, requested_type)
	return {
		code = 0,
		total = tonumber(capabilities.total) or count,
		count = count,
		used = tonumber(capabilities.used) or count,
		smslist = smslist,
		type = kind,
		ready = 1
	}
end

local function sms_ids(data)
	local raw = data.ids or data.index
	local result = {}
	if type(raw) == "table" then
		for _, id in ipairs(raw) do result[#result + 1] = tostring(id) end
	else
		for id in tostring(raw or ""):gmatch("[^,%s]+") do
			result[#result + 1] = id
		end
	end
	if #result == 0 then return nil end
	for _, id in ipairs(result) do
		if not id:match("^%d+$") then return nil end
	end
	return result
end

local function qmodem_sms_success(value)
	if type(value) ~= "table" or value.error ~= nil then return false end
	local source = type(value.result) == "table" and value.result or value
	return tostring(source.status or "0") == "1"
end

local function do_sms(data)
	local raw, section
	if data.action == "read" then
		raw, section = modem_call("get_sms")
		if not section or type(raw) ~= "table" or raw.error ~= nil then
			return nil, nil, "sms read failed"
		end
		return { code = 0, result = normalize_sms_read(raw, data.type) }, section
	elseif data.action == "del" then
		local ids = sms_ids(data)
		if not ids then return nil, nil, "invalid sms id" end
		raw, section = modem_call("delete_sms", {
			index = table.concat(ids, " ")
		})
		if not section then return nil, nil, "modem not found" end
		local success = qmodem_sms_success(raw)
		local deleted = {}
		for _, id in ipairs(ids) do
			deleted[#deleted + 1] = {
				index = tonumber(id) or id,
				code = success and 0 or 1
			}
		end
		return { code = success and 0 or 1, smsdel = deleted }, section
	elseif data.action == "send" then
		local phone = data.phone_num or data.phone_number
		local message = data.msg or data.message_content
		if type(phone) ~= "string" or not phone:match("^%+?[%d*#]+$") or
		   #phone > 32 or not valid_text(message, 2048, false) then
			return nil, nil, "invalid sms"
		end
		raw, section = modem_call("send_sms", {
			params = {
				phone_number = phone,
				message_content = message
			}
		})
		if not section then return nil, nil, "modem not found" end
		local success = qmodem_sms_success(raw)
		return {
			code = success and 0 or -1,
			item = { {
				code = success and 0 or -1,
				index = "",
				timestamp = os.time()
			} }
		}, section
	end
	return nil, nil, "invalid sms action"
end

local function basic_status()
	return {
		uptime = sys.uptime(),
		lan = safe_ubus("network.interface.lan", "status", {}),
		wan = safe_ubus("network.interface.c2000_wan", "status", {}),
		port = safe_ubus("c2000max", "port_status", {}),
		sim = sim_status()
	}
end

function M.prewarm()
	local modems = list_modems()
	local refresh = M.signal_refresh_policy()
	for _, modem in ipairs(modems) do
		current_signal_status(modem, refresh.normal)
		cached_carrier_topology(modem, refresh.carrier)
	end
	return {
		modems = #modems,
		updated = os.time()
	}
end

function M.handle(action, data, context)
	data = type(data) == "table" and data or {}
	context = type(context) == "table" and context or {}
	local rv = response(data)

	if action == "heartbeat" then
		return rv
	elseif action == "signal" then
		local focused = tonumber(data.at_signal or 0) == 1
		local cellular
		if focused and modem_cache and #modem_cache > 0 then
			cellular = modem_cache
		else
			cellular = list_modems()
		end
		local refresh = M.signal_refresh_policy()
		if focused then
			rv.at_signal = app_at_signal(cellular, data.index, refresh.test)
			return rv
		end
		rv.signal = {}
		for index, modem in ipairs(cellular) do
			local status = {}
			local current = current_signal_status(modem, refresh.normal)
			apply_carrier_topology(current,
				cached_carrier_topology(modem, refresh.carrier))
			for key, value in pairs(current) do
				status[key] = value
			end
			status.using = index == 1
			status.cpeno = index
			rv.signal[index] = status
		end
		if #rv.signal == 0 then
			rv.signal[1] = {}
		end
		return rv
	elseif action == "info" then
		local modems = list_modems()
		local allow_signal = bool_option("local_signal_enable")
		local allow_wifi = bool_option("local_wifi_enable")
		local allow_clients = bool_option("local_client_enable")
		local selector = modems[1] and modems[1].selector or sim_status()
		local selection = sim_selection(selector)
		local active = {}
		for index, modem in ipairs(modems) do
			if type(modem.status) == "table" and
			   tonumber(modem.status.netlink or 0) == 1 then
				active[#active + 1] = index
			end
		end
		if #active == 0 and #modems > 0 then
			active[1] = 1
		end
		rv.result = {
			basic = {
				version = APP_SOFTWARE_VERSION,
				mac = M.device_id(),
				name = "C2000-MAX",
				modem_cnt = #modems,
				active_modem = active
			},
			runtime = basic_status(),
			wifi = allow_wifi and list_wifi() or {},
			cellular = allow_signal and app_cellular(modems) or {},
			client = allow_clients and list_clients() or {},
			cpesel = { selection },
			cpecfg = app_cpecfg(),
			apn = {},
			bat = { percent = "-1", charging = false },
			diagnosis = allow_signal and app_diagnosis(modems) or {},
			auth_on = 0
		}
		return rv
	elseif action == "wifi" then
		if data.list ~= nil then
			local ok, message = apply_wifi(data.list)
			if not ok then
				rv.code = "2"
				rv.message = message
				return rv
			end
		end
		rv.result = { list = list_wifi() }
		return rv
	elseif action == "client" then
		local mac, allowed, requested = device_internet_request(data)
		local control
		if requested then
			control = M.set_device_internet(mac, allowed)
			if tostring(control.code or control.errcode or "2") ~= "0" then
				rv.code = tostring(control.code or control.errcode or "2")
				rv.message = control.message or "device internet control failed"
				return rv
			end
		end
		rv.result = { client = list_clients() }
		if control then
			rv.result.control = control
			rv.mac = control.mac
			rv.switch = control.switch
			rv.switch_off = control.switch_off
		end
		return rv
	elseif action == "cpesel" then
		local fresh_selector = sim_status(true)
		if type(fresh_selector) ~= "table" or not next(fresh_selector) then
			rv.code = "2"
			rv.message = "SIM selector status unavailable"
			return rv
		end
		local before = sim_selection(fresh_selector)
		local requested_mode
		if data.mode ~= nil then
			requested_mode = normalize_sim_mode(data.mode)
			if requested_mode == nil then
				rv.code = "2"
				rv.message = "invalid sim mode"
				return rv
			end
		end
		local requested = data.sim or data.slot
		if type(data.cur) == "table" then
			requested = data.cur[1]
		elseif data.cur ~= nil then
			requested = data.cur
		end
		local switch_result
		if requested ~= nil and slot_number(requested) ~= before.cur then
			local ok, message, result = sim_switch(data)
			if not ok then
				rv.code = "2"
				rv.message = message or "sim switch failed"
				return rv
			end
			switch_result = result
		end
		if requested_mode ~= nil and not persist_sim_mode(requested_mode) then
			rv.code = "2"
			rv.message = "failed to save sim mode"
			return rv
		end
		local current = switch_result and sim_selection(switch_result) or before
		if requested_mode ~= nil then
			current.mode = requested_mode
		end
		rv.result = { cpesel = {
			{
				cur = current.cur,
				mode = current.mode,
				default = current.default,
				gval = current.gval
			}
		} }
		return rv
	elseif action == "neighbour" then
		rv.result = app_neighbour()
		return rv
	elseif action == "sms" then
		if data.action == nil then
			rv.code = 0
			rv.result = {
				index = tostring(data.index or "1"),
				sim = tonumber(data.sim) or sim_selection().cur,
				enabled = "0"
			}
			return rv
		elseif data.action == "modify" then
			rv.code = "3"
			rv.message = "IMS switch is not supported by QModem"
			return rv
		end
		local result, _, message = do_sms(data)
		if not result then
			rv.code = -4
			rv.message = message or "sms failed"
			return rv
		end
		for key, value in pairs(result) do
			rv[key] = value
		end
		return rv
	elseif action == "apn" then
		if data.action == "modify" or data.apn ~= nil or data.name ~= nil then
			local ok, message = apply_apn(data)
			if not ok then
				rv.code = "2"
				rv.message = message
				return rv
			end
		end
		rv.result = apn_info()
		return rv
	elseif action == "lan" then
		if not valid_ipv4(data.ip) then
			rv.code = "2"
			rv.message = "invalid lan address"
			return rv
		end
		uci:set("network", "lan", "ipaddr", data.ip)
		if not uci:commit("network") then
			uci:revert("network")
			rv.code = "2"
			rv.message = "network commit failed"
			return rv
		end
		util.exec("(sleep 1; ubus call network reload >/dev/null 2>&1) &")
		return rv
	elseif action == "status" then
		rv.result = basic_status()
		return rv
	elseif action == "speed" then
		rv.result = interface_stats(tostring(data.name or "br-lan"))
		return rv
	elseif action == "password" then
		if not bool_option("password_enable") then
			rv.code = "3"
			rv.message = "password operation disabled"
			return rv
		end
		if not valid_text(data.password, 128, false) then
			rv.code = "3"
			rv.message = "invalid password"
			return rv
		end
		rv.code = sys.user.setpasswd("root", data.password) == 0 and "0" or "3"
		return rv
	elseif action == "cmd" then
		if data.cmd == "service" then
			if data.name ~= "cellular_record" then
				rv.code = 3
				rv.message = "service is not allowed"
				return rv
			end
			if data.enabled ~= nil then
				local enabled = tonumber(data.enabled)
				if enabled ~= 0 and enabled ~= 1 then
					rv.code = 3
					rv.message = "invalid service state"
					return rv
				end
				uci:set("c2000max_app", "main", "cellular_record_enable",
					tostring(enabled))
				if not uci:commit("c2000max_app") then
					uci:revert("c2000max_app")
					rv.code = 3
					rv.message = "service state commit failed"
					return rv
				end
			end
			rv.code = 0
			rv.name = "cellular_record"
			rv.enabled = bool_option("cellular_record_enable") and 1 or 0
			return rv
		elseif data.cmd ~= "reboot" or not bool_option("reboot_enable") then
			rv.code = "3"
			rv.message = "operation disabled"
			return rv
		end
		util.exec("(sleep 2; reboot) >/dev/null 2>&1 &")
		return rv
	elseif action == "combo" or action == "sync" then
		rv.result = {
			runtime = basic_status(),
			cellular = bool_option("local_signal_enable") and
				list_modems() or {},
			sim = sim_status()
		}
		return rv
	elseif action == "earfcn" then
		if data.mode ~= nil then
			local ok, message = apply_network_mode(data)
			if not ok then
				rv.code = "2"
				rv.message = message or "network mode failed"
				return rv
			end
		end
		if earfcn_lock_write(data) then
			local ok, message = apply_earfcn(data)
			if not ok then
				rv.code = "2"
				rv.message = message or "cell lock failed"
				return rv
			end
		end
		rv.result = app_earfcn(data)
		return rv
	elseif action == "wifiauth" then
		rv.code = nil
		if not fs.access("/usr/sbin/terminal_trackd") then
			rv.wifiauth = -1
			return rv
		end
		if data.wifiauth ~= nil then
			local value = tonumber(data.wifiauth)
			if value ~= 0 and value ~= 1 then
				rv.wifiauth = -1
				return rv
			end
			uci:set("luci", "main", "portal", tostring(value))
			uci:commit("luci")
		end
		rv.wifiauth = tonumber(uci:get("luci", "main", "portal") or "0") or 0
		return rv
	end

	return unsupported(data)
end

function M.local_enabled()
	return bool_option("local_enable")
end

function M.remote_enabled()
	return bool_option("remote_enable")
end

local function local_denied()
	return false, "本地 APP 功能未在“系统 → APP 支持”中启用"
end

local function local_permission(name)
	if bool_option(name) then
		return true
	end
	return local_denied()
end

function M.local_action_allowed(action, data)
	data = type(data) == "table" and data or {}

	if action == "heartbeat" then
		return true
	elseif action == "info" or action == "status" or
	       action == "combo" or action == "sync" then
		return local_permission("local_device_enable")
	elseif action == "signal" or action == "neighbour" then
		return local_permission("local_signal_enable")
	elseif action == "earfcn" then
		if not bool_option("local_signal_enable") then
			return local_denied()
		end
		if not earfcn_query_only(data) and
		   not bool_option("local_network_write_enable") then
			return local_denied()
		end
		return true
	elseif action == "client" then
		local _, _, requested = device_internet_request(data)
		if requested and not bool_option("local_network_write_enable") then
			return local_denied()
		end
		return local_permission("local_client_enable")
	elseif action == "speed" then
		return local_permission("local_traffic_enable")
	elseif action == "sms" then
		return local_permission("local_sms_enable")
	elseif action == "wifi" then
		if not bool_option("local_wifi_enable") then
			return local_denied()
		end
		if data.list ~= nil and
		   not bool_option("local_network_write_enable") then
			return local_denied()
		end
		return true
	elseif action == "apn" then
		local write = data.action == "modify" or data.apn ~= nil or
			data.name ~= nil
		if write then
			return local_permission("local_network_write_enable")
		end
		return local_permission("local_device_enable")
	elseif action == "lan" then
		return local_permission("local_network_write_enable")
	elseif action == "cpesel" then
		local write = data.sim ~= nil or data.slot ~= nil or
			data.cur ~= nil or data.mode ~= nil
		if write then
			return local_permission("local_sim_switch_enable")
		end
		return local_permission("local_device_enable")
	elseif action == "wifiauth" then
		if data.wifiauth ~= nil then
			return local_permission("local_network_write_enable")
		end
		return local_permission("local_wifi_enable")
	elseif action == "password" then
		return local_permission("password_enable")
	elseif action == "cmd" then
		if data.cmd == "reboot" then
			return local_permission("reboot_enable")
		elseif data.cmd == "service" and
		       data.name == "cellular_record" then
			return local_permission("local_cellular_record_enable")
		end
	end
	return local_denied()
end

function M.feature_enabled(name)
	if type(name) ~= "string" or
	   not name:match("^[a-z][a-z0-9_]*_enable$") then
		return false
	end
	if name == "upgrade_enable" then
		return false
	end
	return bool_option(name)
end

function M.encode(value)
	return json.stringify(value)
end

function M.decode(value)
	local ok, result = pcall(json.parse, value or "")
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

return M
