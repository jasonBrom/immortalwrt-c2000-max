include $(TOPDIR)/rules.mk

LUCI_TITLE:=C2000MAX acceleration-aware IP and MAC rate limits
LUCI_DEPENDS:=+tc +nftables +kmod-sched-core +kmod-sched-flower +kmod-ifb +kmod-mediatek_hnat \
	+ip-full +flock @!PACKAGE_luci-app-eqos

PKG_MAINTAINER:=Jianhui Zhao <jianhuizhao329@gmail.com>
PKG_NAME:=luci-app-eqos-mtk

define Package/luci-app-eqos-mtk/conffiles
/etc/config/eqos
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
