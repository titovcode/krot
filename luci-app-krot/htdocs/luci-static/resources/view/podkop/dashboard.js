"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.krot.local_devices as localDevices";
"require view.krot.main as main";

function createDashboardContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => main.DashboardTab.render();
  o.renderWidget = function () {
    const node = main.DashboardTab.render();
    main.DashboardTab.initController();
    main.MonitoringTab.initController({
      loadLocalDeviceChoices: localDevices.loadLocalDeviceChoices,
    });
    return node;
  };
}

const EntryPoint = {
  createDashboardContent,
};

return baseclass.extend(EntryPoint);
