local root = assert(arg[1], "package root is required")
package.path = root .. "/files/usr/lib/lua/?.lua;" ..
	root .. "/files/usr/lib/lua/?/init.lua;" .. package.path

local fixture_now = 1785148582.123456

io.open = io.open or function()
	return nil
end

local function module(name, value)
	package.loaded[name] = value
	package.preload[name] = function()
		return value
	end
end

module("nixio.fs", {
	readfile = function() return nil end,
	access = function() return false end
})
module("nixio", {
	gettimeofday = function()
		local seconds = math.floor(fixture_now)
		return seconds, math.floor((fixture_now - seconds) * 1000000)
	end,
	sysinfo = function()
		return {
			uptime = 3600,
			totalram = 1024,
			freeram = 512,
			bufferram = 64
		}
	end,
	nanosleep = function() end
})
module("luci.jsonc", {
	parse = function() return nil end,
	stringify = function() return "{}" end
})
module("luci.sys", {
	uptime = function() return 3600 end,
	uniqueid = function(bytes)
		return string.rep("a", bytes * 2)
	end,
	call = function() return 0 end
})

local modem_info = {
	{ key = "name", value = "MT5700M-CN", full_name = "Name" },
	{ key = "manufacturer", value = "TD Tech Ltd.",
		full_name = "Manufacturer" },
	{ key = "revision", value = "V200R001C20B024",
		full_name = "Revision" },
	{ key = "connect_status", value = "Yes",
		full_name = "Connect Status" },
	{ key = "temperature", value = "57 °C",
		full_name = "Temperature" },
	{ key = "network_mode", value = "NR5G-SA Mode",
		full_name = "Network Mode" },
	{ key = "Cell ID", value = "52152987650", full_name = "Cell ID" },
	{ key = "Physical Cell ID", value = "896",
		full_name = "Physical Cell ID" },
	{ key = "TAC", value = "143076",
		full_name = "Tracking area code of cell served by neighbor Enb" },
	{ key = "ARFCN", value = "504990",
		full_name = "Absolute Radio-Frequency Channel Number" },
	{ key = "DL Bandwidth", value = "100000",
		full_name = "DL Bandwidth" },
	{ key = "UL Bandwidth", value = "100000",
		full_name = "UL Bandwidth" },
	{ key = "CQI", value = "9",
		full_name = "Channel Quality Indicator" },
	{ key = "NR5G AMBR DL", value = "1000000",
		full_name = "NR5G AMBR DL" },
	{ key = "NR5G AMBR UL", value = "200000",
		full_name = "NR5G AMBR UL" },
	{ key = "RSRP", value = "-84",
		full_name = "Reference Signal Received Power" },
	{ key = "RSRQ", value = "-11",
		full_name = "Reference Signal Received Quality" },
	{ key = "SINR", value = "7",
		full_name = "Signal to Interference plus Noise Ratio Bandwidth" }
}

local sim_info = {
	{ key = "SIM Status", value = "ready", full_name = "SIM Status" },
	{ key = "SIM Slot", value = "0", full_name = "SIM Slot" },
	{ key = "IMEI", value = "861464060144967",
		full_name = "International Mobile Equipment Identity" },
	{ key = "IMSI", value = "460022891828033",
		full_name = "International Mobile Subscriber Identity" }
}

local active_slot = "external2"
local sim_switch_calls = 0
local fast_signal_calls = 0
local carrier_signal_calls = 0
local serialized_at_calls = 0
local neighbor_signal_calls = 0
local lock_commands = {}
local last_exec = ""
local client_neighbor = false
local wireless_mlo_fixture = false
local fast_signal_should_fail = false
local monsc_earfcn = "504990"
local carrier_response = "^HFREQINFO: 0,7," ..
	"41,504990,2524950,100000,504990,2524950,100000," ..
	"41,500000,2500000,80000,500000,2500000,40000," ..
	"41,530000,2650000,60000,530000,2650000,30000\r\nOK"
local fast_signal_values = {
	{ rsrp = "-82", rsrq = "-9", sinr = "11" },
	{ rsrp = "-80", rsrq = "-8", sinr = "13" },
	{ rsrp = "-78", rsrq = "-7", sinr = "15" },
	{ rsrp = "-77", rsrq = "-6", sinr = "16" },
	{ rsrp = "-76", rsrq = "-5", sinr = "17" }
}
local nr_lock_response = table.concat({
	"^NRFREQLOCK: 2", "0,1", "41,504990,1,896", "OK"
}, "\r\n")
local lte_lock_response = "^LTEFREQLOCK: 0\r\nOK"
local network_acquisition = "080302"
local network_option = "1,1,1"

local function selector_status(extra)
	local value = {
		iccid = "898600C82525CA018033",
		current_slot = active_slot,
		configured_slot = active_slot,
		carrier = "中国移动",
		at_port = "/dev/ttyUSB1"
	}
	if type(extra) == "table" then
		for key, item in pairs(extra) do
			value[key] = item
		end
	end
	return value
end

local function ubus(object, method, args)
	if object == "c2000max" and method == "sim_status" then
		return selector_status()
	elseif object == "c2000max" and method == "sim_switch" then
		sim_switch_calls = sim_switch_calls + 1
		active_slot = assert(args and args.slot, "missing serialized SIM slot")
		return selector_status({ success = true, message = "ok" })
	elseif object == "qmodem" and method == "info" then
		return { modem_info = modem_info }
	elseif object == "qmodem" and method == "network_info" then
		-- This is deliberately empty: the real MT5700M-CN output places
		-- radio metrics in qmodem.info rather than qmodem.network_info.
		return { modem_info = {} }
	elseif object == "qmodem" and method == "sim_info" then
		return { modem_info = sim_info }
	elseif object == "qmodem" and method == "get_sms" then
		return {
			msg = {
				{ index = 7, sender = "10086", timestamp = 1785148000,
					content = "balance" },
				{ index = 8, sender = "10010", timestamp = 1785148100,
					content = "welcome", reference = 12, total = 2, part = 1 }
			},
			sms_capabilities = {
				mem1 = "ME", ME = { used = "2", total = "255" }
			}
		}
	elseif object == "qmodem" and method == "delete_sms" then
		assert(args and args.index == "7 8", "normalized delete SMS ids")
		return { result = { status = "1" } }
	elseif object == "qmodem" and method == "send_sms" then
		assert(args and args.params and args.params.phone_number == "10086",
			"normalized send SMS phone")
		assert(args.params.message_content == "hello",
			"normalized send SMS content")
		return { result = { status = "1" } }
	elseif object == "qmodem" and method == "send_at" then
		serialized_at_calls = serialized_at_calls + 1
		assert(args and args.config_section == "2_1",
			"fast signal QModem section")
		assert(args and args.params and
			args.params.port == "/dev/ttyUSB1",
			"fast signal serialized port")
		assert(args and args.params and
			args.params.use_ubus_flag == "1",
			"fast signal ubus serialization flag")
		local command = args.params.at
		if command == "AT^HFREQINFO?" then
			carrier_signal_calls = carrier_signal_calls + 1
			return {
				at_cfg = {
					status = "1",
					res = carrier_response
				}
			}
		end
		if command == "AT^MONNC" then
			neighbor_signal_calls = neighbor_signal_calls + 1
			return { at_cfg = { status = "1", res = table.concat({
				"^MONNC: NR,504990,380,-656,-112,160",
				"^MONNC: LTE,1650,12A,-93,-12,-65",
				"OK"
			}, "\r\n") } }
		elseif command == "AT^NRFREQLOCK?" then
			return { at_cfg = { status = "1", res = nr_lock_response } }
		elseif command == "AT^LTEFREQLOCK?" then
			return { at_cfg = { status = "1", res = lte_lock_response } }
		elseif command == "AT^SYSCFGEX?" then
			return { at_cfg = { status = "1", res =
				'^SYSCFGEX: "' .. network_acquisition ..
				'",40000000,1,2,40000000,,\r\nOK' } }
		elseif command == "AT^C5GOPTION?" then
			return { at_cfg = { status = "1", res =
				"^C5GOPTION: " .. network_option .. "\r\nOK" } }
		elseif command == "AT+CFUN=0" or command == "AT+CFUN=1" then
			lock_commands[#lock_commands + 1] = command
			return { at_cfg = { status = "1", res = "OK" } }
		elseif command:match("^AT%^SYSCFGEX=") then
			network_acquisition = assert(command:match('^AT%^SYSCFGEX="([^"]+)"'),
				"network acquisition command")
			lock_commands[#lock_commands + 1] = command
			return { at_cfg = { status = "1", res = "OK" } }
		elseif command:match("^AT%^C5GOPTION=") then
			network_option = assert(command:match("^AT%^C5GOPTION=(.+)$"),
				"network option command")
			lock_commands[#lock_commands + 1] = command
			return { at_cfg = { status = "1", res = "OK" } }
		elseif command:match("^AT%^NRFREQLOCK=") or
		       command:match("^AT%^LTEFREQLOCK=") then
			lock_commands[#lock_commands + 1] = command
			return { at_cfg = { status = "1", res = "OK" } }
		end
		assert(command == "AT^MONSC", "unexpected serialized AT command")
		fast_signal_calls = fast_signal_calls + 1
		if fast_signal_should_fail then
			return { at_cfg = { status = "0" } }
		end
		local value = fast_signal_values[fast_signal_calls] or
			fast_signal_values[#fast_signal_values]
		return {
			at_cfg = {
				status = "1",
				res = string.format(
					"^MONSC: NR,460,00,%s,1,C248F7002,380,143076,%s,%s,%s\r\nOK",
					monsc_earfcn, value.rsrp, value.rsrq, value.sinr)
			}
		}
	end
	return {}
end

module("luci.util", {
	ubus = ubus,
	exec = function(command)
		last_exec = tostring(command or "")
		if wireless_mlo_fixture and last_exec == "iw dev 2>/dev/null" then
			return table.concat({
				"phy#0", "\tInterface ra0", "\t\taddr 02:11:22:33:44:55",
				"\t\tssid ImmortalWrt-MLO", "\t\ttype AP",
				"\t\tchannel 6 (2437 MHz), width: 40 MHz",
				"phy#1", "\tInterface rai0", "\t\taddr 02:66:77:88:99:AA",
				"\t\tssid ImmortalWrt-MLO", "\t\ttype AP",
				"\t\tchannel 36 (5180 MHz), width: 160 MHz"
			}, "\n") .. "\n"
		elseif wireless_mlo_fixture and last_exec:find("iw dev ra0 station dump", 1, true) then
			return table.concat({
				"Station 12:34:56:78:9A:BC (on ra0)",
				"\trx bytes: 100", "\ttx bytes: 200", "\tsignal: -52 dBm",
				"\trx bitrate: 100.0 MBit/s", "\ttx bitrate: 80.0 MBit/s",
				"\tconnected time: 30 seconds", "\tMLD address: AA:BB:CC:DD:EE:FF"
			}, "\n") .. "\n"
		elseif wireless_mlo_fixture and last_exec:find("iw dev rai0 station dump", 1, true) then
			return table.concat({
				"Station 22:34:56:78:9A:BC (on rai0)",
				"\trx bytes: 300", "\ttx bytes: 400", "\tsignal: -61 dBm",
				"\trx bitrate: 200.0 MBit/s", "\ttx bitrate: 160.0 MBit/s",
				"\tconnected time: 31 seconds", "\tmld addr: AA:BB:CC:DD:EE:FF"
			}, "\n") .. "\n"
		elseif wireless_mlo_fixture and last_exec == "ip -o link show 2>/dev/null" then
			return "5: ra0: <UP> link/ether 02:11:22:33:44:55 brd ff:ff:ff:ff:ff:ff\n" ..
				"6: rai0: <UP> link/ether 02:66:77:88:99:AA brd ff:ff:ff:ff:ff:ff\n"
		end
		if client_neighbor and last_exec:find("ip neigh show dev br%-lan") then
			if wireless_mlo_fixture then
				return "192.168.1.10 dev br-lan lladdr AA:BB:CC:DD:EE:FF REACHABLE\n" ..
					"192.168.1.1 dev br-lan lladdr 02:11:22:33:44:55 STALE\n" ..
					"224.0.0.1 dev br-lan lladdr 01:00:5E:00:00:01 REACHABLE\n"
			end
			return "192.168.1.10 dev br-lan lladdr AA:BB:CC:DD:EE:FF REACHABLE\n"
		end
		return ""
	end,
	shellquote = function(value) return tostring(value) end
})

local app_options = {
	signal_report_enable = "1",
	cellular_record_enable = "0",
	local_signal_enable = "1",
	local_client_enable = "1",
	local_network_write_enable = "1",
	sim_mode = "1",
	modem_cache_interval = "10",
	selector_cache_interval = "15",
	cache_warm_interval = "2"
}
local access_control
local access_devices = {}
local wireless = {
	radio0 = { [".name"] = "radio0", [".type"] = "wifi-device",
		channel = "auto" },
	radio1 = { [".name"] = "radio1", [".type"] = "wifi-device",
		channel = "37" },
	default_radio0 = { [".name"] = "default_radio0",
		[".type"] = "wifi-iface", mode = "ap", device = "radio0",
		ssid = "WRT-IOT", key = "old-password", encryption = "sae-mixed",
		hidden = "0", disabled = "0" },
	default_radio1 = { [".name"] = "default_radio1",
		[".type"] = "wifi-iface", mode = "ap", device = "radio1",
		ssid = "WRT6G", key = "old-password", encryption = "sae",
		hidden = "0", disabled = "0" }
}
local uci = {}
function uci:get(config, section, option)
	if config == "c2000max_app" and section == "main" then
		return app_options[option] or "0"
	elseif config == "dhcp" and section == "@dnsmasq[0]" and option == "leasefile" then
		return "/tmp/c2000max-app-fixture.leases"
	elseif config == "wireless" and wireless[section] then
		return wireless[section][option]
	elseif config == "c2000max" and section == "access_control" and access_control then
		return access_control[option]
	elseif config == "c2000max" and access_devices[section] then
		return access_devices[section][option]
	end
	return nil
end
function uci:set(config, section, option, value)
	if config == "c2000max_app" and section == "main" then
		app_options[option] = tostring(value)
		return true
	elseif config == "wireless" and wireless[section] then
		wireless[section][option] = tostring(value)
		return true
	elseif config == "c2000max" and section == "access_control" and access_control then
		access_control[option] = tostring(value)
		return true
	elseif config == "c2000max" and access_devices[section] then
		access_devices[section][option] = tostring(value)
		return true
	end
	return false
end
function uci:delete(config, section, option)
	if config == "wireless" and wireless[section] then
		wireless[section][option] = nil
		return true
	end
	return false
end
function uci:load()
	return true
end
function uci:section(config, section_type, name, values)
	if config ~= "c2000max" then return nil end
	values = values or {}
	values[".name"] = name
	values[".type"] = section_type
	if name == "access_control" then
		access_control = values
	else
		access_devices[name] = values
	end
	return name
end
function uci:commit()
	return true
end
function uci:revert()
	return true
end
function uci:get_all()
	return {}
end
function uci:foreach(config, section_type, callback)
	if config == "qmodem" and section_type == "modem-device" then
		callback({
			[".name"] = "2_1",
			state = "enabled",
			model = "mt5700m-cn",
			manufacturer = "huawei",
			network_interface = "eth2"
		})
	elseif config == "wireless" and section_type == "wifi-iface" then
		callback(wireless.default_radio0)
		callback(wireless.default_radio1)
	elseif config == "c2000max" and section_type == "access_device" then
		for _, section in pairs(access_devices) do
			callback(section)
		end
	end
end

module("luci.model.uci", {
	cursor = function() return uci end
})
module("c2000max_app.identity", {
	get = function()
		return {
			device_id = "021122334455",
			device_code = nil
		}
	end,
	public_status = function()
		return { device_id = "021122334455" }
	end
})

local real_io_open = io.open
io.open = function(path, mode)
	if path == "/tmp/c2000max-app-fixture.leases" then
		local lines = {
			"1786000000 AA:BB:CC:DD:EE:FF 192.168.1.10 phone *",
			"1785000000 DE:AD:BE:EF:00:02 192.168.1.99 expired *"
		}
		local index = 0
		return {
			lines = function()
				return function()
					index = index + 1
					return lines[index]
				end
			end,
			close = function() end
		}
	end
	return real_io_open(path, mode)
end

local function equal(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label,
			tostring(expected), tostring(actual)))
	end
end

local core = require "c2000max_app.core"
local refresh = core.signal_refresh_policy()
equal(refresh.normal, 3, "ordinary signal refresh interval")
equal(refresh.test, 1, "signal-test refresh interval")
equal(refresh.carrier, 10, "carrier topology refresh interval")
equal(refresh.backend, "qmodem-serialized-single-at",
	"fast signal backend")
equal(refresh.carrier_backend, "qmodem-serialized-hfreqinfo",
	"carrier topology backend")

local result = core.handle("signal", { trans_id = "fixture" })
local signal = assert(result.signal and result.signal[1],
	"missing normalized signal")

equal(result.code, "0", "signal result code")
equal(signal.real_name, "MT5700M-CN", "modem model")
equal(signal.driver, "TD Tech Ltd.", "modem manufacturer")
equal(signal.mode, "NR SA", "APP-compatible network mode")
equal(signal.imei, "861464060144967", "IMEI")
equal(signal.imsi, "460022891828033", "IMSI")
equal(signal.isp, "46002", "APP numeric operator PLMN")
equal(signal.sim_isp, "中国移动", "human-readable operator fallback")
equal(signal.iccid, "898600C82525CA018033", "ICCID selector fallback")
equal(signal.cellid, "52152987650", "cell id")
equal(signal.pci, "896", "physical cell id")
equal(signal.tac, "143076", "tracking area")
equal(signal.earfcn, "504990", "ARFCN")
equal(signal.band, "41", "unambiguous n41 inference")
equal(signal.band_count, 3, "three-carrier aggregation count")
equal(signal.DLBW, "100000", "APP DLBW key and kHz unit")
equal(signal.ULBW, "100000", "APP ULBW key and kHz unit")
equal(signal.band1, "41", "second carrier band")
equal(signal.dl_fcn1, "500000", "second carrier downlink channel")
equal(signal.ul_fcn1, "500000", "second carrier uplink channel")
equal(signal.DLBW1, "80000", "second carrier downlink bandwidth")
equal(signal.ULBW1, "40000", "second carrier uplink bandwidth")
equal(signal.band2, "41", "third carrier band")
equal(signal.dl_fcn2, "530000", "third carrier downlink channel")
equal(signal.ul_fcn2, "530000", "third carrier uplink channel")
equal(signal.DLBW2, "60000", "third carrier downlink bandwidth")
equal(signal.ULBW2, "30000", "third carrier uplink bandwidth")
equal(signal.CQI, "9", "APP CQI key")
equal(signal.NR5G_AMBR_DL, "1000000", "APP downlink AMBR")
equal(signal.NR5G_AMBR_UL, "200000", "APP uplink AMBR")
equal(signal.rsrp, "-82", "fresh ordinary RSRP")
equal(signal.rsrq, "-9", "fresh ordinary RSRQ")
equal(signal.sinr, "11", "fresh ordinary SINR")
equal(signal.netlink, 1, "network registration")
equal(signal.nrcap, "1", "NR capability")
equal(signal.simtype, "0", "external SIM type for remote APP")
equal(signal.simno, "2", "external SIM index for remote APP")
equal(signal.using, true, "active modem")
equal(signal.cpeno, 1, "CPE index")
equal(fast_signal_calls, 1, "initial ordinary MONSC count")
equal(carrier_signal_calls, 1, "initial HFREQINFO count")

local cached_normal = core.handle("signal", { trans_id = "cached-normal" })
equal(cached_normal.signal[1].rsrp, "-82", "ordinary cached RSRP")
equal(fast_signal_calls, 1, "ordinary immediate cache suppresses MONSC")
equal(carrier_signal_calls, 1,
	"ordinary immediate cache suppresses HFREQINFO")

fixture_now = fixture_now + 2.9
core.handle("signal", { trans_id = "normal-before-limit" })
equal(fast_signal_calls, 1, "ordinary cache lasts three seconds")

fixture_now = fixture_now + 0.2
local refreshed_normal = core.handle("signal", {
	trans_id = "normal-after-limit"
})
equal(refreshed_normal.signal[1].rsrp, "-80",
	"ordinary signal refreshes after three seconds")
equal(fast_signal_calls, 2, "ordinary MONSC refresh count")
equal(carrier_signal_calls, 1,
	"carrier topology remains cached for ten seconds")

local focused = core.handle("signal", {
	trans_id = "focused",
	at_signal = 1,
	index = 1
})
equal(focused.at_signal.band, "41", "focused signal band")
equal(focused.at_signal.cell, "52152987650", "focused signal cell")
equal(focused.at_signal.earfcn, "504990", "focused signal EARFCN")
equal(focused.at_signal.pci, "896", "focused signal PCI")
equal(focused.at_signal.rsrp, "-80", "focused cached RSRP")
equal(focused.at_signal.rsrq, "-8", "focused cached RSRQ")
equal(focused.at_signal.sinr, "13", "focused cached SINR")
equal(focused.at_signal.tac, "143076", "focused signal TAC")
equal(fast_signal_calls, 2,
	"focused mode reuses a sub-second ordinary sample")

fixture_now = fixture_now + 1.1
focused = core.handle("signal", {
	trans_id = "focused-after-limit",
	at_signal = 1,
	index = 1
})
equal(focused.at_signal.rsrp, "-78",
	"focused signal refreshes after one second")
equal(fast_signal_calls, 3, "focused MONSC refresh count")

fast_signal_should_fail = true
fixture_now = fixture_now + 1.1
focused = core.handle("signal", {
	trans_id = "focused-failure",
	at_signal = 1,
	index = 1
})
equal(focused.at_signal.rsrp, "-78",
	"failed MONSC preserves the last valid sample")
equal(fast_signal_calls, 4, "failed MONSC attempt count")

fixture_now = fixture_now + 1.1
core.handle("signal", {
	trans_id = "focused-backoff",
	at_signal = 1,
	index = 1
})
equal(fast_signal_calls, 4, "failed MONSC applies five-second backoff")

fast_signal_should_fail = false
fixture_now = fixture_now + 4.0
focused = core.handle("signal", {
	trans_id = "focused-recovered",
	at_signal = 1,
	index = 1
})
equal(focused.at_signal.rsrp, "-76", "focused MONSC recovers")
equal(fast_signal_calls, 5, "recovered MONSC attempt count")

local refreshed_carriers = core.handle("signal", {
	trans_id = "carrier-after-limit"
})
equal(refreshed_carriers.signal[1].band_count, 3,
	"carrier aggregation remains exact after refresh")
equal(carrier_signal_calls, 2,
	"HFREQINFO refreshes after ten seconds")
equal(serialized_at_calls, fast_signal_calls + carrier_signal_calls,
	"all fast radio queries use the serialized QModem path")

-- Replay the exact dual-n78 CA topology from the captured official response.
-- This also proves that a previous third carrier is removed instead of being
-- left behind as stale data when aggregation shrinks from 3CC to 2CC.
carrier_response = "^HFREQINFO: 0,7," ..
	"78,636664,3183320,100000,636664,3183320,100000," ..
	"78,630000,3150000,100000,630000,3150000,100000\r\nOK"
monsc_earfcn = "633984"
fixture_now = fixture_now + 10.1
local official_ca = core.handle("signal", { trans_id = "official-ca" })
local official_signal = official_ca.signal[1]
equal(official_signal.earfcn, "633984", "official CA serving ARFCN")
equal(official_signal.band_count, 2, "official dual-carrier count")
equal(official_signal.band, "78", "official primary carrier band")
equal(official_signal.dl_fcn, "636664",
	"official primary downlink channel")
equal(official_signal.DLBW, "100000",
	"official primary downlink bandwidth")
equal(official_signal.ULBW, "100000",
	"official primary uplink bandwidth")
equal(official_signal.band1, "78", "official secondary carrier band")
equal(official_signal.dl_fcn1, "630000",
	"official secondary downlink channel")
equal(official_signal.DLBW1, "100000",
	"official secondary downlink bandwidth")
equal(official_signal.ULBW1, "100000",
	"official secondary uplink bandwidth")
equal(official_signal.band2, nil, "stale third carrier band is removed")
equal(official_signal.DLBW2, nil,
	"stale third carrier bandwidth is removed")
equal(carrier_signal_calls, 3, "official CA topology refresh count")

focused = core.handle("signal", {
	trans_id = "official-ca-focused",
	at_signal = 1,
	index = 1
})
equal(focused.at_signal.band, "78",
	"focused mode reuses verified CA primary band")
equal(carrier_signal_calls, 3,
	"focused mode never adds an HFREQINFO query")

local ordinary_fast_before = fast_signal_calls
local ordinary_carrier_before = carrier_signal_calls
for request = 1, 120 do
	fixture_now = fixture_now + 1.5
	core.handle("signal", { trans_id = "ordinary-budget-" .. request })
end
equal(fast_signal_calls - ordinary_fast_before, 60,
	"three minutes ordinary mode stays at twenty MONSC per minute")
equal(carrier_signal_calls - ordinary_carrier_before, 17,
	"three minutes ordinary mode stays below six HFREQINFO per minute")

local focused_fast_before = fast_signal_calls
local focused_carrier_before = carrier_signal_calls
for request = 1, 120 do
	fixture_now = fixture_now + 1.5
	core.handle("signal", {
		trans_id = "focused-budget-" .. request,
		at_signal = 1,
		index = 1
	})
end
equal(fast_signal_calls - focused_fast_before, 120,
	"three minutes focused mode follows each 1.5-second APP poll")
equal(carrier_signal_calls - focused_carrier_before, 0,
	"focused mode adds no CA topology queries")
equal(serialized_at_calls, fast_signal_calls + carrier_signal_calls,
	"refresh budget contains only serialized MONSC and HFREQINFO")

local info = core.handle("info", { trans_id = "info", type = "all" })
equal(info.result.basic.mac, "021122334455", "APP factory identity")
equal(info.result.basic.version, "9.9.13.n0.c1", "fixed APP software version")
equal(info.result.basic.modem_cnt, 1, "APP modem count")
equal(info.result.basic.active_modem[1], 1, "APP active modem")
equal(info.result.cpesel[1].cur, 2, "APP active SIM number")
equal(info.result.cpesel[1].mode, 1, "APP persisted manual SIM mode")
equal(info.result.cpesel[1].max, "3", "APP SIM count")
equal(info.result.cellular[1].earfcn, "504990", "APP cellular EARFCN")
equal(info.result.cellular[1].blacklist_band, "79",
	"MT5700 APP blacklist band metadata")
equal(info.result.cellular[1].freq_val,
	"nr-78:41:79:28:1:8:5:3,lte-1:3:5:8:34:38:39:40:41",
	"MT5700 APP band selector metadata")
equal(info.result.diagnosis.list[1].isp, "46002",
	"APP diagnosis exposes numeric operator PLMN")

app_options.local_wifi_enable = "1"
local wifi = core.handle("wifi", {
	trans_id = "wifi-write",
	list = {
		{
			ruleName = "wlan0",
			ssid = "WRT-IOT-NEW",
			password = "new-password-123",
			encryption = "sae-mixed+ccmp",
			hidden = false,
			disabled = false,
			channel = "6",
			max_link = 64
		}
	}
})
equal(wifi.code, "0", "Wi-Fi write result code")
equal(wireless.default_radio0.ssid, "WRT-IOT-NEW",
	"APP wlan0 alias resolves to first OpenWrt AP")
equal(wireless.default_radio0.key, "new-password-123",
	"Wi-Fi password is committed")
equal(wireless.default_radio0.encryption, "sae-mixed+ccmp",
	"MediaTek cipher-suffixed encryption is accepted")
equal(wireless.default_radio0.maxassoc, "64",
	"Wi-Fi station limit is committed")
equal(wireless.radio0.channel, "6", "Wi-Fi channel is committed")
equal(last_exec,
	"/usr/sbin/c2000max-app-wifi-apply >/dev/null 2>&1 &",
	"Wi-Fi reload is queued after the response")
equal(wifi.result.list[1].password, "new-password-123",
	"Wi-Fi response reflects the committed password")

local neighbour = core.handle("neighbour", {
	trans_id = "neighbour"
})
local cells = assert(neighbour.result and neighbour.result.neighbour and
	neighbour.result.neighbour[1], "missing APP neighbour array")
equal(neighbour.code, "0", "neighbour search result code")
equal(#cells, 2, "neighbour search cell count")
equal(cells[1].MODE, "NR", "NR neighbour mode")
equal(cells[1].BAND, "41", "NR neighbour band")
equal(cells[1].EARFCN, "504990", "NR neighbour ARFCN")
equal(cells[1].PCI, "896", "NR neighbour hexadecimal PCI conversion")
equal(cells[1].RSRP, "-82", "NR encoded RSRP conversion")
equal(cells[1].RSRQ, "-14", "NR encoded RSRQ conversion")
equal(cells[1].SINR, "20", "NR encoded SINR conversion")
equal(cells[2].MODE, "LTE", "LTE neighbour mode")
equal(cells[2].BAND, "3", "LTE neighbour band")
equal(cells[2].PCI, "298", "LTE neighbour hexadecimal PCI conversion")
equal(neighbor_signal_calls, 1, "neighbour scan uses one serialized MONNC")

local sms = core.handle("sms", {
	trans_id = "sms",
	index = "1",
	sim = "2"
})
equal(sms.code, 0, "IMS query result code")
equal(sms.result.enabled, "0", "IMS query state")
equal(sms.result.sim, 2, "IMS query SIM")

local sms_read = core.handle("sms", {
	trans_id = "sms-read", action = "read", type = "ME"
})
equal(sms_read.code, 0, "SMS read result code")
equal(sms_read.result.ready, 1, "SMS read completion flag")
equal(sms_read.result.total, 255, "SMS storage capacity")
equal(sms_read.result.count, 2, "SMS message count")
equal(sms_read.result.smslist[1].contact, "10010",
	"SMS conversations sort newest first")
equal(sms_read.result.smslist[1].list[1].multi_sms_index, 1,
	"multipart SMS index is preserved")
equal(sms_read.result.smslist[2].contact, "10086",
	"SMS sender maps to APP contact")

local sms_new = core.handle("sms", {
	trans_id = "sms-new", action = "read", type = "new"
})
equal(sms_new.result.smslist[1].contact, "10010",
	"new-SMS query returns the flat APP callback shape")
equal(sms_new.result.smslist[1].list, nil,
	"new-SMS item is not wrapped in a conversation")

local sms_deleted = core.handle("sms", {
	trans_id = "sms-delete", action = "del", ids = "7,8"
})
equal(sms_deleted.code, 0, "SMS delete result code")
equal(sms_deleted.smsdel[1].index, 7, "SMS delete first index")
equal(sms_deleted.smsdel[2].code, 0, "SMS delete per-item result")

local sms_sent = core.handle("sms", {
	trans_id = "sms-send", action = "send", phone_num = "10086",
	msg = "hello"
})
equal(sms_sent.code, 0, "SMS send result code")
equal(sms_sent.item[1].code, 0, "SMS send per-item result")

local earfcn = core.handle("earfcn", {
	trans_id = "earfcn",
	action = "2",
	index = "1"
})
equal(earfcn.code, "0", "frequency query result code")
equal(earfcn.result.action, 2, "frequency query action")
equal(earfcn.result.earfcn[1].MODE, "NR", "frequency query NR row")
equal(earfcn.result.earfcn[2].MODE, "LTE", "frequency query LTE row")
equal(earfcn.result.earfcn[1].status, "1", "NR lock query state")
equal(earfcn.result.earfcn[1].EARFCN, "504990", "NR lock query ARFCN")
equal(earfcn.result.earfcn[1].PCI, "896", "NR lock query PCI")
equal(earfcn.result.earfcn[1].BAND, "41", "NR lock query band")
equal(earfcn.result.mode, "auto", "configured network mode query")

nr_lock_response = table.concat({
	"^NRFREQLOCK: 3", "0,2", '"78,41"', "OK"
}, "\r\n")
lte_lock_response = table.concat({
	"^LTEFREQLOCK: 3", "0,2", '"3,41"', "OK"
}, "\r\n")
local band_status = core.handle("earfcn", {
	trans_id = "band-status", action = "2", index = "1"
})
equal(band_status.result.earfcn[1].status, "0",
	"NR band lock is not misreported as a cell lock")
equal(band_status.result.earfcn[2].status, "0",
	"LTE band lock is not misreported as a cell lock")
equal(band_status.result.band.status, "1", "APP band lock state")
equal(band_status.result.band.freq, "nr-78:41,lte-3:41",
	"APP multi-band lock value")

lock_commands = {}
local bands_locked = core.handle("earfcn", {
	trans_id = "multi-band-lock", action = 1, index = "1",
	band = {
		enabled = "1",
		freq = "nr-78:41:79:28:1:8:5:3,lte-1:3:5:8:34:38:39:40:41"
	}
})
equal(bands_locked.code, "0", "multi-band lock result code")
equal(lock_commands[1], "AT+CFUN=0", "multi-band lock enters airplane mode")
equal(lock_commands[2],
	'AT^NRFREQLOCK=3,0,8,"78,41,79,28,1,8,5,3"',
	"all selected NR bands are applied in one MT5700 command")
equal(lock_commands[3],
	'AT^LTEFREQLOCK=3,0,9,"1,3,5,8,34,38,39,40,41"',
	"all selected LTE bands are applied in one MT5700 command")
equal(lock_commands[4], "AT+CFUN=1", "multi-band lock leaves airplane mode")

nr_lock_response = table.concat({
	"^NRFREQLOCK: 2", "0,2",
	"41,504990,1,896", "78,633984,1,334", "OK"
}, "\r\n")
lte_lock_response = "^LTEFREQLOCK: 0\r\nOK"
local multi_cell_status = core.handle("earfcn", {
	trans_id = "multi-cell-status", action = "2", index = "1"
})
equal(#multi_cell_status.result.earfcn, 3,
	"multi-cell query returns every lock plus the LTE state")
equal(multi_cell_status.result.earfcn[1].MODE, "NR",
	"multi-cell query first NR mode")
equal(multi_cell_status.result.earfcn[1].PCI, "896",
	"multi-cell query first NR PCI")
equal(multi_cell_status.result.earfcn[2].MODE, "NR",
	"multi-cell query second NR mode")
equal(multi_cell_status.result.earfcn[2].EARFCN, "633984",
	"multi-cell query second NR EARFCN")
equal(multi_cell_status.result.earfcn[2].PCI, "334",
	"multi-cell query second NR PCI")
equal(multi_cell_status.result.earfcn[3].MODE, "LTE",
	"multi-cell query preserves the LTE state row")

nr_lock_response = table.concat({
	"^NRFREQLOCK: 2", "0,1", "41,504990,1,896", "OK"
}, "\r\n")
lte_lock_response = "^LTEFREQLOCK: 0\r\nOK"

app_options.local_network_write_enable = "0"
local allowed = core.local_action_allowed("earfcn", {
	action = 1,
	earfcns = { { enabled = "1", MODE = "NR", BAND = "41",
		EARFCN = "504990", PCI = "896" } }
})
equal(allowed, false, "cell lock requires local network write permission")
app_options.local_network_write_enable = "1"

lock_commands = {}
local single_cell_locked = core.handle("earfcn", {
	trans_id = "single-cell-lock", action = 1, index = "1",
	earfcns = {
		{ enabled = "1", MODE = "NR5G", BAND = "41",
			EARFCN = "504990", PCI = "896" },
		{ enabled = "0", MODE = "LTE", BAND = "", EARFCN = "", PCI = "" }
	}
})
equal(single_cell_locked.code, "0", "single-cell lock remains compatible")
equal(lock_commands[1], "AT+CFUN=0", "single-cell lock enters airplane mode")
equal(lock_commands[2],
	'AT^NRFREQLOCK=2,0,1,"41","504990","1","896"',
	"single-cell lock keeps the existing MT5700 NR command")
equal(lock_commands[3], "AT^LTEFREQLOCK=0",
	"single-cell request still explicitly unlocks disabled LTE")
equal(lock_commands[4], "AT+CFUN=1", "single-cell lock leaves airplane mode")

lock_commands = {}
local locked = core.handle("earfcn", {
	trans_id = "multi-cell-lock",
	action = 1,
	index = "1",
	band = { enabled = "0", freq = "" },
	earfcns = {
		{ enabled = "1", MODE = "NR5G", BAND = "41",
			EARFCN = "504990", PCI = "896" },
		{ enabled = "1", MODE = "NR", BAND = "78",
			EARFCN = "633984", PCI = "334" },
		{ enabled = "1", MODE = "LTE", BAND = "3",
			EARFCN = "1650", PCI = "298" },
		{ enabled = "1", MODE = "LTE", BAND = "41",
			EARFCN = "40000", PCI = "123" }
	}
})
equal(locked.code, "0", "multi-cell lock result code")
equal(lock_commands[1], "AT+CFUN=0", "multi-cell lock enters airplane mode")
equal(lock_commands[2],
	'AT^NRFREQLOCK=2,0,2,"41,78","504990,633984","1,1","896,334"',
	"all selected NR cells are applied in one MT5700 command")
equal(lock_commands[3],
	'AT^LTEFREQLOCK=2,0,2,"3,41","1650,40000","298,123"',
	"all selected LTE cells are applied in one MT5700 command")
equal(lock_commands[4], "AT+CFUN=1", "multi-cell lock leaves airplane mode")

lock_commands = {}
local mode_changed = core.handle("earfcn", {
	trans_id = "network-mode", index = "1", mode = "nsa"
})
equal(mode_changed.code, "0", "network mode result code")
equal(lock_commands[1], "AT+CFUN=0",
	"network mode enters airplane mode")
equal(lock_commands[2],
	'AT^SYSCFGEX="080302",40000000,1,2,40000000,,',
	"network mode preserves Huawei SYSCFGEX fields")
equal(lock_commands[3], "AT^C5GOPTION=0,1,0",
	"network mode applies NSA preference")
equal(lock_commands[4], "AT+CFUN=1",
	"network mode leaves airplane mode")
equal(mode_changed.result.mode, "nsa",
	"network mode response reflects configured NSA preference")

local wifiauth = core.handle("wifiauth", {
	trans_id = "wifiauth"
})
equal(wifiauth.code, nil, "Wi-Fi auth response has no code field")
equal(wifiauth.wifiauth, -1, "Wi-Fi auth unsupported state")

local service = core.handle("cmd", {
	trans_id = "service",
	cmd = "service",
	name = "cellular_record",
	enabled = 1
})
equal(service.code, 0, "cellular record result code")
equal(service.enabled, 1, "cellular record enabled state")
equal(app_options.cellular_record_enable, "1", "cellular record UCI state")

local switched = core.handle("cpesel", {
	trans_id = "switch",
	cur = { 3 },
	mode = { 1 }
})
equal(switched.code, "0", "SIM switch result code")
equal(switched.result.cpesel[1].cur, 3, "SIM switch APP slot")
equal(active_slot, "internal", "SIM switch serialized target")
equal(sim_switch_calls, 1, "SIM switch call count")
equal(app_options.sim_mode, "1", "manual SIM mode persisted")

local automatic = core.handle("cpesel", {
	trans_id = "automatic-mode",
	mode = { 0 }
})
equal(automatic.code, "0", "automatic SIM mode result code")
equal(automatic.result.cpesel[1].mode, 0,
	"automatic SIM mode reflected in APP response")
equal(app_options.sim_mode, "0", "automatic SIM mode persisted")
equal(sim_switch_calls, 1, "mode-only request does not switch hardware")

local refresh = core.cache_refresh_policy()
equal(refresh.modem, 10, "configurable modem snapshot lifetime")
equal(refresh.selector, 15, "configurable SIM selector lifetime")
equal(refresh.warm, 2, "configurable cache prewarm interval")

client_neighbor = true
wireless_mlo_fixture = true
access_control = nil
access_devices = {}
local inventory = core.handle("client", { trans_id = "mlo-inventory" })
equal(#inventory.result.client, 1,
	"MLO link, router, multicast and expired lease MACs are de-duplicated")
equal(inventory.result.client[1].mac, "AA:BB:CC:DD:EE:FF",
	"MLO inventory uses the canonical MLD MAC")
equal(inventory.result.client[1].type, "wireless",
	"canonical MLO terminal remains wireless")
equal(inventory.result.client[1].rxbytes, 400,
	"MLO receive counters are aggregated across links")
equal(inventory.result.client[1].txbytes, 600,
	"MLO transmit counters are aggregated across links")
local station_inventory = core.station_status()
equal(station_inventory.list[1].list[1], "AA:BB:CC:DD:EE:FF",
	"2.4 GHz station status publishes the MLD MAC")
equal(station_inventory.list[2].list[1], "AA:BB:CC:DD:EE:FF",
	"5 GHz station status publishes the same MLD MAC")
app_options.local_network_write_enable = "0"
local can_control = core.local_action_allowed("client", {
	client = "AA:BB:CC:DD:EE:FF", switch = 0
})
equal(can_control, false, "client switch requires local network-write permission")
app_options.local_network_write_enable = "1"
local blocked = core.handle("client", {
	trans_id = "client-block",
	client = "AA:BB:CC:DD:EE:FF",
	switch = 0
})
equal(blocked.code, "0", "local APP client block result")
equal(access_control.enabled, "1", "client block automatically enables access control")
equal(access_control.mode, "blacklist", "client block uses shared blacklist mode")
equal(access_devices.app_aabbccddeeff.source, "official_app",
	"APP-created device rule source")
equal(blocked.result.client[1].switch, 0, "client list reflects blocked state")
local unblocked = core.handle("client", {
	trans_id = "client-allow",
	client = "AA:BB:CC:DD:EE:FF",
	switch = 1
})
equal(unblocked.code, "0", "local APP client allow result")
equal(access_devices.app_aabbccddeeff.enabled, "0", "shared device rule is disabled")
equal(unblocked.result.client[1].switch, 1, "client list reflects allowed state")

local cloud = require "c2000max_app.cloud"
local cpe, event = cloud.handle("cpestatus", {})
equal(event, "cpeinfo", "factory reply event")
local cloud_signal = assert(cpe.list and cpe.list[1],
	"missing factory cpeinfo list")
equal(cloud_signal.mode, "NR SA", "cloud network mode")
equal(cloud_signal.netlink, 1, "cloud registration")
equal(cloud_signal.rsrp, "-76", "cloud uses refreshed RSRP")
equal(cloud_signal.iccid, "898600C82525CA018033", "cloud ICCID")
equal(cloud_signal.band_count, 2, "cloud preserves current CA topology")
equal(cloud_signal.simtype, "4", "internal SIM type for remote APP")
equal(cloud_signal.simno, "1", "internal SIM index for remote APP")

print("PASS: MT5700 refresh throttles and dynamic CA topology map correctly")
