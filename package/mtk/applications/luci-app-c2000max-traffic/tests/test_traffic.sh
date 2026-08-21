#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TRAFFIC="$ROOT/root/usr/sbin/c2000max-traffic"
EQOS_ROOT="$ROOT/../luci-app-eqos-mtk"
TMP="$(mktemp -d)"
cleanup_tmp()
{
	chmod -R u+w "$TMP" 2>/dev/null || true
	rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT HUP INT TERM

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

# Large audit logs must use stat's O(1) metadata path instead of making every
# sampler/status call stream the file through BusyBox wc.
grep -q '+coreutils-stat' "$ROOT/Makefile" ||
	fail "traffic package does not depend on coreutils-stat"
grep -q "stat -c '%s'" "$TRAFFIC" ||
	fail "file_size no longer uses the stat fast path"
truncate -s 10485761 "$TMP/file-size.sparse"
[ "$(file_size "$TMP/file-size.sparse")" = 10485761 ] ||
	fail "file_size stat fast path returned the wrong size"

mkdir -p "$C2000_TRAFFIC_RUNTIME" "$C2000_TRAFFIC_PERSIST_DIR"

# Only a collector-locked caller may rebuild/publish the recent cache.  Generic
# status/catalog initialization must not race a sampler and overwrite its newer
# cache with a snapshot of the old audit inode.
(
	marker="$TMP/recent-ensure.calls"
	ensure_recent_audit_cache() { printf 'called\n' >> "$marker"; }
	AUDIT_LOCK_HELD=0
	ensure_runtime
	[ ! -e "$marker" ] || fail "unlocked ensure_runtime rebuilt the recent cache"
	AUDIT_LOCK_HELD=1
	ensure_runtime
	[ "$(wc -l < "$marker")" -eq 1 ] ||
		fail "collector-locked ensure_runtime did not initialize the recent cache"
)

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
		*audit.ruleset) echo "${AUDIT_RULESET:-}" ;;
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

# Native IK catalogs carry both a semantic leaf category and an internal OAF
# storage shard.  The UI must use the former, otherwise users see categories
# such as “其它应用1..4” from the old adapter.
cat > "$TMP/native-catalog.tsv" <<'EOF'
oaf_appid	name	category_id	category_name	source_appid	compiled	runtime_class_id	runtime_class_name
9001	测试游戏	28	手机游戏	6000001	1	9	其它应用1
9002	未编译应用	28	手机游戏	6000002	0	9	其它应用1
EOF
build_native_profile_catalog "$TMP/native-built.tsv" "$TMP/native-catalog.tsv"
awk -F '\t' '$1==9001 && $2=="测试游戏" && $3==28 && $4=="手机游戏" {ok=1}
	END {exit !(ok && NR==1)}' "$TMP/native-built.tsv" ||
	fail "native IK catalog leaked runtime storage shards into semantic categories"
grep -Fq 'semantic-v${CATALOG_CACHE_SCHEMA}.tsv' "$TRAFFIC" ||
	fail "native catalog cache has no schema key to invalidate the old category layout"

# Profile-aware catalogs stay lazy: metadata is cheap, search returns at most
# one page, and lookup resolves only the selected APPIDs.  Two libraries reuse
# APPID 1001 deliberately so history isolation also catches cross-library names.
PROFILE_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PROFILE_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
PROFILE_ROOT="$TMP/profiles"
mkdir -p "$PROFILE_ROOT/$PROFILE_A" "$PROFILE_ROOT/$PROFILE_B"
cat > "$PROFILE_ROOT/$PROFILE_A/feature.cfg" <<'EOF'
#version v1.0-old
#format v3.0
#class old 1 旧分类
1001 旧应用:[tcp;;;old.example;;]
EOF
{
	printf '%s\n' '#version v8.8-fallback' '#format v3.0' '#class new 2 新分类'
	i=1
	while [ "$i" -le 60 ]; do
		appid=$((1000 + i))
		[ "$appid" -ne 1001 ] || name=新应用
		[ "$appid" -eq 1001 ] || name="应用${i}"
		printf '%s %s:[tcp;;;%s.example;;]\n' "$appid" "$name" "$i"
		i=$((i + 1))
	done
} > "$PROFILE_ROOT/$PROFILE_B/feature.cfg"
cat > "$PROFILE_ROOT/$PROFILE_A/profile.meta" <<EOF
version=v1.0-old
format=v3.0
apps=1
sha256=$PROFILE_A
EOF
cat > "$PROFILE_ROOT/$PROFILE_B/profile.meta" <<EOF
version=v9.9-meta
format=v3.0
apps=60
sha256=$PROFILE_B
EOF
printf '%s\n' "$PROFILE_B" > "$TMP/profile-active"

FEATURE_LIBRARIES_DIR="$PROFILE_ROOT"
FEATURE_ACTIVE_FILE="$TMP/profile-active"
FEATURE_PROFILE_OVERRIDE=""
FEATURE_FILE="$PROFILE_ROOT/$PROFILE_B/feature.cfg"

# A valid matching profile.meta is the status fast path.  A mismatched sha256
# must distrust it and fall back to parsing feature.cfg.
load_status_feature_metadata
[ "$FEATURE_STATUS_META" -eq 1 ] &&
	[ "$FEATURE_STATUS_VERSION" = v9.9-meta ] &&
	[ "$FEATURE_STATUS_FORMAT" = v3.0 ] &&
	[ "$FEATURE_STATUS_APPS" -eq 60 ] ||
	fail "status did not use the trusted active profile metadata"
# Native IK profiles use v4.2 metadata and must use the same O(1) fast path;
# otherwise every five-second status poll rescans a 3000+ application file.
sed 's/^format=.*/format=v4.2/' "$PROFILE_ROOT/$PROFILE_B/profile.meta" > "$TMP/profile.meta.v4"
mv "$TMP/profile.meta.v4" "$PROFILE_ROOT/$PROFILE_B/profile.meta"
load_status_feature_metadata
[ "$FEATURE_STATUS_META" -eq 1 ] &&
	[ "$FEATURE_STATUS_VERSION" = v9.9-meta ] &&
	[ "$FEATURE_STATUS_FORMAT" = v4.2 ] &&
	[ "$FEATURE_STATUS_APPS" -eq 60 ] ||
	fail "status did not trust valid native-v4.2 profile metadata"
sed 's/^sha256=.*/sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/' \
	"$PROFILE_ROOT/$PROFILE_B/profile.meta" > "$TMP/profile.meta.bad"
mv "$TMP/profile.meta.bad" "$PROFILE_ROOT/$PROFILE_B/profile.meta"
load_status_feature_metadata
[ "$FEATURE_STATUS_META" -eq 0 ] &&
	[ "$FEATURE_STATUS_VERSION" = v8.8-fallback ] &&
	[ "$FEATURE_STATUS_FORMAT" = v3.0 ] &&
	[ "$FEATURE_STATUS_APPS" -eq 60 ] ||
	fail "status trusted mismatched metadata instead of feature.cfg"

cat > "$TMP/jshn-mock.sh" <<'EOF'
json_init() { :; }
json_add_boolean() { printf 'bool\t%s\t%s\n' "$1" "$2"; }
json_add_string() { printf 'string\t%s\t%s\n' "$1" "$2"; }
json_add_int() { printf 'int\t%s\t%s\n' "$1" "$2"; }
json_add_array() { printf 'array\t%s\n' "$1"; }
json_add_object() { :; }
json_close_object() { :; }
json_close_array() { :; }
json_dump() { :; }
EOF
JSHN_LIB="$TMP/jshn-mock.sh"

catalog_search_json "$PROFILE_B" "" 0 0 "" > "$TMP/catalog-page-1.events"
catalog_search_json "$PROFILE_B" "" 0 50 50 > "$TMP/catalog-page-2.events"
grep -q '^int	total	60$' "$TMP/catalog-page-1.events" &&
	grep -q '^int	limit	50$' "$TMP/catalog-page-1.events" &&
	[ "$(grep -c '^int	id	' "$TMP/catalog-page-1.events")" -eq 50 ] &&
	[ "$(grep -c '^int	id	' "$TMP/catalog-page-2.events")" -eq 10 ] ||
	fail "lazy catalog search did not enforce 50-item pagination"
catalog_lookup_json "$PROFILE_B" '1001,1060,1512' > "$TMP/catalog-lookup.events"
grep -q '^string	name	新应用$' "$TMP/catalog-lookup.events" &&
	grep -q '^string	name	应用60$' "$TMP/catalog-lookup.events" &&
	grep -q '^string	name	未知应用 1512$' "$TMP/catalog-lookup.events" &&
	grep -q '^bool	missing	1$' "$TMP/catalog-lookup.events" ||
	fail "catalog lookup did not resolve selected and missing APPIDs"

# Upgrade legacy rows under the old audit.ruleset before a feature switch and
# persist the new 13th profile column.
AUDIT_FILE="$TMP/profile-legacy.tsv"
AUDIT_PROFILED_FILE="$TMP/profile-legacy.done"
AUDIT_PERSIST_FILE="$TMP/profile-legacy.persist"
LOCK_FILE="$TMP/profile-legacy.lock"
AUDIT_RULESET="$PROFILE_A"
printf '1700000000\tdevice\t192.0.2.1\tclient\t1001\t1\t2\t3\t4\t5\t6\t1700000000\n' > "$AUDIT_FILE"
persist_audit_profiles > "$TMP/profile-migrate.json"
awk -F '\t' -v profile="$PROFILE_A" 'NF==13 && $13==profile {found=1} END{exit !found}' \
	"$AUDIT_FILE" &&
	awk -F '\t' -v profile="$PROFILE_A" 'NF==13 && $13==profile {found=1} END{exit !found}' \
		"$AUDIT_PERSIST_FILE" ||
	fail "legacy audit rows were not persistently bound to their old profile"

# The same numeric APPID from different profiles must remain two named rows.
AUDIT_FILE="$TMP/profile-history.tsv"
AUDIT_PROFILED_FILE="$TMP/profile-history.done"
printf '1700000000\tdevice\t192.0.2.1\tclient\t1001\t1\t2\t0\t0\t0\t0\t1700000000\t%s\n' \
	"$PROFILE_A" > "$AUDIT_FILE"
printf '1700003600\tdevice\t192.0.2.1\tclient\t1001\t3\t4\t0\t0\t0\t0\t1700003600\t%s\n' \
	"$PROFILE_B" >> "$AUDIT_FILE"
: > "$AUDIT_PROFILED_FILE"
audit_json device 1699999999 1700004000 > "$TMP/profile-history.events"
grep -q '^string	name	旧应用$' "$TMP/profile-history.events" &&
	grep -q '^string	name	新应用$' "$TMP/profile-history.events" &&
	grep -q "^string	profile_id	$PROFILE_A$" "$TMP/profile-history.events" &&
	grep -q "^string	profile_id	$PROFILE_B$" "$TMP/profile-history.events" &&
	grep -q '^string	profile_version	v1.0-old$' "$TMP/profile-history.events" &&
	grep -q '^string	profile_version	v8.8-fallback$' "$TMP/profile-history.events" ||
	fail "audit history was not isolated by feature profile"

# The polling endpoint reads a bounded 150-row cache rather than rescanning
# audit.tsv. It excludes application 0, preserves immutable profile naming,
# falls back from unsafe DHCP hostnames, and paginates newest-first.
AUDIT_FILE="$TMP/recent-history.tsv"
AUDIT_PROFILED_FILE="$TMP/recent-history.done"
AUDIT_PERSIST_FILE="$TMP/recent-history.persist"
RECENT_AUDIT_FILE="$TMP/recent-audit.tsv"
RECENT_AUDIT_READY_FILE="$TMP/recent-audit.ready"
RECENT_BASE="$(date +%s)"
printf '%s\tdevice-new\t192.0.2.21\t新设备\t1001\t1\t1\t0\t0\t0\t0\t%s\t%s\n' \
	"$((RECENT_BASE - 3))" "$((RECENT_BASE - 3))" "$PROFILE_B" > "$AUDIT_FILE"
printf '%s\tdevice-old\t192.0.2.20\t旧设备\t1001\t1\t1\t0\t0\t0\t0\t%s\t%s\n' \
	"$((RECENT_BASE - 2))" "$((RECENT_BASE - 2))" "$PROFILE_A" >> "$AUDIT_FILE"
printf '%s\tdevice-bad\t192.0.2.22\tbad\rname\t1002\t1\t1\t0\t0\t0\t0\t%s\t%s\n' \
	"$((RECENT_BASE - 1))" "$((RECENT_BASE - 1))" "$PROFILE_B" >> "$AUDIT_FILE"
printf '%s\tdevice-unknown\t192.0.2.23\tunknown\t0\t1\t1\t0\t0\t0\t0\t%s\t%s\n' \
	"$RECENT_BASE" "$RECENT_BASE" "$PROFILE_B" >> "$AUDIT_FILE"
: > "$AUDIT_PROFILED_FILE"
rm -f "$RECENT_AUDIT_FILE" "$RECENT_AUDIT_READY_FILE"
rebuild_recent_audit_cache
[ "$(wc -l < "$RECENT_AUDIT_FILE")" -eq 3 ] &&
	[ "$(head -n 1 "$RECENT_AUDIT_FILE" | cut -f1)" -eq $((RECENT_BASE - 1)) ] &&
	! awk -F '\t' '$6==0 {found=1} END{exit !found}' "$RECENT_AUDIT_FILE" ||
	fail "recent audit cache ordering or unknown filtering is wrong"
recent_audit_json "" "" > "$TMP/recent-profile.events"
grep -q '^int[[:space:]]total[[:space:]]3$' "$TMP/recent-profile.events" &&
	grep -q '^int[[:space:]]limit[[:space:]]50$' "$TMP/recent-profile.events" &&
	grep -q '^string[[:space:]]name[[:space:]]旧应用$' "$TMP/recent-profile.events" &&
	grep -q '^string[[:space:]]name[[:space:]]新应用$' "$TMP/recent-profile.events" &&
	grep -q '^string[[:space:]]device_name[[:space:]]192.0.2.22$' "$TMP/recent-profile.events" &&
	grep -q "^string[[:space:]]profile_id[[:space:]]$PROFILE_A$" "$TMP/recent-profile.events" &&
	grep -q "^string[[:space:]]profile_id[[:space:]]$PROFILE_B$" "$TMP/recent-profile.events" ||
	fail "recent audit RPC lost device or feature-profile semantics"
if recent_audit_json 151 50 > "$TMP/recent-invalid-offset.events"; then
	fail "recent audit accepted an offset outside its 150-row window"
fi
grep -q '"error":"invalid offset"' "$TMP/recent-invalid-offset.events" ||
	fail "recent audit offset error is not structured"
if recent_audit_json 0 0 > "$TMP/recent-invalid-limit.events"; then
	fail "recent audit accepted a zero page size"
fi

: > "$AUDIT_FILE"
i=1
while [ "$i" -le 170 ]; do
	stamp=$((RECENT_BASE - 170 + i))
	appid=$((1000 + (i - 1) % 60 + 1))
	printf '%s\tdevice-%03d\t192.0.2.%s\t设备%03d\t%s\t1\t1\t0\t0\t0\t0\t%s\t%s\n' \
		"$stamp" "$i" "$((i % 250 + 1))" "$i" "$appid" "$stamp" "$PROFILE_B" \
		>> "$AUDIT_FILE"
	i=$((i + 1))
done
rm -f "$RECENT_AUDIT_FILE" "$RECENT_AUDIT_READY_FILE"
rebuild_recent_audit_cache
[ "$(wc -l < "$RECENT_AUDIT_FILE")" -eq 150 ] &&
	[ "$(head -n 1 "$RECENT_AUDIT_FILE" | cut -f1)" -eq "$RECENT_BASE" ] &&
	[ "$(tail -n 1 "$RECENT_AUDIT_FILE" | cut -f1)" -eq $((RECENT_BASE - 149)) ] ||
	fail "recent audit did not retain exactly the newest 150 identified rows"
recent_audit_json 50 50 > "$TMP/recent-page.events"
[ "$(grep -c '^int[[:space:]]timestamp[[:space:]]' "$TMP/recent-page.events")" -eq 50 ] &&
	grep -q '^bool[[:space:]]has_more[[:space:]]1$' "$TMP/recent-page.events" ||
	fail "recent audit did not return a stable 50-row middle page"
recent_audit_json 0 999 > "$TMP/recent-limit.events"
grep -q '^int[[:space:]]limit[[:space:]]100$' "$TMP/recent-limit.events" &&
	[ "$(grep -c '^int[[:space:]]timestamp[[:space:]]' "$TMP/recent-limit.events")" -eq 100 ] ||
	fail "recent audit did not cap oversized pages at 100 rows"

printf 'device-live\t192.0.2.250\t实时设备\tfiveg\t1\t2\t%s\t1001\n' \
	"$((RECENT_BASE + 1))" > "$TMP/recent.delta"
printf 'device-unknown\t192.0.2.251\t未知设备\tfiveg\t1\t2\t%s\t0\n' \
	"$((RECENT_BASE + 2))" >> "$TMP/recent.delta"
update_recent_audit_cache "$TMP/recent.delta" "$PROFILE_B" "$((RECENT_BASE + 2))" \
	"$((RECENT_BASE - 86400))" 0
[ "$(head -n 1 "$RECENT_AUDIT_FILE" | cut -f3)" = device-live ] &&
	! awk -F '\t' '$6==0 {found=1} END{exit !found}' "$RECENT_AUDIT_FILE" ||
	fail "incremental recent audit cache admitted unknown traffic or lost newest activity"

# The page-load endpoint must not wait behind a sampler that is merging a
# potentially 100 MB audit.tsv under collector.lock.  During that transaction
# the ready marker is absent, but the rename-published old 150-row cache is a
# safe at-most-one-sample-stale response.
LOCK_FILE="$TMP/recent-busy-collector.lock"
rm -f "$RECENT_AUDIT_READY_FILE" "$TMP/recent-lock-held" \
	"$TMP/recent-lock-release" "$TMP/recent-rpc-done"
(
	exec 8> "$LOCK_FILE"
	flock -x 8
	: > "$TMP/recent-lock-held"
	while [ ! -f "$TMP/recent-lock-release" ]; do sleep 0.01; done
) &
recent_lock_pid=$!
tries=0
while [ ! -f "$TMP/recent-lock-held" ]; do
	tries=$((tries + 1))
	[ "$tries" -lt 200 ] || fail "timed out taking the recent-audit test lock"
	sleep 0.01
done
(
	recent_audit_json 0 50 > "$TMP/recent-busy.events"
	: > "$TMP/recent-rpc-done"
) &
recent_rpc_pid=$!
tries=0
while [ ! -f "$TMP/recent-rpc-done" ]; do
	tries=$((tries + 1))
	if [ "$tries" -ge 100 ]; then
		: > "$TMP/recent-lock-release"
		kill "$recent_rpc_pid" 2>/dev/null || true
		wait "$recent_rpc_pid" 2>/dev/null || true
		wait "$recent_lock_pid" 2>/dev/null || true
		fail "recent audit blocked behind the busy collector"
	fi
	sleep 0.01
done
wait "$recent_rpc_pid"
grep -q '^bool[[:space:]]stale[[:space:]]1$' "$TMP/recent-busy.events" &&
	[ "$(grep -c '^int[[:space:]]timestamp[[:space:]]' "$TMP/recent-busy.events")" -eq 50 ] || {
		: > "$TMP/recent-lock-release"
		wait "$recent_lock_pid" 2>/dev/null || true
		fail "recent audit did not serve the bounded stale cache while sampling"
	}
: > "$TMP/recent-lock-release"
wait "$recent_lock_pid"
file_size "$AUDIT_FILE" > "$RECENT_AUDIT_READY_FILE"

# A pipeline producer failure must not be hidden by ash's lack of pipefail or
# publish a partial cache.  Exercise the checked sort stage independently.
(
	RECENT_AUDIT_FILE="$TMP/recent-sort-failure.tsv"
	RECENT_AUDIT_READY_FILE="$TMP/recent-sort-failure.ready"
	rm -f "$RECENT_AUDIT_FILE" "$RECENT_AUDIT_READY_FILE"
	sort() { return 1; }
	if rebuild_recent_audit_cache; then
		fail "recent cache rebuild hid a sort failure"
	fi
	[ ! -e "$RECENT_AUDIT_FILE" ] && [ ! -e "$RECENT_AUDIT_READY_FILE" ] ||
		fail "failed recent cache rebuild published partial state"
)

# Once audit.tsv is committed, a disposable-cache failure must remain success
# so sample_once_locked advances its conntrack snapshot instead of counting the
# same delta again.  The invalidated cache must be recoverable from audit.tsv.
(
	CACHE_FAIL_NOW="$(date +%s)"
	AUDIT_FILE="$TMP/cache-failure-audit.tsv"
	TOTALS_FILE="$TMP/cache-failure-totals.tsv"
	RECENT_AUDIT_FILE="$TMP/cache-failure-recent.tsv"
	RECENT_AUDIT_READY_FILE="$TMP/cache-failure-recent.ready"
	: > "$AUDIT_FILE"
	: > "$TOTALS_FILE"
	printf 'stale\n' > "$RECENT_AUDIT_FILE"
	printf '1\n' > "$RECENT_AUDIT_READY_FILE"
	printf 'cache-device\t192.0.2.44\t缓存设备\tfiveg\t7\t9\t%s\t1001\n' \
		"$CACHE_FAIL_NOW" > "$TMP/cache-failure.delta"
	update_recent_audit_cache() { return 1; }
	merge_audit "$TMP/cache-failure.delta" "$CACHE_FAIL_NOW" ||
		fail "durable audit merge failed with only its derivative cache unavailable"
	awk -F '\t' '$2=="cache-device" && $5==1001 {n++; up+=$6; down+=$7}
		END {exit !(n==1 && up==7 && down==9)}' "$AUDIT_FILE" ||
		fail "cache failure duplicated or lost committed audit accounting"
	[ ! -e "$RECENT_AUDIT_FILE" ] && [ ! -e "$RECENT_AUDIT_READY_FILE" ] ||
		fail "cache failure did not invalidate its disposable files"
	rebuild_recent_audit_cache || fail "invalidated recent cache could not be rebuilt"
	[ -s "$RECENT_AUDIT_FILE" ] && [ -r "$RECENT_AUDIT_READY_FILE" ] &&
		grep -q 'cache-device' "$RECENT_AUDIT_FILE" ||
		fail "rebuilt recent cache lost committed audit data"
)
grep -q '"recent_audit"' "$ROOT/root/usr/libexec/rpcd/c2000max.traffic" &&
	grep -q '"recent_audit"' "$ROOT/root/usr/share/rpcd/acl.d/luci-app-c2000max-traffic.json" ||
	fail "recent audit RPC is not exposed through the read ACL"
grep -q '"feature_install_status"' "$ROOT/root/usr/libexec/rpcd/c2000max.traffic" &&
	grep -q '"feature_install_status"' "$ROOT/root/usr/share/rpcd/acl.d/luci-app-c2000max-traffic.json" &&
	grep -Fq 'c2000max-feature-job start /tmp/c2000max-feature-upload' \
		"$ROOT/root/usr/libexec/rpcd/c2000max.traffic" &&
	grep -Fq 'c2000max-feature-job activate "$id"' \
		"$ROOT/root/usr/libexec/rpcd/c2000max.traffic" &&
	grep -Fq 'c2000max-feature-job rollback' \
		"$ROOT/root/usr/libexec/rpcd/c2000max.traffic" ||
	fail "asynchronous feature install/switch/status RPC is not exposed safely"

# OAF APPIDs use type*1000+index, including the complete class-32 range.
valid_app_id 32001 && valid_app_id 32512 &&
	! valid_app_id 1999 && ! valid_app_id 32513 ||
	fail "APPID type/index boundary validation is wrong"
cat > "$TMP/class32-hosts.tsv" <<'EOF'
192.0.2.10	aa:bb:cc:dd:ee:32	class32
EOF
cat > "$TMP/class32-conntrack.raw" <<'EOF'
tcp src=192.0.2.10 dst=198.51.100.1 bytes=10 src=198.51.100.1 dst=192.0.2.10 bytes=20 mark=0 secmark=32512 id=32001
tcp src=192.0.2.10 dst=198.51.100.2 bytes=30 src=198.51.100.2 dst=192.0.2.10 bytes=40 mark=0 secmark=32513 id=32002
tcp src=192.0.2.10 dst=198.51.100.3 bytes=50 src=198.51.100.3 dst=192.0.2.10 bytes=60 mark=0 secmark=1999 id=32003
EOF
parse_conntrack "$TMP/class32-hosts.tsv" "$TMP/class32-conntrack.raw" "$TMP/class32-current.tsv"
awk -F '\t' '$1==32001 && $8==32512 {upper=1} $1==32002 && $8==0 {overflow=1} \
	$1==32003 && $8==0 {gap=1} END {exit !(upper && overflow && gap)}' \
	"$TMP/class32-current.tsv" || fail "conntrack APPID class-32 normalization regressed"

# A numeric APPID is catalog-specific.  The upper secmark epoch must agree
# with the currently committed OAF generation; otherwise a profile switch can
# rename an old flow as an unrelated application in the new library.
OLD_OAF_SYSCTL_DIR="$OAF_SYSCTL_DIR"
OAF_SYSCTL_DIR="$TMP/oaf-profile-epoch"
mkdir -p "$OAF_SYSCTL_DIR"
printf '4660\n' > "$OAF_SYSCTL_DIR/feature_generation"
cat > "$TMP/epoch-conntrack.raw" <<'EOF'
tcp src=192.0.2.10 dst=198.51.100.10 bytes=10 src=198.51.100.10 dst=192.0.2.10 bytes=20 mark=0 secmark=0x123403ea id=33001
tcp src=192.0.2.10 dst=198.51.100.11 bytes=30 src=198.51.100.11 dst=192.0.2.10 bytes=40 mark=0 secmark=0x123503ea id=33002
tcp src=192.0.2.10 dst=198.51.100.12 bytes=50 src=198.51.100.12 dst=192.0.2.10 bytes=60 mark=1002 secmark=0 id=33003
EOF
parse_conntrack "$TMP/class32-hosts.tsv" "$TMP/epoch-conntrack.raw" "$TMP/epoch-current.tsv"
awk -F '\t' '$1==33001 && $8==1002 {current=1} $1==33002 && $8==0 {stale=1} \
	$1==33003 && $8==0 {legacy_mark_ignored=1} \
	END {exit !(current && stale && legacy_mark_ignored)}' "$TMP/epoch-current.tsv" ||
	fail "profile-generation APPID isolation regressed"
OAF_SYSCTL_DIR="$OLD_OAF_SYSCTL_DIR"

# A schedule from another profile compiles nothing.  The active schedule uses
# one anonymous nft set instead of one sequential rule per application.
SCHEDULE_APPS="$(awk '/^[0-9]+[[:space:]]+[^:]+:\[/ {printf "%s ",$1}' \
	"$PROFILE_ROOT/$PROFILE_B/feature.cfg")"
SCHEDULE_RULESET="$PROFILE_A"
config_get()
{
	local value="${4:-}"
	case "$3" in
		ruleset) value="$SCHEDULE_RULESET" ;;
		target) value=all ;;
		apps) value="$SCHEDULE_APPS" ;;
		categories|whitelist) value="" ;;
		days) value='0 1 2 3 4 5 6' ;;
		start|end) value=00:00 ;;
	esac
	eval "$1=\"\$value\""
}
config_get_bool() { eval "$1=1"; }
POLICY_ACTIVE_PROFILE="$PROFILE_B"
POLICY_FEATURE_FILE="$PROFILE_ROOT/$PROFILE_B/feature.cfg"
POLICY_RULE_FILE="$TMP/profile-policy.nft"
POLICY_ACTIVE_COUNT=0
POLICY_TRUNCATED=0
POLICY_ACTIVE_EPOCH_HEX=0x12340000
: > "$POLICY_RULE_FILE"
compile_schedule regression
[ ! -s "$POLICY_RULE_FILE" ] || fail "a schedule from an inactive profile was compiled"
SCHEDULE_RULESET="$PROFILE_B"
compile_schedule regression
	[ "$(wc -l < "$POLICY_RULE_FILE")" -eq 1 ] &&
	[ "$POLICY_ACTIVE_COUNT" -eq 60 ] &&
	grep -q 'ct secmark & 0x1fff0000 == 0x12340000' "$POLICY_RULE_FILE" &&
	grep -q 'ct secmark & 0x0000ffff { 1001, 1002,' "$POLICY_RULE_FILE" &&
	grep -Fq '[ "$POLICY_ACTIVE_PROFILE" = "$current_profile_sha" ]' "$TRAFFIC" &&
	grep -Fq '[ "$ruleset" = "$POLICY_ACTIVE_PROFILE" ]' "$TRAFFIC" ||
	fail "application policy is not one set bound to active profile and feature SHA"

# DNS-assisted control complements DPI without globally disabling HNAT.  Each
# active schedule owns bounded IPv4/IPv6 timeout sets, directs client DNS to the
# router, and asks dnsmasq to populate both address families.
(
	POLICY_DOMAIN_INDEX="$TMP/policy-domains.tsv"
	POLICY_SET_FILE="$TMP/policy-domain-sets.nft"
	POLICY_RULE_FILE="$TMP/policy-domain-block.nft"
	POLICY_DNS_REDIRECT_RULE_FILE="$TMP/policy-domain-redirect.nft"
	POLICY_DNSMASQ_RULE_FILE="$TMP/policy-domain-dnsmasq.conf"
	POLICY_ACTIVE_PROFILE="$PROFILE_B"
	POLICY_TABLE=c2000_appaudit
	POLICY_VERDICT=reject
	POLICY_DNS_DOMAIN_COUNT=0
	POLICY_DNS_SCHEDULE_COUNT=0
	POLICY_DNS_TRUNCATED=0
	cat > "$POLICY_DOMAIN_INDEX" <<'EOF'
1001	baidu.com
1001	www.baidu.com
1002	douyin.com
1003	unselected.example
EOF
	: > "$POLICY_SET_FILE"
	: > "$POLICY_RULE_FILE"
	: > "$POLICY_DNS_REDIRECT_RULE_FILE"
	: > "$POLICY_DNSMASQ_RULE_FILE"
	compile_schedule_domains dns-regression \
		'iifname "br-lan" ether saddr { aa:bb:cc:dd:ee:01 }' '1001, 1002'
	[ "$POLICY_DNS_DOMAIN_COUNT" -eq 3 ] &&
		[ "$POLICY_DNS_SCHEDULE_COUNT" -eq 1 ] &&
		grep -Fq 'type ipv4_addr;' "$POLICY_SET_FILE" &&
		grep -Fq 'type ipv6_addr;' "$POLICY_SET_FILE" &&
		grep -Fq 'flags timeout;' "$POLICY_SET_FILE" &&
		grep -Fq 'ip daddr @dns4_' "$POLICY_RULE_FILE" &&
		grep -Fq 'ip6 daddr @dns6_' "$POLICY_RULE_FILE" &&
		grep -Fq 'udp dport 53 counter redirect to :53' "$POLICY_DNS_REDIRECT_RULE_FILE" &&
		grep -Fq 'tcp dport 53 counter redirect to :53' "$POLICY_DNS_REDIRECT_RULE_FILE" &&
		[ "$(grep -c '^nftset=/' "$POLICY_DNSMASQ_RULE_FILE")" -eq 3 ] &&
		grep -Fq 'nftset=/baidu.com/4#inet#c2000_appaudit#dns4_' \
			"$POLICY_DNSMASQ_RULE_FILE" &&
		! grep -Fq 'unselected.example' "$POLICY_DNSMASQ_RULE_FILE" ||
		fail "DNS A/AAAA policy-set compilation regressed"

	C2000_TRAFFIC_DNSMASQ_CONFDIRS="$TMP/dnsmasq-policy.d"
	C2000_TRAFFIC_NO_DNSMASQ_RELOAD=1
	sync_dnsmasq_policy "$POLICY_DNSMASQ_RULE_FILE"
	cmp -s "$POLICY_DNSMASQ_RULE_FILE" \
		"$TMP/dnsmasq-policy.d/$DNSMASQ_POLICY_FILE" ||
		fail "dnsmasq did not receive the generated nftset policy"
	: > "$POLICY_DNSMASQ_RULE_FILE"
	sync_dnsmasq_policy "$POLICY_DNSMASQ_RULE_FILE"
	[ ! -e "$TMP/dnsmasq-policy.d/$DNSMASQ_POLICY_FILE" ] ||
		fail "stale dnsmasq nftset policy was not removed"
)

# Strict mode keeps only covered clients on the CPU path.  Downlink matching
# must include both IPv4 and IPv6 client addresses; deep mode is the explicit
# global fallback and is reported with a distinct sentinel count.
(
	POLICY_SET_FILE="$TMP/policy-bypass-sets.nft"
	POLICY_MARK_RULE_FILE="$TMP/policy-bypass-mark.nft"
	POLICY_LAN_DEVICE=br-lan
	: > "$POLICY_SET_FILE"
	: > "$POLICY_MARK_RULE_FILE"
	build_policy_targets()
	{
		: > "$2"
		cat > "$3" <<'EOF'
192.0.2.10	aa:bb:cc:dd:ee:01
2001:db8::10	aa:bb:cc:dd:ee:01
192.0.2.11	aa:bb:cc:dd:ee:02
EOF
		printf '%s\n' aa:bb:cc:dd:ee:01 aa:bb:cc:dd:ee:02 > "$4"
	}
	compile_policy_bypass strict "$TMP/unused-scopes"
	[ "$POLICY_BYPASS_COUNT" -eq 2 ] &&
		grep -Fq 'set strict_clients4 {' "$POLICY_SET_FILE" &&
		grep -Fq 'elements = { 192.0.2.10, 192.0.2.11 };' "$POLICY_SET_FILE" &&
		grep -Fq 'set strict_clients6 {' "$POLICY_SET_FILE" &&
		grep -Fq 'elements = { 2001:db8::10 };' "$POLICY_SET_FILE" &&
		grep -Fq 'ip daddr @strict_clients4 ct mark set ct mark | 0x00800000 meta mark set meta mark | 0x00800000' \
			"$POLICY_MARK_RULE_FILE" &&
		grep -Fq 'ip saddr @strict_clients4 ct mark set ct mark | 0x00800000 meta mark set meta mark | 0x00800000' \
			"$POLICY_MARK_RULE_FILE" &&
		grep -Fq 'ip6 daddr @strict_clients6 ct mark set ct mark | 0x00800000 meta mark set meta mark | 0x00800000' \
			"$POLICY_MARK_RULE_FILE" &&
		grep -Fq 'ip6 saddr @strict_clients6 ct mark set ct mark | 0x00800000 meta mark set meta mark | 0x00800000' \
			"$POLICY_MARK_RULE_FILE" &&
		! grep -Eq 'iifname "br-lan" meta mark set' "$POLICY_MARK_RULE_FILE" ||
		fail "strict mode does not selectively bypass IPv4/IPv6 client acceleration"

	: > "$POLICY_MARK_RULE_FILE"
	compile_policy_bypass deep "$TMP/unused-scopes"
	[ "$POLICY_BYPASS_COUNT" -eq -1 ] &&
		grep -Fq 'iifname "br-lan" ct mark set ct mark | 0x00800000 meta mark set meta mark | 0x00800000' \
			"$POLICY_MARK_RULE_FILE" &&
		grep -Fq 'oifname "br-lan" ct mark set ct mark | 0x00800000 meta mark set meta mark | 0x00800000' \
			"$POLICY_MARK_RULE_FILE" ||
		fail "deep diagnostic mode does not bypass both LAN directions"
)

# The immutable profile domain index must not launch the ucode parser at the
# collector's ten-second cadence.  One parse per content-addressed profile is
# sufficient; changing the profile invalidates the cache.
(
	mkdir -p "$TMP/domain-cache-bin"
	cat > "$TMP/domain-cache-bin/ucode" <<'EOF'
#!/bin/sh
printf 'run\n' >> "$DOMAIN_CACHE_CALLS"
printf '5110\thdslb.com\n'
EOF
	chmod +x "$TMP/domain-cache-bin/ucode"
	export PATH="$TMP/domain-cache-bin:$PATH"
	export DOMAIN_CACHE_CALLS="$TMP/domain-cache.calls"
	POLICY_FEATURE_FILE="$TMP/domain-cache-feature.cfg"
	DOMAIN_HELPER="$TMP/domain-cache-helper.uc"
	POLICY_ACTIVE_PROFILE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	printf 'fixture\n' > "$POLICY_FEATURE_FILE"
	printf 'fixture\n' > "$DOMAIN_HELPER"
	build_policy_domain_index "$TMP/domain-cache.tsv"
	build_policy_domain_index "$TMP/domain-cache.tsv"
	[ "$(wc -l < "$DOMAIN_CACHE_CALLS")" -eq 1 ] &&
		awk -F '\t' '$1==5110 && $2=="hdslb.com" {found=1} END {exit !found}' \
			"$TMP/domain-cache.tsv" ||
		fail "immutable policy domain index was reparsed despite a valid cache"
	POLICY_ACTIVE_PROFILE="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	build_policy_domain_index "$TMP/domain-cache.tsv"
	[ "$(wc -l < "$DOMAIN_CACHE_CALLS")" -eq 2 ] ||
		fail "profile switch did not invalidate the policy domain cache"
)

# Deterministic switch concurrency: an old-profile sample holds a shared
# profile lock through merge/snapshot.  The manager's exclusive transaction
# waits for it, then blocks a new-profile sample until pointer switch and reset
# finish.  This exercises real merge_audit() profile capture on both sides.
wait_for_file()
{
	local file="$1" tries=0
	while [ ! -f "$file" ]; do
		tries=$((tries + 1))
		[ "$tries" -lt 500 ] || fail "timed out waiting for ${file##*/}"
		sleep 0.01
	done
}

CONCURRENCY_DIR="$TMP/profile-concurrency"
mkdir -p "$CONCURRENCY_DIR"
PROFILE_LOCK_FILE="$CONCURRENCY_DIR/profile.lock"
LOCK_FILE="$CONCURRENCY_DIR/collector.lock"
AUDIT_FILE="$CONCURRENCY_DIR/audit.tsv"
AUDIT_PROFILED_FILE="$CONCURRENCY_DIR/audit.profiled"
TOTALS_FILE="$CONCURRENCY_DIR/totals.tsv"
SNAPSHOT_FILE="$CONCURRENCY_DIR/snapshot.tsv"
FEATURE_ACTIVE_FILE="$CONCURRENCY_DIR/active"
: > "$AUDIT_FILE"
: > "$AUDIT_PROFILED_FILE"
: > "$TOTALS_FILE"
: > "$SNAPSHOT_FILE"
printf '%s\n' "$PROFILE_A" > "$FEATURE_ACTIVE_FILE"
printf 'device\t192.0.2.1\tclient\tfiveg\t10\t20\t1700010000\t1001\n' \
	> "$CONCURRENCY_DIR/old.delta"
printf 'device\t192.0.2.1\tclient\tfiveg\t30\t40\t1700013600\t1002\n' \
	> "$CONCURRENCY_DIR/new.delta"

(
	profile_owned=0
	collector_owned=0
	profile_lock_acquire shared profile_owned
	collector_lock_acquire blocking collector_owned
	: > "$CONCURRENCY_DIR/old-held"
	wait_for_file "$CONCURRENCY_DIR/release-old"
	merge_audit "$CONCURRENCY_DIR/old.delta" 1700010060
	printf 'old\n' > "$SNAPSHOT_FILE"
	collector_lock_release collector_owned
	profile_lock_release profile_owned
	: > "$CONCURRENCY_DIR/old-done"
) &
old_pid=$!
wait_for_file "$CONCURRENCY_DIR/old-held"

# Daemon sampling keeps its historical nonblocking collector behavior, while
# an explicit/manager sample waits instead of returning false success.
probe_profile_owned=0
probe_collector_owned=0
profile_lock_acquire shared probe_profile_owned
if collector_lock_acquire nonblocking probe_collector_owned; then
	collector_lock_release probe_collector_owned
	profile_lock_release probe_profile_owned
	: > "$CONCURRENCY_DIR/release-old"
	wait "$old_pid" 2>/dev/null || true
	fail "daemon collector probe unexpectedly entered a busy sample"
else
	probe_rc=$?
fi
profile_lock_release probe_profile_owned
[ "$probe_rc" -eq 2 ] || fail "nonblocking collector did not report a busy sample"

(
	profile_owned=0
	collector_owned=0
	profile_lock_acquire shared profile_owned
	: > "$CONCURRENCY_DIR/blocking-sample-trying"
	collector_lock_acquire blocking collector_owned
	: > "$CONCURRENCY_DIR/blocking-sample-acquired"
	collector_lock_release collector_owned
	profile_lock_release profile_owned
) &
blocking_sample_pid=$!
wait_for_file "$CONCURRENCY_DIR/blocking-sample-trying"
[ ! -f "$CONCURRENCY_DIR/blocking-sample-acquired" ] || {
	: > "$CONCURRENCY_DIR/release-old"
	wait "$old_pid" 2>/dev/null || true
	wait "$blocking_sample_pid" 2>/dev/null || true
	fail "explicit sample did not block on the busy collector"
}

(
	profile_owned=0
	: > "$CONCURRENCY_DIR/manager-trying"
	profile_lock_acquire exclusive profile_owned
	: > "$CONCURRENCY_DIR/manager-held"
	printf '%s\n' "$PROFILE_B" > "$FEATURE_ACTIVE_FILE"
	: > "$SNAPSHOT_FILE"
	: > "$CONCURRENCY_DIR/manager-reset"
	wait_for_file "$CONCURRENCY_DIR/release-manager"
	profile_lock_release profile_owned
) &
manager_pid=$!
wait_for_file "$CONCURRENCY_DIR/manager-trying"
if [ -f "$CONCURRENCY_DIR/manager-held" ]; then
	: > "$CONCURRENCY_DIR/release-old"
	wait "$old_pid" 2>/dev/null || true
	wait "$manager_pid" 2>/dev/null || true
	fail "profile switch did not wait for the old sample"
fi
: > "$CONCURRENCY_DIR/release-old"
wait "$old_pid"
wait "$blocking_sample_pid"
wait_for_file "$CONCURRENCY_DIR/blocking-sample-acquired"
wait_for_file "$CONCURRENCY_DIR/manager-held"
wait_for_file "$CONCURRENCY_DIR/manager-reset"
[ -f "$CONCURRENCY_DIR/old-done" ] && [ -f "$CONCURRENCY_DIR/manager-reset" ] ||
	fail "manager entered the switch before old merge/reset ordering completed"

(
	profile_owned=0
	collector_owned=0
	: > "$CONCURRENCY_DIR/new-trying"
	profile_lock_acquire shared profile_owned
	collector_lock_acquire blocking collector_owned
	: > "$CONCURRENCY_DIR/new-held"
	merge_audit "$CONCURRENCY_DIR/new.delta" 1700013660
	printf 'new\n' > "$SNAPSHOT_FILE"
	collector_lock_release collector_owned
	profile_lock_release profile_owned
) &
new_pid=$!
wait_for_file "$CONCURRENCY_DIR/new-trying"
if [ -f "$CONCURRENCY_DIR/new-held" ]; then
	: > "$CONCURRENCY_DIR/release-manager"
	wait "$manager_pid" 2>/dev/null || true
	wait "$new_pid" 2>/dev/null || true
	fail "new sample entered while the profile transaction was exclusive"
fi
: > "$CONCURRENCY_DIR/release-manager"
wait "$manager_pid"
wait "$new_pid"

awk -F '\t' -v old="$PROFILE_A" -v new="$PROFILE_B" '
	$5==1001 && $13==old { old_ok=1 }
	$5==1002 && $13==new { new_ok=1 }
	END { exit !(old_ok && new_ok) }
' "$AUDIT_FILE" && [ "$(cat "$SNAPSHOT_FILE")" = new ] ||
	fail "profile switch mixed audit identities or let reset overwrite the new snapshot"

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

# A second, IKprotocol-shaped upload exercises the complete multi-profile
# lifecycle without redistributing any third-party feature data.  Six full
# 512-entry classes prove that a 3000+ application catalog is accepted, while
# conversion metadata preserves the distinction between source and converted
# application counts.
SMALL_PROFILE="$(sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p' "$TMP/feature-result.json")"
[ "${#SMALL_PROFILE}" -eq 64 ] || fail "initial feature profile id is invalid"
mkdir -p "$TMP/large-feature/app_icons"
{
	printf '%s\n' '#version v2.0.476-ikuai' '#format v3.0'
	class=1
	while [ "$class" -le 6 ]; do
		printf '#class class%s %s 分类%s\n' "$class" "$class" "$class"
		seq=1
		while [ "$seq" -le 512 ]; do
			appid=$((class * 1000 + seq))
			printf '%s 应用%s_%s:[tcp;;;a%s.example;;]\n' \
				"$appid" "$class" "$seq" "$appid"
			seq=$((seq + 1))
		done
		class=$((class + 1))
	done
} > "$TMP/large-feature/feature.cfg"
printf '%s\n' 'Synthetic compatibility fixture; no third-party rules.' > \
	"$TMP/large-feature/README.txt"
printf '%s\n' 'source_appid,oaf_appid' > "$TMP/large-feature/appid-map.csv"
printf '%s\n' '{}' > "$TMP/large-feature/appid-map.json"
printf '%s\n' '{"source_apps":3329,"skipped_apps":257}' > \
	"$TMP/large-feature/conversion-report.json"
tar -czf "$TMP/large-feature.bin" -C "$TMP/large-feature" \
	feature.cfg README.txt appid-map.csv appid-map.json conversion-report.json app_icons
C2000_FEATURE_DIR="$TMP/feature-install" \
C2000_FEATURE_ICON_DIR="$TMP/feature-icons" \
C2000_FEATURE_META="$TMP/feature.meta" \
	"$ROOT/root/usr/sbin/c2000max-feature-install" "$TMP/large-feature.bin" \
	> "$TMP/large-feature-result.json"
grep -q '"success":true' "$TMP/large-feature-result.json" &&
	grep -q '"apps":3072' "$TMP/large-feature-result.json" &&
	grep -q '"source_apps":3329' "$TMP/large-feature-result.json" &&
	grep -q '"skipped_apps":257' "$TMP/large-feature-result.json" ||
	fail "3000+ IKprotocol-shaped feature profile was not imported correctly"
LARGE_PROFILE="$(sed -n 's/.*"sha256":"\([0-9a-f]*\)".*/\1/p' "$TMP/large-feature-result.json")"
[ "${#LARGE_PROFILE}" -eq 64 ] && [ "$LARGE_PROFILE" != "$SMALL_PROFILE" ] ||
	fail "large feature profile id is invalid"

FEATURE_MANAGER="$ROOT/root/usr/sbin/c2000max-feature-manager"
feature_manager()
{
	C2000_FEATURE_DIR="$TMP/feature-install" \
	C2000_FEATURE_FILE="$TMP/feature-install/feature.cfg" \
	C2000_FEATURE_ICON_DIR="$TMP/feature-icons" \
	C2000_FEATURE_META="$TMP/feature.meta" \
	C2000_FEATURE_NO_RUNTIME=1 "$FEATURE_MANAGER" "$@"
}
feature_manager rollback > "$TMP/feature-rollback.json"
[ "$(cat "$TMP/feature-install/.c2000max-features/active")" = "$SMALL_PROFILE" ] &&
	grep -q '^1001 测试应用:' "$TMP/feature-install/feature.cfg" ||
	fail "feature profile rollback did not restore the original library"
mkdir "$TMP/feature-install/.c2000max-features/libraries/.incoming.interrupted"
feature_manager list > "$TMP/feature-list.json"
[ ! -e "$TMP/feature-install/.c2000max-features/libraries/.incoming.interrupted" ] ||
	fail "an interrupted profile staging directory was not reaped under the manager lock"
grep -q "\"active\":\"$SMALL_PROFILE\"" "$TMP/feature-list.json" &&
	grep -q "\"previous\":\"$LARGE_PROFILE\"" "$TMP/feature-list.json" &&
	[ "$(grep -o '"sha256"' "$TMP/feature-list.json" | wc -l)" -eq 2 ] ||
	fail "feature profile list did not preserve both switchable libraries"

# LuCI loads this list in its initial Promise.all.  It must not wait behind a
# long archive compilation/runtime reload, and immutable profile metadata must
# avoid re-hashing every 3000+ application feature.cfg just to render the list.
list_profiles_block="$(sed -n '/^list_profiles()/,/^}/p' "$FEATURE_MANAGER")"
if printf '%s\n' "$list_profiles_block" | grep -q 'sha256sum'; then
	fail "feature profile list still re-hashes complete feature libraries"
fi
MANAGER_LOCK="$TMP/feature-install/.c2000max-features/manager.lock"
rm -f "$TMP/manager-list-held" "$TMP/manager-list-release" "$TMP/manager-list-done"
(
	exec 7> "$MANAGER_LOCK"
	flock -x 7
	: > "$TMP/manager-list-held"
	while [ ! -f "$TMP/manager-list-release" ]; do sleep 0.01; done
) &
manager_list_lock_pid=$!
wait_for_file "$TMP/manager-list-held"
(
	feature_manager list > "$TMP/feature-list-busy.json"
	: > "$TMP/manager-list-done"
) &
manager_list_rpc_pid=$!
tries=0
while [ ! -f "$TMP/manager-list-done" ]; do
	tries=$((tries + 1))
	if [ "$tries" -ge 100 ]; then
		: > "$TMP/manager-list-release"
		kill "$manager_list_rpc_pid" 2>/dev/null || true
		wait "$manager_list_rpc_pid" 2>/dev/null || true
		wait "$manager_list_lock_pid" 2>/dev/null || true
		fail "feature profile list blocked behind the manager lock"
	fi
	sleep 0.01
done
wait "$manager_list_rpc_pid"
grep -q "\"active\":\"$SMALL_PROFILE\"" "$TMP/feature-list-busy.json" || {
	: > "$TMP/manager-list-release"
	wait "$manager_list_lock_pid" 2>/dev/null || true
	fail "nonblocking feature profile list lost the active profile"
}
: > "$TMP/manager-list-release"
wait "$manager_list_lock_pid"

# Simulate power loss after the active pointer commit but before feature.cfg
# replacement.  Boot-time init must adopt the material actually on disk under
# the exclusive profile lock, so the kernel and traffic identity agree again.
printf '%s\n' "$LARGE_PROFILE" > "$TMP/feature-install/.c2000max-features/active"
feature_manager init > "$TMP/feature-reconcile.json"
[ "$(cat "$TMP/feature-install/.c2000max-features/active")" = "$SMALL_PROFILE" ] &&
	[ "$(cat "$TMP/feature-install/.c2000max-features/previous")" = "$LARGE_PROFILE" ] &&
	grep -q "\"sha256\":\"$SMALL_PROFILE\"" "$TMP/feature-reconcile.json" ||
	fail "boot-time reconciliation left the pointer and active feature material mismatched"

# Failures after the pointer commit point must restore pointers, material and
# policy identity rather than leave a cross-library state.
for failpoint in pointer reload policy; do
	if C2000_FEATURE_TEST_FAIL="$failpoint" feature_manager activate "$LARGE_PROFILE" \
		> "$TMP/feature-fail-$failpoint.out" 2>&1; then
		fail "feature activation failpoint $failpoint unexpectedly succeeded"
	fi
	[ "$(cat "$TMP/feature-install/.c2000max-features/active")" = "$SMALL_PROFILE" ] &&
		grep -q '^1001 测试应用:' "$TMP/feature-install/feature.cfg" ||
		fail "feature activation failpoint $failpoint did not roll back"
done
if find "$TMP/feature-install/.c2000max-features" "$TMP/feature-install" \
	-name '*.new.*' -o -name '*.rollback.*' | grep -q .; then
	fail "feature activation left transaction staging files behind"
fi

# If both the new reload and rollback reload fail, disk state must still be
# restored, blocking policy must stay fail-open, and the operator must receive
# an explicit reboot warning rather than a false "previous profile restored".
mkdir -p "$TMP/fake-bin" "$TMP/fake-sysctl"
cat > "$TMP/fake-bin/pidof" <<'EOF'
#!/bin/sh
printf '%s\n' 999999
EOF
cat > "$TMP/fake-traffic" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$C2000_TEST_TRAFFIC_LOG"
EOF
chmod 0755 "$TMP/fake-bin/pidof" "$TMP/fake-traffic"
printf '1\n' > "$TMP/fake-sysctl/feature_init"
: > "$TMP/fake-traffic.log"
if PATH="$TMP/fake-bin:$PATH" \
	C2000_FEATURE_DIR="$TMP/feature-install" \
	C2000_FEATURE_FILE="$TMP/feature-install/feature.cfg" \
	C2000_FEATURE_ICON_DIR="$TMP/feature-icons" \
	C2000_FEATURE_META="$TMP/feature.meta" \
	C2000_FEATURE_NO_RUNTIME=0 \
	C2000_FEATURE_TRAFFIC="$TMP/fake-traffic" \
	C2000_FEATURE_SYSCTL_DIR="$TMP/fake-sysctl" \
	C2000_FEATURE_DAEMON=fake-oafd \
	C2000_TEST_TRAFFIC_LOG="$TMP/fake-traffic.log" \
	"$FEATURE_MANAGER" activate "$LARGE_PROFILE" \
	> "$TMP/double-reload-failure.out" 2>&1; then
	fail "activation succeeded after both runtime reloads failed"
fi
[ "$(cat "$TMP/feature-install/.c2000max-features/active")" = "$SMALL_PROFILE" ] &&
	grep -q '^1001 测试应用:' "$TMP/feature-install/feature.cfg" &&
	grep -q 'OAF runtime recovery failed' "$TMP/double-reload-failure.out" &&
	[ "$(tail -n 1 "$TMP/fake-traffic.log")" = audit-policy-clear ] ||
	fail "double reload failure did not restore disk, disable policy and require reboot"

# Raw/proprietary libraries and malformed match dictionaries are rejected;
# neither failure may alter the active profile.
printf '%s\n' 'not-a-converted-oaf-library' > "$TMP/raw.lib"
if feature_manager install "$TMP/raw.lib" > "$TMP/raw-lib.out" 2>&1; then
	fail "an unconverted raw library was accepted"
fi
mkdir -p "$TMP/bad-feature/app_icons"
cat > "$TMP/bad-feature/feature.cfg" <<'EOF'
#version v2.0.476-ikuai
#format v3.0
#class bad 1 错误
1001 错误应用:[tcp;;;bad.example;;00:73:01]
EOF
tar -czf "$TMP/bad-feature.bin" -C "$TMP/bad-feature" feature.cfg app_icons
if feature_manager install "$TMP/bad-feature.bin" > "$TMP/bad-feature.out" 2>&1; then
	fail "an unsafe feature dictionary was accepted"
fi
cat > "$TMP/bad-feature/feature.cfg" <<'EOF'
#version v2.0.476-ikuai
#format v3.0
#class bad 1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
1001 错误应用:[tcp;;;bad.example;;]
EOF
tar -czf "$TMP/bad-class-name.bin" -C "$TMP/bad-feature" feature.cfg app_icons
if feature_manager install "$TMP/bad-class-name.bin" > "$TMP/bad-class-name.out" 2>&1; then
	fail "a class display name wider than the oafd table was accepted"
fi
[ "$(cat "$TMP/feature-install/.c2000max-features/active")" = "$SMALL_PROFILE" ] ||
	fail "a rejected upload changed the active profile"

# Feature imports must outlive the short ubus/XHR request.  Exercise the real
# detached-job front end with a deliberately slow installer, including its
# single-instance lease, atomic terminal result and temporary-file cleanup.
FEATURE_JOB="$ROOT/root/usr/sbin/c2000max-feature-job"
FEATURE_JOB_DIR="$TMP/feature-jobs"
cat > "$TMP/feature-job-traffic" <<'EOF'
#!/bin/sh
[ "$1" = audit-migrate ] || exit 1
printf '%s\n' "$1" >> "$C2000_FEATURE_JOB_TEST_LOG"
EOF
cat > "$TMP/feature-job-installer" <<'EOF'
#!/bin/sh
case "${C2000_FEATURE_JOB_TEST_MODE:-success}" in
	slow) sleep 1 ;;
	fail)
		printf '%s\n' 'fake "install" rejected \\ input' >&2
		exit 1
		;;
esac
printf '%s\n' '{"success":true,"version":"v9.9.9","apps":3218,"features":12073}'
EOF
cat > "$TMP/feature-job-manager" <<'EOF'
#!/bin/sh
case "$1" in
	activate)
		[ "$#" -eq 2 ] || exit 2
		printf 'activate\t%s\n' "$2" >> "$C2000_FEATURE_JOB_MANAGER_LOG"
		;;
	rollback)
		[ "$#" -eq 1 ] || exit 2
		printf '%s\n' rollback >> "$C2000_FEATURE_JOB_MANAGER_LOG"
		;;
	*) exit 2 ;;
esac
case "${C2000_FEATURE_JOB_TEST_MODE:-success}" in
	manager-slow) sleep 1 ;;
	manager-fail)
		printf '%s\n' 'fake manager failure' >&2
		exit 1
		;;
esac
printf '%s\n' '{"success":true,"version":"v8.8.8","apps":3072,"features":10000}'
EOF
chmod 0755 "$TMP/feature-job-traffic" "$TMP/feature-job-installer" \
	"$TMP/feature-job-manager"
: > "$TMP/feature-job-traffic.log"
: > "$TMP/feature-job-manager.log"
C2000_FEATURE_JOB_DIR="$FEATURE_JOB_DIR"
C2000_FEATURE_JOB_LOCK="$FEATURE_JOB_DIR/active.lock"
C2000_FEATURE_JOB_CURRENT="$FEATURE_JOB_DIR/current"
C2000_FEATURE_JOB_INSTALLER="$TMP/feature-job-installer"
C2000_FEATURE_JOB_MANAGER="$TMP/feature-job-manager"
C2000_FEATURE_JOB_TRAFFIC="$TMP/feature-job-traffic"
C2000_FEATURE_JOB_TEST_LOG="$TMP/feature-job-traffic.log"
C2000_FEATURE_JOB_MANAGER_LOG="$TMP/feature-job-manager.log"
export C2000_FEATURE_JOB_DIR C2000_FEATURE_JOB_LOCK C2000_FEATURE_JOB_CURRENT
export C2000_FEATURE_JOB_INSTALLER C2000_FEATURE_JOB_MANAGER C2000_FEATURE_JOB_TRAFFIC
export C2000_FEATURE_JOB_TEST_LOG C2000_FEATURE_JOB_MANAGER_LOG
feature_job()
{
	"$FEATURE_JOB" "$@"
}

printf '%s\n' slow-upload > "$TMP/feature-job-upload-one"
C2000_FEATURE_JOB_TEST_MODE=slow
export C2000_FEATURE_JOB_TEST_MODE
feature_job start "$TMP/feature-job-upload-one" > "$TMP/feature-job-start.json"
grep -q '"accepted":true' "$TMP/feature-job-start.json" &&
	grep -Eq '"state":"(queued|running)"' "$TMP/feature-job-start.json" ||
	fail "feature import RPC did not return an immediate asynchronous job"
FEATURE_JOB_ID="$(sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p' "$TMP/feature-job-start.json")"
[ -n "$FEATURE_JOB_ID" ] && [ ! -e "$TMP/feature-job-upload-one" ] ||
	fail "feature job did not atomically take ownership of the upload"

printf '%s\n' competing-upload > "$TMP/feature-job-upload-two"
feature_job start "$TMP/feature-job-upload-two" > "$TMP/feature-job-busy.json" || true
grep -q '"busy":true' "$TMP/feature-job-busy.json" &&
	grep -q '"accepted":false' "$TMP/feature-job-busy.json" &&
	[ ! -e "$TMP/feature-job-upload-two" ] ||
	fail "feature jobs were not single-instance or left a competing upload behind"

tries=0
while :; do
	feature_job status "$FEATURE_JOB_ID" > "$TMP/feature-job-status.json"
	FEATURE_JOB_STATE="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$TMP/feature-job-status.json")"
	[ "$FEATURE_JOB_STATE" != done ] || break
	tries=$((tries + 1))
	[ "$tries" -lt 200 ] || fail "detached feature import did not complete"
	sleep 0.02
done
grep -q '"result":{"success":true' "$TMP/feature-job-status.json" &&
	grep -q '"apps":3218' "$TMP/feature-job-status.json" &&
	grep -q '^audit-migrate$' "$TMP/feature-job-traffic.log" ||
	fail "detached feature job lost the install result or audit migration"
if find "$FEATURE_JOB_DIR" -type f \( -name '*.upload' -o -name '*.result' -o -name '*.error' \) |
	grep -q .; then
	fail "completed feature job left uploaded content or worker logs behind"
fi

# The worker may complete before start_job() performs its kill -0 probe.  An
# immediate successful installer must never have its done state overwritten by
# a false "worker did not start" failure.
sleep 0.1
printf '%s\n' immediate-upload > "$TMP/feature-job-upload-fast"
C2000_FEATURE_JOB_TEST_MODE=success
export C2000_FEATURE_JOB_TEST_MODE
feature_job start "$TMP/feature-job-upload-fast" > "$TMP/feature-job-fast-start.json"
FEATURE_JOB_FAST_ID="$(sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p' "$TMP/feature-job-fast-start.json")"
tries=0
while :; do
	feature_job status "$FEATURE_JOB_FAST_ID" > "$TMP/feature-job-fast-status.json"
	FEATURE_JOB_STATE="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$TMP/feature-job-fast-status.json")"
	[ "$FEATURE_JOB_STATE" != done ] || break
	[ "$FEATURE_JOB_STATE" != failed ] || fail "an immediate successful worker was reported as failed"
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || fail "immediate feature import did not complete"
	sleep 0.01
done
grep -q '"result":{"success":true' "$TMP/feature-job-fast-status.json" ||
	fail "immediate feature import lost its terminal result"

# Exercise the worker entry point synchronously as well.  Its EXIT trap runs
# after run_worker() locals leave scope; set -u must not turn a successful job
# into a nonzero process exit at that boundary.
FEATURE_DIRECT_ID=1700000001-1-fedcba9876543210
printf '%s\n' direct-upload > "$FEATURE_JOB_DIR/$FEATURE_DIRECT_ID.upload"
feature_job _run "$FEATURE_DIRECT_ID" 1700000001 install ""
grep -q '"state":"done"' "$FEATURE_JOB_DIR/$FEATURE_DIRECT_ID.json" &&
	[ ! -e "$FEATURE_JOB_DIR/$FEATURE_DIRECT_ID.upload" ] ||
	fail "feature worker EXIT cleanup lost its terminal state"

# Switching and rollback share the exact same detached worker and activity
# lock as imports.  They must return immediately, reject a competing action,
# call the manager with an exact validated target, and avoid duplicating the
# manager's own pre-switch audit transaction.
sleep 0.1
FEATURE_MIGRATIONS_BEFORE="$(wc -l < "$TMP/feature-job-traffic.log")"
C2000_FEATURE_JOB_TEST_MODE=manager-slow
export C2000_FEATURE_JOB_TEST_MODE
feature_job activate "$PROFILE_A" > "$TMP/feature-job-activate-start.json"
grep -q '"accepted":true' "$TMP/feature-job-activate-start.json" &&
	grep -q '"action":"activate"' "$TMP/feature-job-activate-start.json" &&
	grep -Eq '"state":"(queued|running)"' "$TMP/feature-job-activate-start.json" ||
	fail "feature activation did not return an immediate asynchronous job"
FEATURE_ACTIVATE_JOB_ID="$(sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p' \
	"$TMP/feature-job-activate-start.json")"
feature_job rollback > "$TMP/feature-job-switch-busy.json" || true
grep -q '"busy":true' "$TMP/feature-job-switch-busy.json" &&
	grep -q '"accepted":false' "$TMP/feature-job-switch-busy.json" ||
	fail "activation and rollback did not share the feature-job single-instance lock"
tries=0
while :; do
	feature_job status "$FEATURE_ACTIVATE_JOB_ID" > "$TMP/feature-job-activate-status.json"
	FEATURE_JOB_STATE="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' \
		"$TMP/feature-job-activate-status.json")"
	[ "$FEATURE_JOB_STATE" != done ] || break
	[ "$FEATURE_JOB_STATE" != failed ] || fail "asynchronous feature activation failed"
	tries=$((tries + 1))
	[ "$tries" -lt 200 ] || fail "asynchronous feature activation did not complete"
	sleep 0.02
done
grep -Fxq "$(printf 'activate\t%s' "$PROFILE_A")" "$TMP/feature-job-manager.log" &&
	grep -q '"result":{"success":true' "$TMP/feature-job-activate-status.json" ||
	fail "feature activation lost its manager argument or terminal result"

sleep 0.1
C2000_FEATURE_JOB_TEST_MODE=success
export C2000_FEATURE_JOB_TEST_MODE
feature_job rollback > "$TMP/feature-job-rollback-start.json"
FEATURE_ROLLBACK_JOB_ID="$(sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p' \
	"$TMP/feature-job-rollback-start.json")"
tries=0
while :; do
	feature_job status "$FEATURE_ROLLBACK_JOB_ID" > "$TMP/feature-job-rollback-status.json"
	FEATURE_JOB_STATE="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' \
		"$TMP/feature-job-rollback-status.json")"
	[ "$FEATURE_JOB_STATE" != done ] || break
	[ "$FEATURE_JOB_STATE" != failed ] || fail "asynchronous feature rollback failed"
	tries=$((tries + 1))
	[ "$tries" -lt 100 ] || fail "asynchronous feature rollback did not complete"
	sleep 0.01
done
grep -Fxq rollback "$TMP/feature-job-manager.log" &&
	[ "$(wc -l < "$TMP/feature-job-traffic.log")" -eq "$FEATURE_MIGRATIONS_BEFORE" ] ||
	fail "feature rollback did not use the manager transaction or duplicated audit migration"

# Failed installers publish valid structured JSON and still delete the upload.
sleep 0.1
printf '%s\n' rejected-upload > "$TMP/feature-job-upload-fail"
C2000_FEATURE_JOB_TEST_MODE=fail
export C2000_FEATURE_JOB_TEST_MODE
feature_job start "$TMP/feature-job-upload-fail" > "$TMP/feature-job-fail-start.json"
FEATURE_JOB_FAIL_ID="$(sed -n 's/.*"job_id":"\([^"]*\)".*/\1/p' "$TMP/feature-job-fail-start.json")"
tries=0
while :; do
	feature_job status "$FEATURE_JOB_FAIL_ID" > "$TMP/feature-job-fail-status.json"
	FEATURE_JOB_STATE="$(sed -n 's/.*"state":"\([^"]*\)".*/\1/p' "$TMP/feature-job-fail-status.json")"
	[ "$FEATURE_JOB_STATE" != failed ] || break
	tries=$((tries + 1))
	[ "$tries" -lt 200 ] || fail "failed feature import never published terminal state"
	sleep 0.02
done
python3 -m json.tool "$TMP/feature-job-fail-status.json" >/dev/null 2>&1 &&
	grep -q 'fake \\"install\\" rejected' "$TMP/feature-job-fail-status.json" &&
	[ ! -e "$TMP/feature-job-upload-fail" ] ||
	fail "failed feature job emitted invalid JSON or leaked its upload"

# A queued/running state without the activity lock is a killed worker, not a
# task that should leave the UI polling forever after rpcd/service disruption.
sleep 0.1
FEATURE_STALE_ID=1700000000-1-0123456789abcdef
printf '%s\n' "$FEATURE_STALE_ID" > "$FEATURE_JOB_DIR/current"
printf '%s\n' '{"success":true,"job_id":"1700000000-1-0123456789abcdef","state":"running","started":1700000000}' \
	> "$FEATURE_JOB_DIR/$FEATURE_STALE_ID.json"
printf '%s\n' stale > "$FEATURE_JOB_DIR/$FEATURE_STALE_ID.upload"
feature_job status "$FEATURE_STALE_ID" > "$TMP/feature-job-stale-status.json"
grep -q '"state":"failed"' "$TMP/feature-job-stale-status.json" &&
	grep -q '任务被中断' "$TMP/feature-job-stale-status.json" &&
	[ ! -e "$FEATURE_JOB_DIR/$FEATURE_STALE_ID.upload" ] ||
	fail "an interrupted feature job was not recovered as a terminal failure"

sh -n "$TRAFFIC" "$EQOS_ROOT/root/usr/sbin/eqos" \
	"$EQOS_ROOT/root/etc/init.d/eqos" "$ROOT/root/etc/init.d/c2000max-traffic" \
	"$ROOT/root/usr/sbin/c2000max-feature-install" \
	"$ROOT/root/usr/sbin/c2000max-feature-manager" \
	"$ROOT/root/usr/sbin/c2000max-feature-job" \
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
	grep -Fq "'time_desc', '时间：最近优先'" "$TRAFFIC_VIEW" &&
	grep -Fq "renderAuditPage(1, 'time_desc')" "$TRAFFIC_VIEW" ||
	fail "application details do not provide 20-row paging and traffic/time sorting"
grep -Fq 'var pageSize = 50' "$TRAFFIC_VIEW" &&
	grep -Fq 'callCatalogSearch(profile' "$TRAFFIC_VIEW" &&
	grep -Fq 'var LazyAppSelector = form.MultiValue.extend' "$TRAFFIC_VIEW" &&
	grep -Fq '单项软件最多选择 256 个' "$TRAFFIC_VIEW" ||
	fail "large application catalogs are not searched and paged lazily"
grep -Fq "children: Array.prototype.slice.call(parentModalNode.childNodes)" "$TRAFFIC_VIEW" &&
	grep -Fq "parentModal.node.removeChild(child)" "$TRAFFIC_VIEW" &&
	grep -Fq "L.dom.content(parentModal.node, parentModal.children)" "$TRAFFIC_VIEW" &&
	grep -Fq "'type': 'button', 'click': closePicker" "$TRAFFIC_VIEW" ||
	fail "application picker does not preserve and restore the parent rule modal"
grep -Fq 'function safeText(value)' "$TRAFFIC_VIEW" &&
	grep -Fq "E('strong', {}, safeText(app.name))" "$TRAFFIC_VIEW" &&
	grep -Fq 'function safeChoice(value)' "$TRAFFIC_VIEW" &&
	grep -Fq 'safeChoice(category.name)' "$TRAFFIC_VIEW" &&
	grep -Fq "'应用流量审计 - %h'.format" "$TRAFFIC_VIEW" &&
	grep -Fq "'<b>%h</b><br>%h" \
		"$ROOT/htdocs/luci-static/resources/c2000max/traffic-chart.js" ||
	fail "uploaded catalog and device labels are not rendered as escaped text"
grep -Fq "addEventListener('c2000max-chart-destroy'" "$TRAFFIC_CHART" &&
	grep -Fq 'observer.disconnect()' "$TRAFFIC_CHART" &&
	grep -Fq 'destroyCharts(overview)' "$TRAFFIC_VIEW" ||
	fail "polling chart replacement does not release resize observers"
if grep -Fq 'callTrafficCatalog()' "$TRAFFIC_VIEW"; then
	fail "traffic page still downloads the complete application catalog"
fi
grep -Fq "data-tab-title': '概览'" "$TRAFFIC_VIEW" &&
	grep -Fq "data-tab-title': '设备流量'" "$TRAFFIC_VIEW" &&
	grep -Fq "data-tab-title': '应用审计'" "$TRAFFIC_VIEW" &&
	grep -Fq "data-tab-title': '实时应用'" "$TRAFFIC_VIEW" &&
	grep -Fq "data-tab-title': '管控与设置'" "$TRAFFIC_VIEW" ||
	fail "traffic statistics were not split into focused tabs"
grep -Fq "method: 'recent_audit'" "$TRAFFIC_VIEW" &&
	grep -Fq 'var pageSize = 50' "$TRAFFIC_VIEW" &&
	grep -Fq 'Math.min(150' "$TRAFFIC_VIEW" &&
	grep -Fq "'实时刷新'" "$TRAFFIC_VIEW" &&
	grep -Fq "'每 5 秒'" "$TRAFFIC_VIEW" &&
	grep -Fq '未知连接已过滤' "$TRAFFIC_VIEW" &&
	grep -Fq 'var loading = false' "$TRAFFIC_VIEW" &&
	grep -Fq "pane.getAttribute('data-tab-active') === 'true'" "$TRAFFIC_VIEW" &&
	grep -Fq "pane.addEventListener('cbi-tab-active'" "$TRAFFIC_VIEW" ||
	fail "real-time application tab is not bounded, paged or refreshable"
if sed -n '/function renderRealtimeAudit/,/^}/p' "$TRAFFIC_VIEW" | grep -Fq 'setInterval('; then
	fail "real-time application refresh can overlap slow RPC requests"
fi
grep -Fq 'var auditModalSequence = 0' "$TRAFFIC_VIEW" &&
	grep -Fq 'requestSequence !== auditModalSequence' "$TRAFFIC_VIEW" &&
	grep -Fq 'result.success !== true' "$TRAFFIC_VIEW" ||
	fail "modal audit/search requests do not reject stale or failed responses"
grep -Fq '最多检查 8 个有效载荷包' "$TRAFFIC_VIEW" &&
	grep -Fq '最多检查 64 个有效载荷包' "$TRAFFIC_VIEW" &&
	! grep -Fq '未知连接最多 %d 包' "$TRAFFIC_VIEW" ||
	fail "recognition window UI does not describe payload-packet accounting"
grep -Fq 'callFeatureActivate(id)' "$TRAFFIC_VIEW" &&
	grep -Fq 'callFeatureRollback()' "$TRAFFIC_VIEW" ||
	fail "LuCI does not expose safe user-controlled profile switching"
if grep -Fq '支持 OpenAppFilter 官方 ZIP/.bin' "$TRAFFIC_VIEW" ||
	grep -Fq '爱快规则不会被打包到固件或自动下载' "$TRAFFIC_VIEW" ||
	grep -Fq 'HNAT 使用硬件 MIB 同步' "$TRAFFIC_VIEW"; then
	fail "the removed feature-package/HNAT implementation notes are still visible"
fi
grep -Fq "method: 'feature_install_status'" "$TRAFFIC_VIEW" &&
	grep -Fq "method: 'feature_install_ack'" "$TRAFFIC_VIEW" &&
	grep -Fq "'id': 'c2000max-feature-job-banner'" "$TRAFFIC_VIEW" &&
	grep -Fq '任务正在路由器后台执行，请勿断电' "$TRAFFIC_VIEW" &&
	grep -Fq '重新进入本页仍会显示任务进度' "$TRAFFIC_VIEW" &&
	grep -Fq 'recoverFeatureJob(initialFeatureJob)' "$TRAFFIC_VIEW" &&
	grep -Fq 'function waitFeatureInstall(jobId, progress, failures)' "$TRAFFIC_VIEW" &&
	grep -Fq 'resolveWithin(callFeatureInstallStatus(jobId), null, 5000)' "$TRAFFIC_VIEW" &&
	grep -Fq 'result.busy === true || result.accepted === false' "$TRAFFIC_VIEW" &&
	grep -Fq "resolveFeatureJobStart(result, progress, '特征库切换失败')" "$TRAFFIC_VIEW" &&
	grep -Fq "resolveFeatureJobStart(result, progress, '特征库回退失败')" "$TRAFFIC_VIEW" &&
	grep -Fq 'return waitFeatureInstall(result.job_id, progress, 0)' "$TRAFFIC_VIEW" &&
	grep -Fq 'function acknowledgeFeatureJob(jobId)' "$TRAFFIC_VIEW" &&
	grep -Fq 'return acknowledgeFeatureJob(jobId).then(function() { return result; })' "$TRAFFIC_VIEW" ||
	fail "LuCI feature operations do not expose persistent bounded background progress"
if ! awk '
	/o = s\.option\(form\.Button, ._upload_feature./ { upload_block = 1 }
	upload_block && /if \(rejectConcurrentFeatureJob\(\)\)/ && !guard { guard = NR }
	upload_block && /ui\.uploadFile\(/ && !upload { upload = NR }
	END { exit !(guard && upload && guard < upload) }
' "$TRAFFIC_VIEW"; then
	fail "feature upload can start before the shared single-flight UI guard"
fi
[ "$(grep -c 'if (rejectConcurrentFeatureJob())' "$TRAFFIC_VIEW")" -ge 5 ] &&
	[ "$(grep -c 'releaseOnError = featureJobStartCanRelease(result)' "$TRAFFIC_VIEW")" -eq 3 ] &&
	[ "$(grep -c 'var startResponseReceived = false' "$TRAFFIC_VIEW")" -eq 3 ] &&
	grep -Fq 'if (!uploadCompleted || releaseOnError)' "$TRAFFIC_VIEW" &&
	! grep -Fq 'if (!asyncAccepted)' "$TRAFFIC_VIEW" ||
	fail "feature operation UI guard can be cleared by a competing or ambiguous start request"
grep -Fq '特征库操作任务被中断，请重试。' "$ROOT/root/usr/sbin/c2000max-feature-job" &&
	! grep -Fq '特征库安装任务被中断' "$ROOT/root/usr/sbin/c2000max-feature-job" ||
	fail "stale feature jobs still report an install-only recovery action"
grep -Fq 'acknowledge)' "$ROOT/root/usr/sbin/c2000max-feature-job" &&
	grep -Fq 'feature_install_ack)' "$ROOT/root/usr/libexec/rpcd/c2000max.traffic" &&
	grep -Fq '"feature_install_ack"' \
		"$ROOT/root/usr/share/rpcd/acl.d/luci-app-c2000max-traffic.json" ||
	fail "terminal feature jobs cannot be acknowledged and cleared after refresh"
grep -Fq 'var deferredStatus = { _deferred: true }' "$TRAFFIC_VIEW" &&
	grep -Fq 'managementDeferred: !!(statusDeferred' "$TRAFFIC_VIEW" &&
	grep -Fq 'var statusPollRequest = data.statusRequest || null' "$TRAFFIC_VIEW" &&
	grep -Fq 'var rulesetOption = o = s.option' "$TRAFFIC_VIEW" &&
	grep -Fq 'rulesetOption.default = currentProfileId' "$TRAFFIC_VIEW" ||
	fail "bounded first paint does not safely hydrate status and rule-profile identity"
	grep -Fq "callCatalogInfo('')" "$TRAFFIC_VIEW" &&
	grep -Fq "var lookupProfile = String(info.profile || info.profile_id || '')" "$TRAFFIC_VIEW" &&
	grep -Fq 'var ruleset = String(section.ruleset || active)' "$TRAFFIC_VIEW" &&
	grep -Fq 'callCatalogLookup(lookupProfile, Object.keys(wanted)' "$TRAFFIC_VIEW" &&
	grep -Fq 'currentProfileId = String(catalog.profile || catalog.profile_id ||' "$TRAFFIC_VIEW" &&
	! grep -Fq 'callCatalogLookup(active,' "$TRAFFIC_VIEW" ||
	fail "management choices can mix UCI and active-pointer feature generations"
grep -Fq 'var featureInstallInProgress = false' "$TRAFFIC_VIEW" &&
	grep -Fq 'featureInstallInProgress = true' "$TRAFFIC_VIEW" &&
	grep -Fq 'var profileConsistencyRequest = null' "$TRAFFIC_VIEW" &&
	grep -Fq "var request = L.resolveDefault(callCatalogInfo(''), {})" "$TRAFFIC_VIEW" &&
	grep -Fq 'resolvedProfile === wantedProfile' "$TRAFFIC_VIEW" &&
	grep -Fq 'pendingProfileId = String(nextStatus.feature_profile)' "$TRAFFIC_VIEW" ||
	fail "an asynchronous feature switch can reload LuCI before reaching a terminal state"
grep -Fq 'var managementOpened = false' "$TRAFFIC_VIEW" &&
	grep -Fq "if (tabName === 'traffic-manage')" "$TRAFFIC_VIEW" &&
	grep -Fq "managementPane.getAttribute('data-tab-active') === 'true'" "$TRAFFIC_VIEW" &&
	grep -Fq 'if (!managementOpened || !managementReady || managementRenderStarted)' "$TRAFFIC_VIEW" ||
	fail "the management form is still rendered before its tab is first opened"
grep -Fq '+coreutils-od' "$ROOT/Makefile" &&
	grep -Fq '+coreutils-sort' "$ROOT/Makefile" ||
	fail "traffic package is missing its od/sort runtime dependencies"
grep -Fxq '/etc/c2000max-traffic/features/' \
	"$ROOT/root/lib/upgrade/keep.d/c2000max-traffic" ||
	fail "uploaded feature profiles are not preserved by sysupgrade"
grep -Fxq '/www/luci-static/resources/c2000max-app-icons/' \
	"$ROOT/root/lib/upgrade/keep.d/c2000max-traffic" ||
	fail "the active profile icon set is not preserved by sysupgrade"
if find "$ROOT" -type f \( -name 'IKprotocol-*.bin' -o -name '*ikuai*.bin' \) | grep -q .; then
	fail "a third-party IKprotocol feature archive was bundled in the image"
fi
grep -Fq 'json_add_int last_seen' "$TRAFFIC" ||
	fail "application audit API does not expose the last activity time"
grep -q "option storage_limit_mb '100'" "$ROOT/root/etc/config/c2000max_traffic" &&
	grep -Fq "'storage_limit_mb', '日志数据上限（MB）'" "$TRAFFIC_VIEW" ||
	fail "traffic log storage does not default to a configurable 100 MB cap"
grep -q "option control_mode 'seamless'" "$ROOT/root/etc/config/c2000max_traffic" &&
	grep -Fq "o.value('force', '强力管控" "$TRAFFIC_VIEW" &&
	grep -Fq "o.value('strict', '选择性严格" "$TRAFFIC_VIEW" &&
	grep -Fq "o.value('deep', '全局深度实验" "$TRAFFIC_VIEW" &&
	grep -Fq 'force_recheck_policy_clients "$scope_file"' "$TRAFFIC" &&
	grep -Fq 'compile_policy_bypass "$control_mode" "$scope_file"' "$TRAFFIC" &&
	grep -Fq 'FLOW_BYPASS_MARK="0x00800000"' "$TRAFFIC" ||
	fail "application control does not expose targeted and diagnostic enforcement"
if grep -Fq '[ "$control_mode" != force ] || invalidate_acceleration_cache' "$TRAFFIC"; then
	fail "targeted force mode still flushes the complete HNAT table"
fi
grep -q 'ct secmark & 0x1fff0000' "$TRAFFIC" &&
	grep -q 'ct secmark & 0x0000ffff' "$TRAFFIC" ||
	fail "application blocking is not keyed by the profile epoch and isolated OAF APP_ID"
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
grep -q 'g_hold_acceleration || policy_no_offload' "$OAF_SOURCE" &&
	grep -q 'skb->mark |= OAF_ACCEL_BYPASS_MARK' "$OAF_SOURCE" ||
	fail "OAF acceleration bypass is not controlled by the recognition profile"
	grep -Fq 'mark |= OAF_CT_NO_OFFLOAD_MARK' "$OAF_SOURCE" &&
	grep -Fq 'af_ct_set_no_offload(ct, !!g_hold_acceleration || policy_no_offload)' "$OAF_SOURCE" &&
	grep -Fq 'af_ct_set_no_offload_locked(ct, drop)' "$OAF_SOURCE" &&
	grep -Fq 'policy_no_offload = !!(skb->mark & OAF_ACCEL_BYPASS_MARK)' "$OAF_SOURCE" &&
	grep -Fq 'skb->mark &= ~OAF_ACCEL_BYPASS_MARK' "$OAF_SOURCE" &&
	grep -Fq 'af_skb_apply_terminal_offload(skb,' "$OAF_SOURCE" &&
	grep -Fq 'policy_hold_published' "$OAF_SOURCE" ||
	fail "OAF does not persist pending/BLOCK or release ALLOW acceleration state"
grep -Fq 'ct mark set ct mark | %s meta mark set meta mark | %s' "$TRAFFIC" ||
	fail "strict policy marks only the current skb instead of the conntrack"
grep -Fq 'ct secmark & 0x0000ffff { %s } ct mark set ct mark | %s counter %s' "$TRAFFIC" ||
	fail "blocked APPID verdict does not pin the per-flow accelerator guard"
grep -Fq 'udp dport 443 ct mark set ct mark | %s counter reject comment "app_strict_quic_fallback"' "$TRAFFIC" ||
	fail "strict policy does not force opaque QUIC flows back to inspectable TCP/TLS"
grep -Fq 'POLICY_DOMAIN_CACHE_SCHEMA=2' "$TRAFFIC" &&
	grep -Fq 'cache_key="${POLICY_DOMAIN_CACHE_SCHEMA}:${POLICY_ACTIVE_PROFILE}"' "$TRAFFIC" &&
	grep -Fq 'POLICY_REFRESH_INTERVAL=60' "$TRAFFIC" &&
	grep -Fq 'now - last_policy_refresh' "$TRAFFIC" ||
	fail "periodic accounting still recompiles the 14k-feature policy every ten seconds"
grep -Fq 'symbol_get(mtk_hnat_kick_conntrack)' "$OAF_SOURCE" &&
	grep -Fq 'if (published && (drop || policy_no_offload))' "$OAF_SOURCE" &&
	grep -Fq 'af_hnat_kick_conntrack(ct);' "$OAF_SOURCE" ||
	fail "OAF BLOCK verdicts do not request an optional per-flow HNAT kick"
HNAT_HOOK_SOURCE="$ROOT/../../../../target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c"
grep -Fq 'READ_ONCE(ct->mark) & HNAT_EXCEPTION_TAG' "$HNAT_HOOK_SOURCE" ||
	fail "proprietary MediaTek HNAT does not honor the per-flow OAF guard"
FLOWCTL_PATCH="$ROOT/../../../../target/linux/mediatek/patches-6.12/999-zzzz-6003-c2000max-hnat-per-flow-kick.patch"
grep -Fq 'EXPORT_SYMBOL_GPL(mtk_hnat_kick_conntrack)' "$FLOWCTL_PATCH" &&
	grep -Fq '#define HNAT_FLOWCTL_COLLISION_SLOTS' "$FLOWCTL_PATCH" &&
	grep -Fq 'hnat_get_ppe_hash_by_count(&key, entry_count)' "$FLOWCTL_PATCH" &&
	grep -Fq 'entry->ipv4_hnapt.sport == tuple->sport' "$FLOWCTL_PATCH" &&
	grep -Fq 'entry->ipv4_hnapt.dport == tuple->dport' "$FLOWCTL_PATCH" &&
	grep -Fq 'spin_lock_bh(&h->entry_lock)' "$FLOWCTL_PATCH" &&
	grep -Fq '__entry_delete(h, entry)' "$FLOWCTL_PATCH" ||
	fail "HNAT flowctl does not tuple-verify a bounded collision bucket before KICK"
grep -Fq 'hnat_cache_clr(ppe_index)' "$FLOWCTL_PATCH" &&
	grep -Fq 'hnat_flowctl_flush(h)' "$FLOWCTL_PATCH" &&
	grep -Fq 'hnat_flowctl_deinit(h)' "$FLOWCTL_PATCH" &&
	grep -Fq 'debugfs_create_file("flowctl_status"' "$FLOWCTL_PATCH" ||
	fail "HNAT flowctl lacks cache commit, lifecycle drain, or diagnostics"
if grep -Fq 'foe_clear_all_bind_entries' "$FLOWCTL_PATCH"; then
	fail "per-flow HNAT KICK unexpectedly clears the global FOE table"
fi
PPE_MARK_PATCH="$ROOT/../../../../target/linux/mediatek/patches-6.12/999-ppe-36-mtk_ppe-add-binding-bypass-by-ct-mark-0x99.patch"
grep -Eq '^\+#define MTK_PPE_NO_OFFLOAD_MASK[[:space:]]+0x00800000' "$PPE_MARK_PATCH" &&
	grep -Fq 'ct->mark & MTK_PPE_NO_OFFLOAD_MASK' "$PPE_MARK_PATCH" ||
	fail "generic MediaTek PPE does not honor the per-flow OAF guard"
grep -q 'payload_count > g_max_dpi_packets' "$OAF_SOURCE" ||
	fail "OAF DPI packet window is still compile-time only"
grep -Fq 'af_dpi_global_try_enter(urgent_http)' "$OAF_SOURCE" &&
	grep -Fq 'atomic_cmpxchg(&af_dpi_global_owner, 0, 1)' "$OAF_SOURCE" &&
grep -Fq 'af_dpi_global_leave()' "$OAF_SOURCE" ||
	fail "large native DPI bursts can still monopolize both router CPUs"
grep -Fq 'ensure_audit_engine' "$TRAFFIC" &&
	grep -Fq '/etc/init.d/c2000max-appfilter start' "$TRAFFIC" &&
	grep -Fq 'audit-engine-sync' "$ROOT/root/etc/init.d/c2000max-traffic" ||
	fail "enabling audit after boot does not start OAF before policy compilation"
grep -Fq 'slot->ct == ct && !slot->complete' "$OAF_SOURCE" &&
	grep -Fq 'flow->dir != AF_IK_DIR_ORIGINAL' "$OAF_SOURCE" &&
	grep -Fq 'atomic64_inc(&af_http_stats.prefix_restarted)' "$OAF_SOURCE" &&
	grep -A8 -F 'if (terminal) {' "$OAF_SOURCE" | grep -Fq 'af_http_prefix_forget(ct)' &&
	grep -A8 -F 'if (published)' "$OAF_SOURCE" | grep -Fq 'af_http_prefix_forget(ct)' ||
	fail "terminal generic keep-alive requests can still reuse a stale HTTP prefix"
grep -Fq 'af_get_app_status_fast(node->app_id)' "$OAF_SOURCE" &&
	grep -Fq 'priority_budget_expired' "$OAF_SOURCE" &&
	grep -Fq 'field_prefilter_reject' "$OAF_SOURCE" &&
	grep -Fq 'proc_create("oaf_http_match_recent"' "$OAF_SOURCE" &&
	grep -Fq 'sync_oaf_priority_apps "$priority_app_build_file"' "$TRAFFIC" &&
	grep -Fq 'mv -f "$priority_app_build_file" "$priority_app_file"' "$TRAFFIC" ||
	fail "active policy APPIDs are not protected from native matcher budget starvation"
grep -Fq '#define AF_TLS_PREFIX_MAX 8192U' "$OAF_SOURCE" &&
	grep -Fq 'af_tls_client_hello_prefix(flow.l4_data, flow.l4_len)' "$OAF_SOURCE" &&
	grep -Fq 'atomic64_inc(&af_http_stats.tls_prefix_complete)' "$OAF_SOURCE" &&
	grep -Fq 'proc_create("oaf_sni_recent"' "$OAF_SOURCE" &&
	grep -Fq 'sni_heads[0] = &db->heads[proto][AF_FEATURE_FAMILY_SNI]' "$OAF_SOURCE" &&
	grep -Fq 'atomic64_inc(&af_http_stats.sni_prepass_match)' "$OAF_SOURCE" &&
	grep -Fq 'proc_create("oaf_sni_match_recent"' "$OAF_SOURCE" ||
	fail "split desktop TLS ClientHello/SNI does not have bounded reassembly and diagnostics"
grep -Fq 'kzalloc(sizeof(char) * (size + 1), GFP_KERNEL)' "$OAF_SOURCE" ||
	fail "OAF boot feature parser still reads beyond its exact-size buffer"
grep -Fq 'if (!skb || !len || from > skb->len || len > skb->len - from)' "$OAF_SOURCE" &&
	grep -Fq 'skb_copy_bits(skb, from, msg_buf, len)' "$OAF_SOURCE" ||
	fail "OAF non-linear skb payload copies are not bounded to the allocated buffer"
if grep -Fq 'skb_seq_read(consumed' "$OAF_SOURCE"; then
	fail "OAF still copies whole skb fragments into a payload-sized buffer"
fi
grep -Fq 'load_feature_config() < 0 || g_feature_init == 0' "$OAF_SOURCE" ||
	fail "OAF does not synchronously load the boot feature database"
grep -Fq 'db->count++' "$OAF_SOURCE" &&
	grep -Fq 'g_feature_init = new_db->count' "$OAF_SOURCE" ||
	fail "OAF does not expose the committed number of kernel signatures"
grep -Fq 'af_feature_active = new_db' "$OAF_SOURCE" &&
	grep -Fq 'af_feature_staging = NULL' "$OAF_SOURCE" &&
	grep -Fq 'g_feature_generation++' "$OAF_SOURCE" ||
	fail "OAF feature reload does not atomically publish the staged database"
grep -Fq 'left->fallback != right->fallback' "$OAF_SOURCE" &&
	grep -Fq 'left->specificity != right->specificity' "$OAF_SOURCE" &&
	grep -Fq 'iKuai stores port/IP/length, raw payload, SNI and HTTP rules' "$OAF_SOURCE" ||
	fail "native iKuai rules are still globally ordered by numeric priority before evidence strength"
feature_compare_block="$(sed -n '/^static int af_feature_node_compare(/,/^}/p' "$OAF_SOURCE")"
printf '%s\n' "$feature_compare_block" | grep -Fq 'af_feature_precedes(left, right)' &&
	printf '%s\n' "$feature_compare_block" | grep -Fq 'af_feature_precedes(right, left)' ||
	fail "feature bucket sort and runtime merge use different iKuai evidence orders"
grep -Fq 'list_add_tail(&node->head' "$OAF_SOURCE" &&
	grep -Fq 'list_sort(NULL, &db->heads' "$OAF_SOURCE" &&
	grep -Fq 'cond_resched()' "$OAF_SOURCE" ||
	fail "large native libraries still use quadratic/non-yielding feature insertion"
OAF_CLIENT_SOURCE="$ROOT/../c2000max-appfilter/src/oaf/af_client.c"
OAF_UTILS_SOURCE="$ROOT/../c2000max-appfilter/src/oaf/af_utils.c"
grep -Fq 'state->in ? state->in : skb->dev' "$OAF_CLIENT_SOURCE" &&
	grep -Fq 'netdev_master_upper_dev_get_rcu' "$OAF_UTILS_SOURCE" &&
	grep -Fq 'af_netdev_is_lan(in, g_lan_ifname)' "$OAF_SOURCE" ||
	fail "wired DSA/bridge clients can still be mistaken for WAN traffic"
grep -Fq 'alloc_ordered_workqueue("oaf_work", WQ_MEM_RECLAIM)' "$OAF_CLIENT_SOURCE" &&
	grep -Fq 'INIT_DELAYED_WORK(&client->client_work, client_work_handler)' "$OAF_CLIENT_SOURCE" &&
	grep -Fq 'cancel_delayed_work_sync(&client->client_work)' "$OAF_CLIENT_SOURCE" ||
	fail "OAF client reports are not confined to a cancel-safe process-context queue"
if grep -Eq 'timer_setup\(&client->client_timer|__af_visit_info_report\(client\).*timer' \
	"$OAF_CLIENT_SOURCE"; then
	fail "OAF client JSON reporting can still run from timer softirq context"
fi
OAFD_MAIN="$ROOT/../c2000max-appfilter/src/oafd/main.c"
grep -Fq 'initialise_boot_feature_state() < 0' "$OAFD_MAIN" &&
	grep -Fq 'kernel_count != expected_count' "$OAFD_MAIN" &&
	grep -Fq 'reuse boot feature database' "$OAFD_MAIN" ||
	fail "oafd still recompiles the complete native profile immediately after modprobe"
boot_init_line="$(grep -n 'initialise_boot_feature_state() < 0' "$OAFD_MAIN" | tail -n1 | cut -d: -f1)"
record_enable_line="$(grep -n '^[[:space:]]*update_oaf_record_status();' "$OAFD_MAIN" | tail -n1 | cut -d: -f1)"
[ -n "$boot_init_line" ] && [ -n "$record_enable_line" ] &&
	[ "$boot_init_line" -lt "$record_enable_line" ] ||
	fail "OAF packet recording starts before the boot feature database is validated"
grep -Fq 'INIT_DELAYED_WORK(&oaf_maintenance_work' "$OAF_SOURCE" &&
	grep -Fq 'cancel_delayed_work_sync(&oaf_maintenance_work)' "$OAF_SOURCE" ||
	fail "OAF periodic maintenance still runs from an unsafe timer context"
APPFILTER_INIT="$ROOT/../c2000max-appfilter/files/c2000max-appfilter.init"
TRAFFIC_INIT="$ROOT/root/etc/init.d/c2000max-traffic"
acct_line="$(grep -n 'nf_conntrack_acct=1' "$APPFILTER_INIT" | cut -d: -f1)"
module_line="$(grep -n '^[[:space:]]*modprobe oaf' "$APPFILTER_INIT" | cut -d: -f1)"
[ "$(grep -n 'c2000max-feature-manager init' "$APPFILTER_INIT" | cut -d: -f1)" -lt "$module_line" ] ||
	fail "OAF startup does not reconcile an interrupted profile transaction before module load"
[ "$(grep -n 'ln -sf /etc/appfilter/feature.cfg' "$APPFILTER_INIT" | cut -d: -f1)" -lt "$module_line" ] ||
	fail "OAF feature path is still created after the module loads"
[ -n "$acct_line" ] && [ -n "$module_line" ] && [ "$acct_line" -lt "$module_line" ] ||
	fail "application audit does not enable conntrack accounting before OAF"
grep -q "auto_load_engine='0'" "$APPFILTER_INIT" ||
	fail "OAF daemon can still race the init script by loading the module twice"
if grep -q 'c2000max-traffic audit-reset' "$APPFILTER_INIT"; then
	fail "enabling audit still destroys every LAN conntrack/PPE entry"
fi
grep -q 'c2000max-traffic sample' "$APPFILTER_INIT" &&
	grep -q 'traffic_run audit-rebaseline' "$ROOT/root/usr/sbin/c2000max-feature-manager" ||
	fail "audit startup/profile switching does not establish a non-destructive counter baseline"
grep -Fq 'ik-compiler.error' "$FEATURE_MANAGER" &&
	grep -Fq 'feature_reload_errno' "$FEATURE_MANAGER" &&
	grep -Fq '内核内存不足' "$FEATURE_MANAGER" ||
	fail "feature imports still hide compiler or kernel reload diagnostics"
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
{
	sed -n '/^apply_lan_device_profile()/,/^}/p' "$APPFILTER_INIT"
	sed -n '/^apply_recognition_profile()/,/^}/p' "$APPFILTER_INIT"
} > "$TMP/recognition-profile.sh"
. "$TMP/recognition-profile.sh"
OAF_SYSCTL_DIR="$TMP/oaf-sysctl"
mkdir -p "$OAF_SYSCTL_DIR"
: > "$OAF_SYSCTL_DIR/hold_acceleration"
: > "$OAF_SYSCTL_DIR/max_dpi_packets"
: > "$OAF_SYSCTL_DIR/lan_ifname"
uci() { printf '%s\n' "$PROFILE_MODE"; }
PROFILE_MODE=seamless
apply_recognition_profile
[ "$(cat "$OAF_SYSCTL_DIR/hold_acceleration")" = 0 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/max_dpi_packets")" = 8 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/lan_ifname")" = br-lan ] ||
	fail "seamless profile does not preserve immediate acceleration"
PROFILE_MODE=balanced
apply_recognition_profile
[ "$(cat "$OAF_SYSCTL_DIR/hold_acceleration")" = 1 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/max_dpi_packets")" = 8 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/lan_ifname")" = br-lan ] ||
	fail "balanced profile does not use the short DPI window"
PROFILE_MODE=precise
apply_recognition_profile
[ "$(cat "$OAF_SYSCTL_DIR/hold_acceleration")" = 1 ] &&
	[ "$(cat "$OAF_SYSCTL_DIR/max_dpi_packets")" = 64 ] ||
	fail "precise profile does not retain the full DPI window"
grep -q "option recognition_mode 'balanced'" \
	"$ROOT/root/etc/config/c2000max_traffic" ||
	fail "balanced recognition is not the accuracy-safe default"
grep -Fq "accuracy_default_v42" \
	"$ROOT/root/etc/uci-defaults/luci-c2000max-traffic" ||
	fail "the previous seamless default is not migrated once"
grep -q "value('balanced'.*8 个有效载荷包后恢复硬件加速" \
	"$ROOT/htdocs/luci-static/resources/view/c2000max/traffic.js" ||
	fail "LuCI does not expose the balanced recognition profile"
grep -q "value('precise'.*最多检查 64 个有效载荷包" \
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
HNAT_PATCH="$ROOT/../../../../target/linux/mediatek/patches-6.12/999-zzz-5120-mtk-hnat-bound-audit-mib-sync.patch"
grep -Fq 'debugfs_create_file("mib_sync"' "$HNAT_PATCH" ||
	fail "HNAT final-layer patch does not expose the lightweight MIB sync path"
grep -Fq 'struct mutex' "$HNAT_PATCH" &&
	grep -Fq 'mutex_lock_interruptible(&h->mib_sync_lock)' "$HNAT_PATCH" &&
	grep -Fq 'HNAT_MIB_SYNC_SCAN_BUDGET' "$HNAT_PATCH" &&
	grep -Fq 'HNAT_MIB_SYNC_READ_BUDGET' "$HNAT_PATCH" &&
	grep -Fq 'cond_resched()' "$HNAT_PATCH" ||
	fail "HNAT MIB accounting is not serialized and incrementally scheduled"
if grep -Eq '^\+.*!\(val & BIT_MIB_BUSY\), 20, 10000' "$HNAT_PATCH"; then
	fail "HNAT can still atomically spin for 10ms per flow counter"
fi
grep -Eq '^\+.*!\(val & BIT_MIB_BUSY\), 20, 1000' "$HNAT_PATCH" ||
	fail "HNAT final-layer patch does not cap each atomic MIB poll at 1ms"

echo "PASS: acceleration-aware traffic accounting fixtures"
