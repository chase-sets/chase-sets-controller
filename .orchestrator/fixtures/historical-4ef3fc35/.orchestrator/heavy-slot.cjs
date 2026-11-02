"use strict";

const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");

const kinds = new Set(["repository-gate", "playwright", "vitest-full", "script-battery", "build"]);
const ownerTransitionName = /^owner\.transition\.[a-f0-9]{32}\.tmp$/;
const processIdentityProbe = [
  "$ErrorActionPreference = 'Stop'",
  "$candidate = Get-Process -Id ([int]$env:CHASE_SETS_SLOT_OWNER_PID) -ErrorAction Stop",
  "$expected = [DateTimeOffset]::Parse($env:CHASE_SETS_SLOT_OWNER_START).ToUniversalTime().Ticks",
  "if ($candidate.StartTime.ToUniversalTime().Ticks -ne $expected) { exit 1 }",
].join("; ");
const nestedDeadlineMilliseconds = 15000;
const nestedMaxReplyBytes = 16384;
const nestedSharedBytes = 8 + nestedMaxReplyBytes;
const lockIdShape = /^[a-f0-9]{32}$/;
const headShape = /^[a-f0-9]{40}$/;
const launchIdShape = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const laneShape = /^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/;
const ownerFieldsV4 = [
  "schemaVersion",
  "lockId",
  "owner",
  "lane",
  "branch",
  "worktree",
  "head",
  "identityMode",
  "pid",
  "processStartUtc",
  "startedUtc",
  "gate",
  "commandIdentity",
  "state",
  "childPid",
  "childProcessStartUtc",
];
const ownerFieldsV5 = [...ownerFieldsV4, "admissionRoot"];
const transportFields = ["schemaVersion", "lockId", "publicKey", "launchId", "laneRole"];
const dispatchFields = ["launchId", "laneRole"];
const replyFields = [
  "schemaVersion",
  "accepted",
  "challenge",
  "client",
  "root",
  "wrapper",
  "lockId",
  "dispatch",
  "kind",
  "gate",
  "lane",
  "worktree",
  "branch",
  "head",
  "identityMode",
  "owner",
];

function refuse(message) {
  process.stderr.write(`heavy-admission: ${message}\n`);
  process.exit(73);
}

function sleep(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function isPlainFile(candidate) {
  try {
    const stat = fs.lstatSync(candidate);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function isPlainDirectory(candidate) {
  try {
    const stat = fs.lstatSync(candidate);
    return stat.isDirectory() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

function lockEntriesMatchWriterContract(lockPath) {
  const entries = fs.readdirSync(lockPath);
  if (entries.length === 1) return entries[0] === "owner.json";
  if (entries.length !== 2 || !entries.includes("owner.json")) return false;
  const transition = entries.find((entry) => entry !== "owner.json");
  if (!ownerTransitionName.test(transition)) return false;
  if (isPlainFile(path.join(lockPath, transition))) return true;

  // The writer may have completed its atomic move after the directory read.
  const currentEntries = fs.readdirSync(lockPath);
  return currentEntries.length === 1 && currentEntries[0] === "owner.json";
}

function findContainerRoot() {
  let current = path.resolve(__dirname);
  while (true) {
    if (isPlainFile(path.join(current, ".orchestrator", "invoke-heavy-verifier.ps1"))) {
      return current;
    }
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

function resolvePowerShell(configuration) {
  if (typeof configuration?.powershellPath === "string" && path.isAbsolute(configuration.powershellPath)) {
    return configuration.powershellPath;
  }
  return "pwsh.exe";
}

function resolveNodeLauncherExecutable() {
  if (/^node(?:\.exe)?$/i.test(path.basename(process.execPath)) && isPlainFile(process.execPath)) return process.execPath;
  const lifecycleShell = process.env.npm_config_script_shell;
  if (
    typeof lifecycleShell === "string" &&
    path.isAbsolute(lifecycleShell) &&
    /^node(?:\.exe)?$/i.test(path.basename(lifecycleShell)) &&
    isPlainFile(lifecycleShell)
  ) {
    return lifecycleShell;
  }
  return null;
}

// Non-Windows continuation is unchanged: one PowerShell identity probe per call.
function liveOwnerMatchesToken(containerRoot, token, powershellPath) {
  if (!lockIdShape.test(token)) return false;
  const lockPath = path.join(containerRoot, ".orchestrator", "verify-lock.d");
  const ownerPath = path.join(lockPath, "owner.json");
  if (!isPlainDirectory(lockPath) || !isPlainFile(ownerPath)) return false;
  try {
    if (!lockEntriesMatchWriterContract(lockPath)) return false;
    const owner = JSON.parse(fs.readFileSync(ownerPath, "utf8"));
    if (
      owner.lockId !== token ||
      !Number.isInteger(owner.pid) ||
      owner.pid < 1 ||
      typeof owner.processStartUtc !== "string"
    ) {
      return false;
    }
    const probe = childProcess.spawnSync(
      powershellPath,
      ["-NoProfile", "-NonInteractive", "-Command", processIdentityProbe],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          CHASE_SETS_SLOT_OWNER_PID: String(owner.pid),
          CHASE_SETS_SLOT_OWNER_START: owner.processStartUtc,
        },
        windowsHide: true,
      },
    );
    return probe.status === 0;
  } catch {
    return false;
  }
}

function hasExactKeys(candidate, expected) {
  if (candidate === null || typeof candidate !== "object" || Array.isArray(candidate)) return false;
  const keys = Object.keys(candidate);
  if (keys.length !== expected.length) return false;
  return expected.every((name) => Object.hasOwn(candidate, name));
}

function isPositiveInteger(value) {
  return Number.isInteger(value) && value >= 1 && value <= 2147483647;
}

function isUtcIdentity(value) {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$/.test(value)) return false;
  const milliseconds = value.slice(0, 23) + "Z";
  const parsed = new Date(milliseconds);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString() === milliseconds;
}

// JSON.parse validates grammar; this token walk additionally rejects repeated
// object keys at every depth before any closed-schema object is consumed.
function parseClosedJson(text) {
  const value = JSON.parse(text);
  const stack = [];
  const tokens = /"(?:[^"\\]|\\.)*"|[{}\[\]:,]|[^\s{}\[\]:,]+/g;
  for (const match of text.matchAll(tokens)) {
    const token = match[0];
    const current = stack.at(-1);
    if (token === "{") stack.push({ keys: new Set(), key: true });
    else if (token === "[") stack.push(null);
    else if (token === "}" || token === "]") stack.pop();
    else if (token === "," && current) current.key = true;
    else if (token.startsWith('"') && current?.key) {
      const key = JSON.parse(token);
      if (current.keys.has(key)) throw new Error("duplicate JSON field");
      current.keys.add(key);
      current.key = false;
    }
  }
  return value;
}

function samePath(left, right) {
  try {
    return (
      path.resolve(left).replace(/[\\/]+$/, "").toLowerCase() ===
      path.resolve(right).replace(/[\\/]+$/, "").toLowerCase()
    );
  } catch {
    return false;
  }
}

// One canonical owner file contract: the closed schema-v4/v5 record that the
// exact wrapper published. The client compares every identity in the signed
// reply against this record, so a forged or replaced owner cannot admit.
function readNestedOwner(containerRoot, token) {
  const lockPath = path.join(containerRoot, ".orchestrator", "verify-lock.d");
  const ownerPath = path.join(lockPath, "owner.json");
  if (!isPlainDirectory(lockPath) || !isPlainFile(ownerPath)) return { failure: "no live owner record" };
  let owner;
  try {
    if (!lockEntriesMatchWriterContract(lockPath)) return { failure: "owner writer entries are unknown" };
    if (fs.statSync(ownerPath).size > nestedMaxReplyBytes) return { failure: "owner record is oversized" };
    owner = parseClosedJson(fs.readFileSync(ownerPath, "utf8"));
  } catch {
    return { failure: "owner record was unreadable" };
  }
  const fields = owner?.schemaVersion === 5 ? ownerFieldsV5 : ownerFieldsV4;
  if (!hasExactKeys(owner, fields) || (owner.schemaVersion !== 4 && owner.schemaVersion !== 5)) {
    return { failure: "owner record is not a closed schema-v4 or v5 record" };
  }
  if (owner.lockId !== token) return { failure: "owner record does not carry the inherited token" };
  if (owner.state !== "started" && owner.state !== "attached") {
    return { failure: `owner record state ${JSON.stringify(owner.state)} is not started or attached` };
  }
  if (
    !isPositiveInteger(owner.pid) ||
    !isUtcIdentity(owner.processStartUtc) ||
    !isUtcIdentity(owner.startedUtc) ||
    !isPositiveInteger(owner.childPid) ||
    !isUtcIdentity(owner.childProcessStartUtc) ||
    typeof owner.owner !== "string" ||
    owner.owner.length === 0 ||
    typeof owner.gate !== "string" ||
    owner.gate.length === 0 ||
    typeof owner.commandIdentity !== "string" ||
    !/^[a-f0-9]{64}$/.test(owner.commandIdentity) ||
    (owner.schemaVersion === 5 && (typeof owner.admissionRoot !== "string" || !path.isAbsolute(owner.admissionRoot))) ||
    typeof owner.lane !== "string" ||
    !laneShape.test(owner.lane) ||
    typeof owner.worktree !== "string" ||
    !path.isAbsolute(owner.worktree) ||
    typeof owner.head !== "string" ||
    !headShape.test(owner.head) ||
    (owner.identityMode !== "branch" && owner.identityMode !== "immutable-head") ||
    (owner.identityMode === "branch" && (typeof owner.branch !== "string" || owner.branch.length === 0)) ||
    (owner.identityMode === "immutable-head" && owner.branch !== null)
  ) {
    return { failure: "owner record identity fields are malformed" };
  }
  return { owner };
}

// The transport descriptor names the admission-published endpoint key. It is
// published only by the exact wrapper (guarded environment or validated
// attached result) and is never authority: the signed reply is.
function parseTransportDescriptor(encoded, token) {
  if (typeof encoded !== "string" || encoded.length === 0) return { failure: "nested transport descriptor is missing" };
  if (encoded.length > nestedMaxReplyBytes) return { failure: "nested transport descriptor is oversized" };
  let descriptor;
  try {
    descriptor = parseClosedJson(Buffer.from(encoded, "base64").toString("utf8"));
  } catch {
    return { failure: "nested transport descriptor is unreadable" };
  }
  const hostVerifier = descriptor?.schemaVersion === 2 && descriptor.authority === "host-verifier";
  const fields = hostVerifier ? [...transportFields, "authority", "commandIdentity"] : transportFields;
  if (!hasExactKeys(descriptor, fields) || (!hostVerifier && descriptor.schemaVersion !== 1)) {
    return { failure: "nested transport descriptor is not closed" };
  }
  if (hostVerifier && (descriptor.launchId !== null || descriptor.laneRole !== null ||
      !/^[a-f0-9]{64}$/.test(descriptor.commandIdentity ?? ""))) {
    return { failure: "nested host verifier transport identity is malformed" };
  }
  if (descriptor.lockId !== token) return { failure: "nested transport descriptor names a different owner" };
  if ((descriptor.launchId !== null && (typeof descriptor.launchId !== "string" || !launchIdShape.test(descriptor.launchId))) ||
      (descriptor.laneRole !== null && descriptor.laneRole !== "implementation" && descriptor.laneRole !== "review")) {
    return { failure: "nested transport descriptor dispatch claims are malformed" };
  }
  if (typeof descriptor.publicKey !== "string" || !/^[A-Za-z0-9+/]+=*$/.test(descriptor.publicKey)) {
    return { failure: "nested transport descriptor key is malformed" };
  }
  let publicKey;
  try {
    publicKey = crypto.createPublicKey({ key: Buffer.from(descriptor.publicKey, "base64"), format: "der", type: "spki" });
    if (publicKey.asymmetricKeyType !== "ec" || publicKey.asymmetricKeyDetails?.namedCurve !== "prime256v1") {
      return { failure: "nested transport descriptor key is not ECDSA P-256" };
    }
  } catch {
    return { failure: "nested transport descriptor key is invalid" };
  }
  return { descriptor: { lockId: descriptor.lockId, publicKey, launchId: descriptor.launchId, laneRole: descriptor.laneRole,
    hostVerifier, commandIdentity: descriptor.commandIdentity } };
}

function validateTransportField(transport, token) {
  if (typeof transport !== "string") return null;
  return parseTransportDescriptor(transport, token).descriptor ? transport : null;
}

// Each call opens a NEW pipe connection from a worker thread while the main
// thread waits on Atomics; no process is spawned and no connection is reused.
function exchangeNested(containerRoot, pipeName, requestLine) {
  const { Worker } = require("node:worker_threads");
  const shared = new SharedArrayBuffer(nestedSharedBytes);
  const status = new Int32Array(shared, 0, 2);
  const workerPath = path.join(containerRoot, ".orchestrator", "heavy-nested-client.cjs");
  if (!isPlainFile(workerPath)) return { failure: "nested transport worker is unavailable or unsafe" };
  const workerEnvironment = { ...process.env };
  delete workerEnvironment.NODE_OPTIONS;
  delete workerEnvironment.CHASE_SETS_HEAVY_ADMISSION_CONFIG;
  let worker;
  try {
    worker = new Worker(workerPath, {
      workerData: { shared, pipeName, requestLine, maxReplyBytes: nestedMaxReplyBytes, deadlineMs: nestedDeadlineMilliseconds },
      env: workerEnvironment,
      execArgv: [],
      stdout: false,
      stderr: false,
    });
  } catch {
    return { failure: "nested transport worker could not start" };
  }
  worker.on("error", () => {
    Atomics.store(status, 1, 0);
    Atomics.store(status, 0, 2);
    Atomics.notify(status, 0);
  });
  worker.unref();
  const waited = Atomics.wait(status, 0, 0, nestedDeadlineMilliseconds);
  const code = Atomics.load(status, 0);
  const length = Atomics.load(status, 1);
  const bytes = Buffer.from(Buffer.from(shared, 8, Math.min(length, nestedMaxReplyBytes)));
  worker.terminate().catch(() => {});
  if (waited === "timed-out" || code === 0) return { failure: "nested continuation did not reply within 15 seconds" };
  if (code !== 1) return { failure: length > 0 ? bytes.toString("utf8") : "nested transport worker failed" };
  return { replyLine: bytes };
}

function verifyNestedReply(replyLine, descriptor, owner, challenge, kind) {
  let envelope;
  try {
    envelope = parseClosedJson(replyLine.toString("utf8"));
  } catch {
    return { failure: "nested continuation reply was unreadable" };
  }
  if (hasExactKeys(envelope, ["accepted", "message"]) && envelope.accepted === false) {
    return { failure: typeof envelope.message === "string" ? envelope.message : "nested continuation refused" };
  }
  if (
    !hasExactKeys(envelope, ["payload", "signature"]) ||
    typeof envelope.payload !== "string" ||
    typeof envelope.signature !== "string"
  ) {
    return { failure: "nested continuation reply envelope is not closed" };
  }
  const payload = Buffer.from(envelope.payload, "base64");
  const signature = Buffer.from(envelope.signature, "base64");
  let verified = false;
  try {
    verified =
      signature.length === 64 &&
      crypto.verify("sha256", payload, { key: descriptor.publicKey, dsaEncoding: "ieee-p1363" }, signature);
  } catch {
    verified = false;
  }
  if (!verified) return { failure: "nested continuation reply signature did not verify against the admitted key" };
  let reply;
  try {
    reply = parseClosedJson(payload.toString("utf8"));
  } catch {
    return { failure: "nested continuation reply payload was unreadable" };
  }
  const identity = ["pid", "processStartUtc"];
  if (
    !hasExactKeys(reply, descriptor.hostVerifier ? [...replyFields, "authority", "commandIdentity"] : replyFields) ||
    reply.schemaVersion !== (descriptor.hostVerifier ? 2 : 1) ||
    reply.accepted !== true ||
    reply.challenge !== challenge ||
    !hasExactKeys(reply.client, identity) ||
    !hasExactKeys(reply.root, identity) ||
    !hasExactKeys(reply.wrapper, identity) ||
    !hasExactKeys(reply.dispatch, dispatchFields)
  ) {
    return { failure: "nested continuation reply is not the closed reply for this challenge" };
  }
  if (reply.client.pid !== process.pid || !isUtcIdentity(reply.client.processStartUtc)) {
    return { failure: "nested continuation reply names a different client process" };
  }
  if (
    reply.root.pid !== owner.childPid ||
    reply.root.processStartUtc !== owner.childProcessStartUtc ||
    reply.wrapper.pid !== owner.pid ||
    reply.wrapper.processStartUtc !== owner.processStartUtc
  ) {
    return { failure: "nested continuation reply names a different guarded root or wrapper" };
  }
  // Null dispatch claims grant nothing by omission. Only the distinct signed
  // host variant binds a closed Gate command instead of a lane dispatch.
  if (descriptor.hostVerifier) {
    if (reply.authority !== "host-verifier" || reply.commandIdentity !== descriptor.commandIdentity ||
        reply.commandIdentity !== owner.commandIdentity || owner.schemaVersion !== 4 || owner.state !== "started" ||
        reply.dispatch.launchId !== null || reply.dispatch.laneRole !== null) {
      return { failure: "nested continuation reply carries no exact host verifier authority" };
    }
  } else if (
    typeof reply.dispatch.launchId !== "string" ||
    !launchIdShape.test(reply.dispatch.launchId) ||
    reply.dispatch.launchId !== descriptor.launchId ||
    reply.dispatch.laneRole !== descriptor.laneRole ||
    (reply.dispatch.laneRole !== "implementation" && reply.dispatch.laneRole !== "review")
  ) {
    return { failure: "nested continuation reply carries no admitted dispatch binding" };
  }
  if (
    reply.lockId !== owner.lockId ||
    reply.kind !== kind ||
    reply.gate !== owner.gate ||
    reply.lane !== owner.lane ||
    !samePath(reply.worktree, owner.worktree) ||
    reply.branch !== owner.branch ||
    reply.head !== owner.head ||
    reply.identityMode !== owner.identityMode ||
    reply.owner !== owner.owner
  ) {
    return { failure: "nested continuation reply identity does not equal the admitted owner" };
  }
  return { accepted: true };
}

// Windows nested continuation: the inherited token is never authority by
// itself. Authority is the exact wrapper's signed answer to a fresh challenge
// after it has proven this process is a live descendant of the guarded root.
function nestedContinuation(containerRoot, token, kind) {
  if (!lockIdShape.test(token)) return "inherited heavy slot token is malformed";
  const ownerResult = readNestedOwner(containerRoot, token);
  if (ownerResult.failure) return ownerResult.failure;
  const transportResult = parseTransportDescriptor(process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT, token);
  if (transportResult.failure) return transportResult.failure;
  const { owner } = ownerResult;
  const { descriptor } = transportResult;
  const challenge = crypto.randomBytes(32).toString("hex");
  const request = {
    schemaVersion: 1,
    challenge,
    pid: process.pid,
    kind,
    lockId: token,
    lane: owner.lane,
    worktree: owner.worktree,
    branch: owner.branch,
    head: owner.head,
    identityMode: owner.identityMode,
    gate: owner.gate,
    launchId: descriptor.launchId,
    laneRole: descriptor.laneRole,
  };
  const exchange = exchangeNested(containerRoot, `\\\\.\\pipe\\chase-sets-heavy-${token}`, `${JSON.stringify(request)}\n`);
  if (exchange.failure) return exchange.failure;
  const verification = verifyNestedReply(exchange.replyLine, descriptor, owner, challenge, kind);
  return verification.failure ?? null;
}

function runGit(worktree, argumentsList, description) {
  const result = childProcess.spawnSync("git", ["-C", worktree, ...argumentsList], {
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.status !== 0) throw new Error(`unable to resolve live Git ${description}`);
  return result.stdout.trim();
}

function derivedConfiguration(containerRoot, powershellPath) {
  const worktree = runGit(process.cwd(), ["rev-parse", "--show-toplevel"], "worktree");
  const canonicalWorktree = path.resolve(worktree);
  const containerPrefix = `${path.resolve(containerRoot)}${path.sep}`.toLowerCase();
  if (!canonicalWorktree.toLowerCase().startsWith(containerPrefix)) {
    throw new Error("worktree is not contained by the discovered container");
  }
  const head = runGit(canonicalWorktree, ["rev-parse", "--verify", "HEAD"], "HEAD").toLowerCase();
  const branch = runGit(canonicalWorktree, ["branch", "--show-current"], "branch");
  if (!headShape.test(head)) throw new Error("live Git HEAD was not an exact commit");
  const lane = path.basename(canonicalWorktree);
  if (!laneShape.test(lane)) throw new Error("worktree lane name is invalid");
  return {
    powershellPath,
    worktree: canonicalWorktree,
    lane,
    ...(branch ? { branch, head } : { immutableHead: head }),
  };
}

function admissionConfiguration(containerRoot, configuration) {
  const powershellPath = resolvePowerShell(configuration);
  if (configuration) {
    const worktree = runGit(process.cwd(), ["rev-parse", "--show-toplevel"], "worktree");
    if (!samePath(worktree, configuration.worktree)) {
      throw new Error("heavy-verifier: worktree must name the canonical Git worktree root");
    }
    return {
      powershellPath,
      worktree: configuration.worktree,
      lane: configuration.lane,
      ...(typeof configuration.immutableHead === "string"
        ? { immutableHead: configuration.immutableHead }
        : { branch: configuration.branch, head: configuration.head }),
    };
  }
  return derivedConfiguration(containerRoot, powershellPath);
}

let preloadConfiguration;

function launcherConfiguration(encoded = process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG, { useForAcquisition = false } = {}) {
  if (!Object.hasOwn(process.env, "CHASE_SETS_HEAVY_ADMISSION_CONFIG")) return undefined;
  let config;
  try {
    config = JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
  } catch {
    refuse("launcher admission configuration was invalid; command body was not executed");
  }
  const branchIdentity =
    typeof config?.branch === "string" && config.branch.length > 0 && config.branch.trim() === config.branch &&
    typeof config.head === "string" && /^[a-f0-9]{40}$/i.test(config.head);
  const immutableHeadIdentity = typeof config?.immutableHead === "string" && /^[a-f0-9]{40}$/i.test(config.immutableHead);
  const identityValid =
    (branchIdentity && !Object.hasOwn(config, "immutableHead")) ||
    (immutableHeadIdentity && !Object.hasOwn(config, "branch") && !Object.hasOwn(config, "head"));
  if (
    config?.schemaVersion !== 1 ||
    !path.isAbsolute(config.guardPath ?? "") ||
    !path.isAbsolute(config.powershellPath ?? "") ||
    !path.isAbsolute(config.containerRoot ?? "") ||
    !path.isAbsolute(config.worktree ?? "") ||
    !laneShape.test(config.lane ?? "") || !identityValid
  ) {
    refuse("launcher admission configuration failed validation; command body was not executed");
  }
  if (useForAcquisition) preloadConfiguration = config;
  return config;
}

function acquire(kind, options = {}) {
  if (!kinds.has(kind)) refuse("heavy kind was invalid; command body was not executed");
  const containerRoot = findContainerRoot();
  if (!containerRoot) refuse("container controller was not found; command body was not executed");
  // An active preload opts this process into its validated dispatch claim,
  // including later adapter calls. Standalone callers still derive live Git.
  const configuration = options.configuration ?? preloadConfiguration;
  const powershellPath = resolvePowerShell(configuration);
  const token = process.env.CHASE_SETS_HEAVY_SLOT_ID;
  if (typeof token === "string" && token.length > 0) {
    if (process.platform === "win32") {
      // A present token selects the nested path only. A missing descriptor or
      // any refusal fails closed here and never falls through to a new holder.
      const refusal = nestedContinuation(containerRoot, token, kind);
      if (refusal) refuse(`${refusal}; command body was not executed`);
      return;
    }
    if (liveOwnerMatchesToken(containerRoot, token, powershellPath)) return;
  }

  let admission;
  try {
    admission = admissionConfiguration(containerRoot, configuration);
  } catch (error) {
    refuse(`${error instanceof Error ? error.message : "admission identity was unavailable"}; command body was not executed`);
  }

  const admissionRoot = fs.mkdtempSync(path.join(os.tmpdir(), "chase-sets-heavy-admission-"));
  const resultPath = path.join(admissionRoot, "result.json");
  const nonce = crypto.randomBytes(16).toString("hex");
  const command = [process.execPath, ...process.argv.slice(1)].join(" ").slice(0, 4096);
  const identityArguments =
    typeof admission.immutableHead === "string"
      ? ["-ImmutableHead", admission.immutableHead]
      : ["-Branch", admission.branch, "-ClaimedHead", admission.head];
  const guardPath = path.join(containerRoot, ".orchestrator", "invoke-heavy-verifier.ps1");
  const holderArguments = [
    "-NoProfile",
    "-NonInteractive",
    "-File",
    guardPath,
    "-AdmissionKind",
    kind,
    "-GuardedPid",
    String(process.pid),
    "-AdmissionNonce",
    nonce,
    "-AdmissionResultPath",
    resultPath,
    "-AdmissionCommand",
    command,
    "-Worktree",
    admission.worktree,
    "-Lane",
    admission.lane,
    ...identityArguments,
    "-ContainerRoot",
    containerRoot,
  ];
  const holderLauncherPath = path.join(
    containerRoot,
    ".orchestrator",
    "heavy-admission-holder-launcher.cjs",
  );
  if (!isPlainFile(holderLauncherPath)) {
    fs.rmSync(admissionRoot, { recursive: true, force: true });
    refuse("admission holder launcher was unavailable or unsafe; command body was not executed");
  }
  const launcherExecutablePath = resolveNodeLauncherExecutable();
  if (!launcherExecutablePath) {
    fs.rmSync(admissionRoot, { recursive: true, force: true });
    refuse("admission holder launcher Node executable was unavailable or unsafe; use invoke-heavy-verifier.ps1 -Gate or -WorkspaceTest; command body was not executed");
  }
  const launcherEnvironment = { ...process.env };
  for (const name of [
    "NODE_OPTIONS",
    "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
    "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
    "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
    "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL",
    "CHASE_SETS_HEAVY_SLOT_ID",
    "CHASE_SETS_HEAVY_SLOT_TRANSPORT",
  ]) {
    delete launcherEnvironment[name];
  }

  let child;
  try {
    child = childProcess.spawn(
      launcherExecutablePath,
      [holderLauncherPath, admission.powershellPath, ...holderArguments],
      { detached: true, stdio: "ignore", windowsHide: true, env: launcherEnvironment },
    );
    // Atomics.wait below blocks delivery of this event. The listener prevents a
    // later unhandled throw; result publication remains the asynchronous authority.
    child.on("error", () => {});
    if (!Number.isInteger(child.pid) || child.pid < 1) {
      fs.rmSync(admissionRoot, { recursive: true, force: true });
      refuse("admission holder launcher did not publish a child pid; command body was not executed");
    }
    child.unref();
  } catch {
    fs.rmSync(admissionRoot, { recursive: true, force: true });
    refuse("admission holder launcher could not start; command body was not executed");
  }

  const started = performance.now();
  // Attach performs three eligibility censuses, each with at most one recheck.
  // Six maximum 30s budgets plus 30s total holder overhead is the hard ceiling.
  // A pending heartbeat carries the actual budget from the holder, not authority.
  const hardDeadline = started + 210000;
  let deadline = started + 15000;
  let pendingSequence = 0;
  const pendingPath = `${resultPath}.pending`;
  while (!fs.existsSync(resultPath) && performance.now() < deadline) {
    const now = performance.now();
    try {
      const stat = fs.lstatSync(pendingPath);
      if (stat.isFile() && !stat.isSymbolicLink() && stat.size <= 1024) {
        const pending = JSON.parse(fs.readFileSync(pendingPath, "utf8"));
        if (pending.schemaVersion === 1 && pending.nonce === nonce &&
            Number.isSafeInteger(pending.sequence) && pending.sequence > pendingSequence &&
            Number.isSafeInteger(pending.budgetMs) && pending.budgetMs > 0 && pending.budgetMs <= 210000) {
          pendingSequence = pending.sequence;
          deadline = Math.min(hardDeadline, now + pending.budgetMs + 15000);
        }
      }
    } catch {
      // Missing, partial or malformed progress cannot grant more waiting time.
    }
    sleep(20);
  }
  if (!fs.existsSync(resultPath)) {
    fs.rmSync(admissionRoot, { recursive: true, force: true });
    refuse("admission holder did not publish a result within its bounded census deadline; command body was not executed");
  }

  let result;
  let resultReadFailed = false;
  try {
    result = JSON.parse(fs.readFileSync(resultPath, "utf8"));
  } catch {
    resultReadFailed = true;
  } finally {
    fs.rmSync(admissionRoot, { recursive: true, force: true });
  }
  if (resultReadFailed) refuse("admission result was unreadable; command body was not executed");
  if (result.schemaVersion !== 1 || result.nonce !== nonce || typeof result.accepted !== "boolean") {
    refuse("admission result identity was invalid; command body was not executed");
  }
  if (!result.accepted) {
    refuse(`${result.message ?? "lock unavailable"}; command body was not executed`);
  }
  if (!lockIdShape.test(result.owner?.lockId ?? "")) {
    refuse("admission owner identity was invalid; command body was not executed");
  }
  process.env.CHASE_SETS_HEAVY_SLOT_ID = result.owner.lockId;
  // The attached result may carry the validated transport descriptor for this
  // process's descendants. It is transport only, never authority; a missing or
  // malformed descriptor simply leaves descendants to refuse fail-closed.
  const transport = validateTransportField(result.transport, result.owner.lockId);
  if (transport) process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT = transport;
  else delete process.env.CHASE_SETS_HEAVY_SLOT_TRANSPORT;
}

module.exports = acquire;
module.exports.launcherConfiguration = launcherConfiguration;
