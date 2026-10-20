import { spawn } from "node:child_process";
import { pathToFileURL } from "node:url";
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
      env: process.env,
      stdio: "inherit",
      windowsHide: true,
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => resolve(signal ? 1 : (code ?? 1)));
  });
}

const preflight = await run(process.execPath, [path.join(repositoryRoot, "scripts", "db-test-preflight.mjs")]);
if (preflight !== 0) process.exitCode = preflight;
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
        process.exitCode = await run(process.execPath, [pnpm, "--dir", workspaceDirectory, "exec", "vitest", "run", "--config", "./tests/vitest.config.mjs", relativeToWorkspace]);
      } catch (error) {
        process.stderr.write(`workspace-db-test: could not load product test environment: ${error instanceof Error ? error.message : String(error)}\n`);
        process.exitCode = 1;
      }
    }
  }
} else {
  process.exitCode = await run(process.execPath, [runWorkspacesPath, "test:db*", `--workspace=${workspace}`]);
}
