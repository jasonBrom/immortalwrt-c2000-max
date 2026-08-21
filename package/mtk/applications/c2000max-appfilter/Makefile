include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=c2000max-appfilter
PKG_VERSION:=6.1.8
PKG_RELEASE:=16
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=C2000MAX maintainers

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define KernelPackage/c2000max-oaf
  SUBMENU:=Network Support
  TITLE:=C2000MAX OpenAppFilter DPI engine
  DEPENDS:=+kmod-nf-conntrack +kmod-nf-reject
  KCONFIG:=CONFIG_NETWORK_SECMARK=y CONFIG_NF_CONNTRACK_SECMARK=y \
	CONFIG_NF_CONNTRACK_MARK=y \
	CONFIG_NETFILTER_XT_TARGET_CONNSECMARK=n \
	CONFIG_NETFILTER_XT_TARGET_SECMARK=n
  FILES:=$(PKG_BUILD_DIR)/oaf/oaf.ko
endef

define KernelPackage/c2000max-oaf/description
 OpenAppFilter flow DPI engine adapted for acceleration-safe APP_ID tagging.
 The original project is https://github.com/destan19/OpenAppFilter.
endef

define Package/c2000max-appfilter
  SECTION:=net
  CATEGORY:=Network
  TITLE:=C2000MAX application audit service
  DEPENDS:=+kmod-c2000max-oaf +libubox +libubus +libuci +libpthread +libjson-c +libblobmsg-json
endef

define Package/c2000max-appfilter/description
 OpenAppFilter userspace loader used by C2000MAX traffic audit. It is disabled
 until application auditing is explicitly enabled in LuCI.
endef

define Package/c2000max-appfilter/conffiles
/etc/config/appfilter
/etc/appfilter/feature.cfg
endef

OAF_KCFLAGS:=-Wno-error=missing-prototypes \
	-Wno-error=missing-declarations \
	-Wno-error=unused-variable \
	-Wno-error=declaration-after-statement \
	-Wno-error=implicit-fallthrough \
	-Wno-error=missing-braces \
	-Wno-error=parentheses \
	-Wno-error=format

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(KERNEL_MAKE_FLAGS) \
		M="$(PKG_BUILD_DIR)/oaf" \
		KCFLAGS="$(OAF_KCFLAGS)" \
		modules
	$(MAKE) -C "$(PKG_BUILD_DIR)/oafd" \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS) -Werror=implicit-function-declaration" \
		LIBS="$(TARGET_LDFLAGS) -lm -lpthread -lubox -luci -lubus -ljson-c -lblobmsg_json" \
		all
endef

define Package/c2000max-appfilter/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/etc/init.d $(1)/etc/config $(1)/etc/appfilter
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/oafd/oafd $(1)/usr/bin/c2000max-oafd
	$(INSTALL_BIN) ./files/gen_class.sh $(1)/usr/bin/gen_class.sh
	$(INSTALL_BIN) ./files/c2000max-appfilter.init $(1)/etc/init.d/c2000max-appfilter
	$(INSTALL_CONF) ./files/appfilter.config $(1)/etc/config/appfilter
	$(INSTALL_CONF) ./files/feature.cfg $(1)/etc/appfilter/feature.cfg
	$(INSTALL_DATA) ./LICENSE $(1)/etc/appfilter/COPYING
endef

$(eval $(call KernelPackage,c2000max-oaf))
$(eval $(call BuildPackage,c2000max-appfilter))
