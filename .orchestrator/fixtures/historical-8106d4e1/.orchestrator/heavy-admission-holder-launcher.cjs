"use strict";

const childProcess = require("node:child_process");

const [powershellPath, ...holderArguments] = process.argv.slice(2);
if (typeof powershellPath !== "string" || powershellPath.length === 0 || holderArguments.length === 0) {
  process.exit(74);
}

const holder = childProcess.spawn(powershellPath, holderArguments, {
  detached: false,
  stdio: "ignore",
  windowsHide: true,
});
holder.on("error", () => process.exit(74));
holder.on("exit", (code) => process.exit(typeof code === "number" ? code : 74));
