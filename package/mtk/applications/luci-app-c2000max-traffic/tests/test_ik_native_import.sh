#!/bin/sh

set -eu
LC_ALL=C
export LC_ALL

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PACKAGE_DIR="$(CDPATH= cd -- "$HERE/.." && pwd)"
COMPILER="$PACKAGE_DIR/root/usr/libexec/c2000max-ik-compile.uc"
DOMAIN_HELPER="$PACKAGE_DIR/root/usr/libexec/c2000max-feature-domains.uc"
MANAGER="$PACKAGE_DIR/root/usr/sbin/c2000max-feature-manager"
UCODE_BIN="${UCODE_BIN:-$(command -v ucode 2>/dev/null || true)}"
UCODE_MODULE_PATH="${UCODE_MODULE_PATH:-}"

if [ -z "$UCODE_BIN" ]; then
	echo "SKIP: ucode is unavailable (set UCODE_BIN and optionally UCODE_MODULE_PATH)"
	exit 0
fi

TMP="$(mktemp -d /tmp/c2000max-ik-test.XXXXXX)"
cleanup_tmp()
{
	chmod -R u+w "$TMP" 2>/dev/null || true
	rm -rf "$TMP" 2>/dev/null || true
}
trap cleanup_tmp EXIT HUP INT TERM
FIXTURE="$TMP/fixture"
OUTPUT="$TMP/output"
mkdir -p "$FIXTURE" "$OUTPUT"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

# BusyBox awk terminates a /.../ literal at an unescaped slash even when it
# appears inside a bracket expression.  Keep archive path normalization on
# substr(), otherwise /^\.[/]/ is parsed as the invalid expression /^\.[/.
if grep -Fq 'sub(/^\.[/]/' "$MANAGER"; then
	fail "manager contains the BusyBox awk-incompatible ./ regex"
fi
[ "$(grep -Fc 'substr(path, 1, 2) == "./"' "$MANAGER")" -ge 1 ] ||
	fail "tar member path normalization does not use substr"
[ "$(grep -Fc 'substr(p, 1, 2) == "./"' "$MANAGER")" -ge 1 ] ||
	fail "archive path normalization does not use substr"

run_ucode()
{
	if [ -n "$UCODE_MODULE_PATH" ]; then
		"$UCODE_BIN" -L "$UCODE_MODULE_PATH" "$@"
	else
		"$UCODE_BIN" "$@"
	fi
}

cat > "$FIXTURE/README.txt" <<'EOF'
IKprotocol 9.8.7 extracted edition

Leaf applications/protocols: 3
IKAPP rules decoded: 7
HTTP rules decoded: 4
EOF

cat > "$FIXTURE/appid-map.json" <<'EOF'
[
 {"appid":0,"name":"未定义","category":"未分类","major_category":"未分类","oaf_appid":3001},
 {"appid":100,"name":"Alpha:App","category":"系统工具","major_category":"工具","oaf_appid":1001},
 {"appid":200,"name":"Beta App","category":"网页服务","major_category":"网页","oaf_appid":2001}
]
EOF

cat > "$FIXTURE/ikapp-rules.jsonl" <<'EOF'
{"kind":"IKAPP","appid":100,"proto":0,"dir":1,"pkt_seq":2,"data_b64":"YWJj","data_len":3,"match_flag":0,"offset":null,"match_method":5,"port_range":[],"priority":42,"rule_id":1001,"https_tls":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKAPP","appid":100,"proto":6,"dir":1,"pkt_seq":1,"data_b64":"ZXhhbXBsZS5jb20=","data_len":11,"match_flag":0,"offset":null,"match_method":0,"port_range":[[443,443]],"priority":90,"rule_id":1002,"https_tls":1,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKAPP","appid":100,"proto":6,"dir":1,"pkt_seq":1,"data_b64":"eHg=","data_len":2,"match_flag":0,"offset":null,"match_method":0,"port_range":[],"priority":80,"rule_id":1003,"https_tls":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKAPP","appid":100,"proto":6,"dir":1,"pkt_seq":1,"data_b64":"eHg=","data_len":2,"match_flag":0,"offset":null,"match_method":0,"port_range":[],"priority":80,"rule_id":1004,"https_tls":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKAPP","appid":100,"proto":17,"dir":1,"pkt_seq":0,"data_b64":"","data_len":0,"match_flag":0,"offset":null,"match_method":2,"port_range":[[80,80],[443,443]],"priority":70,"rule_id":1005,"https_tls":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKAPP","appid":100,"proto":17,"dir":1,"pkt_seq":0,"data_b64":"","data_len":0,"match_flag":0,"offset":null,"match_method":2,"port_range":[],"priority":70,"rule_id":1006,"https_tls":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKAPP","appid":100,"proto":6,"dir":1,"pkt_seq":1,"data_b64":"XGQ=","data_len":2,"match_flag":0,"offset":null,"match_method":1,"port_range":[],"priority":60,"rule_id":1007,"https_tls":0,"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
EOF

cat > "$FIXTURE/http-rules.jsonl" <<'EOF'
{"kind":"IKHTTPAPP","appid":200,"dir":1,"pkt_seq":1,"match_flag":0,"priority":200,"rule_id":2001,"headers":[{"index":1,"data":"api.example","match_method":0}],"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKHTTPAPP","appid":200,"dir":1,"pkt_seq":1,"match_flag":0,"priority":190,"rule_id":2002,"headers":[{"index":0,"data":"^/v1","match_method":0}],"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKHTTPAPP","appid":200,"dir":1,"pkt_seq":1,"match_flag":0,"priority":180,"rule_id":2003,"headers":[{"index":0,"data":"^/x","match_method":0},{"index":1,"data":"x.example","match_method":0}],"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
{"kind":"IKHTTPAPP","appid":200,"dir":1,"pkt_seq":1,"match_flag":0,"priority":170,"rule_id":2004,"headers":[{"index":0,"data":"literal","match_method":0}],"sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
EOF

cat > "$FIXTURE/app5.decode_raw.txt" <<'EOF'
5 {
  1 {
    1 {
      2: 0
      20: 1001
    }
    1 {
      2: 6
      20: 1002
    }
    1 {
      2: 6
      20: 1003
    }
    1 {
      2: 17
      20: 1005
    }
    1 {
      2: 17
      20: 1006
    }
    1 {
      2: 6
      20: 1007
    }
  }
  17 {
    1: 4
    2: 64
    3 {
      1 {
        2: 6
        20: 1004
      }
    }
  }
  13 {
    1 {
      8: 2001
    }
  }
  14 {
    1: 0
    2: 4
    3: 16
    4 {
      1 {
        8: 2002
      }
    }
  }
  2 {
    8: 2003
  }
  18 {
    1: 0
    2 {
      8: 2004
    }
  }
}
EOF
printf 'synthetic app5 fixture\n' > "$FIXTURE/app5.dat"

run_ucode "$COMPILER" "$FIXTURE" "$OUTPUT" > "$TMP/compiler.json"
grep -q '"compiled_apps": 2' "$TMP/compiler.json" || fail "compiled app count"
grep -q '"compiled_rules": 8' "$TMP/compiler.json" || fail "compiled rule count"
grep -q '"skipped_rules": 3' "$TMP/compiler.json" || fail "skipped rule count"
grep -q '"dns_domains": 2' "$TMP/compiler.json" || fail "safe DNS domain count"
grep -q '^#format v4.2$' "$OUTPUT/feature.cfg" || fail "v4.2 header"
grep -q 'any;;;;;;;0;1;2;bm;;616263;42' "$OUTPUT/feature.cfg" || fail "native any/BM rule"
grep -q 'udp;;80|443;;;;;0;1;0;port;;;70;;;;1' "$OUTPUT/feature.cfg" ||
	fail "weak port evidence was not deferred behind the application's payload rules"
grep -q 'exact;0;7878;80' "$OUTPUT/feature.cfg" || fail "prefix context starts at payload byte zero"
grep -q 'http_multi;;0101000b6170692e6578616d706c65;200' "$OUTPUT/feature.cfg" || fail "exact-host compound context"
grep -q 'http_multi;;010002045e2f7631;190' "$OUTPUT/feature.cfg" || fail "prefix compound context"
grep -q 'http_multi;;020002035e2f78010209782e6578616d706c65;180' "$OUTPUT/feature.cfg" || fail "multi-header AND expression"
grep -q '"exact_context_missing": 1' "$OUTPUT/conversion-report.json" || fail "missing exact context report"
grep -q '"regex_character_escape_unsupported": 1' "$OUTPUT/conversion-report.json" || fail "unsupported regex escape report"
grep -q '"http_multi": 4' "$OUTPUT/conversion-report.json" || fail "compound HTTP kind report"
grep -q '"deferred_weak_features": 1' "$OUTPUT/conversion-report.json" ||
	fail "deferred weak-feature accounting"
[ "$(wc -l < "$OUTPUT/catalog.tsv")" -eq 4 ] || fail "full source catalog"
awk -F '\t' '$1 == 1001 && $2 == "Alpha_App" && $4 == "系统工具" { found = 1 } END { exit !found }' \
	"$OUTPUT/catalog.tsv" || fail "semantic application category"
awk -F '\t' '$1==1001 && $2=="example.com" && $3==100 {found=1} END {exit !found}' \
	"$OUTPUT/domains.tsv" || fail "SNI domain index"
awk -F '\t' '$1==2001 && $2=="api.example" && $3==200 {found=1} END {exit !found}' \
	"$OUTPUT/domains.tsv" || fail "standalone Host domain index"
! grep -q 'x.example' "$OUTPUT/domains.tsv" || fail "multi-clause Host was unsafely flattened"
run_ucode "$DOMAIN_HELPER" "$OUTPUT/feature.cfg" "$OUTPUT/domains.tsv" |
	sort -t "$(printf '\t')" -k1,1n -k2,2 > "$TMP/domain-helper.tsv"
awk -F '\t' '$1==1001 && $2=="example.com" {a=1} $1==2001 && $2=="api.example" {b=1} END {exit !(a&&b)}' \
	"$TMP/domain-helper.tsv" ||
	fail "runtime DNS domain helper"

( cd "$FIXTURE" && tar -czf "$TMP/native.tar.gz" . )
cat > "$TMP/compiler-wrapper" <<'EOF'
#!/bin/sh
if [ -n "${UCODE_MODULE_PATH:-}" ]; then
	exec "$UCODE_BIN" -L "$UCODE_MODULE_PATH" "$IK_COMPILER_SCRIPT" "$@"
fi
exec "$UCODE_BIN" "$IK_COMPILER_SCRIPT" "$@"
EOF
chmod 0755 "$TMP/compiler-wrapper"

mkdir -p "$TMP/router/etc/appfilter" "$TMP/router/etc/traffic" \
	"$TMP/router/www/icons" "$TMP/router/tmp"
cat > "$TMP/router/etc/appfilter/feature.cfg" <<'EOF'
#version v1.0
#format v3.0
#class builtin 1 Builtin
1001 Builtin:[tcp;;;;;]
EOF

export UCODE_BIN UCODE_MODULE_PATH IK_COMPILER_SCRIPT="$COMPILER"
manager_env()
{
	C2000_FEATURE_DIR="$TMP/router/etc/appfilter" \
	C2000_FEATURE_FILE="$TMP/router/etc/appfilter/feature.cfg" \
	C2000_FEATURE_ICON_DIR="$TMP/router/www/icons" \
	C2000_FEATURE_META_FILE="$TMP/router/etc/traffic/feature.meta" \
	C2000_FEATURE_STATE_DIR="$TMP/router/state" \
	C2000_FEATURE_TRAFFIC_PROFILE_LOCK="$TMP/router/traffic.lock" \
	C2000_FEATURE_TMPDIR="$TMP/router/tmp" \
	C2000_FEATURE_IK_COMPILER="$TMP/compiler-wrapper" \
	NO_RUNTIME=1 "$MANAGER" "$@"
}

manager_env import "$TMP/native.tar.gz" > "$TMP/import.json"
grep -q '"source_format":"ik-native-v1"' "$TMP/import.json" || fail "manager source format"
grep -q '"format":"v4.2"' "$TMP/import.json" || fail "manager runtime format"
grep -q '"compiled_rules":8' "$TMP/import.json" || fail "manager rule count"
ACTIVE="$(cat "$TMP/router/state/active")"
[ -f "$TMP/router/state/libraries/$ACTIVE/app5.dat" ] || fail "raw app5 preservation"
[ -f "$TMP/router/state/libraries/$ACTIVE/app5.decode_raw.txt" ] || fail "raw context preservation"
[ -f "$TMP/router/state/libraries/$ACTIVE/ikapp-rules.jsonl" ] || fail "IK JSONL preservation"
[ -f "$TMP/router/state/libraries/$ACTIVE/domains.tsv" ] || fail "DNS domain index preservation"
grep -q '^raw_context_recovered=1$' "$TMP/router/state/libraries/$ACTIVE/native.meta" || fail "native metadata"
grep -q '^dns_domains=2$' "$TMP/router/state/libraries/$ACTIVE/native.meta" || fail "DNS metadata"

mkdir "$TMP/incomplete"
cp "$FIXTURE/README.txt" "$FIXTURE/appid-map.json" "$FIXTURE/ikapp-rules.jsonl" \
	"$FIXTURE/http-rules.jsonl" "$FIXTURE/app5.dat" "$TMP/incomplete/"
( cd "$TMP/incomplete" && tar -czf "$TMP/incomplete.tar.gz" . )
if manager_env import "$TMP/incomplete.tar.gz" > "$TMP/incomplete.out" 2>&1; then
	fail "archive without raw parent context was accepted"
fi
[ "$(cat "$TMP/router/state/active")" = "$ACTIVE" ] || fail "failed import switched profile"

echo "PASS: ik-native-v1 compiler, context recovery, archive import and rollback safety"
