#
# Copyright (C) 2015-2016 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v3.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=leigod-acc
PKG_VERSION:=1.3.0.30
PKG_RELEASE:=4

include $(INCLUDE_DIR)/package.mk

# The vendor executable is a packed, sectionless AArch64 ELF.  The generic
# sstrip pass truncates its opaque trailer, so preserve it byte-for-byte.
RSTRIP:=:

define Package/$(PKG_NAME)
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Powerful Leigod Game Accelerater
	DEPENDS:=@aarch64 +libpcap +iptables-nft +ipset +kmod-tun +curl
	URL:=https://www.leigod.com/
endef

define Package/$(PKG_NAME)/description
leigod-acc is a powerful game accelerater
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)/bin
	cp ./files/acc-gw.linux.arm64 $(PKG_BUILD_DIR)/bin/acc-gw.linux.arm64
	chmod +x $(PKG_BUILD_DIR)/bin/acc-gw.linux.arm64
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/sbin/leigod
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/acc-gw.linux.arm64 $(1)/usr/sbin/leigod/acc-gw.linux.arm64
	$(INSTALL_DATA) ./files/version $(1)/usr/sbin/leigod/version
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
