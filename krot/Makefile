include $(TOPDIR)/rules.mk

PKG_NAME:=krot

PODKOP_RELEASE_VERSION:=$(or $(PODKOP_PACKAGE_VERSION),$(PODKOP_VERSION),dev)
PODKOP_LEGACY_RELEASE:=$(findstring -,$(PODKOP_RELEASE_VERSION))
PODKOP_BASE_VERSION:=$(or $(PODKOP_BASE_VERSION),$(if $(PODKOP_LEGACY_RELEASE),$(word 1,$(subst -, ,$(PODKOP_RELEASE_VERSION))),$(PODKOP_RELEASE_VERSION)))
PODKOP_FORK_RELEASE:=$(or $(PODKOP_FORK_RELEASE),$(if $(PODKOP_LEGACY_RELEASE),$(word 2,$(subst -, ,$(PODKOP_RELEASE_VERSION))),))
PODKOP_COMPILED_VERSION:=$(if $(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION)-$(PODKOP_FORK_RELEASE),$(PODKOP_BASE_VERSION))
PODKOP_SDK_VERSION:=$(if $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(PODKOP_BASE_VERSION),$(PODKOP_COMPILED_VERSION))
PODKOP_SDK_RELEASE:=$(if $(filter apk,$(PODKOP_PACKAGE_FORMAT)),$(PODKOP_FORK_RELEASE),)

PKG_VERSION:=$(PODKOP_SDK_VERSION)
PKG_RELEASE:=$(PODKOP_SDK_RELEASE)

PKG_MAINTAINER:=ushan0v <ushan0v@users.noreply.github.com>
PKG_LICENSE:=GPL-2.0-or-later

include $(INCLUDE_DIR)/package.mk

define Package/krot
	SECTION:=net
	CATEGORY:=Network
	DEPENDS:=+sing-box +curl +ucode +ucode-mod-fs +kmod-nft-tproxy +coreutils-base64 +coreutils-sort +bind-dig +nftables +kmod-nft-nat +kmod-nft-offload
	CONFLICTS:=https-dns-proxy nextdns luci-app-passwall luci-app-passwall2
	TITLE:=K.R.O.T. backend service
	URL:=https://github.com/titovcode/krot
	PKGARCH:=all
endef

define Package/krot/description
	Rule-based K.R.O.T. backend with hybrid sing-box + zapret orchestration
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/krot/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

krot_has_enabled_sections() {
	uci -q show krot 2>/dev/null | awk -F'[.=]' '
		function clean(value) { gsub(/^'\''|'\''$$/, "", value); return value }
		$$3 == "section" { type[$$2] = 1 }
		$$3 == "enabled" && clean($$4) != "0" { enabled[$$2] = 1 }
		$$3 == "action" && clean($$4) ~ /^(direct|proxy|vpn|outbound|byedpi|zapret)$$/ { action[$$2] = 1 }
		END {
			for (section in action) {
				if (type[section] && enabled[section]) {
					found = 1
				}
			}
			exit found ? 0 : 1
		}
	'
}

if [ -x /etc/init.d/krot ] && krot_has_enabled_sections; then
	/etc/init.d/krot enable >/dev/null 2>&1 || true
	/etc/init.d/krot start >/dev/null 2>&1 || true
fi

exit 0
endef

define Package/krot/prerm
#!/bin/sh

grep -q "105 krot" /etc/iproute2/rt_tables && sed -i "/105 krot/d" /etc/iproute2/rt_tables

/etc/init.d/krot stop >/dev/null 2>&1 || true
/usr/bin/krot restore_dnsmasq >/dev/null 2>&1 || true
if [ -r /usr/lib/krot/dnsmasq_failsafe_restore.sh ]; then
	sh /usr/lib/krot/dnsmasq_failsafe_restore.sh >/dev/null 2>&1 || true
else
	uci -q delete dhcp.krot >/dev/null 2>&1 || true
	uci -q del_list 'dhcp.@dnsmasq[0].notinterface=br-lan' >/dev/null 2>&1 || true
	uci -q del_list 'dhcp.@dnsmasq[0].server=127.0.0.42' >/dev/null 2>&1 || true
	uci -q set 'dhcp.@dnsmasq[0].noresolv=0' >/dev/null 2>&1 || true
	uci -q set 'dhcp.@dnsmasq[0].cachesize=150' >/dev/null 2>&1 || true
	uci -q commit dhcp >/dev/null 2>&1 || true
	[ -x /etc/init.d/dnsmasq ] && /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

exit 0
endef

define Package/krot/conffiles
/etc/config/krot
endef

define Package/krot/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/podkop $(1)/etc/init.d/krot

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/podkop $(1)/etc/config/krot

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/podkop $(1)/usr/bin/krot

	$(INSTALL_DIR) $(1)/usr/lib/krot
	$(CP) ./files/usr/lib/* $(1)/usr/lib/krot/

	sed -i -e 's/__COMPILED_VERSION_VARIABLE__/$(PODKOP_COMPILED_VERSION)/g' $(1)/usr/lib/krot/constants.sh
endef

$(eval $(call BuildPackage,krot))
