include $(TOPDIR)/rules.mk

PKG_NAME:=mt5700-web-go
PKG_VERSION:=1.1.0
PKG_RELEASE:=1
PKG_LICENSE:=Proprietary
PKG_MAINTAINER:=C2000MAX firmware project
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=mt5700web
GO_PKG_BUILD_PKG:=mt5700web
GO_PKG_LDFLAGS:=-s -w

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/mt5700-web-go
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lightweight MT5700 Web and AT service
  DEPENDS:=$(GO_ARCH_DEPENDS) +qmodem
endef

define Package/mt5700-web-go/description
 A self-contained Go HTTP/WebSocket service for the supplied MT5700 control
 panel. It discovers the modem and AT port through QModem, supports manual
 serial or network AT selection, serializes local AT through QModem, and
 embeds all Web assets in one binary.
endef

define Package/mt5700-web-go/conffiles
/etc/config/mt5700-web
endef

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Package/mt5700-web-go/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/mt5700web $(1)/usr/bin/mt5700-web-go
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_CONF) ./files/etc/config/mt5700-web $(1)/etc/config/mt5700-web
	$(INSTALL_BIN) ./files/etc/init.d/mt5700-web $(1)/etc/init.d/mt5700-web
	$(INSTALL_DIR) $(1)/usr/libexec/mt5700-web
	$(INSTALL_BIN) ./files/usr/libexec/mt5700-web/service-control $(1)/usr/libexec/mt5700-web/service-control
	$(INSTALL_BIN) ./files/usr/libexec/mt5700-web/qmodem-at $(1)/usr/libexec/mt5700-web/qmodem-at
endef

define Package/mt5700-web-go/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
if [ "$$(uci -q get mt5700-web.main.enabled)" = "1" ]; then
	/etc/init.d/mt5700-web enable >/dev/null 2>&1 || true
	/etc/init.d/mt5700-web restart >/dev/null 2>&1 || true
else
	/etc/init.d/mt5700-web stop >/dev/null 2>&1 || true
	/etc/init.d/mt5700-web disable >/dev/null 2>&1 || true
fi
exit 0
endef

define Package/mt5700-web-go/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/mt5700-web stop >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,mt5700-web-go))
