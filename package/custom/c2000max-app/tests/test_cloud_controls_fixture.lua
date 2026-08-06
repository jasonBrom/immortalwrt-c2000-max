local root = assert(arg[1], "package root is required")
package.path = root .. "/files/usr/lib/lua/?.lua;" ..
	root .. "/files/usr/lib/lua/?/init.lua;" .. package.path

local function module(name, value)
	package.loaded[name] = value
	package.preload[name] = function() return value end
end

local helper_available = false
local scheduled_commands = {}
module("nixio.fs", {
	mkdirr = function() return true end,
	writefile = function() return true end,
	chmod = function() return true end,
	unlink = function() return true end,
	access = function(path)
		return helper_available and
			path == "/usr/sbin/c2000max-app-sim-switch"
	end
})
module("nixio", {
	gettimeofday = function() return 1785693399, 123456 end,
	sysinfo = function() return { uptime = 120 } end
})
module("luci.jsonc", {
	stringify = function() return "{}" end
})
module("luci.sys", {
	uniqueid = function() return "0011223344556677" end,
	call = function(command)
		scheduled_commands[#scheduled_commands + 1] = command
		return 0
	end,
	uptime = function() return 120 end
})
module("luci.util", {
	shellquote = function(value) return "'" .. tostring(value) .. "'" end,
	ubus = function() return {} end,
	exec = function() return "" end
})

local uci = {}
function uci:get(config, section, option)
	if config == "oem" and section == "board" and option == "iccid" then
		return "898600INTERNAL"
	elseif config == "cpesel" and section == "sim" and option == "stype" then
		return "0,0,4"
	end
	return nil
end
function uci:get_all() return {} end
module("luci.model.uci", { cursor = function() return uci end })
module("c2000max_app.identity", {
	get = function() return { device_id = "021122334455" } end
})
module("c2000max_app.rweb", {
	prepare = function() return true end,
	prepare_command = function(command) return command end
})

local sim_requests = {}
local reboot_requests = 0
local core = {
	device_id = function() return "021122334455" end,
	software_version = function() return "9.9.13.n0.c1" end,
	feature_enabled = function(name)
		return name == "terminal_tracking_enable"
	end,
	modems = function()
		return {
			{ status = { iccid = "898600CURRENT", simtype = "0", simno = "2" } }
		}
	end,
	station_status = function()
		return {
			list = { { band = "5.2G", online = 1, servied = 0,
				list = { "AA:BB:CC:DD:EE:FF" }, mac = "02:11:22:33:44:55" } },
			deny = { "" }
		}
	end
}
function core.handle(action, data)
	if action == "cpesel" then
		sim_requests[#sim_requests + 1] = data
		return { code = "0" }
	elseif action == "sms" and data.action == "read" then
		return { code = 0, result = {
			code = 0, ready = 1, smslist = {
				{ contact = "10086", undeal = 0, list = {
					{ index = 7, timestamp = 1785693000, content = "ok",
						role = 0, stat = 1, multi_sms_index = 0 }
				} }
			}
		} }
	elseif action == "client" then
		return { code = "0", result = { client = {
			{ client = "AA:BB:CC:DD:EE:FF", ip = "192.168.1.10" }
		} } }
	elseif action == "cmd" and data.cmd == "reboot" then
		reboot_requests = reboot_requests + 1
		return { code = "0" }
	end
	return { code = "0", result = {} }
end
module("c2000max_app.core", core)

local function equal(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label,
			tostring(expected), tostring(actual)))
	end
end

local cloud = require "c2000max_app.cloud"
local publications = {}
cloud.publish = function(event, payload, reply)
	publications[#publications + 1] = {
		event = event, payload = payload, reply = reply
	}
	return true
end

local switched, event = cloud.handle("simswitch", {
	simswitch = { type = 0, index = 2, mode = 1 }
})
equal(event, "simswitch", "external SIM reply event")
equal(switched.errcode, "0", "external SIM result")
equal(sim_requests[1].cur[1], 2, "external SIM hardware slot")
equal(sim_requests[1].mode[1], 1, "external SIM mode forwarded")

switched = cloud.handle("simswitch", {
	simswitch = { type = 4, index = 1 }
})
equal(switched.errcode, "0", "embedded SIM type-4 result")
equal(sim_requests[2].cur[1], 3, "embedded SIM hardware slot")

switched = cloud.handle("simswitch", {
	simswitch = { type = 1, iccid = "898600INTERNAL" }
})
equal(switched.errcode, "0", "embedded ICCID result")
equal(sim_requests[3].cur[1], 3, "embedded ICCID maps through stype")

local invalid = cloud.handle("simswitch", {})
equal(invalid.errcode, "3", "missing nested SIM request")

local mode_only = cloud.handle("simswitch", {
	simswitch = { type = 99, mode = 0 }
})
equal(mode_only.errcode, "0", "factory mode-only SIM request")
equal(sim_requests[4].mode[1], 0, "mode-only SIM value forwarded")

local invalid_mode = cloud.handle("simswitch", {
	simswitch = { type = 0, index = 1, mode = 7 }
})
equal(invalid_mode.errcode, "3", "invalid SIM mode rejected")

helper_available = true
local scheduled = cloud.handle("simswitch", {
	simswitch = { type = 0, index = 1, mode = 0 }
})
equal(scheduled.errcode, "0", "async external SIM request accepted")
equal(#sim_requests, 4, "async SIM request does not block in core")
equal(scheduled_commands[1],
	"/usr/sbin/c2000max-app-sim-switch external1 0 >/dev/null 2>&1 &",
	"async SIM helper command")
helper_available = false

local sms, sms_event = cloud.handle("sms", {
	action = "read", serial_num = "serial-7"
})
equal(sms_event, "sms", "SMS reply event")
equal(sms.code, 0, "remote SMS result code")
equal(sms.serial_num, "serial-7", "remote SMS serial echo")
equal(sms.result.ready, 1, "remote SMS completion flag")
equal(sms.result.smslist[1].contact, "10086", "remote SMS contact")
equal(sms.trans_id, nil, "remote SMS excludes local APP envelope")

local terminal, terminal_event = cloud.handle("terminal", {})
equal(terminal_event, "terminal", "terminal reply event")
equal(terminal.auth_on, 0, "terminal auth flag is numeric")
equal(terminal.client[1].client, "AA:BB:CC:DD:EE:FF",
	"terminal client list")

local stations, station_event = cloud.handle("stastatus", {})
equal(station_event, "stalist", "station reply uses factory event")
equal(stations.list[1].band, "5.2G", "station radio band")
equal(stations.list[1].list[1], "AA:BB:CC:DD:EE:FF",
	"station association list")

local reboot, reboot_event, reply_expected = cloud.handle("reboot", {})
equal(reboot_event, "reboot", "reboot internal event")
equal(reply_expected, false, "reboot suppresses ordinary reply")
equal(next(reboot), nil, "reboot has no ordinary payload")
equal(reboot_requests, 1, "reboot schedules exactly once")
equal(publications[1].event, "device_info", "reboot state event")
equal(publications[1].payload.state, 6, "reboot state value")
equal(publications[1].reply, true, "reboot state uses reply topic")

print("PASS: official remote SIM, SMS, terminal, station and reboot protocols")
