"use strict";
"require form";
"require uci";
"require ui";
"require rpc";
"require baseclass";
"require tools.widgets as widgets";
"require view.krot.local_devices as localDevices";
"require view.krot.main as main";

const UCI_PACKAGE = main.PODKOP_UCI_PACKAGE;

// The update runs detached on the router: a synchronous exec would be
// killed by the HTTP/ubus request timeout mid-download.
const callHageziAction = rpc.declare({
  object: "file",
  method: "exec",
  params: ["command", "params"],
});

function pollHageziUpdate(attemptsLeft) {
  return callHageziAction("/usr/bin/krot", ["hagezi_update_status"]).then(
    function (res) {
      let state = {};
      try {
        state = JSON.parse(res.stdout || "{}");
      } catch (e) {}

      if (state.status === "running" || state.status === "started") {
        if (attemptsLeft <= 0) {
          throw new Error(_("Timeout"));
        }
        return new Promise(function (resolve) {
          setTimeout(resolve, 2000);
        }).then(function () {
          return pollHageziUpdate(attemptsLeft - 1);
        });
      }
      if (state.status === "done" && state.exit_code === 0) {
        return;
      }
      throw new Error(_("Update failed on the router"));
    },
  );
}

// Wraps the HaGeZi option rows into a single bordered panel and moves it to
// the bottom of the Rules tab. Called from podkop.js after the map has
// rendered, because LuCI renders each option as a standalone .cbi-value row
// with no grouping container. UCI bindings are keyed by cbid, so relocating
// the DOM nodes does not affect Save & Apply.
const HAGEZI_SHIELD_SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/><path d="m9 12 2 2 4-4"/></svg>';

function formatHageziLastUpdate(value) {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}:\d{2})/.exec(
    `${value || ""}`.trim(),
  );
  return m ? `${m[3]}.${m[2]}.${m[1]}, ${m[4]}` : value;
}

function groupHageziOptions(rootEl) {
  const names = [
    "hagezi_enabled",
    "hagezi_list",
    "_hagezi_update",
    "hagezi_last_update",
    "hagezi_domains_count",
  ];
  const rows = names
    .map((name) => rootEl.querySelector('.cbi-value[data-name="' + name + '"]'))
    .filter(Boolean);

  if (rows.length === 0 || rows[0].closest(".krot-hagezi-panel")) {
    return;
  }

  const panel = document.createElement("div");
  panel.className = "krot-hagezi-panel";

  const head = document.createElement("div");
  head.className = "krot-hagezi-panel__head";

  const title = document.createElement("h3");
  title.className = "krot-hagezi-panel__title";
  title.innerHTML = HAGEZI_SHIELD_SVG;
  title.appendChild(document.createTextNode(_("HaGeZi — DNS Blocklists")));
  head.appendChild(title);

  const stats = document.createElement("div");
  stats.className = "krot-hagezi-panel__stats";
  head.appendChild(stats);

  const body = document.createElement("div");
  body.className = "krot-hagezi-panel__body";

  panel.appendChild(head);
  panel.appendChild(body);

  rows.forEach((row) => {
    const name = row.getAttribute("data-name");
    if (name === "hagezi_last_update") {
      const out = row.querySelector("output");
      if (out) {
        out.textContent = formatHageziLastUpdate(out.textContent);
      }
      stats.appendChild(row);
    } else if (name === "hagezi_domains_count") {
      stats.appendChild(row);
    } else {
      body.appendChild(row);
    }
  });

  // The Rules tab container is #cbi-<config>-<section type>; the type of the
  // rules GridSection is "section". Fall back to leaving the panel in place.
  const rulesTab = rootEl.querySelector("#cbi-krot-section");
  if (rulesTab) {
    rulesTab.appendChild(panel);
  } else {
    rows[0].parentNode.insertBefore(panel, rows[0]);
  }
}

function isSingBoxDuration(value) {
  return /^([0-9]+(?:\.[0-9]+)?(?:ns|us|ms|s|m|h|d))+$/.test(value);
}

function createSettingsContent(section, capabilities) {
  let o = section.option(
    form.ListValue,
    "dns_type",
    _("DNS Protocol Type"),
    _("Select DNS protocol to use"),
  );
  o.value("doh", _("DNS over HTTPS (DoH)"));
  o.value("dot", _("DNS over TLS (DoT)"));
  o.value("udp", _("UDP (Unprotected DNS)"));
  o.default = "udp";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "dns_server",
    _("DNS Server"),
    _("Select or enter DNS server address"),
  );
  Object.entries(main.DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "8.8.8.8";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  o = section.option(
    form.Value,
    "bootstrap_dns_server",
    _("Bootstrap DNS server"),
    _(
      "The DNS server used to look up the IP address of an upstream DNS server",
    ),
  );
  Object.entries(main.BOOTSTRAP_DNS_SERVER_OPTIONS).forEach(([key, label]) => {
    o.value(key, _(label));
  });
  o.default = "77.88.8.8";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    const validation = main.validateDNS(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };

  // HaGeZi DNS blocklists are built into K.R.O.T. — always available.
  {
    o = section.option(
      form.Flag,
      "hagezi_enabled",
      _("Enable HaGeZi ad blocking"),
      _("Block ads, trackers and malware using HaGeZi DNS blocklists."),
    );
    o.default = "0";
    o.rmempty = false;

    o = section.option(
      form.ListValue,
      "hagezi_list",
      _("HaGeZi Blocklist"),
      _(
        "Select blocklist. Full versions block more but use more RAM; Mini versions are for low-memory devices. The list is downloaded automatically on Save & Apply.",
      ),
    );
    o.value("light", _("HaGeZi Multi LIGHT (minimal)"));
    o.value("multi", _("HaGeZi Multi NORMAL (recommended)"));
    o.value("pro", _("HaGeZi Multi PRO (extended)"));
    o.value("pro.plus", _("HaGeZi Multi PRO++ (maximum)"));
    o.value("ultimate", _("HaGeZi Multi ULTIMATE (aggressive)"));
    o.value("pro.mini", _("HaGeZi PRO Mini (low memory)"));
    o.value("pro.plus.mini", _("HaGeZi PRO++ Mini (low memory)"));
    o.value("ultimate.mini", _("HaGeZi ULTIMATE Mini (low memory)"));
    o.value("tif.mini", _("HaGeZi TIF Mini (threats only)"));
    o.value("tif.medium", _("HaGeZi TIF Medium (threats only, large)"));
    o.default = "multi";
    o.rmempty = false;
    o.depends("hagezi_enabled", "1");

    o = section.option(form.Button, "_hagezi_update", _("Blocklist update"));
    o.inputtitle = _("Update now");
    o.inputstyle = "reload";
    o.depends("hagezi_enabled", "1");
    o.onclick = function (ev) {
      const btn = ev.target;
      btn.disabled = true;
      return callHageziAction("/usr/bin/krot", ["hagezi_update_async"])
        .then(function () {
          return pollHageziUpdate(120);
        })
        .then(function () {
          // uci.unload() is synchronous and returns undefined, not a promise.
          uci.unload("krot");
          return uci.load("krot");
        })
        .then(function () {
          const lastUpdate = uci.get("krot", "settings", "hagezi_last_update");
          const domainsCount = uci.get(
            "krot",
            "settings",
            "hagezi_domains_count",
          );
          // DummyValue renders the visible text in an <output> next to a
          // hidden input that carries the cbid id.
          ["hagezi_last_update", "hagezi_domains_count"].forEach(function (
            name,
          ) {
            const hidden = document.getElementById("cbid.krot.settings." + name);
            const out = hidden && hidden.parentNode
              ? hidden.parentNode.querySelector("output")
              : null;
            if (out) {
              out.textContent =
                name === "hagezi_last_update"
                  ? formatHageziLastUpdate(lastUpdate) || "-"
                  : domainsCount || "0";
            }
          });
          main.injectGlobalStyles();
          main.showToast(
            _("HaGeZi blocklist updated: %s domains blocked.").format(
              domainsCount || "0",
            ),
            "success",
          );
        })
        .catch(function (e) {
          main.injectGlobalStyles();
          main.showToast(
            _("HaGeZi blocklist update failed: %s").format(e.message),
            "error",
          );
        })
        .finally(function () {
          btn.disabled = false;
        });
    };

    o = section.option(
      form.DummyValue,
      "hagezi_last_update",
      _("Blocklist last updated"),
      _("Last time the HaGeZi blocklist was downloaded"),
    );
    o.default = _("Never");
    o.depends("hagezi_enabled", "1");

    o = section.option(
      form.DummyValue,
      "hagezi_domains_count",
      _("Blocked domains"),
      _("Number of domains in the current blocklist"),
    );
    o.default = "0";
    o.depends("hagezi_enabled", "1");
  }

  o = section.option(
    form.Value,
    "dns_rewrite_ttl",
    _("DNS Rewrite TTL"),
    _("Time in seconds for DNS record caching (default: 60)"),
  );
  o.default = "60";
  o.rmempty = false;
  o.validate = function (section_id, value) {
    if (!value) {
      return _("TTL value cannot be empty");
    }

    const ttl = parseInt(value);
    if (isNaN(ttl) || ttl < 0) {
      return _("TTL must be a positive number");
    }

    return true;
  };

  o = section.option(
    widgets.DeviceSelect,
    "source_network_interfaces",
    _("Source Network Interface"),
    _("Select the network interface from which the traffic will originate"),
  );
  o.default = "br-lan";
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = true;

  o = section.option(
    form.Flag,
    "enable_output_network_interface",
    _("Enable Output Network Interface"),
    _("You can select Output Network Interface, by default autodetect"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    widgets.DeviceSelect,
    "output_network_interface",
    _("Output Network Interface"),
    _("Select the network interface to which the traffic will originate"),
  );
  o.noaliases = true;
  o.nobridges = false;
  o.noinactive = false;
  o.multiple = false;
  o.depends("enable_output_network_interface", "1");

  o = section.option(
    form.Flag,
    "enable_badwan_interface_monitoring",
    _("Interface Monitoring"),
    _("Interface monitoring for Bad WAN"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    widgets.NetworkSelect,
    "badwan_monitored_interfaces",
    _("Monitored Interfaces"),
    _("Select the WAN interfaces to be monitored"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.multiple = true;
  o.filter = function (section_id, value) {
    // Reject if the value is in the blocked list ['lan', 'loopback']
    if (["lan", "loopback"].includes(value)) {
      return false;
    }

    // Reject if the value starts with '@' (means it's an alias/reference)
    if (value.startsWith("@")) {
      return false;
    }

    // Otherwise allow it
    return true;
  };

  o = section.option(
    form.Value,
    "badwan_reload_delay",
    _("Interface Monitoring Delay"),
    _("Delay in milliseconds before reloading K.R.O.T. after interface UP"),
  );
  o.depends("enable_badwan_interface_monitoring", "1");
  o.default = "2000";
  o.rmempty = false;
  o.validate = function (_section_id, value) {
    if (!value) {
      return _("Delay value cannot be empty");
    }
    const delay = parseInt(value, 10);
    return isNaN(delay) || `${delay}` !== `${value}`.trim() || delay < 0 || delay > 600000
      ? _("Delay must be an integer between 0 and 600000")
      : true;
  };

  o = section.option(
    form.Flag,
    "enable_yacd",
    _("Enable YACD"),
    `<a href="${main.getClashUIUrl()}" target="_blank">${main.getClashUIUrl()}</a>`,
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "enable_yacd_wan_access",
    _("Enable YACD WAN Access"),
    _(
      "Allows access to YACD from the WAN. Make sure to open the appropriate port in your firewall.",
    ),
  );
  o.depends("enable_yacd", "1");
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "yacd_secret_key",
    _("YACD Secret Key"),
    _(
      "Secret key for authenticating remote access to YACD when WAN access is enabled.",
    ),
  );
  o.depends("enable_yacd_wan_access", "1");
  o.rmempty = false;
  o.validate = function (_section_id, value) {
    if (!value) {
      return _("Secret must be 8-128 printable ASCII characters");
    }
    return /^[\x21-\x7E]{8,128}$/.test(value)
      ? true
      : _("Secret must be 8-128 printable ASCII characters");
  };

  o = section.option(
    form.Flag,
    "disable_quic",
    _("Disable QUIC"),
    _(
      "Disable the QUIC protocol to improve compatibility or fix issues with video streaming",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "list_update_enabled",
    _("Enable list updates"),
    _("Enable automatic updates for remote lists and rule sets"),
  );
  o.default = "1";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "update_interval",
    _("List Update Frequency"),
    _("Use sing-box duration format like 1d, 12h or 30m"),
  );
  o.depends("list_update_enabled", "1");
  o.placeholder = "1d";
  o.default = "1d";
  o.rmempty = false;
  o.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "update_interval") || "1d";
  };
  o.write = function (section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (normalized.length) {
      uci.set(UCI_PACKAGE, section_id, "update_interval", normalized);
    } else {
      uci.set(UCI_PACKAGE, section_id, "update_interval", "1d");
    }
  };
  o.validate = function (_section_id, value) {
    const normalized = value ? `${value}`.trim() : "";

    if (!normalized.length) {
      return _("Use sing-box duration format like 1d, 12h or 30m");
    }

    if (isSingBoxDuration(normalized)) {
      return true;
    }

    return _("Use sing-box duration format like 1d, 12h or 30m");
  };

  o = section.option(
    form.Flag,
    "download_lists_via_proxy",
    _("Download lists/updates/subscriptions via Proxy/VPN"),
    _("Download external lists/updates/subscriptions via the selected section"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "download_lists_via_proxy_section",
    _("Select a specific section for downloading external resources"),
    _(
      "Download external lists/updates/subscriptions via one of the enabled proxy/VPN sections",
    ),
  );

  o.rmempty = false;
  o.depends("download_lists_via_proxy", "1");
  o.cfgvalue = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "download_lists_via_proxy_section");
  };
  o.load = function () {
    const sections = this.map?.data?.state?.values?.[UCI_PACKAGE] ?? {};

    this.keylist = [];
    this.vallist = [];

    for (const secName in sections) {
      const sec = sections[secName];
      const action = `${sec.action || ""}`;

      // A module-provided action (any non-empty action that is not a built-in
      // non-outbound one) behaves like the JSON-outbound primitive, so it can
      // be selected as a download route here.
      const isOutboundCapable =
        action === "proxy" ||
        action === "outbound" ||
        action === "vpn" ||
        (action !== "" &&
          action !== "direct" &&
          action !== "block" &&
          action !== "zapret" &&
          action !== "byedpi");

      if (
        sec[".type"] === "section" &&
        sec.enabled !== "0" &&
        isOutboundCapable
      ) {
        this.keylist.push(secName);
        this.vallist.push(sec.label || secName);
      }
    }

    return Promise.resolve();
  };

  o = section.option(
    form.Flag,
    "dont_touch_dhcp",
    _("Dont Touch My DHCP!"),
    _("K.R.O.T. will not modify your DHCP configuration"),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.ListValue,
    "config_path",
    _("Config File Path"),
    _(
      "Select path for sing-box config file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/etc/sing-box/config.json", "Flash (/etc/sing-box/config.json)");
  o.value("/tmp/sing-box/config.json", "RAM (/tmp/sing-box/config.json)");
  o.default = "/etc/sing-box/config.json";
  o.rmempty = false;

  o = section.option(
    form.Value,
    "cache_path",
    _("Cache File Path"),
    _(
      "Select or enter path for sing-box cache file. Change this ONLY if you know what you are doing",
    ),
  );
  o.value("/tmp/sing-box/cache.db", "RAM (/tmp/sing-box/cache.db)");
  o.value(
    "/usr/share/sing-box/cache.db",
    "Flash (/usr/share/sing-box/cache.db)",
  );
  o.default = "/tmp/sing-box/cache.db";
  o.rmempty = false;
  o.validate = function (_section_id, value) {
    if (!value) {
      return _("Cache file path cannot be empty");
    }

    const allowed = [
      "/tmp/sing-box/",
      "/etc/sing-box/",
      "/usr/share/sing-box/",
    ];

    return allowed.some((prefix) => `${value}`.startsWith(prefix))
      ? true
      : _(
          "Path must be under /tmp/sing-box, /etc/sing-box or /usr/share/sing-box",
        );
  };

  o = section.option(
    form.ListValue,
    "log_level",
    _("Log Level"),
    _("Select the log level for sing-box"),
  );
  o.value("trace", "Trace");
  o.value("debug", "Debug");
  o.value("info", "Info");
  o.value("warn", "Warn");
  o.value("error", "Error");
  o.value("fatal", "Fatal");
  o.value("panic", "Panic");
  o.default = "warn";
  o.rmempty = false;

  o = section.option(
    form.Flag,
    "exclude_ntp",
    _("Exclude NTP"),
    _(
      "Exclude NTP protocol traffic from the tunnel to prevent it from being routed through the proxy or VPN",
    ),
  );
  o.default = "0";
  o.rmempty = false;

  o = section.option(
    form.DynamicList,
    "routing_excluded_ips",
    _("Routing Excluded IPs"),
    _(
      "Select local devices or enter IP addresses/subnets to be excluded from routing",
    ),
  );
  o.placeholder = _("Device, IP, or subnet");
  o.rmempty = true;
  o.validate = function (section_id, value) {
    // Optional
    if (!value || value.length === 0) {
      return true;
    }

    const validation = main.validateSubnet(value);

    if (validation.valid) {
      return true;
    }

    return validation.message;
  };
  o.load = function (section_id) {
    const values = localDevices.normalizeOptionValues(
      uci.get(UCI_PACKAGE, section_id, "routing_excluded_ips"),
    );

    return localDevices
      .preloadLocalDeviceChoicesForValues(values)
      .then(() => values);
  };
  o.renderWidget = function (section_id, _option_index, cfgvalue) {
    return localDevices.createLocalDeviceDynamicListWidget(
      this,
      section_id,
      cfgvalue,
    );
  };
}

const EntryPoint = {
  createSettingsContent,
  groupHageziOptions,
};

return baseclass.extend(EntryPoint);
