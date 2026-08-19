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
record_audit_diagnostics "$TMP/conntrack.raw" "$TMP/current.tsv"
grep -q '^total=2$' "$AUDIT_DIAG_FILE" || fail "audit diagnostic connection count is wrong"
grep -q '^identified=1$' "$AUDIT_DIAG_FILE" || fail "audit diagnostic APP_ID count is wrong"
grep -q '^unknown=1$' "$AUDIT_DIAG_FILE" || fail "audit diagnostic unknown count is wrong"
grep -q '^secmarks=2$' "$AUDIT_DIAG_FILE" || fail "audit diagnostic secmark count is wrong"

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

# The application-detail and trend logs share one bounded logical budget.
# Trimming keeps complete newest TSV rows and removes the oldest rows first.
C2000_TRAFFIC_STORAGE_LIMIT_BYTES=320
export C2000_TRAFFIC_STORAGE_LIMIT_BYTES
awk -v OFS='\t' 'BEGIN { for (i=1; i<=40; i++) print 1700000000+i,"device",i,"name",1002,1,2,3,4,5,6,1700000000+i }' > "$AUDIT_FILE"
first_before="$(head -n 1 "$AUDIT_FILE" | cut -f1)"
enforce_storage_limit
[ $(( $(wc -c < "$AUDIT_FILE") + $(wc -c < "$HISTORY_FILE") )) -le 320 ] ||
	fail "traffic log storage limit was not enforced"
first_after="$(head -n 1 "$AUDIT_FILE" | cut -f1)"
[ -z "$first_after" ] || [ "$first_after" -gt "$first_before" ] ||
	fail "traffic log eviction did not remove the oldest rows first"
unset C2000_TRAFFIC_STORAGE_LIMIT_BYTES

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

TRAFFIC_VIEW="$ROOT/htdocs/luci-static/resources/view/c2000max/traffic.js"
TRAFFIC_CHART="$ROOT/htdocs/luci-static/resources/c2000max/traffic-chart.js"
grep -Fq "require c2000max.traffic-chart as trafficChart" "$TRAFFIC_VIEW" ||
	fail "traffic UI does not load the reusable chart component"
grep -Fq "'require baseclass';" "$TRAFFIC_CHART" &&
	grep -Fq 'return baseclass.extend({' "$TRAFFIC_CHART" ||
	fail "traffic chart module does not return a LuCI class constructor"
grep -Fq "getContext('2d')" "$TRAFFIC_CHART" ||
	fail "traffic charts are not rendered through responsive canvas"
grep -Fq "addEventListener('mousemove'" "$TRAFFIC_CHART" ||
	fail "traffic charts do not expose pointer interaction"
grep -Fq "ResizeObserver" "$TRAFFIC_CHART" ||
	fail "traffic charts do not resize with their LuCI container"
grep -Fq 'ctx.measureText(label).width' "$TRAFFIC_CHART" ||
	fail "traffic chart does not reserve space for variable-width Y-axis labels"
if grep -q 'createElementNS\|conic-gradient' "$TRAFFIC_VIEW" "$TRAFFIC_CHART"; then
	fail "traffic charts still depend on the clipped static SVG/CSS renderer"
fi
grep -Fq 'max-height:calc(100vh - 190px);overflow-y:auto' "$TRAFFIC_VIEW" ||
	fail "device audit modal is not vertically scrollable"
grep -Fq "'c2000max-audit-modal'" "$TRAFFIC_VIEW" &&
	grep -Fq 'max-width:1280px!important' "$TRAFFIC_VIEW" ||
	fail "device audit modal does not use the wide responsive layout"
if grep -Fq "E('h4', {}, '该设备流量趋势')" "$TRAFFIC_VIEW"; then
	fail "device audit modal still renders the unnecessary per-device trend"
fi
grep -Fq 'var pageSize = 20' "$TRAFFIC_VIEW" &&
	grep -Fq "'traffic_desc', '流量：从大到小'" "$TRAFFIC_VIEW" &&
	grep -Fq "'time_desc', '时间：最近优先'" "$TRAFFIC_VIEW" ||
	fail "application details do not provide 20-row paging and traffic/time sorting"
grep -Fq 'json_add_int last_seen' "$TRAFFIC" ||
	fail "application audit API does not expose the last activity time"
grep -q "option storage_limit_mb '100'" "$ROOT/root/etc/config/c2000max_traffic" &&
	grep -Fq "'storage_limit_mb', '日志数据上限（MB）'" "$TRAFFIC_VIEW" ||
	fail "traffic log storage does not default to a configurable 100 MB cap"
grep -q "option control_mode 'seamless'" "$ROOT/root/etc/config/c2000max_traffic" &&
	grep -Fq "o.value('force', '强力管控" "$TRAFFIC_VIEW" &&
	grep -Fq '[ "$control_mode" != force ] || invalidate_acceleration_cache' "$TRAFFIC" ||
	fail "application control does not expose seamless and force enforcement"
grep -q 'ct secmark & 0x0000ffff' "$TRAFFIC" ||
	fail "application blocking is not keyed by the isolated OAF APP_ID"
grep -q 'OAF_CT_TAG(ct) ((ct)->secmark)' \
	"$ROOT/../c2000max-appfilter/src/oaf/app_filter.c" ||
	fail "OAF still risks overwriting policy-routing conntrack marks"
SECMARK_PATCH="$ROOT/../../../../target/linux/mediatek/patches-6.12/999-zzzz-6002-c2000max-conntrack-export-secmark.patch"
grep -Fq 'nla_put_be32(skb, CTA_SECMARK, htonl(secmark))' "$SECMARK_PATCH" ||
	fail "Linux 6.12 conntrack dumps do not expose the OAF APP_ID secmark"
grep -Fq 'ctnetlink_dump_secmark(skb, ct, true)' "$SECMARK_PATCH" ||
	fail "conntrack dump/get replies omit the raw application secmark"
grep -Fq 'nla_total_size(sizeof(u_int32_t)) /* CTA_SECMARK */' "$SECMARK_PATCH" ||
	fail "conntrack event buffers do not reserve space for CTA_SECMARK"
grep -Fq 'ctnetlink_dump_secmark(skb, ct, false)' "$SECMARK_PATCH" ||
	fail "conntrack update events omit nonzero application secmarks"
if grep -Fq 'CTA_MARK, htonl(secmark)' "$SECMARK_PATCH"; then
	fail "OAF APP_ID export collides with policy-routing conntrack marks"
fi
OAF_SOURCE="$ROOT/../c2000max-appfilter/src/oaf/app_filter.c"
grep -q 'if (g_hold_acceleration)' "$OAF_SOURCE" &&
	grep -q 'skb->mark |= OAF_ACCEL_BYPASS_MARK' "$OAF_SOURCE" ||
	fail "OAF acceleration bypass is not controlled by the recognition profile"
grep -q 'total_packets > g_max_dpi_packets' "$OAF_SOURCE" ||
	fail "OAF DPI packet window is still compile-time only"
grep -Fq 'kzalloc(sizeof(char) * (size + 1), GFP_KERNEL)' "$OAF_SOURCE" ||
	fail "OAF boot feature parser still reads beyond its exact-size buffer"
grep -Fq 'load_feature_config() < 0 || g_feature_init == 0' "$OAF_SOURCE" ||
	fail "OAF does not synchronously load the boot feature database"
grep -Fq 'g_feature_init++' "$OAF_SOURCE" ||
	fail "OAF does not expose the number of loaded kernel signatures"
APPFILTER_INIT="$ROOT/../c2000max-appfilter/files/c2000max-appfilter.init"
TRAFFIC_INIT="$ROOT/root/etc/init.d/c2000max-traffic"
acct_line="$(grep -n 'nf_conntrack_acct=1' "$APPFILTER_INIT" | cut -d: -f1)"
module_line="$(grep -n '^[[:space:]]*modprobe oaf' "$APPFILTER_INIT" | cut -d: -f1)"
[ "$(grep -n 'ln -sf /etc/appfilter/feature.cfg' "$APPFILTER_INIT" | cut -d: -f1)" -lt "$module_line" ] ||
	fail "OAF feature path is still created after the module loads"
[ -n "$acct_line" ] && [ -n "$module_line" ] && [ "$acct_line" -lt "$module_line" ] ||
	fail "application audit does not enable conntrack accounting before OAF"
grep -q "auto_load_engine='0'" "$APPFILTER_INIT" ||
	fail "OAF daemon can still race the init script by loading the module twice"
grep -q 'c2000max-traffic audit-reset' "$APPFILTER_INIT" ||
	fail "enabling audit does not reset old unclassifiable LAN sessions"
reload_block="$(sed -n '/^reload_service()/,/^}/p' "$APPFILTER_INIT")"
printf '%s\n' "$reload_block" | grep -Fq 'pidof c2000max-oafd' &&
	printf '%s\n' "$reload_block" | grep -Fq 'apply_recognition_profile' ||
	fail "saving traffic policy still restarts a healthy OAF engine"
first_hot_apply="$(printf '%s\n' "$reload_block" | grep -n 'apply_recognition_profile' | head -n1 | cut -d: -f1)"
first_restart="$(printf '%s\n' "$reload_block" | grep -n '^[[:space:]]*stop$' | tail -n1 | cut -d: -f1)"
[ -n "$first_hot_apply" ] && [ -n "$first_restart" ] &&
	[ "$first_hot_apply" -lt "$first_restart" ] ||
	fail "OAF hot reload does not precede its recovery restart path"
traffic_reload_block="$(sed -n '/^reload_service()/,/^}/p' "$TRAFFIC_INIT")"
printf '%s\n' "$traffic_reload_block" | grep -Fq 'kill -0 "$pid"' &&
	printf '%s\n' "$traffic_reload_block" | grep -Fq 'c2000max-traffic audit-policy' ||
	fail "saving traffic settings still restarts the healthy collector"
if printf '%s\n' "$traffic_reload_block" | sed -n '/kill -0/,/return 0/p' |
	grep -Fq 'stop'; then
	fail "traffic collector hot reload still flushes the full persisted log"
fi
grep -q '^#version v26\.4\.10$' "$ROOT/../c2000max-appfilter/files/feature.cfg" ||
	fail "the supplied current OAF feature library is not bundled"
grep -Fq 'if (ret < 0)' "$ROOT/../c2000max-appfilter/src/oafd/appfilter_netlink.c" ||
	fail "OAF userspace still treats failed netlink sends as successful"
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
grep -Fq 'tc_police_rule mac "$mac" "$rule_id" "$dev" "$rate"' \
	"$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not police limited MAC uploads on the original LAN ingress"
if grep -Fq 'action mirred' \
	"$EQOS_ROOT/root/usr/sbin/eqos"; then
	fail "EQoS still changes the firewall ingress path through an upload IFB"
fi
grep -q 'ether "$addr"' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not implement MAC nft matching"
grep -A5 -F 'nft_mark_rule()' "$EQOS_ROOT/root/usr/sbin/eqos" >/dev/null ||
	fail "EQoS nft mark helper is missing"
[ "$(sed -n '/^nft_mark_rule()/,/^}/p' "$EQOS_ROOT/root/usr/sbin/eqos" | \
	grep -c '^[[:space:]]*counter')" -eq 3 ] ||
	fail "EQoS HNAT selector rules do not expose nft packet counters"
grep -q '^START=99$' "$EQOS_ROOT/root/etc/init.d/eqos" ||
	fail "EQoS does not perform its final boot apply after uplink convergence"
if grep -Eq '/etc/init\.d/eqos (restart|stop)' \
	"$EQOS_ROOT/root/etc/uci-defaults/luci-eqos"; then
	fail "EQoS uci-defaults still applies the limiter before HNAT boot convergence"
fi
grep -q 'wait_qdma_layout' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not wait for late HNAT/QDMA debugfs nodes"
awk '
/^start_hnat_qos\(\)/ { copy=1 }
copy && /write_hnat "qdma_sch\$DL_SCH" "1 wrr/ { scheduler=NR }
copy && /write_hnat "qos_toggle" "1"/ { toggle=NR }
copy && /^}/ { exit !(scheduler && toggle && scheduler < toggle) }
' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS enables HQoS before its QDMA transaction is complete"
if grep -Eq 'procd_add_reload_trigger.*\beqos\b' \
	"$ROOT/../../../custom/c2000max-board/files/etc/init.d/c2000max-hnat"; then
	fail "saving EQoS still races a parallel HNAT topology rebuild"
fi
grep -q 'failed to initialize the .* limiter backend' "$EQOS_ROOT/root/etc/init.d/eqos" ||
	fail "EQoS does not preserve the failing transaction stage"
if grep -A20 '^eqos_run_reported()' "$EQOS_ROOT/root/etc/init.d/eqos" |
	grep -q '/usr/sbin/eqos diagnose'; then
	fail "EQoS still replaces its failure with a post-cleanup HQoS diagnostic"
fi
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
if grep -Fq 'IS_HQOS_EXT_UL_PATH(dev, skb)' "$HQOS_EXT_PATCH"; then
	fail "unsafe external-WAN HQoS forcing is still present"
fi
grep -Fq 'must stay out of the' "$HQOS_EXT_PATCH" ||
	fail "kernel patch does not document the external PPD/HQoS restriction"

# USB/cellular external uplinks traverse the PPD-reserved QID 63. Verify that
# the service detects both a routed device and an up device whose default route
# has not appeared yet, then selects bidirectional selective tc for only the
# limited flows while unrelated connections remain HNAT eligible.
awk '
/^c2000_eqos_external_uplink_active\(\) \{/ { copy = 1 }
copy { print }
copy && /^}/ { copy = 0 }
' "$EQOS_ROOT/root/etc/init.d/eqos" > "$TMP/eqos-uplink-lib.sh"
. "$TMP/eqos-uplink-lib.sh"
mkdir -p "$TMP/hnat"
cat > "$TMP/hnat/external_interface" <<'EOF'
ext devices [0] = eth2  (ifindex=17)
ext devices [19] = ra0  (ifindex=5)
EOF
cat > "$TMP/ip-route" <<'EOF'
#!/bin/sh
if [ "$1" = link ]; then
	[ "${MOCK_LINK_UP:-0}" = 1 ] && [ "$4" = eth2 ] &&
		printf '17: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> state UP\n'
	exit 0
fi
printf 'default via 10.0.0.1 dev %s table 100\n' "${MOCK_ROUTE_DEV:-eth1}"
EOF
chmod +x "$TMP/ip-route"
EQOS_HNAT_DIR="$TMP/hnat"
EQOS_IP="$TMP/ip-route"
MOCK_ROUTE_DEV=eth2
export MOCK_ROUTE_DEV
c2000_eqos_external_uplink_active ||
	fail "EQoS did not detect an active HNAT external uplink"
MOCK_ROUTE_DEV=eth1
export MOCK_ROUTE_DEV
if c2000_eqos_external_uplink_active; then
	fail "EQoS mistook the Ethernet WAN route for an external uplink"
fi
mkdir -p "$TMP/sys-class-net/eth2"
EQOS_SYS_CLASS_NET="$TMP/sys-class-net"
MOCK_LINK_UP=1
export MOCK_LINK_UP
c2000_eqos_external_uplink_active ||
	fail "EQoS missed an up external device before its default route appeared"
grep -Fq 'EQOS_BACKEND=hybrid' "$EQOS_ROOT/root/etc/init.d/eqos" ||
	fail "external uplinks do not select the HNAT/tc hybrid backend"
resolved_block="$(sed -n '/The MAC rule above already owns/,/^[[:space:]]*done$/p' "$EQOS_ROOT/root/etc/init.d/eqos")"
printf '%s\n' "$resolved_block" |
	grep -Fq 'eqos download-alias "$EQOS_BACKEND" "$download" "$resolved"' ||
	fail "resolved MAC addresses do not use the download-only alias path"
printf '%s\n' "$resolved_block" |
	grep -Fq '"$dl_profile"' ||
	fail "resolved MAC download aliases do not retain the HNAT profile"
if printf '%s\n' "$resolved_block" | grep -Fq 'eqos add '; then
	fail "resolved MAC addresses still repeat a complete tc/HQoS rule"
fi
alias_block="$(sed -n '/^add_download_alias()/,/^}/p' "$EQOS_ROOT/root/usr/sbin/eqos")"
printf '%s\n' "$alias_block" | grep -Fq 'nft_mark_rule dl' &&
	printf '%s\n' "$alias_block" | grep -Fq 'nft_exception_rule dl' ||
	fail "download aliases do not cover both pure HNAT and hybrid/software backends"
awk '
/^(is_uinteger|valid_ipv4|valid_ipv6|valid_mac|queue_from_profile|add_download_alias)\(\) \{/ { copy = 1 }
copy { print }
copy && /^}/ { copy = 0 }
' "$EQOS_ROOT/root/usr/sbin/eqos" > "$TMP/eqos-download-alias-lib.sh"
. "$TMP/eqos-download-alias-lib.sh"
die() { return 1; }
nft_mark_rule() { printf 'mark|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }
nft_exception_rule() { printf 'bypass|%s|%s|%s\n' "$1" "$2" "$3"; }
DL_QID_BASE=32
HNAT_PROFILE_MAX=31
[ "$(add_download_alias hnat 100000 192.168.66.245 1)" = 'mark|dl|ip|192.168.66.245|32' ] ||
	fail "pure-HNAT MAC alias did not mark the first download QID"
[ "$(add_download_alias hybrid 100000 192.168.66.245 0)" = 'bypass|dl|ip|192.168.66.245' ] ||
	fail "hybrid MAC alias did not bypass accelerated download forwarding"
hybrid_block="$(sed -n '/if \[ "$backend" = hybrid \]/,/^[[:space:]]*fi$/p' \
	"$EQOS_ROOT/root/usr/sbin/eqos" | head -n 60)"
printf '%s\n' "$hybrid_block" | grep -Fq 'ensure_tc_qos' ||
	fail "external hybrid does not create bidirectional selective tc"
printf '%s\n' "$hybrid_block" | grep -Fq 'nft_exception_rule dl' ||
	fail "external hybrid does not keep limited downloads out of HNAT"
if printf '%s\n' "$hybrid_block" | grep -Fq 'program_queue'; then
	fail "external hybrid still assigns an unsafe PPD-adjacent QDMA queue"
fi
grep -Fq 'external-uplink HQoS did not stay disabled' \
	"$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "external hybrid does not verify that QDMA HQoS stays disabled"
grep -Fq 'flush_hnat_entries' \
	"$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "hybrid activation does not invalidate existing PPE entries"
grep -A12 -F 'stop_hnat_qos()' "$EQOS_ROOT/root/usr/sbin/eqos" |
	grep -Fq 'flush_hnat_entries' ||
	fail "disabling HQoS leaves stale fqos/QID PPE entries active"
grep -Fq "hybrid: 'HNAT + 下载 HTB / 上传 Police'" \
	"$EQOS_ROOT/htdocs/luci-static/resources/view/eqos.js" ||
	fail "LuCI does not explain the external-uplink hybrid backend"

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
EQOS_BACKEND=hybrid
allocate_hnat_profile up 18000
[ "$HNAT_PROFILE_ID" -eq 0 ] || fail "hybrid upload incorrectly consumes an HNAT profile"
allocate_hnat_profile dl 18000
[ "$HNAT_PROFILE_ID" -eq 0 ] || fail "hybrid download incorrectly consumes an HNAT profile"
EQOS_BACKEND=hnat
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
