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
  const label = _("Edit rule action");

  return label === "Edit rule action" ? "Edit" : label;
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
}

const EntryPoint = {
  async render() {
    main.injectGlobalStyles();
    const serverCapabilities = { singBoxExtended: false };

    try {
      const systemInfoResponse = await main.PodkopShellMethods.getSystemInfo();
      serverCapabilities.singBoxExtended = Boolean(
        systemInfoResponse?.success &&
          Number(systemInfoResponse.data?.sing_box_extended) === 1,
      );
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
      _("Sections"),
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
    settings.createSettingsContent(settingsSection);

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
      _("Updates"),
    );
    updatesSection.anonymous = true;
    updatesSection.addremove = false;
    updatesSection.cfgsections = function () {
      return ["updates"];
    };
    updates.createUpdatesContent(updatesSection);

    main.coreService();

    const rendered = await podkopMap.render();
    return rendered;
  },
};

return view.extend(EntryPoint);
