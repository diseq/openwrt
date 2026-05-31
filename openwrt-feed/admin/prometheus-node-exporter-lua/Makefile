include $(TOPDIR)/rules.mk

PKG_NAME:=prometheus-node-exporter-lua
PKG_VERSION:=2025.11.22
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKGARCH:=all

include $(INCLUDE_DIR)/package.mk

Build/Compile=

define Package/prometheus-node-exporter-lua
  SECTION:=admin
  CATEGORY:=Administration
  TITLE:=Prometheus node exporter Lua web endpoint
  URL:=https://openwrt.org/packages/pkgdata/prometheus-node-exporter-lua
  DEPENDS:=+lua +luasocket +uhttpd +uhttpd-mod-lua +libubus-lua
endef

define Package/prometheus-node-exporter-lua/description
  Lightweight Lua Prometheus endpoint used by local collector packages.
  This feed-local package intentionally contains only the core endpoint,
  avoiding optional collector subpackages during SDK package builds.
endef

define Package/prometheus-node-exporter-lua/conffiles
/etc/config/prometheus-node-exporter-lua
endef

define Package/prometheus-node-exporter-lua/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/prometheus-node-exporter-lua $(1)/etc/config/prometheus-node-exporter-lua
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/prometheus-node-exporter-lua $(1)/etc/init.d/prometheus-node-exporter-lua
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/prometheus-node-exporter-lua $(1)/usr/bin/prometheus-node-exporter-lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/prometheus-collectors
endef

$(eval $(call BuildPackage,prometheus-node-exporter-lua))
