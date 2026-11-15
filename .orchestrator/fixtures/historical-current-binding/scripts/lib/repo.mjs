import { existsSync, readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

export const workspaceRoots = ["bounded-contexts", "contracts", "infrastructure", "packages", "deployables"];

export function readJson(filePath) {
  return JSON.parse(readFileSync(filePath, "utf8"));
}

export function readDir(rootPath) {
  return existsSync(rootPath) ? readdirSync(rootPath, { withFileTypes: true }) : [];
}

export function normalizePath(value) {
  return value.replaceAll("\\", "/");
}

export function listContextManifests(options = {}) {
  const rootDir = options.repoRoot ?? repoRoot;
  const contextsDir = path.join(rootDir, "bounded-contexts");

  return (
    readDir(contextsDir)
      .filter((entry) => entry.isDirectory())
      .map((entry) => ({
        dirName: entry.name,
        dir: path.join(contextsDir, entry.name),
        manifestPath: path.join(contextsDir, entry.name, "context.json"),
      }))
      // Switching branches in a git worktree leaves ghost context directories
      // behind when only ignored files (node_modules) remain inside them; a
      // directory is a context only when its tracked manifest exists.
      .filter((context) => existsSync(context.manifestPath))
      .map((context) => ({ ...context, manifest: readJson(context.manifestPath) }))
      .sort((left, right) => left.dirName.localeCompare(right.dirName, "en"))
  );
}

// The sandbox-ownership and registry-generation predicates must agree on
// which directories are eligible contexts at all: a directory that only has
// a context.json (no workspace package.json) is a manifest fragment, not an
// implemented bounded context, and must not become a database/registry
// owner. This closure is the single admission gate both predicates share.
export function listBoundedContextManifests(options = {}) {
  const rootDir = options.repoRoot ?? repoRoot;
  const workspaces = (
    options.workspaces ?? listWorkspacePackages({ repoRoot: rootDir, roots: ["bounded-contexts"] })
  ).filter((workspace) => workspace.root === "bounded-contexts");

  return workspaces
    .map((workspace) => {
      const manifestPath = path.join(workspace.dir, "context.json");
      const manifest = readJson(manifestPath);
      if (typeof manifest?.contextName !== "string" || !manifest.contextName.trim()) {
        throw new Error(`Context manifest must declare a non-empty contextName: ${manifestPath}`);
      }

      return {
        contextName: manifest.contextName,
        dirName: workspace.dirName,
        packageName: workspace.name,
        dir: workspace.dir,
        manifest,
        manifestPath,
      };
    })
    .sort((left, right) => left.contextName.localeCompare(right.contextName, "en"));
}

export function contextManifestContributesToApiHost(manifest, hostName) {
  return (
    manifest.apiDeployables?.includes(hostName) ||
    manifest.sourceRuntimeDeployables?.includes(hostName) ||
    manifest.sourceRuntimeProfiles?.length > 0
  );
}

export function normalizeRelative(filePath, fromRoot = repoRoot) {
  return normalizePath(path.relative(fromRoot, filePath));
}

function reportSkippedWorkspace(options, skippedWorkspace) {
  if (options.onSkippedWorkspace) {
    options.onSkippedWorkspace(skippedWorkspace);
    return;
  }

  console.warn(
    `[repo] Skipping workspace package at ${normalizeRelative(skippedWorkspace.packageJsonPath, options.repoRoot ?? repoRoot)}: ${skippedWorkspace.reason}.`,
  );
}

export function listWorkspacePackages(options = {}) {
  const roots = options.roots ?? workspaceRoots;
  const rootDir = options.repoRoot ?? repoRoot;
  const workspaces = [];

  if (!options.roots && options.assertRootCoverage !== false) {
    assertWorkspaceRootsCoverPackageDirectories({ repoRoot: rootDir, roots });
  }

  for (const workspaceRoot of roots) {
    const rootPath = path.join(rootDir, workspaceRoot);

    for (const entry of readDir(rootPath)) {
      if (!entry.isDirectory()) {
        continue;
      }

      const packageDir = path.join(rootPath, entry.name);
      const packageJsonPath = path.join(packageDir, "package.json");

      if (!existsSync(packageJsonPath)) {
        continue;
      }

      try {
        const packageJson = readJson(packageJsonPath);
        if (typeof packageJson.name !== "string" || !packageJson.name.trim()) {
          reportSkippedWorkspace(options, {
            packageJsonPath,
            reason: "package.json is missing a non-empty name",
          });
          continue;
        }

        workspaces.push({
          name: packageJson.name,
          dir: packageDir,
          dirName: entry.name,
          root: workspaceRoot,
          packageJson,
          packageJsonPath,
        });
      } catch (error) {
        reportSkippedWorkspace(options, {
          packageJsonPath,
          reason: `package.json could not be read (${error instanceof Error ? error.message : String(error)})`,
        });
      }
    }
  }

  return workspaces.sort((left, right) => left.name.localeCompare(right.name));
}

export function assertWorkspaceRootsCoverPackageDirectories(options = {}) {
  const roots = new Set(options.roots ?? workspaceRoots);
  const rootDir = options.repoRoot ?? repoRoot;
  const ignoredTopLevelDirectories = new Set([
    ".codex",
    ".git",
    ".github",
    ".turbo",
    "artifacts",
    "docs",
    "node_modules",
    "scripts",
    "uat-artifacts",
  ]);
  const uncoveredRoots = [];

  for (const entry of readDir(rootDir)) {
    if (!entry.isDirectory() || roots.has(entry.name) || ignoredTopLevelDirectories.has(entry.name)) {
      continue;
    }

    const topLevelPath = path.join(rootDir, entry.name);
    const containsWorkspacePackage = readDir(topLevelPath).some(
      (child) => child.isDirectory() && existsSync(path.join(topLevelPath, child.name, "package.json")),
    );
    if (containsWorkspacePackage) {
      uncoveredRoots.push(entry.name);
    }
  }

  if (uncoveredRoots.length > 0) {
    throw new Error(
      `workspaceRoots is missing top-level package root(s): ${uncoveredRoots.sort().join(", ")}. Add them to scripts/lib/repo.mjs.`,
    );
  }
}
