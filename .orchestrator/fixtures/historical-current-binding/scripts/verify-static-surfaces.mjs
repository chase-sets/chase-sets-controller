export const ALWAYS_RUN = "always-run";
export const MAY_NARROW = "may-narrow";

const exact = (...values) => values.map((value) => ({ kind: "exact", value }));
const prefix = (...values) => values.map((value) => ({ kind: "prefix", value }));
const regex = (...values) => values.map((value) => ({ kind: "regex", value }));

// The complete scripts battery remains part of the authoritative hosted
// verify:static chain, but it is intentionally outside the focused local
// command plan. Script-tooling authors run the named tests for their change.
export const VERIFY_STATIC_SCOPED_EXCLUSIONS = Object.freeze({
  "test:scripts": "complete scripts battery is a hosted-CI gate; run named focused script tests locally",
});

// This is the auditable link -> input-surface contract for verify:static.
// ALWAYS_RUN links deliberately have no include rules: their input is not
// bounded by changed repository paths. MAY_NARROW rules are conservative
// supersets of the scan boundaries cited in evidence.
export const VERIFY_STATIC_SURFACES = {
  "format:check": {
    classification: MAY_NARROW,
    rule: "any changed path; format:check performs its own supported-file filtering",
    evidence: ["scripts/format-check.mjs:121-138,219-257"],
    include: [{ kind: "any" }],
  },
  "check:kb-reference-ratchet": {
    classification: ALWAYS_RUN,
    rule: "PR/issue body input can change with no repository path change",
    evidence: ["scripts/check-structure/kb-reference-ratchet.mjs:45-51"],
  },
  "check:postage-adapters": {
    classification: MAY_NARROW,
    rule: "bounded-contexts/fulfillment/**",
    evidence: ["scripts/check-postage-adapter-boundaries.mjs:8-15,86-91"],
    include: prefix("bounded-contexts/fulfillment"),
  },
  "check:github-actions-runtime": {
    classification: MAY_NARROW,
    rule: ".github/**",
    evidence: ["scripts/check-github-actions-runtime.mjs:6-7,24-36,406-413"],
    include: prefix(".github"),
  },
  "check:identity-creation-positions": {
    classification: ALWAYS_RUN,
    rule: "scans every git-tracked file for each command byte sequence derived from the Identity domain anchors",
    evidence: ["scripts/identity-creation-position-guard.mjs:79-120,301-363"],
  },
  "check:managed-postgres-authority": {
    classification: ALWAYS_RUN,
    rule: "workflow steps transitively resolve arbitrary executables and package scripts",
    evidence: ["scripts/managed-postgres-authority-guard.mjs:429-508"],
  },
  "check:managed-registry-authority": {
    classification: ALWAYS_RUN,
    rule: "fail-closed: link postdates the ratified 8/21 classification and has not been approved for narrowing",
    evidence: ["scripts/managed-registry-authority-guard.mjs:11-12,24-35,50-153"],
  },
  "check:environment-topology": {
    classification: ALWAYS_RUN,
    rule: "scans every git-tracked file for retired host tokens",
    evidence: ["scripts/environment-topology-guard.mjs:556-580,583-635"],
  },
  "check:workflow-canonical-artifacts": {
    classification: MAY_NARROW,
    rule: ".github/workflows/**, .github/actions/**, or the workflow artifact baseline",
    evidence: ["scripts/workflow-canonical-artifacts.mjs:10,205-206,258-307"],
    include: [
      ...prefix(".github/workflows", ".github/actions"),
      ...exact("scripts/workflow-canonical-artifacts-baseline.json"),
    ],
  },
  "check:no-legacy-forms": {
    classification: MAY_NARROW,
    rule: "bounded-contexts/**, deployables/**, or packages/**",
    evidence: ["scripts/check-no-legacy-forms.mjs:8-12,30-34,203-211"],
    include: prefix("bounded-contexts", "deployables", "packages"),
  },
  "check:design-system-hoc-budget": {
    classification: MAY_NARROW,
    rule: "design-system components/primitives or the HOC budget ledger",
    evidence: ["scripts/design-system-hoc-budget.mjs:31-42,77-90,185-225"],
    include: [
      ...prefix("packages/design-system/src/components", "packages/design-system/src/primitives"),
      ...exact("packages/design-system/DESIGN_SYSTEM_HOC_BUDGET.json"),
    ],
  },
  "check:responsive-safety": {
    classification: MAY_NARROW,
    rule: "production TSX under its three roots or the responsive-safety ledger",
    evidence: ["scripts/check-responsive-safety.mjs:19-24,55-84,279-282,359-390"],
    include: [
      ...regex("^bounded-contexts/.+\\.tsx$", "^deployables/.+\\.tsx$", "^packages/design-system/src/.+\\.tsx$"),
      ...exact("packages/design-system/RESPONSIVE_SAFETY.json"),
    ],
  },
  "check:design-system-raw-ui-budget": {
    classification: MAY_NARROW,
    rule: "bounded-contexts/**, deployables/**, or the raw-UI budget ledger",
    evidence: ["scripts/design-system-raw-ui-budget.mjs:28-35,128-145,265-323"],
    include: [
      ...prefix("bounded-contexts", "deployables"),
      ...exact("packages/design-system/DESIGN_SYSTEM_RAW_UI_BUDGET.json"),
    ],
  },
  "check:design-system-color-utilities": {
    classification: MAY_NARROW,
    rule: "packages/design-system/src/**",
    evidence: ["scripts/check-design-system-color-utilities.mjs:157-192"],
    include: prefix("packages/design-system/src"),
  },
  "check:readme-manifest-sections": {
    classification: MAY_NARROW,
    rule: "root README, context manifests/READMEs, or deployable package manifests",
    evidence: ["scripts/generate-readme-manifest-sections.mjs:7-10,80-113,188-218"],
    include: [
      ...exact("README.md"),
      ...regex("^bounded-contexts/[^/]+/(?:context\\.json|README\\.md)$", "^deployables/[^/]+/package\\.json$"),
    ],
  },
  "check:agent-connector-packaging": {
    classification: ALWAYS_RUN,
    rule: "runtime value-import graph reaches contracts and infrastructure beyond a finite declared surface",
    evidence: [
      "scripts/generate-agent-connector-packaging.mjs:34-38",
      "infrastructure/platform-runtime/agent-connector-packaging.ts:1-10",
      "infrastructure/platform-runtime/mcp.ts:24-50",
      "infrastructure/platform-runtime/agent-guardrails.ts:1",
    ],
  },
  "check:public-policies": {
    classification: ALWAYS_RUN,
    rule: "policy evidence citations resolve arbitrary repository paths and exact line ranges",
    evidence: ["bounded-contexts/public-presence/features/policies/domain/canonical-claim-guard.ts:79-90"],
  },
  "check:developer-articles": {
    classification: ALWAYS_RUN,
    rule: "compiler follows help, platform-runtime, and auth-context value-import graphs",
    evidence: [
      "bounded-contexts/public-presence/features/developer-portal/integrations/compile-developer-articles.mjs:5-7,16-30",
    ],
  },
  "check:docs-index": {
    classification: ALWAYS_RUN,
    rule: "any repository file can be the final basename mention keeping a context document indexed",
    evidence: ["scripts/check-docs-index.mjs:145-161"],
  },
  "check:docs-path-claims": {
    classification: ALWAYS_RUN,
    rule: "deleting or renaming any path can invalidate an unchanged Markdown path claim",
    evidence: ["scripts/check-docs-path-claims.mjs:20-38,227-238"],
  },
  "check:design-system-component-index": {
    classification: MAY_NARROW,
    rule: "design-system sources/index, TypeScript compiler API, or production consumers",
    evidence: [
      "scripts/generate-design-system-component-index.mjs:8,42-48,66-73",
      "scripts/check-design-system-dead-exports.mjs:5",
      "scripts/check-design-system-dead-exports.mjs:188-223",
    ],
    include: prefix("packages/design-system", "packages/typescript-compiler-api", "bounded-contexts", "deployables"),
  },
  "check:design-system-export-coverage": {
    classification: MAY_NARROW,
    rule: "design-system runtime graph, including contracts/primitives, or the export-coverage guard itself",
    evidence: [
      "scripts/check-design-system-export-coverage.mjs:423-448",
      "packages/design-system/src/components/forms/number-field.tsx:5-9",
    ],
    include: [
      ...prefix("packages/design-system", "contracts/primitives"),
      ...exact("scripts/check-design-system-export-coverage.mjs"),
    ],
  },
  "check:package-export-targets": {
    classification: MAY_NARROW,
    rule: "any of the five workspace roots",
    evidence: ["scripts/check-package-export-targets.mjs:51-89,99-113", "scripts/lib/repo.mjs:7"],
    include: prefix("bounded-contexts", "contracts", "infrastructure", "packages", "deployables"),
  },
  "check:env-examples": {
    classification: MAY_NARROW,
    rule: "the five enumerated config/example inputs",
    evidence: ["scripts/check-env-examples.mjs:50-70,128-145"],
    include: exact(
      "deployables/platform-api/src/config.ts",
      "infrastructure/platform-runtime/http.ts",
      "deployables/platform-api/.env.example",
      "deployables/platform-worker/src/config.ts",
      "deployables/platform-worker/.env.example",
    ),
  },
  "check:structure": {
    classification: ALWAYS_RUN,
    rule: "repo-wide structure scan plus diff-consuming SQL and boot-schema guards",
    evidence: ["scripts/check-structure/run.mjs:40-55,1344-1353,3370-3378"],
  },
  "check:localization": {
    classification: MAY_NARROW,
    rule: "English locale sources or any path admitted by the localization source predicate",
    evidence: ["scripts/check-localization.mjs:5-16,117-139"],
    include: [
      ...regex(
        "^contracts/localization/locales/en(?:\\.ts|/)",
        "/features/",
        "/routes/",
        "/support/(?:api-support|request-support|shell-support)/",
      ),
      ...prefix("deployables/marketplace/app", "deployables/admin-web/app"),
    ],
  },
  "check:buyer-seller-jargon": {
    classification: MAY_NARROW,
    rule: "English locales, bounded contexts, or marketplace app sources",
    evidence: ["scripts/check-buyer-seller-jargon.mjs:6-11,81-101"],
    include: [
      ...exact("contracts/localization/locales/en.ts"),
      ...prefix("contracts/localization/locales/en", "bounded-contexts", "deployables/marketplace/app"),
    ],
  },
  "check:operator-surface-pm": {
    classification: MAY_NARROW,
    rule: "bounded-context UI or catalog locale sources",
    evidence: ["scripts/check-operator-surface-pm-content.mjs:20-32,236-248"],
    include: [
      ...regex(
        "^bounded-contexts/[^/]+/(?:.+/)?ui/",
        "^contracts/localization/locales/.+/catalog/.*\\.ts$",
        "^contracts/localization/locales/.+/catalog\\.ts$",
      ),
    ],
  },
  "test:scripts": {
    classification: ALWAYS_RUN,
    rule: "script tests read repository inputs dynamically outside their static import graph",
    evidence: [
      "vitest.scripts.config.mjs:3-10",
      "scripts/digitalocean-platform-config.test.mjs:8-18",
      "scripts/check-structure/skill-mirror.test.mjs:15-16",
    ],
  },
};

function normalizedPath(filePath) {
  return String(filePath).replaceAll("\\", "/").replace(/^\.\//, "");
}

export function surfaceRuleMatches(filePath, surfaceRule) {
  const normalized = normalizedPath(filePath);
  if (surfaceRule.kind === "any") return normalized.length > 0;
  if (surfaceRule.kind === "exact") return normalized === surfaceRule.value;
  if (surfaceRule.kind === "prefix") {
    return normalized === surfaceRule.value || normalized.startsWith(`${surfaceRule.value}/`);
  }
  if (surfaceRule.kind === "regex") return new RegExp(surfaceRule.value).test(normalized);
  throw new Error(`Unknown verify:static surface-rule kind: ${surfaceRule.kind}`);
}

export function linkSurfaceMatches(entry, changedFiles) {
  return (entry.include ?? []).some((surfaceRule) =>
    changedFiles.some((filePath) => surfaceRuleMatches(filePath, surfaceRule)),
  );
}
