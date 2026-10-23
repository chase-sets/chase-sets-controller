"use strict";

// Derived admission mode keeps the preload on descendants; launcher mode
// restores the environment supplied by the dispatch configuration.
const childProcess = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const moduleApi = require("node:module");
const path = require("node:path");
const { fileURLToPath } = require("node:url");
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

function installDiagnosticModulePolicy(config, encodedConfiguration) {
  const diagnostic = config?.diagnostic;
  if (!diagnostic) return;
  if (diagnostic.kind !== "standalone-node") refuse("diagnostic declaration kind was not standalone-node");
  if (typeof moduleApi.registerHooks !== "function") refuse("diagnostic module hooks are unavailable");
  const worktree = path.resolve(diagnostic.worktree ?? config.worktree);
  const entry = path.resolve(diagnostic.entry ?? "");
  const manifestPrefix = path.resolve(diagnostic.moduleManifestPath ?? "");
  const boundHead = String(diagnostic.boundHead ?? "");
  const entrySha256 = String(diagnostic.entrySha256 ?? "").toLowerCase();
  if (!/^[a-f0-9]{40}$/.test(boundHead) || !/^[a-f0-9]{64}$/.test(entrySha256) || !entry || !manifestPrefix) {
    refuse("diagnostic module policy configuration was invalid");
  }
  let tracked;
  try {
    const output = childProcess.execFileSync("git", ["-C", worktree, "ls-tree", "-r", "-z", "--name-only", boundHead], {
      windowsHide: true,
      stdio: ["ignore", "pipe", "ignore"],
    });
    tracked = new Set(output.toString("utf8").split("\0").filter(Boolean).map((value) => value.replaceAll("\\", "/")));
  } catch {
    refuse("diagnostic tracked-file inventory was unavailable");
  }

  const samePath = (left, right) => path.resolve(left).toLowerCase() === path.resolve(right).toLowerCase();
  const inside = (root, candidate) => {
    const relative = path.relative(root, candidate);
    return relative !== "" && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
  };
  const isNodeModulesFile = (candidate) => {
    if (!inside(worktree, candidate)) return false;
    const relative = path.relative(worktree, candidate).split(path.sep);
    for (let index = 0; index < relative.length; index += 1) {
      if (relative[index].toLowerCase() !== "node_modules") continue;
      if (index === 0) return true;
      const packageRoot = path.resolve(worktree, ...relative.slice(0, index));
      const packageJson = path.relative(worktree, path.join(packageRoot, "package.json")).replaceAll("\\", "/");
      if (tracked.has(packageJson)) return true;
    }
    return false;
  };
  const manifestPath = `${manifestPrefix}-${process.pid}.json`;
  const digestBytes = (bytes) => crypto.createHash("sha256").update(bytes).digest("hex");
  const loadedSourceBytes = (source, actual) => {
    if (source === null || typeof source === "undefined") {
      // CommonJS nextLoad returns null source; only that case falls back to file bytes.
      return fs.readFileSync(actual);
    }
    if (typeof source === "string" || Buffer.isBuffer(source)) return Buffer.from(source);
    if (ArrayBuffer.isView(source)) return Buffer.from(source.buffer, source.byteOffset, source.byteLength);
    if (source instanceof ArrayBuffer) return Buffer.from(source);
    refuse(`diagnostic module source had an unsupported type: ${actual}`);
  };
  const modules = new Map();
  const writeManifest = () => {
    fs.writeFileSync(manifestPath, JSON.stringify({ schema: "host-heavy-diagnostic-modules/v1", modules: [...modules.values()] }), {
      encoding: "utf8",
    });
  };
  const authorize = (url) => {
    if (url.startsWith("node:")) return null;
    if (!url.startsWith("file:")) refuse(`diagnostic module URL was not a file: ${url}`);
    let requested;
    let actual;
    try {
      requested = fileURLToPath(url);
      actual = fs.realpathSync.native(requested);
    } catch {
      refuse(`diagnostic module could not be resolved: ${url}`);
    }
    if (!samePath(actual, entry) &&
        (!inside(worktree, actual) || (!isNodeModulesFile(actual) && !tracked.has(path.relative(worktree, actual).replaceAll("\\", "/"))))) {
      refuse(`diagnostic module was not tracked at the bound head or under an admitted node_modules directory: ${actual}`);
    }
    return actual;
  };
  const record = (url, source) => {
    const actual = authorize(url);
    if (!actual || modules.has(actual)) return;
    const sha256 = digestBytes(loadedSourceBytes(source, actual));
    if (samePath(actual, entry) && sha256 !== entrySha256) {
      refuse("declared diagnostic entry changed before evaluation");
    }
    modules.set(actual, { module: actual, path: actual, sha256 });
    writeManifest();
  };
  moduleApi.registerHooks({
    resolve(specifier, context, nextResolve) {
      const result = nextResolve(specifier, context);
      authorize(result.url);
      return result;
    },
    load(url, context, nextLoad) {
      const result = nextLoad(url, context);
      record(url, result.source);
      return result;
    },
  });

  const preloadPath = path.resolve(__filename).replaceAll("\\", "/").toLowerCase();
  const unquote = (value) => value.replace(/"([^"]*)"|'([^']*)'/g, (_match, double, single) => double ?? single);
  // Tokenize NODE_OPTIONS and require a --require/-r whose operand is exactly this preload.
  const hasDiagnosticPreload = (nodeOptions) => {
    if (typeof nodeOptions !== "string") return false;
    const tokens = nodeOptions.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) ?? [];
    const isPreload = (operand) => path.resolve(unquote(operand)).replaceAll("\\", "/").toLowerCase() === preloadPath;
    for (let index = 0; index < tokens.length; index += 1) {
      const token = tokens[index];
      const assigned = /^--require=(.+)$/s.exec(token);
      if (assigned && isPreload(assigned[1])) return true;
      if ((token === "--require" || token === "-r") && index + 1 < tokens.length && isPreload(tokens[index + 1])) return true;
    }
    return false;
  };
  // The host sets a preload-only NODE_OPTIONS for diagnostics. Children must carry
  // that exact string: parsing a caller-built string is never trusted.
  const requiredNodeOptions = process.env.NODE_OPTIONS;
  if (!hasDiagnosticPreload(requiredNodeOptions)) refuse("diagnostic NODE_OPTIONS did not carry the diagnostic preload");
  const isPlainObject = (candidate) => candidate !== null && typeof candidate === "object" && !Array.isArray(candidate);
  // exec/execSync take (command, [options], [callback]); the others take
  // (command, [args], [options], [callback]). Only the slot Node itself reads counts:
  // an object anywhere else is ignored by Node, so checking it would prove nothing.
  const optionsIndex = (method, argumentsList) => {
    if (method === "exec" || method === "execSync") return isPlainObject(argumentsList[1]) ? 1 : -1;
    if (isPlainObject(argumentsList[1])) return 1;
    const argsSlot = argumentsList[1];
    if ((Array.isArray(argsSlot) || argsSlot === undefined || argsSlot === null) && isPlainObject(argumentsList[2])) return 2;
    return -1;
  };
  const refuseChildLaunch = (reason) => {
    throw Object.assign(new Error(`heavy-admission: diagnostic child process launch refused because ${reason}`), {
      code: "ERR_HEAVY_DIAGNOSTIC_CHILD_REFUSED",
    });
  };
  const guardedMethods = ["spawn", "spawnSync", "exec", "execSync", "execFile", "execFileSync", "fork"];
  // Where options go when the caller passed none: exec/execSync take them at 1;
  // the others take them after an args array, otherwise at 1.
  const optionsSlot = (method, argumentsList) => {
    if (method === "exec" || method === "execSync") return 1;
    return Array.isArray(argumentsList[1]) ? 2 : 1;
  };
  // Null-prototype copies: no inherited setter can drop a write and no inherited
  // getter can answer a later read, so the guard and Node see the same values.
  const snapshotEnvironment = (source) => {
    const copy = Object.create(null);
    for (const key in source) copy[key] = source[key];
    return copy;
  };
  for (const method of guardedMethods) {
    const original = childProcess[method];
    childProcess[method] = function guardedDiagnosticLaunch(...argumentsList) {
      let index = optionsIndex(method, argumentsList);
      const requested = index >= 0 ? argumentsList[index] : undefined;
      if (index < 0) {
        // Always hand Node explicit options so it never falls back to process.env
        // or an inherited options.env.
        index = optionsSlot(method, argumentsList);
        if (argumentsList[index] !== undefined && argumentsList[index] !== null) argumentsList.splice(index, 0, undefined);
      }
      // Snapshot once and hand Node the same data the guard checked. Getters and
      // proxies are read exactly once and Node receives plain own values.
      const snapshot = Object.assign(Object.create(null), requested);
      const requestedEnvironment = requested === undefined ? undefined : requested.env;
      if (requestedEnvironment !== undefined && requestedEnvironment !== null && typeof requestedEnvironment !== "object") {
        refuseChildLaunch("the child environment was not an object");
      }
      // Node uses options.env || process.env and enumerates it with for...in.
      const environment = snapshotEnvironment(requestedEnvironment || process.env);
      snapshot.env = environment;
      argumentsList[index] = snapshot;
      // Node writes each entry as key=value, so a key such as "NODE_OPTIONS=x" or a
      // differently cased duplicate would become a second guarded variable.
      for (const key of Object.keys(environment)) {
        const upper = key.toUpperCase();
        if (key.indexOf("=", 1) !== -1) refuseChildLaunch("a child environment key contained '='");
        if ((upper === "NODE_OPTIONS" || upper === "CHASE_SETS_HEAVY_ADMISSION_CONFIG") && key !== upper) {
          refuseChildLaunch("a child environment key duplicated a guarded variable in another case");
        }
      }
      if (environment.NODE_OPTIONS !== requiredNodeOptions) refuseChildLaunch("NODE_OPTIONS lacks the diagnostic preload");
      // A child without the exact admission configuration would take the
      // unconfigured preload branch and load modules without the policy.
      if (environment.CHASE_SETS_HEAVY_ADMISSION_CONFIG !== encodedConfiguration) {
        refuseChildLaunch("the diagnostic admission configuration was not inherited");
      }
      return original.apply(this, argumentsList);
    };
  }
  // Every child_process route, including new ChildProcess().spawn and a reused child
  // handle, ends in one of these two native calls. Check the environment block the
  // operating system will receive, copied once, and hand exactly that copy to Node.
  const originalBinding = process.binding;
  const guardedVariables = new Map([
    ["NODE_OPTIONS", ["NODE_OPTIONS lacks the diagnostic preload", requiredNodeOptions]],
    ["CHASE_SETS_HEAVY_ADMISSION_CONFIG", ["the diagnostic admission configuration was not inherited", encodedConfiguration]],
  ]);
  const checkEnvironmentPairs = (pairs) => {
    if (!Array.isArray(pairs)) refuseChildLaunch("the child environment block was not an array");
    const length = pairs.length;
    const copy = [];
    for (let index = 0; index < length; index += 1) copy.push(String(pairs[index]));
    const seen = new Map();
    for (const pair of copy) {
      // Windows keeps per-drive entries such as "=C:=C:\\"; a name never starts at "=".
      const separator = pair.indexOf("=", 1);
      const name = separator === -1 ? pair : pair.slice(0, separator);
      const upper = name.toUpperCase();
      if (!guardedVariables.has(upper)) continue;
      if (seen.has(upper)) refuseChildLaunch(`the child environment block named ${upper} more than once`);
      seen.set(upper, { name, value: separator === -1 ? undefined : pair.slice(separator + 1) });
    }
    for (const [name, [reason, required]] of guardedVariables) {
      const entry = seen.get(name);
      if (!entry || entry.name !== name || entry.value !== required) refuseChildLaunch(reason);
    }
    return copy;
  };
  const guardNativeSpawn = (owner, label) => {
    const nativeSpawn = owner.spawn;
    owner.spawn = function guardedNativeSpawn(...argumentsList) {
      // spawn_sync and older Node 24 process_wrap take one options object.
      if (argumentsList.length === 1) {
        const options = argumentsList[0];
        if (options === null || typeof options !== "object") refuseChildLaunch(`${label} options were not an object`);
        if (Array.isArray(options)) refuseChildLaunch(`${label} options were an array`);
        const snapshot = Object.assign(Object.create(null), options);
        snapshot.envPairs = checkEnvironmentPairs(snapshot.envPairs);
        return nativeSpawn.call(this, snapshot);
      }
      // Newer Node 24 process_wrap takes (file, args, cwd, envPairs, stdio,
      // flags, uid, gid). Never infer an environment slot from an unknown ABI.
      const optionalString = (value) => value === undefined || value === null || typeof value === "string";
      const uint32 = (value) => Number.isInteger(value) && value >= 0 && value <= 0xffffffff;
      const optionalId = (value) => value === undefined || value === null || uint32(value);
      if (label === "process_wrap" && argumentsList.length === 8 &&
          typeof argumentsList[0] === "string" &&
          (argumentsList[1] === undefined || Array.isArray(argumentsList[1])) &&
          optionalString(argumentsList[2]) && Array.isArray(argumentsList[4]) &&
          uint32(argumentsList[5]) && optionalId(argumentsList[6]) && optionalId(argumentsList[7])) {
        argumentsList[3] = checkEnvironmentPairs(argumentsList[3]);
        return nativeSpawn.apply(this, argumentsList);
      }
      refuseChildLaunch(`${label} call shape was not recognized`);
    };
  };
  guardNativeSpawn(originalBinding.call(process, "process_wrap").Process.prototype, "process_wrap");
  guardNativeSpawn(originalBinding.call(process, "spawn_sync"), "spawn_sync");
  if (typeof process.execve === "function") {
    process.execve = function refusedDiagnosticExecve() {
      refuseChildLaunch("process.execve is not available to diagnostics");
    };
  }
  // Diagnostics have no use for the raw spawn bindings themselves.
  process.binding = function guardedDiagnosticBinding(name) {
    const requestedBinding = String(name);
    if (requestedBinding === "spawn_sync" || requestedBinding === "process_wrap") {
      refuseChildLaunch(`process.binding('${requestedBinding}') is not available to diagnostics`);
    }
    return originalBinding.call(this, requestedBinding);
  };
  const workerThreads = require("node:worker_threads");
  const RefusedWorker = function RefusedWorker() {
    throw Object.assign(new Error("heavy-admission: diagnostic Worker launch refused"), {
      code: "ERR_HEAVY_DIAGNOSTIC_WORKER_REFUSED",
    });
  };
  Object.defineProperty(workerThreads, "Worker", { configurable: true, writable: true, value: RefusedWorker });
  // ESM named imports of builtins read a synced snapshot; publish the guards to them.
  moduleApi.syncBuiltinESMExports();
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
  installDiagnosticModulePolicy(config, encoded);
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
