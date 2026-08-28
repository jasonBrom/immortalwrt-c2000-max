#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
LUCI_ROOT="$(dirname "$ROOT")/luci-app-c2000max-app"
REPO="$(CDPATH= cd "$ROOT/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

assert_contains()
{
	local file="$1" value="$2"
	rg -Fq -- "$value" "$file" || fail "$file does not contain: $value"
}

assert_not_contains()
{
	local file="$1" value="$2"
	! rg -Fq -- "$value" "$file" ||
		fail "$file unexpectedly contains: $value"
}

CRYPTO="$TMP/c2000max-app-crypto"
cc -Wall -Wextra -Werror -O2 -o "$CRYPTO" "$ROOT/src/crypto.c" -lcrypto

PLAIN='{"token":"0123456789abcdef0123456789abcdef","trans_id":"test"}'
FIXED_KEY='383a537d1f2df8c5a76e2f95ddae6a92'
APP310_KEY='59ad910d5902374f90224e063538b100'
DEVICE_KEY='abcdef0123456789abcdef0123456789'
RANDOM_KEY='0123456789abcdef0123456789abcdef'
IV_HEX='000102030405060708090a0b0c0d0e0f'

current_cipher="$(printf '%s' "$PLAIN" | "$CRYPTO" des-encrypt)"
current_expected="$(
	printf '%s' "$PLAIN" |
		openssl enc -des-ecb -provider legacy -e -A -a \
			-K 3936373834633166
)"
[[ "$current_cipher" == "$current_expected" ]] ||
	fail "current APP DES-ECB vector does not match OpenSSL"
[[ "$(printf '%s' "$current_cipher" |
	"$CRYPTO" des-decrypt)" == "$PLAIN" ]] ||
	fail "current APP DES-ECB round trip failed"

# APP 2.3.1 uses this exact deterministic envelope to recognize a legacy
# device during its plaintext /signal probe.  The value is also present in the
# captured official-firmware HAR.
probe_plain='{"code":"1"}'
probe_cipher="$(printf '%s' "$probe_plain" | "$CRYPTO" des-encrypt)"
[[ "$probe_cipher" == '+2j4zUClduWNHc2LNm8p6w==' ]] ||
	fail "APP 2.3.1 legacy probe response vector does not match"
[[ "$(printf '%s' "$probe_cipher" |
	"$CRYPTO" des-decrypt)" == "$probe_plain" ]] ||
	fail "APP 2.3.1 legacy probe response does not decrypt"

fixed_cipher="$(printf '%s' "$PLAIN" | "$CRYPTO" encrypt "$FIXED_KEY")"
fixed_expected="$(
	printf '%s' "$PLAIN" |
		openssl enc -aes-256-cbc -e -A -a \
			-K "$(printf '%s' "$FIXED_KEY" |
				od -An -tx1 | tr -d ' \n')" \
			-iv "$IV_HEX"
)"
[[ "$fixed_cipher" == "$fixed_expected" ]] ||
	fail "fixed-key AES vector does not match OpenSSL"
[[ "$(printf '%s' "$fixed_cipher" |
	"$CRYPTO" decrypt "$FIXED_KEY")" == "$PLAIN" ]] ||
	fail "fixed-key round trip failed"

app310_cipher="$(printf '%s' "$PLAIN" |
	"$CRYPTO" encrypt "$APP310_KEY")"
[[ "$(printf '%s' "$app310_cipher" |
	"$CRYPTO" decrypt "$APP310_KEY")" == "$PLAIN" ]] ||
	fail "APP 3.1 AES fallback round trip failed"

device_cipher="$(printf '%s' "$PLAIN" | "$CRYPTO" encrypt "$DEVICE_KEY")"
[[ "$(printf '%s' "$device_cipher" |
	"$CRYPTO" decrypt "$DEVICE_KEY")" == "$PLAIN" ]] ||
	fail "per-device crypto_secret round trip failed"
random_cipher="$(printf '%s' "$PLAIN" | "$CRYPTO" encrypt "$RANDOM_KEY")"
[[ "$(printf '%s' "$random_cipher" |
	"$CRYPTO" decrypt "$RANDOM_KEY")" == "$PLAIN" ]] ||
	fail "random-key payload round trip failed"
wrapped_random="$(printf '%s' "$RANDOM_KEY" |
	"$CRYPTO" encrypt "$FIXED_KEY")"
[[ "$(printf '%s' "$wrapped_random" |
	"$CRYPTO" decrypt "$FIXED_KEY")" == "$RANDOM_KEY" ]] ||
	fail "wrapped random key round trip failed"

AUTH_MATERIAL='device_codeABC123timestamp1701439510trans_idT-1'
AUTH_SECRET='89abcdef0123456789abcdef01234567'
token="$(printf '%s' "$AUTH_MATERIAL" |
	"$CRYPTO" token "$AUTH_SECRET")"
expected="$(printf '%s%s' "$AUTH_MATERIAL" "$AUTH_SECRET" |
	md5sum | cut -d ' ' -f1)"
[[ "$token" == "$expected" ]] ||
	fail "dynamic APP auth MD5 vector does not match"

CURRENT_AUTH_MATERIAL='device_codePHONE-1timestamp2026-07-27 12:34:56trans_id123456'
CURRENT_AUTH_SECRET='f2e6e232e75f33d5f3d5b040c93d0d'
current_token="$(printf '%s' "$CURRENT_AUTH_MATERIAL" |
	"$CRYPTO" token "$CURRENT_AUTH_SECRET")"
current_token_expected="$(
	printf '%s%s' "$CURRENT_AUTH_MATERIAL" "$CURRENT_AUTH_SECRET" |
		md5sum | cut -d ' ' -f1
)"
[[ "$current_token" == "$current_token_expected" ]] ||
	fail "current APP auth token vector does not match"

LUAC="${LUAC:-$(command -v luac5.1 || true)}"
if [[ -x "$LUAC" ]]; then
	while IFS= read -r file; do
		"$LUAC" -p "$file"
	done < <(find "$ROOT/files" -type f \( -name '*.lua' -o \
		-path '*/usr/sbin/c2000max-app-local' -o \
		-path '*/usr/sbin/c2000max-app-httpd' -o \
		-path '*/usr/sbin/c2000max-app-remote' -o \
		-path '*/usr/sbin/c2000max-app-reporter' -o \
		-path '*/usr/sbin/c2000max-app-cache' \))
fi

LUA="${LUA:-$(command -v lua5.1 || command -v texlua || true)}"
if [[ -x "$LUA" ]]; then
	"$LUA" "$ROOT/tests/test_modem_fixture.lua" "$ROOT"
	"$LUA" "$ROOT/tests/test_remote_command_fixture.lua" "$ROOT"
	"$LUA" "$ROOT/tests/test_cloud_controls_fixture.lua" "$ROOT"
fi

TEXLUA="${TEXLUA:-$(command -v texlua || true)}"
if [[ -x "$TEXLUA" ]]; then
	"$TEXLUA" "$ROOT/tests/test_identity_fixture.lua" "$ROOT"
fi

bash "$ROOT/tests/test_huawei_detail.sh"

node --check "$LUCI_ROOT/htdocs/luci-static/resources/view/c2000max/app.js"
sh -n "$ROOT/files/etc/init.d/c2000max-app"
sh -n "$LUCI_ROOT/root/usr/libexec/rpcd/c2000max_app"
sh -n "$ROOT/files/usr/sbin/c2000max-app-bridge"
sh -n "$ROOT/files/usr/sbin/c2000max-app-wifi-apply"
sh -n "$ROOT/files/usr/sbin/c2000max-app-sim-switch"
sh -n "$ROOT/files/etc/uci-defaults/99-c2000max-app-autostart"

CONFIG="$ROOT/files/etc/config/c2000max_app"
for option in local remote
do
	assert_contains "$CONFIG" "option ${option}_enable '0'"
done
assert_not_contains "$CONFIG" "option local_password_required"
assert_contains "$CONFIG" "option local_protocol_mode 'modern'"
for option in local_device local_signal local_client local_wifi \
	local_traffic local_sms local_network_write local_sim_switch \
	local_cellular_record password reboot remote_web device_report signal_report \
	traffic_report terminal_tracking broadcast command file \
	appstore developer
do
	assert_contains "$CONFIG" "option ${option}_enable '1'"
done
assert_not_contains "$CONFIG" "option upgrade_enable"
assert_not_contains "$CONFIG" "option device_id"
assert_not_contains "$CONFIG" "option allow_sensitive"
assert_contains "$CONFIG" "option modem_cache_interval '10'"
assert_contains "$CONFIG" "option selector_cache_interval '15'"
assert_contains "$CONFIG" "option cache_warm_interval '2'"
assert_contains "$CONFIG" "option cache_idle_interval '30'"
assert_contains "$CONFIG" "option cache_active_window '180'"
assert_contains "$CONFIG" "option signal_normal_interval '3'"
assert_contains "$CONFIG" "option signal_test_interval '1'"
assert_contains "$CONFIG" "option signal_carrier_interval '10'"

IDENTITY="$ROOT/files/usr/lib/lua/c2000max_app/identity.lua"
assert_contains "$IDENTITY" 'partition_devices("bdinfo")'
assert_contains "$IDENTITY" 'partition_devices("factory")'
assert_contains "$IDENTITY" 'local raw = read_limited(path, 6, 4)'
assert_contains "$IDENTITY" 'local bdinfo_id = clean_device_id(values.fac_mac)'
assert_contains "$IDENTITY" 'local BDINFO_KEYS = {'
assert_contains "$IDENTITY" 'local position = lower:find(wanted, start, true)'
assert_contains "$IDENTITY" 'bdinfo_identity_valid = bdinfo_identity_valid'
assert_contains "$IDENTITY" 'remote_identity_available = remote_identity_available'
assert_contains "$IDENTITY" 'crypto_key = clean_aes_key(values.crypto_secret)'
assert_contains "$IDENTITY" 'crypto_key = clean_aes_key(values.fac_key)'
assert_contains "$IDENTITY" 'local app_secret = clean_aes_key(values.app_secret)'
assert_contains "$IDENTITY" 'return value:sub(1, 32)'
assert_contains "$IDENTITY" 'current_app_secret = RANDOM_AUTH_KEY'
assert_contains "$IDENTITY" 'app310_fallback_key = APP310_AES_FALLBACK_KEY'
assert_contains "$IDENTITY" 'CURRENT_APP_SOURCE = "official APP v5 DES protocol"'
assert_contains "$IDENTITY" 'APP310_AES_FALLBACK_KEY = "59ad910d5902374f90224e063538b100"'
assert_contains "$IDENTITY" 'crypto_source = "APP 3.1 AES fallback"'
assert_not_contains "$IDENTITY" "/sys/class/net/"

CORE="$ROOT/files/usr/lib/lua/c2000max_app/core.lua"
assert_contains "$CORE" 'return identity.get().device_id'
assert_contains "$CORE" 'bool_option("password_enable")'
assert_contains "$CORE" 'bool_option("reboot_enable")'
assert_contains "$CORE" 'local function collect_modem_fields(fields, source)'
assert_contains "$CORE" 'local function build_modem_status(modem, selector, index)'
assert_contains "$CORE" 'local function app_remote_sim_slot(value)'
assert_contains "$CORE" 'return "0", "1"'
assert_contains "$CORE" 'return "0", "2"'
assert_contains "$CORE" 'return "4", "1"'
assert_contains "$CORE" 'function M.management_password_configured()'
assert_not_contains "$CORE" 'function M.local_password_required()'
assert_contains "$CORE" 'auth_on = M.management_password_configured() and 1 or 0'
assert_contains "$CORE" 'local APP_SOFTWARE_VERSION = "2.9.9.9"'
assert_not_contains "$CORE" '9.9.13.n0.c1'
assert_contains "$CORE" 'function M.software_version()'
assert_contains "$CORE" 'function M.local_protocol_mode()'
assert_contains "$CORE" 'local DEFAULT_MODEM_CACHE_INTERVAL = 10'
assert_contains "$CORE" 'local DEFAULT_SELECTOR_CACHE_INTERVAL = 15'
assert_contains "$CORE" 'local DEFAULT_CACHE_WARM_INTERVAL = 2'
assert_contains "$CORE" 'function M.signal_refresh_policy()'
assert_contains "$CORE" 'DEFAULT_SIGNAL_NORMAL_INTERVAL = 3'
assert_contains "$CORE" 'DEFAULT_SIGNAL_TEST_INTERVAL = 1'
assert_contains "$CORE" 'DEFAULT_SIGNAL_CARRIER_INTERVAL = 10'
assert_contains "$CORE" 'FAST_SIGNAL_FAILURE_BACKOFF = 5'
assert_contains "$CORE" 'local function inferred_band(mode, channel)'
assert_contains "$CORE" 'DLBW = dlbw'
assert_contains "$CORE" 'NR5G_AMBR_DL = ambr_dl'
assert_contains "$CORE" 'status.cpeno = index'
assert_contains "$CORE" 'signalStrength = signal or ""'
assert_contains "$CORE" 'network_mode'
assert_contains "$CORE" 'physical_cell_id'
assert_contains "$CORE" 'tonumber(data.at_signal or 0) == 1'
assert_contains "$CORE" 'query_serialized_at(modem, "AT^MONSC")'
assert_contains "$CORE" 'query_serialized_at(modem, "AT^HFREQINFO?")'
assert_contains "$CORE" 'safe_ubus("qmodem", "send_at"'
assert_contains "$CORE" 'use_ubus_flag = "1"'
assert_contains "$CORE" 'local function parse_huawei_hfreqinfo(response, mode)'
assert_contains "$CORE" 'local result = { band_count = #carriers }'
assert_contains "$CORE" 'MAX_APP_CARRIERS = 8'
assert_contains "$CORE" 'cached_carrier_topology(modem, refresh.carrier)'
assert_contains "$CORE" 'type(data.cur) == "table"'
assert_contains "$CORE" 'safe_ubus("c2000max", "sim_switch"'
assert_contains "$CORE" 'uci:get("c2000max_app", "main", "sim_mode")'
assert_contains "$CORE" 'persist_sim_mode(requested_mode)'
assert_contains "$CORE" 'query_serialized_at(modem, "AT^IMSSWITCH?")'
assert_contains "$CORE" '"AT^IMSSWITCH=1,0,0"'
assert_contains "$CORE" 'local function app_sms_switch(data)'
assert_contains "$CORE" 'query_serialized_at(modem, "AT^MONNC")'
assert_contains "$CORE" 'AT^NRFREQLOCK='
assert_contains "$CORE" 'AT^LTEFREQLOCK='
assert_contains "$CORE" 'local function apply_huawei_lock(modem, data)'
assert_contains "$CORE" 'local function huawei_cell_commands(rows)'
assert_contains "$CORE" 'tostring(#group.items), quoted_values(bands)'
assert_contains "$CORE" 'for value in tostring(values or ""):gmatch("[^:;/%s]+") do'
assert_contains "$CORE" 'local function apply_huawei_network_mode(modem, mode)'
assert_contains "$CORE" 'status = (lock_type == 1 or lock_type == 2) and "1" or "0"'
assert_contains "$CORE" 'function M.station_status()'
assert_contains "$CORE" 'local function valid_client_mac(value)'
assert_contains "$CORE" 'station.mld_mac = mld:upper()'
assert_contains "$CORE" 'station_aliases[link_mac] = device_mac'
assert_contains "$CORE" 'expiry == 0 or expiry > math.floor(precise_time())'
assert_contains "$CORE" 'if live[mac] and not local_macs[mac] then'
assert_contains "$CORE" 'local function normalize_sms_read(value, requested_type)'
assert_contains "$CORE" 'local function normalize_qmodem_neighbor_cells(value)'
assert_contains "$CORE" 'local function app_operator_plmn(fields, imsi, operator)'
assert_contains "$CORE" 'local function shared_cache_read(name, maximum_age, allow_stale)'
assert_contains "$CORE" 'local function shared_cache_write(name, value)'
assert_contains "$CORE" 'function M.prewarm()'
assert_contains "$CORE" 'function M.cache_refresh_policy()'
assert_contains "$CORE" 'function M.note_activity()'
assert_contains "$CORE" 'function M.cache_active()'
assert_contains "$CORE" 'M.set_device_internet(mac, allowed)'
assert_contains "$CORE" 'rv.result = { client = list_clients() }'
assert_contains "$CORE" 'uci:set("c2000max", "access_control", "enabled", "1")'
assert_contains "$CORE" 'item.rule_name or item.ruleName or "t0"'
assert_contains "$CORE" '"/usr/sbin/c2000max-app-wifi-apply >/dev/null 2>&1 &"'
assert_contains "$CORE" 'name == "upgrade_enable"'
assert_contains "$CORE" 'data.name ~= "cellular_record"'
assert_contains "$CORE" 'rv.code = nil'
assert_contains "$CORE" 'function M.local_action_allowed(action, data)'
for permission in local_device local_signal local_client local_wifi \
	local_traffic local_sms local_network_write local_sim_switch \
	local_cellular_record
do
	assert_contains "$CORE" "\"${permission}_enable\""
done
assert_contains "$CORE" '系统 → APP 支持'

CLOUD="$ROOT/files/usr/lib/lua/c2000max_app/cloud.lua"
REMOTE="$ROOT/files/usr/sbin/c2000max-app-remote"
assert_contains "$CLOUD" 'local function control_item(value, depth)'
assert_contains "$CLOUD" 'control_key == "internetcontrol"'
assert_contains "$REMOTE" '"kp/" .. device_id .. "/#"'
assert_contains "$REMOTE" 'event = rest:match("^([^/]+)$")'
assert_not_contains "$CORE" '/dev/ttyUSB'
assert_not_contains "$CORE" '/dev/ttyACM'
if rg -n 'io\.open\([^)]*(at_port|control|tty|serial)' "$CORE"; then
	fail "APP core must not open a modem AT device directly"
fi
assert_not_contains "$CORE" 'uci:get("c2000max_app", "main", "device_id")'

PROTOCOL="$ROOT/files/usr/lib/lua/c2000max_app/protocol.lua"
assert_contains "$PROTOCOL" 'current_identity.crypto_key'
assert_contains "$PROTOCOL" 'context.crypto_key or current_identity.crypto_key'
assert_contains "$PROTOCOL" 'current_identity.fixed_wrapper_key'
assert_contains "$PROTOCOL" 'current_identity.random_auth_key'
assert_contains "$PROTOCOL" 'wire_mode = "des-current"'
assert_contains "$PROTOCOL" 'current_identity.current_app_secret'
assert_contains "$PROTOCOL" 'des-%s'
assert_contains "$PROTOCOL" '"device_code" .. device_code'
assert_contains "$PROTOCOL" '"timestamp" .. timestamp .. "trans_id" .. trans_id'
assert_contains "$PROTOCOL" 'auth_token(material, secret)'
assert_contains "$PROTOCOL" 'secret = context.crypto_key or current_identity.app_secret'
assert_contains "$PROTOCOL" 'fs.chmod(SESSION_DIR, "0700")'
assert_contains "$PROTOCOL" 'function M.decode(body)'
assert_contains "$PROTOCOL" 'function M.encode(value, context)'
assert_contains "$PROTOCOL" 'current_identity.app310_fallback_key'
assert_contains "$PROTOCOL" 'function M.new_session(auth_kind)'
assert_contains "$PROTOCOL" 'function M.valid_session(data, context, require_password)'
assert_contains "$PROTOCOL" 'auth_kind ~= "password"'
assert_contains "$PROTOCOL" '" " .. auth_kind .. "\n"'
assert_contains "$PROTOCOL" 'function M.current_des_response_context(context)'
assert_contains "$PROTOCOL" 'context.wire_mode = "des-current"'
assert_contains "$PROTOCOL" 'cookie:match("sysauth=([0-9A-Fa-f]+)")'
if rg -n 'fs\.chmod\([^,]+,[[:space:]]*[0-9]+\)' "$ROOT/files"; then
	fail "nixio.fs.chmod mode must be a string, not a decimal number"
fi

HTTP="$ROOT/files/usr/lib/lua/c2000max_app/http.lua"
assert_contains "$HTTP" 'protocol.verify_auth(data, context)'
assert_contains "$HTTP" 'sys.user.checkpasswd("root", data.password)'
assert_contains "$HTTP" 'local function plaintext_password_authenticated(data)'
assert_contains "$HTTP" 'if not core.management_password_configured() then'
assert_not_contains "$HTTP" 'local password_hash = sys.user.getpasswd("root")'
assert_contains "$HTTP" 'action == "signal" and context.plaintext'
assert_contains "$HTTP" 'not core.management_password_configured() and'
assert_contains "$HTTP" 'protocol.new_session(auth_kind)'
assert_contains "$HTTP" 'core.management_password_configured())'
assert_contains "$HTTP" 'protocol.current_des_response_context(context)'
assert_contains "$HTTP" 'local function plaintext_signal_probe(context)'
assert_contains "$HTTP" 'core.local_protocol_mode() == "legacy"'
assert_contains "$HTTP" 'mac = device_id'
assert_contains "$HTTP" 'protocol.reply({ code = "1" }, context)'
assert_contains "$HTTP" 'function action_health()'
assert_contains "$HTTP" 'build = "V36.10"'
assert_contains "$HTTP" 'signal_refresh = core.signal_refresh_policy()'
assert_contains "$HTTP" 'function process(action, body, request_context)'
assert_contains "$HTTP" 'core.local_action_allowed(action, data)'

node "$ROOT/tests/test_app_231_probe.js"
node "$ROOT/tests/test_app_310_probe.js"

API_MENU="$ROOT/files/usr/share/luci/menu.d/c2000max_app_api.json"
python3 -m json.tool "$API_MENU" >/dev/null
assert_contains "$API_MENU" '"module": "c2000max_app.http"'
assert_contains "$API_MENU" '"parameters": [ "signal" ]'
assert_contains "$API_MENU" '"parameters": [ "wifiauth" ]'
assert_contains "$API_MENU" '"nradio/app/health"'

CONTROLLER="$ROOT/files/usr/lib/lua/luci/controller/nradio/app.lua"
assert_not_contains "$CONTROLLER" 'function index'
if rg -q '(^|[^.])entry\s*\(' "$CONTROLLER"; then
	fail "APP package still uses a legacy global LuCI entry() helper"
fi

RPC="$LUCI_ROOT/root/usr/libexec/rpcd/c2000max_app"
assert_contains "$RPC" '"developer_enable": "bool"'
assert_contains "$RPC" '"local_protocol_mode": "string"'
assert_contains "$RPC" '"local_device_enable": "bool"'
assert_contains "$RPC" '"local_network_write_enable": "bool"'
assert_contains "$RPC" '"remote_web_enable": "bool"'
assert_contains "$RPC" 'uci -q delete c2000max_app.main.device_id'
assert_not_contains "$RPC" '"device_id": "string"'
assert_not_contains "$RPC" 'main.device_id=$device_id'
assert_contains "$RPC" "pgrep -f '/usr/sbin/c2000max-app-local'"
assert_contains "$RPC" 'http://127.0.0.1/cgi-bin/luci/nradio/app/health'
assert_contains "$RPC" 'http://127.0.0.1:82/cgi-bin/luci/nradio/app/health'
assert_contains "$RPC" 'json_add_string app_build "V36.10"'
assert_contains "$RPC" 'json_add_string app_software_version "2.9.9.9"'
assert_contains "$RPC" 'json_add_string local_protocol_mode "$value"'
assert_contains "$RPC" 'json_add_boolean upgrade_permanently_disabled 1'
assert_not_contains "$RPC" '"upgrade_enable": "bool"'
assert_contains "$RPC" 'json_add_string agent_log "$agent_log"'
assert_contains "$RPC" 'bdinfo_present'
assert_contains "$RPC" 'bdinfo_identity_valid'
assert_contains "$RPC" 'remote_identity_available'
assert_contains "$RPC" 'device_code_present'
assert_contains "$RPC" '/etc/init.d/c2000max-app enable'
assert_not_contains "$RPC" '/etc/init.d/c2000max-app disable'
assert_contains "$RPC" 'json_add_boolean service_autostart'
assert_contains "$RPC" 'json_add_boolean cache_running'
assert_contains "$RPC" 'json_add_boolean reporter_running'
assert_contains "$RPC" 'json_add_int bridge_session_age'
assert_not_contains "$RPC" 'V35.21'
assert_contains "$RPC" 'json_add_string remote_command_message "$remote_command_message"'

VIEW="$LUCI_ROOT/htdocs/luci-static/resources/view/c2000max/app.js"
assert_contains "$VIEW" 'node.checked = !!checked'
assert_contains "$VIEW" '鲲鹏无限 3.1+（AES，推荐）'
assert_contains "$VIEW" "['local_protocol_mode']"
assert_contains "$VIEW" '设备编号（只读）'
assert_contains "$VIEW" "name: 'local_device_enable'"
assert_contains "$VIEW" "name: 'local_network_write_enable'"
assert_contains "$VIEW" "name: 'remote_web_enable'"
assert_contains "$VIEW" '官方云端远程管理（实验）'
assert_contains "$VIEW" '发送设备身份与在线握手'
assert_contains "$VIEW" "name: 'command_enable'"
assert_contains "$VIEW" "name: 'developer_enable'"
assert_not_contains "$VIEW" "'checked': checked"
assert_not_contains "$VIEW" "'c2000max-app-device-id'"
assert_contains "$VIEW" '局域网和云端总开关默认关闭'
assert_contains "$VIEW" '当前界面：'
assert_contains "$VIEW" "text(status.app_build, 'V36.10')"
assert_contains "$VIEW" '软件更新权限'
assert_contains "$VIEW" '永久关闭'
assert_not_contains "$VIEW" "name: 'upgrade_enable'"
assert_contains "$VIEW" '重新启动 APP 服务'
assert_contains "$VIEW" '设备身份与状态'
assert_contains "$VIEW" 'MQTT 会话建立时间'
assert_contains "$VIEW" '本次开机主动重连次数'

MENU="$LUCI_ROOT/root/usr/share/luci/menu.d/c2000max_app.json"
ACL="$LUCI_ROOT/root/usr/share/rpcd/acl.d/c2000max_app.json"
python3 -m json.tool "$MENU" >/dev/null
python3 -m json.tool "$ACL" >/dev/null
assert_contains "$MENU" '"admin/system/c2000max-app"'
assert_contains "$MENU" '"title": "APP 支持"'
assert_contains "$MENU" '"path": "c2000max/app"'

LOCAL="$ROOT/files/usr/sbin/c2000max-app-local"
assert_contains "$LOCAL" 'local PORT = 8888'
assert_contains "$LOCAL" 'local MAX_REQUEST = 1023'
assert_contains "$LOCAL" 'local ACK = "OK\r\n"'
assert_contains "$LOCAL" 'server:bind("0.0.0.0", PORT)'
assert_contains "$LOCAL" 'client:send(ACK)'

HTTPD="$ROOT/files/usr/sbin/c2000max-app-httpd"
assert_contains "$HTTPD" 'local PORT = 82'
assert_contains "$HTTPD" 'local MAX_BODY = 262144'
assert_contains "$HTTPD" '"/cgi-bin/luci/nradio/app/"'
assert_contains "$HTTPD" 'pcall(app_http.process, action, request.body'
assert_contains "$HTTPD" 'server:bind("0.0.0.0", PORT)'

INIT="$ROOT/files/etc/init.d/c2000max-app"
[[ -x "$INIT" ]] || fail "$INIT is not executable"
assert_contains "$INIT" 'config_get_bool local_enabled main local_enable 0'
assert_contains "$INIT" 'procd_set_param command /usr/sbin/c2000max-app-local'
assert_contains "$INIT" 'procd_set_param command /usr/sbin/c2000max-app-httpd'
assert_contains "$INIT" 'procd_set_param command /usr/sbin/c2000max-app-bridge'
assert_contains "$INIT" 'procd_set_param command /usr/sbin/c2000max-app-cache'

REMOTE="$ROOT/files/usr/sbin/c2000max-app-remote"
assert_contains "$REMOTE" '"kp/" .. device_id .. "/#"'
assert_contains "$REMOTE" '"$SYS/broker/connection/" .. device_id .. "/state"'
assert_contains "$REMOTE" '"rpc/exec/#"'
assert_contains "$REMOTE" 'LOCAL_BROKER = "127.0.0.1"'
assert_contains "$REMOTE" 'LOCAL_PORT = 1884'
assert_contains "$REMOTE" 'local function wait_for_local_broker()'
assert_contains "$REMOTE" 'nixio.connect(LOCAL_BROKER, LOCAL_PORT'
assert_contains "$REMOTE" 'FACTORY_SELF_GROUP = "g1"'
assert_contains "$REMOTE" 'cloud.publish("group_id"'
assert_contains "$REMOTE" 'cloud.publish("status"'
assert_contains "$REMOTE" 'id = device_id'
assert_not_contains "$REMOTE" 'id = "mosca"'
assert_contains "$REMOTE" 'cloud.publish("time"'
assert_contains "$REMOTE" 'current_identity.bdinfo_present'
assert_contains "$REMOTE" 'current_identity.bdinfo_identity_valid'
assert_contains "$REMOTE" 'current_identity.remote_identity_available'
assert_contains "$REMOTE" 'current_identity.device_code_present'
assert_contains "$REMOTE" 'nixio.nanosleep(5)'
assert_contains "$REMOTE" 'COMMAND_STATE = STATE_DIR .. "/remote-command.state"'
assert_contains "$REMOTE" 'BRIDGE_SESSION_STATE = STATE_DIR .. "/bridge-session.state"'
assert_contains "$REMOTE" 'bridge_reconnect_count'
assert_not_contains "$RPC" '"local_password_required": "bool"'
assert_contains "$REMOTE" 'reply_expected == false'
assert_not_contains "$REMOTE" 'state = "online"'

COMMAND_DIAG="$ROOT/files/usr/lib/lua/c2000max_app/command_diag.lua"
assert_contains "$COMMAND_DIAG" 'output:find("Ready to RSSH", 1, true)'
assert_contains "$COMMAND_DIAG" 'state = "permission_disabled"'

BRIDGE="$ROOT/files/usr/sbin/c2000max-app-bridge"
assert_contains "$BRIDGE" "remote_clientid \$device_id"
assert_contains "$BRIDGE" 'remote_username router'
assert_contains "$BRIDGE" 'notifications_local_only true'
assert_contains "$BRIDGE" 'cleansession false'
assert_contains "$BRIDGE" 'bridge_restart_interval'
assert_contains "$BRIDGE" '/usr/bin/timeout -s TERM -k 15'
assert_contains "$BRIDGE" 'scheduled official MQTT session refresh'
assert_contains "$BRIDGE" '[ "$bdinfo_present" = true ] || fail "bdinfo unavailable"'
assert_contains "$BRIDGE" '[ "$bdinfo_identity_valid" = true ] || fail "bdinfo identity invalid"'
assert_contains "$BRIDGE" '[ "$remote_identity_available" = true ] || fail "remote identity unavailable"'
assert_contains "$BRIDGE" '[ "$device_code_present" = true ] || fail "device code unavailable"'
assert_not_contains "$BRIDGE" 'cleansession true'
assert_contains "$BRIDGE" "topic kp/\$device_id/+/# in 1"
assert_contains "$BRIDGE" "topic kp/mosca/\$device_id/# out 1"
assert_contains "$BRIDGE" "topic mosca/# in 1 kp/\$device_id/ kp/FFFFFFFFFFFF/"
assert_contains "$BRIDGE" "topic exec/# both 1 rpc/ \$device_id/"

CLOUD="$ROOT/files/usr/lib/lua/c2000max_app/cloud.lua"
for feature in remote_web device_report signal_report traffic_report \
	terminal_tracking command file appstore developer
do
	assert_contains "$CLOUD" "\"${feature}_enable\""
done
assert_contains "$CLOUD" '"kp/mosca/" .. device_id .. "/"'
assert_contains "$CLOUD" '"-h 127.0.0.1"'
assert_contains "$CLOUD" '"/usr/bin/timeout"'
assert_contains "$CLOUD" 'id = device_id'
assert_contains "$CLOUD" '"-p 1884"'
assert_contains "$CLOUD" 'local function response_timestamp()'
assert_contains "$CLOUD" 'local function presence_timestamp()'
assert_not_contains "$VIEW" "name: 'local_password_required'"
assert_not_contains "$VIEW" '系统未设置管理密码：APP 将自动认证，不显示密码验证弹窗。'
assert_not_contains "$VIEW" 'const passwordPolicy ='
assert_contains "$ROOT/files/etc/uci-defaults/99-c2000max-app-autostart" \
	'uci -q delete c2000max_app.main.local_password_required'
assert_contains "$CLOUD" 'nixio.gettimeofday'
assert_contains "$CLOUD" 'payload.uniq = response_timestamp()'
assert_contains "$CLOUD" 'elseif event == "time" then'
assert_contains "$CLOUD" 'state = 2'
assert_contains "$CLOUD" 'elseif event == "runtime" then'
assert_contains "$CLOUD" 'return runtime_status(), "runtime"'
assert_contains "$CLOUD" 'return device_status(payload), "device_info"'
assert_contains "$CLOUD" 'return internet_status(), "intinfo"'
assert_contains "$CLOUD" 'return cpe_status(), "cpeinfo"'
assert_contains "$CLOUD" 'return battery_status(), "batinfo"'
assert_contains "$CLOUD" 'sversion = core.software_version()'
assert_contains "$CLOUD" 'ptype = trim_line(board_options.ptype) or "rt"'
assert_contains "$CLOUD" 'wifiauth = tonumber(board_options.wifiauth) or -1'
assert_contains "$CLOUD" 'device_code = current_identity.device_code'
assert_contains "$CLOUD" 'traffic = {'
assert_contains "$CLOUD" 'wired_client = {'
assert_contains "$CLOUD" 'M.publish("cpestatus", { uniq = presence_timestamp() }, false)'
assert_contains "$CLOUD" 'function M.open_cpe_status_publisher()'
assert_contains "$CLOUD" 'function M.publish_cpe_status_stream(stream)'
assert_contains "$CLOUD" 'return M.publish("status", {'
assert_contains "$CLOUD" 'uniq = presence_timestamp()'
assert_not_contains "$CLOUD" 'sys.uniqueid(4) or "00000000"'
assert_contains "$CLOUD" 'state = "permanently_disabled"'
assert_contains "$CLOUD" 'message = "software update permanently disabled"'
assert_not_contains "$CLOUD" '/sbin/sysupgrade'
assert_contains "$CLOUD" 'local function execute(command, timeout)'
assert_contains "$CLOUD" 'core.feature_enabled("remote_web_enable")'
assert_contains "$CLOUD" 'local result, output = execute(prepared_command, 60)'
assert_contains "$CLOUD" 'fs.chmod(path, "0600")'
assert_contains "$CLOUD" 'return remote_sim_switch(payload), "simswitch"'
assert_contains "$CLOUD" 'schedule_remote_sim_switch(slot, requested_mode)'
assert_contains "$CLOUD" 'local control = terminal_control(payload)'
assert_contains "$CLOUD" 'return control, event'
assert_contains "$CLOUD" 'return remote_sms(payload), "sms"'
assert_contains "$CLOUD" 'return station_status(), "stalist"'
assert_contains "$CLOUD" 'state = 6'

REPORTER="$ROOT/files/usr/sbin/c2000max-app-reporter"
assert_contains "$REPORTER" '"presence_interval"'
assert_contains "$REPORTER" 'cloud.publish_online_status()'
assert_contains "$REPORTER" 'cloud.publish_cpe_status()'
assert_contains "$REPORTER" 'cloud.open_cpe_status_publisher()'
assert_contains "$REPORTER" 'cloud.publish_cpe_status_stream(presence_stream)'
assert_contains "$REPORTER" 'cloud.publish_reports()'
assert_contains "$REPORTER" '"report_interval"'
assert_contains "$REMOTE" 'core.note_activity()'

MAKEFILE="$ROOT/Makefile"
assert_contains "$MAKEFILE" '+mosquitto-nossl'
assert_contains "$MAKEFILE" 'PKG_VERSION:=1.10.0'
assert_contains "$MAKEFILE" 'PKG_RELEASE:=16'
for dependency in '+flock' '+blkid' '+ip-full' '+iw' '+uclient-fetch'; do
	assert_contains "$MAKEFILE" "$dependency"
done
assert_contains "$MAKEFILE" 'uci -q delete c2000max_app.main.upgrade_enable'
assert_contains "$MAKEFILE" 'c2000max-app-httpd'
assert_contains "$MAKEFILE" '/etc/init.d/c2000max-app enable'
assert_not_contains "$MAKEFILE" '/etc/init.d/c2000max-app disable'
assert_contains "$MAKEFILE" 'c2000max-app-cache'
assert_contains "$MAKEFILE" 'c2000max-app-wifi-apply'
assert_contains "$MAKEFILE" 'c2000max-app-sim-switch'
assert_not_contains "$MAKEFILE" 'app_v30.js $(1)'

LUCI_MAKEFILE="$LUCI_ROOT/Makefile"
assert_contains "$LUCI_MAKEFILE" 'LUCI_TITLE:=LuCI configuration for C2000-MAX APP support'
assert_contains "$LUCI_MAKEFILE" 'LUCI_DEPENDS:=+c2000max-app'
assert_contains "$LUCI_MAKEFILE" 'PKG_RELEASE:=9'
assert_contains "$LUCI_MAKEFILE" '# call BuildPackage - OpenWrt buildroot signature'
assert_contains "$ACL" '"c2000max_app": [ "set", "restart" ]'

PROFILE="$REPO/target/linux/mediatek/image/filogic.mk"
assert_contains "$PROFILE" 'c2000max-app luci-app-c2000max-app'

CNSPEEDTEST="${ROOT%/c2000max-app}/luci-app-cnspeedtest/root/usr/share/luci/menu.d/luci-app-cnspeedtest.json"
python3 -m json.tool "$CNSPEEDTEST" >/dev/null
assert_contains "$CNSPEEDTEST" '"title": "外网测速"'

QMODEM_HUAWEI="${ROOT%/c2000max-app}/qmodem/application/qmodem/files/usr/share/qmodem/vendor/huawei.sh"
assert_contains "$QMODEM_HUAWEI" 'AT^HFREQINFO?'
assert_contains "$QMODEM_HUAWEI" 'AT^DSAMBR=$cid'
assert_contains "$QMODEM_HUAWEI" 'AT+CGEQOSRDP=$cid'
assert_contains "$QMODEM_HUAWEI" 'cache_c2000max_huawei_detail_'
assert_contains "$QMODEM_HUAWEI" '[ "$age" -ge 0 ] && [ "$age" -le 60 ]'

echo "PASS: V36.10 local cellular and official remote-control compatibility"
for interval in modem_cache selector_cache cache_warm cache_idle \
	signal_normal signal_test signal_carrier
do
	assert_contains "$VIEW" "${interval}_interval"
done
assert_contains "$VIEW" 'cache_active_window'
assert_contains "$VIEW" '数据刷新与缓存'
assert_contains "$RPC" '"modem_cache_interval": "int"'
