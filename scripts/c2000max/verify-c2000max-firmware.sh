#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CONFIG="$ROOT/configs/c2000max.config"
DEVICE_MK="$ROOT/target/linux/mediatek/image/filogic.mk"
BOARD="$ROOT/package/custom/c2000max-board"
BOARD_DTS="$ROOT/target/linux/mediatek/dts/mt7987a-nradio-c2000-max.dts"
TRAFFIC="$ROOT/package/mtk/applications/luci-app-c2000max-traffic"
APPFILTER="$ROOT/package/mtk/applications/c2000max-appfilter"
OAF_SRC="$APPFILTER/src/oaf"
OAFD_SRC="$APPFILTER/src/oafd"
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

require_rootfs_path() {
	path="$1"
	[ -e "$ROOTFS/$path" ] || [ -L "$ROOTFS/$path" ] ||
		fail "rootfs omits /$path"
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
require_contains "$BOARD_DTS" 'cpufreq.default_governor=schedutil' \
	"board still forces the thermal-unfriendly performance CPU governor"
require_contains "$BOARD_DTS" 'ramoops@5ff80000' \
	"board does not reserve persistent kernel crash-log memory"
require_contains "$BOARD_DTS" 'no-map;' \
	"board persistent crash-log memory is not excluded from ordinary DDR"
require_contains "$BOARD/files/etc/config/c2000max" "option enabled '1'" \
	"board does not enable its smart fan by default"
require_contains "$BOARD/files/etc/init.d/c2000max-fan" 'START=18' \
	"board fan does not cover boot-time thermal load"
require_contains "$ROOT/package/mtk/applications/c2000max-appfilter/Makefile" \
	'CONFIG_NETFILTER_XT_TARGET_CONNSECMARK=n' \
	"OAF leaves the kernel CONNSECMARK prompt unanswered"
require_contains "$ROOT/package/mtk/applications/c2000max-appfilter/Makefile" \
	'CONFIG_NETFILTER_XT_TARGET_SECMARK=n' \
	"OAF leaves the kernel SECMARK prompt unanswered"
require_contains "$ROOT/package/mtk/applications/c2000max-appfilter/Makefile" \
	'+kmod-nf-reject' "OAF kernel package omits its nf_reject_ipv4 dependency"

for dependency in \
	'+coreutils-od' '+coreutils-sort' '+coreutils-stat' '+ucode' '+ucode-mod-fs'
do
	require_contains "$TRAFFIC/Makefile" "$dependency" \
		"traffic package omits runtime dependency: $dependency"
done

# The native importer emits the extended, one-feature-per-line OAF v4 grammar.
# Keep the userspace validator, loader acknowledgement and kernel matcher in
# lockstep so a large profile cannot be reported active after a partial load.
require_contains "$TRAFFIC/root/usr/libexec/c2000max-ik-compile.uc" \
	"feature_fp.write('#format v4.2" "IK compiler does not emit OAF v4.2"
require_contains "$TRAFFIC/root/usr/sbin/c2000max-feature-manager" \
	'#format v4.2' "feature manager does not accept OAF v4.2"
require_contains "$TRAFFIC/root/usr/sbin/c2000max-feature-manager" \
	'valid_http_multi' "feature manager does not validate compound HTTP rules"
require_contains "$TRAFFIC/root/usr/sbin/c2000max-feature-manager" \
	'feature_generation' "feature manager does not acknowledge OAF generations"
require_contains "$TRAFFIC/root/usr/sbin/c2000max-feature-job" \
	'run_worker' "traffic package omits asynchronous feature installation"
require_contains "$TRAFFIC/root/usr/libexec/rpcd/c2000max.traffic" \
	'feature_install_status' "traffic RPC omits asynchronous feature status"
require_contains "$TRAFFIC/htdocs/luci-static/resources/view/c2000max/traffic.js" \
	'resolveWithin' "traffic view does not bound first-paint RPC latency"
require_contains "$OAF_SRC/Makefile" 'ik_regex.o' \
	"OAF kernel module omits the bounded native regex matcher"
require_contains "$OAF_SRC/app_filter.h" '#define MAX_FEATURE_NUM_TOTAL 32768' \
	"OAF kernel feature limit is not 32768"
require_contains "$OAF_SRC/app_filter.h" 'ikv4' \
	"OAF kernel version does not identify the v4 matcher"
require_contains "$OAF_SRC/app_filter.c" 'af_begin_feature_reload' \
	"OAF kernel module lacks transactional reload begin"
require_contains "$OAF_SRC/app_filter.c" 'af_commit_feature_reload' \
	"OAF kernel module lacks transactional reload commit"
require_contains "$OAF_SRC/af_log.c" 'feature_generation' \
	"OAF kernel module does not publish feature generations"
require_contains "$OAFD_SRC/main.c" '/proc/sys/oaf/feature_generation' \
	"OAF userspace loader does not verify the committed generation"

if [ -n "$MANIFEST" ]; then
	[ -f "$MANIFEST" ] || fail "manifest not found: $MANIFEST"
	for package in \
		c2000max-board luci-app-c2000max-traffic c2000max-appfilter \
		kmod-c2000max-oaf mt5700-web-go luci-app-mt5700-web qmodem \
		luci-app-qmodem-next uboot-envtools luci-app-eqos-mtk \
		luci-app-turboacc-mtk c2000max-app luci-app-c2000max-app \
		coreutils-od coreutils-sort coreutils-stat ucode ucode-mod-fs
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
		etc/config/c2000max_traffic \
		usr/sbin/c2000max-traffic \
		usr/sbin/c2000max-feature-install \
		usr/sbin/c2000max-feature-manager \
		usr/sbin/c2000max-feature-job \
		usr/libexec/c2000max-ik-compile.uc \
		usr/libexec/rpcd/c2000max.traffic \
		usr/share/rpcd/acl.d/luci-app-c2000max-traffic.json \
		lib/upgrade/keep.d/c2000max-traffic \
		www/luci-static/resources/view/c2000max/traffic.js \
		www/luci-static/resources/c2000max/traffic-chart.js \
		etc/init.d/c2000max-appfilter \
		usr/bin/c2000max-oafd \
		etc/appfilter/feature.cfg \
		usr/bin/od \
		usr/bin/sort \
		bin/stat \
		usr/libexec/od-coreutils \
		usr/libexec/sort-coreutils \
		usr/libexec/stat-coreutils \
		usr/bin/ucode \
		usr/lib/ucode/fs.so \
		etc/init.d/mt5700-web \
		www/luci-static/resources/view/mt5700-web/status_v8.js
	do
		require_rootfs_path "$path"
	done

	oaf_module="$(find "$ROOTFS/lib/modules" -type f -name oaf.ko -print -quit 2>/dev/null)"
	[ -n "$oaf_module" ] || fail "rootfs omits the OAF kernel module"
	grep -aFq 'feature_generation' "$oaf_module" ||
		fail "rootfs OAF module omits generation acknowledgement"
	grep -aFq 'ikv4' "$oaf_module" ||
		fail "rootfs OAF module is not the native v4 matcher build"
	grep -aFq '/proc/sys/oaf/feature_generation' "$ROOTFS/usr/bin/c2000max-oafd" ||
		fail "rootfs OAF loader does not verify committed generations"

	require_fixed "$ROOTFS/etc/appfilter/feature.cfg" '#format v3.0' \
		"default rootfs feature library is not the built-in OAF v3 profile"
	require_contains "$ROOTFS/usr/libexec/c2000max-ik-compile.uc" \
		"feature_fp.write('#format v4.2" "rootfs IK compiler does not emit OAF v4.2"
	require_contains "$ROOTFS/usr/sbin/c2000max-feature-manager" \
		'valid_http_multi' "rootfs feature manager omits compound HTTP validation"
	require_contains "$ROOTFS/usr/sbin/c2000max-feature-manager" \
		'feature_generation' "rootfs feature manager omits generation acknowledgement"
	require_contains "$ROOTFS/usr/libexec/rpcd/c2000max.traffic" \
		'recent_audit' "rootfs traffic RPC omits recent application audit"
	require_contains "$ROOTFS/usr/libexec/rpcd/c2000max.traffic" \
		'feature_install_status' "rootfs traffic RPC omits asynchronous feature status"
	require_contains "$ROOTFS/usr/sbin/c2000max-feature-job" \
		'run_worker' "rootfs omits asynchronous feature installation"
	require_contains "$ROOTFS/etc/config/c2000max" "option enabled '1'" \
		"rootfs does not enable the C2000MAX smart fan by default"
	require_contains "$ROOTFS/etc/init.d/c2000max-fan" 'START=18' \
		"rootfs fan does not cover boot-time thermal load"
	require_contains "$ROOTFS/www/luci-static/resources/view/c2000max/traffic.js" \
		'resolveWithin' "rootfs traffic view does not bound first-paint RPC latency"
	require_contains "$ROOTFS/usr/share/rpcd/acl.d/luci-app-c2000max-traffic.json" \
		'recent_audit' "rootfs traffic ACL omits recent application audit"
	require_contains "$ROOTFS/lib/upgrade/keep.d/c2000max-traffic" \
		'/etc/c2000max-traffic/features/' "sysupgrade does not retain uploaded feature profiles"

	# Import support belongs in the image, but third-party rule data does not.
	# Check names rather than file contents because the importer intentionally
	# documents the upstream asset names that it accepts from an administrator.
	bundled_ik_assets="$(find "$ROOTFS" -mindepth 1 -print | awk '
	{
		name = tolower($0)
		n = split(name, part, "/")
		base = part[n]
		if (base ~ /^ikprotocol([._-]|$)/ ||
		    base ~ /^app5([._-]|$)/ ||
		    base ~ /decode[_-]?raw/ ||
		    base ~ /^appid[-_]?map([._-]|$)/ ||
		    base ~ /^conversion[-_]?report([._-]|$)/ ||
		    base ~ /[.]jsonl$/)
			print $0
	}')"
	if [ -n "$bundled_ik_assets" ]; then
		printf '%s\n' "$bundled_ik_assets" >&2
		fail "rootfs bundles external IKprotocol rule-library assets"
	fi
	if [ -d "$ROOTFS/etc/c2000max-traffic/features" ] &&
	   find "$ROOTFS/etc/c2000max-traffic/features" -mindepth 1 -print -quit |
		grep -q .; then
		fail "rootfs bundles an uploaded feature profile"
	fi
fi

echo "C2000MAX firmware verification passed"
