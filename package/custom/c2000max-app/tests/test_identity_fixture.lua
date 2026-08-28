local root = assert(arg[1], "package root is required")
package.path = root .. "/files/usr/lib/lua/?.lua;" ..
	root .. "/files/usr/lib/lua/?/init.lua;" .. package.path

local bdinfo_data
local factory_data = "\0\0\0\0" ..
	string.char(0x02, 0x11, 0x22, 0x33, 0x44, 0x55)

local function memory_file(data)
	local position = 1
	return {
		seek = function(_, mode, offset)
			assert(mode == "set")
			position = offset + 1
			return offset
		end,
		read = function(_, maximum)
			local value = data:sub(position, position + maximum - 1)
			position = position + #value
			return value
		end,
		close = function() return true end
	}
end

local real_open = io.open
io.open = function(path, mode)
	assert(mode == "rb")
	if path == "/dev/mtdblock0" then
		return memory_file(bdinfo_data)
	elseif path == "/dev/mmcblk0p3" then
		return memory_file(factory_data)
	end
	return nil
end

package.preload["nixio.fs"] = function()
	return {
		stat = function(path)
			return path == "/dev/mtdblock0"
		end,
		readfile = function(path)
			if path == "/proc/mtd" then
				return 'mtd0: 00010000 00010000 "bdinfo"\n'
			end
			return nil
		end
	}
end

package.preload["luci.util"] = function()
	return {
		exec = function(command)
			if command:find("PARTLABEL=factory", 1, true) then
				return "/dev/mmcblk0p3\n"
			end
			return ""
		end
	}
end

local identity = require "c2000max_app.identity"

local function equal(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label,
			tostring(expected), tostring(actual)))
	end
end

-- Real-unit regression: the first assignment can have non-configuration bytes
-- in front of it.  The old line-anchored parser skipped fac_mac but still read
-- device_code from the next line, then silently used the SD Factory ID.
bdinfo_data = "\239\187\191META:" ..
	"fac_mac = A2:11:22:33:44:55\n" ..
	"device_code = Fixture7\n" ..
	"fac_key = " .. string.rep("0123456789abcdef", 16) .. "\n"

local valid = identity.get(true)
equal(valid.device_id, "A21122334455", "factory bdinfo device ID")
equal(valid.bdinfo_id, "A21122334455", "validated bdinfo ID")
equal(valid.factory_id, "021122334455", "SD diagnostic factory ID")
equal(valid.device_source, "/dev/mtdblock0:fac_mac", "identity source")
equal(valid.device_code, "Fixture7", "device code")
equal(valid.crypto_key, "0123456789abcdef0123456789abcdef",
	"APP 3.1 first-32-char fac_key")
equal(valid.crypto_source, "bdinfo:fac_key", "APP 3.1 fac_key source")
equal(valid.bdinfo_identity_valid, true, "bdinfo identity validation")
equal(valid.remote_identity_available, true, "remote identity readiness")
equal(valid.identity_mismatch, true, "factory mismatch diagnostic")

bdinfo_data = "device_code = Fixture7\n"
local missing_mac = identity.get(true)
equal(missing_mac.device_id, "021122334455", "local diagnostic fallback")
equal(valid.app310_fallback_key, "59ad910d5902374f90224e063538b100",
	"unbound APP 3.1 fallback key")
equal(missing_mac.bdinfo_identity_valid, false, "missing fac_mac rejection")
equal(missing_mac.remote_identity_available, false,
	"remote fallback rejection")
equal(missing_mac.identity_error, "原厂 bdinfo 中的 fac_mac 缺失或格式无效",
	"identity error")

io.open = real_open
print("PASS: bdinfo parser recovers prefixed fac_mac and rejects SD cloud fallback")
