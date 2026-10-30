import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, mkdirSync, realpathSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Reviewed bytes published by the controller release; the host declaration pins
// their SHA-256. Copy this file unchanged into the seat before admission.
const root = "D:/Users/ToddS/Source/Repos/chase-sets/20261029-10761-impl-g1";
const branch = "codex/10761-impl-g1";
const selectors = "census work stays source-bounded|derives the exact real census and execution partition";
const resultPath = fileURLToPath(import.meta.url).replace(/\.mjs$/, ".result.json");
// Descendant temporary and compile-cache writes stay in the seat's ignored .tmp/.
const scratchRelative = { temp: ".tmp/10761-json-census/tmp", compileCache: ".tmp/10761-json-census/compile-cache" };
const scratchVariables = ["TEMP", "TMP", "TMPDIR", "NODE_COMPILE_CACHE"];
const receipt = { schema: "json-census-five-run/v1", admissionIdentity: null, exactHead: null, runs: [], exit: 1 };

const env = { ...process.env };
for (const key of Object.keys(env)) {
  if (key.toUpperCase() === "CHASE_SETS_LANE_MODE") delete env[key];
}

function command(executable, args, timeout = 30_000) {
  const child = spawnSync(executable, args, {
    cwd: root,
    env,
    encoding: "utf8",
    timeout,
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });
  if (child.error || child.signal || child.status !== 0) {
    throw new Error(`${executable} failed: ${child.error?.message ?? child.signal ?? child.status}\n${child.stderr ?? ""}`);
  }
  return child.stdout.trim();
}

// Creates one segment at a time and refuses any segment that is not a plain
// directory, so a junction or symbolic link cannot redirect writes outside the seat.
function seatScratchDirectory(relative) {
  const assertPlain = (directory) => {
    const stat = lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || realpathSync.native(directory).toLowerCase() !== directory.toLowerCase()) {
      throw new Error(`Seat scratch path is not a plain directory: ${directory}`);
    }
  };
  let current = path.resolve(root);
  assertPlain(current);
  for (const segment of relative.split("/")) {
    current = path.join(current, segment);
    if (!existsSync(current)) mkdirSync(current);
    assertPlain(current);
  }
  command("git", ["check-ignore", "-q", "--", `${relative}/`]);
  return current;
}

try {
  const config = JSON.parse(Buffer.from(process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG ?? "", "base64").toString("utf8"));
  const slot = process.env.CHASE_SETS_HEAVY_SLOT_ID;
  const head = config.diagnostic?.boundHead;
  if (process.env.CHASE_SETS_HEAVY_ADMITTED !== "1" || !slot || !/^[a-f0-9]{40}$/.test(head ?? "")) {
    throw new Error("Missing real heavy-verifier admission identity or bound head");
  }
  if (path.resolve(config.worktree).toLowerCase() !== path.resolve(root).toLowerCase() || config.head !== head || config.branch !== branch) {
    throw new Error("Admission worktree/branch/head does not match this lane");
  }
  receipt.admissionIdentity = { slotId: slot, lane: config.lane, worktree: config.worktree, boundHead: head };
  receipt.exactHead = head;

  const assertHead = () => {
    if (command("git", ["rev-parse", "HEAD"]) !== head || command("git", ["branch", "--show-current"]) !== branch) {
      throw new Error("Seat moved away from the admitted exact head");
    }
    if (command("git", ["status", "--porcelain"]) !== "") throw new Error("Seat is not clean");
  };
  assertHead();
  const pushed = command("git", ["ls-remote", "--exit-code", "origin", `refs/heads/${branch}`]).split(/\s+/)[0];
  if (pushed !== head) throw new Error("Admitted head is not the pushed branch head");

  const tempDirectory = seatScratchDirectory(scratchRelative.temp);
  const compileCacheDirectory = seatScratchDirectory(scratchRelative.compileCache);
  // Windows environment names are case-insensitive: drop every inherited case variant.
  for (const key of Object.keys(env)) {
    if (scratchVariables.includes(key.toUpperCase())) delete env[key];
  }
  env.TEMP = tempDirectory;
  env.TMP = tempDirectory;
  env.TMPDIR = tempDirectory;
  env.NODE_COMPILE_CACHE = compileCacheDirectory;

  for (let run = 1; run <= 5; run += 1) {
    assertHead();
    // Direct Windows Node launch avoids trying to execute a .cmd as a PE binary.
    // The exact inherited admission preload/configuration remains in env.
    const child = spawnSync(process.execPath, [
      path.join(root, "node_modules/vitest/vitest.mjs"),
      "run", "--config", "./vitest.scripts.config.mjs",
      "scripts/check-structure/json-import-attributes.test.mjs",
      "-t", selectors, "--reporter=verbose",
    ], { cwd: root, env, encoding: "utf8", timeout: 115_000, maxBuffer: 64 * 1024 * 1024, windowsHide: true });
    const output = `${child.stdout ?? ""}\n${child.stderr ?? ""}`;
    process.stdout.write(output);
    const censusReceipts = output.split(/\r?\n/).filter((line) => line.includes('"censusWork"')).map((line) => JSON.parse(line.slice(line.indexOf("{"))).censusWork);
    const census = censusReceipts.length === 1 ? censusReceipts[0] : null;
    const runReceipt = {
      run, admissionIdentity: receipt.admissionIdentity, exactHead: head,
      exit: child.status ?? 1, signal: child.signal, error: child.error?.message ?? null,
      invocations: census?.invocations ?? null, hookDurationMs: census?.hookDurationMs ?? null,
    };
    receipt.runs.push(runReceipt);
    console.log(`CENSUS_RUN ${JSON.stringify(runReceipt)}`);
    // Duration is informational: require a receipt value, never compare it to a budget.
    if (child.error || child.signal || child.status !== 0 || census?.invocations !== 1 || !Number.isFinite(census?.hookDurationMs)) {
      throw new Error(`Admitted run ${run} was red or lacked the required receipt; stopping immediately`);
    }
    assertHead();
  }
  receipt.exit = 0;
} catch (error) {
  receipt.error = error.message;
  console.error(error.message);
} finally {
  writeFileSync(resultPath, `${JSON.stringify(receipt, null, 2)}\n`, { flag: "wx" });
  process.exitCode = receipt.exit;
}
