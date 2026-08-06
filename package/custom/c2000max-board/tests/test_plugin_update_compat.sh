#!/bin/bash

set -euo pipefail

BOARD_ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TOP="$(CDPATH= cd "$BOARD_ROOT/../../.." && pwd)"
ADB_HELPER="$BOARD_ROOT/files/usr/sbin/c2000max-adblock-compat"
NB_JOB="$BOARD_ROOT/files/usr/sbin/c2000max-netbird-job"
NB_WORKER="$BOARD_ROOT/files/usr/sbin/c2000max-service-worker"
NB_VIEW="$BOARD_ROOT/files/www/luci-static/resources/view/c2000max/netbird_async_v353.js"
NB_MENU="$BOARD_ROOT/files/usr/share/luci/menu.d/zzzz-c2000max-netbird.json"
NB_RPC="$BOARD_ROOT/files/usr/libexec/rpcd/c2000max"
NB_ACL="$BOARD_ROOT/files/usr/share/rpcd/acl.d/c2000max.json"
PLUGIN_VIEW="$TOP/package/custom/luci-app-netbird/htdocs/luci-static/resources/view/netbird/overview.js"
PLUGIN_MENU="$TOP/package/custom/luci-app-netbird/root/usr/share/luci/menu.d/luci-app-netbird.json"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

for script in "$ADB_HELPER" "$NB_JOB" "$NB_WORKER"; do
	sh -n "$script" || fail "shell syntax failed: $script"
done
node --check "$NB_VIEW" || fail "board-owned NetBird view has invalid JavaScript"
python3 -m json.tool "$NB_MENU" >/dev/null ||
	fail "board-owned NetBird menu has invalid JSON"
python3 -m json.tool "$NB_ACL" >/dev/null ||
	fail "board ACL has invalid JSON"

for dep in gawk grep sed coreutils-sort luci-app-netbird netbird; do
	grep -Eq "(^|[[:space:]\\\\])\\+${dep}([[:space:]\\\\]|$)" "$BOARD_ROOT/Makefile" ||
		fail "board package does not own dependency: $dep"
done

grep -Fq 'HaGeZi - Light (C2000-MAX)' "$ADB_HELPER" ||
	fail "small default AdBlock source is missing"
grep -Fq '/etc/init.d/adblock-fast restart' "$ADB_HELPER" ||
	fail "AdBlock is not retried after an updated plugin resets its config"
grep -Fq 'ensure-if-enabled' "$NB_WORKER" ||
	fail "board worker does not repair AdBlock configuration after updates"
grep -Fq 'refresh-status' "$NB_WORKER" ||
	fail "NetBird status is not refreshed outside rpcd"
grep -Fq 'luci[.]netbird.*do_up' "$NB_WORKER" ||
	fail "blocking plugin watchdog upgrade guard is missing"

grep -Fq "object: 'c2000max'" "$NB_VIEW" ||
	fail "NetBird page does not use the board RPC object"
grep -Fq "method: 'netbird_job_start'" "$NB_VIEW" ||
	fail "NetBird page does not enqueue background jobs"
grep -Fq "method: 'netbird_job_status'" "$NB_VIEW" ||
	fail "NetBird page does not poll background job state"
if grep -Eq "object:[[:space:]]*'luci[.]netbird'|L[.]env[.]rpctimeout|callDoUp" "$NB_VIEW"; then
	fail "NetBird page still enters the plugin's blocking RPC path"
fi
grep -Fq '"netbird_job_start"' "$NB_RPC" ||
	fail "board RPC does not expose NetBird job enqueue"
grep -Fq '"netbird_job_status"' "$NB_RPC" ||
	fail "board RPC does not expose NetBird job status"

# The read RPC must only consume the board cache.  The two-second CLI probe is
# allowed solely in refresh_status(), which runs in the independent worker.
compat_body="$(sed -n '/^compat_status()/,/^refresh_status()/p' "$NB_JOB")"
if printf '%s\n' "$compat_body" | grep -Fq 'status --json'; then
	fail "NetBird read RPC still executes the CLI synchronously"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/menu" "$tmp/view" "$tmp/netbird-run"

cat > "$tmp/functions.sh" <<'EOF'
config_load()
{
	return 0
}

config_foreach()
{
	local callback="$1"
	[ "${MOCK_SOURCE:-0}" = 1 ] && "$callback" custom
}

config_get()
{
	local target="$1"
	local option="$3"
	local fallback="${4:-}"
	local value="$fallback"

	if [ "${MOCK_SOURCE:-0}" = 1 ]; then
		case "$option" in
			enabled) value=1 ;;
			action) value=block ;;
			url) value='https://example.invalid/custom.txt' ;;
		esac
	fi
	eval "$target=\"\$value\""
}
EOF

cat > "$tmp/bin/uci" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_UCI_LOG"
if [ "$1" = -q ] && [ "$2" = get ]; then
	case "$3" in
		adblock-fast.config) echo adblock-fast ;;
		adblock-fast.config.parallel_downloads) echo "${MOCK_PARALLEL:-8}" ;;
		adblock-fast.config.blocked_domain)
			[ -z "${MOCK_LOCAL_DOMAINS:-}" ] || echo "$MOCK_LOCAL_DOMAINS"
			;;
	esac
fi
exit 0
EOF
chmod +x "$tmp/bin/uci"
printf 'MemTotal:        524288 kB\n' > "$tmp/meminfo"

export MOCK_UCI_LOG="$tmp/uci.log"
: > "$MOCK_UCI_LOG"
PATH="$tmp/bin:$PATH" \
	MOCK_SOURCE=0 MOCK_PARALLEL=8 \
	C2000MAX_FUNCTIONS_SH="$tmp/functions.sh" \
	C2000MAX_MEMINFO="$tmp/meminfo" \
	sh "$ADB_HELPER" seed
grep -Fq 'set adblock-fast.config.parallel_downloads=2' "$MOCK_UCI_LOG" ||
	fail "512 MiB concurrency was not repaired"
grep -Fq 'set adblock-fast.c2000max_light.enabled=1' "$MOCK_UCI_LOG" ||
	fail "empty upstream configuration did not receive a usable source"

: > "$MOCK_UCI_LOG"
PATH="$tmp/bin:$PATH" \
	MOCK_SOURCE=1 MOCK_PARALLEL=2 \
	C2000MAX_FUNCTIONS_SH="$tmp/functions.sh" \
	C2000MAX_MEMINFO="$tmp/meminfo" \
	sh "$ADB_HELPER" seed
if grep -Fq 'c2000max_light' "$MOCK_UCI_LOG"; then
	fail "an enabled user-selected AdBlock source was overwritten"
fi

: > "$MOCK_UCI_LOG"
PATH="$tmp/bin:$PATH" \
	MOCK_SOURCE=0 MOCK_LOCAL_DOMAINS='ads.example.test' MOCK_PARALLEL=2 \
	C2000MAX_FUNCTIONS_SH="$tmp/functions.sh" \
	C2000MAX_MEMINFO="$tmp/meminfo" \
	sh "$ADB_HELPER" seed
if grep -Fq 'c2000max_light' "$MOCK_UCI_LOG"; then
	fail "a user-maintained local block list was overwritten"
fi

# Simulate both plugin APKs replacing every file they own.  The lexically-late
# board menu and its view remain separate package-owned files and still win.
cp "$PLUGIN_MENU" "$tmp/menu/luci-app-netbird.json"
cp "$NB_MENU" "$tmp/menu/zzzz-c2000max-netbird.json"
cp "$PLUGIN_VIEW" "$tmp/view/overview.js"
cp "$NB_VIEW" "$tmp/view/netbird_async_v353.js"
printf '%s\n' '{"updated-plugin":true}' > "$tmp/menu/luci-app-netbird.json"
printf '%s\n' "'use strict'; /* updated plugin view */" > "$tmp/view/overview.js"

[ -s "$tmp/menu/zzzz-c2000max-netbird.json" ] ||
	fail "plugin update removed the board menu override"
[ -s "$tmp/view/netbird_async_v353.js" ] ||
	fail "plugin update removed the board asynchronous view"
[ "$(find "$tmp/menu" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort | tail -n 1)" = \
	zzzz-c2000max-netbird.json ] ||
	fail "board menu override is not loaded after the plugin menu"
grep -Fq 'c2000max/netbird_async_v353' "$tmp/menu/zzzz-c2000max-netbird.json" ||
	fail "board menu no longer routes Authentication to the asynchronous view"

echo 'C2000-MAX plugin-update compatibility tests passed'
