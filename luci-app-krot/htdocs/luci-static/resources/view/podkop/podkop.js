"use strict";
"require view";
"require dom";
"require form";
"require baseclass";
"require uci";
"require ui";
"require view.krot.main as main";

// Global settings
"require view.krot.settings as settings";

// Sections
"require view.krot.section as section";

// Server
"require view.krot.server as server";

// Dashboard
"require view.krot.dashboard as dashboard";

// Diagnostic
"require view.krot.diagnostic as diagnostic";

// Updates
"require view.krot.updates as updates";

const UCI_PACKAGE = main.PODKOP_UCI_PACKAGE;
const CBI_PREFIX = UCI_PACKAGE;

const HEADER_METRICS_POLL_INTERVAL = 10000;
const WAN_METRICS_POLL_INTERVAL = 2000;
const WAN_HISTORY_LIMIT = 60;
let headerMetricsTimer = null;
let headerMetricsInflight = null;
let headerMetricsCache = null;
let headerMetricsObserver = null;
let headerMetricsGeneration = 0;
let wanMetricsTimer = null;
let wanMetricsInflight = null;
let wanMetricsGeneration = 0;
let wanPreviousSample = null;
let wanHistory = [];

function formatHeaderBytes(bytes) {
  // Use binary units (MiB/GiB) to match LuCI status page
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  if (!Number.isFinite(bytes) || bytes < 0) {
    return "";
  }
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  const exp = Math.min(Math.floor(Math.log2(bytes) / 10), units.length - 1);
  const value = Number((bytes / Math.pow(1024, exp)).toPrecision(3));
  return `${value} ${units[exp]}`;
}

function formatHeaderUptime(totalSeconds) {
  const seconds = Math.max(0, Math.floor(Number(totalSeconds) || 0));
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const secs = seconds % 60;
  const parts = [];
  if (days > 0) {
    parts.push(`${days}d`);
  }
  if (hours > 0 || days > 0) {
    parts.push(`${hours}h`);
  }
  if (minutes > 0 || hours > 0 || days > 0) {
    parts.push(`${minutes}m`);
  }
  parts.push(`${secs}s`);
  return parts.join(" ");
}

function createHeaderMetricsRow(label, value) {
  const row = document.createElement("span");
  row.className = "ifacebadge";
  row.style.cssText = "display:inline-flex;align-items:center;gap:4px;margin:2px 0;";

  const labelEl = document.createElement("strong");
  labelEl.textContent = `${label}: `;
  row.appendChild(labelEl);

  const valueEl = document.createElement("span");
  valueEl.textContent = value;
  row.appendChild(valueEl);

  return row;
}

function renderHeaderMetricsContent(badge, data) {
  const tempText =
    typeof data.temperature_c === "number"
      ? `${data.temperature_c}°C`
      : _("n/a");
  const memTotalKb = Number(data.mem_total_kb) || 0;
  const memUsedKb = Number(data.mem_used_kb) || 0;
  const memPercent = Math.max(0, Math.min(100, Number(data.mem_used_percent) || 0));
  const memFreePercent = 100 - memPercent;
  const memText =
    memTotalKb > 0
      ? `${formatHeaderBytes(memUsedKb * 1024)} / ${formatHeaderBytes(memTotalKb * 1024)} (${memFreePercent}% ${_("free")})`
      : _("n/a");

  const body = document.createElement("div");
  body.className = "ifacebox-body left";
  const statusRow = document.createElement("div");
  statusRow.className = "krot-header-metrics__status";
  statusRow.appendChild(createHeaderMetricsRow(_("CPU Temp"), tempText));
  const uptimeText =
    typeof data.uptime_seconds === "number" && data.uptime_seconds > 0
      ? formatHeaderUptime(data.uptime_seconds)
      : "…";
  statusRow.appendChild(createHeaderMetricsRow(_("Uptime"), uptimeText));
  body.appendChild(statusRow);
  const memoryRow = createHeaderMetricsRow(_("Memory"), memText);
  memoryRow.classList.add("krot-header-metrics__memory");
  body.appendChild(memoryRow);

  const meter = document.createElement("div");
  meter.className = "krot-meter";
  const meterFill = document.createElement("div");
  meterFill.className = "krot-meter-fill";
  meterFill.style.width = `${memPercent}%`;
  meter.appendChild(meterFill);
  body.appendChild(meter);

  // Keep the live graph (including its history and values) when the slower
  // CPU/memory poll replaces only the surrounding metric rows.
  const wanWidget = badge.querySelector(".krot-header-network");
  badge.replaceChildren(body);
  if (wanWidget) {
    body.appendChild(wanWidget);
  }
}

function calculateWanRate(previous, current) {
  if (!previous || previous.interface !== current.interface) {
    return null;
  }
  const elapsed = Number(current.timestamp) - Number(previous.timestamp);
  if (!Number.isFinite(elapsed) || elapsed <= 0) {
    return null;
  }
  const counters = ["rx_bytes", "tx_bytes", "rx_packets", "tx_packets"];
  const next = counters.map((key) => Number(current[key]));
  const before = counters.map((key) => Number(previous[key]));
  if (
    [...next, ...before].some((value) => !Number.isFinite(value) || value < 0) ||
    next.some((value, index) => value < before[index])
  ) {
    return null;
  }
  return {
    rxBytesPerSecond: (next[0] - before[0]) / elapsed,
    txBytesPerSecond: (next[1] - before[1]) / elapsed,
    rxPacketsPerSecond: Math.round((next[2] - before[2]) / elapsed),
    txPacketsPerSecond: Math.round((next[3] - before[3]) / elapsed),
  };
}

function formatWanBitsPerSecond(bytesPerSecond) {
  const bitsPerSecond = Math.max(0, bytesPerSecond) * 8;
  const megabits = bitsPerSecond / 1000000;
  if (megabits >= 1) {
    return `${megabits.toFixed(megabits >= 100 ? 0 : 1)} Mbit/s`;
  }
  if (bitsPerSecond >= 1000) {
    return `${(bitsPerSecond / 1000).toFixed(0)} Kbit/s`;
  }
  return `${bitsPerSecond.toFixed(0)} bit/s`;
}

function createWanMetricsWidget() {
  const widget = document.createElement("div");
  widget.className = "krot-header-network";

  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 240 36");
  svg.setAttribute("preserveAspectRatio", "none");
  svg.setAttribute("aria-hidden", "true");
  const baseline = document.createElementNS("http://www.w3.org/2000/svg", "path");
  baseline.setAttribute("d", "M0 35 H240");
  baseline.setAttribute("class", "krot-header-network__baseline");
  const area = document.createElementNS("http://www.w3.org/2000/svg", "path");
  area.setAttribute("class", "krot-header-network__area");
  const line = document.createElementNS("http://www.w3.org/2000/svg", "path");
  line.setAttribute("class", "krot-header-network__line");
  svg.append(baseline, area, line);
  widget.appendChild(svg);

  const values = document.createElement("div");
  values.className = "krot-header-network__values";
  for (const field of ["down", "up", "packets"]) {
    const span = document.createElement("span");
    span.className = `krot-header-network__${field}`;
    span.textContent = "…";
    values.appendChild(span);
  }
  widget.appendChild(values);
  return widget;
}

function getWanMetricsWidget() {
  const body = document.querySelector(".krot-page-header-text");
  if (!body) {
    return null;
  }
  let widget = body.querySelector(".krot-header-network");
  if (!widget) {
    try {
      widget = createWanMetricsWidget();
      body.appendChild(widget);
    } catch (error) {
      console.warn("Failed to create WAN graph", error);
      return null;
    }
  }
  return widget;
}

function drawWanHistory() {
  const widget = getWanMetricsWidget();
  if (!widget) {
    return;
  }
  const width = 240;
  const max = Math.max(...wanHistory, 1);
  const step = width / (WAN_HISTORY_LIMIT - 1);
  const points = wanHistory.map((value, index) => {
    const x = width - (wanHistory.length - index - 1) * step;
    const y = 32 - (value / max) * 28;
    return [x, y];
  });
  const linePath = points.map(([x, y], index) =>
    `${index ? "L" : "M"}${x.toFixed(2)} ${y.toFixed(2)}`,
  ).join(" ");
  const areaPath = points.length
    ? `${linePath} L${points.at(-1)[0].toFixed(2)} 35 L${points[0][0].toFixed(2)} 35 Z`
    : "";
  widget.querySelector(".krot-header-network__line").setAttribute("d", linePath);
  widget.querySelector(".krot-header-network__area").setAttribute("d", areaPath);
}

function renderWanMetrics(data) {
  const rate = calculateWanRate(wanPreviousSample, data);
  wanPreviousSample = data;
  if (!rate) {
    wanHistory = [];
    drawWanHistory();
    return;
  }
  wanHistory.push(rate.rxBytesPerSecond);
  wanHistory = wanHistory.slice(-WAN_HISTORY_LIMIT);
  drawWanHistory();
  const widget = getWanMetricsWidget();
  if (!widget) {
    return;
  }
  widget.title = `${data.interface} · ${_("WAN traffic")}`;
  widget.querySelector(".krot-header-network__down").textContent =
    `↓ ${formatWanBitsPerSecond(rate.rxBytesPerSecond)}`;
  widget.querySelector(".krot-header-network__up").textContent =
    `↑ ${formatWanBitsPerSecond(rate.txBytesPerSecond)}`;
  widget.querySelector(".krot-header-network__packets").textContent =
    `↓${rate.rxPacketsPerSecond} ↑${rate.txPacketsPerSecond} pps`;
}

async function fetchWanMetrics() {
  if (document.hidden || wanMetricsInflight) {
    return wanMetricsInflight || Promise.resolve();
  }
  const generation = wanMetricsGeneration;
  wanMetricsInflight = (async () => {
    try {
      // LuCI's own finite RPC timeout releases this request for the next poll.
      const res = await main.PodkopShellMethods.getWanMetrics();
      if (generation === wanMetricsGeneration && res?.success && res.data) {
        renderWanMetrics(res.data);
      }
    } catch (error) {
      // Keep the current chart through transient RPC failures.
      console.warn("Failed to update WAN metrics", error);
    } finally {
      wanMetricsInflight = null;
    }
  })();
  return wanMetricsInflight;
}

function startWanMetricsPolling() {
  stopWanMetricsPolling();
  const generation = wanMetricsGeneration;
  fetchWanMetrics().finally(() => {
    // A rate needs two counter samples. Take the second one quickly so the
    // graph appears immediately, then continue with the regular interval.
    window.setTimeout(() => {
      if (generation === wanMetricsGeneration) {
        fetchWanMetrics();
      }
    }, 250);
  });
  wanMetricsTimer = window.setInterval(
    fetchWanMetrics,
    WAN_METRICS_POLL_INTERVAL,
  );
}

function stopWanMetricsPolling() {
  if (wanMetricsTimer !== null) {
    window.clearInterval(wanMetricsTimer);
    wanMetricsTimer = null;
  }
  wanMetricsGeneration += 1;
  wanPreviousSample = null;
  wanHistory = [];
}

function fetchHeaderMetrics() {
  if (document.hidden) {
    return Promise.resolve();
  }
  if (headerMetricsInflight) {
    return headerMetricsInflight;
  }
  const generation = headerMetricsGeneration;
  headerMetricsInflight = (async () => {
    try {
      // Keep tracking the same RPC until its finite LuCI timeout completes.
      const res = await main.PodkopShellMethods.getRouterMetrics();
      if (generation === headerMetricsGeneration && res?.success && res.data) {
        headerMetricsCache = res.data;
        const badge = document.getElementById("krot-header-metrics");
        if (badge) {
          renderHeaderMetricsContent(badge, res.data);
        }
      }
    } catch (_error) {
      // keep previous values on transient errors or timeout
    } finally {
      headerMetricsInflight = null;
    }
  })();
  return headerMetricsInflight;
}

function startHeaderMetricsPolling() {
  stopHeaderMetricsPolling();
  stopWanMetricsPolling();
  fetchHeaderMetrics();
  getWanMetricsWidget();
  startWanMetricsPolling();
  headerMetricsTimer = window.setInterval(
    fetchHeaderMetrics,
    HEADER_METRICS_POLL_INTERVAL,
  );
}

function stopHeaderMetricsPolling() {
  if (headerMetricsTimer !== null) {
    window.clearInterval(headerMetricsTimer);
    headerMetricsTimer = null;
  }
  headerMetricsGeneration += 1;
}

function watchHeaderMetricsRemoval() {
  headerMetricsObserver?.disconnect();
  const badge = document.getElementById("krot-header-metrics");
  if (!badge) {
    return;
  }
  headerMetricsObserver = new MutationObserver(() => {
    if (!document.getElementById("krot-header-metrics")) {
      stopHeaderMetricsPolling();
      stopWanMetricsPolling();
      headerMetricsObserver?.disconnect();
      headerMetricsObserver = null;
    }
  });
  headerMetricsObserver.observe(document.body, { childList: true, subtree: true });
}

function renderSectionAdd(sectionRef, extra_class) {
  const el = form.GridSection.prototype.renderSectionAdd.apply(sectionRef, [
    extra_class,
  ]);
  const nameEl = el.querySelector(".cbi-section-create-name");

  ui.addValidator(
    nameEl,
    "uciname",
    true,
    (value) => {
      const button = el.querySelector(".cbi-section-create > .cbi-button-add");
      const uciconfig = sectionRef.uciconfig || sectionRef.map.config;

      if (!value) {
        button.disabled = true;
        return true;
      }

      if (uci.get(uciconfig, value)) {
        button.disabled = true;
        return _("Expecting: %s").format(_("unique UCI identifier"));
      }

      button.disabled = null;
      return true;
    },
    "blur",
    "keyup",
  );

  return el;
}

function getRuleEditButtonText() {
  return _("Edit");
}

function resetHorizontalPageScroll() {
  try {
    window.scrollTo(0, window.scrollY);
    if (document.documentElement) {
      document.documentElement.scrollLeft = 0;
    }
    if (document.body) {
      document.body.scrollLeft = 0;
    }
  } catch (_error) {
    // Best-effort layout repair after LuCI modal saves.
  }
}

function cleanupClosedModalArtifacts() {
  try {
    const overlay = document.getElementById("modal_overlay");
    const visibleModal = overlay?.querySelector(
      '.modal:not([style*="display: none"])',
    );
    const overlayHasContent = Boolean(
      overlay && `${overlay.textContent || ""}`.trim(),
    );

    if (overlay && !visibleModal && !overlayHasContent) {
      overlay.remove();
    }

    if (!document.getElementById("modal_overlay")) {
      document.body.classList.remove("modal-overlay-active");
    }

    document
      .querySelectorAll('.cbi-tooltip[style*="opacity: 0"]')
      .forEach((tooltip) => {
        if (tooltip instanceof HTMLElement) {
          tooltip.remove();
        }
      });

    const remainingOverlay = document.getElementById("modal_overlay");
    if (remainingOverlay) {
      remainingOverlay.scrollLeft = 0;
    }
  } catch (_error) {
    // LuCI versions differ in how they dispose modals.
  }
}

function repairHorizontalOverflowAfterModalSave() {
  const repair = () => {
    try {
      cleanupClosedModalArtifacts();
      const viewportWidth = document.documentElement.clientWidth;

      document
        .querySelectorAll(
          "#maincontent, .cbi-map, .cbi-section, .cbi-section-table, .cbi-page-actions",
        )
        .forEach((node) => {
          if (!(node instanceof HTMLElement)) {
            return;
          }

          const rect = node.getBoundingClientRect();
          const overflowsViewport = rect.right > viewportWidth + 1;

          if (!overflowsViewport) {
            return;
          }

          node.style.maxWidth = "100%";
          node.style.boxSizing = "border-box";
        });

      resetHorizontalPageScroll();
    } catch (_error) {
      resetHorizontalPageScroll();
    }
  };

  window.setTimeout(repair, 0);
  window.setTimeout(repair, 100);
  window.setTimeout(repair, 300);
  window.setTimeout(repair, 600);
}

function configureGridSection(sectionRef, type, title, addTitle) {
  sectionRef.anonymous = false;
  sectionRef.addremove = true;
  sectionRef.sortable = true;
  sectionRef.rowcolors = true;
  sectionRef.nodescriptions = true;
  sectionRef.modaltitle = function (section_id) {
    const label = uci.get(UCI_PACKAGE, section_id, "label");
    return section_id ? `${title}: ${label || section_id}` : addTitle;
  };
  sectionRef.sectiontitle = function (section_id) {
    return uci.get(UCI_PACKAGE, section_id, "label") || section_id;
  };
  sectionRef.renderSectionAdd = function (extra_class) {
    return renderSectionAdd(sectionRef, extra_class);
  };

  if (type === "section") {
    sectionRef.handleModalSave = function (modalMap, ev) {
      const mapNode = this.getActiveModalMap();
      const activeMap = dom.findClassInstance(mapNode);

      return activeMap
        .parse()
        .then(() =>
          form.GridSection.prototype.handleModalSave.call(this, modalMap, ev),
        )
        .then((result) => {
          repairHorizontalOverflowAfterModalSave();
          return result;
        });
    };

    sectionRef.renderRowActions = function (section_id) {
      return form.TableSection.prototype.renderRowActions.call(
        this,
        section_id,
        getRuleEditButtonText(),
      );
    };
  }

  // Add Name column with drag handle before other columns
  const origRenderContents = sectionRef.renderContents;
  sectionRef.renderContents = function (cfgsections, nodes) {
    const result = origRenderContents.apply(this, arguments);
    if (result && typeof result.then === 'function') {
      return result.then((sectionEl) => {
        requestAnimationFrame(() => requestAnimationFrame(() => addNameColumnWithDrag(sectionEl)));
        return sectionEl;
      });
    }
    requestAnimationFrame(() => requestAnimationFrame(() => addNameColumnWithDrag(result)));
    return result;
  }.bind(sectionRef);
}

function addNameColumnWithDrag(sectionEl) {
  if (!sectionEl || sectionEl.dataset.nameColumnAdded) return;
  sectionEl.dataset.nameColumnAdded = '1';

  const table = sectionEl.querySelector('.cbi-section-table');
  if (!table) return;

  // Hide CSS-generated name pseudo-element and fix cell alignment
  const style = document.createElement('style');
  style.textContent = `
    .cbi-section-table-titles.named::before,
    .cbi-section-table-descr.named::before,
    .cbi-section-table-row[data-title]::before {
      display: none !important;
    }
    .table.cbi-section-table .td.cbi-section-table-cell {
      text-align: left !important;
    }
  `;
  sectionEl.appendChild(style);

  // Add Name header
  const theadTr = table.querySelector('.cbi-section-table-titles');
  if (theadTr) {
    const nameTh = document.createElement('th');
    nameTh.className = 'th cbi-section-table-cell';
    nameTh.textContent = _('Name');
    theadTr.insertBefore(nameTh, theadTr.firstChild);
  }

  // Add Name cell with drag handle to each row
  const rows = table.querySelectorAll('.cbi-section-table-row:not(.placeholder)');
  rows.forEach((trEl) => {
    const sectionId = trEl.dataset.sid;
    const sectionName = trEl.dataset.title || sectionId;

    // Get drag handle from actions
    const actionsTd = trEl.querySelector('.cbi-section-actions');
    const dragBtn = actionsTd ? actionsTd.querySelector('.drag-handle') : null;

    // Create name td
    const nameTd = document.createElement('td');
    nameTd.className = 'td cbi-section-table-cell';
    nameTd.style.cssText = 'white-space:nowrap;vertical-align:middle;font-weight:bold;';

    if (dragBtn) {
      dragBtn.style.marginRight = '10px';
      nameTd.appendChild(dragBtn);
    }

    const nameSpan = document.createElement('span');
    nameSpan.textContent = sectionName;
    nameTd.appendChild(nameSpan);

    trEl.insertBefore(nameTd, trEl.firstChild);

    // Icon column: show the actual icon image instead of plain text
    const iconTd = trEl.querySelector('.td[data-name="_icon_display"]');
    if (iconTd && !iconTd.dataset.iconRendered && !iconTd.querySelector('input')) {
      iconTd.dataset.iconRendered = '1';
      iconTd.replaceChildren(
        section.renderSectionIconNode(section.getSectionIconValue(sectionId)),
      );
    }

    // Action column: render the value as a badge, like LuCI status labels
    const actionTd = trEl.querySelector('.td[data-name="_action_display"]');
    if (
      actionTd &&
      !actionTd.dataset.badgeRendered &&
      !actionTd.querySelector('input')
    ) {
      const actionText = actionTd.textContent.trim();
      if (actionText) {
        actionTd.dataset.badgeRendered = '1';
        const badge = document.createElement('span');
        badge.className = 'ifacebadge';
        badge.textContent = actionText;
        actionTd.replaceChildren(badge);
      }
    }
  });
}

// Moves the GridSection "Add" row above the table and pins it to the right
// corner. GridSection renders it after the table by default.
function relocateSectionCreateRows(rootEl) {
  rootEl.querySelectorAll(".cbi-tblsection-create").forEach((el) => {
    const container = el.closest(".cbi-section") || el.parentNode;
    const table = container.querySelector(".cbi-section-table");
    if (
      table &&
      table.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING
    ) {
      container.insertBefore(el, table);
    }
    el.classList.add("krot-section-create--top");

    if (!table || el.parentNode.classList.contains("krot-section-head")) {
      return;
    }
    const descr = container.querySelector(
      ".cbi-tab-descr, .cbi-section-descr",
    );
    if (!descr) {
      return;
    }
    const head = document.createElement("div");
    head.className = "krot-section-head";
    container.insertBefore(head, table);
    head.appendChild(descr);
    head.appendChild(el);
  });
}

const EntryPoint = {
  async render() {
    main.injectGlobalStyles();
    const serverCapabilities = {
      singBoxExtended: false,
    };

    // Reuse cached system info when available. On a cold visit, request only
    // the sing-box capability flag through the backend's pre-lib fast path:
    // the full system report takes over a second and must not hold the entire
    // page at "Loading view..." just to populate protocol choices.
    try {
      const cachedInfo = main.store?.get?.()?.diagnosticsSystemInfo;
      if (cachedInfo?.loaded) {
        serverCapabilities.singBoxExtended = Boolean(
          Number(cachedInfo.sing_box_extended) === 1,
        );
      } else {
        const capabilitiesResponse =
          await main.PodkopShellMethods.getSingBoxCapabilities();
        serverCapabilities.singBoxExtended = Boolean(
          capabilitiesResponse?.success &&
            Number(capabilitiesResponse.data?.sing_box_extended) === 1,
        );
      }
    } catch (error) {
      console.warn("Failed to load K.R.O.T. server capabilities", error);
    }

    const podkopMap = new form.Map(
      UCI_PACKAGE,
      _("K.R.O.T. Settings"),
      _("Configuration for K.R.O.T. (Kernel Routing Overlay Tunnel) service"),
    );
    podkopMap.tabbed = true;

    const dashboardSection = podkopMap.section(
      form.TypedSection,
      "dashboard",
      _("Dashboard"),
    );
    dashboardSection.anonymous = true;
    dashboardSection.addremove = false;
    dashboardSection.cfgsections = function () {
      return ["dashboard"];
    };
    dashboard.createDashboardContent(dashboardSection);

    const rulesSection = podkopMap.section(
      form.GridSection,
      "section",
      _("Rules"),
      _("Drag rows to change priority. The rule at the top is checked first."),
    );
    configureGridSection(
      rulesSection,
      "section",
      _("Section"),
      _("Add a section"),
    );
    section.createSectionContent(rulesSection);

    const serverSection = podkopMap.section(
      form.GridSection,
      "server",
      _("Servers"),
      _("Accept external proxy connections and route them with sing-box."),
    );
    configureGridSection(
      serverSection,
      "server",
      _("Server"),
      _("Add a server inbound"),
    );
    server.configureServerSection(serverSection);
    server.createServerContent(serverSection, serverCapabilities);

    const settingsSection = podkopMap.section(
      form.TypedSection,
      "settings",
      _("Settings"),
    );
    settingsSection.anonymous = true;
    settingsSection.addremove = false;
    settingsSection.cfgsections = function () {
      return ["settings"];
    };
    settings.createSettingsContent(settingsSection, serverCapabilities);

    const diagnosticSection = podkopMap.section(
      form.TypedSection,
      "diagnostic",
      _("Diagnostics"),
    );
    diagnosticSection.anonymous = true;
    diagnosticSection.addremove = false;
    diagnosticSection.cfgsections = function () {
      return ["diagnostic"];
    };
    diagnostic.createDiagnosticContent(diagnosticSection);

    const updatesSection = podkopMap.section(
      form.TypedSection,
      "updates",
      _("Modules"),
    );
    updatesSection.anonymous = true;
    updatesSection.addremove = false;
    updatesSection.cfgsections = function () {
      return ["updates"];
    };
    updates.createUpdatesContent(updatesSection);

    // Kick the header metrics off NOW: the backend answers it on a fast path
    // (no library sourcing, ~6ms) so it costs nothing, and having it in flight
    // during the CBI render means the badge paints real numbers instead of
    // showing "..." for the whole render. The heavier coreService() still
    // waits, so the rpcd/uhttpd channel stays free for podkopMap.render().
    fetchHeaderMetrics().catch(() => {});

    const rendered = await podkopMap.render();

    // Defer coreService(): it starts the 3s log watcher and a system-info poll,
    // and rpcd serialises file.exec calls onto one channel. Firing that during
    // the page's own XHR burst is what pushes a slow request past LuCI's 20s
    // rpctimeout ("Loading view..." then "XHR request timed out"). Letting the
    // page settle first keeps the channel clear for the render-critical calls.
    window.setTimeout(() => {
      if (!document.getElementById("view")) {
        return;
      }
      main.coreService();
    }, 1500);

    try {
      const titleEl = rendered.querySelector("h2[name='content'], h2");
      const descrEl = rendered.querySelector(".cbi-map-descr");

      if (titleEl || descrEl) {
        const headerContainer = document.createElement("div");
        headerContainer.className = "krot-page-header";
        headerContainer.style.cssText = "margin:0 0 16px 0;";

        const textWrapper = document.createElement("div");
        textWrapper.className = "krot-page-header-text";
        textWrapper.style.cssText = "display:flex;flex-direction:column;gap:4px;";

        if (titleEl) {
          titleEl.style.margin = "0";
          titleEl.style.padding = "0";
          titleEl.parentNode?.removeChild(titleEl);
          textWrapper.appendChild(titleEl);
        }

        if (descrEl) {
          descrEl.style.margin = "0";
          descrEl.style.padding = "0";
          descrEl.parentNode?.removeChild(descrEl);
          textWrapper.appendChild(descrEl);
        }

        headerContainer.appendChild(textWrapper);

        const metricsBadge = document.createElement("div");
        metricsBadge.id = "krot-header-metrics";
        metricsBadge.className = "krot-header-metrics";
        metricsBadge.style.cssText =
          "margin-left:auto;align-self:center;min-width:180px;font-size:90%;";
        if (headerMetricsCache) {
          renderHeaderMetricsContent(metricsBadge, headerMetricsCache);
        } else {
          const placeholder = document.createElement("div");
          placeholder.className = "ifacebox-body left";
          placeholder.appendChild(createHeaderMetricsRow(_("CPU Temp"), "…"));
          placeholder.appendChild(createHeaderMetricsRow(_("Memory"), "…"));
          metricsBadge.appendChild(placeholder);
        }
        headerContainer.appendChild(metricsBadge);

        if (rendered.firstChild) {
          rendered.insertBefore(headerContainer, rendered.firstChild);
        } else {
          rendered.appendChild(headerContainer);
        }

        startHeaderMetricsPolling();
        watchHeaderMetricsRemoval();
      }
    } catch (err) {
      console.warn("Failed to attach K.R.O.T. header logo", err);
    }

    try {
      settings.groupHageziOptions(rendered);
    } catch (err) {
      console.warn("Failed to group HaGeZi options", err);
    }

    try {
      relocateSectionCreateRows(rendered);
    } catch (err) {
      console.warn("Failed to relocate section add rows", err);
    }

    return rendered;
  },

  handleRemove() {
    stopHeaderMetricsPolling();
    stopWanMetricsPolling();
    headerMetricsObserver?.disconnect();
    headerMetricsObserver = null;
    headerMetricsCache = null;
  },
};

return view.extend(EntryPoint);
