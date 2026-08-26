include $(TOPDIR)/rules.mk

LUCI_TITLE:=C2000MAX acceleration-independent traffic accounting
LUCI_DEPENDS:=+conntrack +ip-full +coreutils-timeout +coreutils-od +coreutils-sort +coreutils-stat +flock +kmod-mediatek_hnat \
	+c2000max-appfilter +unzip +tar +gzip +ucode +ucode-mod-fs

PKG_NAME:=luci-app-c2000max-traffic
PKG_VERSION:=26.233.1
PKG_RELEASE:=12
PKG_MAINTAINER:=C2000MAX maintainers

define Package/luci-app-c2000max-traffic/conffiles
/etc/config/c2000max_traffic
/etc/c2000max-traffic/usage.tsv
/etc/c2000max-traffic/history.tsv
/etc/c2000max-traffic/audit.tsv
/etc/c2000max-traffic/feature.meta
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
