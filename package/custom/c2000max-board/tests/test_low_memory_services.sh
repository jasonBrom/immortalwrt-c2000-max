#!/bin/bash

set -euo pipefail

BOARD_ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TOP="$(CDPATH= cd "$BOARD_ROOT/../../.." && pwd)"
ADB_ROOT="$TOP/feeds/packages/net/adblock-fast"
NB_APP="$TOP/package/custom/luci-app-netbird"
NB_PKG="$TOP/feeds/packages/net/netbird"

if [ ! -d "$ADB_ROOT" ]; then
	ADB_ROOT="$TOP/feed-overlays/packages/net/adblock-fast"
fi
if [ ! -d "$NB_PKG" ]; then
	NB_PKG="$TOP/feed-overlays/packages/net/netbird"
fi

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

ADB_INIT="$ADB_ROOT/files/etc/init.d/adblock-fast"
ADB_CORE="$ADB_ROOT/files/lib/adblock-fast/adblock-fast.uc"
ADB_CONFIG="$ADB_ROOT/files/etc/config/adblock-fast"
NB_SETTINGS="$NB_APP/root/etc/init.d/netbird-settings"
NB_WATCHDOG="$NB_APP/root/usr/share/netbird/netbird-autoreconnect.sh"
NB_STATE="$NB_APP/root/usr/share/rpcd/ucode/lib/state.uc"
NB_RPC="$NB_APP/root/usr/share/rpcd/ucode/netbird.uc"
NB_CLI="$NB_APP/root/usr/share/rpcd/ucode/lib/netbird_cli.uc"
NB_INIT="$NB_PKG/files/netbird.init"

for script in "$ADB_INIT" "$NB_SETTINGS" "$NB_WATCHDOG" "$NB_INIT"; do
	sh -n "$script" || fail "shell syntax failed: $script"
done

grep -Fq "option parallel_downloads '2'" "$ADB_CONFIG" ||
	fail "adblock-fast fresh-install concurrency is not capped at two"
grep -Fq 'low_ram_reserve: 100663296' "$ADB_CORE" ||
	fail "adblock-fast does not reserve 96 MiB for the management plane"
grep -Fq 'low_ram_parallel_cap: 2' "$ADB_CORE" ||
	fail "adblock-fast runtime concurrency cap is missing"
grep -Fq 'echo 500 > /proc/self/oom_score_adj' "$ADB_INIT" ||
	fail "adblock-fast worker has no OOM preference"
grep -Fq 'nice -n 10' "$ADB_INIT" ||
	fail "adblock-fast worker is not de-prioritized"

grep -Fq '_bounded 30s "$bin"' "$NB_SETTINGS" ||
	fail "NetBird settings apply has no bounded up command"
grep -Fq '_bounded 5s "$bin" down' "$NB_SETTINGS" ||
	fail "NetBird down command has no timeout"
grep -Fq 'applying NetBird settings outside rpcd' "$NB_WATCHDOG" ||
	fail "NetBird watchdog does not use the out-of-rpcd reconnect path"
grep -Fq 'echo 500 > /proc/self/oom_score_adj' "$NB_WATCHDOG" ||
	fail "NetBird reconnect worker has no OOM preference"
if grep -Eq 'ubus .*luci\.netbird .*do_up' "$NB_WATCHDOG"; then
	fail "NetBird watchdog still blocks rpcd with do_up"
fi
grep -Fq 'timeout 2s ' "$NB_STATE" ||
	fail "NetBird state probe timeout is not two seconds"
grep -Fq 'probe_state(true)' "$NB_RPC" ||
	fail "NetBird normal RPC paths do not use the fast state probe"
grep -Fq 'timeout 2s ' "$NB_CLI" ||
	fail "NetBird hot-path CLI timeout is not two seconds"
grep -Fq "message: 'timeout after 2s'" "$NB_CLI" ||
	fail "NetBird hot-path timeout message does not match its wall clock"

grep -Fq 'echo 500 > /proc/self/oom_score_adj' "$NB_INIT" ||
	fail "NetBird daemon has no OOM preference"
grep -Fq 'procd_set_param nice 10' "$NB_INIT" ||
	fail "NetBird daemon is not de-prioritized"
grep -Fq 'procd_set_param respawn 3600 5 5' "$NB_INIT" ||
	fail "NetBird daemon has no bounded respawn policy"

# Exercise the helper itself: a command that sleeps for five seconds must be
# terminated near its one-second wall clock, not inherited as an unbounded wait.
(
	# shellcheck disable=SC1090
	source "$NB_SETTINGS"
	start="$(date +%s)"
	if _bounded 1s sh -c 'sleep 5'; then
		fail "NetBird timeout helper accepted a hung command"
	fi
	elapsed=$(( $(date +%s) - start ))
	[ "$elapsed" -le 4 ] ||
		fail "NetBird timeout helper took ${elapsed}s for a one-second limit"
)

grep -Fq 'PKG_VERSION:=2.35.21' "$BOARD_ROOT/Makefile" ||
	fail "board package version is not V35.21"
grep -Fq 'PKG_RELEASE:=14' "$NB_APP/Makefile" ||
	fail "luci-app-netbird release was not bumped"
grep -Fq 'PKG_RELEASE:=2' "$NB_PKG/Makefile" ||
	fail "netbird package release was not bumped"
grep -Fq 'PKG_RELEASE:=5' "$ADB_ROOT/Makefile" ||
	fail "adblock-fast package release was not bumped"

echo 'C2000-MAX low-memory service tests passed'
