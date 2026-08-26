include $(TOPDIR)/rules.mk

LUCI_TITLE:=C2000MAX acceleration-aware IP and MAC rate limits
LUCI_DEPENDS:=+tc +nftables +conntrack +kmod-sched-core +kmod-sched-flower +kmod-sched-act-police +kmod-ifb +kmod-mediatek_hnat \
	+ip-full +flock @!PACKAGE_luci-app-eqos

PKG_MAINTAINER:=Jianhui Zhao <jianhuizhao329@gmail.com>
PKG_NAME:=luci-app-eqos-mtk
PKG_VERSION:=26.235.1
PKG_RELEASE:=5

define Package/luci-app-eqos-mtk/conffiles
/etc/config/eqos
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
