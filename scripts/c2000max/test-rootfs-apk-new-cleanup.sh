#!/bin/sh
set -eu

TOPDIR="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
ROOTFS_MK="$TOPDIR/include/rootfs.mk"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

mkdir -p "$TEST_ROOT/etc/init.d" "$TEST_ROOT/etc/rc.d"
: > "$TEST_ROOT/etc/init.d/existing.apk-new"
: > "$TEST_ROOT/etc/init.d/canonical"
ln -s ../init.d/existing.apk-new "$TEST_ROOT/etc/rc.d/S99existing.apk-new"
ln -s ../init.d/missing.apk-new "$TEST_ROOT/etc/rc.d/K10missing.apk-new"
ln -s ../init.d/canonical "$TEST_ROOT/etc/rc.d/S99canonical"
ln -s ../init.d/existing.apk-new "$TEST_ROOT/etc/rc.d/not-an-rc-link"

find "$TEST_ROOT/etc/rc.d" -maxdepth 1 -type l \
	-name '[SK][0-9][0-9]*.apk-new' \
	-lname '../init.d/*.apk-new' -delete

[ ! -e "$TEST_ROOT/etc/rc.d/S99existing.apk-new" ] || {
	echo 'FAIL: existing .apk-new target link survived cleanup' >&2
	exit 1
}
[ ! -L "$TEST_ROOT/etc/rc.d/K10missing.apk-new" ] || {
	echo 'FAIL: missing .apk-new target link survived cleanup' >&2
	exit 1
}
[ -L "$TEST_ROOT/etc/rc.d/S99canonical" ] || {
	echo 'FAIL: canonical rc link was removed' >&2
	exit 1
}
[ -L "$TEST_ROOT/etc/rc.d/not-an-rc-link" ] || {
	echo 'FAIL: non-rc .apk-new link was removed' >&2
	exit 1
}

grep -Fq -- "-lname '../init.d/*.apk-new' -delete" "$ROOTFS_MK" || {
	echo 'FAIL: rootfs cleanup command is missing' >&2
	exit 1
}
if grep -Fq -- '-xtype l' "$ROOTFS_MK"; then
	echo 'FAIL: rootfs cleanup still depends on target existence' >&2
	exit 1
fi

echo 'rootfs .apk-new rc-link cleanup tests passed'
