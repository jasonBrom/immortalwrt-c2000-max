#!/bin/bash

set -euo pipefail

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
TOP="$(CDPATH= cd "$ROOT/../../.." && pwd)"
KERNEL="$TOP/target/linux/mediatek/patches-6.12"
HNAT="$TOP/target/linux/mediatek/files-6.12/drivers/net/ethernet/mediatek/mtk_hnat/hnat_nf_hook.c"
FW4="$TOP/package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch"
DEFAULTS="$ROOT/files/etc/uci-defaults/99-c2000max-defaults"
TURBO="$TOP/package/mtk/applications/luci-app-turboacc-mtk/root/usr/share/rpcd/ucode/luci.turboacc"

fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'NF_NAT_RANGE_FULLCONE' "$KERNEL/984-add-sonic-fullcone-support.patch" ||
	fail 'SONiC conntrack/NAT core patch is missing'
grep -Fq 'nft_fullcone' "$KERNEL/986-add-sonic-fullcone-to-nft.patch" ||
	fail 'nftables FullCone expression patch is missing'
grep -Fq 'nat_fullcone' "$KERNEL/985-c2000max-mark-sonic-fullcone-conntracks.patch" &&
grep -Fq 'READ_ONCE(ct->nat_fullcone)' "$HNAT" ||
	fail 'FullCone conntracks are not excluded from MediaTek HNAT per flow'
grep -Fq 'fullcone_proto' "$FW4" ||
	fail 'firewall4 lacks per-protocol SONiC FullCone rules'

grep -Fq "firewall.@defaults[0].fullcone='1'" "$DEFAULTS" &&
grep -Fq 'fullcone_proto=udp' "$DEFAULTS" ||
	fail 'factory firewall does not restrict FullCone to WAN UDP'
grep -Fq "SONiC FullCone (UDP)" "$TURBO" ||
	fail 'network acceleration status does not report native SONiC FullCone'

if grep -Eq 'kmod-nft-fullcone' "$TOP/configs/c2000max.config" \
	"$TOP/defconfig/low-mem-512m/c2000max-mt7993-be3600-wifi.config" \
	"$TOP/target/linux/mediatek/image/filogic.mk" \
	"$TOP/package/network/config/firewall4/Makefile"; then
	fail 'legacy nft_fullcone module is still selected'
fi

echo 'C2000MAX SONiC FullCone/HNAT compatibility tests passed'
