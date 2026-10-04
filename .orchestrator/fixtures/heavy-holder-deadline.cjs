"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const input = JSON.parse(fs.readFileSync(0, "utf8"));
let source = input.source;
if (input.mutant) {
  const needle = input.mutant === "hard-coded-15s"
    ? "deadline = Math.min(hardDeadline, now + pending.budgetMs + 15000);"
    : "const hardDeadline = started + 210000;";
  assert.ok(source.includes(needle), `mutant target exists: ${input.mutant}`);
  source = source.replace(needle, input.mutant === "hard-coded-15s"
    ? "deadline = started + 15000;"
    : "const hardDeadline = Infinity;");
}

function run({ resultAt = Infinity, heartbeat, accepted = true, nonceMatches = true,
  pendingRaw, pendingSize = 256, pendingSymlink = false }) {
  let elapsed = 0;
  let nonce;
  let body = false;
  let cleaned = false;
  let stderr = "";
  let status = 0;
  const sandboxProcess = {
    env: {}, platform: "win32", pid: 123, execPath: "node.exe", argv: ["node.exe", "inert.cjs"],
    stderr: { write: (message) => { stderr += message; } },
    exit: (code) => { throw Object.assign(new Error("refused"), { exitCode: code }); },
  };
  const pending = () => heartbeat?.(elapsed, nonce);
  const fakeFs = {
    mkdtempSync: () => path.resolve("synthetic-admission"),
    existsSync: (name) => name.endsWith("result.json") ? elapsed >= resultAt : Boolean(pending()),
    lstatSync: () => ({ isFile: () => true, isSymbolicLink: () => pendingSymlink, size: pendingSize }),
    readFileSync: (name) => name.endsWith(".pending") ? pendingRaw ?? JSON.stringify(pending()) : JSON.stringify({
      schemaVersion: 1, nonce: nonceMatches ? nonce : "wrong", accepted, message: "fixture holder refusal",
      owner: { lockId: "a".repeat(32) },
    }),
    rmSync: () => { cleaned = true; },
  };
  const fakeChildProcess = {
    spawn: (_executable, args) => {
      nonce = args[args.indexOf("-AdmissionNonce") + 1];
      return { pid: 456, on() {}, unref() {} };
    },
  };
  const context = vm.createContext({
    require: (name) => name === "node:fs" ? fakeFs : name === "node:child_process" ? fakeChildProcess : require(name),
    module: { exports: {} }, process: sandboxProcess, Buffer, SharedArrayBuffer, Int32Array,
    performance: { now: () => elapsed }, Date: { now: () => elapsed },
    Atomics: { wait: (_array, _index, _value, milliseconds) => {
      elapsed += milliseconds;
      // A test watchdog, not a production timeout. Kills a removed-ceiling
      // mutant in virtual time without leaving a hung process on the host.
      assert.ok(elapsed <= 210020, "absolute 210000ms ceiling must refuse before the watchdog");
    } },
  });
  vm.runInContext(source + `
    findContainerRoot = () => ${JSON.stringify(path.resolve("synthetic-container"))};
    resolvePowerShell = () => "pwsh.exe";
    resolveNodeLauncherExecutable = () => "node.exe";
    isPlainFile = () => true;
    admissionConfiguration = () => ({ worktree: "synthetic-worktree", lane: "fixture", branch: "fixture", head: "a".repeat(40), powershellPath: "pwsh.exe" });
  `, context);
  try {
    context.module.exports("build");
    body = true;
  } catch (error) {
    if (!error.exitCode) throw error;
    status = error.exitCode;
  }
  assert.ok(cleaned, "owned admission directory is cleaned");
  return { elapsed, status, body, stderr };
}

const beat = (time, nonce) => time >= 1000
  ? { schemaVersion: 1, nonce, sequence: 1, budgetMs: input.budgetMs }
  : undefined;
let failed = 0;
function check(name, test) {
  try { test(); console.log(`PASS ${name}`); }
  catch (error) { failed++; console.error(`FAIL ${name}: ${error.message}`); }
}
function refused(result, at) {
  assert.equal(result.status, 73);
  assert.equal(result.body, false);
  assert.equal(result.elapsed, at);
  assert.match(result.stderr, /command body was not executed/);
}

check("slow holder census: 20000ms > old 15000ms, < actual 24000ms budget", () => {
  const result = run({ resultAt: 21000, heartbeat: beat });
  assert.equal(result.status, 0);
  assert.equal(result.body, true);
  assert.equal(result.elapsed, 21000);
});
check("holder never publishes anything: bounded startup refusal at 15000ms", () => refused(run({}), 15000));
check("single pending heartbeat without a result: no reread extension, refusal at 40000ms", () => {
  refused(run({ heartbeat: beat }), 40000);
});
check("repeated pending without a result: absolute ceiling at 210000ms", () => {
  refused(run({ heartbeat: (time, nonce) => ({ schemaVersion: 1, nonce,
    sequence: 1 + Math.floor(time / 10000), budgetMs: input.budgetMs }) }), 210000);
});
check("three censuses with one recheck each: late valid publication at 180000ms", () => {
  const result = run({ resultAt: 180000, heartbeat: (time, nonce) => ({ schemaVersion: 1, nonce,
    sequence: 1 + Math.min(5, Math.floor(time / 30000)), budgetMs: 30000 }) });
  assert.equal(result.status, 0);
  assert.equal(result.elapsed, 180000);
});
check("foreign or malformed pending cannot extend startup", () => {
  for (const change of [{ nonce: "wrong" }, { schemaVersion: 2 }, { sequence: 0 },
    { sequence: 1.5 }, { budgetMs: -1 }, { budgetMs: "24000" }, { budgetMs: 210001 }]) {
    refused(run({ heartbeat: (time, nonce) => ({ ...beat(time, nonce), ...change }) }), 15000);
  }
  for (const change of [{ pendingRaw: "{" }, { pendingRaw: "null" },
    { pendingSize: 1025 }, { pendingSymlink: true }]) {
    refused(run({ heartbeat: beat, ...change }), 15000);
  }
});
check("regressed progress sequence cannot refresh a deadline", () => {
  refused(run({ heartbeat: (time, nonce) => time >= 1000 ? { schemaVersion: 1, nonce,
    sequence: time < 2000 ? 2 : 1, budgetMs: input.budgetMs } : undefined }), 40000);
});
check("pending does not bypass refusal or result nonce checks", () => {
  refused(run({ resultAt: 21000, heartbeat: beat, accepted: false }), 21000);
  refused(run({ resultAt: 21000, heartbeat: beat, nonceMatches: false }), 21000);
});
if (failed) process.exitCode = 1;
