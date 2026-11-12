include $(TOPDIR)/rules.mk

PKG_NAME:=fluent-bit
PKG_VERSION:=5.2.0
PKG_RELEASE:=3

PKG_SOURCE_URL:=https://github.com/fluent/fluent-bit/archive/refs/tags/
PKG_SOURCE:=v$(PKG_VERSION).tar.gz
PKG_HASH:=7f1b92ed09e43c33d8c572bc1643ad0e797f129286468faf85ac56beed6cccad

PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/cmake.mk

define Package/fluent-bit
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Fast and Lightweight Logs and Metrics processor
  URL:=https://fluentbit.io/
  DEPENDS:= +libyaml +libopenssl +libatomic +musl-fts
endef

define Package/fluent-bit/description
  Fluent Bit is a super fast, lightweight, and highly scalable logging
  and metrics processor and forwarder.
endef

define Package/fluent-bit/conffiles
/etc/config/fluent-bit
/etc/fluent-bit/fluent-bit.conf
/etc/fluent-bit/parsers.conf
endef

TARGET_LDFLAGS +=-lfts -latomic

CMAKE_OPTIONS+= \
	-DFLB_RELEASE=Yes \
	-DEXCLUDE_FROM_ALL=true \
	-DFLB_EXAMPLES=No \
	-DFLB_CHUNK_TRACE=No \
	-DFLB_BACKTRACE=No \
	-DFLB_WASM=No \
	-DFLB_LUAJIT=No \
	-DFLB_USE_SIMDUTF=No \
	-DFLB_UNICODE_ENCODER=No \
	-DFLB_USE_RIPSER=No \
	-DFLB_RIPSER=No \
	-DFLB_KAFKA=No \
	-DWITH_SASL=No \
	-DWITH_ZLIB=No \
	-DWITH_ZSTD=No

define Package/fluent-bit/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/bin/fluent-bit $(1)/usr/sbin/

	$(INSTALL_DIR) $(1)/etc/fluent-bit
	$(INSTALL_CONF) ./files/fluent-bit.conf $(1)/etc/fluent-bit/fluent-bit.conf
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/conf/parsers.conf $(1)/etc/fluent-bit/parsers.conf

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/fluent-bit.config $(1)/etc/config/fluent-bit

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/fluent-bit.init $(1)/etc/init.d/fluent-bit

endef

$(eval $(call BuildPackage,fluent-bit))
