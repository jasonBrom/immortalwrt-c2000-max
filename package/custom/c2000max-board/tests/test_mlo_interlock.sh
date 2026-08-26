#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/files/usr/sbin/c2000max-mlo-interlock"
INIT="$ROOT/files/etc/init.d/c2000max-mlo-interlock"
WIFI="$ROOT/../../network/config/wifi-scripts/files/sbin/wifi"
VIEW="$ROOT/../../mtk/applications/luci-app-mtwifi-cfg/root/usr/share/luci-app-mtwifi-cfg/wireless-mtk.js"
RPC="$ROOT/../../mtk/applications/luci-app-mtwifi-cfg/root/usr/share/rpcd/ucode/luci.mtwifi"
ACL="$ROOT/../../mtk/applications/luci-app-mtwifi-cfg/root/usr/share/rpcd/acl.d/luci-app-mtwifi-cfg.json"
DRIVER="$ROOT/../../mtk/applications/mtwifi-cfg-ucode/files/lib/netifd/wireless/mtwifi.sh"

declare -A TYPE DB
COMMITS=0

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

uci()
{
	[[ "${1-}" == -q ]] && shift
	local op="${1-}" arg="${2-}" key value section
	case "$op" in
		show)
			[[ "$arg" == wireless ]] || return 1
			for section in "${!TYPE[@]}"; do
				printf 'wireless.%s=%s\n' "$section" "${TYPE[$section]}"
			done
			for key in "${!DB[@]}"; do
				printf '%s=%s\n' "$key" "${DB[$key]}"
			done
			;;
		get)
			[[ -v "DB[$arg]" ]] || return 1
			printf '%s\n' "${DB[$arg]}"
			;;
		set)
			key="${arg%%=*}"
			value="${arg#*=}"
			DB["$key"]="$value"
			;;
		delete)
			unset 'DB[$arg]'
			;;
		commit)
			[[ "$arg" == wireless ]] || return 1
			((COMMITS+=1))
			;;
		*) return 1 ;;
	esac
}

logger() { :; }

reset_config()
{
	TYPE=(
		[radio2g]=wifi-device
		[radio5g]=wifi-device
		[normal2g]=wifi-iface
		[normal5g]=wifi-iface
		[guest5g]=wifi-iface
		[mlo]=wifi-iface
	)
	DB=(
		[wireless.radio2g.band]=2g
		[wireless.radio5g.band]=5g
		[wireless.normal2g.device]=radio2g
		[wireless.normal2g.mode]=ap
		[wireless.normal2g.ssid]=ImmortalWrt-2.4G
		[wireless.normal2g.encryption]=none
		[wireless.normal5g.device]=radio5g
		[wireless.normal5g.mode]=ap
		[wireless.normal5g.ssid]=ImmortalWrt-5G
		[wireless.normal5g.encryption]=none
		[wireless.guest5g.device]=radio5g
		[wireless.guest5g.mode]=ap
		[wireless.guest5g.disabled]=1
		[wireless.mlo.device]='radio2g radio5g'
		[wireless.mlo.mode]=ap
		[wireless.mlo.mlo]=1
		[wireless.mlo.disabled]=1
	)
	COMMITS=0
}

export C2000MAX_MLO_INTERLOCK_SOURCE_ONLY=1
source "$SCRIPT"

reset_config
sync_interlock
[[ ! -v DB[wireless.normal2g.disabled] && ! -v DB[wireless.normal5g.disabled] ]] ||
	fail "disabled MLO changed ordinary AP state"
[[ "${DB[wireless.normal2g.encryption]}" == none && "${DB[wireless.normal5g.encryption]}" == none ]] ||
	fail "disabled MLO changed open-network security"
[[ "$COMMITS" == 0 ]] || fail "no-op synchronization committed wireless"

unset 'DB[wireless.mlo.disabled]'
sync_interlock
for iface in normal2g normal5g; do
	[[ "${DB[wireless.$iface.disabled]-}" == 1 &&
	   "${DB[wireless.$iface.c2000max_mlo_locked]-}" == 1 ]] ||
		fail "active MLO did not lock $iface"
done
[[ "${DB[wireless.guest5g.disabled]}" == 1 &&
   ! -v DB[wireless.guest5g.c2000max_mlo_locked] ]] ||
	fail "pre-disabled guest AP was claimed by the interlock"
[[ "${DB[wireless.normal2g.encryption]}" == none && "${DB[wireless.normal5g.encryption]}" == none ]] ||
	fail "active MLO modified ordinary AP encryption"
commits_after_lock="$COMMITS"
sync_interlock
[[ "$COMMITS" == "$commits_after_lock" ]] ||
	fail "stable active MLO state caused a redundant wireless commit"

DB[wireless.mlo.disabled]=1
sync_interlock
for iface in normal2g normal5g; do
	[[ ! -v DB[wireless.$iface.disabled] &&
	   ! -v DB[wireless.$iface.c2000max_mlo_locked] ]] ||
		fail "disabled MLO did not restore $iface"
done
[[ "${DB[wireless.guest5g.disabled]}" == 1 ]] ||
	fail "disabled MLO enabled a user-disabled guest AP"
[[ "${DB[wireless.normal2g.encryption]}" == none && "${DB[wireless.normal5g.encryption]}" == none ]] ||
	fail "restore modified ordinary AP encryption"

reset_config
DB[wireless.radio5g.disabled]=1
unset 'DB[wireless.mlo.disabled]'
sync_interlock
[[ ! -v DB[wireless.radio5g.disabled] &&
   "${DB[wireless.radio5g.c2000max_mlo_radio_locked]-}" == 1 ]] ||
	fail "MLO did not temporarily enable its disabled 5 GHz member radio"
DB[wireless.mlo.disabled]=1
sync_interlock
[[ "${DB[wireless.radio5g.disabled]-}" == 1 &&
   ! -v DB[wireless.radio5g.c2000max_mlo_radio_locked] ]] ||
	fail "MLO disable did not restore the prior radio state"

grep -Fq 'verify_interlock || return 1' "$SCRIPT" || fail "helper does not fail closed"
grep -Fq 'START=18' "$INIT" || fail "interlock does not run before network"
grep -Fq 'wifi_interlock_sync' "$WIFI" || fail "wifi reload bypasses the interlock"
grep -Fq '启用 MLO 并停用普通 SSID' "$VIEW" || fail "LuCI lacks an explicit enable warning"
grep -Fq 'callMtwifiSetMloState(section_id, enabled)' "$VIEW" || fail "LuCI toggle bypasses backend transaction"
grep -Fq 'c2000max_mlo_locked' "$VIEW" || fail "LuCI does not block a locked ordinary AP"
grep -Fq 'setMloState' "$RPC" || fail "rpcd lacks the atomic MLO state method"
grep -Fq "run_command('/bin/ubus call network reload 2>&1')" "$RPC" || fail "rpcd uses the wrong ubus path"
grep -Fq 'setMloState' "$ACL" || fail "rpcd ACL does not permit the MLO state method"
grep -Fq 'enforce_runtime_mlo_interlock(data);' "$DRIVER" || fail "driver setup lacks fail-closed interlock"
grep -Fq 'config.mode == '\''ap'\'' && !is_one(config.mlo)' "$DRIVER" ||
	fail "driver setup does not suppress ordinary APs during MLO"
if command -v node >/dev/null 2>&1; then
	node -e 'new Function(require("fs").readFileSync(process.argv[1], "utf8"))' "$VIEW"
fi

echo 'C2000-MAX MLO interlock tests passed'
