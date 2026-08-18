#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CONFIG="$ROOT/configs/c2000max.config"
DEVICE_MK="$ROOT/target/linux/mediatek/image/filogic.mk"
BOARD="$ROOT/package/custom/c2000max-board"
MANIFEST="${1:-}"
ROOTFS="${2:-}"

fail() {
	echo "C2000MAX firmware verification failed: $*" >&2
	exit 1
}

require_fixed() {
	file="$1"
	needle="$2"
	label="$3"
	grep -Fqx "$needle" "$file" || fail "$label"
}

require_contains() {
	file="$1"
	needle="$2"
	label="$3"
	grep -Fq "$needle" "$file" || fail "$label"
}

require_fixed "$CONFIG" 'CONFIG_TARGET_PREINIT_IP="192.168.66.1"' \
	"preinit LAN address is not 192.168.66.1"
require_fixed "$CONFIG" 'CONFIG_TARGET_PREINIT_BROADCAST="192.168.66.255"' \
	"preinit LAN broadcast is not 192.168.66.255"
require_fixed "$CONFIG" 'CONFIG_TARGET_DEFAULT_LAN_IP_FROM_PREINIT=y' \
	"base-files will not inherit the C2000MAX preinit LAN address"
require_fixed "$CONFIG" 'CONFIG_PREINITOPT=y' \
	"Kconfig will discard the custom C2000MAX preinit LAN address"

for symbol in \
	CONFIG_PACKAGE_c2000max-board=y \
	CONFIG_PACKAGE_luci-app-c2000max-traffic=y \
	CONFIG_PACKAGE_c2000max-appfilter=y \
	CONFIG_PACKAGE_kmod-c2000max-oaf=y \
	CONFIG_PACKAGE_mt5700-web-go=y \
	CONFIG_PACKAGE_luci-app-mt5700-web=y \
	CONFIG_PACKAGE_qmodem=y \
	CONFIG_PACKAGE_luci-app-qmodem-next=y \
	CONFIG_PACKAGE_uboot-envtools=y \
	CONFIG_PACKAGE_xz-utils=y
do
	require_fixed "$CONFIG" "$symbol" "missing saved-config selection: $symbol"
done

if [ -f "$ROOT/.config" ]; then
	require_fixed "$ROOT/.config" 'CONFIG_TARGET_PREINIT_IP="192.168.66.1"' \
		"generated config reset preinit LAN away from 192.168.66.1"
	require_fixed "$ROOT/.config" 'CONFIG_TARGET_PREINIT_BROADCAST="192.168.66.255"' \
		"generated config reset the C2000MAX preinit broadcast"
	require_fixed "$ROOT/.config" 'CONFIG_TARGET_DEFAULT_LAN_IP_FROM_PREINIT=y' \
		"generated config will not set the base LAN address from preinit"
	require_fixed "$ROOT/.config" 'CONFIG_PREINITOPT=y' \
		"generated config disabled custom preinit options"
	for package in \
		c2000max-board luci-app-c2000max-traffic c2000max-appfilter \
		kmod-c2000max-oaf mt5700-web-go luci-app-mt5700-web \
		luci-app-qmodem-next uboot-envtools xz-utils
	do
		grep -Fqx "CONFIG_PACKAGE_${package}=y" "$ROOT/.config" ||
			fail "generated config omits $package"
	done
fi

device_block="$(sed -n '/^define Device\/nradio_c2000-max$/,/^endef$/p' "$DEVICE_MK")"
for package in \
	c2000max-board uboot-envtools xz-utils mt5700-web-go luci-app-mt5700-web \
	luci-app-qmodem-next luci-app-c2000max-traffic c2000max-appfilter \
	kmod-c2000max-oaf luci-app-eqos-mtk c2000max-app luci-app-c2000max-app
do
	printf '%s\n' "$device_block" | grep -Eq "(^|[[:space:]])${package}([[:space:]\\]|$)" ||
		fail "device package list omits $package"
done

require_contains "$BOARD/files/etc/uci-defaults/99-c2000max-defaults" \
	"network.lan.ipaddr='192.168.66.1'" "board defaults do not set LAN to 192.168.66.1"
require_contains "$BOARD/Makefile" '+uboot-envtools' \
	"board package does not require U-Boot environment tools"
require_contains "$ROOT/target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh" \
	'/usr/sbin/c2000max-sim persist' "sysupgrade does not persist the SIM slot"
require_contains "$ROOT/package/custom/qmodem/application/qmodem/files/etc/init.d/qmodem_reboot" \
	'nradio,c2000-max' "QModem shutdown does not protect C2000MAX modem power sequencing"
require_contains "$BOARD/files/etc/init.d/c2000max-sim" \
	'/usr/sbin/c2000max-sim boot-prepare' "early MT5700 power/mux restore is missing"
require_contains "$ROOT/package/mtk/applications/c2000max-appfilter/Makefile" \
	'CONFIG_NETFILTER_XT_TARGET_CONNSECMARK=n' \
	"OAF leaves the kernel CONNSECMARK prompt unanswered"
require_contains "$ROOT/package/mtk/applications/c2000max-appfilter/Makefile" \
	'CONFIG_NETFILTER_XT_TARGET_SECMARK=n' \
	"OAF leaves the kernel SECMARK prompt unanswered"
require_contains "$ROOT/package/mtk/applications/c2000max-appfilter/Makefile" \
	'+kmod-nf-reject' "OAF kernel package omits its nf_reject_ipv4 dependency"

if [ -n "$MANIFEST" ]; then
	[ -f "$MANIFEST" ] || fail "manifest not found: $MANIFEST"
	for package in \
		c2000max-board luci-app-c2000max-traffic c2000max-appfilter \
		kmod-c2000max-oaf mt5700-web-go luci-app-mt5700-web qmodem \
		luci-app-qmodem-next uboot-envtools luci-app-eqos-mtk \
		luci-app-turboacc-mtk c2000max-app luci-app-c2000max-app
	do
		grep -Eq "^${package} - " "$MANIFEST" || fail "firmware manifest omits $package"
	done
fi

if [ -n "$ROOTFS" ]; then
	[ -d "$ROOTFS" ] || fail "rootfs staging directory not found: $ROOTFS"
	for path in \
		etc/uci-defaults/99-c2000max-defaults \
		etc/init.d/c2000max-sim \
		usr/sbin/c2000max-sim \
		usr/share/luci/menu.d/c2000max.json \
		www/luci-static/resources/view/c2000max/sim_v8.js \
		etc/init.d/c2000max-traffic \
		www/luci-static/resources/view/c2000max/traffic.js \
		etc/init.d/c2000max-appfilter \
		usr/bin/c2000max-oafd \
		etc/init.d/mt5700-web \
		www/luci-static/resources/view/mt5700-web/status_v8.js
	do
		[ -e "$ROOTFS/$path" ] || fail "rootfs omits /$path"
	done
	find "$ROOTFS/lib/modules" -type f -name oaf.ko -print -quit 2>/dev/null |
		grep -q . || fail "rootfs omits the OAF kernel module"
fi

echo "C2000MAX firmware verification passed"
