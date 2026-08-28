#!/bin/sh
set -eu

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$HERE/.." && pwd)"
SRC="$ROOT/src"
BACKEND="$ROOT/files/usr/sbin/c2000max-ip-family"
RPC="$ROOT/files/usr/libexec/rpcd/c2000max"
VIEW="$ROOT/files/www/luci-static/resources/view/c2000max/ip_family.js"
CONFIG="$ROOT/files/etc/config/c2000max"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
MENU="$ROOT/files/usr/share/luci/menu.d/c2000max.json"
ACL="$ROOT/files/usr/share/rpcd/acl.d/c2000max.json"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT INT TERM

cc -O2 -std=c99 -Wall -Wextra -Werror -Wformat=2 \
	-o "$TMPDIR_TEST/c2000max-stun" "$SRC/c2000max-stun.c"

"$TMPDIR_TEST/c2000max-stun" --validate-address ipv4 223.5.5.5
! "$TMPDIR_TEST/c2000max-stun" --validate-address ipv4 999.5.5.5
"$TMPDIR_TEST/c2000max-stun" --validate-address ipv6 2400:3200::1
! "$TMPDIR_TEST/c2000max-stun" --validate-address ipv6 2400:::1

if "$TMPDIR_TEST/c2000max-stun" -6 no-such-stun-host.invalid:3478 \
		>"$TMPDIR_TEST/error.json"; then
	echo 'Expected an IPv6 DNS failure for the reserved invalid domain' >&2
	exit 1
fi
python3 - "$TMPDIR_TEST/error.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    result = json.load(handle)
assert result["success"] is False
assert result["family"] == "ipv6"
assert result["error"] == "dns_no_ipv6_address"
PY

sh -n "$BACKEND"
sh -n "$RPC"
sh -n "$DEFAULTS"
python3 -m json.tool "$MENU" >/dev/null
python3 -m json.tool "$ACL" >/dev/null
sh "$RPC" list | python3 -m json.tool >/dev/null

grep -Fq 'ATTR_OTHER_ADDRESS' "$SRC/c2000max-stun.c"
grep -Fq 'CHANGE_IP | CHANGE_PORT' "$SRC/c2000max-stun.c"
grep -Fq 'endpoint_independent' "$SRC/c2000max-stun.c"
grep -Fq 'stun.miwifi.com:3478' "$VIEW"
grep -Fq 'stun.hot-chilli.net:3478' "$VIEW"
grep -Fq 'stun.voipbuster.com:3478' "$VIEW"
grep -Fq 'stun.telnyx.com:3478' "$VIEW"
grep -Fq 'stun.cloudflare.com:3478' "$VIEW"
grep -Fq 'global.stun.twilio.com:3478' "$VIEW"
grep -Fq 'stun.l.google.com:19302' "$VIEW"
grep -Fq 'c2000-family-tabbar' "$VIEW"
grep -Fq "if (family === 'ipv6')" "$VIEW"
grep -Fq "row('地址转换'" "$VIEW"
grep -Fq 'IPv6 连通性与 UDP 防火墙检测' "$VIEW"
grep -Fq 'IPv6 不显示 RFC 3489 锥形 NAT 类型' "$VIEW"
grep -Fq '本次仅完成基础 STUN 连通性与反射端点检测' "$VIEW"
! grep -Fq "E('h3', {}, 'IPv6 NAT / 防火墙行为')" "$VIEW"
grep -Fq 'IPv4 / IPv6 配置' "$MENU"
grep -Fq 'ip_family_status' "$ACL"
grep -Fq 'stun_test' "$ACL"
grep -Fq 'AAAA records through an IPv4 upstream' \
	"$DEFAULTS"
grep -Fq "option dns_service '1'" "$CONFIG"
grep -Fq 'dhcp.lan.dns_service' "$DEFAULTS"
! grep -Fq 'dhcp.lan.ra_dns' "$BACKEND"
grep -Fq "params: [ 'preference', 'dns_service'" "$VIEW"
grep -Fq '}, [ dnsText(status.ipv4_dns) ])' "$VIEW"
grep -Fq '}, [ dnsText(status.ipv6_dns) ])' "$VIEW"

echo 'C2000MAX IPv4/IPv6 configuration and STUN tests passed'
