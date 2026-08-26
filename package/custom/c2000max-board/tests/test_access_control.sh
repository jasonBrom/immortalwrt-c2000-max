#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/files/usr/sbin/c2000max-access"
VIEW="$ROOT/files/www/luci-static/resources/view/c2000max/access_v352.js"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

sh -n "$SCRIPT" || fail 'access-control helper has invalid shell syntax'

declare -A DB

uci()
{
	[[ "${1-}" == -q ]] && shift
	local op="${1-}" arg="${2-}" key value
	case "$op" in
		get)
			[[ -v "DB[$arg]" ]] || return 1
			printf '%s\n' "${DB[$arg]}"
			;;
		set)
			key="${arg%%=*}"
			value="${arg#*=}"
			DB["$key"]="$value"
			;;
		add_list)
			key="${arg%%=*}"
			value="${arg#*=}"
			DB["$key"]="${DB[$key]-}${DB[$key]:+ }$value"
			;;
		delete)
			for key in "${!DB[@]}"; do
				if [[ "$key" == "$arg" || "$key" == "$arg".* ]]; then
					unset "DB[$key]"
				fi
			done
			;;
		*) return 1 ;;
	esac
}

# Import only the helper functions; do not execute its daemon entry point.
source <(awk '/^json_escape/{emit=1} /^mkdir -p /{exit} emit{print}' "$SCRIPT")

RULE_ALLOW=c2000max_access_allow
RULE_BLOCK=c2000max_access_block

DB[firewall.$RULE_ALLOW.c2000max_access]=1
DB[firewall.$RULE_BLOCK.c2000max_access]=1
ACCESS_ENABLED=0
ACCESS_MODE=blacklist
ACCESS_COUNT=0
ACCESS_MACS=''
write_firewall_policy || fail 'disabled policy could not remove managed rules'
[[ ! -v 'DB[firewall.c2000max_access_allow.c2000max_access]' ]] ||
	fail 'disabled policy retained the allow rule'
[[ ! -v 'DB[firewall.c2000max_access_block.c2000max_access]' ]] ||
	fail 'disabled policy retained the block rule'

DB=()
ACCESS_ENABLED=1
ACCESS_MODE=blacklist
ACCESS_COUNT=2
ACCESS_MACS='02:11:22:33:44:55 06:AA:BB:CC:DD:EE'
write_firewall_policy || fail 'blacklist policy generation failed'
[[ "${DB[firewall.$RULE_BLOCK.target]}" == REJECT ]] ||
	fail 'blacklist did not generate a reject rule'
[[ "${DB[firewall.$RULE_BLOCK.src_mac]}" == *'02:11:22:33:44:55'* ]] &&
[[ "${DB[firewall.$RULE_BLOCK.src_mac]}" == *'06:AA:BB:CC:DD:EE'* ]] ||
	fail 'blacklist MAC entries are incomplete'

DB=()
ACCESS_ENABLED=1
ACCESS_MODE=whitelist
ACCESS_COUNT=1
ACCESS_MACS='0A:10:20:30:40:50'
write_firewall_policy || fail 'whitelist policy generation failed'
[[ "${DB[firewall.$RULE_ALLOW.target]}" == ACCEPT ]] ||
	fail 'whitelist did not generate an allow rule'
[[ "${DB[firewall.$RULE_BLOCK.target]}" == REJECT ]] ||
	fail 'whitelist did not generate a final reject rule'

normalize_mac '02:11:22:33:44:55' >/dev/null ||
	fail 'valid unicast MAC was rejected'
if normalize_mac '01:00:5E:00:00:01' >/dev/null; then
	fail 'multicast MAC was accepted'
fi

grep -Fq 'uci -q export firewall' "$SCRIPT" &&
grep -Fq 'uci -q import firewall' "$SCRIPT" ||
	fail 'firewall update does not have transactional rollback'
grep -Fq 'flush flowtable inet fw4 ft' "$SCRIPT" ||
	fail 'rule update does not invalidate the existing flowtable cache'
if grep -Eq 'converge_non_hnat|flow_offloading_hw=0|hook forward priority' "$SCRIPT"; then
	fail 'access control still disables acceleration or installs a private forward hook'
fi
grep -Fq "option enabled '0'" "$ROOT/files/etc/config/c2000max" ||
	fail 'access control is not disabled by default'
grep -Fq "this.super('handleSave', arguments)" "$VIEW" ||
	fail 'LuCI view does not apply rules through its save handler'

if command -v node >/dev/null 2>&1; then
	node "$ROOT/tests/test_luci_access_view.js" "$VIEW"
fi

echo 'C2000-MAX device access-control tests passed'
