#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/files/usr/sbin/c2000max-access"
HNAT="$ROOT/files/etc/init.d/c2000max-hnat"
VIEW="$ROOT/files/www/luci-static/resources/view/c2000max/access_v352.js"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

declare -A DB
declare -a DEVICE_SECTIONS
NFT_ACTIVE=0
NFT_LOG="$TMP/nft.log"
TABLE=c2000max_access

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
			[[ -v "DB[$arg]" ]] || return 1
			printf '%s\n' "${DB[$arg]}"
			;;
		*)
			return 1
			;;
	esac
}

ubus() { return 1; }
jsonfilter() { return 1; }
logger() { return 0; }

config_load() { return 0; }
config_get()
{
	local out="$1" section="$2" option="$3" default="${4-}"
	printf -v "$out" '%s' "${DB[c2000max.$section.$option]-$default}"
}
config_get_bool() { config_get "$@"; }
config_foreach()
{
	local callback="$1" type="$2" section
	[[ "$type" == access_device ]] || return 0
	for section in "${DEVICE_SECTIONS[@]}"; do
		"$callback" "$section"
	done
}

mock_nft()
{
	if [[ "${1-}" == list && "${2-}" == table ]]; then
		[[ "$NFT_ACTIVE" == 1 ]]
		return
	fi
	if [[ "${1-}" == delete && "${2-}" == table ]]; then
		NFT_ACTIVE=0
		return
	fi
	if [[ "${1-}" == -f ]]; then
		cp "$2" "$NFT_LOG"
		NFT_ACTIVE=1
		return
	fi
	return 1
}

source <(awk '/^json_escape/{emit=1} /^mkdir -p /{exit} emit{print}' "$SCRIPT")

NFT=mock_nft
LOCK="$TMP/access.lock"
HNAT_EFFECTIVE="$TMP/hnat-effective"
HNAT_HOOK="$TMP/hook-toggle"
NFT_SCRIPT="$TMP/access.nft"

reload_hnat()
{
	DB["firewall.@defaults[0].flow_offloading"]=0
	DB["firewall.@defaults[0].flow_offloading_hw"]=0
	printf 'disabled\n' > "$HNAT_EFFECTIVE"
	printf 'disabled\n' > "$HNAT_HOOK"
}

reset_policy()
{
	DB=(
		[c2000max.access_control.enabled]=0
		[c2000max.access_control.mode]=blacklist
		[c2000max.access_control.lan_device]=auto
		[network.lan.device]=br-lan
		["firewall.@defaults[0].flow_offloading"]=0
		["firewall.@defaults[0].flow_offloading_hw"]=0
	)
	DEVICE_SECTIONS=()
	NFT_ACTIVE=0
	: > "$NFT_LOG"
	printf 'disabled\n' > "$HNAT_EFFECTIVE"
	printf 'disabled\n' > "$HNAT_HOOK"
	ACCESS_ENABLED=0
	ACCESS_MODE=blacklist
	ACCESS_LAN=auto
}

reset_policy
output="$(apply_policy)"
grep -Fq '"success":true' <<<"$output" ||
	fail "disabled default did not apply successfully"
[[ "$NFT_ACTIVE" == 0 ]] ||
	fail "disabled default left an nftables table active"

reset_policy
DB[c2000max.access_control.enabled]=1
DEVICE_SECTIONS=(phone tv duplicate)
DB[c2000max.phone.enabled]=1
DB[c2000max.phone.mac]='02:11:22:33:44:55'
DB[c2000max.tv.enabled]=1
DB[c2000max.tv.mac]='06:AA:BB:CC:DD:EE'
DB[c2000max.duplicate.enabled]=1
DB[c2000max.duplicate.mac]='02:11:22:33:44:55'
output="$(apply_policy)"
grep -Fq '"success":true' <<<"$output" ||
	fail "blacklist policy did not apply"
grep -Fq 'ether saddr @devices counter drop' "$NFT_LOG" ||
	fail "blacklist did not emit a MAC drop rule"
! grep -Fq 'counter return' "$NFT_LOG" ||
	fail "blacklist emitted a whitelist return rule"
[[ "$(grep -o '02:11:22:33:44:55' "$NFT_LOG" | wc -l)" == 1 ]] ||
	fail "duplicate MAC address was not collapsed"
grep -Fq '06:AA:BB:CC:DD:EE' "$NFT_LOG" ||
	fail "second blacklist device is missing"

reset_policy
DB[c2000max.access_control.enabled]=1
DB[c2000max.access_control.mode]=whitelist
DEVICE_SECTIONS=(laptop)
DB[c2000max.laptop.enabled]=1
DB[c2000max.laptop.mac]='0A:10:20:30:40:50'
output="$(apply_policy)"
grep -Fq '"success":true' <<<"$output" ||
	fail "whitelist policy did not apply"
grep -Fq 'ether saddr @devices counter return' "$NFT_LOG" ||
	fail "whitelist did not allow listed MAC addresses"
grep -Fq 'iifname "br-lan" counter drop' "$NFT_LOG" ||
	fail "whitelist did not drop every unlisted LAN forward"

reset_policy
DB[c2000max.access_control.enabled]=1
DB[c2000max.access_control.mode]=whitelist
output="$(apply_policy)"
grep -Fq '"success":true' <<<"$output" ||
	fail "empty whitelist did not apply"
grep -Fq 'iifname "br-lan" counter drop' "$NFT_LOG" ||
	fail "empty whitelist did not block all forwarded LAN traffic"
! grep -Fq 'hook input' "$NFT_LOG" ||
	fail "access control unexpectedly blocks router management input"

reset_policy
DB[c2000max.access_control.enabled]=1
DEVICE_SECTIONS=(bad)
DB[c2000max.bad.enabled]=1
DB[c2000max.bad.mac]='01:00:5E:00:00:01'
if output="$(apply_policy)"; then
	fail "multicast MAC address was accepted"
fi
grep -Fq '"success":false' <<<"$output" ||
	fail "invalid MAC did not return structured failure JSON"
[[ "$NFT_ACTIVE" == 0 ]] ||
	fail "invalid policy changed the active nftables state"

grep -Fq 'access_enabled="$(uci -q get c2000max.access_control.enabled)"' "$HNAT" ||
	fail "HNAT controller does not read the access-control gate"
grep -A4 -F 'if [ "$access_enabled" = 1 ]; then' "$HNAT" |
	grep -Fq 'converge_non_hnat disabled' ||
	fail "HNAT controller does not force a non-accelerated policy"
grep -Fq 'hook forward priority -10' "$SCRIPT" ||
	fail "rules are not installed before the fw4 forward hook"
grep -Fq 'option enabled '\''0'\''' "$ROOT/files/etc/config/c2000max" ||
	fail "access control is not disabled by default"
! grep -Fq 'm.handleSaveApply.bind' "$VIEW" ||
	fail "LuCI view still binds a form.Map method that does not exist"
grep -Fq "this.super('handleSave', arguments)" "$VIEW" ||
	fail "LuCI view does not apply rules through the view save handler"
if command -v node >/dev/null 2>&1; then
	node "$ROOT/tests/test_luci_access_view.js" "$VIEW"
fi

echo 'C2000-MAX device access-control tests passed'
