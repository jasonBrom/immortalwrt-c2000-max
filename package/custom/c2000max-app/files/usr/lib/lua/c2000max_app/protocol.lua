local fs = require "nixio.fs"
local http = require "luci.http"
local json = require "luci.jsonc"
local sys = require "luci.sys"
local util = require "luci.util"
local identity = require "c2000max_app.identity"

local M = {}
local SESSION_DIR = "/tmp/c2000max-app-sessions"
local CRYPTO = "/usr/bin/c2000max-app-crypto"

local function json_parse(value)
	local ok, result = pcall(json.parse, value or "")
	if ok and type(result) == "table" then
		return result
	end
	return nil
end

local function json_encode(value)
	return json.stringify(value)
end

local function crypt(mode, value, key)
	if mode ~= "encrypt" and mode ~= "decrypt" then
		return nil
	end
	if type(value) ~= "string" or #value > 262144 then
		return nil
	end
	if key ~= nil and
	   (type(key) ~= "string" or #key ~= 32 or key:find("%z")) then
		return nil
	end

	local nonce = sys.uniqueid(8)
	if not nonce or not nonce:match("^[0-9a-f]+$") then
		return nil
	end
	local input = "/tmp/c2000max-app-" .. nonce .. ".in"
	local output = "/tmp/c2000max-app-" .. nonce .. ".out"
	if not fs.writefile(input, value) then
		return nil
	end
	fs.chmod(input, "0600")

	local command = string.format("%s %s%s < %s > %s",
		util.shellquote(CRYPTO), mode,
		key and (" " .. util.shellquote(key)) or "",
		util.shellquote(input), util.shellquote(output))
	local rc = sys.call(command)
	local result
	if rc == 0 then
		result = fs.readfile(output)
	end
	fs.unlink(input)
	fs.unlink(output)
	if not result or #result > 262144 then
		return nil
	end
	return result:match("^%s*(.-)%s*$")
end

local function crypt_current(mode, value)
	if mode ~= "encrypt" and mode ~= "decrypt" then
		return nil
	end
	if type(value) ~= "string" or #value > 262144 then
		return nil
	end

	local nonce = sys.uniqueid(8)
	if not nonce or not nonce:match("^[0-9a-f]+$") then
		return nil
	end
	local input = "/tmp/c2000max-app-current-" .. nonce .. ".in"
	local output = "/tmp/c2000max-app-current-" .. nonce .. ".out"
	if not fs.writefile(input, value) then
		return nil
	end
	fs.chmod(input, "0600")

	local command = string.format("%s des-%s < %s > %s",
		util.shellquote(CRYPTO), mode,
		util.shellquote(input), util.shellquote(output))
	local rc = sys.call(command)
	local result = rc == 0 and fs.readfile(output) or nil
	fs.unlink(input)
	fs.unlink(output)
	if not result or #result > 262144 then
		return nil
	end
	return result:match("^%s*(.-)%s*$")
end

local function auth_token(value, secret)
	if type(value) ~= "string" or #value > 4096 or
	   type(secret) ~= "string" or #secret == 0 or #secret > 128 then
		return nil
	end
	local nonce = sys.uniqueid(8)
	if not nonce or not nonce:match("^[0-9a-f]+$") then
		return nil
	end
	local input = "/tmp/c2000max-app-token-" .. nonce .. ".in"
	local output = "/tmp/c2000max-app-token-" .. nonce .. ".out"
	if not fs.writefile(input, value) then
		return nil
	end
	fs.chmod(input, "0600")
	local command = string.format("%s token %s < %s > %s",
		util.shellquote(CRYPTO), util.shellquote(secret),
		util.shellquote(input), util.shellquote(output))
	local rc = sys.call(command)
	local result = rc == 0 and fs.readfile(output) or nil
	fs.unlink(input)
	fs.unlink(output)
	result = result and result:match("^%s*([0-9A-Fa-f]+)%s*$") or nil
	return result and #result == 32 and result:lower() or nil
end

function M.decode(body)
	body = body or ""
	if #body == 0 or #body > 262144 then
		return nil, { encrypted = false }, "empty request"
	end

	local outer = json_parse(body)
	if not outer then
		return nil, { encrypted = false }, "invalid json"
	end

	if type(outer.data) == "string" then
		-- The current official APP (v5 family) uses DES-ECB with its
		-- built-in eight-byte protocol key. Try that exact format first.
		-- The older AES formats below remain available for installed
		-- legacy APP versions.
		if outer.random == nil then
			local current_plain = crypt_current("decrypt", outer.data)
			local current_decoded = current_plain and
				json_parse(current_plain) or nil
			if current_decoded then
				return current_decoded, {
					encrypted = true,
					random = false,
					wire_mode = "des-current",
					auth_mode = 2
				}
			end
		end

		local current_identity = identity.get()
		local random
		if outer.random ~= nil then
			if type(outer.random) ~= "string" then
				return nil, { encrypted = true, random = true },
					"invalid random key"
			end
			random = crypt("decrypt", outer.random,
				current_identity.fixed_wrapper_key)
			if not random or #random ~= 32 or random:find("%z") then
				return nil, { encrypted = true, random = true },
					"random key decrypt failed"
			end
		end
		local plain = crypt("decrypt", outer.data,
			random or current_identity.crypto_key)
		local decoded = plain and json_parse(plain) or nil
		if not decoded then
			return nil, {
				encrypted = true,
				random = random ~= nil
			}, "decrypt failed"
		end
		return decoded, {
			encrypted = true,
			random = random ~= nil,
			auth_mode = random ~= nil and 1 or 0
		}
	end

	return outer, { encrypted = false, plaintext = true, auth_mode = -1 }
end

-- APP 2.3.1 probes /signal in plaintext before it knows which local wire
-- protocol the device supports.  A legacy device is selected only when the
-- probe response is an outer { data = "..." } DES envelope.  Keep the
-- request plaintext, but force that exact response wire format so the APP can
-- continue to /auth instead of classifying the device as disconnected.
function M.current_des_response_context(context)
	context = type(context) == "table" and context or {}
	context.encrypted = true
	context.plaintext = nil
	context.random = false
	context.wire_mode = "des-current"
	context.auth_mode = 2
	return context
end

function M.request()
	local body = http.content() or ""
	if #body == 0 then
		local form_data = http.formvalue("data")
		if form_data then
			body = json_encode({ data = form_data })
		end
	end
	local data, context, message = M.decode(body)
	context = context or { encrypted = false }
	context.authorization = http.getenv("HTTP_AUTHORIZATION") or ""
	context.cookie = http.getenv("HTTP_COOKIE") or ""
	return data, context, message
end

function M.encode(value, context)
	local payload = value
	context = context or {}
	if context.encrypted then
		if context.wire_mode == "des-current" then
			local encrypted = crypt_current("encrypt", json_encode(value))
			if encrypted then
				payload = { data = encrypted }
			else
				payload = {
					code = "2",
					message = "encrypt failed"
				}
			end
		else
		local current_identity = identity.get()
		local random
		local encrypted_random
		if context.random then
			random = sys.uniqueid(16)
			if random and random:match("^[0-9a-f]+$") and #random == 32 then
				encrypted_random = crypt("encrypt", random,
					current_identity.fixed_wrapper_key)
			else
				random = nil
			end
		end
		local encrypted = crypt("encrypt", json_encode(value),
			random or current_identity.crypto_key)
		if not encrypted then
			payload = {
				code = "2",
				message = "encrypt failed"
			}
		else
			payload = { data = encrypted }
			if random then
				if not encrypted_random then
					payload = {
						code = "2",
						message = "encrypt failed"
					}
				else
					payload.random = encrypted_random
				end
			end
		end
		end
	end
	return payload
end

function M.reply(value, context)
	local payload = M.encode(value, context)
	http.prepare_content("application/json")
	http.header("Cache-Control", "no-store")
	http.header("Access-Control-Allow-Origin", "*")
	http.header("Access-Control-Allow-Credentials", "true")
	http.header("Access-Control-Allow-Headers",
		"Origin,X-Requested-With,Content-Type")
	http.header("Access-Control-Allow-Methods", "POST,GET,OPTIONS,PUT")
	http.write(json_encode(payload))
end

function M.error(code, message, context, trans_id)
	M.reply({
		code = tostring(code or 2),
		trans_id = tostring(trans_id or ""),
		message = message or "request failed"
	}, context)
end

function M.verify_auth(data, context)
	if type(data) ~= "table" or type(context) ~= "table" or
	   not context.encrypted then
		return false
	end
	local device_code = data.device_code
	local timestamp = data.timestamp
	local trans_id = data.trans_id
	local supplied = data.token
	if (type(device_code) ~= "string" and type(device_code) ~= "number") or
	   (type(timestamp) ~= "string" and type(timestamp) ~= "number") or
	   (type(trans_id) ~= "string" and type(trans_id) ~= "number") or
	   type(supplied) ~= "string" or
	   not supplied:match("^[0-9A-Fa-f]+$") or #supplied ~= 32 then
		return false
	end

	device_code = tostring(device_code)
	timestamp = tostring(timestamp)
	trans_id = tostring(trans_id)
	if #device_code > 256 or #timestamp > 32 or #trans_id > 256 then
		return false
	end

	local current_identity = identity.get()
	local secret
	if context.wire_mode == "des-current" then
		secret = current_identity.current_app_secret
	elseif context.random then
		secret = current_identity.random_auth_key
	else
		secret = current_identity.app_secret
	end
	local material = "device_code" .. device_code ..
		"timestamp" .. timestamp .. "trans_id" .. trans_id
	local expected = auth_token(material, secret)
	return expected ~= nil and expected == supplied:lower()
end

local function request_token(data, context)
	local token = type(data) == "table" and data.token or nil
	context = type(context) == "table" and context or {}
	if not token then
		local authorization = context.authorization or
			http.getenv("HTTP_AUTHORIZATION") or ""
		token = authorization:match("^[Bb]earer%s+([0-9A-Fa-f]+)$")
	end
	if not token then
		local cookie = context.cookie or http.getenv("HTTP_COOKIE") or ""
		token = cookie:match("sysauth=([0-9A-Fa-f]+)") or
			http.getcookie("sysauth") or http.formvalue("token")
	end
	if type(token) ~= "string" or
	   not token:match("^[0-9A-Fa-f]+$") or #token ~= 32 then
		return nil
	end
	return token:lower()
end

function M.new_session()
	fs.mkdirr(SESSION_DIR)
	fs.chmod(SESSION_DIR, "0700")
	local token = sys.uniqueid(16)
	if not token or not token:match("^[0-9a-f]+$") or #token ~= 32 then
		return nil
	end
	local expires = os.time() + 3600
	local path = SESSION_DIR .. "/" .. token
	if not fs.writefile(path, tostring(expires) .. "\n") then
		return nil
	end
	fs.chmod(path, "0600")
	return token, 3600
end

function M.valid_session(data, context)
	local token = request_token(data, context)
	if not token then
		return false
	end
	local path = SESSION_DIR .. "/" .. token
	local expires = tonumber(fs.readfile(path) or "")
	if not expires or expires < os.time() then
		fs.unlink(path)
		return false
	end
	-- Sliding one-hour timeout, matching the official APP session behavior.
	fs.writefile(path, tostring(os.time() + 3600) .. "\n")
	return true
end

return M
