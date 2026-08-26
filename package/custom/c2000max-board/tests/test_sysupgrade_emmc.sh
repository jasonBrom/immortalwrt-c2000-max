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
identify_magic_long() { printf 'tar\n'; }
get_magic_long() { printf '00000000\n'; }
source "$PLATFORM"

# Model two SD cards with identical GPT labels.  /rom is mounted from card 7;
# card 8 is a decoy which must never be selected by a global MMC scan.
C2000MAX_SYS_CLASS_BLOCK="$TMPDIR/sys/class/block"
mkdir -p \
	"$C2000MAX_SYS_CLASS_BLOCK/mmcblk7/device" \
	"$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p5" \
	"$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p6" \
	"$C2000MAX_SYS_CLASS_BLOCK/mmcblk8/device" \
	"$C2000MAX_SYS_CLASS_BLOCK/mmcblk8p5" \
	"$C2000MAX_SYS_CLASS_BLOCK/mmcblk8p6"
printf 'SD\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7/device/type"
printf '0123456789abcdef0123456789abcdef\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7/device/cid"
printf '179:0\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7/dev"
printf 'PARTNAME=kernel\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p5/uevent"
printf '179:5\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p5/dev"
printf '8192\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p5/size"
printf 'PARTNAME=rootfs\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p6/uevent"
printf '179:6\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p6/dev"
printf '8192\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7p6/size"
printf 'SD\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk8/device/type"
printf 'fedcba9876543210fedcba9876543210\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk8/device/cid"
printf '180:0\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk8/dev"
printf 'PARTNAME=kernel\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk8p5/uevent"
printf '180:5\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk8p5/dev"
printf 'PARTNAME=rootfs\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk8p6/uevent"
printf '180:6\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk8p6/dev"

c2000max_is_block_device() { return 0; }
c2000max_block_info()
{
	printf '/dev/mmcblk8p6: TYPE="squashfs"\n'
	printf '/dev/mmcblk7p6: TYPE="squashfs" MOUNT="/rom"\n'
}

c2000max_prepare_tf_targets || fail 'active TF target preparation failed'
[[ "$C2000MAX_TF_DISK" == /dev/mmcblk7 ]] || fail 'the active TF disk was not pinned'
[[ "$C2000MAX_TF_KERNEL" == /dev/mmcblk7p5 ]] || fail 'kernel escaped to another MMC disk'
[[ "$C2000MAX_TF_ROOTFS" == /dev/mmcblk7p6 ]] || fail 'rootfs escaped to another MMC disk'
c2000max_validate_tf_targets || fail 'an unchanged TF identity was rejected'

printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7/device/cid"
if c2000max_validate_tf_targets; then
	fail 'a changed TF CID was accepted'
fi
printf '0123456789abcdef0123456789abcdef\n' > "$C2000MAX_SYS_CLASS_BLOCK/mmcblk7/device/cid"

c2000max_block_info()
{
	printf '/dev/mmcblk7p6: TYPE="squashfs" MOUNT="/rom"\n'
	printf '/dev/mmcblk8p6: TYPE="squashfs" MOUNT="/rom"\n'
}
if c2000max_prepare_tf_targets >/dev/null 2>&1; then
	fail 'ambiguous /rom TF devices were accepted'
fi

mkdir -p "$TMPDIR/tree/sysupgrade-test"
dd if=/dev/urandom of="$TMPDIR/tree/sysupgrade-test/kernel" bs=1 count=70011 status=none
dd if=/dev/urandom of="$TMPDIR/tree/sysupgrade-test/root" bs=1 count=131089 status=none
tar -C "$TMPDIR/tree" -cf "$TMPDIR/image.bin" sysupgrade-test
truncate -s 4194304 "$TMPDIR/kernel.dev"
truncate -s 4194304 "$TMPDIR/root.dev"

C2000MAX_TF_KERNEL="$TMPDIR/kernel.dev"
C2000MAX_TF_ROOTFS="$TMPDIR/root.dev"
c2000max_validate_tf_targets() { return 0; }
c2000max_tf_sectors() { printf '8192\n'; }

UPGRADE_BACKUP=
C2000MAX_TF_UPGRADE_OK=
c2000max_tf_upgrade_tar "$TMPDIR/image.bin" || fail 'valid image was rejected'
[[ "$C2000MAX_TF_UPGRADE_OK" == 1 ]] || fail 'successful write did not set its completion guard'
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

c2000max_validate_tf_targets() { return 1; }
if c2000max_tf_upgrade_tar "$TMPDIR/image.bin" >/dev/null 2>&1; then
	fail 'an unbound TF target was silently accepted'
fi

grep -Fq 'c2000max_tf_do_upgrade "$1" ||' "$PLATFORM" ||
	fail 'C2000MAX upgrade failures do not stop stage2'
grep -Fq 'c2000max_prepare_tf_targets ||' "$PLATFORM" ||
	fail 'the live TF is not pinned before entering ramfs'
grep -Fq 'C2000MAX_TF_UPGRADE_OK=1' "$PLATFORM" ||
	fail 'the successful-write completion guard is missing'
grep -Fq "RAMFS_COPY_BIN='fitblk fit_check_sign sha256sum'" "$PLATFORM" ||
	fail 'readback hashing is not present in upgrade ramfs'

c2000max_code="$(sed -n '/^# C2000MAX boots this image/,/^xiaomi_initial_setup()/p' "$PLATFORM")"
! grep -Eq 'find_mmc_part|/dev/mtd|mtd(write| erase)' <<<"$c2000max_code" ||
	fail 'C2000MAX TF upgrade code can reach an unbound MMC or MTD target'

echo 'C2000-MAX TF-only verified sysupgrade tests passed'
