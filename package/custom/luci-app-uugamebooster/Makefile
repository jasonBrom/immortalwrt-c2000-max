# Copyright (C) 2021 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for UUgamebooster
LUCI_DEPENDS:=+luci-compat +curl +ca-bundle +firewall4 +flock +kmod-tun +ip-full \
	+kmod-nf-conntrack-netlink +nftables-json +kmod-nft-core \
	+kmod-nft-nat +kmod-nft-compat +iptables-nft +ip6tables-nft \
	+ipset +kmod-ipt-core +kmod-ipt-ipset +kmod-ipt-nat \
	+kmod-ipt-nat-extra +kmod-nft-tproxy \
	+kmod-nft-socket +iptables-mod-tproxy +iptables-mod-socket
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-uugamebooster
PKG_VERSION:=1.0
PKG_RELEASE:=18

define Package/luci-app-uugamebooster/postinst
#!/bin/sh
ROOT="$${IPKG_INSTROOT:-}"
MIGRATOR="$$ROOT/usr/libexec/uuplugin-migrate-apk-new"
if [ -n "$$ROOT" ]; then
	[ ! -x "$$MIGRATOR" ] || "$$MIGRATOR" "$$ROOT" || exit 1
	exit 0
fi
"$$MIGRATOR" / || exit 1
if command -v ubus >/dev/null 2>&1; then
	GHOST="$$(ubus call service list '{"name":"uuplugin.apk-new"}' 2>/dev/null)" || exit 1
	if printf '%s\n' "$$GHOST" | grep -Fq '"uuplugin.apk-new"'; then
		ubus call service delete '{"name":"uuplugin.apk-new"}' >/dev/null || exit 1
	fi
fi
# default_postinst starts packaged init scripts before this package hook runs.
# Stop that canonical instance first so its non-blocking lifecycle lock cannot
# race the mandatory stale-rule cleanup below.
/etc/init.d/uuplugin stop >/dev/null 2>&1 || exit 1
/usr/libexec/uuplugin-launcher --cleanup-only || exit 1
/etc/init.d/uuplugin enable >/dev/null 2>&1 || exit 1
/etc/init.d/uuplugin restart >/dev/null 2>&1 || exit 1
exit 0
endef

define Package/luci-app-uugamebooster/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT:-}" ] || exit 0
MARKER=/tmp/uuplugin.clean-deinstall
rm -f "$$MARKER"
/etc/init.d/uuplugin stop >/dev/null 2>&1 || exit 1
/usr/libexec/uuplugin-launcher --cleanup-only || exit 1
if command -v ubus >/dev/null 2>&1; then
	GHOST="$$(ubus call service list '{"name":"uuplugin.apk-new"}' 2>/dev/null)" || exit 1
	if printf '%s\n' "$$GHOST" | grep -Fq '"uuplugin.apk-new"'; then
		ubus call service delete '{"name":"uuplugin.apk-new"}' >/dev/null || exit 1
	fi
fi
printf 'cleanup-complete\n' > "$$MARKER.new" || exit 1
mv -f "$$MARKER.new" "$$MARKER" || exit 1
exit 0
endef

define Package/luci-app-uugamebooster/postrm
#!/bin/sh
[ -z "$${IPKG_INSTROOT:-}" ] || exit 0
MARKER=/tmp/uuplugin.clean-deinstall
[ "$$(cat "$$MARKER" 2>/dev/null)" = cleanup-complete ] || exit 1
# During an APK upgrade the replacement package already owns this path. Do not
# disable the user's saved selection in that case; its postinst restarts the
# canonical namespace after deleting uuplugin.apk-new.
if [ -x /usr/libexec/uuplugin-launcher ] ||
   [ "$${PKG_UPGRADE:-$${IPKG_UPGRADE:-0}}" = 1 ]; then
	rm -f "$$MARKER"
	exit 0
fi
if uci -q get uuplugin.uuplugin >/dev/null 2>&1; then
	uci -q set uuplugin.uuplugin.enabled='0' || exit 1
	uci -q commit uuplugin || exit 1
fi
for SECTION in c2000max_uu_tun c2000max_uu_lan_to_tun c2000max_uu_tun_to_lan; do
	uci -q delete "firewall.$$SECTION" >/dev/null 2>&1 || true
done
uci -q commit firewall || exit 1
/etc/init.d/firewall reload >/dev/null 2>&1 || exit 1
if [ -L /var/tmp/uu ] && [ "$$(readlink /var/tmp/uu 2>/dev/null)" = /tmp/uu ]; then
	rm -f /var/tmp/uu || exit 1
fi
rm -rf /tmp/uu || exit 1
rm -f /tmp/uuplugin.state /var/lock/uuplugin.lock \
	/etc/uuplugin.accel-state || exit 1
rm -f "$$MARKER" || exit 1
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
