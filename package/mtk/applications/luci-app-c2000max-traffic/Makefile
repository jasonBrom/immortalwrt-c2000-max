include $(TOPDIR)/rules.mk

LUCI_TITLE:=C2000MAX acceleration-independent traffic accounting
LUCI_DEPENDS:=+conntrack +ip-full +coreutils-timeout +flock +kmod-mediatek_hnat

PKG_NAME:=luci-app-c2000max-traffic
PKG_MAINTAINER:=C2000MAX maintainers

define Package/luci-app-c2000max-traffic/conffiles
/etc/config/c2000max_traffic
/etc/c2000max-traffic/usage.tsv
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
