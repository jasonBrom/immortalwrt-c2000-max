module("luci.controller.nradio.app", package.seeall)

-- Compatibility shim for systems upgrading from V25. Route registration now
-- lives in c2000max_app_api.json, so this scanned controller deliberately has
-- no index() function and cannot break LuCI menu-tree construction.
local http = require "c2000max_app.http"

action_health = http.action_health
action_auth = http.action_auth
action_dispatch = http.action_dispatch
