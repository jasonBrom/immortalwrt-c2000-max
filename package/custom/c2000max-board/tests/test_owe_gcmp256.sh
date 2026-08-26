#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
HELPER="$ROOT/files/usr/sbin/c2000max-owe-transition"
MTKDAT="$ROOT/../../mtk/drivers/wifi-profile/files/unified_script/mtkdat.lua"
SCHEMA="$ROOT/../../mtk/applications/mtwifi-cfg-ucode/files/usr/share/schema/mtwifi/wireless.iface.json"
NETIFD="$ROOT/../../mtk/applications/mtwifi-cfg-ucode/files/lib/netifd/wireless/mtwifi.sh"
HOSTAPD="$ROOT/../../mtk/drivers/wifi-profile/files/unified_script/hostapd.lua"

fail() { echo "FAIL: $*" >&2; exit 1; }

sh -n "$HELPER" || fail 'OWE lifecycle helper has invalid shell syntax'
python3 -m json.tool "$SCHEMA" >/dev/null || fail 'mtwifi iface schema is invalid JSON'

for option in owe_transition_bssid owe_transition_ssid owe_transition_ifname owe_groups; do
	grep -Fq "\"$option\"" "$SCHEMA" || fail "$option is absent from netifd schema"
	grep -Fq "\"$option\"" "$MTKDAT" || fail "$option is absent from DAT/hostapd UCI projection"
done
grep -Fq 'iface.owe_transition_ifname' "$HOSTAPD" ||
	fail 'hostapd generator does not emit OWE transition pairing'

grep -Fq 'wireless.c2000max_owe_5g.hidden=' "$DEFAULTS" &&
grep -Fq "wireless.c2000max_owe_5g.encryption='owe+gcmp256'" "$DEFAULTS" &&
grep -Fq 'wireless.c2000max_owe_5g.c2000max_factory_owe=' "$DEFAULTS" ||
	fail 'factory hidden OWE partner is incomplete'
grep -Fq 'wireless.$iface.encryption=none' "$DEFAULTS" ||
	fail 'factory visible transition BSS is not open'

grep -Fq 'if [ "$encryption" = none ]' "$HELPER" &&
grep -Fq 'delete_changed "wireless.${main}.owe_transition_bssid"' "$HELPER" &&
grep -Fq 'delete_changed "wireless.${main}.owe_transition_ifname"' "$HELPER" &&
grep -Fq 'set_changed "wireless.${PARTNER_SECTION}.disabled=1"' "$HELPER" ||
	fail 'encryption changes do not suspend and detach the hidden OWE BSS'
grep -Fq 'enforce_runtime_owe_transition(data);' "$NETIFD" &&
grep -Fq 'partner_config.disabled = true;' "$NETIFD" &&
grep -Fq "main_config.encryption == 'none'" "$NETIFD" ||
	fail 'mtwifi setup lacks the runtime OWE lifecycle gate'

declare -A OWE_DB

uci()
{
	[[ "${1-}" == -q ]] && shift
	local op="${1-}" arg="${2-}" key value
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
		set)
			key="${arg%%=*}"
			value="${arg#*=}"
			OWE_DB["$key"]="$value"
			;;
		delete)
			unset "OWE_DB[$arg]"
			;;
		commit) return 0 ;;
		*) return 1 ;;
	esac
}

logger() { return 0; }

# Load the lifecycle functions without executing the command dispatcher.
source <(awk '/^case "\$\{1:-sync\}"/{exit} {print}' "$HELPER")

OWE_DB=(
	[c2000max.wireless.owe_main]=default_5g
	[wireless.default_5g]=wifi-iface
	[wireless.default_5g.c2000max_owe_transition]=1
	[wireless.default_5g.device]=MT7993_1_2
	[wireless.default_5g.network]=lan
	[wireless.default_5g.ssid]=ImmortalWrt-5G
	[wireless.default_5g.encryption]=none
	[wireless.c2000max_owe_5g]=wifi-iface
	[wireless.c2000max_owe_5g.c2000max_factory_owe]=1
	[wireless.c2000max_owe_5g.disabled]=1
)

sync_pair || fail 'open transition BSS could not restore its hidden partner'
[[ "${OWE_DB[wireless.c2000max_owe_5g.encryption]}" == owe+gcmp256 ]] ||
	fail 'restored hidden BSS is not OWE GCMP-256'
[[ "${OWE_DB[wireless.c2000max_owe_5g.hidden]}" == 1 ]] ||
	fail 'restored OWE partner is not hidden'
[[ ! -v 'OWE_DB[wireless.c2000max_owe_5g.disabled]' ]] ||
	fail 'open transition mode left the hidden OWE partner disabled'
[[ "${OWE_DB[wireless.default_5g.owe_transition_ifname]}" == rai1 ]] ||
	fail 'visible BSS was not paired with the hidden OWE interface'

OWE_DB[wireless.default_5g.encryption]=psk2
OWE_DB[wireless.default_5g.owe_transition_bssid]=00:0C:43:26:60:12
sync_pair || fail 'WPA2 switch did not complete OWE lifecycle cleanup'
[[ "${OWE_DB[wireless.c2000max_owe_5g.disabled]}" == 1 ]] ||
	fail 'WPA2 switch left the hidden OWE partner active'
[[ "${OWE_DB[wireless.c2000max_owe_5g.c2000max_owe_suspended]}" == 1 ]] ||
	fail 'WPA2 switch did not mark the hidden partner suspended'
for option in owe_transition_bssid owe_transition_ifname owe_transition_ssid; do
	[[ ! -v "OWE_DB[wireless.default_5g.$option]" ]] ||
		fail "WPA2 switch retained stale $option"
done

OWE_DB[wireless.default_5g.encryption]=none
OWE_DB[wireless.default_5g.ssid]=C2000MAX-5G
sync_pair || fail 'switching back to open did not restore OWE transition mode'
[[ ! -v 'OWE_DB[wireless.c2000max_owe_5g.disabled]' ]] &&
[[ ! -v 'OWE_DB[wireless.c2000max_owe_5g.c2000max_owe_suspended]' ]] ||
	fail 'switching back to open left the OWE partner suspended'
[[ "${OWE_DB[wireless.c2000max_owe_5g.ssid]}" == C2000MAX-5GOWE ]] ||
	fail 'hidden partner SSID did not follow the renamed visible BSS'

OWE_DB[wireless.default_5g.encryption]=owe+gcmp256
sync_pair || fail 'pure OWE switch did not complete hidden-partner cleanup'
[[ "${OWE_DB[wireless.c2000max_owe_5g.disabled]}" == 1 ]] ||
	fail 'pure OWE mode left the transition-only hidden BSS active'

OWE_DB[wireless.default_5g.encryption]=none
OWE_DB[wireless.default_5g.disabled]=1
sync_pair || fail 'disabling the visible BSS did not complete partner cleanup'
[[ "${OWE_DB[wireless.c2000max_owe_5g.disabled]}" == 1 ]] ||
	fail 'disabled visible BSS left the hidden OWE BSS active'

echo 'C2000MAX OWE transition lifecycle tests passed'
