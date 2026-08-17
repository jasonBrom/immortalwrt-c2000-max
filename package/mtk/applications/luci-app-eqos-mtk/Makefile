include $(TOPDIR)/rules.mk

LUCI_TITLE:=C2000MAX acceleration-aware rate limits and traffic accounting
LUCI_DEPENDS:=+tc +nftables +kmod-sched-core +kmod-ifb +kmod-mediatek_hnat \
	+conntrack +ip-full +coreutils-timeout +flock @!PACKAGE_luci-app-eqos

PKG_MAINTAINER:=Jianhui Zhao <jianhuizhao329@gmail.com>
PKG_NAME:=luci-app-eqos-mtk

define Package/luci-app-eqos-mtk/conffiles
/etc/config/eqos
/etc/c2000max-traffic/usage.tsv
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
