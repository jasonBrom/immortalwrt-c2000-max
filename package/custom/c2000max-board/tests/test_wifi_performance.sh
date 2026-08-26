#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/files/usr/sbin/c2000max-wifi-performance"
INIT="$ROOT/files/etc/init.d/c2000max-wifi-performance"
WIRELESS_VIEW="$ROOT/../../mtk/applications/luci-app-mtwifi-cfg/root/usr/share/luci-app-mtwifi-cfg/wireless-mtk.js"
RPC="$ROOT/../../mtk/applications/luci-app-mtwifi-cfg/root/usr/share/rpcd/ucode/luci.mtwifi"
SYSTEM_VIEW="$ROOT/../../../feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/system.js"
SYSTEM_ACL="$ROOT/../../../feeds/luci/modules/luci-mod-system/root/usr/share/rpcd/acl.d/luci-mod-system.json"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

PROFILE="$TMPDIR/mt7993.1.dat"
cat > "$PROFILE" <<'EOF'
Default
PciL1ss=1
LpOption=2:1
TpoEn=1
EOF

MODE=0
declare -a MWCTL_CALLS=()
RUNTIME_PCI=1
RUNTIME_LP_SELECT=2
RUNTIME_LP_VALUE=1
FAIL_MATCH=

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

uci()
{
	[[ "${1-}" == -q ]] && shift
	local op="${1-}" arg="${2-}"
	case "$op" in
		get)
			case "$arg" in
				c2000max.wifi_performance) return 0 ;;
				c2000max.wifi_performance.enabled) printf '%s\n' "$MODE" ;;
				*) return 1 ;;
			esac
			;;
		set)
			[[ "$arg" == c2000max.wifi_performance=wifi_performance ]] && return 0
			[[ "$arg" =~ ^c2000max\.wifi_performance\.enabled=([01])$ ]] || return 1
			MODE="${BASH_REMATCH[1]}"
			;;
		commit) [[ "$arg" == c2000max ]] ;;
		*) return 1 ;;
	esac
}

logger() { :; }

export C2000MAX_WIFI_PERF_SOURCE_ONLY=1
export C2000MAX_WIFI_PERF_PROFILE="$PROFILE"
export C2000MAX_WIFI_PERF_INTERFACE=ra0
source "$SCRIPT"

# Exercise the real runtime and readback logic with a stateful driver mock.
run_mwctl()
{
	local command="$*" parameter
	MWCTL_CALLS+=("$command")

	if [[ "${2-}" == set ]]; then
		parameter="${3-}"
		[[ -z "$FAIL_MATCH" || "$command" != *"$FAIL_MATCH"* ]] || return 1
		case "$parameter" in
			PciL1ss=*) RUNTIME_PCI="${parameter#*=}" ;;
			LpOption=*)
				RUNTIME_LP_SELECT="${parameter#*=}"
				RUNTIME_LP_VALUE="${RUNTIME_LP_SELECT#*:}"
				RUNTIME_LP_SELECT="${RUNTIME_LP_SELECT%%:*}"
				;;
		esac
		return 0
	fi

	if [[ "${2-}" == show && "${3-}" == lpinfo ]]; then
		printf 'L1ss: %s\n' "$RUNTIME_PCI"
		printf 'Profile LPOption: (2:1)\n'
		printf 'Last LPOption: (%s,%s,0,0)\n' "$RUNTIME_LP_SELECT" "$RUNTIME_LP_VALUE"
		return 0
	fi

	return 1
}

set_mode 1
[[ "$MODE" == 1 ]] || fail 'high-performance mode was not persisted'
grep -qx 'PciL1ss=0' "$PROFILE" || fail 'L1SS was not disabled'
grep -qx 'LpOption=2:0' "$PROFILE" || fail 'low-power features were not disabled'
[[ " ${MWCTL_CALLS[*]} " == *' ra0 set PciL1ss=0 '* ]] || fail 'runtime L1SS command missing'
[[ " ${MWCTL_CALLS[*]} " == *' ra0 set LpOption=2:0 '* ]] || fail 'runtime LP command missing'
grep -Fq '"$MWCTL_BIN" dev "$@"' "$SCRIPT" || fail 'mwctl scripting form does not identify the netdev explicitly'

set_mode 0
[[ "$MODE" == 0 ]] || fail 'normal mode was not restored'
grep -qx 'PciL1ss=1' "$PROFILE" || fail 'normal L1SS default was not restored'
grep -qx 'LpOption=2:1' "$PROFILE" || fail 'normal LP default was not restored'

set_mode 1
FAIL_MATCH='LpOption=2:1'
if set_mode 0; then
	fail 'a rejected runtime command was reported as success'
fi
[[ "$MODE" == 1 ]] || fail 'failed switch did not roll UCI back'
grep -qx 'PciL1ss=0' "$PROFILE" || fail 'failed switch did not roll the profile back'
grep -qx 'LpOption=2:0' "$PROFILE" || fail 'failed switch did not roll LP profile back'

grep -Fq 'START=17' "$INIT" || fail 'profile is not applied before network startup'
grep -Fq 'getWifiPerformanceState' "$RPC" || fail 'status RPC is missing'
grep -Fq 'setWifiPerformanceState' "$RPC" || fail 'toggle RPC is missing'
grep -Fq 'setWifiPerformanceState' "$SYSTEM_ACL" || fail 'system page toggle RPC permission is missing'
grep -Fq '无线性能模式' "$SYSTEM_VIEW" || fail 'system page toggle is missing'
if grep -Fq 'renderWifiPerformancePanel' "$WIRELESS_VIEW"; then
	fail 'obsolete wireless-page performance card is still present'
fi
if command -v node >/dev/null 2>&1; then
	node -e 'new Function(require("fs").readFileSync(process.argv[1], "utf8"))' "$WIRELESS_VIEW"
	node -e 'new Function(require("fs").readFileSync(process.argv[1], "utf8"))' "$SYSTEM_VIEW"
fi

echo 'C2000-MAX Wi-Fi performance mode tests passed'
