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
  if (/^node(?:\.exe)?$/i.test(path.basename(process.execPath))) return process.execPath;
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

function liveOwnerMatchesToken(containerRoot, token, powershellPath) {
  if (!/^[a-f0-9]{32}$/.test(token)) return false;
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
  if (!/^[a-f0-9]{40}$/.test(head)) throw new Error("live Git HEAD was not an exact commit");
  const lane = path.basename(canonicalWorktree);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$/.test(lane)) throw new Error("worktree lane name is invalid");
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

function acquire(kind, options = {}) {
  if (!kinds.has(kind)) refuse("heavy kind was invalid; command body was not executed");
  const containerRoot = findContainerRoot();
  if (!containerRoot) refuse("container controller was not found; command body was not executed");
  const configuration = options.configuration;
  const powershellPath = resolvePowerShell(configuration);
  const token = process.env.CHASE_SETS_HEAVY_SLOT_ID;
  if (typeof token === "string" && liveOwnerMatchesToken(containerRoot, token, powershellPath)) return;

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
    refuse("admission holder launcher Node executable was unavailable or unsafe; command body was not executed");
  }
  const launcherEnvironment = { ...process.env };
  for (const name of [
    "NODE_OPTIONS",
    "CHASE_SETS_HEAVY_ADMISSION_CONFIG",
    "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS",
    "CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL",
    "CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL",
    "CHASE_SETS_HEAVY_SLOT_ID",
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

  const deadline = Date.now() + 15000;
  while (!fs.existsSync(resultPath) && Date.now() < deadline) sleep(20);
  if (!fs.existsSync(resultPath)) {
    fs.rmSync(admissionRoot, { recursive: true, force: true });
    refuse("admission holder did not publish a result within 15 seconds; command body was not executed");
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
  if (!/^[a-f0-9]{32}$/.test(result.owner?.lockId ?? "")) {
    refuse("admission owner identity was invalid; command body was not executed");
  }
  process.env.CHASE_SETS_HEAVY_SLOT_ID = result.owner.lockId;
}

module.exports = acquire;
