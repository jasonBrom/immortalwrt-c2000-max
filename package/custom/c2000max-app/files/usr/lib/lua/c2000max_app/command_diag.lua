local M = {}
local rweb_compat = require "c2000max_app.rweb"

local function contains(value, needle)
	return value:lower():find(needle:lower(), 1, true) ~= nil
end

local function safe_basename(value)
	value = tostring(value or ""):gsub("^[\"']+", ""):gsub("[\"']+$", "")
	value = value:gsub("^.*/", "")
	if value == "" or #value > 32 or value ~= value:lower() or
	   not value:match("^[a-z0-9][a-z0-9._+%-]*$") or
	   value:find("secret", 1, true) or value:find("token", 1, true) or
	   value:find("password", 1, true) or value:find("passwd", 1, true) then
		return nil
	end
	-- Do not persist values that look like tokens rather than executable names.
	if (#value >= 12 and value:match("^[A-Fa-f0-9]+$")) or
	   (#value >= 16 and value:match("^[a-z0-9]+$")) then
		return nil
	end
	return value
end

local function missing_program(output)
	for line in tostring(output or ""):gmatch("[^\r\n]+") do
		local candidate =
			line:match(":%s*line%s+%d+:%s*([A-Za-z0-9_./+%-]+):%s*not found%s*$") or
			line:match(":%s*([A-Za-z0-9_./+%-]+):%s*not found%s*$") or
			line:match("[Cc]an't execute%s+[\"']?([A-Za-z0-9_./+%-]+)[\"']?:%s*[Nn]o such file or directory%s*$") or
			line:match("exec:%s*([A-Za-z0-9_./+%-]+):%s*[Nn]o such file or directory%s*$")
		candidate = safe_basename(candidate)
		if candidate then
			return candidate
		end
	end
	return nil
end

local function failure_class(output, exit_code, missing)
	if contains(output, "uci: entry not found") then
		return "uci_entry_missing"
	elseif missing then
		return "missing_program"
	elseif exit_code == "124" or contains(output, "timed out") then
		return "timeout"
	elseif contains(output, "permission denied") then
		return "permission_denied"
	elseif contains(output, "not found") or
	       contains(output, "no such file or directory") then
		return "missing_program_unidentified"
	elseif contains(output, "could not resolve") or
	       contains(output, "bad address") or
	       contains(output, "name resolution") then
		return "dns_error"
	elseif contains(output, "certificate") or contains(output, "tls") or
	       contains(output, "ssl") then
		return "tls_error"
	elseif contains(output, "connection refused") or
	       contains(output, "connection reset") or
	       contains(output, "network is unreachable") or
	       contains(output, "failed to connect") then
		return "connection_error"
	elseif exit_code ~= "" and exit_code ~= "0" then
		return "command_failed"
	end
	return ""
end

function M.analyze(result)
	result = type(result) == "table" and result or {}
	local output = type(result.result) == "string" and result.result or ""
	local exit_code = tostring(result["return"] or "")
	local message = tostring(result.message or "")
	local ready = output:find("Ready to RSSH", 1, true) ~= nil
	local rweb = contains(output, "rweb")
	local app_ready = ready and rweb
	local missing = missing_program(output)
	local class = failure_class(output, exit_code, missing)
	local inspection = rweb_compat.inspect(result.cmd)
	local state
	local detail

	if contains(message, "disabled") then
		state = "permission_disabled"
		detail = "远程后台登录权限未开启，官方 command 已拒绝"
		class = "permission_disabled"
	elseif exit_code ~= "" and exit_code ~= "0" then
		state = "failed"
		if class == "uci_entry_missing" then
			detail = "原厂远程隧道命令读取的 UCI 项仍不存在（退出码 " ..
				exit_code .. "）"
		elseif missing then
			detail = "远程后台命令找不到程序 " .. missing ..
				"（退出码 " .. exit_code .. "）"
		elseif exit_code == "127" then
			detail = "远程后台命令缺少程序或解释器（退出码 127，名称未能安全识别）"
		else
			detail = "远程后台命令执行失败（退出码 " .. exit_code ..
				"，类型 " .. (class ~= "" and class or "command_failed") .. "）"
		end
	elseif app_ready then
		state = "ready"
		detail = "已收到 rweb 与 Ready to RSSH，回执已发送"
	elseif ready then
		state = "incomplete_ready_marker"
		detail = "已收到 Ready to RSSH，但缺少 APP 要求的 rweb 标记"
	elseif rweb then
		state = "completed_without_ready"
		detail = "命令已完成并出现 rweb，但缺少 Ready to RSSH"
	else
		state = "completed_without_ready"
		detail = "命令已完成，但输出中没有 rweb 与 Ready to RSSH"
	end

	return {
		state = state,
		message = detail,
		exit_code = exit_code,
		ready = ready,
		rweb = rweb,
		app_ready = app_ready,
		failure_class = class,
		missing_program = missing or "",
		tunnel_method = inspection.tunnel_method or "unknown",
		bootstrap_tool = inspection.bootstrap_tool or "",
		uci_queries = inspection.uci_queries or ""
	}
end

return M
