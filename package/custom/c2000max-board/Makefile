include $(TOPDIR)/rules.mk

PKG_NAME:=c2000max-board
PKG_VERSION:=2.36.01
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/c2000max-board
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=NRadio C2000-MAX board integration
  PKGARCH:=all
	DEPENDS:=+qmodem +luci-base +jq +jsonfilter +ip-full +firewall4 \
	+kmod-dummy +kmod-mediatek_hnat +mtkhnat_util +hnat-detect \
	+luci-app-turboacc-mtk +luci-app-eqos-mtk +luci-app-c2000max-traffic \
	+mwan3 +coreutils-timeout \
	+flock +uboot-envtools +zram-swap +gawk +grep +sed +coreutils-sort \
	+luci-app-netbird +netbird
endef

define Package/c2000max-board/description
 Board defaults, three-slot SIM multiplexer, PWM fan, RGB signal LEDs and LuCI
 integration for the NRadio C2000-MAX.
endef

define Package/c2000max-board/conffiles
/etc/config/c2000max
endef

define Build/Compile
endef

define Package/c2000max-board/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults $(1)/etc/rc.d
	$(INSTALL_DATA) ./files/etc/c2000max-build $(1)/etc/c2000max-build
	$(INSTALL_CONF) ./files/etc/config/c2000max $(1)/etc/config/c2000max
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-sim $(1)/etc/init.d/c2000max-sim
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-leds $(1)/etc/init.d/c2000max-leds
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-fan $(1)/etc/init.d/c2000max-fan
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-hnat $(1)/etc/init.d/c2000max-hnat
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-access $(1)/etc/init.d/c2000max-access
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-swap-tune $(1)/etc/init.d/c2000max-swap-tune
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-uplink $(1)/etc/init.d/c2000max-uplink
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-service-worker $(1)/etc/init.d/c2000max-service-worker
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/etc/hotplug.d/iface/98-c2000max-uplink $(1)/etc/hotplug.d/iface/98-c2000max-uplink
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-c2000max-defaults $(1)/etc/uci-defaults/99-c2000max-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-y-c2000max-v3601-services $(1)/etc/uci-defaults/99-y-c2000max-v3601-services
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-z-c2000max-feed-fix $(1)/etc/uci-defaults/99-z-c2000max-feed-fix
	ln -sf ../init.d/c2000max-hnat $(1)/etc/rc.d/S91c2000max-hnat
	ln -sf ../init.d/eqos $(1)/etc/rc.d/S99eqos
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-sim $(1)/usr/sbin/c2000max-sim
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-leds $(1)/usr/sbin/c2000max-leds
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-fan $(1)/usr/sbin/c2000max-fan
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-hwmon $(1)/usr/sbin/c2000max-hwmon
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-port-role $(1)/usr/sbin/c2000max-port-role
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-eqos-locked $(1)/usr/sbin/c2000max-eqos-locked
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-hnat-locked $(1)/usr/sbin/c2000max-hnat-locked
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-access $(1)/usr/sbin/c2000max-access
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-swap $(1)/usr/sbin/c2000max-swap
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-adblock-compat $(1)/usr/sbin/c2000max-adblock-compat
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-netbird-job $(1)/usr/sbin/c2000max-netbird-job
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-service-worker $(1)/usr/sbin/c2000max-service-worker
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-factory $(1)/usr/sbin/c2000max-factory
	$(INSTALL_DIR) $(1)/usr/lib/c2000max
	$(INSTALL_DATA) ./files/usr/lib/c2000max/port-role.sh $(1)/usr/lib/c2000max/port-role.sh
	$(INSTALL_DATA) ./files/usr/lib/c2000max/uplink-mode.sh $(1)/usr/lib/c2000max/uplink-mode.sh
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/c2000max $(1)/usr/libexec/rpcd/c2000max
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/c2000max
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/c2000max/sim.js $(1)/www/luci-static/resources/view/c2000max/sim.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/c2000max/sim_v8.js $(1)/www/luci-static/resources/view/c2000max/sim_v8.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/c2000max/fan.js $(1)/www/luci-static/resources/view/c2000max/fan.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/c2000max/port_role_v31.js $(1)/www/luci-static/resources/view/c2000max/port_role_v31.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/c2000max/access_v352.js $(1)/www/luci-static/resources/view/c2000max/access_v352.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/c2000max/swap_v352.js $(1)/www/luci-static/resources/view/c2000max/swap_v352.js
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/c2000max/netbird_async_v353.js $(1)/www/luci-static/resources/view/c2000max/netbird_async_v353.js
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/status/include
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/status/include/15_c2000max_v16.js $(1)/www/luci-static/resources/view/status/include/15_c2000max_v16.js
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/c2000max.json $(1)/usr/share/luci/menu.d/c2000max.json
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/zzzz-c2000max-netbird.json $(1)/usr/share/luci/menu.d/zzzz-c2000max-netbird.json
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/zzzz-c2000max-reboot-last.json $(1)/usr/share/luci/menu.d/zzzz-c2000max-reboot-last.json
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/c2000max.json $(1)/usr/share/rpcd/acl.d/c2000max.json
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/zzzz-c2000max-netbird.json $(1)/usr/share/rpcd/acl.d/zzzz-c2000max-netbird.json
endef

define Package/c2000max-board/postinst
#!/bin/sh
rm -f \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/port_role_v20.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/port_role_v21.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/port_role_v22.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/port_role_v23.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/port_role_v24.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/port_role_v25.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/port_role_v26.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/access_v35.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/swap_v35.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/access_v351.js" \
	"$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/swap_v351.js"
[ -n "$${IPKG_INSTROOT}" ] || {
	# Seed the persistent slot before a later sysupgrade -n can erase UCI.
	# Failure is visible to the installer; never claim cross-reset persistence
	# when fw_setenv or its readback is unavailable.
	/usr/sbin/c2000max-sim persist >/dev/null 2>&1 || exit 1
	/usr/sbin/c2000max-adblock-compat seed >/dev/null 2>&1 || true
	/etc/init.d/c2000max-service-worker enable >/dev/null 2>&1 || true
	/etc/init.d/c2000max-service-worker restart >/dev/null 2>&1 || true
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache
}
exit 0
endef

$(eval $(call BuildPackage,c2000max-board))
