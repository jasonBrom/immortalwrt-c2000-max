include $(TOPDIR)/rules.mk

PKG_VERSION:=0.9.3
PKG_RELEASE:=1
PKG_LICENSE:=Proprietary
PKG_MAINTAINER:=CNSpeedTest

LUCI_TITLE:=LuCI support for CNSpeedTest
LUCI_DESCRIPTION:=CNSpeedTest service management UI with Argon theme integration
LUCI_DEPENDS:=+cnspeedtest
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
