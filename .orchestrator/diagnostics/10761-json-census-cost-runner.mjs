import childProcess from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import { Session } from "node:inspector/promises";
import { syncBuiltinESMExports } from "node:module";
import path from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath, pathToFileURL } from "node:url";

// PROPOSAL ONLY. Host-reviewed declaration and an attributed verifier are required.
// This standalone diagnostic is not Vitest, hookDurationMs, AC4, or product PASS.
const root = "D:/Users/ToddS/Source/Repos/chase-sets/20261029-10761-impl-g1";
const branch = "codex/10761-impl-g1";
const head = "7c373870313a83e564ddae64e72cbc75354a64ab";
const diagnosticName = "json-census-cost-attribution";
const entryRelative = ".tmp/10761-json-census-cost/diagnostic-runner.mjs";
const entry = fileURLToPath(import.meta.url);
const prefix = entry.replace(/\.mjs$/, "");
const resultPath = `${prefix}.result.json`;
const eventsPath = `${prefix}.events.jsonl`;
const sourcePaths = [
  "scripts/check-structure/json-import-attributes.mjs",
  "scripts/check-structure/json-import-attributes.test.mjs",
  "scripts/lib/repo.mjs",
  "scripts/lib/git-listing.mjs",
  "packages/typescript-compiler-api/index.mjs",
  "vitest.shared.mjs",
];
const original = {
  readFileSync: fs.readFileSync,
  readdirSync: fs.readdirSync,
  existsSync: fs.existsSync,
  execFileSync: childProcess.execFileSync,
};
const receipt = {
  schema: "json-census-cost-attribution/v1",
  claim: "DIAGNOSTIC_ONLY_NOT_AC4",
  exactHead: head,
  branch,
  invocations: 0,
  terminal: "NOT_STARTED",
  stages: {},
  artifacts: [],
  exit: 1,
  limitations: [
    "Fresh process; compile-cache state is inherited, not an OS page-cache purge or an idle-host claim.",
    "Inspector sampling is estimated attribution, not exact per-function wall time.",
    "Sampling and wrappers add diagnostic overhead; precise coverage stays off because it deoptimizes JS and would skew attribution; no acceptance claim follows.",
    "Read bytes are returned UTF-8 bytes, not physical disk IO or exact preprocessing bytes.",
    "CPU stacks attribute preprocessing/resolution and the work receipt supplies counts; zero samples do not prove zero cost.",
    "The host cutoff is <=600s; killed/noncompleted stages retain unknown duration and terminal state.",
  ],
};
let admitted = false;
let ownsEvidence = false;
let activeIO = null;
let session;
const digest = (value) => crypto.createHash("sha256").update(value).digest("hex");
const samePath = (left, right) => path.resolve(left).toLowerCase() === path.resolve(right).toLowerCase();
function git(args) {
  return original.execFileSync("git", args, {
    cwd: root, encoding: "utf8", timeout: 30_000,
    maxBuffer: 64 * 1024 * 1024, windowsHide: true,
  }).trim();
}
function event(value) {
  fs.appendFileSync(eventsPath, `${JSON.stringify({ at: new Date().toISOString(), ...value })}\n`);
  console.log(`CENSUS_COST ${JSON.stringify(value)}`);
}
function artifact(suffix, value) {
  const destination = `${prefix}.${suffix}.json`;
  const bytes = Buffer.from(`${JSON.stringify(value)}\n`);
  fs.writeFileSync(destination, bytes, { flag: "wx" });
  receipt.artifacts.push({ path: path.basename(destination), sha256: digest(bytes), bytes: bytes.length });
}
function plainDirectory(relative) {
  const assertPlain = (directory) => {
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || !samePath(fs.realpathSync.native(directory), directory)) {
      throw new Error(`Not a plain seat directory: ${directory}`);
    }
  };
  let current = path.resolve(root);
  assertPlain(current);
  for (const segment of relative.split("/")) {
    current = path.join(current, segment);
    if (!fs.existsSync(current)) fs.mkdirSync(current);
    assertPlain(current);
  }
  git(["check-ignore", "-q", "--", `${relative}/`]);
  return current;
}
function snapshot() {
  if (git(["rev-parse", "HEAD"]) !== head || git(["branch", "--show-current"]) !== branch || git(["status", "--porcelain"]) !== "") {
    throw new Error("Stopped exact-head seat/branch/clean identity changed");
  }
  const index = original.execFileSync("git", ["ls-files", "-z"], { cwd: root, timeout: 30_000, windowsHide: true });
  const indexed = original.execFileSync("git", ["ls-files", "--stage", "-z"], { cwd: root, timeout: 30_000, windowsHide: true });
  return {
    pathSetSha256: digest(index), pathCount: index.toString("utf8").split("\0").filter(Boolean).length,
    indexEntriesSha256: digest(indexed),
    sources: sourcePaths.map((relative) => {
      const actualBlob = git(["hash-object", `--path=${relative}`, relative]);
      const expectedBlob = git(["rev-parse", `${head}:${relative}`]);
      if (actualBlob !== expectedBlob) throw new Error(`Tracked source differs from stopped head: ${relative}`);
      return { path: relative, blob: actualBlob, diskSha256: digest(original.readFileSync(path.join(root, relative))) };
    }),
  };
}
function safeFileName(value) {
  if (typeof value === "number") return "<file-descriptor>";
  const absolute = value instanceof URL ? fileURLToPath(value) : path.resolve(String(value));
  const relative = path.relative(root, absolute);
  return relative.startsWith("..") || path.isAbsolute(relative) ? "<outside-seat>" : relative.replaceAll("\\", "/");
}
function installIOMeters() {
  for (const name of ["readFileSync", "readdirSync", "existsSync"]) {
    fs[name] = function (...args) {
      if (!activeIO) return original[name].apply(this, args);
      const target = activeIO;
      const started = performance.now();
      let value;
      let failed = true;
      try { value = original[name].apply(this, args); failed = false; return value; }
      finally {
        const elapsedMs = performance.now() - started;
        const key = `${name}:${safeFileName(args[0])}`;
        const item = target[key] ??= { method: name, path: safeFileName(args[0]), calls: 0, returnedBytes: 0, elapsedMs: 0, errors: 0 };
        item.calls += 1; item.elapsedMs += elapsedMs; item.errors += Number(failed);
        if (name === "readFileSync" && !failed) item.returnedBytes += Buffer.isBuffer(value) ? value.length : Buffer.byteLength(value, "utf8");
      }
    };
  }
  childProcess.execFileSync = function (...args) {
    if (!activeIO) return original.execFileSync.apply(this, args);
    const target = activeIO;
    const started = performance.now();
    let failed = true;
    try { const value = original.execFileSync.apply(this, args); failed = false; return value; }
    finally {
      const key = `execFileSync:${path.basename(String(args[0]))}:${JSON.stringify(args[1] ?? [])}`;
      const item = target[key] ??= { method: "execFileSync", command: path.basename(String(args[0])), args: args[1] ?? [], calls: 0, elapsedMs: 0, errors: 0 };
      item.calls += 1; item.elapsedMs += performance.now() - started; item.errors += Number(failed);
    }
  };
  // Saved functions already include the canonical preload guards; never replace those with native bindings.
  syncBuiltinESMExports();
}
function restoreIOMeters() {
  for (const name of ["readFileSync", "readdirSync", "existsSync"]) fs[name] = original[name];
  childProcess.execFileSync = original.execFileSync;
  syncBuiltinESMExports();
}
function profileSummary(profile) {
  const nodes = new Map(profile.nodes.map((node) => [node.id, node]));
  const parents = new Map(profile.nodes.flatMap((node) => (node.children ?? []).map((id) => [id, node.id])));
  const groups = {
    preprocessing: /^preProcessFile$/, ast: /^(createSourceFile|sourceFile|declarationRecords)$/,
    resolution: /^(resolveRelative|resolveSpecifier|packageResolution)$/,
    closure: /^moduleClosure$/, discovery: /^(listWorkspacePackages|possibleManifestPaths|viteExecution|vitestExecution|implementedContexts)$/, git: /^(trackedPaths|gitGrepPaths)$/, freeze: /^deepFreeze$/,
  };
  const inclusiveSampledMicroseconds = Object.fromEntries(Object.keys(groups).map((key) => [key, 0]));
  for (let index = 0; index < (profile.samples?.length ?? 0); index += 1) {
    const matched = new Set();
    for (let id = profile.samples[index]; id !== undefined; id = parents.get(id)) {
      const name = nodes.get(id)?.callFrame.functionName ?? "";
      for (const [key, expression] of Object.entries(groups)) if (expression.test(name)) matched.add(key);
    }
    for (const key of matched) inclusiveSampledMicroseconds[key] += profile.timeDeltas?.[index] ?? 0;
  }
  return { sampleCount: profile.samples?.length ?? 0, inclusiveSampledMicroseconds, note: "Inclusive estimates overlap; never sum groups as an exclusive cost partition." };
}
async function stage(name, operation) {
  const stageReceipt = receipt.stages[name] = { terminal: "STARTED", durationMs: null };
  event({ stage: name, terminal: "STARTED", durationMs: null });
  await session.post("Profiler.start");
  const io = {};
  activeIO = io;
  const started = performance.now();
  let value;
  let failure;
  let finalizationFailure;
  try { value = await operation(); stageReceipt.terminal = "COMPLETED"; }
  catch (error) { failure = error; stageReceipt.terminal = "ERROR"; }
  finally {
    stageReceipt.durationMs = performance.now() - started;
    activeIO = null;
    try {
      const { profile } = await session.post("Profiler.stop");
      stageReceipt.profile = profileSummary(profile);
      artifact(`${name}.profile`, profile);
      artifact(`${name}.io`, Object.values(io));
      event({ stage: name, terminal: stageReceipt.terminal, durationMs: stageReceipt.durationMs });
    } catch (error) {
      finalizationFailure = error;
      stageReceipt.terminal = "ERROR";
      stageReceipt.finalizationError = { message: error.message, stack: error.stack };
      event({ stage: name, terminal: stageReceipt.terminal, durationMs: stageReceipt.durationMs });
    }
  }
  if (failure) throw failure;
  if (finalizationFailure) throw finalizationFailure;
  return value;
}
// Byte-for-byte helper body from stopped-head test; no prewarm or alternate freeze boundary.
function deepFreeze(value) {
  if (value && typeof value === "object" && !Object.isFrozen(value)) {
    Object.freeze(value);
    for (const child of Object.values(value)) deepFreeze(child);
  }
  return value;
}
try {
  const config = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG ?? "", "base64").toString("utf8"));
  const slot = process.env.CHASE_SETS_HEAVY_SLOT_ID;
  if (process.env.CHASE_SETS_HEAVY_ADMITTED !== "1" || !slot || config.head !== head || config.diagnostic?.boundHead !== head || config.branch !== branch || !samePath(config.worktree, root) || !config.lane) {
    throw new Error("Missing/mismatched canonical admission identity, stopped head, branch, seat or attributed lane");
  }
  if (!samePath(entry, path.join(root, entryRelative))) throw new Error("Runner is not at its declared seat path");
  if (config.diagnostic.kind !== "standalone-node" || !samePath(config.diagnostic.entry, entry)) throw new Error("Admission declaration kind/path mismatch");
  if (config.diagnostic.entrySha256 !== digest(original.readFileSync(entry))) throw new Error("Admission entry digest mismatch");
  admitted = true;
  receipt.admissionIdentity = { slotId: slot, lane: config.lane, worktree: config.worktree, head, diagnosticName, entrySha256: config.diagnostic.entrySha256 };
  plainDirectory(".tmp/10761-json-census-cost");
  if (fs.existsSync(resultPath) || fs.existsSync(eventsPath)) throw new Error("Prior diagnostic evidence exists; do not rerun or overwrite it");
  fs.writeFileSync(eventsPath, "", { flag: "wx" });
  ownsEvidence = true;
  const temp = plainDirectory(".tmp/10761-json-census-cost/tmp");
  const compileCache = plainDirectory(".tmp/10761-json-census-cost/compile-cache");
  for (const key of Object.keys(process.env)) if (["TEMP", "TMP", "TMPDIR", "NODE_COMPILE_CACHE", "CHASE_SETS_LANE_MODE"].includes(key.toUpperCase())) delete process.env[key];
  Object.assign(process.env, { TEMP: temp, TMP: temp, TMPDIR: temp, NODE_COMPILE_CACHE: compileCache });
  receipt.before = snapshot();
  const pushed = git(["ls-remote", "--exit-code", "origin", `refs/heads/${branch}`]).split(/\s+/)[0];
  if (pushed !== head) throw new Error("Stopped branch is no longer at the pushed head; host must resolve ownership");
  receipt.terminal = "STARTED";
  event({ terminal: "STARTED", exactHead: head, admissionIdentity: receipt.admissionIdentity, pathSetSha256: receipt.before.pathSetSha256 });
  installIOMeters();
  session = new Session();
  session.connect();
  await session.post("Profiler.enable");
  await session.post("Profiler.setSamplingInterval", { interval: 1000 });
  const censusModule = await stage("moduleImport", () => import(pathToFileURL(path.join(root, sourcePaths[0])).href));
  const result = await stage("census", () => {
    receipt.invocations += 1;
    return censusModule.validateJsonImportAttributes();
  });
  await stage("freeze", () => deepFreeze(result));
  receipt.work = result.inventory.work;
  receipt.correctness = { declarations: result.inventory.declarations.length, partition: result.inventory.partition, violations: result.violations };
  artifact("work", receipt.work);
  session.disconnect(); session = undefined;
  restoreIOMeters();
  receipt.after = snapshot();
  if (JSON.stringify(receipt.before) !== JSON.stringify(receipt.after)) throw new Error("Tracked source/index/path identity changed during diagnostic");
  if (receipt.invocations !== 1) throw new Error("Diagnostic did not make exactly one full-census invocation");
  receipt.terminal = "COMPLETED_DIAGNOSTIC_ONLY";
  receipt.exit = 0;
} catch (error) {
  activeIO = null;
  receipt.error = { message: error.message, stack: error.stack };
  receipt.terminal = admitted
    ? (receipt.terminal === "NOT_STARTED" ? "ERROR_BEFORE_CENSUS" : "ERROR_DIAGNOSTIC_ONLY")
    : "REFUSED_BEFORE_CENSUS";
  console.error(error.message);
} finally {
  activeIO = null;
  restoreIOMeters();
  if (session) session.disconnect();
  if (ownsEvidence && !fs.existsSync(resultPath)) {
    event({ terminal: receipt.terminal, invocations: receipt.invocations, exit: receipt.exit });
    fs.writeFileSync(resultPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: "wx" });
  }
  process.exitCode = receipt.exit;
}
