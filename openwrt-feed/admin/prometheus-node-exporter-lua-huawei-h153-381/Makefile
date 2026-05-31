include $(TOPDIR)/rules.mk

PKG_NAME:=prometheus-node-exporter-lua-huawei-h153-381
PKG_VERSION:=0.1.0
PKG_RELEASE:=11

PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

Build/Compile=

define Package/prometheus-node-exporter-lua-huawei-h153-381
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Huawei H153-381 5G router Prometheus Lua collector
  URL:=https://github.com/Salamek/huawei-lte-api
  DEPENDS:=+prometheus-node-exporter-lua +luasocket +luasec +openssl-util +libuci-lua
endef

define Package/prometheus-node-exporter-lua-huawei-h153-381/description
  Lua collector for Huawei H153-381 5G router metrics. It uses the Huawei
  XML API and exposes signal, traffic, device, network, and host metrics
  through prometheus-node-exporter-lua.
endef

define Package/prometheus-node-exporter-lua-huawei-h153-381/conffiles
/etc/config/huawei-h153-381
endef

define Package/prometheus-node-exporter-lua-huawei-h153-381/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./src/huawei-h153-381-metrics.lua $(1)/usr/bin/huawei-h153-381-metrics
	$(INSTALL_BIN) ./src/huawei-h153-381-reconnect.lua $(1)/usr/bin/huawei-h153-381-reconnect
	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(INSTALL_DATA) ./src/huawei_h153_381_metrics.lua $(1)/usr/lib/lua/huawei_h153_381_metrics.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/prometheus-collectors
	$(INSTALL_DATA) ./src/huawei-h153-381.lua $(1)/usr/lib/lua/prometheus-collectors/huawei-h153-381.lua
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./src/huawei-h153-381.config $(1)/etc/config/huawei-h153-381
endef

$(eval $(call BuildPackage,prometheus-node-exporter-lua-huawei-h153-381))
