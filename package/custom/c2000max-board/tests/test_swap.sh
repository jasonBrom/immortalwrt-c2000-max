#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/files/usr/sbin/c2000max-swap"
VIEW="$ROOT/files/www/luci-static/resources/view/c2000max/swap_v352.js"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

declare -A DB
SERVICE_ENABLED=1
STOP_FAIL=0
PROC_SWAPS="$TMP/swaps"
ZRAM_SYS="$TMP/zram0"
ZRAM_INIT="$TMP/zram"
SWAPPINESS_PROC="$TMP/swappiness"

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

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
		commit)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

mkdir -p "$ZRAM_SYS"
printf 'lzo [lzo-rle]\n' > "$ZRAM_SYS/comp_algorithm"
printf '0 0 0 0 0 0 0 0\n' > "$ZRAM_SYS/mm_stat"
printf '60\n' > "$SWAPPINESS_PROC"
printf '#!/bin/sh\nexit 0\n' > "$ZRAM_INIT"
chmod +x "$ZRAM_INIT"

source <(awk '/^json_escape/{emit=1} /^mkdir -p /{exit} emit{print}' "$SCRIPT")

service_enable() { SERVICE_ENABLED=1; }
service_disable() { SERVICE_ENABLED=0; }
service_stop()
{
	[[ "$STOP_FAIL" == 1 ]] && return 1
	printf 'Filename Type Size Used Priority\n' > "$PROC_SWAPS"
}
service_start()
{
	printf 'Filename Type Size Used Priority\n/dev/zram0 partition %s 0 %s\n' \
		"$((DB[c2000max.swap.size_mb] * 1024))" "${DB[c2000max.swap.priority]}" > "$PROC_SWAPS"
}

reset_swap()
{
	DB=(
		[c2000max.swap.enabled]=1
		[c2000max.swap.size_mb]=256
		[c2000max.swap.comp_algo]=lzo
		[c2000max.swap.priority]=100
		[c2000max.swap.swappiness]=150
		["system.@system[0].zram_size_mb"]=256
		["system.@system[0].zram_comp_algo"]=lzo
		["system.@system[0].zram_priority"]=100
	)
	SERVICE_ENABLED=1
	STOP_FAIL=0
	printf '150\n' > "$SWAPPINESS_PROC"
	printf 'Filename Type Size Used Priority\n/dev/zram0 partition 262144 1024 100\n' > "$PROC_SWAPS"
}

reset_swap
apply_swap true 512 lzo-rle 120 150 > "$TMP/output"
output="$(<"$TMP/output")"
grep -Fq '"success":true' <<<"$output" ||
	fail "valid ZRAM resize did not succeed"
[[ "${DB[c2000max.swap.size_mb]}" == 512 &&
   "${DB[system.@system[0].zram_size_mb]}" == 512 ]] ||
	fail "ZRAM size was not mirrored into both configurations"
[[ "${DB[c2000max.swap.comp_algo]}" == lzo-rle ]] ||
	fail "compression algorithm was not saved"
[[ "${DB[c2000max.swap.swappiness]}" == 150 &&
   "$(<"$SWAPPINESS_PROC")" == 150 ]] ||
	fail "configured swappiness was not saved and applied"
zram_active || fail "ZRAM was not active after a successful resize"

reset_swap
STOP_FAIL=1
if apply_swap true 512 lzo 100 150 > "$TMP/output"; then
	fail "resize succeeded even though active swap could not be released"
fi
output="$(<"$TMP/output")"
grep -Fq '设置未更改' <<<"$output" ||
	fail "swapoff failure did not return the safety error"
[[ "${DB[c2000max.swap.size_mb]}" == 256 ]] ||
	fail "swapoff failure changed the saved size"
[[ "$(<"$SWAPPINESS_PROC")" == 150 ]] ||
	fail "swapoff failure changed runtime swappiness"
zram_active || fail "swapoff failure removed the original active swap"

reset_swap
apply_swap false 256 lzo 100 150 > "$TMP/output"
output="$(<"$TMP/output")"
grep -Fq '"success":true' <<<"$output" ||
	fail "disabling ZRAM failed"
[[ "${DB[c2000max.swap.enabled]}" == 0 && "$SERVICE_ENABLED" == 0 ]] ||
	fail "disabling ZRAM did not save and disable the boot service"
! zram_active || fail "ZRAM remained active after disable"

reset_swap
if apply_swap true 63 lzo 100 150 > "$TMP/output"; then
	fail "undersized ZRAM setting was accepted"
fi
output="$(<"$TMP/output")"
grep -Fq '64–1024' <<<"$output" ||
	fail "invalid size did not return a precise validation error"

reset_swap
if apply_swap true 256 zstd 100 150 > "$TMP/output"; then
	fail "unsupported compressor was accepted"
fi
output="$(<"$TMP/output")"
grep -Fq '不支持' <<<"$output" ||
	fail "unsupported compressor did not return a precise validation error"

reset_swap
if apply_swap true 256 lzo 100 201 > "$TMP/output"; then
	fail "out-of-range swappiness was accepted"
fi
output="$(<"$TMP/output")"
grep -Fq '0–200' <<<"$output" ||
	fail "invalid swappiness did not return a precise validation error"

reset_swap
DB[c2000max.swap.swappiness]=150
tune_swappiness > "$TMP/output"
[[ "$(<"$SWAPPINESS_PROC")" == 150 ]] ||
	fail "boot-time swappiness tuning was not applied"

reset_swap
status_json="$(status_swap)"
jq -e '.success == true and .active == true and .size_mb == 256
	and .swappiness == 150 and .current_swappiness == 150' \
	<<<"$status_json" >/dev/null ||
	fail "status JSON does not describe the active configuration"
jq -e '.supported_algorithms == ["lzo","lzo-rle"]' \
	<<<"$status_json" >/dev/null ||
	fail "status JSON does not expose the kernel-supported algorithms"

grep -Fq '+zram-swap' "$ROOT/Makefile" ||
	fail "board package does not depend on zram-swap"
grep -Fq "option size_mb '256'" "$ROOT/files/etc/config/c2000max" ||
	fail "fresh-install ZRAM size is not 256 MB"
grep -Fq "option swappiness '150'" "$ROOT/files/etc/config/c2000max" ||
	fail "fresh-install swappiness is not 150"
grep -Fq 'c2000max-swap-tune' "$ROOT/Makefile" ||
	fail "board package does not install the boot-time swappiness service"
grep -Fq "'priority', 'swappiness'" "$VIEW" ||
	fail "LuCI SWAP view does not send the swappiness setting"
grep -Fq '空闲 100%' "$VIEW" ||
	fail "LuCI SWAP view does not explain the free-SWAP percentage"
if command -v node >/dev/null 2>&1; then
	node -e 'new Function(require("fs").readFileSync(process.argv[1], "utf8"))' "$VIEW"
fi

echo 'C2000-MAX ZRAM SWAP tests passed'
