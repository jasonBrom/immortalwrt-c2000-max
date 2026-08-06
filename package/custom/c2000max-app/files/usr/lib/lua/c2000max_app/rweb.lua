local fs = require "nixio.fs"
local json = require "luci.jsonc"

local M = {}
local STATE_DIR = "/var/run/c2000max-app"
local STATE_FILE = STATE_DIR .. "/rweb-compat.state"
local OEM_CONFIG = "/etc/config/oem"
local PRIVATE_BIN = "/usr/libexec/c2000max-rweb-bin"
local PRIVATE_WGET = "/usr/lib/c2000max-rweb-compat/wget-ssl"

local function trim(value)
	if type(value) ~= "string" then
		return nil
	end
	value = value:match("^%s*(.-)%s*$")
	return value ~= "" and value or nil
end

local function normalized_device_id(value)
	value = tostring(value or ""):gsub("[^0-9A-Fa-f]", ""):upper()
	if #value ~= 12 or value == "000000000000" or
	   value == "FFFFFFFFFFFF" then
		return nil
	end
	return value
end

local function device_mac(value)
	value = normalized_device_id(value)
	if not value then
		return nil
	end
	return value:gsub("(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)",
		"%1:%2:%3:%4:%5:%6")
end

local function safe_factory_value(value, maximum, pattern)
	value = trim(value)
	if not value or #value > maximum or value:find("[%z\r\n]") or
	   (pattern and not value:match(pattern)) then
		return nil
	end
	return value
end

local function factory_options(identity)
	local path = safe_factory_value(identity.bdinfo_source, 256,
		"^/[A-Za-z0-9_./%-]+$")
	if not path then
		return {}
	end
	local file = io.open(path, "rb")
	if not file then
		return {}
	end
	local data = file:read(65536) or ""
	file:close()
	data = data:gsub("%z", "\n"):gsub("\255", "\n")
	local wanted = {
		board = true,
		country = true,
		oem_domain = true,
		oem_pname = true,
		oem_ptype = true,
		oem_vendor = true
	}
	local result = {}
	for line in (data .. "\n"):gmatch("([^\r\n]*)[\r\n]+") do
		local key, value = line:match(
			"^%s*([A-Za-z0-9_]+)%s*=%s*(.-)%s*$")
		if wanted[key] and result[key] == nil then
			result[key] = safe_factory_value(value, 64,
				"^[A-Za-z0-9_. +%-]+$")
		end
	end
	return result
end

local function write_state(value)
	fs.mkdirr(STATE_DIR)
	value.updated = os.time()
	fs.writefile(STATE_FILE, json.stringify(value))
	fs.chmod(STATE_FILE, "0600")
end

local function mark_changed(changed, config, section, option)
	changed[config] = true
	local key = config .. "." .. section
	if option then
		key = key .. "." .. option
	end
	return key
end

local function ensure_section(cursor, changed, applied, config, section, kind)
	if cursor:get(config, section) == nil then
		cursor:set(config, section, kind)
		applied[#applied + 1] = mark_changed(changed, config, section)
	end
end

local function set_missing(cursor, changed, applied, config, section,
		option, value)
	if value ~= nil and value ~= "" and
	   cursor:get(config, section, option) == nil then
		cursor:set(config, section, option, tostring(value))
		applied[#applied + 1] =
			mark_changed(changed, config, section, option)
	end
end

local function set_identity(cursor, changed, applied, config, section,
		option, value)
	if value ~= nil and value ~= "" and
	   cursor:get(config, section, option) ~= tostring(value) then
		cursor:set(config, section, option, tostring(value))
		applied[#applied + 1] =
			mark_changed(changed, config, section, option)
	end
end

-- The vendor's cloud-generated rweb bootstrap assumes the UCI namespace
-- produced by /lib/functions/oem.sh in the factory image.  The clean-room SD
-- image deliberately did not import that vendor init stack, so the bootstrap
-- stopped at its first `uci get` before starting the temporary reverse-SSH
-- client.  Recreate only the read-only identity and role aliases needed by
-- the bootstrap; do not import the factory network, password or upgrade
-- settings.
function M.prepare(cursor, identity)
	if cursor == nil or type(cursor.get) ~= "function" or
	   type(cursor.set) ~= "function" or type(identity) ~= "table" then
		return false, "invalid compatibility context"
	end

	-- libuci does not create a missing package implicitly on every OpenWrt
	-- release.  The factory image always ships /etc/config/oem, whereas the
	-- clean-room image does not, so create an empty package before setting the
	-- compatibility sections.
	if not fs.access(OEM_CONFIG) then
		fs.mkdirr("/etc/config")
		if not fs.writefile(OEM_CONFIG, "") then
			return false, "unable to create factory UCI namespace"
		end
		if type(cursor.unload) == "function" then
			pcall(cursor.unload, cursor, "oem")
		end
		if type(cursor.load) == "function" then
			local ok, loaded = pcall(cursor.load, cursor, "oem")
			if not ok or loaded == false then
				return false, "unable to load factory UCI namespace"
			end
		end
	end

	local id = normalized_device_id(identity.device_id)
	local mac = trim(identity.device_mac) or device_mac(id)
	if not id or not mac then
		write_state({
			state = "identity_error",
			message = "factory device identity unavailable",
			applied = {}
		})
		return false, "factory device identity unavailable"
	end

	local changed = {}
	local applied = {}
	local factory = factory_options(identity)
	-- C2000-MAX is registered with the vendor cloud as router type `rt`.
	-- Do not inherit a stale AP/AC role from reused factory storage.
	local ptype = "rt"
	local vendor = factory.oem_vendor or "nradio"
	local country = factory.country or "CN"
	local domain = factory.oem_domain or "nradio.in"

	ensure_section(cursor, changed, applied, "oem", "board", "system")
	set_identity(cursor, changed, applied, "oem", "board", "id", mac)
	set_identity(cursor, changed, applied, "oem", "board", "ptype", ptype)
	set_identity(cursor, changed, applied, "oem", "board", "vendor", vendor)
	set_missing(cursor, changed, applied, "oem", "board", "name",
		factory.board or "C2000-MAX")
	set_missing(cursor, changed, applied, "oem", "board", "pname",
		factory.oem_pname or "C2000-788")
	set_identity(cursor, changed, applied, "oem", "board", "country",
		country)
	set_missing(cursor, changed, applied, "oem", "board", "keep", "1")
	set_missing(cursor, changed, applied, "oem", "board", "device_code",
		identity.device_code)

	ensure_section(cursor, changed, applied, "oem", "feature", "system")
	set_missing(cursor, changed, applied, "oem", "feature", "cpe", "1")

	ensure_section(cursor, changed, applied, "oem", "custom", "system")
	set_identity(cursor, changed, applied, "oem", "custom", "domain",
		domain)

	-- Standard OpenWrt already has network.globals.  The extra default_* keys
	-- are vendor metadata ignored by netifd, but factory rweb helpers use them
	-- to resolve the local LuCI endpoint.
	if cursor:get("network", "globals") ~= nil then
		set_missing(cursor, changed, applied, "network", "globals",
			"default_lan", "lan")
		set_missing(cursor, changed, applied, "network", "globals",
			"default_wan", "wan")
		set_missing(cursor, changed, applied, "network", "globals",
			"default_wan6", "wan6")
		local cellular = cursor:get("network", "cpe") and "cpe" or nil
		set_missing(cursor, changed, applied, "network", "globals",
			"default_cellular", cellular)
	end

	for config in pairs(changed) do
		local ok, committed, err = pcall(function()
			return cursor:commit(config)
		end)
		if not ok or committed == false then
			write_state({
				state = "commit_error",
				message = "unable to commit " .. config,
				applied = applied
			})
			return false, tostring(err or committed or "UCI commit failed")
		end
	end

	if cursor:get("oem", "board", "id") ~= mac or
	   cursor:get("oem", "board", "ptype") ~= "rt" then
		return false, "factory UCI identity verification failed"
	end

	write_state({
		state = "ready",
		message = "factory rweb UCI aliases ready",
		device_id = id,
		applied = applied
	})
	return true, applied
end

-- The factory rweb bootstrap was generated for GNU Wget 1.19.2.  On the
-- clean-room image `/usr/bin/wget` is an uclient-fetch alternative.  A common
-- bootstrap form is `wget ... -O- | sh`; when uclient-fetch rejects a GNU-only
-- option or TLS handshake, the empty downstream shell still returns zero.
-- That produced a misleading successful command reply without ever starting
-- RSSH.  Run only the official rweb command with the isolated factory GNU Wget
-- runtime.  The system wget alternative remains untouched for apk and normal
-- OpenWrt services.
function M.prepare_command(command)
	if type(command) ~= "string" or command == "" or #command > 4096 or
	   command:find("%z") then
		return nil, "invalid rweb command"
	end
	if not fs.access(PRIVATE_WGET) or
	   not fs.access(PRIVATE_BIN .. "/wget") or
	   not fs.access(PRIVATE_BIN .. "/wget-ssl") then
		return nil, "isolated factory GNU Wget runtime unavailable"
	end

	-- Bare wget resolves through PRIVATE_BIN.  Rewrite the three absolute
	-- paths used by vendor bootstrap revisions so they cannot fall back to
	-- uclient-fetch.  No URL, argument or one-time secret is persisted.
	local rewritten = command
	rewritten = rewritten:gsub("/usr/bin/wget%-ssl",
		PRIVATE_BIN .. "/wget-ssl")
	rewritten = rewritten:gsub("/usr/bin/wget",
		PRIVATE_BIN .. "/wget")
	rewritten = rewritten:gsub("/bin/wget",
		PRIVATE_BIN .. "/wget")

	return "PATH=" .. PRIVATE_BIN ..
		":/usr/sbin:/usr/bin:/sbin:/bin; export PATH; " .. rewritten
end

function M.runtime_status()
	return {
		private_wget = fs.access(PRIVATE_WGET) and true or false,
		private_wget_entry = fs.access(PRIVATE_BIN .. "/wget") and
			true or false,
		private_wget_ssl_entry =
			fs.access(PRIVATE_BIN .. "/wget-ssl") and true or false,
		runtime = "factory GNU Wget 1.19.2 (isolated)"
	}
end

local function safe_uci_key(value)
	value = tostring(value or ""):gsub("^[\"']+", ""):
		gsub("[\"';|&<>].*$", "")
	if value == "" or #value > 96 or
	   not value:match("^[A-Za-z0-9_@%[%]%.%-]+$") then
		return nil
	end
	return value
end

local function add_unique(items, seen, value)
	value = safe_uci_key(value)
	if value and not seen[value] then
		seen[value] = true
		items[#items + 1] = value
	end
end

-- Inspect only executable names and UCI paths.  Never retain the full cloud
-- command, URLs, arguments or the one-time plainSecret.
function M.inspect(command)
	command = type(command) == "string" and command or ""
	local keys = {}
	local seen = {}
	for key in command:gmatch("uci%s+%-q%s+get%s+([A-Za-z0-9_@%[%]%.%-]+)") do
		add_unique(keys, seen, key)
	end
	for key in command:gmatch("uci%s+get%s+%-q%s+([A-Za-z0-9_@%[%]%.%-]+)") do
		add_unique(keys, seen, key)
	end
	for key in command:gmatch("uci%s+get%s+([A-Za-z0-9_@%[%]%.%-]+)") do
		add_unique(keys, seen, key)
	end

	local lower = command:lower()
	local method = "unknown"
	if lower:match("[%s/;|&]frpc[%s;|&]") or
	   lower:find("frpc", 1, true) then
		method = "frp"
	elseif lower:find("ready to rssh", 1, true) or
	       lower:match("[%s/;|&]rssh[%s;|&]") or
	       lower:match("[%s/;|&]dbclient[%s;|&].-%s%-[Rr]") or
	       lower:match("[%s/;|&]ssh[%s;|&].-%s%-[Rr]") then
		method = "reverse_ssh"
	elseif lower:find("wget", 1, true) or lower:find("curl", 1, true) or
	       lower:find("uclient-fetch", 1, true) then
		method = "remote_bootstrap"
	end

	local bootstrap = ""
	if lower:find("wget-ssl", 1, true) then
		bootstrap = "wget-ssl"
	elseif lower:find("uclient-fetch", 1, true) then
		bootstrap = "uclient-fetch"
	elseif lower:find("curl", 1, true) then
		bootstrap = "curl"
	elseif lower:find("wget", 1, true) then
		bootstrap = "wget"
	end

	return {
		tunnel_method = method,
		bootstrap_tool = bootstrap,
		uci_queries = table.concat(keys, ",")
	}
end

return M
