include $(TOPDIR)/rules.mk

PKG_VERSION:=1.5.0
PKG_RELEASE:=9

LUCI_TITLE:=LuCI configuration for C2000-MAX APP support
LUCI_DEPENDS:=+c2000max-app
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/luci-app-c2000max-app/postinst
#!/bin/sh
rm -f "$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/app_v29.js" 2>/dev/null || true
rm -f "$${IPKG_INSTROOT}/www/luci-static/resources/view/c2000max/app_v30.js" 2>/dev/null || true
rm -f "$${IPKG_INSTROOT}/tmp/luci-indexcache."* 2>/dev/null || true
rm -rf "$${IPKG_INSTROOT}/tmp/luci-modulecache" 2>/dev/null || true
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}
exit 0
endef

# call BuildPackage - OpenWrt buildroot signature
