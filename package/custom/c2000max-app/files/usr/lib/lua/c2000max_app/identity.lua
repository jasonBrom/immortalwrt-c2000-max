local fs = require "nixio.fs"
local util = require "luci.util"

local M = {}

local FIXED_CRYPTO_KEY = "383a537d1f2df8c5a76e2f95ddae6a92"
local RANDOM_AUTH_KEY = "f2e6e232e75f33d5f3d5b040c93d0d"
-- 鲲鹏无限 3.1.0 uses the first 32 characters of its server facKey for
-- AES-256-CBC and for the sorted MD5 authentication token.  Devices without
-- a fac_key in bdinfo must use the APP's built-in fallback, not the wrapper
-- key used by the older random-key protocol.
local APP310_AES_FALLBACK_KEY = "59ad910d5902374f90224e063538b100"
local CURRENT_APP_SOURCE = "official APP v5 DES protocol"
local CACHE_SECONDS = 5
local cached
local cached_at = 0

-- The first assignment in factory bdinfo may be preceded by a UTF-8 BOM or
-- vendor metadata bytes.  Keep the keys explicit so recovery scanning cannot
-- accidentally turn arbitrary flash text into credentials.
local BDINFO_KEYS = {
	"fac_mac",
	"device_code",
	"crypto_secret",
	"fac_key",
	"app_secret"
}

local function trim(value)
	if type(value) ~= "string" then
		return nil
	end
	value = value:match("^%s*(.-)%s*$")
	return value ~= "" and value or nil
end

local function read_limited(path, maximum, offset)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	if offset and not file:seek("set", offset) then
		file:close()
		return nil
	end
	local data = file:read(maximum)
	file:close()
	return data
end

local function append_unique(list, seen, value)
	value = trim(value)
	if value and not seen[value] then
		seen[value] = true
		list[#list + 1] = value
	end
end

local function partition_devices(label)
	local result = {}
	local seen = {}
	local by_label = "/dev/disk/by-partlabel/" .. label
	if fs.stat(by_label) then
		append_unique(result, seen, by_label)
	end
	local output = util.exec("blkid -t PARTLABEL=" .. label ..
		" -o device 2>/dev/null") or ""
	for path in output:gmatch("[^\r\n]+") do
		append_unique(result, seen, path)
	end
	return result
end

local function bdinfo_devices()
	local result = partition_devices("bdinfo")
	local seen = {}
	for _, path in ipairs(result) do
		seen[path] = true
	end
	local proc_mtd = fs.readfile("/proc/mtd") or ""
	for number, name in proc_mtd:gmatch(
		'mtd(%d+):%s+[%x]+%s+[%x]+%s+"([^"]+)"') do
		if name == "bdinfo" or name == "oeminfo" then
			local block = "/dev/mtdblock" .. number
			local raw = "/dev/mtd" .. number
			if fs.stat(block) then
				append_unique(result, seen, block)
			elseif fs.stat(raw) then
				append_unique(result, seen, raw)
			end
		end
	end
	return result
end

local function parse_bdinfo(data)
	local result = {}
	if type(data) ~= "string" or data == "" then
		return result
	end
	data = data:gsub("%z", "\n"):gsub("\255", "\n")
	for line in (data .. "\n"):gmatch("([^\r\n]*)[\r\n]+") do
		local key, value = line:match(
			"^%s*([A-Za-z0-9_]+)%s*=%s*(.-)%s*$")
		key = key and key:lower() or nil
		value = trim(value)
		if key and value and result[key] == nil then
			result[key] = value
		end

		-- The old parser required the key to be the first printable token on
		-- the line.  On the real WT9303 partition that caused the leading
		-- fac_mac assignment to be skipped while later device_code text was
		-- accepted.  Search only the five protocol keys and still require an
		-- assignment immediately after the exact key.
		local lower = line:lower()
		for _, wanted in ipairs(BDINFO_KEYS) do
			if result[wanted] == nil then
				local start = 1
				while start <= #line do
					local position = lower:find(wanted, start, true)
					if not position then
						break
					end
					local suffix = line:sub(position + #wanted)
					local _, equals_end = suffix:find("^%s*=%s*")
					if equals_end then
						local recovered = trim(suffix:sub(equals_end + 1))
						if recovered then
							result[wanted] = recovered
							break
						end
					end
					start = position + #wanted
				end
			end
		end
	end
	return result
end

local function clean_device_id(value)
	if type(value) ~= "string" then
		return nil
	end
	value = value:gsub("[^0-9A-Fa-f]", ""):upper()
	if #value ~= 12 or value == "000000000000" or
	   value == "FFFFFFFFFFFF" then
		return nil
	end
	local first = tonumber(value:sub(1, 2), 16)
	if not first or first % 2 ~= 0 then
		return nil
	end
	return value
end

local function clean_aes_key(value)
	value = trim(value)
	if not value or #value < 32 or #value > 4096 or
	   value:find("[%z\r\n]") then
		return nil
	end
	-- APP 3.1.0 derives AES_KEY with String(facKey).slice(0, 32).
	return value:sub(1, 32)
end

local function factory_device_id()
	for _, path in ipairs(partition_devices("factory")) do
		local raw = read_limited(path, 6, 4)
		if raw and #raw == 6 then
			local parts = {}
			for index = 1, 6 do
				parts[index] = string.format("%02X", raw:byte(index))
			end
			local value = clean_device_id(table.concat(parts))
			if value then
				return value, path .. "@0x4"
			end
		end
	end
	return nil, nil
end

local function load_bdinfo()
	local paths = {
		"/mnt/app_data/bdinfo",
		"/etc/bdinfo.bin",
		"/bdinfo/bdinfo.bin"
	}
	local seen = {}
	for _, path in ipairs(paths) do
		seen[path] = true
	end
	for _, path in ipairs(bdinfo_devices()) do
		append_unique(paths, seen, path)
	end

	local merged = {}
	local first_source
	for _, path in ipairs(paths) do
		local data = read_limited(path, 65536)
		local values = parse_bdinfo(data)
		if next(values) then
			first_source = first_source or path
			for key, value in pairs(values) do
				if merged[key] == nil then
					merged[key] = value
				end
			end
		end
	end
	return merged, first_source
end

local function build()
	local values, bdinfo_source = load_bdinfo()
	local factory_id, factory_source = factory_device_id()
	local bdinfo_id = clean_device_id(values.fac_mac)
	local device_id = bdinfo_id or factory_id
	local device_code = trim(values.device_code)
	local bdinfo_identity_valid = bdinfo_id ~= nil
	local remote_identity_available = bdinfo_identity_valid and
		device_code ~= nil
	local identity_error
	if not bdinfo_source then
		identity_error = "未发现可读取的原厂 bdinfo"
	elseif not bdinfo_identity_valid then
		identity_error = "原厂 bdinfo 中的 fac_mac 缺失或格式无效"
	elseif not device_code then
		identity_error = "原厂 bdinfo 中的 device_code 缺失"
	end
	local device_source = bdinfo_id and
		(bdinfo_source and (bdinfo_source .. ":fac_mac") or "bdinfo:fac_mac") or
		factory_source

	local crypto_key = clean_aes_key(values.crypto_secret)
	local crypto_source = crypto_key and "bdinfo:crypto_secret" or nil
	if not crypto_key then
		crypto_key = clean_aes_key(values.fac_key)
		crypto_source = crypto_key and "bdinfo:fac_key" or nil
	end
	if not crypto_key then
		crypto_key = APP310_AES_FALLBACK_KEY
		crypto_source = "APP 3.1 AES fallback"
	end

	local app_secret = clean_aes_key(values.app_secret)
	local app_source = app_secret and "bdinfo:app_secret" or crypto_source
	if not app_secret then
		app_secret = crypto_key
	end

	return {
		available = device_id ~= nil,
		device_id = device_id,
		device_mac = device_id and device_id:gsub(
			"(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)(%x%x)",
			"%1:%2:%3:%4:%5:%6") or nil,
		device_source = device_source,
		factory_id = factory_id,
		bdinfo_id = bdinfo_id,
		bdinfo_source = bdinfo_source,
		bdinfo_fac_mac_present = trim(values.fac_mac) ~= nil,
		bdinfo_identity_valid = bdinfo_identity_valid,
		remote_identity_available = remote_identity_available,
		identity_error = identity_error,
		identity_mismatch = bdinfo_id ~= nil and factory_id ~= nil and
			bdinfo_id ~= factory_id,
		crypto_key = crypto_key,
		app310_fallback_key = APP310_AES_FALLBACK_KEY,
		crypto_source = crypto_source,
		app_secret = app_secret,
		app_source = app_source,
		current_app_secret = RANDOM_AUTH_KEY,
		current_app_source = CURRENT_APP_SOURCE,
		device_code = device_code,
		fixed_wrapper_key = FIXED_CRYPTO_KEY,
		random_auth_key = RANDOM_AUTH_KEY
	}
end

function M.get(force)
	local now = os.time()
	if force or not cached or now - cached_at >= CACHE_SECONDS then
		cached = build()
		cached_at = now
	end
	return cached
end

function M.public_status(force)
	local identity = M.get(force)
	return {
		available = identity.available,
		device_id = identity.device_id or "",
		device_mac = identity.device_mac or "",
		device_source = identity.device_source or "",
		factory_id = identity.factory_id or "",
		bdinfo_present = identity.bdinfo_source ~= nil,
		bdinfo_source = identity.bdinfo_source or "",
		bdinfo_fac_mac_present = identity.bdinfo_fac_mac_present,
		bdinfo_identity_valid = identity.bdinfo_identity_valid,
		remote_identity_available = identity.remote_identity_available,
		identity_error = identity.identity_error or "",
		identity_mismatch = identity.identity_mismatch,
		crypto_source = identity.crypto_source or "",
		app_auth_source = identity.current_app_source or "",
		legacy_app_auth_source = identity.app_source or "",
		device_code_present = identity.device_code ~= nil
	}
end

return M
