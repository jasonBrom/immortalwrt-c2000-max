module("c2000max_app.http", package.seeall)

local core = require "c2000max_app.core"
local identity = require "c2000max_app.identity"
local protocol = require "c2000max_app.protocol"
local sys = require "luci.sys"

function action_health()
	protocol.reply({
		code = core.local_enabled() and "0" or "3",
		service = "c2000max-app",
		build = "V36.10",
		local_enabled = core.local_enabled(),
		cache_refresh = core.cache_refresh_policy(),
		signal_refresh = core.signal_refresh_policy()
	}, { encrypted = false })
end

function action_auth()
	local data, context, message = protocol.request()
	if not data then
		protocol.error(2, message, context)
		return
	end
	if not core.local_enabled() then
		protocol.error(2, "local app management disabled", context,
			data.trans_id)
		return
	end
	if not identity.get().available then
		protocol.error(2, "device identity unavailable", context,
			data.trans_id)
		return
	end

	local authenticated
	if context.encrypted then
		authenticated = protocol.verify_auth(data, context)
	else
		authenticated = type(data.password) == "string" and
			sys.user.checkpasswd("root", data.password)
	end
	if not authenticated then
		protocol.error(1, "authentication failed", context, data.trans_id)
		return
	end

	local token, timeout = protocol.new_session()
	if not token then
		protocol.error(2, "session creation failed", context, data.trans_id)
		return
	end
	protocol.reply({
		code = "0",
		trans_id = tostring(data.trans_id or ""),
		token = token,
		timeout = timeout
	}, context)
end

function action_dispatch(action)
	local data, context, message = protocol.request()
	if not data then
		protocol.error(2, message, context)
		return
	end
	if not core.local_enabled() then
		protocol.error(2, "local app management disabled", context,
			data.trans_id)
		return
	end
	-- APP 2.3.1 sends one plaintext /signal request solely to distinguish the
	-- AES and legacy DES protocols.  Returning a normal plaintext signal array
	-- makes it match neither protocol and the UI stays at "disconnected".  A
	-- DES envelope is the legacy capability marker; no modem query is needed.
	if action == "signal" and context.plaintext then
		protocol.reply({ code = "1" },
			protocol.current_des_response_context(context))
		return
	end
	if not protocol.valid_session(data, context) then
		-- Match the official firmware byte-level business payload.  APP clients
		-- use this minimal response as the session-expired marker.
		protocol.reply({ code = "1" }, context)
		return
	end
	local allowed, denied_message = core.local_action_allowed(action, data)
	if not allowed then
		protocol.error(3, denied_message, context, data.trans_id)
		return
	end

	local ok, result = pcall(core.handle, action, data, {
		source = "local"
	})
	if not ok or type(result) ~= "table" then
		protocol.error(2, "request failed", context, data.trans_id)
		return
	end
	protocol.reply(result, context)
end

local function merge_context(context, request_context)
	context = type(context) == "table" and context or {}
	request_context = type(request_context) == "table" and request_context or {}
	context.authorization = request_context.authorization or ""
	context.cookie = request_context.cookie or ""
	return context
end

local function encoded_error(code, message, context, trans_id)
	return protocol.encode({
		code = tostring(code or 2),
		trans_id = tostring(trans_id or ""),
		message = message or "request failed"
	}, context)
end

-- Standalone HTTP compatibility entry point used by the dedicated port-82
-- listener.  The official APP probes both ports 80 and 82; keeping the
-- request implementation here ensures the LuCI and fallback paths behave
-- identically.
function process(action, body, request_context)
	if action == "health" then
		return {
			code = core.local_enabled() and "0" or "3",
			service = "c2000max-app",
			build = "V36.10",
			local_enabled = core.local_enabled(),
			cache_refresh = core.cache_refresh_policy(),
			signal_refresh = core.signal_refresh_policy()
		}
	end

	local data, context, message = protocol.decode(body)
	context = merge_context(context, request_context)
	if not data then
		return encoded_error(2, message, context)
	end
	if not core.local_enabled() then
		return encoded_error(2, "local app management disabled", context,
			data.trans_id)
	end

	if action == "auth" then
		if not identity.get().available then
			return encoded_error(2, "device identity unavailable", context,
				data.trans_id)
		end
		local authenticated
		if context.encrypted then
			authenticated = protocol.verify_auth(data, context)
		else
			authenticated = type(data.password) == "string" and
				sys.user.checkpasswd("root", data.password)
		end
		if not authenticated then
			return encoded_error(1, "authentication failed", context,
				data.trans_id)
		end
		local token, timeout = protocol.new_session()
		if not token then
			return encoded_error(2, "session creation failed", context,
				data.trans_id)
		end
		return protocol.encode({
			code = "0",
			trans_id = tostring(data.trans_id or ""),
			token = token,
			timeout = timeout
		}, context)
	end

	if action == "signal" and context.plaintext then
		return protocol.encode({ code = "1" },
			protocol.current_des_response_context(context))
	end
	if not protocol.valid_session(data, context) then
		return protocol.encode({ code = "1" }, context)
	end
	local allowed, denied_message = core.local_action_allowed(action, data)
	if not allowed then
		return encoded_error(3, denied_message, context, data.trans_id)
	end
	local ok, result = pcall(core.handle, action, data, {
		source = "local"
	})
	if not ok or type(result) ~= "table" then
		return encoded_error(2, "request failed", context, data.trans_id)
	end
	return protocol.encode(result, context)
end
