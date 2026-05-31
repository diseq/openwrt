include $(TOPDIR)/rules.mk

PKG_NAME:=fluent-bit
PKG_VERSION:=5.0.6
PKG_RELEASE:=2

PKG_SOURCE_URL:=https://github.com/fluent/fluent-bit/archive/refs/tags/
PKG_SOURCE:=v$(PKG_VERSION).tar.gz
PKG_HASH:=bffe424e9010e89f412fbc0bbd054040aa4f447b9f2f20ffd5b42110db9b2fa3

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
	$(INSTALL_CONF) $(PKG_BUILD_DIR)/conf/parsers.conf $(1)/etc/fluent-bit/parsers.conf
endef

$(eval $(call BuildPackage,fluent-bit))
