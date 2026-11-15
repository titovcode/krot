#!/usr/bin/env node
// Regression tests for the browser-side K.R.O.T. update metadata request.
"use strict";

const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const source = fs.readFileSync(
  path.join(root, "luci-app-krot/htdocs/luci-static/resources/view/podkop/main.js"),
  "utf8",
);
const match = source.match(/async function Sr\(\)\{.*?\}(?=async function \$c)/s);
if (!match) throw new Error("Sr update metadata function not found");

function loadCheck(fetch) {
  const factory = new Function(
    "Vc",
    "d",
    "Ne",
    "zc",
    "fetch",
    `${match[0]}; return Sr;`,
  );
  return factory(
    "https://example.invalid/latest.json",
    { get: () => ({ diagnosticsSystemInfo: { podkop_version: "0.2.0.1" } }) },
    (value) => value,
    () => 0,
    fetch,
  );
}

async function main() {
  const success = loadCheck(async () => ({
    ok: true,
    json: async () => ({ version: "0.2.0.1", url: "https://example.invalid/release" }),
  }));
  const result = await success();
  if (result?.status !== "latest" || result?.latestVersion !== "0.2.0.1") {
    throw new Error(`Successful check returned ${JSON.stringify(result)}`);
  }
  console.log("PASS: valid update metadata returns the release status");

  const started = Date.now();
  const keepAlive = setInterval(() => {}, 1000);
  const hanging = loadCheck((url, { signal }) => new Promise((resolve, reject) => {
    signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
  }));
  const timedOut = await hanging();
  clearInterval(keepAlive);
  const elapsed = Date.now() - started;
  if (timedOut !== null || elapsed < 4500 || elapsed > 7000) {
    throw new Error(`Hanging request: result=${timedOut}, elapsed=${elapsed}ms`);
  }
  console.log(`PASS: hanging request times out for backend fallback (${elapsed}ms)`);
}

main().catch((error) => {
  console.error(`FAIL: ${error.message}`);
  process.exit(1);
});
