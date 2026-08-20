#!/bin/bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
DIAL="$ROOT/files/usr/share/qmodem/modem_dial.sh"
BOARD_DEFAULTS="$ROOT/../../../c2000max-board/files/etc/uci-defaults/99-c2000max-defaults"

fail()
{
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

declare -A DB
ADD_LIST_CALLS=0
DEBUG_LOG=""

uci()
{
	local args=() arg key value current

	for arg in "$@"; do
		[ "$arg" = -q ] || args+=("$arg")
	done
	case "${args[0]-}" in
		show)
			[ "${args[1]-}" = firewall ] || return 1
			printf '%s\n' \
				"firewall.@zone[0]=zone" \
				"firewall.@zone[0].name='guest'" \
				"firewall.@zone[3]=zone" \
				"firewall.@zone[3].name='wan'"
			;;
		get)
			key="${args[1]}"
			[ -v "DB[$key]" ] || return 1
			printf '%s\n' "${DB[$key]}"
			;;
		add_list)
			key="${args[1]%%=*}"
			value="${args[1]#*=}"
			current="${DB[$key]-}"
			DB[$key]="${current:+$current }$value"
			ADD_LIST_CALLS=$((ADD_LIST_CALLS + 1))
			;;
		*) return 1 ;;
	esac
}

m_debug()
{
	DEBUG_LOG="${DEBUG_LOG}${DEBUG_LOG:+\n}$*"
}

# Load only the two firewall helpers; sourcing the full dialer would start a
# modem operation at the bottom of the production script.
eval "$(sed -n '/^find_wan_fw_zone()/,/^set_if()/p' "$DIAL" | sed '$d')"

DB['firewall.@zone[3].network']='wan wan6 custom_uplink'
firewall_reload_flag=0

[ "$(find_wan_fw_zone)" = '@zone[3]' ] ||
	fail 'the actual WAN zone section was not resolved'
ensure_wan_zone_network eth2 || fail 'eth2 could not be added to WAN'
[ "${DB['firewall.@zone[3].network']}" = 'wan wan6 custom_uplink eth2' ] ||
	fail 'adding eth2 overwrote an existing custom WAN network list'
[ "$firewall_reload_flag" = 1 ] ||
	fail 'a firewall reload was not requested after changing the zone'
[ "$ADD_LIST_CALLS" = 1 ] || fail 'eth2 was not added exactly once'

firewall_reload_flag=0
ensure_wan_zone_network eth2 || fail 'idempotent eth2 repair failed'
[ "$ADD_LIST_CALLS" = 1 ] || fail 'idempotent repair duplicated eth2'
[ "$firewall_reload_flag" = 0 ] ||
	fail 'unchanged firewall membership requested an unnecessary reload'

# Both calls must be outside QModem's create-only branches so an interface
# preserved in /etc/config/network is repaired on the next dial attempt.
awk '
	/^set_if\(\)/ { in_set_if=1 }
	in_set_if && /\[ -z "\$interface" \]/ { in_create4=1 }
	in_set_if && /\[ -z "\$interfacev6" \]/ { in_create6=1 }
	in_set_if && /ensure_wan_zone_network "\$interface_name"/ {
		if (in_create4) exit 11
		seen4=1
	}
	in_set_if && /ensure_wan_zone_network "\$interface6_name"/ {
		if (in_create6) exit 12
		seen6=1
	}
	in_create4 && /^        fi$/ { in_create4=0 }
	in_create6 && /^        fi$/ { in_create6=0 }
	END { if (!seen4 || !seen6) exit 13 }
' "$DIAL" || fail 'zone repair is still restricted to newly-created interfaces'

grep -Eq 'for wan_network in .*eth2 eth2v6' "$BOARD_DEFAULTS" ||
	fail 'C2000-MAX upgrade defaults do not fail-close the reserved QModem networks'

printf 'PASS: QModem interfaces are added idempotently to the actual WAN zone\n'
