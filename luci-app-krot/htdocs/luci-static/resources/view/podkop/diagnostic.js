"use strict";
"require baseclass";
"require form";
"require ui";
"require uci";
"require fs";
"require view.krot.main as main";

function createDiagnosticContent(section) {
  const o = section.option(form.DummyValue, "_mount_node");
  o.rawhtml = true;
  o.cfgvalue = () => main.DiagnosticTab.render();
  o.renderWidget = function () {
    const node = main.DiagnosticTab.render();
    main.DiagnosticTab.initController();
    return node;
  };
}

const EntryPoint = {
  createDiagnosticContent,
};

return baseclass.extend(EntryPoint);
