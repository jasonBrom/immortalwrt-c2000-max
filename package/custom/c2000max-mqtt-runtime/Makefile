include $(TOPDIR)/rules.mk

PKG_NAME:=c2000max-mqtt-runtime
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKGARCH:=aarch64_cortex-a53

include $(INCLUDE_DIR)/package.mk

define Package/c2000max-mqtt-runtime
  SECTION:=libs
  CATEGORY:=Libraries
  TITLE:=C2000-MAX MQTT client runtime compatibility libraries
  DEPENDS:=+libc
  PROVIDES:=cJSON libcares
endef

define Package/c2000max-mqtt-runtime/description
  Supplies the two MIT-licensed ABI libraries required by the Mosquitto
  command-line clients included in the C2000-MAX V35.7 image family.
endef

define Build/Compile
endef

define Package/c2000max-mqtt-runtime/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(INSTALL_DATA) ./files/usr/lib/libcjson.so.1.7.15 $(1)/usr/lib/
	$(INSTALL_DATA) ./files/usr/lib/libcares.so.2.4.3 $(1)/usr/lib/
	$(LN) libcjson.so.1.7.15 $(1)/usr/lib/libcjson.so.1
	$(LN) libcares.so.2.4.3 $(1)/usr/lib/libcares.so.2
	$(INSTALL_DIR) $(1)/usr/share/licenses/c2000max-mqtt-runtime
	$(INSTALL_DATA) ./files/usr/share/licenses/c2000max-mqtt-runtime/* \
		$(1)/usr/share/licenses/c2000max-mqtt-runtime/
endef

$(eval $(call BuildPackage,c2000max-mqtt-runtime))
