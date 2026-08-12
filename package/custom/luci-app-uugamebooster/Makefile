# Copyright (C) 2021 Openwrt.org
#
# This is free software, licensed under the Apache License, Version 2.0 .
#

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for UUgamebooster
LUCI_DEPENDS:=+luci-compat +curl +ca-bundle +kmod-tun +ip-full \
	+kmod-nf-conntrack-netlink +nftables-json +kmod-nft-core \
	+kmod-nft-nat +kmod-nft-compat +iptables-nft +ip6tables-nft \
	+ipset +kmod-ipt-core +kmod-ipt-ipset +kmod-nft-tproxy \
	+kmod-nft-socket +iptables-mod-tproxy +iptables-mod-socket
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-uugamebooster
PKG_VERSION:=1.0
PKG_RELEASE:=8

include $(TOPDIR)/feeds/luci/luci.mk
# call BuildPackage - OpenWrt buildroot signature
