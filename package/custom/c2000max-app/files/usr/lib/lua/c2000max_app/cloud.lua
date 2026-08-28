local fs = require "nixio.fs"
local nixio = require "nixio"
local json = require "luci.jsonc"
local sys = require "luci.sys"
local util = require "luci.util"
local uci = require("luci.model.uci").cursor()
local core = require "c2000max_app.core"
local identity = require "c2000max_app.identity"
local rweb = require "c2000max_app.rweb"

local M = {}
local STATE_DIR = "/var/run/c2000max-app"
local DOWNLOAD_DIR = "/tmp/c2000max-app-downloads"
local MAX_OUTPUT = 65536

local function response_timestamp()
	-- Factory cloudd.lua uses tostring(socket.gettime()) for requests and
	-- replies.  Keep this distinct from report_proactively, whose `uniq`
	-- really is a numeric epoch second.
	if type(nixio.gettimeofday) == "function" then
		local ok, seconds, microseconds = pcall(nixio.gettimeofday)
		seconds = ok and tonumber(seconds) or nil
		microseconds = ok and tonumber(microseconds) or nil
		if seconds then
			local value = string.format("%d.%06d", math.floor(seconds),
				math.floor(microseconds or 0))
			value = value:gsub("0+$", "")
			return value:sub(-1) == "." and (value .. "0") or value
		end
	end
	return tostring(math.floor(tonumber(os.time()) or 0)) .. ".000001"
end

local function presence_timestamp()
	return math.floor(tonumber(os.time()) or 0)
end

local function code(result)
	return type(result) == "table" and tostring(result.code or "2") or "2"
end

local function disabled(feature)
	return {
		code = "3",
		errcode = "3",
		message = feature .. " disabled"
	}
end

local function read_limited(path, maximum)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local data = file:read(maximum + 1)
	file:close()
	if not data then
		return nil
	end
	if #data > maximum then
		return data:sub(1, maximum) .. "\n[output truncated]"
	end
	return data
end

local function safe_ubus(object, method, args)
	if type(object) ~= "string" or type(method) ~= "string" or
	   not object:match("^[A-Za-z0-9_.%-]+$") or
	   not method:match("^[A-Za-z0-9_.%-]+$") then
		return nil
	end
	local ok, result = pcall(util.ubus, object, method,
		type(args) == "table" and args or {})
	return ok and type(result) == "table" and result or nil
end

local function valid_url(value)
	return type(value) == "string" and #value <= 2048 and
		value:match("^https?://") and not value:find("[%z\r\n]")
end

local function download(url, path)
	if not valid_url(url) then
		return false, "invalid url"
	end
	fs.mkdirr(DOWNLOAD_DIR)
	local command
	if fs.access("/bin/uclient-fetch") then
		command = "/bin/uclient-fetch -q -T 60 -O " ..
			util.shellquote(path) .. " " .. util.shellquote(url)
	else
		command = "/usr/bin/wget -q -T 60 -O " ..
			util.shellquote(path) .. " " .. util.shellquote(url)
	end
	if sys.call(command) ~= 0 or not fs.stat(path) then
		fs.unlink(path)
		return false, "download failed"
	end
	return true
end

local function checksum(path, algorithm)
	local binary = algorithm == "sha256" and "sha256sum" or "md5sum"
	local output = util.exec(binary .. " " .. util.shellquote(path) ..
		" 2>/dev/null") or ""
	return output:match("^([0-9A-Fa-f]+)")
end

local function verify_checksum(path, payload)
	local expected = payload.sha256
	local algorithm = "sha256"
	if expected == nil or expected == "" then
		expected = payload.md5
		algorithm = "md5"
	end
	if expected == nil or expected == "" then
		return false, "checksum required"
	end
	if type(expected) ~= "string" or
	   not expected:match("^[0-9A-Fa-f]+$") or
	   #expected ~= (algorithm == "sha256" and 64 or 32) then
		return false, "invalid checksum"
	end
	local actual = checksum(path, algorithm)
	if not actual or actual:lower() ~= expected:lower() then
		return false, "checksum mismatch"
	end
	return true, actual:lower()
end

local function execute(command, timeout)
	if type(command) ~= "string" or command == "" or #command > 4096 or
	   command:find("%z") then
		return 2, "invalid command"
	end
	timeout = tonumber(timeout) or 30
	if timeout < 5 then
		timeout = 5
	elseif timeout > 90 then
		timeout = 90
	end
	fs.mkdirr(STATE_DIR)
	local nonce = sys.uniqueid(8)
	if not nonce then
		return 2, "temporary file error"
	end
	local output_file = STATE_DIR .. "/command-" .. nonce .. ".log"
	local timeout_binary = fs.access("/usr/bin/timeout") and
		"/usr/bin/timeout" or "/bin/timeout"
	local shell = timeout_binary .. " " .. tostring(math.floor(timeout)) ..
		" /bin/sh -c " ..
		util.shellquote(command) ..
		" >" .. util.shellquote(output_file) .. " 2>&1"
	local result = sys.call(shell)
	local output = read_limited(output_file, MAX_OUTPUT) or ""
	fs.unlink(output_file)
	return result, output
end

local function trim_line(value)
	if type(value) ~= "string" then
		return nil
	end
	value = value:match("^%s*(.-)%s*$")
	return value ~= "" and value or nil
end

local function ipv4_address(status)
	if type(status) ~= "table" then
		return nil
	end
	local addresses = status["ipv4-address"]
	if type(addresses) == "table" and type(addresses[1]) == "table" then
		return trim_line(addresses[1].address)
	end
	return nil
end

local function traffic_status()
	-- The factory traffic reply is Wi-Fi-band traffic, not arbitrary LAN/WAN
	-- interface counters. Keep the exact envelope even when this clean-room
	-- build cannot attribute hardware-offloaded bytes to a radio reliably.
	return {
		id = core.device_id() or "",
		traffic = {
			txbytes2 = 0,
			rxbytes2 = 0,
			txbytes5 = 0,
			rxbytes5 = 0
		}
	}
end

local function terminal_status()
	local result = core.handle("client", {})
	return {
		client = result.result and result.result.client or { {} },
		auth_on = 0
	}
end

local function station_status()
	if type(core.station_status) == "function" then
		local result = core.station_status()
		if type(result) == "table" then return result end
	end
	return { list = { "" }, deny = { "" } }
end

local function remote_sms(payload)
	local result = core.handle("sms", payload)
	local value = { code = tonumber(result.code) or -4 }
	if payload.serial_num ~= nil then value.serial_num = payload.serial_num end
	if payload.action == "read" then
		value.result = type(result.result) == "table" and result.result or {
			code = -4, smslist = { {} }, ready = 1
		}
	elseif payload.action == "del" then
		value.smsdel = type(result.smsdel) == "table" and result.smsdel or {}
	elseif payload.action == "send" then
		value.item = type(result.item) == "table" and result.item or {}
	else
		value.result = type(result.result) == "table" and result.result or {}
	end
	return value
end

local function split_values(value)
	local result = {}
	for item in tostring(value or ""):gmatch("[^,]+") do
		result[#result + 1] = item:match("^%s*(.-)%s*$")
	end
	return result
end

local function remote_sim_slot_by_iccid(iccid)
	if type(core.modems) == "function" then
		for _, modem in ipairs(core.modems(true) or {}) do
			local status = type(modem.status) == "table" and modem.status or {}
			if tostring(status.iccid or "") == iccid then
				if tostring(status.simtype or "") == "4" then return 3 end
				local index = tonumber(status.simno)
				if tostring(status.simtype or "") == "0" and index then
					return index
				end
			end
		end
	end
	local iccids = split_values(uci:get("oem", "board", "iccid") or "")
	local types = split_values(uci:get("cpesel", "sim", "stype") or
		"0,0,4")
	local wanted
	for index, value in ipairs(iccids) do
		if value == iccid then wanted = index break end
	end
	if not wanted then return nil end
	local embedded = 0
	for slot, value in ipairs(types) do
		if tostring(value) ~= "0" then
			embedded = embedded + 1
			if embedded == wanted then return slot end
		end
	end
	return nil
end

local function normalize_remote_sim_mode(value)
	if value == nil then return nil, true end
	local mode = tonumber(value)
	if mode == 0 or mode == 1 then return mode, true end
	return nil, false
end

local function schedule_remote_sim_switch(slot, mode)
	if not fs.access("/usr/sbin/c2000max-app-sim-switch") then
		return nil
	end
	local names = {
		[1] = "external1", [2] = "external2", [3] = "internal"
	}
	local name = names[tonumber(slot)]
	if not name then return false end
	-- Slot names come exclusively from the fixed table above.  The helper
	-- obtains the board service lock and records the eventual hardware result.
	-- The optional mode is validated above and persisted only after success.
	local mode_argument = mode == nil and "" or (" " .. tostring(mode))
	return sys.call("/usr/sbin/c2000max-app-sim-switch " .. name ..
		mode_argument ..
		" >/dev/null 2>&1 &") == 0
end

local function remote_sim_switch(payload)
	local request = type(payload.simswitch) == "table" and
		payload.simswitch or nil
	if not request then return { errcode = "3" } end
	local requested_mode, mode_valid = normalize_remote_sim_mode(request.mode)
	if not mode_valid then return { errcode = "3" } end
	local sim_type = tonumber(request.type)
	local slot, failure_code
	if sim_type == 0 then
		if request.index == nil then return { errcode = "3" } end
		slot = tonumber(request.index)
		if slot ~= 1 and slot ~= 2 then return { errcode = "1" } end
		failure_code = "1"
	elseif sim_type == 1 then
		local iccid = tostring(request.iccid or "")
		if iccid == "" then return { errcode = "3" } end
		slot = remote_sim_slot_by_iccid(iccid)
		if not slot then return { errcode = "2" } end
		failure_code = "2"
	elseif sim_type == 4 then
		if request.index == nil then return { errcode = "3" } end
		if tonumber(request.index) ~= 1 then return { errcode = "1" } end
		slot = 3
		failure_code = "1"
	else
		-- Factory firmware treats unknown types as a mode-only request.
		if requested_mode == nil then return { errcode = "0" } end
		local result = core.handle("cpesel", { mode = { requested_mode } })
		return { errcode = code(result) == "0" and "0" or "3" }
	end
	local scheduled = schedule_remote_sim_switch(slot, requested_mode)
	if scheduled ~= nil then
		return { errcode = scheduled and "0" or failure_code }
	end
	local data = { cur = { slot } }
	if requested_mode ~= nil then
		data.mode = { requested_mode }
	end
	local result = core.handle("cpesel", data)
	return { errcode = code(result) == "0" and "0" or failure_code }
end

local function signal_status()
	local result = core.handle("signal", {})
	return {
		id = core.device_id() or "",
		errcode = code(result) == "0" and "0" or code(result),
		result = result.signal or { {} }
	}
end

local function cpe_status()
	local result = core.handle("signal", {})
	local list = {}
	for index, item in ipairs(type(result.signal) == "table" and
	    result.signal or {}) do
		if type(item) == "table" then
			local value = {}
			for key, field in pairs(item) do
				value[key] = field
			end
			value.cpeno = value.cpeno or index
			list[#list + 1] = value
		end
	end
	if #list == 0 then
		list[1] = ""
	end
	return { list = list }
end

local function cpe_selection(info)
	local selection = {}
	local iccid = {}
	local simid = {}
	local source = type(info.cpesel) == "table" and info.cpesel or {}
	for index, item in ipairs(source) do
		if type(item) == "table" then
			local card_value = type(item.iccid) == "table" and
				item.iccid[1] or item.iccid
			local card = trim_line(card_value) or ""
			selection[#selection + 1] = {
				mode = tostring(item.mode or "1"),
				cur = tostring(item.cur or item.current_slot or "1"),
				iccid = card
			}
			iccid[#iccid + 1] = { card }
			simid[#simid + 1] = { tostring(item.simid or "") }
		end
	end
	if #selection == 0 then
		selection[1] = {}
	end
	if #iccid == 0 then
		iccid[1] = { "" }
	end
	if #simid == 0 then
		simid[1] = { "" }
	end
	return selection, iccid, simid
end

local function radio_status(info)
	local radio = {}
	local count = {
		band2 = 0,
		band5 = 0,
		phy2 = 0,
		phy5 = 0,
		chlist = {},
		skip_channels = {},
		bwlist = {}
	}
	for index, item in ipairs(type(info.wifi) == "table" and
	    info.wifi or {}) do
		if type(item) == "table" then
			local band5 = index > 1 or
				tostring(item.ssid or ""):match("5G") ~= nil
			if band5 then
				count.band5 = count.band5 + 1
				count.phy5 = count.phy5 + 1
			else
				count.band2 = count.band2 + 1
				count.phy2 = count.phy2 + 1
			end
			radio[#radio + 1] = {
				name = item.rule_name or ("wlan" .. tostring(index - 1)),
				ssid = item.ssid or "",
				channel = item.channel or "auto",
				frequency = band5 and "5G" or "2.4G",
				assoclist = {}
			}
		end
	end
	return radio, count
end

local function device_status(payload)
	-- `/usr/lib/cloudd/status` in factory 2.2.5 replies with
	-- cloudd_get_status(), not the generic interface status object. The
	-- vendor registry uses this envelope to populate/refresh its device row.
	local result = core.handle("info", { type = "all" })
	local info = type(result.result) == "table" and result.result or {}
	local board_options = uci:get_all("oem", "board") or {}
	local current_identity = identity.get()
	local device_id = core.device_id() or ""
	local selection, iccid, simid = cpe_selection(info)
	local system = nixio.sysinfo() or {}
	local model = trim_line(board_options.pname) or
		trim_line(board_options.name) or "C2000-MAX"
	local value = {
		sversion = core.software_version(),
		iccid = iccid,
		simid = simid,
		cpesel = selection,
		-- `/etc/ptype.d/name` in the factory image defaults this to `rt`.
		-- It is a role identifier, not the marketing model name.
		ptype = trim_line(board_options.ptype) or "rt",
		vendor = trim_line(board_options.vendor) or "nradio",
		board = trim_line(board_options.name) or "C2000-MAX",
		name = model,
		-- Factory support_wifiauth() returns -1 when terminal_trackd is
		-- unavailable, and Lua still treats that value as present/truthy.
		wifiauth = tonumber(board_options.wifiauth) or -1,
		wired_client = {
			count = type(info.client) == "table" and #info.client or 0,
			client = type(info.client) == "table" and info.client or {}
		},
		uptime = math.floor(tonumber(system.uptime or sys.uptime() or 0) or 0)
	}
	if current_identity.device_code then
		value.device_code = current_identity.device_code
	end
	if payload and tostring(payload.brief or "") == "1" then
		return value
	end

	value.id = device_id
	value.oid = device_id
	value.ifinfo = {}
	local runtime = type(info.runtime) == "table" and info.runtime or {}
	value.ipaddr = ipv4_address(runtime.wan) or
		ipv4_address(runtime.lan) or ""
	value.radio, value.radiocnt = radio_status(info)
	value.client = {}
	return value
end

local function internet_status()
	local result = core.handle("status", {})
	local status = type(result.result) == "table" and result.result or {}
	local wan = type(status.wan) == "table" and status.wan or {}
	local value = {
		mode = tostring(wan.proto or ""),
		time = tonumber(wan.uptime or -1) or -1
	}
	local address = ipv4_address(wan)
	if address then
		value.ip = address
	end
	return value
end

local function battery_status()
	return {
		percent = "-1",
		charging = false
	}
end

local function runtime_status()
	local info_result = core.handle("info", { type = "all" })
	local status_result = core.handle("status", {})
	local info = type(info_result.result) == "table" and
		info_result.result or {}
	local status = type(status_result.result) == "table" and
		status_result.result or {}
	local system = nixio.sysinfo() or {}
	local total = tonumber(system.totalram or 0) or 0
	local free = tonumber(system.freeram or 0) or 0
	local buffers = tonumber(system.bufferram or 0) or 0
	local memory_percent = 0
	if total > 0 then
		memory_percent = math.floor(
			((total - free - buffers) * 100 / total) + 0.5)
		if memory_percent < 0 then
			memory_percent = 0
		elseif memory_percent > 100 then
			memory_percent = 100
		end
	end

	local cpe = {}
	for index, modem in ipairs(core.modems()) do
		if type(modem) == "table" then
			local value = {}
			for key, field in pairs(type(modem.status) == "table" and
			    modem.status or {}) do
				value[key] = field
			end
			value.name = value.name or modem.name or
				("cpe" .. tostring(index))
			value.cpeno = index
			value.device_traffic = tonumber(value.device_traffic or 0) or 0
			value.traffic = tonumber(value.traffic or 0) or 0
			value.sim_flow = tonumber(value.sim_flow or 0) or 0
			value.sim_mon = tonumber(value.sim_mon or 0) or 0
			cpe[#cpe + 1] = value
		end
	end

	local link = {}
	if type(status.port) == "table" then
		if type(status.port[1]) == "table" then
			for _, item in ipairs(status.port) do
				link[#link + 1] = item
			end
		else
			link[1] = status.port
		end
	end

	local wan = type(status.wan) == "table" and status.wan or {}
	local route = type(wan.route) == "table" and wan.route[1] or {}
	local wans = {
		{
			name = "c2000_wan",
			status = wan.up and "up" or "down",
			proto = wan.proto or "",
			device = wan.device or wan.l3_device or "",
			uptime = tonumber(wan.uptime or 0) or 0,
			gateway = type(route) == "table" and
				(route.nexthop or route.gateway or "") or "",
			upload = 0,
			download = 0
		}
	}

	return {
		result = {
			global = {
				uptime = tonumber(system.uptime or sys.uptime() or 0) or 0,
				cpu_percent = 0,
				mem_percent = memory_percent,
				net_prefer = "auto"
			},
			cpe = cpe,
			link = link,
			wans = wans
		}
	}
end

local function basic_result(event, payload)
	local result
	if event == "heartbeat" then
		return { errcode = "0", code = "0" }, "heartbeat"
	elseif event == "time" then
		return {
			id = core.device_id() or "",
			state = 2
		}, "device_info"
	elseif event == "runtime" then
		return runtime_status(), "runtime"
	elseif event == "info" then
		result = core.handle("info", payload)
		result.errcode = code(result) == "0" and "0" or code(result)
		return result, "info"
	elseif event == "status" then
		return device_status(payload), "device_info"
	elseif event == "intstatus" then
		return internet_status(), "intinfo"
	elseif event == "wifistatus" then
		result = core.handle("wifi", {})
		local value = result.result or {}
		return value, "wifistatus"
	elseif event == "wifiset" then
		result = core.handle("wifi", {
			trans_id = payload.trans_id,
			list = payload.wifiset or payload.list
		})
		return {
			errcode = code(result) == "0" and "0" or code(result),
			message = result.message
		}, "wifiset"
	elseif event == "cpestatus" then
		return cpe_status(), "cpeinfo"
	elseif event == "batstatus" then
		return battery_status(), "batinfo"
	elseif event == "wanstatus" then
		result = core.handle("status", payload)
		return {
			errcode = code(result) == "0" and "0" or code(result),
			result = result.result and result.result.wan or {}
		}, "wanstatus"
	elseif event == "linkstatus" then
		result = core.handle("status", payload)
		return {
			errcode = code(result) == "0" and "0" or code(result),
			link = { result.result and result.result.port or {} }
		}, "linkstatus"
	elseif event == "sms" then
		return remote_sms(payload), "sms"
	elseif event == "apn" then
		return core.handle("apn", payload), "apn"
	elseif event == "simswitch" then
		return remote_sim_switch(payload), "simswitch"
	elseif event == "password" then
		return core.handle("password", payload), "password"
	elseif event == "reboot" then
		local reboot = core.handle("cmd", { cmd = "reboot" })
		if code(reboot) == "0" then
			-- The factory handler sends device_info/state=6 and deliberately
			-- emits no ordinary reboot reply.
			M.publish("device_info", {
				id = core.device_id() or "",
				state = 6
			}, true)
			return {}, "reboot", false
		end
		return {
			code = code(reboot),
			errcode = code(reboot),
			message = reboot.message
		}, "reboot", true
	end
	return nil
end

local function handle_command(event, payload)
	if event == "command" then
		-- The official APP implements remote LuCI login by sending a per-device
		-- `command` request which starts its temporary RSSH tunnel.  Keep that
		-- permission separate from rpc/exec and all other shell interfaces.
		if not core.feature_enabled("remote_web_enable") and
		   not core.feature_enabled("command_enable") then
			return disabled("remote web login"), event
		end
		local environment_ready, environment_error =
			rweb.prepare(uci, identity.get(true))
		if not environment_ready then
			payload.result = "rweb compatibility preparation failed"
			payload["return"] = "1"
			payload.errcode = "1"
			payload.message = tostring(environment_error or
				"rweb compatibility preparation failed")
			return payload, "command"
		end
		local prepared_command, command_error =
			rweb.prepare_command(payload.cmd)
		if not prepared_command then
			payload.result = "rweb bootstrap runtime unavailable"
			payload["return"] = "1"
			payload.errcode = nil
			payload.message = tostring(command_error or
				"rweb bootstrap runtime unavailable")
			return payload, "command"
		end
		local result, output = execute(prepared_command, 60)
		payload.result = output
		payload["return"] = tostring(result)
		-- Factory cloudd returns the original command envelope with only
		-- `result` and `return` added.  Do not add an errcode field: the APP's
		-- rweb callback consumes the vendor envelope verbatim.
		payload.errcode = nil
		return payload, "command"
	end
	if not core.feature_enabled("command_enable") then
		return disabled("command"), event
	end

	local command = tostring(payload.cmd or "")
	if command == "ping" or command == "nslookup" then
		local destination = tostring(payload.destination or "")
		if not destination:match("^[A-Za-z0-9_.:%-]+$") or
		   #destination > 253 then
			return { code = "1", result = "invalid destination" }, "cmd"
		end
		local shell = command == "ping" and
			("ping -c 5 " .. util.shellquote(destination)) or
			("nslookup " .. util.shellquote(destination))
		local result, output = execute(shell)
		return {
			cmd = command,
			destination = destination,
			code = tostring(result),
			result = output
		}, "cmd"
	elseif command == "service" then
		local service = tostring(payload.service or payload.name or "")
		local action = tostring(payload.action or "")
		if not service:match("^[A-Za-z0-9_.%-]+$") or
		   not ({ start=true, stop=true, restart=true, reload=true,
			    enable=true, disable=true, status=true })[action] then
			return { code = "1", result = "invalid service request" }, "cmd"
		end
		local result, output = execute("/etc/init.d/" .. service .. " " .. action)
		return { code = tostring(result), result = output }, "cmd"
	end
	return { code = "1", result = "unsupported cmd action" }, "cmd"
end

local function handle_upgrade(event)
	-- This is an invariant, not a configurable permission.  Keep an explicit
	-- reply for protocol compatibility while deliberately retaining no
	-- download, validation or sysupgrade execution path in the APP service.
	return {
		code = "3",
		errcode = "3",
		state = "permanently_disabled",
		version = core.software_version(),
		message = "software update permanently disabled"
	}, event == "firmware" and "firmware_status" or "upgrade"
end

local function destination_path(payload)
	local requested = payload.dfile or payload.path or payload.file
	if type(requested) ~= "string" or requested == "" or #requested > 512 or
	   requested:find("[%z\r\n]") then
		return nil
	end
	if requested:sub(1, 1) ~= "/" then
		requested = DOWNLOAD_DIR .. "/" .. requested
	end
	if requested:match("^/tmp/c2000max%-app%-downloads/") or
	   requested:match("^/mnt/") then
		return requested
	end
	if core.feature_enabled("developer_enable") and
	   not requested:match("^/proc/") and
	   not requested:match("^/sys/") and
	   not requested:match("^/dev/") then
		return requested
	end
	return nil
end

local function handle_file(payload)
	if not core.feature_enabled("file_enable") then
		return disabled("file"), "file"
	end
	local url = payload.url or payload.sfile
	local target = destination_path(payload)
	if not target or not valid_url(url) then
		return { code = "2", errcode = "2",
			message = "invalid file request" }, "file"
	end
	local directory = target:match("^(.*)/[^/]+$")
	if not directory or directory == "" then
		return { code = "2", errcode = "2",
			message = "invalid destination" }, "file"
	end
	fs.mkdirr(directory)
	local temporary = DOWNLOAD_DIR .. "/file.part"
	local ok, message = download(url, temporary)
	if not ok then
		return { code = "3", errcode = "3", message = message }, "file"
	end
	ok, message = verify_checksum(temporary, payload)
	if not ok then
		fs.unlink(temporary)
		return { code = "4", errcode = "4", message = message }, "file"
	end
	if not os.rename(temporary, target) then
		fs.unlink(temporary)
		return { code = "5", errcode = "5", message = "move failed" }, "file"
	end
	local action_result
	if payload.action and payload.action ~= "" then
		if not core.feature_enabled("command_enable") then
			return { code = "3", errcode = "3",
				message = "file saved; action disabled", path = target }, "file"
		end
		local result, output = execute(tostring(payload.action))
		action_result = { code = result, output = output }
	end
	return {
		code = "0",
		errcode = "0",
		path = target,
		checksum = message,
		action = action_result
	}, "file"
end

local function handle_appstore(payload)
	if not core.feature_enabled("appstore_enable") then
		return disabled("appstore"), "appstore"
	end
	local url = payload.url
	local path = DOWNLOAD_DIR .. "/appstore.zip"
	local ok, message = download(url, path)
	if not ok then
		return { code = "7", errcode = "7", message = message }, "appstore"
	end
	ok, message = verify_checksum(path, payload)
	if not ok then
		fs.unlink(path)
		return { code = "3", errcode = "3", message = message }, "appstore"
	end
	return {
		code = "0",
		errcode = "0",
		state = "staged",
		path = path,
		checksum = message,
		message = "package staged; no compatible appcenter backend"
	}, "appstore"
end

local function handle_develop(payload)
	if not core.feature_enabled("developer_enable") then
		return disabled("developer"), "develop"
	end
	if payload.object and payload.method then
		local result = safe_ubus(payload.object, payload.method, payload.params)
		return {
			code = result and "0" or "2",
			errcode = result and "0" or "2",
			result = result or {}
		}, "develop"
	end
	return {
		code = "0",
		errcode = "0",
		enable = "1"
	}, "develop"
end

local function control_item(value, depth)
	if type(value) ~= "table" or (depth or 0) > 5 then return nil end
	if value.mac ~= nil or
	   (value.client ~= nil and type(value.client) ~= "table") or
	   value.real_mac ~= nil or
	   value.macaddr ~= nil or value.device_mac ~= nil or value.sta_mac ~= nil then
		return value
	end
	local keys = {
		"control", "data", "payload", "item", "client", "clients",
		"station", "stations", "terminal", "terminals", "stacontrol",
		"sta_control", "clientcontrol", "terminalcontrol"
	}
	for _, key in ipairs(keys) do
		local item = control_item(value[key], (depth or 0) + 1)
		if item then return item end
	end
	for _, item in ipairs(value) do
		local nested = control_item(item, (depth or 0) + 1)
		if nested then return nested end
	end
	return nil
end

local function control_flag(value)
	if type(value) == "boolean" then return value end
	local number = tonumber(value)
	if number ~= nil then return number ~= 0 end
	value = tostring(value or ""):lower()
	if value == "true" or value == "on" or value == "yes" or
	   value == "allow" or value == "allowed" or value == "enable" or
	   value == "enabled" then return true end
	if value == "false" or value == "off" or value == "no" or
	   value == "deny" or value == "denied" or value == "disable" or
	   value == "disabled" or value == "block" or value == "blocked" then
		return false
	end
	return nil
end

local function terminal_control(payload)
	local item = control_item(payload) or payload
	local mac = item.mac or item.client or item.real_mac or item.macaddr or
		item.device_mac or item.sta_mac
	if not mac then return nil end
	local allowed
	if item.switch_off ~= nil then
		local blocked = control_flag(item.switch_off)
		if blocked ~= nil then allowed = not blocked end
	elseif item.switch ~= nil then
		allowed = control_flag(item.switch)
	elseif item.online ~= nil then
		allowed = control_flag(item.online)
	elseif item.deny ~= nil then
		local denied = control_flag(item.deny)
		if denied ~= nil then allowed = not denied end
	elseif item.blocked ~= nil then
		local blocked = control_flag(item.blocked)
		if blocked ~= nil then allowed = not blocked end
	elseif item.disabled ~= nil then
		local disabled = control_flag(item.disabled)
		if disabled ~= nil then allowed = not disabled end
	elseif item.internet ~= nil then
		allowed = control_flag(item.internet)
	elseif item.allow ~= nil then
		allowed = control_flag(item.allow)
	elseif item.enabled ~= nil then
		allowed = control_flag(item.enabled)
	end
	if allowed == nil then return nil end
	return core.set_device_internet(mac, allowed)
end

function M.handle(event, payload)
	payload = type(payload) == "table" and payload or {}
	local result, reply_event, reply_expected = basic_result(event, payload)
	if result then
		return result, reply_event, reply_expected
	end

	local control_key = tostring(event or ""):lower():gsub("[^a-z0-9]", "")
	local control_event = control_key == "stacontrol" or
		control_key == "stactrl" or control_key == "stationcontrol" or
		control_key == "clientcontrol" or control_key == "terminalcontrol" or
		control_key == "clientset" or control_key == "terminalset" or
		control_key == "staset" or control_key == "clientupdate" or
		control_key == "terminalupdate" or control_key == "accesscontrol" or
		control_key == "internetcontrol"
	if control_event then
		-- Remote access control is an authenticated command, not a periodic
		-- terminal-tracking report.  It must remain actionable while tracking is
		-- disabled; set_device_internet() enables and applies c2000max-access.
		local control = terminal_control(payload)
		return control or { code = "2", errcode = "2", message = "invalid control" }, event
	elseif event == "client" or event == "terminal" then
		-- Factory cloud builds also reuse the ordinary client/terminal event for
		-- writes.  Treat a payload carrying switch state as a command, while an
		-- empty payload remains the inventory query.
		local control = terminal_control(payload)
		if control then return control, event end
		if not core.feature_enabled("terminal_tracking_enable") then
			return disabled("terminal tracking"), event
		end
		return terminal_status(), event == "client" and "client" or "terminal"
	elseif event == "stastatus" then
		if not core.feature_enabled("terminal_tracking_enable") then
			return disabled("terminal tracking"), "stalist"
		end
		return station_status(), "stalist"
	elseif event == "device_info" or event == "report" or
	       event == "config" then
		if not core.feature_enabled("device_report_enable") then
			return disabled("device report"), event
		end
		return device_status(), event == "status" and "device_info" or event
	elseif event == "cellular_record" or event == "cpeinfo" then
		if not core.feature_enabled("signal_report_enable") then
			return disabled("signal report"), event
		end
		return signal_status(), event
	elseif event == "traffic" or event == "trafficstatus" then
		if not core.feature_enabled("traffic_report_enable") then
			return disabled("traffic report"), event
		end
		return traffic_status(), event == "trafficstatus" and "traffic" or event
	elseif event == "command" or event == "cmd" then
		return handle_command(event, payload)
	elseif event == "firmware" or event == "upgrade" then
		return handle_upgrade(event, payload)
	elseif event == "file" then
		return handle_file(payload)
	elseif event == "appstore" then
		return handle_appstore(payload)
	elseif event == "develop" then
		return handle_develop(payload)
	end
	return { code = "-5", errcode = "-5", message = "unsupported" }, event
end

function M.publish(event, payload, reply)
	local device_id = core.device_id()
	if not device_id or
	   type(event) ~= "string" or not event:match("^[A-Za-z0-9_.%-]+$") or
	   type(payload) ~= "table" then
		return false
	end
	if payload.uniq == nil then
		payload.uniq = response_timestamp()
	end
	fs.mkdirr(STATE_DIR)
	local nonce = sys.uniqueid(8)
	if not nonce then
		return false
	end
	local path = STATE_DIR .. "/publish-" .. nonce .. ".json"
	if not fs.writefile(path, json.stringify(payload)) then
		return false
	end
	fs.chmod(path, "0600")
	local topic = "kp/mosca/" .. device_id .. "/" ..
		(reply and "reply/" or "") .. event
	local command = table.concat({
		"/usr/bin/timeout",
		"-s TERM",
		"-k 2",
		"10",
		"/usr/bin/mosquitto_pub",
		"-h 127.0.0.1",
		"-p 1884",
		"-V mqttv311",
		"-i", util.shellquote("c2000max-tx-" .. nonce:sub(1, 8)),
		"-q 1",
		"-t", util.shellquote(topic),
		"-f", util.shellquote(path)
	}, " ")
	local result = sys.call(command) == 0
	fs.unlink(path)
	return result
end

function M.publish_reports()
	local sent = {}
	if core.feature_enabled("device_report_enable") then
		sent.device_info = M.publish("device_info", device_status(), false)
	end
	if core.feature_enabled("traffic_report_enable") then
		sent.traffic = M.publish("traffic", traffic_status(), false)
	end
	if core.feature_enabled("terminal_tracking_enable") then
		sent.terminal = M.publish("terminal", terminal_status(), false)
	end
	return sent
end

function M.publish_cpe_status()
	if not core.feature_enabled("signal_report_enable") then
		return nil
	end
	-- This is the factory presence request, not a proactive CPE data report.
	-- The original binary sends only the automatically added numeric `uniq`.
	return M.publish("cpestatus", { uniq = presence_timestamp() }, false)
end

function M.open_cpe_status_publisher()
	if not core.feature_enabled("signal_report_enable") then
		return nil
	end
	local device_id = core.device_id()
	local nonce = sys.uniqueid(8)
	if not device_id or not nonce then
		return nil
	end
	local topic = "kp/mosca/" .. device_id .. "/cpestatus"
	local command = table.concat({
		"exec /usr/bin/mosquitto_pub",
		"-h 127.0.0.1",
		"-p 1884",
		"-V mqttv311",
		"-i", util.shellquote("c2000max-presence-" .. nonce:sub(1, 8)),
		"-q 1",
		"-k 30",
		"-t", util.shellquote(topic),
		"-l",
		"2>/dev/null"
	}, " ")
	return io.popen(command, "w")
end

function M.publish_cpe_status_stream(stream)
	if not core.feature_enabled("signal_report_enable") then
		return nil
	end
	if not stream then
		return false
	end
	local encoded = json.stringify({ uniq = presence_timestamp() })
	local ok, written = pcall(stream.write, stream, encoded .. "\n")
	if not ok or not written then
		return false
	end
	local flushed_ok, flushed = pcall(stream.flush, stream)
	return flushed_ok and flushed and true or false
end

function M.publish_online_status()
	local device_id = core.device_id()
	if not device_id then
		return false
	end
	return M.publish("status", {
		id = device_id,
		uniq = presence_timestamp()
	}, false)
end

return M
