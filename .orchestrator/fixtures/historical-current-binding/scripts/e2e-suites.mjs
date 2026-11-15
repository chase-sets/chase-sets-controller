import { isDesignSystemNavigationRiskPath } from "./lib/risk-policy-v1.mjs";

export const e2eSuites = Object.freeze([
  {
    id: "marketplace_browse",
    label: "Marketplace Browse",
    deployable: "marketplace",
    journeys: ["browse", "search", "auth entry"],
    grep: "@marketplace-browse",
    estimatedDurationSeconds: 420,
  },
  {
    id: "marketplace_account",
    label: "Marketplace Account",
    deployable: "marketplace",
    journeys: ["account access", "authentication"],
    grep: "@marketplace-account",
    estimatedDurationSeconds: 300,
  },
  {
    id: "marketplace_checkout",
    label: "Marketplace Checkout",
    deployable: "marketplace",
    journeys: ["buy cart", "sell list", "checkout"],
    grep: "@marketplace-checkout",
    estimatedDurationSeconds: 540,
  },
  {
    id: "marketplace_seller",
    label: "Marketplace Seller",
    deployable: "marketplace",
    journeys: ["listings", "offers", "seller operations"],
    grep: "@marketplace-seller",
    estimatedDurationSeconds: 360,
  },
  {
    id: "catalog_admin_integrations",
    label: "Catalog Admin Integrations",
    deployable: "admin-web",
    journeys: ["provider profile management", "catalog integrations"],
    grep: "@catalog-admin-integrations",
    estimatedDurationSeconds: 720,
  },
  {
    id: "catalog_admin_modeling",
    label: "Catalog Admin Modeling",
    deployable: "admin-web",
    journeys: ["dimensions", "catalog model authoring"],
    grep: "@catalog-admin-modeling",
    estimatedDurationSeconds: 660,
  },
  {
    id: "admin_growth",
    label: "Admin Growth",
    deployable: "admin-web",
    journeys: ["Google Shopping operations", "waitlist review", "promo bar management"],
    grep: "@admin-growth",
    estimatedDurationSeconds: 360,
  },
  {
    id: "admin_commerce",
    label: "Admin Commerce",
    deployable: "admin-web",
    journeys: ["commercial terms management", "postage policy management", "facility return intake"],
    grep: "@admin-commerce",
    estimatedDurationSeconds: 420,
  },
  {
    id: "admin_support",
    label: "Admin Support",
    deployable: "admin-web",
    journeys: ["support request operations", "platform feedback triage"],
    grep: "@admin-support",
    estimatedDurationSeconds: 240,
  },
  {
    id: "admin_platform",
    label: "Admin Platform",
    deployable: "admin-web",
    journeys: ["projection operations", "Listing Evidence Policy", "API topology"],
    grep: "@admin-platform",
    estimatedDurationSeconds: 240,
  },
  {
    id: "admin_auth",
    label: "Admin Auth",
    deployable: "admin-web",
    journeys: ["admin sign-in", "shell session", "RBAC entry"],
    grep: "@admin-auth",
    estimatedDurationSeconds: 180,
  },
  {
    id: "admin_access",
    label: "Admin Access",
    deployable: "admin-web",
    journeys: ["invitation lifecycle", "api key lifecycle"],
    grep: "@admin-access",
    estimatedDurationSeconds: 300,
  },
  {
    id: "platform_mcp_sdk",
    label: "Platform MCP SDK",
    deployable: "platform-api",
    journeys: ["SDK client discovery", "agent commerce journey", "agent grant guardrails"],
    grep: "@mcp-sdk-journey",
    command: [
      "--filter",
      "@chase-sets/app-platform-api",
      "exec",
      "vitest",
      "run",
      "--config",
      "./vitest.config.ts",
      "__tests__/mcp-sdk-agent-journey.e2e.test.ts",
    ],
    estimatedDurationSeconds: 90,
  },
]);

const suiteOrder = new Map(e2eSuites.map((suite, index) => [suite.id, index]));
const suitesById = new Map(e2eSuites.map((suite) => [suite.id, suite]));
const allMarketplaceSuiteIds = e2eSuites.filter((suite) => suite.deployable === "marketplace").map((suite) => suite.id);
const allAdminWebSuiteIds = e2eSuites.filter((suite) => suite.deployable === "admin-web").map((suite) => suite.id);
const allBrowserSuiteIds = e2eSuites
  .filter((suite) => suite.deployable === "marketplace" || suite.deployable === "admin-web")
  .map((suite) => suite.id);
const defaultSuiteBatchSize = 2;
const fallbackEstimatedSuiteDurationSeconds = 300;

const browserRuntimePatterns = [
  /^package\.json$/,
  /^pnpm-lock\.yaml$/,
  /^pnpm-workspace\.yaml$/,
  /^\.npmrc$/,
  /^tsconfig\.json$/,
  /^tsconfig\.base\.json$/,
  /^tailwind\.config\.ts$/,
  /^vite\.config\.[cm]?[tj]s$/,
  /^react-router\.config\.[cm]?[tj]s$/,
  /^playwright\.config\.ts$/,
  /^scripts\/e2e-suites\.mjs$/,
  /^infrastructure\/playwright-evidence\/(?:index\.ts|package\.json|responsive-evidence-manifest\.json)$/,
  /^scripts\/validate-responsive-evidence-artifacts\.mjs$/,
  /^scripts\/run-e2e-suite\.mjs$/,
];

const contextSuiteOwnership = new Map([
  ["auth", ["marketplace_account", "admin_auth"]],
  ["catalog", ["marketplace_browse", "catalog_admin_integrations"]],
  ["channels", ["marketplace_account", "marketplace_seller"]],
  ["checkout", ["marketplace_checkout"]],
  ["commercial-terms", ["marketplace_browse", "marketplace_seller"]],
  ["discovery", ["marketplace_browse"]],
  ["fulfillment", ["marketplace_account"]],
  ["identity", ["marketplace_account", "admin_access"]],
  ["inventory", ["marketplace_seller"]],
  ["marketplace", ["marketplace_account", "marketplace_seller"]],
  ["notifications", ["marketplace_account"]],
  ["ordering", ["marketplace_account", "marketplace_checkout", "admin_commerce"]],
  ["payments", ["marketplace_account", "marketplace_checkout"]],
  ["platform-operations", ["marketplace_account", "admin_support", "admin_platform"]],
  ["pricing", ["marketplace_browse"]],
  ["public-presence", ["marketplace_browse", "admin_growth"]],
  ["settlement", ["marketplace_account", "marketplace_seller"]],
]);

const marketplaceContextRouteSuiteOwnership = new Map([
  ["auth", ["marketplace_account"]],
  ["channels", ["marketplace_account", "marketplace_seller"]],
  ["discovery", ["marketplace_browse"]],
  ["fulfillment", ["marketplace_account"]],
  ["identity", ["marketplace_account"]],
  ["inventory", ["marketplace_seller"]],
  ["marketplace", ["marketplace_account", "marketplace_seller"]],
  ["payments", ["marketplace_account", "marketplace_checkout"]],
  ["platform-operations", ["marketplace_account"]],
  ["pricing", ["marketplace_seller"]],
  ["public-presence", ["marketplace_browse"]],
  ["settlement", ["marketplace_account", "marketplace_seller"]],
]);

const adminContextRouteSuiteOwnership = new Map([
  ["auth", ["admin_auth", "admin_access"]],
  ["catalog", ["catalog_admin_modeling"]],
  ["commercial-terms", ["admin_commerce"]],
  ["discovery", ["admin_growth"]],
  ["identity", ["admin_access"]],
  ["fulfillment", ["admin_commerce"]],
  ["inventory", ["admin_commerce"]],
  ["ordering", ["admin_commerce"]],
  ["platform-operations", ["admin_support", "admin_platform"]],
  ["public-presence", ["admin_growth"]],
  ["settlement", ["admin_commerce"]],
]);

const e2eSpecSuiteOwnership = [
  { pattern: /^deployables\/marketplace\/e2e\/item-detail\.spec\.ts$/, suites: ["marketplace_browse"] },
  { pattern: /^deployables\/marketplace\/e2e\/critical-flows\.spec\.ts$/, suites: allMarketplaceSuiteIds },
  {
    pattern:
      /^deployables\/marketplace\/e2e\/(?:account-payment|buy-funnel-redesign|buyer-purchase-journey|sell-checkout-session)\.spec\.ts$/,
    suites: ["marketplace_checkout"],
  },
  {
    pattern: /^deployables\/marketplace\/e2e\/responsive-evidence-contract\.spec\.ts$/,
    suites: ["marketplace_browse"],
  },
  { pattern: /^deployables\/admin-web\/e2e\/access-/, suites: ["admin_access"] },
  {
    pattern: /^deployables\/admin-web\/e2e\/admin-tablet-navigation\.spec\.ts$/,
    suites: ["catalog_admin_integrations", "admin_support"],
  },
  { pattern: /^deployables\/admin-web\/e2e\/auth-shell-rbac\.spec\.ts$/, suites: ["admin_auth"] },
  { pattern: /^deployables\/admin-web\/e2e\/catalog-integrations\.spec\.ts$/, suites: ["catalog_admin_integrations"] },
  { pattern: /^deployables\/admin-web\/e2e\/catalog-scopes\.spec\.ts$/, suites: ["catalog_admin_integrations"] },
  { pattern: /^deployables\/admin-web\/e2e\/catalog-modeling\.spec\.ts$/, suites: ["catalog_admin_modeling"] },
  { pattern: /^deployables\/admin-web\/e2e\/commerce-/, suites: ["admin_commerce"] },
  { pattern: /^deployables\/admin-web\/e2e\/growth-/, suites: ["admin_growth"] },
  { pattern: /^deployables\/admin-web\/e2e\/support-/, suites: ["admin_support"] },
  {
    pattern: /^deployables\/admin-web\/e2e\/(?:admin-cross-cutting-topology|platform-projection-operations)\.spec\.ts$/,
    suites: ["admin_platform"],
  },
];

export const e2eNoSuiteExclusions = Object.freeze([
  {
    pattern:
      /^deployables\/marketplace\/app\/routes\/(?:chrome-devtools|favicon|favicon-svg|health-ready|manifest|robots|service-worker|sitemap)\./,
    reason: "Marketplace technical endpoint with static/runtime health coverage instead of browser journey coverage.",
  },
  {
    pattern: /^deployables\/admin-web\/e2e\/catalog-staging-provider-sync\.uat\.spec\.ts$/,
    reason: "Manual staging UAT spec; it is intentionally outside the CI grep suite catalog.",
  },
  {
    pattern: /^deployables\/marketplace\/e2e\/account-payment-stripe-embed\.uat\.spec\.ts$/,
    reason:
      "Manual staging UAT spec exercising the real Stripe embed -> confirm -> webhook path with live Stripe test-mode keys; it is intentionally outside the CI grep suite catalog.",
  },
  {
    pattern: /^deployables\/marketplace\/e2e\/payout-connect-appearance\.uat\.spec\.ts$/,
    reason:
      "Manual staging UAT spec exercising the real Stripe Connect embedded payout surface with live Stripe test-mode keys; it is intentionally outside the CI grep suite catalog.",
  },
  {
    pattern: /^deployables\/public-web\/e2e\/.*\.spec\.ts$/,
    reason:
      "public-presence/public-web deployed-target spec: the public-web Playwright project only exists when PUBLIC_WEB_URL names a running public-web host, and the PR browser-e2e system boots admin-web and marketplace only. It runs through test:e2e:deployed in the staging advisory evidence lane.",
  },
]);

const marketplaceRouteSuiteOwnership = [
  {
    pattern:
      /^deployables\/marketplace\/app\/routes\/(?:chrome-devtools|favicon|favicon-svg|health-ready|manifest|robots|service-worker|sitemap)\./,
    suites: [],
  },
  {
    pattern: /^deployables\/marketplace\/app\/routes\/(?:search|_index|index)\./,
    suites: ["marketplace_browse"],
  },
  {
    pattern: /^deployables\/marketplace\/app\/routes\/(?:account-payment|checkout-payment)/,
    suites: ["marketplace_checkout"],
  },
  {
    pattern:
      /^deployables\/marketplace\/app\/routes\/(?:account-listing|account-listings|account-inventory|account-offers|account-repricing)/,
    suites: ["marketplace_seller"],
  },
  {
    pattern:
      /^deployables\/marketplace\/app\/routes\/(?:account-purchase|account-sale|account-review|account-payout|account-settlement|account-support)/,
    suites: ["marketplace_account"],
  },
  {
    pattern: /^deployables\/marketplace\/app\/(?:auth\.server|root)\./,
    suites: ["marketplace_account", "marketplace_browse"],
  },
  {
    pattern: /^deployables\/marketplace\/app\/routes\/(?:not-found|offline)\./,
    suites: ["marketplace_browse"],
  },
  {
    pattern: /^deployables\/marketplace\/app\/routes\/layout\./,
    suites: allMarketplaceSuiteIds,
  },
];

const boundedContextRouteSuiteOwnership = [
  {
    pattern: /^bounded-contexts\/channels\/routes\/marketplace\/account-channel-connection\./,
    suites: ["marketplace_account"],
  },
  {
    pattern:
      /^bounded-contexts\/fulfillment\/(?:routes\/admin\/return-intake|features\/return-shipments\/(?:api|ui)\/)/,
    suites: ["admin_commerce"],
  },
  {
    pattern: /^bounded-contexts\/marketplace\/routes\/admin\/listing-evidence-policy\./,
    suites: ["admin_platform"],
  },
  {
    pattern: /^bounded-contexts\/marketplace\/features\/listing-evidence-policy\/(?:api|ui)\//,
    suites: ["admin_platform"],
  },
  {
    pattern: /^bounded-contexts\/identity\/routes\/admin\/accounts/,
    suites: ["admin_access"],
  },
  {
    pattern: /^bounded-contexts\/identity\/routes\/admin\/invitations/,
    suites: ["admin_access"],
  },
  {
    pattern: /^bounded-contexts\/identity\/routes\/admin\/api-keys/,
    suites: ["admin_access"],
  },
  {
    pattern: /^bounded-contexts\/identity\/features\/accounts\/(?:api|ui)\//,
    suites: ["admin_access"],
  },
  {
    pattern: /^bounded-contexts\/identity\/features\/invitations\/(?:api|ui)\//,
    suites: ["admin_access"],
  },
  {
    pattern: /^bounded-contexts\/identity\/features\/api-keys\/(?:api|ui)\//,
    suites: ["admin_access"],
  },
  {
    pattern: /^bounded-contexts\/commercial-terms\/routes\/admin\//,
    suites: ["admin_commerce"],
  },
  {
    pattern: /^bounded-contexts\/commercial-terms\/routes\/public\//,
    suites: ["marketplace_browse"],
  },
  {
    pattern: /^bounded-contexts\/commercial-terms\/features\/(?:schedules|agreements|resolutions)\/(?:api|ui)\//,
    suites: ["admin_commerce"],
  },
  {
    pattern: /^bounded-contexts\/ordering\/routes\/admin\/postage-policies/,
    suites: ["admin_commerce"],
  },
  {
    pattern: /^bounded-contexts\/ordering\/features\/postage-policies\/(?:api|ui)\//,
    suites: ["admin_commerce"],
  },
  {
    pattern: /^bounded-contexts\/inventory\/features\/recovered-items\/(?:api|ui)\//,
    suites: ["admin_commerce"],
  },
  {
    pattern: /^bounded-contexts\/discovery\/routes\/admin\/google-shopping\./,
    suites: ["admin_growth"],
  },
  {
    pattern: /^bounded-contexts\/discovery\/features\/google-shopping-operations\/(?:api|ui)\//,
    suites: ["admin_growth"],
  },
  {
    pattern: /^bounded-contexts\/public-presence\/routes\/admin\/waitlist\./,
    suites: ["admin_growth"],
  },
  {
    pattern: /^bounded-contexts\/public-presence\/features\/waitlist\/(?:api|ui)\//,
    suites: ["admin_growth"],
  },
  {
    pattern: /^bounded-contexts\/public-presence\/routes\/admin\/promo-bar\./,
    suites: ["admin_growth"],
  },
  {
    pattern: /^bounded-contexts\/platform-operations\/routes\/admin\/request(?:s|-detail)/,
    suites: ["admin_support"],
  },
  {
    pattern: /^bounded-contexts\/platform-operations\/features\/support-requests\/(?:api|ui)\//,
    suites: ["admin_support"],
  },
  {
    pattern: /^bounded-contexts\/platform-operations\/routes\/admin\/platform-feedback/,
    suites: ["admin_support"],
  },
  {
    pattern: /^bounded-contexts\/platform-operations\/routes\/admin\/projection-operations/,
    suites: ["admin_platform"],
  },
  {
    pattern: /^bounded-contexts\/customer-feedback\/(?:routes\/admin\/|features\/attention\/(?:api|ui)\/)/,
    suites: ["admin_support"],
  },
  {
    pattern: /^bounded-contexts\/catalog\/routes\/admin\/integrations\./,
    suites: ["catalog_admin_integrations"],
  },
  {
    pattern: /^bounded-contexts\/catalog\/routes\/admin\/integrations-/,
    suites: ["catalog_admin_integrations"],
  },
  {
    pattern: /^bounded-contexts\/catalog\/routes\/admin\/dimensions(?:-detail)?\./,
    suites: ["catalog_admin_modeling"],
  },
  {
    pattern: /^bounded-contexts\/catalog\/features\/dimensions\/(?:api|ui)\//,
    suites: ["catalog_admin_modeling"],
  },
  {
    pattern: /^bounded-contexts\/catalog\/routes\/admin\//,
    suites: ["catalog_admin_modeling"],
  },
  {
    pattern: /^bounded-contexts\/identity\/routes\/marketplace\//,
    suites: ["marketplace_account"],
  },
  {
    pattern: /^bounded-contexts\/marketplace\/routes\/marketplace\//,
    suites: ["marketplace_account"],
  },
  {
    pattern: /^bounded-contexts\/platform-operations\/routes\/marketplace\//,
    suites: ["marketplace_account"],
  },
  {
    pattern: /^bounded-contexts\/auth\/routes\/marketplace\//,
    suites: ["marketplace_account"],
  },
  {
    pattern: /^bounded-contexts\/auth\/routes\/(?:access-admin|catalog-admin)\//,
    suites: ["admin_auth", "admin_access"],
  },
  {
    pattern: /^bounded-contexts\/checkout\/routes\//,
    suites: ["marketplace_checkout"],
  },
  {
    pattern: /^bounded-contexts\/discovery\/routes\/(?:search|public-|account-product-alerts|set\.)/,
    suites: ["marketplace_browse"],
  },
  {
    pattern: /^bounded-contexts\/identity\/routes\/admin\//,
    suites: ["admin_access"],
  },
  {
    pattern: /^bounded-contexts\/marketplace\/routes\/account-(?:desk|listing|listings|offer)/,
    suites: ["marketplace_account", "marketplace_seller"],
  },
  {
    pattern: /^bounded-contexts\/ordering\/routes\/account-(?:purchase|sale)/,
    suites: ["marketplace_account"],
  },
  {
    pattern: /^bounded-contexts\/payments\/routes\/marketplace\/account-payment(?:-methods|-new)/,
    suites: ["marketplace_account"],
  },
  {
    pattern: /^bounded-contexts\/pricing\/routes\/marketplace\/account-repricing/,
    suites: ["marketplace_seller"],
  },
  {
    pattern: /^bounded-contexts\/settlement\/routes\/marketplace\//,
    suites: ["marketplace_account", "marketplace_seller"],
  },
  {
    pattern: /^bounded-contexts\/marketplace\/routes\/account-listing\./,
    suites: ["marketplace_account", "marketplace_seller"],
  },
  {
    // Milestone-25 decomposed route: browse -> item-detail commerce panel
    // composition is owned by the marketplace_browse item-detail e2e spec.
    // Also covers the item-detail-market-history.tsx resource route (m111
    // market panel): its Sales-tab range/data fetch is exercised by the same
    // spec's Sales-tab assertion.
    pattern: /^bounded-contexts\/discovery\/routes\/item-detail(?:\.|-market-history\.)/,
    suites: ["marketplace_browse"],
  },
  {
    // Milestone-25 decomposed route: the sell-handoff composition + readiness
    // redirect chain is owned by the marketplace_checkout sell-checkout-session spec.
    pattern: /^bounded-contexts\/checkout\/routes\/sell-checkout-session\./,
    suites: ["marketplace_checkout"],
  },
  {
    // Milestone-25 decomposed routes: the signed-in payment confirmation surface
    // and the guest checkout-payment claim entry point are owned by the
    // marketplace_checkout account-payment spec.
    pattern: /^bounded-contexts\/payments\/routes\/marketplace\/(?:account-payment|checkout-payment)\./,
    suites: ["marketplace_checkout"],
  },
  {
    pattern: /^bounded-contexts\/public-presence\/routes\/marketplace\//,
    suites: ["marketplace_browse"],
  },
  {
    pattern: /^bounded-contexts\/public-presence\/routes\/developers\//,
    suites: ["marketplace_browse"],
  },
  {
    pattern: /^bounded-contexts\/public-presence\/features\/waitlist\/ui\/public-pages\./,
    suites: ["marketplace_browse"],
  },
  {
    pattern: /^bounded-contexts\/notifications\/routes\/account-notifications\./,
    suites: ["marketplace_account"],
  },
];

function normalizeFilePath(filePath) {
  return filePath.replace(/\\/g, "/").replace(/^\.\//, "");
}

function matchesAny(filePath, patterns) {
  return patterns.some((pattern) => pattern.test(filePath));
}

export function isBrowserRuntimeFile(filePath) {
  return matchesAny(normalizeFilePath(filePath), browserRuntimePatterns);
}

export function isDesignSystemNavigationFile(filePath) {
  return isDesignSystemNavigationRiskPath(filePath);
}

export function orderE2eSuiteIds(suiteIds) {
  return [...new Set(suiteIds)].sort((left, right) => (suiteOrder.get(left) ?? 999) - (suiteOrder.get(right) ?? 999));
}

export function batchE2eSuiteIds(suiteIds, batchSize = defaultSuiteBatchSize) {
  const orderedSuiteIds = orderE2eSuiteIds(suiteIds);
  const safeBatchSize = Math.max(1, batchSize);
  const batchCount = Math.ceil(orderedSuiteIds.length / safeBatchSize);
  const batches = Array.from({ length: batchCount }, (_entry, index) => ({
    estimatedDurationSeconds: 0,
    index,
    suiteIds: [],
  }));

  const suiteIdsByDescendingDuration = [...orderedSuiteIds].sort((left, right) => {
    const durationDelta = estimatedE2eSuiteDurationSeconds(right) - estimatedE2eSuiteDurationSeconds(left);
    return durationDelta === 0 ? (suiteOrder.get(left) ?? 999) - (suiteOrder.get(right) ?? 999) : durationDelta;
  });

  for (const suiteId of suiteIdsByDescendingDuration) {
    const targetBatch = batches
      .filter((batch) => batch.suiteIds.length < safeBatchSize)
      .sort(
        (left, right) =>
          left.estimatedDurationSeconds - right.estimatedDurationSeconds ||
          left.suiteIds.length - right.suiteIds.length ||
          left.index - right.index,
      )[0];

    targetBatch.suiteIds.push(suiteId);
    targetBatch.estimatedDurationSeconds += estimatedE2eSuiteDurationSeconds(suiteId);
  }

  return batches.map((batch) => orderE2eSuiteIds(batch.suiteIds).join(","));
}

export function e2eSuiteById(suiteId) {
  return suitesById.get(suiteId);
}

export function estimatedE2eSuiteDurationSeconds(suiteId) {
  return e2eSuiteById(suiteId)?.estimatedDurationSeconds ?? fallbackEstimatedSuiteDurationSeconds;
}

export function isE2eSpecFile(filePath) {
  return /^deployables\/(?:marketplace|admin-web|public-web)\/e2e\/.*\.spec\.ts$/.test(normalizeFilePath(filePath));
}

export function isRouteFile(filePath) {
  const normalized = normalizeFilePath(filePath);
  if (/\.(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs)$/.test(normalized)) {
    return false;
  }

  return (
    /^deployables\/(?:marketplace|admin-web)\/app\/routes\/.*\.(?:ts|tsx|js|jsx)$/.test(normalized) ||
    /^bounded-contexts\/[^/]+\/routes\/.*\.(?:ts|tsx|js|jsx)$/.test(normalized)
  );
}

export function e2eNoSuiteExclusionForChangedFile(filePath) {
  const normalized = normalizeFilePath(filePath);
  return e2eNoSuiteExclusions.find((exclusion) => exclusion.pattern.test(normalized)) ?? null;
}

function e2eSpecSuiteIdsForChangedFile(filePath) {
  for (const specOwnership of e2eSpecSuiteOwnership) {
    if (specOwnership.pattern.test(filePath)) {
      return specOwnership.suites;
    }
  }

  return e2eNoSuiteExclusionForChangedFile(filePath) ? [] : allBrowserSuiteIds;
}

function isTestOnlyOrDocumentationFile(filePath) {
  return (
    /\.(?:test|spec)\.(?:ts|tsx|js|jsx|mjs|cjs)$/.test(filePath) ||
    /(?:^|\/)(?:__tests__|tests|test-support)\//.test(filePath) ||
    /\.(?:md|mdx)$/.test(filePath)
  );
}

function marketplaceDeployableSuiteIdsForChangedFile(filePath) {
  if (e2eNoSuiteExclusionForChangedFile(filePath)) {
    return [];
  }

  if (isTestOnlyOrDocumentationFile(filePath)) {
    return [];
  }

  for (const routeOwnership of marketplaceRouteSuiteOwnership) {
    if (routeOwnership.pattern.test(filePath)) {
      return routeOwnership.suites;
    }
  }

  return allMarketplaceSuiteIds;
}

function boundedContextSuiteIdsForChangedFile(filePath, contextName) {
  if (isTestOnlyOrDocumentationFile(filePath)) {
    return [];
  }

  for (const routeOwnership of boundedContextRouteSuiteOwnership) {
    if (routeOwnership.pattern.test(filePath)) {
      return routeOwnership.suites;
    }
  }

  if (/(?:^|\/)routes\//.test(filePath)) {
    if (/^bounded-contexts\/[^/]+\/routes\/marketplace\//.test(filePath)) {
      return marketplaceContextRouteSuiteOwnership.get(contextName) ?? [];
    }
    if (/^bounded-contexts\/[^/]+\/routes\/(?:admin|access-admin|catalog-admin)\//.test(filePath)) {
      return adminContextRouteSuiteOwnership.get(contextName) ?? [];
    }

    return [];
  }

  return contextSuiteOwnership.get(contextName) ?? [];
}

export function e2eSuiteIdsForChangedFile(filePath) {
  const normalized = normalizeFilePath(filePath);

  if (isE2eSpecFile(normalized)) {
    return e2eSpecSuiteIdsForChangedFile(normalized);
  }

  if (isBrowserRuntimeFile(normalized)) {
    return allBrowserSuiteIds;
  }

  if (normalized.startsWith("deployables/marketplace/")) {
    return marketplaceDeployableSuiteIdsForChangedFile(normalized);
  }

  if (normalized.startsWith("deployables/admin-web/")) {
    return isTestOnlyOrDocumentationFile(normalized) ? [] : allAdminWebSuiteIds;
  }

  if (normalized.startsWith("deployables/platform-api/")) {
    return isTestOnlyOrDocumentationFile(normalized) ? [] : allBrowserSuiteIds;
  }

  if (normalized.startsWith("packages/design-system/")) {
    if (isTestOnlyOrDocumentationFile(normalized)) {
      return [];
    }

    return isDesignSystemNavigationFile(normalized) ? allBrowserSuiteIds : allMarketplaceSuiteIds;
  }

  const boundedContextMatch = normalized.match(
    /^bounded-contexts\/([^/]+)\/(?:(?:routes\/)|(?:features\/[^/]+\/(?:api|ui)\/)|(?:support\/shell-support\/))/,
  );
  if (!boundedContextMatch) {
    return [];
  }

  return boundedContextSuiteIdsForChangedFile(normalized, boundedContextMatch[1] ?? "");
}
