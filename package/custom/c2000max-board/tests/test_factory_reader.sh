#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
READER="$ROOT/files/usr/sbin/c2000max-factory"
FIXTURES="${C2000_FACTORY_TEST_FIXTURES:-/workspace/scratch/b87f2a9b152c/upload}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

GOOD="$FIXTURES/C2000MAX-v35.35-eeprom-1e00.bin"
OEM="$FIXTURES/C2000MAX-original-Factory.bin"
[ -r "$GOOD" ] && [ -r "$OEM" ] || {
	echo "SKIP: uploaded C2000-MAX EEPROM fixtures are unavailable"
	exit 0
}

# Build a full-size calibrated fixture without altering the uploaded data.
dd if=/dev/zero of="$WORK/good-full.bin" bs=2048 count=661 2>/dev/null
dd if="$GOOD" of="$WORK/good-full.bin" bs=7680 count=1 conv=notrunc 2>/dev/null

C2000_FACTORY_CANDIDATES="mtd:$OEM block:$WORK/good-full.bin" \
C2000_FACTORY_STATUS_FILE="$WORK/status" \
	sh "$READER" prepare-eeprom "$WORK/e2p" 1353728 "$GOOD"

cmp "$WORK/good-full.bin" "$WORK/e2p"
grep -qx 'source_kind=block' "$WORK/status"
grep -qx 'quality=calibrated' "$WORK/status"

# The OEM raw Factory header has a multicast band-0 value and must never be
# accepted as a standard MT7993 EEPROM merely because its label matches.
if C2000_FACTORY_CANDIDATES="mtd:$OEM" \
	C2000_FACTORY_STATUS_FILE="$WORK/fallback.status" \
	sh "$READER" prepare-eeprom "$WORK/fallback" 1353728 "$GOOD"; then
	grep -qx 'source_kind=template' "$WORK/fallback.status"
	grep -qx 'quality=reference-only' "$WORK/fallback.status"
else
	echo "FAIL: validated reference fallback was not created" >&2
	exit 1
fi

echo "PASS: content-validated Factory discovery rejects OEM raw EEPROM layout"
