# call BuildPackage - OpenWrt buildroot signature
include $(TOPDIR)/rules.mk

LUCI_NAME:=luci-app-xray-ext
LUCI_TITLE:=Xray Extender
LUCI_DESCRIPTION:=Subscription management, server health monitoring and balancer tools for luci-app-xray.
LUCI_DEPENDS:=+luci-base +luci-app-xray +lua +lua-cjson +libubox-lua +libubus-lua +libuci-lua +wget-ssl

PKG_VERSION:=0.4.9
PKG_RELEASE:=7

# The init script and helper scripts are executable at runtime. ZIP files made
# on Windows may lose Unix mode bits, so restore them after luci.mk copies root/.
define Build/Prepare/luci-app-xray-ext
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/init.d/xray_extd
	chmod 0755 $(PKG_BUILD_DIR)/root/etc/uci-defaults/zz-xray-ext
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/xray_extd/xray_extd.lua
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/xray_extd/upstream_patches.sh
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/xray_extd/install_config.sh
	chmod 0755 $(PKG_BUILD_DIR)/root/usr/sbin/xray-ext-patches
	chmod 0644 $(PKG_BUILD_DIR)/root/usr/libexec/xray_extd/xray_subscription_parser.lua
	chmod 0644 $(PKG_BUILD_DIR)/root/usr/libexec/xray_extd/xray_subscription_json_parser.lua
endef

# Keep the UCI configuration as a conffile so package upgrades preserve the
# user's subscription sections and resolver/health-check settings.
define Package/$(LUCI_NAME)/conffiles
/etc/config/xray_ext
endef

# Install-time integration is deliberately limited to the upstream patches and
# required UCI flags. Xray itself is not restarted to avoid interrupting traffic.
define Package/$(LUCI_NAME)/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

if ! /usr/libexec/xray_extd/install_config.sh; then
	echo 'Xray Extender: configuration/patch step failed; see the message above.' >&2
	exit 1
fi

/etc/init.d/xray_extd enable
if ! /etc/init.d/xray_extd restart; then
	echo 'Xray Extender: daemon is enabled but did not start; inspect logread -e xray_extd.' >&2
fi

rm -f /tmp/luci-indexcache.* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/ 2>/dev/null || true
/etc/init.d/rpcd reload 2>/dev/null || true
exit 0
endef

define Package/$(LUCI_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/xray_extd stop 2>/dev/null || true
/etc/init.d/xray_extd disable 2>/dev/null || true
exit 0
endef

# Prefer the standard OpenWrt LuCI feed location; also support being placed
# directly inside the LuCI feed tree (../../luci.mk).
LUCI_MK:=$(firstword $(wildcard $(TOPDIR)/feeds/luci/luci.mk) $(wildcard ../../luci.mk))
ifeq ($(strip $(LUCI_MK)),)
  $(error Could not find luci.mk. Update/install the OpenWrt luci feed first.)
endif
include $(LUCI_MK)

