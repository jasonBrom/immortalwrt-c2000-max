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
. "$TRAFFIC"

mkdir -p "$C2000_TRAFFIC_RUNTIME" "$C2000_TRAFFIC_PERSIST_DIR"

cat > "$TMP/hosts.tsv" <<'EOF'
192.168.66.10	aa:bb:cc:dd:ee:01	phone
192.168.66.11	aa:bb:cc:dd:ee:02	laptop
192.168.66.1	@router	C2000MAX
EOF

cat > "$TMP/conntrack.raw" <<'EOF'
tcp 6 431999 ESTABLISHED src=192.168.66.10 dst=8.8.8.8 sport=50000 dport=443 packets=10 bytes=1200 src=8.8.8.8 dst=192.168.66.10 sport=443 dport=50000 packets=12 bytes=3400 [ASSURED] mark=0x100 use=1 id=42
udp 17 28 src=192.168.66.11 dst=9.9.9.9 sport=53000 dport=53 packets=2 bytes=200 src=9.9.9.9 dst=192.168.66.11 sport=53 dport=53000 packets=2 bytes=300 mark=512 use=1 id=43
tcp 6 100 ESTABLISHED src=192.168.66.10 dst=192.168.66.11 sport=10 dport=20 packets=1 bytes=90 src=192.168.66.11 dst=192.168.66.10 sport=20 dport=10 packets=1 bytes=80 mark=0 use=1 id=44
EOF

parse_conntrack "$TMP/hosts.tsv" "$TMP/conntrack.raw" "$TMP/current.tsv"
[ "$(wc -l < "$TMP/current.tsv")" -eq 2 ] ||
	fail "LAN-to-LAN traffic was not excluded"
grep -q '^42	aa:bb:cc:dd:ee:01	1200	3400	256	192.168.66.10	phone$' \
	"$TMP/current.tsv" || fail "IPv4/hex-mark parser output is wrong"
grep -q '^43	aa:bb:cc:dd:ee:02	200	300	512	192.168.66.11	laptop$' \
	"$TMP/current.tsv" || fail "decimal-mark parser output is wrong"

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
grep -q '^aa:bb:cc:dd:ee:01	192.168.66.10	phone	fiveg	200	400	1700000000$' \
	"$TMP/deltas.tsv" || fail "5G delta is wrong"
grep -q '^aa:bb:cc:dd:ee:02	192.168.66.11	laptop	other	50	50	1700000000$' \
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
	esac
}
append_history 1700000000
append_history 1700000030
[ "$(wc -l < "$HISTORY_FILE")" -eq 1 ] || fail "history interval was not enforced"
append_history 1700000060
[ "$(wc -l < "$HISTORY_FILE")" -eq 2 ] || fail "history sample was not appended"

sh -n "$TRAFFIC" "$EQOS_ROOT/root/usr/sbin/eqos" \
	"$EQOS_ROOT/root/etc/init.d/eqos" "$ROOT/root/etc/init.d/c2000max-traffic" \
	"$ROOT/root/usr/libexec/rpcd/c2000max.traffic" \
	"$EQOS_ROOT/root/usr/libexec/rpcd/c2000max.eqos"

grep -Fq 'meta mark & 0x00800000 == 0 meta l4proto' \
	"$ROOT/../../../network/config/firewall4/patches/002-c2000max-preserve-eqos-flow-path.patch" ||
	fail "firewall4 does not exclude shaped flows"
grep -q 'flower.*src_mac\|"${key}_mac"' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not implement MAC tc matching"
grep -q 'ether "$addr"' "$EQOS_ROOT/root/usr/sbin/eqos" ||
	fail "EQoS does not implement MAC nft matching"
grep -q 'debugfs_create_file("mib_sync"' \
	"$ROOT/../../../../target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/hnat_debugfs.c" ||
	fail "HNAT driver does not expose the lightweight MIB sync path"

echo "PASS: acceleration-aware traffic accounting fixtures"
