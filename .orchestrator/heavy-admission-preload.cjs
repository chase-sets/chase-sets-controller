"use strict";

// Derived admission mode keeps the preload on descendants; launcher mode
// restores the environment supplied by the dispatch configuration.
const childProcess = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");
const acquireHeavySlot = require("./heavy-slot.cjs");

const HEAVY_GATES = new Set([
  "verify:static",
  "check:static",
  "test:scripts",
  "verify:test",
  "test",
  "test:fast",
  "build",
  "verify",
  "verify:build",
  "verify:test-db",
]);
const E2E_SCRIPTS = new Set(["test:e2e", "test:e2e:deployed", "test:e2e:headed", "test:e2e:suite"]);
const E2E_SCRIPT_BASENAMES = new Set(["browser-e2e-probe.mjs"]);
const OPTION_VALUES = new Set([
  "--config",
  "-c",
  "--dir",
  "-C",
  "--filter",
  "-F",
  "--project",
  "--reporter",
  "--testNamePattern",
  "-t",
  "--testTimeout",
  "--maxWorkers",
  "--minWorkers",
  "--pool",
  "--shard",
]);

function tokenize(command) {
  return command.match(/"[^"]*"|'[^']*'|[^\s]+/g)?.map((token) => token.replace(/^(['"])(.*)\1$/, "$2")) ?? [];
}

function hasExactScriptBasename(command, basenames) {
  return command.split(/&&|\|\||;/).some((segment) =>
    tokenize(segment).some((token) => basenames.has(path.basename(token.replaceAll("\\", "/")).toLowerCase())),
  );
}

function hasExplicitTestFile(argumentsList) {
  for (let index = 0; index < argumentsList.length; index += 1) {
    const token = argumentsList[index];
    if (OPTION_VALUES.has(token)) {
      index += 1;
      continue;
    }
    if (token.startsWith("-")) continue;
    if (/\.(?:test|spec)\.[cm]?[jt]sx?$/i.test(token)) return true;
  }
  return false;
}

function isRegisteredSuiteInvocation(tokens) {
  const basename = (token) => path.basename((token ?? "").replaceAll("\\", "/")).toLowerCase();
  const executable = basename(tokens[0]);
  const script = /^(?:node|node\.exe)$/.test(executable) ? basename(tokens[1]) : executable;
  return script === "run-e2e-suite.mjs";
}

function classifyVitest(argumentsList) {
  const runIndex = argumentsList.findIndex((argument) => argument.toLowerCase() === "run");
  if (runIndex < 0) return null;
  return hasExplicitTestFile(argumentsList.slice(runIndex + 1)) ? null : "vitest-full";
}

function classifyPlaywright(argumentsList) {
  return argumentsList.some((argument) => argument.toLowerCase() === "test") ? "playwright" : null;
}

function nearestPackageJson(startDirectory, worktree) {
  let current = path.resolve(startDirectory);
  const boundary = path.resolve(worktree);
  while (current.toLowerCase().startsWith(boundary.toLowerCase())) {
    const candidate = path.join(current, "package.json");
    if (fs.existsSync(candidate)) return candidate;
    if (current.toLowerCase() === boundary.toLowerCase()) break;
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return null;
}

function isFilteredWorkspaceTest(argumentsList) {
  return argumentsList[0] === "--filter" && /^@chase-sets\/[a-z0-9-]+$/.test(argumentsList[1] ?? "") &&
    argumentsList[2] === "run" && argumentsList[3] === "test";
}

function isExecutedPnpm(tokens, index) {
  const executable = path.basename(tokens[0] ?? "").toLowerCase();
  if (index === 0) return executable === "pnpm" || executable === "pnpm.exe";
  return index === 1 && /^(?:node|node\.exe)$/.test(executable) &&
    /^pnpm\.(?:cjs|js|mjs)$/i.test(path.basename(tokens[1] ?? ""));
}

function classifyScriptText(command, packageScripts, seen, allowFilteredTest = true) {
  // The legacy splitter is not a shell parser. Quoted separators or incomplete
  // quotes cannot establish an executed position for the new form.
  const quotedText = /"[^"]*"|'[^']*'/g;
  allowFilteredTest = allowFilteredTest && !/["']/.test(command.replace(quotedText, "")) &&
    !(command.match(quotedText) ?? []).some((text) => /&&|\|\||;/.test(text));
  const lower = command.toLowerCase();
  if (command.split(/&&|\|\||;/).some((segment) => isRegisteredSuiteInvocation(tokenize(segment)))) return "playwright";
  if (/\bplaywright(?:\.cmd|\.js)?\s+test\b/i.test(command)) return "playwright";
  if (hasExactScriptBasename(command, E2E_SCRIPT_BASENAMES) || /\bdev-system\.mjs\b.*\bbrowser-e2e\b/i.test(command)) {
    return "script-battery";
  }
  if (/\brun-workspaces\.mjs\b\s+(?:test|test:unit|test:db|build)\b/i.test(command)) {
    return lower.includes("build") ? "build" : "script-battery";
  }
  if (/\breact-router-build\.mjs\b/i.test(command)) return "build";

  for (const segment of command.split(/&&|\|\||;/)) {
    const tokens = tokenize(segment);
    // Only the newly earned form needs this boundary; legacy kinds stay frozen.
    for (const index of [0, 1]) {
      if (allowFilteredTest && isExecutedPnpm(tokens, index) && isFilteredWorkspaceTest(tokens.slice(index + 1))) {
        return classifyPnpm(tokens.slice(index + 1), packageScripts, seen);
      }
    }
    const vitestIndex = tokens.findIndex((token) => /^(?:vitest|vitest\.(?:mjs|js|cmd))$/i.test(path.basename(token)));
    if (vitestIndex >= 0) {
      const result = classifyVitest(tokens.slice(vitestIndex + 1));
      if (result) return result;
    }
    const pnpmIndex = tokens.findIndex((token) => /^(?:pnpm|pnpm\.(?:cjs|js|cmd|exe))$/i.test(path.basename(token)));
    if (pnpmIndex >= 0) {
      const result = classifyPnpm(tokens.slice(pnpmIndex + 1), packageScripts, seen,
        allowFilteredTest && isExecutedPnpm(tokens, pnpmIndex));
      // A newly classified browser alias must be executed, not passed as data.
      if (result === "playwright" && pnpmIndex !== 0 &&
          !(pnpmIndex === 1 && /^(?:node|node\.exe)$/i.test(path.basename(tokens[0])))) continue;
      if (result) return result;
    }
  }
  return null;
}

function classifyPnpm(argumentsList, packageScripts = {}, seen = new Set(), allowFilteredTest = true) {
  if (allowFilteredTest && isFilteredWorkspaceTest(argumentsList)) return "script-battery";
  const lowered = argumentsList.map((argument) => argument.toLowerCase());
  let commandIndex = 0;
  while (commandIndex < argumentsList.length) {
    if (OPTION_VALUES.has(argumentsList[commandIndex])) commandIndex += 2;
    else if (argumentsList[commandIndex].startsWith("-")) commandIndex += 1;
    else break;
  }
  const execIndex = lowered.findIndex((argument) => argument === "exec" || argument === "dlx");
  if (execIndex >= 0) {
    if (execIndex === commandIndex && isRegisteredSuiteInvocation(argumentsList.slice(execIndex + 1))) return "playwright";
    const executable = path.basename(lowered[execIndex + 1] ?? "");
    if (/^playwright(?:\.cmd|\.js)?$/.test(executable)) return classifyPlaywright(argumentsList.slice(execIndex + 2));
    if (/^vitest(?:\.mjs|\.js|\.cmd)?$/.test(executable)) return classifyVitest(argumentsList.slice(execIndex + 2));
  }

  let runIndex = lowered.findIndex((argument) => argument === "run" || argument === "run-script");
  let directCommand = null;
  if (runIndex < 0) {
    for (let index = 0; index < argumentsList.length; index += 1) {
      if (OPTION_VALUES.has(argumentsList[index])) {
        index += 1;
        continue;
      }
      if (argumentsList[index].startsWith("-")) continue;
      directCommand = argumentsList[index];
      break;
    }
  }
  const scriptName = runIndex >= 0 ? argumentsList[runIndex + 1] : directCommand;
  if (!scriptName) return null;
  if (HEAVY_GATES.has(scriptName)) {
    if (scriptName === "build" || scriptName === "verify:build") return "build";
    if (scriptName === "test:scripts") return "script-battery";
    return "repository-gate";
  }
  const scriptIsExecuted = runIndex < 0 || runIndex === commandIndex;
  if (E2E_SCRIPTS.has(scriptName)) return scriptIsExecuted ? "playwright" : null;
  if (seen.has(scriptName)) return null;
  const script = packageScripts[scriptName];
  if (typeof script !== "string") return null;
  seen.add(scriptName);
  const result = classifyScriptText(script, packageScripts, seen, allowFilteredTest && scriptIsExecuted);
  return result === "playwright" && !scriptIsExecuted ? null : result;
}

function classifyCommand(argv, options = {}) {
  const runtimeExecutable = path.basename(argv[0] ?? "").toLowerCase();
  const packagedPnpm = runtimeExecutable === "pnpm.exe";
  const executableScript = path.basename(argv[1] ?? "").toLowerCase();
  const argumentsList = packagedPnpm ? argv.slice(1) : argv.slice(2);
  const normalizedScriptPath = (argv[1] ?? "").replaceAll("\\", "/").toLowerCase();
  let packageScripts = options.packageScripts;
  if (!packageScripts) {
    try {
      const packagePath = nearestPackageJson(options.cwd ?? process.cwd(), options.worktree ?? process.cwd());
      packageScripts = packagePath ? JSON.parse(fs.readFileSync(packagePath, "utf8")).scripts ?? {} : {};
    } catch {
      packageScripts = {};
    }
  }

  if (packagedPnpm || /^(?:pnpm|pnpm\.cjs|pnpm\.mjs|pnpm\.js|pnpm\.exe)$/.test(executableScript) || normalizedScriptPath.includes("/pnpm/dist/pnpm.cjs")) {
    const nodeScriptMode = !(options.execArgv ?? []).some((argument) => /^(?:--(?:eval|print)(?:=|$)|-[ep])/.test(argument));
    const packagedArguments = packagedPnpm && path.resolve(argv[1] ?? "") === path.resolve(argv[0])
      ? argv.slice(2) : argumentsList;
    if (packagedPnpm && isFilteredWorkspaceTest(packagedArguments)) return "script-battery";
    return classifyPnpm(argumentsList, packageScripts, new Set(),
      (packagedPnpm || nodeScriptMode) && isExecutedPnpm(argv, packagedPnpm ? 0 : 1));
  }
  if (/^(?:npx-cli\.js|npm-cli\.js)$/.test(executableScript)) {
    const commandIndex = argumentsList.findIndex((argument) => !argument.startsWith("-"));
    const command = path.basename((argumentsList[commandIndex] ?? "").toLowerCase());
    if (command.startsWith("playwright")) return classifyPlaywright(argumentsList.slice(commandIndex + 1));
    if (command.startsWith("vitest")) return classifyVitest(argumentsList.slice(commandIndex + 1));
  }
  if (normalizedScriptPath.includes("/playwright/") || normalizedScriptPath.includes("/@playwright/") || /^playwright(?:\.js|\.mjs)?$/.test(executableScript)) {
    return classifyPlaywright(argumentsList);
  }
  if (normalizedScriptPath.includes("/vitest/") || /^vitest(?:\.js|\.mjs)?$/.test(executableScript)) {
    return classifyVitest(argumentsList);
  }
  if (/run-workspaces\.mjs$/i.test(executableScript) && /^(?:test|test:unit|test:db|build)$/i.test(argumentsList[0] ?? "")) {
    return argumentsList[0].toLowerCase() === "build" ? "build" : "script-battery";
  }
  if (/react-router-build\.mjs$/i.test(executableScript)) return "build";
  if (executableScript === "run-e2e-suite.mjs") return "playwright";
  if (E2E_SCRIPT_BASENAMES.has(executableScript)) return "script-battery";
  if (/dev-system\.mjs$/i.test(executableScript) && argumentsList.some((argument) => argument.toLowerCase() === "browser-e2e")) {
    return "script-battery";
  }
  return null;
}

function restoreOriginalNodeEnvironment(config) {
  // Closed host gates keep admission on every lifecycle and Node descendant.
  // This retains transport only; the exact wrapper still decides every call.
  if (config.retainAdmission === true) return;
  if (config.originalNodeOptionsPresent) process.env.NODE_OPTIONS = config.originalNodeOptions;
  else delete process.env.NODE_OPTIONS;
  if (config.originalScriptShellPresent) process.env.npm_config_script_shell = config.originalScriptShell;
  else delete process.env.npm_config_script_shell;
  delete process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG;
  delete process.env.CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_NODE_OPTIONS;
  delete process.env.CHASE_SETS_HEAVY_ADMISSION_ORIGINAL_SCRIPT_SHELL;
  delete process.env.CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL;
}

function refuse(message) {
  process.stderr.write(`heavy-admission: ${message}\n`);
  process.exit(73);
}

function runAdmission(kind, config) {
  acquireHeavySlot(kind, { configuration: config });
  restoreOriginalNodeEnvironment(config);
}

function packageScriptsFor(config) {
  const packagePath = nearestPackageJson(process.cwd(), config.worktree);
  if (!packagePath) return {};
  return JSON.parse(fs.readFileSync(packagePath, "utf8")).scripts ?? {};
}

function classifyLifecycleScript(config) {
  const scriptName = process.env.npm_lifecycle_event ?? "";
  const command = process.env.npm_lifecycle_script ?? "";
  const packageScripts = packageScriptsFor(config);
  return classifyPnpm(["run", scriptName], packageScripts) || classifyScriptText(command, packageScripts, new Set());
}

function runLifecycleScriptShell(config) {
  const command = process.env.npm_lifecycle_script;
  if (typeof command !== "string" || command.length === 0) {
    refuse("pnpm lifecycle command was unavailable; command body was not executed");
  }

  let kind;
  try {
    kind = classifyLifecycleScript(config);
  } catch {
    refuse("pnpm lifecycle classification failed; command body was not executed");
  }
  if (kind) runAdmission(kind, config);

  const originalShell = config.originalScriptShellPresent ? config.originalScriptShell : process.env.ComSpec || "cmd.exe";
  const result = childProcess.spawnSync(command, {
    cwd: process.cwd(),
    env: process.env,
    shell: originalShell,
    stdio: "inherit",
    windowsHide: true,
  });
  if (result.error) {
    refuse("pnpm lifecycle shell failed to start; command body was not executed");
  }
  process.exit(result.status ?? 74);
}

function main() {
  const encoded = process.env.CHASE_SETS_HEAVY_ADMISSION_CONFIG;
  if (!Object.hasOwn(process.env, "CHASE_SETS_HEAVY_ADMISSION_CONFIG")) {
    const cwd = process.cwd();
    const kind = classifyCommand(process.argv, { cwd, worktree: cwd, execArgv: process.execArgv });
    if (!kind) return;
    if (!process.env.CHASE_SETS_HEAVY_SLOT_ID) {
      const result = childProcess.spawnSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
        encoding: "utf8",
        windowsHide: true,
      });
      const worktree = result.status === 0 ? path.resolve(result.stdout.trim()) : null;
      // Both modules are colocated with the container's admission guard.
      const containerPrefix = `${path.resolve(__dirname, "..")}${path.sep}`.toLowerCase();
      if (
        !worktree ||
        !worktree.toLowerCase().startsWith(containerPrefix) ||
        path.basename(worktree).toLowerCase() === "main"
      ) {
        // This fixed-size root fingerprint suppresses only repeat diagnostics, never admission.
        const warningRoot = require("node:crypto").createHash("sha256")
          .update((worktree ?? path.resolve(cwd)).toLowerCase()).digest("hex");
        if (process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT !== warningRoot) {
          process.stderr.write(`heavy-admission: unguarded heavy command outside a lane worktree (${cwd})\n`);
        }
        process.env.CHASE_SETS_HEAVY_ADMISSION_WARNED_ROOT = warningRoot;
        return;
      }
    }
    acquireHeavySlot(kind, {});
    return;
  }
  const config = acquireHeavySlot.launcherConfiguration(encoded, { useForAcquisition: true });
  if (
    process.env.CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL === "node-check-proxy" &&
    process.execArgv.some((argument) => argument === "-c" || argument === "--check")
  ) {
    runLifecycleScriptShell(config);
  }
  let kind;
  try {
    kind = classifyCommand(process.argv, { cwd: process.cwd(), worktree: config.worktree, execArgv: process.execArgv });
  } catch {
    refuse("heavy-command classification failed; command body was not executed");
  }
  if (kind) runAdmission(kind, config);
}

module.exports = {
  HEAVY_GATES,
  E2E_SCRIPTS,
  classifyCommand,
  classifyPnpm,
  classifyScriptText,
  classifyVitest,
};

main();
