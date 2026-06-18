include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-krot

PODKOP_RELEASE_VERSION:=$(or $(PODKOP_PACKAGE_VERSION),$(PODKOP_VERSION),dev)
PODKOP_LEGACY_RELEASE:=$(findstring -,$(PODKOP_RELEASE_VERSION))
PODKOP_BASE_VERSION:=$(or $(PODKOP_BASE_VERSION),$(if $(PODKOP_LEGACY_RELEASE),$(word 1,$(subst -, ,$(PODKOP_RELEASE_VERSION))),$(PODKOP_RELEASE_VERSION)))
PODKOP_FORK_RELEASE:=$(or $(PODKOP_FORK_RELEASE),$(if $(PODKOP_LEGACY_RELEASE),$(word 2,$(subst -, ,$(PODKOP_RELEASE_VERSION))),))
PODKOP_COMPILED_VERSION:=$(if $(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)-$(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION))
PODKOP_APK_VERSION:=$(if $(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)-r$(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION))
PODKOP_PO_VERSION:=$(if $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(PODKOP_APK_VERSION),$(PODKOP_COMPILED_VERSION))
PODKOP_SDK_VERSION:=$(if $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(PODKOP_BASE_VERSION),$(PODKOP_COMPILED_VERSION))
PODKOP_SDK_RELEASE:=$(if $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(PODKOP_FORK_RELEASE),)

PKG_VERSION:=$(PODKOP_SDK_VERSION)
PKG_RELEASE:=$(PODKOP_SDK_RELEASE)
PKG_PO_VERSION:=$(PODKOP_PO_VERSION)

LUCI_TITLE:=K.R.O.T. (Kernel Routing Overlay Tunnel)
LUCI_DEPENDS:=+luci-base +krot
LUCI_PKGARCH:=all
LUCI_LANG.ru:=Русский (Russian)
LUCI_LANG.en:=English
LUCI_MAINTAINER:=ushan0v <ushan0v@users.noreply.github.com>

PKG_LICENSE:=GPL-2.0-or-later
LUCI_LANGUAGES:=en ru

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
	Rule-based K.R.O.T. LuCI app with hybrid sing-box + zapret orchestration
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)$(HTDOCS)/luci-static/resources/view/krot
	$(CP) $(PKG_BUILD_DIR)/htdocs/luci-static/resources/view/podkop/* $(1)$(HTDOCS)/luci-static/resources/view/krot/
	$(INSTALL_DIR) $(1)/
	$(CP) $(PKG_BUILD_DIR)/root/* $(1)/
	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PODKOP_COMPILED_VERSION)/g' $(1)$(HTDOCS)/luci-static/resources/view/krot/main.js || true
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
