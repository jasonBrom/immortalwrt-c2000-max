#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
HELPER="$ROOT/files/usr/sbin/c2000max-owe-transition"
NETIFD="$ROOT/../../mtk/applications/mtwifi-cfg-ucode/files/lib/netifd/wireless/mtwifi.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

sh -n "$HELPER" || fail 'legacy OWE cleanup helper has invalid shell syntax'

grep -Fq 'wireless.$iface.encryption=owe' "$DEFAULTS" ||
	fail 'factory 5 GHz BSS is not configured for visible single-BSS OWE'
grep -Fq 'wireless.$iface.ieee80211w=2' "$DEFAULTS" ||
	fail 'factory 5 GHz OWE does not require management frame protection'
grep -Fq 'wifi_owe_single_v3610' "$DEFAULTS" ||
	fail 'preserved upgrades do not migrate to single-BSS OWE'
grep -Fq "set wireless.c2000max_owe_5g='wifi-iface'" "$DEFAULTS" &&
	fail 'factory defaults still create the unsupported hidden OWE BSS'
grep -Fq 'enforce_runtime_owe_transition' "$NETIFD" &&
	fail 'mtwifi setup still contains the obsolete two-BSS OWE runtime gate'

grep -Fq 'wireless.${main}.owe_transition_bssid' "$HELPER" &&
grep -Fq 'wireless.${main}.owe_transition_ifname' "$HELPER" &&
grep -Fq 'wireless.${main}.owe_transition_ssid' "$HELPER" &&
grep -Fq 'wireless.${PARTNER_SECTION}.${PARTNER_MARKER}' "$HELPER" ||
	fail 'legacy transition metadata cleanup is incomplete'

declare -A OWE_DB

uci()
{
	[[ "${1-}" == -q ]] && shift
	local op="${1-}" arg="${2-}" key
	case "$op" in
		show)
			[[ "$arg" == wireless ]] || return 1
			printf 'wireless.default_5g=wifi-iface\n'
			printf 'wireless.c2000max_owe_5g=wifi-iface\n'
			;;
		get)
			[[ -v "OWE_DB[$arg]" ]] || return 1
			printf '%s\n' "${OWE_DB[$arg]}"
			;;
		delete)
			for key in "${!OWE_DB[@]}"; do
				[[ "$key" == "$arg" || "$key" == "$arg".* ]] || continue
				unset "OWE_DB[$key]"
			done
			;;
		commit) return 0 ;;
		*) return 1 ;;
	esac
}

# Load functions without executing the command dispatcher.
source <(awk '/^case "\$\{1:-sync\}"/{exit} {print}' "$HELPER")

OWE_DB=(
	[c2000max.wireless.owe_main]=default_5g
	[wireless.default_5g]=wifi-iface
	[wireless.default_5g.c2000max_owe_transition]=1
	[wireless.default_5g.encryption]=none
	[wireless.default_5g.owe_transition_bssid]=00:0C:43:26:60:12
	[wireless.default_5g.owe_transition_ifname]=rai1
	[wireless.default_5g.owe_transition_ssid]=ImmortalWrt-5GOWE
	[wireless.c2000max_owe_5g]=wifi-iface
	[wireless.c2000max_owe_5g.c2000max_factory_owe]=1
)

sync_legacy_pair || fail 'legacy OWE pair cleanup failed'
for key in \
	c2000max.wireless.owe_main \
	wireless.default_5g.c2000max_owe_transition \
	wireless.default_5g.owe_transition_bssid \
	wireless.default_5g.owe_transition_ifname \
	wireless.default_5g.owe_transition_ssid \
	wireless.c2000max_owe_5g; do
	[[ ! -v "OWE_DB[$key]" ]] || fail "legacy state remains: $key"
done
[[ "${OWE_DB[wireless.default_5g.encryption]}" == none ]] ||
	fail 'runtime cleanup overwrote a user-selected encryption mode'

OWE_DB=(
	[wireless.c2000max_owe_5g]=wifi-iface
	[wireless.c2000max_owe_5g.ssid]=User-OWE
)
CHANGED_WIRELESS=0
CHANGED_BOARD=0
sync_legacy_pair || fail 'custom OWE ownership check failed'
[[ "${OWE_DB[wireless.c2000max_owe_5g.ssid]}" == User-OWE ]] ||
	fail 'cleanup removed a user-owned wireless section'

echo 'C2000MAX single-BSS OWE migration tests passed'
