const POLICY_VERSION = "risk-policy/v1";

export const GENERATED_PATH = /(?:^|\/)(?:generated|__generated__)(?:\/|$)/;
export const DOCUMENTATION_OR_TEST =
  /(?:^|\/)(?:docs?|__tests__|tests?|test-support)(?:\/|$)|\.(?:md|mdx)$|\.(?:test|spec)\.[cm]?[jt]sx?$/;
export const EXECUTABLE_SAFETY_FIXTURE =
  /(?:^|\/)(?:migrations?|backfills?|terraform|helm)(?:\/.*)?\.(?:sql|tf|ya?ml|json)$|^\.github\/workflows\//;

function normalizePath(value) {
  if (typeof value !== "string") return "";
  return value.replaceAll("\\", "/").replace(/^\.\//, "").trim();
}

export function isDesignSystemNavigationRiskPath(path) {
  const normalized = normalizePath(path);
  return [
    /^packages\/design-system\/src\/components\/actions\/(?:navigation|navigation-menu|navigation-header|section-navigation)\.[cm]?[jt]sx?$/,
    /^packages\/design-system\/src\/patterns\/app-shells\/shells\.[cm]?[jt]sx?$/,
    /^packages\/design-system\/src\/theme\/(?:link-adapter|provider)\.[cm]?[jt]sx?$/,
  ].some((pattern) => pattern.test(normalized));
}

const integrationRules = [
  {
    category: "cross-context-contract",
    reason: "Bounded-context metadata, including event subscriptions, changed",
    integrationReason: "Bounded-context metadata, including event subscriptions, changed",
    patterns: [/^bounded-contexts\/[^/]+\/context\.json$/],
  },
  {
    category: "cross-context-contract",
    reason: "Cross-context subscription or runtime composition changed",
    integrationReason: "Cross-context subscription or runtime composition changed",
    patterns: [
      /^infrastructure\/(?:bounded-context-runtime|platform-runtime)\//,
      /^deployables\/(?:platform-api|platform-worker)\/src\/generated\/.*context-registry\.[cm]?[jt]s$/,
      /^deployables\/(?:admin-web|marketplace|public-web)\/app\/generated\/web-context-registry\.[cm]?[jt]s$/,
    ],
  },
  {
    category: "integration-surface",
    reason: "Shared application shell, router, or navigation integration surface changed",
    integrationReason: "Shared application shell or router changed",
    patterns: [
      /^deployables\/admin-web\/app\/(?:admin-root-shell|host|routes)\.[cm]?[jt]sx?$/,
      /^deployables\/admin-web\/app\/routes\/[^/]+-layout\.[cm]?[jt]sx?$/,
      /^deployables\/marketplace\/app\/(?:root|routes)\.[cm]?[jt]sx?$/,
      /^deployables\/marketplace\/app\/routes\/layout\.[cm]?[jt]sx?$/,
    ],
  },
  {
    category: "integration-surface",
    reason: "Design-system navigation integration surface changed",
    integrationReason: "Design-system navigation changed",
    patterns: [],
    matches: isDesignSystemNavigationRiskPath,
  },
];

const rules = [
  {
    category: "money-movement",
    reason: "Money movement, settlement, payout, or tax behavior changed",
    patterns: [
      /^bounded-contexts\/(?:checkout|payments|settlement|payouts)(?:\/|$)/,
      /^bounded-contexts\/ordering\/(?:features\/tax-|[^/]*tax)/,
      /^contracts\/(?:payments|settlement|payouts|tax)(?:\/|$)/,
      /^infrastructure\/(?:stripe-payments|stripe-connect|stripe-config|provider-webhook-inbox)(?:\/|$)/,
      /^scripts\/(?:stripe-money|marketplace-checkout-fee|marketplace-tax)/,
    ],
  },
  {
    category: "cross-context-contract",
    reason: "Cross-context public contract, event schema, subscription, or runtime composition changed",
    patterns: [/^contracts\//],
  },
  ...integrationRules.map((rule) => ({ ...rule, includesDocumentationAndTests: true })),
  {
    category: "database-change",
    reason: "Database migration, backfill, destructive operation, or retention deletion changed",
    patterns: [
      /(?:^|\/)(?:migrations?|backfills?)(?:\/|$)/,
      /(?:^|\/)(?:retention|purge|delete)-[^/]*\.[cm]?[jt]s$/,
      /(?:^|\/)support\/runtime-support\/(?:schema|.*migrations|retention-policy)\.[cm]?[jt]s$/,
      /^infrastructure\/[^/]*(?:postgres|database)[^/]*\/(?:schema(?:\.sql|\.[cm]?[jt]s)|.*migrations?\.[cm]?[jt]s)$/,
      /^scripts\/.*(?:migration|backfill|retention|purge|destructive)/,
    ],
  },
  {
    category: "security-policy",
    reason: "Authentication, authorization, or security policy changed",
    patterns: [
      /^bounded-contexts\/(?:auth|identity)\//,
      /(?:^|\/)(?:authorization|authentication|permissions?|security-policy)(?:\/|\.)/,
      /^\.github\/CODEOWNERS$/,
    ],
  },
  {
    category: "deployment-control",
    reason: "Deployment, infrastructure, secret/configuration contract, or emergency control changed",
    patterns: [
      /^infrastructure\/(?:digitalocean|helm)\//,
      /^\.github\/workflows\/(?:platform-(?:pr|production|staging|release|rollback|emergency|merge)|.*deploy)/,
      /^scripts\/(?:digitalocean-|doks-|platform-kubernetes-|platform-ingress-|render-platform-helm-values|release-lock|rollback-|emergency-)/,
      /(?:^|\/)(?:secrets?|rollback|emergency)-[^/]*\.(?:json|ya?ml|[cm]?[jt]s)$/,
    ],
  },
  {
    category: "risk-policy",
    reason: "Risk-review safety policy or evaluator changed",
    patterns: [
      /^scripts\/lib\/risk-policy-v1\.mjs$/,
      /^scripts\/platform-risk-review(?:\.test)?\.mjs$/,
      /^scripts\/risk-review-eligibility-v1\.json$/,
      /^\.github\/workflows\/platform-risk-review\.yml$/,
      /^docs\/runbooks\/release-process-evolution\.md$/,
    ],
    includesDocumentationAndTests: true,
  },
];

const approvedHighRiskLabels = new Set(["risk:high"]);
const allowedStatuses = new Set(["added", "modified", "removed", "renamed", "copied", "changed"]);

function assertClosedKeys(value, allowed, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${label} must be an object`);
  }
  const unknown = Object.keys(value).filter((key) => !allowed.includes(key));
  if (unknown.length > 0) throw new TypeError(`${label} has unknown field(s): ${unknown.sort().join(", ")}`);
}

function normalizeFile(file, index) {
  if (typeof file === "string") {
    const filename = normalizePath(file);
    if (!filename) throw new TypeError(`changedFiles[${index}] must be a non-empty path`);
    return { filename, status: "modified", previousFilename: null };
  }
  assertClosedKeys(
    file,
    ["filename", "status", "previousFilename", "additions", "deletions", "changes", "patch"],
    `changedFiles[${index}]`,
  );
  const filename = normalizePath(file.filename);
  const previousFilename = file.previousFilename == null ? null : normalizePath(file.previousFilename);
  if (!filename) throw new TypeError(`changedFiles[${index}].filename must be a non-empty string`);
  if (!allowedStatuses.has(file.status)) throw new TypeError(`changedFiles[${index}].status is unsupported`);
  if (file.status === "renamed" && !previousFilename) {
    throw new TypeError(`changedFiles[${index}].previousFilename is required for a rename`);
  }
  for (const field of ["additions", "deletions", "changes"]) {
    if (file[field] != null && (!Number.isInteger(file[field]) || file[field] < 0)) {
      throw new TypeError(`changedFiles[${index}].${field} must be a non-negative integer`);
    }
  }
  if (file.patch != null && typeof file.patch !== "string") {
    throw new TypeError(`changedFiles[${index}].patch must be a string or null`);
  }
  return { ...file, filename, previousFilename };
}

function matchingRules(path) {
  return rules.filter((rule) => {
    if (
      DOCUMENTATION_OR_TEST.test(path) &&
      !EXECUTABLE_SAFETY_FIXTURE.test(path) &&
      !rule.includesDocumentationAndTests
    ) {
      return false;
    }
    return rule.matches?.(path) || rule.patterns.some((pattern) => pattern.test(path));
  });
}

function ruleMatchesPath(rule, path) {
  return rule.matches?.(path) || rule.patterns.some((pattern) => pattern.test(path));
}

export const RISK_POLICY_V1 = Object.freeze({
  schemaVersion: POLICY_VERSION,
  approvedHighRiskLabels: Object.freeze([...approvedHighRiskLabels]),
  categories: Object.freeze([...new Set(rules.map((rule) => rule.category))]),
});

export function classifyIntegrationRisk({ changedFiles }) {
  if (!Array.isArray(changedFiles)) throw new TypeError("changedFiles must be an array");
  const normalizedFiles = changedFiles.map(normalizeFile);
  const reasons = [
    ...new Set(
      normalizedFiles.flatMap((file) =>
        integrationRules.filter((rule) => ruleMatchesPath(rule, file.filename)).map((rule) => rule.integrationReason),
      ),
    ),
  ];
  return { required: reasons.length > 0, reasons };
}

export function classifyRisk({ changedFiles, labels = [] }) {
  if (!Array.isArray(changedFiles) || !Array.isArray(labels) || labels.some((label) => typeof label !== "string")) {
    throw new TypeError("changedFiles and labels must be arrays");
  }

  const normalizedFiles = changedFiles.map(normalizeFile);
  const findings = [];
  const scannedPaths = [];
  for (const file of normalizedFiles) {
    for (const path of [file.filename, file.previousFilename].filter(Boolean)) {
      scannedPaths.push(path);
      for (const rule of matchingRules(path)) {
        findings.push({
          category: rule.category,
          reason: rule.reason,
          source: "path",
          path,
          status: file.status,
          integrationReason: rule.integrationReason ?? null,
        });
      }
    }
  }

  const hasHighRiskSource = findings.length > 0;
  if (hasHighRiskSource) {
    for (const file of normalizedFiles.filter((entry) => GENERATED_PATH.test(entry.filename))) {
      findings.push({
        category: "generated-coupling",
        reason: "Generated metadata accompanies a high-risk source change",
        source: "generated-coupling",
        path: file.filename,
        status: file.status,
        integrationReason: null,
      });
    }
  }

  for (const label of labels.map((value) => value.toLowerCase()).filter((value) => approvedHighRiskLabels.has(value))) {
    findings.push({
      category: "explicit-label",
      reason: `Approved high-risk label '${label}' is present`,
      source: "label",
      path: null,
      status: null,
      integrationReason: null,
    });
  }

  const deduped = [...new Map(findings.map((finding) => [JSON.stringify(finding), finding])).values()].sort((a, b) =>
    `${a.category}:${a.path ?? ""}:${a.reason}`.localeCompare(`${b.category}:${b.path ?? ""}:${b.reason}`),
  );
  return {
    schemaVersion: POLICY_VERSION,
    classification: deduped.length > 0 ? "high" : "low",
    categories: [...new Set(deduped.map((finding) => finding.category))].sort(),
    reasons: [...new Set(deduped.map((finding) => finding.reason))].sort(),
    findings: deduped,
    scan: {
      filesScanned: normalizedFiles.length,
      pathsScanned: scannedPaths.length,
      uniquePathsScanned: new Set(scannedPaths).size,
      totalSurface: scannedPaths.length + labels.length,
    },
  };
}
