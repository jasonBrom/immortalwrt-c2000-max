include $(TOPDIR)/rules.mk

PKG_NAME:=c2000max-app
PKG_VERSION:=1.10.0
PKG_RELEASE:=5
PKG_LICENSE:=GPL-2.0-or-later
PKG_BUILD_PARALLEL:=1

include $(INCLUDE_DIR)/package.mk

define Package/c2000max-app
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=C2000-MAX official APP compatibility service
  DEPENDS:=+luci-base +luci-compat +luci-lua-runtime +libopenssl \
	+mosquitto-nossl +mosquitto-client-nossl +qmodem +jq +jsonfilter \
	+coreutils-timeout +ca-bundle +flock +blkid +ip-full +iw \
	+uclient-fetch
endef

define Package/c2000max-app/description
 Optional local HTTP API compatibility for the current NRadio APP, verified
 against an APP HAR capture and factory firmware 2.2.8.0, plus an isolated
 Mosquitto bridge matching the factory cloud topology. Factory identity is
 read-only. Modem operations use QModem/c2000max serialized interfaces only.
 Local and cloud master switches remain off by default, while their individual
 feature permissions are preselected for easier first-time setup.
 APP-initiated software update is permanently unavailable and is not exposed
 as a user permission. Official remote Web login uses an isolated factory GNU
 Wget runtime and does not expose rpc/exec through the remote-Web permission.
 Remote SIM, SMS, terminal inventory and reboot replies follow the factory
 cloudd envelopes; MT5700 local band, cell and network-mode controls expose the
 fields consumed by the official APP instead of conflating band and cell locks.
 The official MQTT bridge refreshes its session every 24 hours to prevent a
 long-lived vendor-cloud session from becoming stale while appearing connected.
endef

define Package/c2000max-app/conffiles
/etc/config/c2000max_app
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-o $(PKG_BUILD_DIR)/c2000max-app-crypto \
		$(PKG_BUILD_DIR)/crypto.c \
		$(TARGET_LDFLAGS) -lcrypto
endef

define Package/c2000max-app/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_CONF) ./files/etc/config/c2000max_app $(1)/etc/config/c2000max_app
	$(INSTALL_BIN) ./files/etc/init.d/c2000max-app $(1)/etc/init.d/c2000max-app
	$(INSTALL_BIN) ./files/etc/uci-defaults/99-c2000max-app-autostart $(1)/etc/uci-defaults/99-c2000max-app-autostart
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/c2000max-app-crypto $(1)/usr/bin/c2000max-app-crypto
	$(INSTALL_BIN) ./files/usr/bin/wget-ssl $(1)/usr/bin/wget-ssl
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-local $(1)/usr/sbin/c2000max-app-local
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-httpd $(1)/usr/sbin/c2000max-app-httpd
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-bridge $(1)/usr/sbin/c2000max-app-bridge
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-remote $(1)/usr/sbin/c2000max-app-remote
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-reporter $(1)/usr/sbin/c2000max-app-reporter
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-cache $(1)/usr/sbin/c2000max-app-cache
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-wifi-apply $(1)/usr/sbin/c2000max-app-wifi-apply
	$(INSTALL_BIN) ./files/usr/sbin/c2000max-app-sim-switch $(1)/usr/sbin/c2000max-app-sim-switch
	$(INSTALL_DIR) $(1)/usr/lib/lua/c2000max_app
	$(INSTALL_DATA) ./files/usr/lib/lua/c2000max_app/core.lua $(1)/usr/lib/lua/c2000max_app/core.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/c2000max_app/http.lua $(1)/usr/lib/lua/c2000max_app/http.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/c2000max_app/protocol.lua $(1)/usr/lib/lua/c2000max_app/protocol.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/c2000max_app/identity.lua $(1)/usr/lib/lua/c2000max_app/identity.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/c2000max_app/cloud.lua $(1)/usr/lib/lua/c2000max_app/cloud.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/c2000max_app/command_diag.lua $(1)/usr/lib/lua/c2000max_app/command_diag.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/c2000max_app/rweb.lua $(1)/usr/lib/lua/c2000max_app/rweb.lua
	$(INSTALL_DIR) $(1)/usr/lib/c2000max-rweb-compat
	$(INSTALL_DATA) ./files/usr/lib/c2000max-rweb-compat/libcares.so.2 $(1)/usr/lib/c2000max-rweb-compat/libcares.so.2
	$(INSTALL_DATA) ./files/usr/lib/c2000max-rweb-compat/libcrypto.so.1.1 $(1)/usr/lib/c2000max-rweb-compat/libcrypto.so.1.1
	$(INSTALL_DATA) ./files/usr/lib/c2000max-rweb-compat/libpcre.so.1 $(1)/usr/lib/c2000max-rweb-compat/libpcre.so.1
	$(INSTALL_DATA) ./files/usr/lib/c2000max-rweb-compat/libssl.so.1.1 $(1)/usr/lib/c2000max-rweb-compat/libssl.so.1.1
	$(INSTALL_DATA) ./files/usr/lib/c2000max-rweb-compat/libz.so.1 $(1)/usr/lib/c2000max-rweb-compat/libz.so.1
	$(INSTALL_BIN) ./files/usr/lib/c2000max-rweb-compat/wget-ssl $(1)/usr/lib/c2000max-rweb-compat/wget-ssl
	$(INSTALL_DIR) $(1)/usr/libexec/c2000max-rweb-bin
	$(INSTALL_BIN) ./files/usr/libexec/c2000max-rweb-bin/wget $(1)/usr/libexec/c2000max-rweb-bin/wget
	$(INSTALL_BIN) ./files/usr/libexec/c2000max-rweb-bin/wget-ssl $(1)/usr/libexec/c2000max-rweb-bin/wget-ssl
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller/nradio
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/nradio/app.lua $(1)/usr/lib/lua/luci/controller/nradio/app.lua
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/c2000max_app_api.json $(1)/usr/share/luci/menu.d/c2000max_app_api.json
endef

define Package/c2000max-app/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	uci -q delete c2000max_app.main.device_id
	uci -q delete c2000max_app.main.allow_sensitive
	uci -q delete c2000max_app.main.upgrade_enable
	uci -q commit c2000max_app
	# Keep the harmless procd entry enabled even when every APP feature is
	# disabled.  start_service() launches no process in that state, but a
	# sysupgrade-restored opt-in configuration will be honoured on next boot.
	/etc/init.d/c2000max-app enable >/dev/null 2>&1 || true
	/etc/init.d/c2000max-app restart >/dev/null 2>&1 || true
}
rm -f "$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/app_v29.js" 2>/dev/null || true
rm -f "$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/app_v30.js" 2>/dev/null || true
rm -f "$${IPKG_INSTROOT}/tmp/luci-indexcache."* 2>/dev/null || true
rm -rf "$${IPKG_INSTROOT}/tmp/luci-modulecache" 2>/dev/null || true
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}
exit 0
endef

$(eval $(call BuildPackage,c2000max-app))
