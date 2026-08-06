include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-speedtest-x
PKG_VERSION:=1.0.3
PKG_RELEASE:=1
PKG_LICENSE:=LGPL-2.1-or-later
PKG_MAINTAINER:=inst.

LUCI_TITLE:=LuCI support for Speedtest-X Go LAN server
LUCI_DESCRIPTION:=Manage the lightweight Speedtest-X compatible LAN speed-test server
LUCI_DEPENDS:=+speedtest-x-go
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
