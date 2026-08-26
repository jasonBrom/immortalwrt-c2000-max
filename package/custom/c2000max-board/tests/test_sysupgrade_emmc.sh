#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
PLATFORM="$ROOT/../../../target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail()
{
	echo "FAIL: $*" >&2
	exit 1
}

# The platform file only defines functions.  Provide the helpers normally
# sourced by OpenWrt's stage2 upgrade environment.
find_mmc_part() { return 1; }
identify_magic_long() { printf 'tar\n'; }
get_magic_long() { printf '00000000\n'; }
source "$PLATFORM"

mkdir -p "$TMPDIR/tree/sysupgrade-test"
dd if=/dev/urandom of="$TMPDIR/tree/sysupgrade-test/kernel" bs=1 count=70011 status=none
dd if=/dev/urandom of="$TMPDIR/tree/sysupgrade-test/root" bs=1 count=131089 status=none
tar -C "$TMPDIR/tree" -cf "$TMPDIR/image.bin" sysupgrade-test
truncate -s 4194304 "$TMPDIR/kernel.dev"
truncate -s 4194304 "$TMPDIR/root.dev"

c2000max_find_emmc_part()
{
	case "$1" in
		kernel) printf '%s\n' "$TMPDIR/kernel.dev" ;;
		rootfs) printf '%s\n' "$TMPDIR/root.dev" ;;
		*) return 1 ;;
	esac
}
c2000max_validate_emmc_part() { return 0; }
c2000max_emmc_sectors() { printf '8192\n'; }

UPGRADE_BACKUP=
c2000max_emmc_upgrade_tar "$TMPDIR/image.bin" || fail 'valid image was rejected'
cmp "$TMPDIR/tree/sysupgrade-test/kernel" \
	<(dd if="$TMPDIR/kernel.dev" bs=1 count=70011 status=none) ||
	fail 'kernel contents differ after write'
cmp "$TMPDIR/tree/sysupgrade-test/root" \
	<(dd if="$TMPDIR/root.dev" bs=1 count=131089 status=none) ||
	fail 'root contents differ after write'

root_blocks=$(((131089 + 511) / 512))
root_aligned=$(((root_blocks + 127) & ~127))
overlay_sum="$(dd if="$TMPDIR/root.dev" bs=512 skip="$root_aligned" count=2048 status=none |
	od -An -tu1 | awk '{ for (i = 1; i <= NF; i++) sum += $i } END { print sum + 0 }')"
[[ "$overlay_sum" == 0 ]] || fail 'sysupgrade -n did not invalidate the old overlay'
[[ "$EMMC_ROOTFS_BLOCKS" == "$root_aligned" ]] || fail 'aligned root block count was not exported'

c2000max_find_emmc_part() { return 1; }
if c2000max_emmc_upgrade_tar "$TMPDIR/image.bin" >/dev/null 2>&1; then
	fail 'missing GPT targets were silently accepted'
fi

grep -Fq "c2000max_emmc_do_upgrade \"\$1\" ||" "$PLATFORM" ||
	fail 'C2000MAX upgrade failures do not stop stage2'
grep -Fq "sha256sum" "$PLATFORM" || fail 'readback hashing is not present in upgrade ramfs'

echo 'C2000-MAX verified eMMC sysupgrade tests passed'
