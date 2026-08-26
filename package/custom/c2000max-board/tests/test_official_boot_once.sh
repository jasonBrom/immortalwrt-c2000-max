#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TOP="$(CDPATH= cd "$ROOT/../../.." && pwd)"
DTS="$TOP/target/linux/mediatek/dts/mt7987a-nradio-c2000-max.dts"
HELPER="$ROOT/files/usr/sbin/c2000max-boot-official-once"
RPC="$ROOT/files/usr/libexec/rpcd/c2000max"
ACL="$ROOT/files/usr/share/rpcd/acl.d/c2000max.json"
VIEW_PATCH="$TOP/scripts/c2000max/luci-system-official-boot.patch"
VIEW="$TOP/feeds/luci/modules/luci-mod-system/htdocs/luci-static/resources/view/system/reboot.js"
WORKFLOW="$TOP/.github/workflows/c2000max-one-shot-build.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }

sh -n "$HELPER" || fail 'official one-shot helper has invalid shell syntax'
python3 -m json.tool "$ACL" >/dev/null || fail 'C2000MAX ACL JSON is invalid'

sed -n '/partition@40000/,/};/p' "$DTS" | grep -Fq 'label = "u-boot-env"' &&
sed -n '/partition@40000/,/};/p' "$DTS" | grep -Fq 'reg = <0x040000 0x010000>' ||
	fail 'dedicated 64 KiB SPI-NOR U-Boot environment partition is missing'
grep -Fq "ENV_LABEL='u-boot-env'" "$HELPER" &&
grep -Fq 'fw_printenv -c "$ENV_CONFIG"' "$HELPER" &&
grep -Fq 'fw_setenv -c "$ENV_CONFIG" -s "$batch"' "$HELPER" ||
	fail 'helper does not use an isolated verified fw_env configuration'
if grep -Fq '/etc/fw_env.config' "$HELPER"; then
	fail 'helper can overwrite the SD-card SIM environment'
fi
grep -Fq 'setenv bootcmd ${c2000max_bootcmd_saved}' "$HELPER" &&
grep -Fq 'saveenv; mtkboardboot' "$HELPER" ||
	fail 'one-shot command does not restore TF-card boot before factory boot'

grep -Fq 'official_boot_status' "$RPC" && grep -Fq 'official_boot_once' "$RPC" ||
	fail 'official boot RPC methods are missing'
grep -Fq 'official_boot_once' "$ACL" || fail 'official boot RPC permission is missing'
grep -Fq 'handleOfficialOnce' "$VIEW_PATCH" ||
	fail 'durable LuCI reboot-page patch is missing the official boot button'
grep -Fq 'luci-system-official-boot.patch' "$WORKFLOW" ||
	fail 'build workflow does not apply the official boot LuCI patch'

if [ -f "$VIEW" ]; then
	grep -Fq 'handleOfficialOnce' "$VIEW" ||
		fail 'applied LuCI reboot page is missing the official boot button'
fi

if command -v node >/dev/null 2>&1 && [ -f "$VIEW" ]; then
	node --check "$VIEW" >/dev/null
fi

echo 'C2000MAX verified one-shot factory boot tests passed'
