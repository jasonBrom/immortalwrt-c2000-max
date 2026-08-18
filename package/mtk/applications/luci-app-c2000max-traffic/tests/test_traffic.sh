#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TRAFFIC="$ROOT/root/usr/sbin/c2000max-traffic"
EQOS_ROOT="$ROOT/../luci-app-eqos-mtk"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

export C2000_TRAFFIC_LIB_ONLY=1
export C2000_TRAFFIC_RUNTIME="$TMP/runtime"
export C2000_TRAFFIC_PERSIST_DIR="$TMP/persist"
export C2000_FEATURE_FILE="$ROOT/../c2000max-appfilter/files/feature.cfg"
. "$TRAFFIC"

mkdir -p "$C2000_TRAFFIC_RUNTIME" "$C2000_TRAFFIC_PERSIST_DIR"

cat > "$TMP/hosts.tsv" <<'EOF'
192.168.66.10	aa:bb:cc:dd:ee:01	phone
192.168.66.11	aa:bb:cc:dd:ee:02	laptop
192.168.66.1	@router	C2000MAX
EOF

cat > "$TMP/conntrack.raw" <<'EOF'
tcp 6 431999 ESTABLISHED src=192.168.66.10 dst=8.8.8.8 sport=50000 dport=443 packets=10 bytes=1200 src=8.8.8.8 dst=192.168.66.10 sport=443 dport=50000 packets=12 bytes=3400 [ASSURED] mark=0x100 secmark=0x3ea use=1 id=42
udp 17 28 src=192.168.66.11 dst=9.9.9.9 sport=53000 dport=53 packets=2 bytes=200 src=9.9.9.9 dst=192.168.66.11 sport=53 dport=53000 packets=2 bytes=300 mark=512 secmark=1 use=1 id=43
tcp 6 100 ESTABLISHED src=192.168.66.10 dst=192.168.66.11 sport=10 dport=20 packets=1 bytes=90 src=192.168.66.11 dst=192.168.66.10 sport=20 dport=10 packets=1 bytes=80 mark=0 use=1 id=44
EOF

parse_conntrack "$TMP/hosts.tsv" "$TMP/conntrack.raw" "$TMP/current.tsv"
[ "$(wc -l < "$TMP/current.tsv")" -eq 2 ] ||
	fail "LAN-to-LAN traffic was not excluded"
grep -q '^42	aa:bb:cc:dd:ee:01	1200	3400	256	192.168.66.10	phone	1002$' \
	"$TMP/current.tsv" || fail "IPv4/hex-mark parser output is wrong"
grep -q '^43	aa:bb:cc:dd:ee:02	200	300	512	192.168.66.11	laptop	0$' \
	"$TMP/current.tsv" || fail "unknown OAF sentinel was not normalized to application 0"

cat > "$TMP/marks.tsv" <<'EOF'
256	fiveg
512	other
EOF
cat > "$TMP/old.tsv" <<'EOF'
42	aa:bb:cc:dd:ee:01	1000	3000	256	192.168.66.10	phone
43	aa:bb:cc:dd:ee:02	150	250	512	192.168.66.11	laptop
EOF

calculate_deltas "$TMP/marks.tsv" "$TMP/old.tsv" "$TMP/current.tsv" \
	"$TMP/deltas.tsv" other 1700000000
grep -q '^aa:bb:cc:dd:ee:01	192.168.66.10	phone	fiveg	200	400	1700000000	1002$' \
	"$TMP/deltas.tsv" || fail "5G delta is wrong"
grep -q '^aa:bb:cc:dd:ee:02	192.168.66.11	laptop	other	50	50	1700000000	0$' \
	"$TMP/deltas.tsv" || fail "broadband delta is wrong"

: > "$TOTALS_FILE"
merge_totals "$TMP/deltas.tsv"
grep -q '^aa:bb:cc:dd:ee:01	192.168.66.10	phone	200	400	0	0	0	0	1700000000$' \
	"$TOTALS_FILE" || fail "5G device total is wrong"
grep -q '^aa:bb:cc:dd:ee:02	192.168.66.11	laptop	0	0	50	50	0	0	1700000000$' \
	"$TOTALS_FILE" || fail "broadband device total is wrong"

HISTORY_FILE="$TMP/history.tsv"
: > "$HISTORY_FILE"
uci() {
	case "$*" in
		*history_interval) echo 60 ;;
		*history_points) echo 10 ;;
		*audit.enabled) echo "${AUDIT_SWITCH:-0}" ;;
		*audit.retention_days) echo 30 ;;
	esac
}
append_history 1700000000
append_history 1700000030
[ "$(wc -l < "$HISTORY_FILE")" -eq 1 ] || fail "history interval was not enforced"
append_history 1700000060
[ "$(wc -l < "$HISTORY_FILE")" -eq 2 ] || fail "history sample was not appended"

# Existing totals are backfilled once as application 0. While auditing is
# disabled, all subsequent traffic also stays in the unknown application;
# after enabling, the secmark APP_ID is preserved in its own hourly bucket.
AUDIT_FILE="$TMP/audit.tsv"
: > "$AUDIT_FILE"
AUDIT_SWITCH=0
merge_audit "$TMP/deltas.tsv" 1700000060
awk -F '\t' '$2=="aa:bb:cc:dd:ee:01" && $5==0 {found=1} END{exit !found}' "$AUDIT_FILE" ||
	fail "disabled audit traffic was not classified as unknown"
AUDIT_SWITCH=1
merge_audit "$TMP/deltas.tsv" 1700003660
awk -F '\t' '$2=="aa:bb:cc:dd:ee:01" && $5==1002 && $6==200 && $7==400 {found=1} END{exit !found}' "$AUDIT_FILE" ||
	fail "enabled audit did not retain the OAF APP_ID"

CATALOG="$TMP/catalog.tsv"
build_feature_catalog "$CATALOG"
awk -F '\t' '$1==1003 && $2=="微博" && $3==1 {found=1} END{exit !found}' "$CATALOG" ||
	fail "OAF v3.0 feature classes/applications were not parsed"

# Exercise the same direct gzip/tar payload carried by official feature ZIPs.
# This keeps archive validation covered without checking a proprietary/current
# feature database into the source tree.
mkdir -p "$TMP/feature-source/app_icons" "$TMP/feature-install"
cat > "$TMP/feature-source/feature.cfg" <<'EOF'
#version v1.2.3
#format v3.0
#class chat 1 聊天
1001 测试应用:[tcp;;;example.test;;]
EOF
tar -czf "$TMP/test-feature.bin" -C "$TMP/feature-source" feature.cfg app_icons
C2000_FEATURE_DIR="$TMP/feature-install" \
C2000_FEATURE_ICON_DIR="$TMP/feature-icons" \
C2000_FEATURE_META="$TMP/feature.meta" \
	"$ROOT/root/usr/sbin/c2000max-feature-install" "$TMP/test-feature.bin" \
	> "$TMP/feature-result.json"
grep -q '"success":true' "$TMP/feature-result.json" ||
	fail "valid OAF v3.0 feature archive was rejected"
grep -q '^1001 测试应用:' "$TMP/feature-install/feature.cfg" ||
	fail "validated feature.cfg was not installed"

sh -n "$TRAFFIC" "$EQOS_ROOT/root/usr/sbin/eqos" \
	"$EQOS_ROOT/root/etc/init.d/eqos" "$ROOT/root/etc/init.d/c2000max-traffic" \
	"$ROOT/root/usr/sbin/c2000max-feature-install" \
	"$ROOT/root/usr/libexec/rpcd/c2000max.traffic" \
	"$EQOS_ROOT/root/usr/libexec/rpcd/c2000max.eqos" \
	"$ROOT/../c2000max-appfilter/files/c2000max-appfilter.init"

grep -q "createElementNS('http://www.w3.org/2000/svg'" \
	"$ROOT/htdocs/luci-static/resources/view/c2000max/traffic.js" ||
	fail "traffic trend chart still creates non-SVG namespace elements"
grep -q 'ct secmark & 0x0000ffff' "$TRAFFIC" ||
	fail "application blocking is not keyed by the isolated OAF APP_ID"
grep -q 'OAF_CT_TAG(ct) ((ct)->secmark)' \
	"$ROOT/../c2000max-appfilter/src/oaf/app_filter.c" ||
	fail "OAF still risks overwriting policy-routing conntrack marks"
OAF_SOURCE="$ROOT/../c2000max-appfilter/src/oaf/app_filter.c"
grep -q 'if (g_hold_acceleration)' "$OAF_SOURCE" &&
	grep -q 'skb->mark |= OAF_ACCEL_BYPASS_MARK' "$OAF_SOURCE" ||
	fail "OAF acceleration bypass is not controlled by the recognition profile"
grep -q 'total_packets > g_max_dpi_packets' "$OAF_SOURCE" ||
	fail "OAF DPI packet window is still compile-time only"
APPFILTER_INIT="$ROOT/../c2000max-appfilter/files/c2000max-appfilter.init"
acct_line="$(grep -n 'nf_conntrack_acct=1' "$APPFILTER_INIT" | cut -d: -f1)"
module_line="$(grep -n '^[[:space:]]*modprobe oaf' "$APPFILTER_INIT" | cut -d: -f1)"
[ -n "$acct_line" ] && [ -n "$module_line" ] && [ "$acct_line" -lt "$module_line" ] ||
	fail "application audit does not enable conntrack accounting before OAF"
grep -q "auto_load_engine='0'" "$APPFILTER_INIT" ||
	fail "OAF daemon can still race the init script by loading the module twice"
awk '
/^apply_recognition_profile\(\)/ { copy=1 }
copy { print }
copy && /^}/ { copy=0 }
' "$APPFILTER_INIT" > "$TMP/recognition-profile.sh"
. "$TMP/recognition-profile.sh"
OAF_SYSCTL_DIR="$TMP/oaf-sysctl"
mkdir -p "$OAF_SYSCTL_DIR"
: > "$OAF_SYSCTL_DIR/hold_acceleration"
: > "$OAF_SYSCTL_DIR/max_dpi_packets"
uci() { printf '%s\n' "$PROFILE_MODE"; }
PROFILE_MODE=seamless
apply_recognition_profile
[ "$(cat "$OAF_SYSCTL_DIR/hold_acceleration")" = 0 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/max_dpi_packets")" = 8 ] ||
	fail "seamless profile does not preserve immediate acceleration"
PROFILE_MODE=balanced
apply_recognition_profile
[ "$(cat "$OAF_SYSCTL_DIR/hold_acceleration")" = 1 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/max_dpi_packets")" = 8 ] ||
	fail "balanced profile does not use the short DPI window"
PROFILE_MODE=precise
apply_recognition_profile
[ "$(cat "$OAF_SYSCTL_DIR/hold_acceleration")" = 1 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/max_dpi_packets")" = 64 ] ||
	fail "precise profile does not retain the full DPI window"
grep -q "option recognition_mode 'seamless'" \
	"$ROOT/root/etc/config/c2000max_traffic" ||
	fail "seamless recognition is not the default"
grep -q "value('balanced'.*8 包" \
	"$ROOT/htdocs/luci-static/resources/view/c2000max/traffic.js" ||
	fail "LuCI does not expose the balanced recognition profile"
grep -q "value('precise'.*64 包" \
	"$ROOT/htdocs/luci-static/resources/view/c2000max/traffic.js" ||
	fail "LuCI does not expose the precise recognition profile"

grep -Fq 'meta mark & 0x00800000 == 0 meta l4proto' \
	"$ROOT/../../../network/config/firewall4/patches/002-c2000max-preserve-eqos-flow-path.patch" ||
	fail "firewall4 does not exclude shaped flows"
grep -q 'flower.*src_mac\|"${key}_mac"' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not implement MAC tc matching"
grep -q 'ether "$addr"' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not implement MAC nft matching"
grep -A5 -F 'nft_mark_rule()' "$EQOS_ROOT/root/usr/sbin/eqos" >/dev/null ||
	fail "EQoS nft mark helper is missing"
[ "$(sed -n '/^nft_mark_rule()/,/^}/p' "$EQOS_ROOT/root/usr/sbin/eqos" | \
	grep -c '^[[:space:]]*counter')" -eq 3 ] ||
	fail "EQoS HNAT selector rules do not expose nft packet counters"
grep -q '^START=95$' "$EQOS_ROOT/root/etc/init.d/eqos" ||
	fail "EQoS still starts before TurboACC converges"
grep -q 'wait_qdma_layout' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not wait for late HNAT/QDMA debugfs nodes"
if grep -Fq '[ -w "$HNAT_DIR/' "$EQOS_ROOT/root/usr/sbin/eqos"; then
	fail "EQoS still trusts unreliable debugfs W_OK probes"
fi
grep -Fq 'debugfs_create_file(name, 0600, eth->debugfs->root' \
	"$ROOT/../../../../target/linux/mediatek/patches-6.12/999-eth-90-mtk_eth_soc-support-proprietary-debugfs.patch" ||
	fail "QDMA HQoS controls are not root-writable"
grep -Fq 'debugfs_create_file("hnat_entry", 0600' \
	"$ROOT/../../../../target/linux/mediatek/patches-6.12/999-zzzz-6000-c2000max-hqos-debugfs-write-permissions.patch" ||
	fail "HNAT flow-table control is not root-writable"
HQOS_EXT_PATCH="$ROOT/../../../../target/linux/mediatek/patches-6.12/999-zzzz-6001-c2000max-hqos-external-uplink.patch"
grep -Fq 'IS_HQOS_EXT_UL_PATH(dev, skb)' "$HQOS_EXT_PATCH" ||
	fail "HNAT HQoS does not recognize external uplinks"
grep -Fq 'FROM_GE_LAN_GRP(skb) || FROM_WED(skb)' "$HQOS_EXT_PATCH" ||
	fail "external HQoS uplink is not restricted to LAN/WED ingress"

# Hardware queues are rate profiles, independent from the persistent rule ID.
# Upload and download have separate 31-profile pools and equal rates reuse an
# existing profile instead of limiting the configuration to 31 devices.
EQOS_INIT="$EQOS_ROOT/root/etc/init.d/eqos"
grep -Fq 'queue_from_profile "$up_profile" up' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "HNAT upload QID is still derived from the rule ID"
grep -Fq 'queue_from_profile "$dl_profile" dl' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "HNAT download QID is still derived from the rule ID"
awk '
/^allocate_hnat_profile\(\) \{/ { copy = 1 }
copy { print }
copy && /^}/ { copy = 0 }
' "$EQOS_INIT" > "$TMP/eqos-profile-lib.sh"
. "$TMP/eqos-profile-lib.sh"
EQOS_BACKEND=hnat
HNAT_PROFILE_MAX=31
HNAT_UP_PROFILES=""
HNAT_DL_PROFILES=""
HNAT_UP_PROFILE_COUNT=0
HNAT_DL_PROFILE_COUNT=0
allocate_hnat_profile up 15000
[ "$HNAT_PROFILE_ID" -eq 1 ] || fail "first upload rate did not get profile 1"
allocate_hnat_profile up 15000
[ "$HNAT_PROFILE_ID" -eq 1 ] && [ "$HNAT_UP_PROFILE_COUNT" -eq 1 ] ||
	fail "equal upload rates did not reuse one hardware profile"
allocate_hnat_profile dl 15000
[ "$HNAT_PROFILE_ID" -eq 1 ] && [ "$HNAT_DL_PROFILE_COUNT" -eq 1 ] ||
	fail "download profiles are not allocated independently"
profile_rate=15001
while [ "$HNAT_UP_PROFILE_COUNT" -lt "$HNAT_PROFILE_MAX" ]; do
	allocate_hnat_profile up "$profile_rate"
	profile_rate=$((profile_rate + 1))
done
allocate_hnat_profile up 999999
[ "$HNAT_PROFILE_ID" -eq 0 ] || fail "a 32nd distinct upload rate did not fall back to tc"
allocate_hnat_profile up 15000
[ "$HNAT_PROFILE_ID" -eq 1 ] || fail "an existing rate stopped reusing its profile after pool exhaustion"
grep -Fq '不对应 HQoS 队列' "$EQOS_ROOT/htdocs/luci-static/resources/view/eqos.js" ||
	fail "LuCI still presents rule IDs as hardware QIDs"

# Exercise the exact selector helpers from /usr/sbin/eqos.  A six-octet MAC
# is made only of hex digits and colons, so it must be classified before the
# deliberately lightweight IPv6 validator.
awk '
/^(valid_ipv4|valid_ipv6|valid_mac|add_inferred_rule)\(\) \{/ { copy = 1 }
copy { print }
copy && /^}/ { copy = 0 }
' "$EQOS_ROOT/root/usr/sbin/eqos" > "$TMP/eqos-selector-lib.sh"
. "$TMP/eqos-selector-lib.sh"
add_rule()
{
	printf '%s|%s|%s\n' "$5" "$6" "$7"
}
selector_result="$(add_inferred_rule hnat 1 1000 500 \
	'1a:3d:8c:86:20:56' 100 20)"
[ "$selector_result" = '||1a:3d:8c:86:20:56' ] ||
	fail "EQoS classified a MAC address as IPv6: $selector_result"
if valid_ipv6 '1a:3d:8c:86:20:56'; then
	fail "EQoS IPv6 validator still accepts a MAC address"
fi
selector_result="$(add_inferred_rule hnat 1 1000 500 \
	'2001:db8::1' 100 20)"
[ "$selector_result" = '|2001:db8::1|' ] ||
	fail "EQoS no longer classifies a real IPv6 selector: $selector_result"
grep -q 'debugfs_create_file("mib_sync"' \
	"$ROOT/../../../../target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/hnat_debugfs.c" ||
	fail "HNAT driver does not expose the lightweight MIB sync path"

echo "PASS: acceleration-aware traffic accounting fixtures"
