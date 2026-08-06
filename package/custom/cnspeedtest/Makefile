include $(TOPDIR)/rules.mk

PKG_NAME:=cnspeedtest
PKG_VERSION:=0.9.2
PKG_RELEASE:=2
PKG_LICENSE:=Proprietary
PKG_MAINTAINER:=CNSpeedTest
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=openwrt_speed
GO_PKG_BUILD_PKG:=openwrt_speed
GO_PKG_LDFLAGS:=-s -w

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

define Package/cnspeedtest
  SECTION:=net
  CATEGORY:=Network
  TITLE:=CNSpeedTest router speed-test service
  URL:=https://cnspeedtest.w8.hk
  DEPENDS:=$(GO_ARCH_DEPENDS) +ca-bundle
endef

define Package/cnspeedtest/description
 CNSpeedTest is a native router speed-test service with an embedded Web UI.
 This package is compiled for the selected OpenWrt target architecture.
endef

define Package/cnspeedtest/conffiles
/etc/config/cnspeedtest
endef

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Package/cnspeedtest/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/openwrt_speed $(1)/usr/bin/cnspeedtest
	$(INSTALL_DIR) $(1)/usr/libexec/cnspeedtest
	$(INSTALL_BIN) ./files/usr/libexec/cnspeedtest/run $(1)/usr/libexec/cnspeedtest/run
	$(INSTALL_BIN) ./files/usr/libexec/cnspeedtest/identity $(1)/usr/libexec/cnspeedtest/identity
	$(INSTALL_BIN) ./files/usr/libexec/cnspeedtest/service-control $(1)/usr/libexec/cnspeedtest/service-control
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/cnspeedtest $(1)/etc/init.d/cnspeedtest
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/cnspeedtest $(1)/etc/config/cnspeedtest
endef

define Package/cnspeedtest/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
/usr/libexec/cnspeedtest/identity >/dev/null 2>&1 || true
if [ "$$(uci -q get cnspeedtest.main.enabled)" = "1" ]; then
	/etc/init.d/cnspeedtest enable >/dev/null 2>&1 || true
	/etc/init.d/cnspeedtest restart >/dev/null 2>&1 || true
else
	/etc/init.d/cnspeedtest stop >/dev/null 2>&1 || true
	/etc/init.d/cnspeedtest disable >/dev/null 2>&1 || true
fi
exit 0
endef

define Package/cnspeedtest/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] || /etc/init.d/cnspeedtest stop >/dev/null 2>&1 || true
exit 0
endef

$(eval $(call BuildPackage,cnspeedtest))
