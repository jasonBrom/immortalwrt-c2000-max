#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/files/usr/sbin/c2000max-daed-hybrid"
HNAT_INIT="$ROOT/files/etc/init.d/c2000max-hnat"
DAED_PATCH="$ROOT/../../../scripts/c2000max/packages-daed-generated-assets.patch"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

mkdir -p "$TMPDIR/net/br-lan" "$TMPDIR/net/dae0" "$TMPDIR/bin"
touch "$TMPDIR/hook_toggle"
cat > "$TMPDIR/bin/hnat" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${C2000MAX_DAED_HYBRID:-0}" "$1" >> "$HYBRID_TEST_LOG"
[ "$1" != reload ] || printf 'mediatek_hnat\n' > "$HYBRID_TEST_EFFECTIVE"
EOF
cat > "$TMPDIR/bin/pidof" <<'EOF'
#!/bin/sh
[ "$1" = daed ]
EOF
cat > "$TMPDIR/bin/tc" <<'EOF'
#!/bin/sh
[ "$1" = filter ] || exit 0
printf 'filter protocol all pref 49152 bpf chain 0 handle 0x1 daed direct-action\n'
EOF
chmod +x "$TMPDIR/bin/hnat" "$TMPDIR/bin/pidof" "$TMPDIR/bin/tc"

export HYBRID_TEST_LOG="$TMPDIR/calls"
export HYBRID_TEST_EFFECTIVE="$TMPDIR/effective"
export C2000MAX_DAED_HNAT_INIT="$TMPDIR/bin/hnat"
export C2000MAX_DAED_HNAT_HOOK="$TMPDIR/hook_toggle"
export C2000MAX_DAED_HYBRID_STATE="$TMPDIR/state"
export C2000MAX_HNAT_EFFECTIVE="$TMPDIR/effective"
export C2000MAX_DAED_SYS_CLASS_NET="$TMPDIR/net"
export C2000MAX_DAED_TC="$TMPDIR/bin/tc"
export C2000MAX_DAED_PIDOF="$TMPDIR/bin/pidof"
export C2000MAX_DAED_WATCH_LOOPS=5
export C2000MAX_DAED_WATCH_INTERVAL=0

"$HELPER" prepare
grep -qx '0 quiesce' "$TMPDIR/calls" || fail 'prepare did not use the HNAT flush barrier'
grep -qx preparing "$TMPDIR/state" || fail 'prepare state was not published'

"$HELPER" watch
grep -qx '1 reload' "$TMPDIR/calls" || fail 'HNAT was not restored after stable BPF readiness'
grep -q '^active bpf_filters=' "$TMPDIR/state" || fail 'hybrid active state was not published'

"$HELPER" restore
[[ ! -e "$TMPDIR/state" ]] || fail 'restore left a stale hybrid marker'
[[ "$(grep -c ' reload$' "$TMPDIR/calls")" -eq 2 ]] || fail 'restore did not reconcile acceleration'

calls_before="$(wc -l < "$TMPDIR/calls")"
rm -f "$TMPDIR/hook_toggle"
"$HELPER" prepare
grep -qx unavailable "$TMPDIR/state" || fail 'missing HNAT was not treated as a valid daed-only mode'
[[ "$(wc -l < "$TMPDIR/calls")" -eq "$calls_before" ]] || fail 'unavailable HNAT was called unexpectedly'

grep -Fq 'EXTRA_COMMANDS="quiesce"' "$HNAT_INIT" || fail 'HNAT quiesce command is missing'
grep -Fq 'disable_hnat_hook' "$HNAT_INIT" || fail 'HNAT quiesce does not flush PPE entries'
grep -Fq 'C2000MAX_DAED_HYBRID' "$HNAT_INIT" || fail 'EQoS is not protected during BPF handoff'
grep -Fq 'c2000max-daed-hybrid run "$PROG" run' "$DAED_PATCH" ||
	fail 'daed is not launched through the hybrid barrier'
grep -Fq 'c2000max-daed-hybrid restore' "$DAED_PATCH" ||
	fail 'daed shutdown does not restore acceleration'
grep -Fq 'wait_daed_stopped || return 1' "$DAED_PATCH" ||
	fail 'daed reload does not wait for the previous process'
grep -Fq 'mkdir -p /etc/daed /var/log/daed || return 1' "$DAED_PATCH" ||
	fail 'daed database and log directories are not created before launch'
grep -Fq 'touch "$LOG" || return 1' "$DAED_PATCH" ||
	fail 'daed log file is not created before launch'
grep -Fq 'readlink -f "$proc/exe"' "$DAED_PATCH" ||
	fail 'daed process detection does not verify the executable path'
if grep -Fq 'sleep 0.1' "$DAED_PATCH"; then
	fail 'daed init uses a fractional sleep unsupported by this BusyBox build'
fi
if grep -Eq '^\+[[:space:]]*rm -f "\$LOG"' "$DAED_PATCH"; then
	fail 'daed shutdown still deletes the only diagnostic log'
fi

echo 'C2000-MAX daed/HNAT hybrid tests passed'
