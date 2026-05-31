include $(TOPDIR)/rules.mk

PKG_NAME:=prometheus-node-exporter-lua-compal-ch7465lg
PKG_VERSION:=0.1.0
PKG_RELEASE:=6

PKG_LICENSE:=MIT
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

Build/Compile=

define Package/prometheus-node-exporter-lua-compal-ch7465lg
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Compal CH7465LG / ConnectBox Prometheus Lua collector
  URL:=https://github.com/mbugert/connectbox-prometheus
  DEPENDS:=+prometheus-node-exporter-lua +luasocket +libuci-lua +openssl-util
endef

define Package/prometheus-node-exporter-lua-compal-ch7465lg/description
  Lua collector for Compal CH7465LG cable modem metrics. It logs in to the
  ConnectBox XML interface and exposes metrics through prometheus-node-exporter-lua.
endef

define Package/prometheus-node-exporter-lua-compal-ch7465lg/conffiles
/etc/config/compal-ch7465lg
endef

define Package/prometheus-node-exporter-lua-compal-ch7465lg/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./src/ch7465lg-metrics.lua $(1)/usr/bin/ch7465lg-metrics
	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(INSTALL_DATA) ./src/ch7465lg_metrics.lua $(1)/usr/lib/lua/ch7465lg_metrics.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/prometheus-collectors
	$(INSTALL_DATA) ./src/compal-ch7465lg.lua $(1)/usr/lib/lua/prometheus-collectors/compal-ch7465lg.lua
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./src/compal-ch7465lg.config $(1)/etc/config/compal-ch7465lg
endef

$(eval $(call BuildPackage,prometheus-node-exporter-lua-compal-ch7465lg))
