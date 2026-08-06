local root = assert(arg[1], "package root is required")
package.path = root .. "/files/usr/lib/lua/?.lua;" ..
	root .. "/files/usr/lib/lua/?/init.lua;" .. package.path

local files = {}
local flags = {
	remote_web_enable = false,
	command_enable = false
}

local function module(name, value)
	package.loaded[name] = value
	package.preload[name] = function()
		return value
	end
end

module("nixio.fs", {
	mkdirr = function() return true end,
	writefile = function(path, value) files[path] = value return true end,
	chmod = function() return true end,
	unlink = function(path) files[path] = nil return true end,
	stat = function(path) return files[path] and {} or nil end,
	access = function() return false end
})
module("nixio", {
	gettimeofday = function() return 1785693399, 123456 end
})
module("luci.jsonc", {
	stringify = function() return "{}" end
})
module("luci.model.uci", {
	cursor = function() return {} end
})
module("c2000max_app.identity", {
	get = function() return { device_id = "021122334455" } end
})
module("c2000max_app.rweb", {
	prepare = function() return true end,
	prepare_command = function(command) return command end
})

local command_calls = 0
module("luci.sys", {
	uniqueid = function() return "0011223344556677" end,
	call = function()
		command_calls = command_calls + 1
		files["/var/run/c2000max-app/command-0011223344556677.log"] =
			"tunnel allocated\nReady to RSSH\n"
		return 0
	end
})
module("luci.util", {
	shellquote = function(value) return "'" .. tostring(value) .. "'" end,
	ubus = function() return {} end
})
module("c2000max_app.core", {
	feature_enabled = function(name) return flags[name] == true end,
	device_id = function() return "021122334455" end
})

local original_open = io.open
io.open = function(path, mode)
	if mode == "rb" and files[path] ~= nil then
		local value = files[path]
		return {
			read = function(_, count)
				if type(count) == "number" then
					return value:sub(1, count)
				end
				return value
			end,
			close = function() end
		}
	end
	return original_open(path, mode)
end

local function equal(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label,
			tostring(expected), tostring(actual)))
	end
end

local cloud = require "c2000max_app.cloud"

local denied, denied_event = cloud.handle("command", {
	cmd = "temporary-rssh-command"
})
equal(denied_event, "command", "denied reply event")
equal(denied.errcode, "3", "remote Web permission denial")
equal(command_calls, 0, "disabled command is not executed")

flags.remote_web_enable = true
local allowed, allowed_event = cloud.handle("command", {
	cmd = "temporary-rssh-command"
})
equal(allowed_event, "command", "allowed reply event")
equal(allowed["return"], "0", "RSSH command exit code")
equal(allowed.result, "tunnel allocated\nReady to RSSH\n",
	"RSSH readiness output is preserved")
equal(command_calls, 1, "remote Web command executes once")

local generic, generic_event = cloud.handle("cmd", {
	cmd = "ping",
	destination = "127.0.0.1"
})
equal(generic_event, "cmd", "generic reply event")
equal(generic.errcode, "3", "remote Web permission does not enable cmd")
equal(command_calls, 1, "generic command stays disabled")

print("PASS: remote Web permission is isolated from generic command execution")
