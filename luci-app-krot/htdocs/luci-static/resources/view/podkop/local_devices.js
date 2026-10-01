"use strict";
"require baseclass";
"require rpc";
"require ui";
"require view.krot.main as main";

const callHostHints = rpc.declare({
  object: "luci-rpc",
  method: "getHostHints",
  expect: { "": {} },
});
const callDHCPLeases = rpc.declare({
  object: "luci-rpc",
  method: "getDHCPLeases",
  expect: { "": {} },
});
const callNetworkInterfaceDump = rpc.declare({
  object: "network.interface",
  method: "dump",
  expect: { interface: [] },
});

let localDeviceChoicesCache = null;
let localDeviceChoicesCacheAt = 0;
let localDeviceChoicesPromise = null;
const LOCAL_DEVICE_CHOICES_TTL = 60000;

function normalizeOptionValues(value) {
  if (!value) {
    return [];
  }

  if (Array.isArray(value)) {
    return value
      .filter(Boolean)
      .map((item) => `${item}`.trim())
      .filter(Boolean);
  }

  return `${value}`
    .split(/\s+/)
    .map((item) => item.trim())
    .filter(Boolean);
}

function normalizeLocalDeviceName(name) {
  return `${name || ""}`.trim().replace(/\.lan$/i, "");
}

function addLocalDeviceChoice(choices, ip, name) {
  const normalizedIp = `${ip || ""}`.trim();
  const normalizedName = normalizeLocalDeviceName(name);

  if (!normalizedIp) {
    return;
  }

  if (!main.validateIPV4(normalizedIp).valid) {
    return;
  }

  // Devices without a DHCP hostname must stay selectable by their IP address.
  choices[normalizedIp] = normalizedName || normalizedIp;
}

function addRouterIp(routerIps, ip) {
  const normalizedIp = `${ip || ""}`.trim();

  if (!normalizedIp || !main.validateIPV4(normalizedIp).valid) {
    return;
  }

  routerIps[normalizedIp] = true;
}

function buildRouterIpMap(networkInterfaces) {
  const routerIps = {};

  if (!Array.isArray(networkInterfaces)) {
    return routerIps;
  }

  networkInterfaces.forEach((networkInterface) => {
    const ipv4Addresses =
      networkInterface &&
      typeof networkInterface === "object" &&
      Array.isArray(networkInterface["ipv4-address"])
        ? networkInterface["ipv4-address"]
        : [];

    ipv4Addresses.forEach((address) => {
      addRouterIp(
        routerIps,
        address && typeof address === "object" ? address.address : address,
      );
    });
  });

  return routerIps;
}

function subnetFromAddressMask(address, mask) {
  const ip = `${address || ""}`.trim();

  if (!main.validateIPV4(ip).valid) {
    return null;
  }

  const prefix = parseInt(mask, 10);

  if (isNaN(prefix) || prefix < 0 || prefix > 32) {
    return null;
  }

  const octets = ip.split(".").map((part) => parseInt(part, 10));

  for (let bit = 0; bit < 32; bit++) {
    const octetIndex = Math.floor(bit / 8);
    const bitInOctet = 7 - (bit % 8);

    if (bit < prefix) {
      continue;
    }

    octets[octetIndex] &= ~(1 << bitInOctet) & 0xff;
  }

  return `${octets.join(".")}/${prefix}`;
}

function isUsableLanSubnet(networkInterface, subnet) {
  const name = `${networkInterface.interface || ""}`.toLowerCase();
  const device = `${networkInterface.device || networkInterface.l3_device || ""}`.toLowerCase();
  const proto = `${networkInterface.proto || ""}`.toLowerCase();

  if (name === "loopback" || device === "lo") {
    return false;
  }

  // Point-to-point transports (VPN, PPPoE) carry a /32 host address, never a LAN subnet.
  if (["amneziawg", "wireguard", "pppoe", "ppp"].includes(proto)) {
    return false;
  }

  // Loopback and link-local ranges are never user LAN subnets.
  if (subnet.startsWith("127.") || subnet.startsWith("169.254.")) {
    return false;
  }

  return true;
}

function buildLanSubnetMap(networkInterfaces) {
  const lanSubnets = {};

  if (!Array.isArray(networkInterfaces)) {
    return lanSubnets;
  }

  networkInterfaces.forEach((networkInterface) => {
    if (!networkInterface || typeof networkInterface !== "object") {
      return;
    }

    const ipv4Addresses = Array.isArray(networkInterface["ipv4-address"])
      ? networkInterface["ipv4-address"]
      : [];

    ipv4Addresses.forEach((address) => {
      const subnet = subnetFromAddressMask(
        address && typeof address === "object" ? address.address : address,
        address && typeof address === "object" ? address.mask : null,
      );

      if (subnet && isUsableLanSubnet(networkInterface, subnet)) {
        lanSubnets[subnet] = true;
      }
    });
  });

  return lanSubnets;
}

function buildLocalDeviceChoices(hostHints, dhcpLeases, networkInterfaces) {
  const choices = {};
  const routerIps = buildRouterIpMap(networkInterfaces);
  const lanSubnets = Object.keys(buildLanSubnetMap(networkInterfaces)).sort();

  lanSubnets.forEach((subnet, index) => {
    choices[subnet] =
      index === 0
        ? _("ALL (All devices and subnets)")
        : `${subnet} (${_("LAN")})`;
  });

  if (hostHints && typeof hostHints === "object") {
    Object.values(hostHints).forEach((hint) => {
      if (!hint || typeof hint !== "object") {
        return;
      }

      normalizeOptionValues(hint.ipaddrs || hint.ipv4).forEach((ip) => {
        addLocalDeviceChoice(choices, ip, hint.name);
      });
    });
  }

  if (dhcpLeases && Array.isArray(dhcpLeases.dhcp_leases)) {
    dhcpLeases.dhcp_leases.forEach((lease) => {
      if (!lease || typeof lease !== "object") {
        return;
      }

      addLocalDeviceChoice(choices, lease.ipaddr, lease.hostname);
    });
  }

  Object.keys(routerIps).forEach((ip) => {
    delete choices[ip];
  });

  return choices;
}

function loadLocalDeviceChoices() {
  if (
    localDeviceChoicesCache &&
    Date.now() - localDeviceChoicesCacheAt < LOCAL_DEVICE_CHOICES_TTL
  ) {
    return Promise.resolve(localDeviceChoicesCache);
  }

  if (localDeviceChoicesPromise) {
    return localDeviceChoicesPromise;
  }

  localDeviceChoicesPromise = Promise.all([
    callHostHints().catch(() => ({})),
    callDHCPLeases().catch(() => ({})),
    callNetworkInterfaceDump().catch(() => []),
  ])
    .then(([hostHints, dhcpLeases, networkInterfaces]) => {
      localDeviceChoicesCache = buildLocalDeviceChoices(
        hostHints,
        dhcpLeases,
        networkInterfaces,
      );
      localDeviceChoicesCacheAt = Date.now();
      return localDeviceChoicesCache;
    })
    .catch(() => {
      // Return empty object on failure so UI doesn't break
      localDeviceChoicesCache = {};
      localDeviceChoicesCacheAt = Date.now();
      return localDeviceChoicesCache;
    })
    .finally(() => {
      localDeviceChoicesPromise = null;
    });

  return localDeviceChoicesPromise;
}

function sortLocalDeviceChoiceValues(choices) {
  return Object.keys(choices).sort((a, b) => {
    const byName = `${choices[a]}`.localeCompare(`${choices[b]}`);
    return byName || a.localeCompare(b);
  });
}

function hasSingleIpValue(values) {
  return normalizeOptionValues(values).some(
    (value) =>
      main.validateIPV4(value).valid ||
      // Subnet values such as "192.168.1.0/24" must also count, otherwise the
      // device list is never preloaded and the dropdown renders empty.
      main.validateSubnet(value).valid,
  );
}

function preloadLocalDeviceChoicesForValues(values) {
  return hasSingleIpValue(values)
    ? loadLocalDeviceChoices()
    : Promise.resolve(null);
}

function createLocalDeviceDynamicListWidget(option, section_id, cfgvalue) {
  const values = normalizeOptionValues(
    cfgvalue != null ? cfgvalue : option.default,
  );
  const shouldResolveExistingLabels = hasSingleIpValue(values);

  return (
    shouldResolveExistingLabels ? loadLocalDeviceChoices() : Promise.resolve({})
  ).then((initialChoices) => {
    const choices = localDeviceChoicesCache || initialChoices || {};
    const widget = new ui.DynamicList(values, choices, {
      id: option.cbid(section_id),
      sort: sortLocalDeviceChoiceValues(choices),
      optional: option.optional || option.rmempty,
      datatype: option.datatype,
      placeholder: option.placeholder,
      validate: option.validate.bind(option, section_id),
      disabled: option.readonly != null ? option.readonly : option.map.readonly,
    });
    const node = widget.render();
    let choicesLoaded = Boolean(localDeviceChoicesCache);
    let choicesLoading = false;

    const loadChoices = () => {
      if (choicesLoaded || choicesLoading) {
        return;
      }

      choicesLoading = true;
      loadLocalDeviceChoices()
        .then((loadedChoices) => {
          widget.clearChoices();
          widget.addChoices(
            sortLocalDeviceChoiceValues(loadedChoices),
            loadedChoices,
          );
          choicesLoaded = true;
        })
        .finally(() => {
          choicesLoading = false;
        });
    };

    const maybeLoadChoices = (ev) => {
      if (
        ev.target &&
        typeof ev.target.closest === "function" &&
        ev.target.closest(".cbi-dropdown")
      ) {
        loadChoices();
      }
    };

    node.addEventListener("mousedown", maybeLoadChoices, true);
    node.addEventListener("focusin", maybeLoadChoices, true);

    return node;
  });
}

const EntryPoint = {
  createLocalDeviceDynamicListWidget,
  hasSingleIpValue,
  loadLocalDeviceChoices,
  normalizeOptionValues,
  preloadLocalDeviceChoicesForValues,
};

return baseclass.extend(EntryPoint);
