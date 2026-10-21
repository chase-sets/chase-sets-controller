import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
import fs from "node:fs";
import path, { join } from "node:path";

const args = process.argv.slice(2);
const pnpmIndex = args.indexOf("--pnpm-script");
const fileIndex = args.indexOf("--file");
if (pnpmIndex !== 0 || !args[1] || (fileIndex >= 0 && (fileIndex !== 2 || !args[3] || args.length !== 4))) {
  process.stderr.write("workspace-db-test: invalid fixed runner arguments\n");
  process.exitCode = 2;
  process.exit();
}

const pnpm = path.resolve(args[1]);
const repositoryRoot = process.cwd();
const workspace = "@chase-sets/payments";
const workspaceDirectory = path.join(repositoryRoot, "bounded-contexts", "payments");
const workspaceFile = fileIndex >= 0 ? args[3].replaceAll("\\", "/") : null;
const runWorkspacesPath = join(repositoryRoot, "scripts", "run-workspaces.mjs");

function run(executable, commandArguments) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, commandArguments, {
      cwd: repositoryRoot,
      env: { ...process.env, npm_execpath: pnpm },
      stdio: "inherit",
      windowsHide: true,
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve(signal ? 1 : (code ?? 1)));
  });
}

const preflight = await run(process.execPath, [path.join(repositoryRoot, "scripts", "db-test-preflight.mjs")]);
if (preflight !== 0) {
  process.stderr.write("workspace-db-test: DB preflight failed; refusing workspace DB test route\n");
  process.exitCode = 73;
}
else if (workspaceFile) {
  const relativeToWorkspace = workspaceFile.slice("bounded-contexts/payments/".length);
  let runWorkspaces;
  try {
    runWorkspaces = await import(pathToFileURL(runWorkspacesPath).href);
  } catch (error) {
    process.stderr.write(`workspace-db-test: could not load product test environment: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
  if (runWorkspaces) {
    if (typeof runWorkspaces.loadTestEnvironment !== "function") {
      process.stderr.write("workspace-db-test: product runner does not export loadTestEnvironment; refusing file test without test environment\n");
      process.exitCode = 1;
    } else {
      try {
        await runWorkspaces.loadTestEnvironment({ includeTestDatabaseUrl: true });
        process.exitCode = await run(process.execPath, [pnpm, "--config.verify-deps-before-run=false", "--dir", workspaceDirectory, "exec", "vitest", "run", "--config", "./tests/vitest.config.mjs", relativeToWorkspace]);
      } catch (error) {
        process.stderr.write(`workspace-db-test: could not load product test environment: ${error instanceof Error ? error.message : String(error)}\n`);
        process.exitCode = 1;
      }
    }
  }
} else {
  let packageJson;
  try {
    packageJson = JSON.parse(fs.readFileSync(path.join(workspaceDirectory, "package.json"), "utf8"));
  } catch (error) {
    process.stderr.write(`workspace-db-test: could not read Payments package.json: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  }
  if (process.exitCode === undefined && packageJson?.name !== workspace) {
    process.stderr.write(`workspace-db-test: Payments package name is not ${workspace}; refusing zero-test run\n`);
    process.exitCode = 1;
  }
  const scripts = packageJson?.scripts;
  const hasDatabaseScript = scripts && typeof scripts === "object" &&
    Object.keys(scripts).some((name) => name === "test:db" || name.startsWith("test:db:"));
  if (process.exitCode === undefined && !hasDatabaseScript) {
    process.stderr.write("workspace-db-test: Payments has no test:db or test:db:* script; refusing zero-test run\n");
    process.exitCode = 1;
  } else if (process.exitCode === undefined) {
    process.exitCode = await run(process.execPath, [runWorkspacesPath, "test:db*", `--workspace=${workspace}`]);
  }
}
