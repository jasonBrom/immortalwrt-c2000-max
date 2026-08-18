include $(TOPDIR)/rules.mk

PKG_NAME:=speedtest-x-go
PKG_VERSION:=1.0.2
PKG_RELEASE:=1
PKG_LICENSE:=LGPL-2.1-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=inst.
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)
PKG_BUILD_DEPENDS:=golang/host
PKG_BUILD_PARALLEL:=1
PKG_BUILD_FLAGS:=no-mips16

GO_PKG:=speedtestx
GO_PKG_BUILD_PKG:=speedtestx
GO_PKG_INSTALL_ALL:=1
GO_PKG_LDFLAGS:=-s -w

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/golang/golang-package.mk

# Go 1.26 no longer falls back to GOPATH mode when golang-build.sh runs from
# the workspace root. Build this self-contained module from its actual module
# directory so go.mod and all go:embed inputs are visible.
define Build/Compile
	$(INSTALL_DIR) $(GO_PKG_BUILD_BIN_DIR) $(GO_BUILD_CACHE_DIR) $(GO_MOD_CACHE_DIR)
	cd $(PKG_BUILD_DIR) && \
		$(GO_PKG_VARS) \
		go build -v -buildvcs=false -trimpath \
			-ldflags "$(GO_PKG_CUSTOM_LDFLAGS) $(GO_PKG_DEFAULT_LDFLAGS)" \
			-o $(GO_PKG_BUILD_BIN_DIR)/speedtestx .
endef

define Package/speedtest-x-go
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Lightweight Go backend for Speedtest-X
  URL:=https://github.com/MortyFx/speedtest-x
  DEPENDS:=$(GO_ARCH_DEPENDS)
endef

define Package/speedtest-x-go/description
 A lightweight, self-contained Go implementation of the LibreSpeed/Speedtest-X
 protocol for trusted LAN speed testing. It serves the Web UI and implements
 download, upload, latency, client-IP and in-memory result endpoints.
endef

define Package/speedtest-x-go/conffiles
/etc/config/speedtestx
endef

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
	$(CP) ./src/web/LICENSE $(PKG_BUILD_DIR)/LICENSE
endef

define Package/speedtest-x-go/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(GO_PKG_BUILD_BIN_DIR)/speedtestx $(1)/usr/bin/speedtest-x-go
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d
	$(INSTALL_CONF) ./files/etc/config/speedtestx $(1)/etc/config/speedtestx
	$(INSTALL_BIN) ./files/etc/init.d/speedtest-x $(1)/etc/init.d/speedtest-x
	$(INSTALL_DIR) $(1)/usr/libexec/speedtest-x
	$(INSTALL_BIN) ./files/usr/libexec/speedtest-x/service-control $(1)/usr/libexec/speedtest-x/service-control
endef

$(eval $(call BuildPackage,speedtest-x-go))
