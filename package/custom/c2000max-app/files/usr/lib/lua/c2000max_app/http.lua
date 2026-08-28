module("c2000max_app.http", package.seeall)

local core = require "c2000max_app.core"
local identity = require "c2000max_app.identity"
local protocol = require "c2000max_app.protocol"
local sys = require "luci.sys"

local function plaintext_password_authenticated(data)
	if type(data) ~= "table" or type(data.password) ~= "string" then
		return false
	end
	-- 鲲鹏无限 3.1.0 hard-codes a one-time password page for every new AES
	-- device and does not consume the server-side auth_on flag.  With no root
	-- password, accept any non-empty text entered in that page.  Otherwise
	-- validate the actual root password.
	if not core.management_password_configured() then
		return true
	end
	return sys.user.checkpasswd("root", data.password)
end

local function plaintext_signal_probe(context)
	if core.local_protocol_mode() == "legacy" then
		return { code = "1" },
			protocol.current_des_response_context(context)
	end

	-- 鲲鹏无限 3.1.0 selects its AES local protocol only when the plaintext
	-- /signal probe contains a non-empty signal[0].mac or signal[0].id.  This
	-- capability response intentionally avoids querying the modem.
	local device_id = core.device_id()
	if not device_id or device_id == "" then
		return { code = "1" }, context
	end
	return {
		code = "0",
		signal = {{
			mac = device_id,
			id = device_id
		}}
	}, context
end

function action_health()
	protocol.reply({
		code = core.local_enabled() and "0" or "3",
		service = "c2000max-app",
		build = "V36.10",
		local_enabled = core.local_enabled(),
		local_protocol_mode = core.local_protocol_mode(),
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
	local auth_kind
	if context.encrypted then
		-- Encrypted device authentication is the password-free APP 3.1 fast
		-- path.  Reject it only when a real system password exists and the user
		-- kept APP password verification enabled; APP then opens its plaintext
		-- management-password dialog.
		auth_kind = "device"
		authenticated = not core.management_password_configured() and
			protocol.verify_auth(data, context)
	else
		authenticated = plaintext_password_authenticated(data)
		auth_kind = "password"
	end
	if not authenticated then
		protocol.error(1, "authentication failed", context, data.trans_id)
		return
	end

	local token, timeout = protocol.new_session(auth_kind)
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
	-- The plaintext /signal request is a protocol capability probe, not a
	-- normal authenticated modem query.
	local session_valid
	if action == "signal" and context.plaintext then
		-- 3.1.0 uses the same plaintext endpoint twice: first without a
		-- sysauth cookie to detect AES capability, then with the password-auth
		-- session cookie to fetch real signal data.  Only the first request is
		-- a capability probe.
		session_valid = protocol.valid_session(data, context,
			core.management_password_configured())
		if not session_valid then
			local result, response_context = plaintext_signal_probe(context)
			protocol.reply(result, response_context)
			return
		end
	end
	if not session_valid and not protocol.valid_session(data, context,
	   core.management_password_configured()) then
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
			local_protocol_mode = core.local_protocol_mode(),
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
		local auth_kind
		if context.encrypted then
			auth_kind = "device"
			authenticated = not core.management_password_configured() and
				protocol.verify_auth(data, context)
		else
			auth_kind = "password"
			authenticated = plaintext_password_authenticated(data)
		end
		if not authenticated then
			return encoded_error(1, "authentication failed", context,
				data.trans_id)
		end
		local token, timeout = protocol.new_session(auth_kind)
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

	local session_valid
	if action == "signal" and context.plaintext then
		session_valid = protocol.valid_session(data, context,
			core.management_password_configured())
		if not session_valid then
			local result, response_context = plaintext_signal_probe(context)
			return protocol.encode(result, response_context)
		end
	end
	if not session_valid and not protocol.valid_session(data, context,
	   core.management_password_configured()) then
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
