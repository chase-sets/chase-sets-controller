import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

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
  process.exitCode = await run(process.execPath, [pnpm, "--dir", workspaceDirectory, "exec", "vitest", "run", "--config", "./tests/vitest.config.mjs", relativeToWorkspace]);
} else {
  process.exitCode = await run(process.execPath, [pnpm, "--filter", workspace, "run", "test:db"]);
}
