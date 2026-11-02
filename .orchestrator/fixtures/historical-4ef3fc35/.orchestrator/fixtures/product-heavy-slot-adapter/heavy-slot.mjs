import { existsSync, lstatSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const guardModulePath = fileURLToPath(import.meta.url);
const guardDirectory = path.dirname(guardModulePath);
const testFilePattern = /\.(?:test|spec)\.[cm]?[jt]sx?$/i;

function isRegularFile(candidate) {
  try {
    const stat = lstatSync(candidate);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch {
    return false;
  }
}

export function findHeavySlotClient(startDirectory = guardDirectory) {
  let current = path.resolve(startDirectory);
  while (true) {
    const orchestrator = path.join(current, ".orchestrator");
    const verifier = path.join(orchestrator, "invoke-heavy-verifier.ps1");
    const client = path.join(orchestrator, "heavy-slot.cjs");
    if (isRegularFile(verifier) && isRegularFile(client)) {
      return client;
    }
    const parent = path.dirname(current);
    if (parent === current) return null;
    current = parent;
  }
}

export function acquireHeavySlot(kind, options = {}) {
  const client = findHeavySlotClient(options.startDirectory);
  if (!client) return false;
  require(client)(kind);
  return true;
}

function explicitTestFile(filter, root) {
  const withoutLine = filter.replace(/:\d+$/, "");
  if (!testFilePattern.test(withoutLine)) return false;
  const candidate = path.isAbsolute(withoutLine) ? withoutLine : path.resolve(root, withoutLine);
  return existsSync(candidate);
}

export function isFocusedVitestFileRun(project) {
  const filters = project?.vitest?.filenamePattern;
  const root = project?.config?.root;
  return (
    Array.isArray(filters) &&
    filters.length > 0 &&
    typeof root === "string" &&
    project.config.watch === false &&
    filters.every((filter) => typeof filter === "string" && explicitTestFile(filter, root))
  );
}

export function isDatabaseVitestRun(env = process.env) {
  const lifecycleEvent = env.npm_lifecycle_event;
  return (
    (typeof lifecycleEvent === "string" && /^test:db(?::.+)?$/.test(lifecycleEvent)) ||
    (typeof env.TEST_DATABASE_URL === "string" && env.TEST_DATABASE_URL.length > 0)
  );
}

export function acquireVitestHeavySlot(project, kind = "vitest-full", options = {}) {
  const { env = process.env, ...acquisitionOptions } = options;
  if (!isDatabaseVitestRun(env) && isFocusedVitestFileRun(project)) return false;
  return acquireHeavySlot(kind, acquisitionOptions);
}

export const heavySlotVitestGlobalSetupPath = guardModulePath;

export default function setupHeavySlot(project) {
  acquireVitestHeavySlot(project);
}
