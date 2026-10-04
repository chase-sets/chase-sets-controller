[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$ExpectedControllerHead = ""
)

$ErrorActionPreference = "Stop"
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$baseHead = "af24feeabe2df0143e59461ad652291ab0b46936"
$provenanceBaseHead = "c53405bd25eed66232cc3f470e0dd2da3fd69bbf"
$productMainHead = "0fb05e89907f1dc196bbc9a07fa7f852ae81c3fc"
$expectedPaths = @(
  ".orchestrator/controller-release-battery.ps1",
  ".orchestrator/controller-release-battery.test.ps1",
  ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md",
  ".orchestrator/fail-closed-guard-evidence-aggregate.ps1",
  ".orchestrator/fail-closed-guard-evidence-aggregate.test.ps1",
  ".orchestrator/fail-closed-guard-suite-result.schema.json",
  ".orchestrator/install-controller-skills.ps1",
  ".orchestrator/install-controller-skills.test.ps1",
  ".orchestrator/invoke-heavy-verifier.ps1",
  ".orchestrator/issue-6997-autonomy-policy.test.ps1"
)
$baseBlobs = [ordered]@{
  ".orchestrator/landing-preflight.ps1" = "b326bd27922b4791f72eb7220d9436625f6ff488"
  ".orchestrator/landing-preflight.test.ps1" = "c269365bd3e44adbfc06fae86c6b48831c4499be"
  ".orchestrator/issue-6254-fail-closed-guard-evidence.test.ps1" = "18259c116fa37bb2446c716d2ae26b1175b80e42"
  ".orchestrator/issue-6997-autonomy-policy.test.ps1" = "b8f9f7e5698338733364d97611feabb3ede80991"
  ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md" = "c65d50ed03d917b779455cedc20929d31f7db7cb"
}
$script:assertions = 0
$script:claims = [Collections.Generic.List[object]]::new()

function Assert-6997([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Normalize-Text([string]$Text) {
  return ($Text -replace "`r`n", "`n" -replace "`r", "`n")
}

function Compact-Text([string]$Text) {
  return ((Normalize-Text $Text) -replace "\s+", " ").Trim()
}

function Get-RepoText([string]$RelativePath) {
  return Normalize-Text ([IO.File]::ReadAllText((Join-Path $controller $RelativePath)))
}

function Get-BaseText([string]$RelativePath) {
  $spec = "${baseHead}:$RelativePath"
  $stdoutPath = [IO.Path]::GetTempFileName()
  $stderrPath = [IO.Path]::GetTempFileName()
  try {
    & git -C $controller show $spec 1> $stdoutPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
    Assert-6997 ($exitCode -eq 0) "base text does not resolve: $spec"
    return Normalize-Text ([IO.File]::ReadAllText($stdoutPath))
  } finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

function Get-Section([string]$Text, [int]$Number) {
  $match = [regex]::Match(
    (Normalize-Text $Text),
    "(?ms)^## $Number\.[^\n]*\n.*?(?=^## \d+\.|\z)"
  )
  if (-not $match.Success) { return $null }
  return $match.Value.TrimEnd("`n")
}

function Test-ReleaseIdentity([string]$Milestone, [string]$Routing) {
  $milestoneHeaders = [regex]::Matches($Milestone, "(?m)^# Milestone Orchestrator \(v\d+\.\d+, \d{4}-\d{2}-\d{2}\)$")
  $routingHeaders = [regex]::Matches($Routing, "(?m)^# Model Routing \(v\d+\.\d+, \d{4}-\d{2}-\d{2}\)$")
  return (
    $milestoneHeaders.Count -eq 1 -and
    $milestoneHeaders[0].Value -ceq "# Milestone Orchestrator (v2.99, 2026-10-04)" -and
    $routingHeaders.Count -eq 1 -and
    $routingHeaders[0].Value -ceq "# Model Routing (v4.20, 2026-10-02)" -and
    -not $Routing.Contains("v4.5", [StringComparison]::Ordinal) -and
    $archive.Contains("Version 2.60 removes overhead that returns nothing for one operator", [StringComparison]::Ordinal) -and
    $archive.Contains("Version 2.59 removes the runtime retired by v2.58", [StringComparison]::Ordinal) -and
    -not $Milestone.Contains("Version 2.60 removes overhead", [StringComparison]::Ordinal) -and
    -not $Milestone.Contains("# Milestone Orchestrator (v2.41, 2026-08-03)", [StringComparison]::Ordinal) -and
    -not $Milestone.Contains("Version 2.42 remains reserved", [StringComparison]::Ordinal)
  )
}

# v2.60 retired the two-tier/five-mode decision machine from the live skill; its
# vocabulary is pinned verbatim in the provenance archive's v2.60 entry.
function Test-Vocabulary([string]$Archive) {
  $match = [regex]::Match(
    (Normalize-Text $Archive),
    "(?ms)^### Section 11 decision tiers, modes, and premise freshness retired by v2\.60\n.*?(?=^### |^## |\z)"
  )
  if (-not $match.Success) { return $false }
  $section = $match.Value.TrimEnd("`n")
  $compact = Compact-Text $section
  $tierMatches = [regex]::Matches($section, '(?m)^- `(adopt|gate)`:')
  $modeSentence = 'The five and only five modes are `auto-adopted`, `hard-gated`, `ratified`, `overridden`, and `superseded`.'
  return (
    $section.Contains("Decision autonomy has exactly two tiers:", [StringComparison]::Ordinal) -and
    $tierMatches.Count -eq 2 -and
    @($tierMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count -eq 2 -and
    $compact.Contains($modeSentence, [StringComparison]::Ordinal) -and
    $compact.Contains('An override cause is exactly `stale-premise` or `judgment`.', [StringComparison]::Ordinal) -and
    -not $section.Contains("stale premise", [StringComparison]::Ordinal) -and
    $compact.Contains('filed `adopt` only to `auto-adopted`', [StringComparison]::Ordinal) -and
    $compact.Contains('filed `gate` only to `hard-gated`', [StringComparison]::Ordinal) -and
    $compact.Contains("closure alone is not ratification", [StringComparison]::Ordinal) -and
    $compact.Contains("prose cannot produce supersession", [StringComparison]::Ordinal) -and
    $compact.Contains("competing, out-of-order, or terminal-to-terminal movement refuses", [StringComparison]::Ordinal)
  )
}

function Test-AcceptedReplanContract([string]$Contract) {
  $grammar = @'
### changedSinceLastFailure
terminalReceipt: <exact terminal comment URL; comment ID; lineage root; issue/PR/head/attempt identity>
changedFact: <external|architectural|dependency|evidence|scope> - <specific changed fact; source URL/identity; observed UTC instant>
invalidationReason: <why the fact invalidates the prior failure or enables a different bounded approach>
newCeiling: attempts=<positive absolute integer>; nonPass=PARK; authority=<existing binding URL/ID or separate governing ruling URL/comment ID>
'@
  $compact = Compact-Text $Contract
  return (
    [regex]::Matches($Contract, "(?m)^### changedSinceLastFailure$").Count -eq 1 -and
    $Contract.Contains((Normalize-Text $grammar).Trim(), [StringComparison]::Ordinal) -and
    $compact.Contains("Each label appearing once and carrying a non-space payload", [StringComparison]::OrdinalIgnoreCase) -and
    $compact.Contains('planning-repair/v1` completion receipt', [StringComparison]::Ordinal) -and
    $compact.Contains("fresh independent complete-sweep semantic PASS", [StringComparison]::Ordinal) -and
    $compact.Contains("exact current body revision/hash, terminal receipt ID/URL, and immutable artifact identity", [StringComparison]::Ordinal) -and
    $compact.Contains("It grants no attempt authority", [StringComparison]::Ordinal) -and
    $compact.Contains("Billed USD is recorded telemetry and is never a ceiling", [StringComparison]::Ordinal) -and
    $compact.Contains("separate already-governing authority", [StringComparison]::Ordinal) -and
    $compact.Contains("Attempt-ceiling authority must already govern before admission.", [StringComparison]::Ordinal) -and
    $compact.Contains("It is either a Todd-authored ruling or a recorded final independent decision-lane verdict under milestone-orchestrator section 11", [StringComparison]::Ordinal) -and
    $compact.Contains("bound to that lineage root, terminal receipt, and exact absolute ceiling", [StringComparison]::Ordinal) -and
    $compact.Contains("That decision lane is separate from this replan's author, repairer, and reviewers.", [StringComparison]::Ordinal) -and
    $compact.Contains("Neither this replan nor its semantic PASS can supply it.", [StringComparison]::Ordinal) -and
    $compact.Contains('resets no lineage history or consumed count, and never makes `newCeiling` incremental', [StringComparison]::Ordinal) -and
    $compact.Contains("Missing, stale, broader, self-authored, unreadable, or merely recommended authority leaves the item parked", [StringComparison]::Ordinal) -and
    $compact.Contains("never files a cap-only Decision", [StringComparison]::Ordinal)
  )
}

function Get-ProvenanceBlock([string]$Archive) {
  $normalized = Normalize-Text $Archive
  $startMarker = '**v2.45 encoded two-tier decision autonomy'
  $endMarker = '**v2.44 serialized ops/controller work'
  $startMatches = [regex]::Matches($normalized, '(?m)^\*\*v2\.45 encoded two-tier decision autonomy')
  $endMatches = [regex]::Matches($normalized, '(?m)^\*\*v2\.44 serialized ops/controller work')
  if ($startMatches.Count -ne 1 -or $endMatches.Count -ne 1) { return $null }
  $start = $startMatches[0].Index
  $end = $endMatches[0].Index
  if ($end -le $start) { return $null }
  $block = $normalized.Substring($start, $end - $start)
  if ([string]::IsNullOrWhiteSpace($block) -or -not $block.Contains($startMarker, [StringComparison]::Ordinal)) { return $null }
  return $block
}

function Test-Provenance([string]$Archive) {
  $block = Get-ProvenanceBlock $Archive
  if ($null -eq $block) { return $false }
  $compact = (Compact-Text $block) -replace '>\s+', ''
  return (
    $compact.Contains("v2.45 encoded two-tier decision autonomy", [StringComparison]::Ordinal) -and
    $block.Contains($provenanceBaseHead, [StringComparison]::Ordinal) -and
    $compact.Contains("two decision-autonomy tiers, five modes, two override causes", [StringComparison]::Ordinal) -and
    $compact.Contains("one standing artifact-cap continuation followed by one idempotent terminal park", [StringComparison]::Ordinal) -and
    $compact.Contains("The release added no event schema or telemetry implementation change.", [StringComparison]::Ordinal) -and
    $Archive.Contains("**v2.44 serialized ops/controller work", [StringComparison]::Ordinal) -and
    -not [regex]::IsMatch($block, "(?i)model[- _]routing|v4\.")
  )
}

function Test-ControllerBase([string]$Head) {
  if ($Head -cnotmatch "^[a-f0-9]{40}$") { return $false }
  & git -C $controller cat-file -e "${Head}^{commit}" 2>$null
  if ($LASTEXITCODE -ne 0) { return $false }
  foreach ($path in $baseBlobs.Keys) {
    & git -C $controller cat-file -e "${Head}:$path" 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
  }
  return $Head -ceq $baseHead
}

# Policy pin (v2.52): the candidate keeps the base head's fifteen section titles
# in order and carries every reviewed required statement verbatim. Section
# bytes are not frozen; a reviewed rule change edits this statement list.
$script:requiredMilestoneStatements = @(
  'Astra (`gpt-6-astra`) is selectable for Codex tasks and as the registered `astra-high` host arm. Sol high remains the default. Model selection does not relax single-writer exclusivity, exact review authority, release promotion, or spend rules; Astra evidence starts independently from every predecessor.',
  "Record spend per model-routing's telemetry rules; spend never opens a breaker.",
  'the host rotates only when Todd says so; no lease freshness, session limit, or spend rotates a host',
  'the record is identity, not exclusion',
  'Body size is never a readiness gate',
  'retry with backoff and open no breaker',
  'Spend rolls up once per UTC day',
  'Post a status entry on #4388 only after a landing, a breaker change, or two hours without one, at most 1,500 bytes',
  'No USD figure is a ceiling.',
  'a brief takes at most two complete-sweep semantic reviews in its lifetime',
  'an implementation takes one exact-head code review before ready',
  'Reviewers apply mechanical fixes (pins, counts, generated outputs, lint) directly on the branch and let hosted CI validate them',
  'A reviewed draft PR is always the implementation head for its issue',
  'An artifact that accumulates more than four implementation attempts stops dispatching',
  'Review, repair, and planning rounds never count toward this ceiling.',
  'Semantic implementation G1 identity and attempt counts persist across repair.',
  'The lane name identifies the current author or reviewer execution',
  'reuse on an unrelated issue/head cannot poison a current controller candidate',
  'Landings are ordered by the merge queue alone.',
  'A PASS review is authority to push, publish, mark ready, and enqueue',
  'funding a bounded review, repair, verification, or re-review never needs a Decision',
  'At most two concurrent lanes serve `kind:ops` or controller work',
  'A host continuation note is at most 2,000 bytes',
  'No packet manifest, evidence file, or hash comparison is required of any lane',
  'the relaunch continues from the partial, never from zero',
  'A Todd-authored change takes one independent review and installs at once',
  'the controller never registers push sequences, evidence-only pushes, single-push limits, or a local full battery as a precondition',
  'the controller enqueues on its own authority and no held landing order exists; Todd never enqueues on the controller''s behalf',
  'A refusal of a landing-authority-complete PR by any controller gate for a reason that is not a product finding is a controller P0',
  'enqueue the product PR directly once with GitHub `enqueuePullRequest`',
  'Manual fallback on #4388 is used only when the direct mutation fails or the refused candidate is a controller release',
  'the host runs the representative refresh in-cluster itself',
  'The host reads the failing run''s log itself and dispatches no diagnosis lane',
  'Two blocking rounds on the same PR force a third repair that applies the reviewer''s prescribed remedies verbatim, never a replan',
  'An ops-kind issue is dispatched only when a ready product issue is blocked on it or Todd names it',
  '`bookkeeping`, `note`, and `flow-snapshot` are not accepted',
  'A decision is one comment on #4388',
  'There are no tiers, modes, premise-freshness verdicts, or transition rules',
  'Launch the pinned Codex executable',
  'Remove nothing else without Todd''s word',
  'No flow snapshot, replan reconciliation, or metrics check exists in the cycle',
  'The selected battery runs once per candidate head, by the author lane, with its log bound to the exact head; the governing review verifies that log and re-runs only the tests the diff changed',
  'A review report is the report alone: no manifest, evidence file, or hash comparison',
  'A breaker never blocks its own repair.',
  'a controller P0 ships out of band by default without a Todd ruling',
  'A P0 repair brief is exempt from the planning pressure sweep',
  'A breaker open more than four hours with no repair candidate in flight is a stall alert',
  'parking a ruling''s implementation, or conditioning it on an empty product frontier, is prohibited',
  'a repair is re-read as a delta review over its changed hunks that inherits the predecessor sweep',
  'Every controller release, Todd-authored or controller-authored, takes one governing review scoped to its change and installs on PASS; there is no packet lifecycle and no weekly release train',
  'There is no standing-cap continuation row, no escalation count, and no ceiling authority ceremony',
  'The author-iteration battery runs the impact scope: the smoke set (policy pin, contract enforcement, installer, battery self-test, landing preflight), the changed tests, the guard discriminators, and every test that reads a changed file, following code readers transitively and skill, contract and data readers directly.',
  'No baseline, `-Scope full`, or a changed runtime file that no test reads runs the full battery; a battery change adds its full self-test.',
  'In an impact run a guard-omission mutant or #8102 classifier leg runs only when its guarded file or the carrier support changed; candidate arms always run.',
  'Tests run fastest first and the battery stops at the first failure that is not PREEXISTING, naming the rest not run (`-OnFailure all` runs all).',
  'A failure that reproduces identically on the installed baseline ends `FAIL_PREEXISTING_ONLY`, which never prints PASS; the governing review accepts it once each named item has an open issue, and nothing waits on that issue.',
  'The #6026 protected sweep runs only after a landing that touches its footprint and at most once per 24 hours',
  'Only confirmed correctness, security, or objective quality findings block',
  'Every review receipt carries the `G0` gate answer, the quality profile, and a two-sided verdict on all twelve pairs of `contracts/quality-v2.md`, one line per key.',
  'a side blocks only on its reproducible sub-case at the weight its profile sets',
  'Non-blocking findings carry stable IDs and stay in the receipt; the controller files no issue, debt slice, or weekly review from them',
  'A non-blocking finding never delays landing.',
  'Quality verdicts are retro input: recalibration reads `NOTE` counts by key, side, profile, and author model from the review receipts and tunes the profile weight table only when Todd asks for a recalibration'
)

function Get-SectionTitles([string]$Text) {
  return @([regex]::Matches((Normalize-Text $Text), "(?m)^## (\d+)\. (.*)$") | ForEach-Object { $_.Value })
}

function Test-PreservedSections([string]$Candidate, [string]$Base) {
  $baseTitles = Get-SectionTitles $Base
  $candidateTitles = Get-SectionTitles $Candidate
  if ($baseTitles.Count -ne 15 -or (($baseTitles -join "`n") -cne ($candidateTitles -join "`n"))) { return $false }
  $compact = Compact-Text $Candidate
  foreach ($statement in $script:requiredMilestoneStatements) {
    if (-not $compact.Contains((Compact-Text $statement), [StringComparison]::Ordinal)) { return $false }
  }
  return $true
}

function Add-MutantClaim([string]$Id, [bool]$CandidatePassed, [bool]$MutantPassed, [string]$GoverningVariable) {
  Assert-6997 $CandidatePassed "$Id candidate was not green"
  Assert-6997 (-not $MutantPassed) "$Id bypass mutant survived"
  $script:claims.Add([pscustomobject][ordered]@{
    id = $Id
    governingVariable = $GoverningVariable
    preservedVariables = "all other fixture and policy inputs"
    candidate = "PASS"
    bypassMutant = "FAIL"
  })
}

function Test-DescendantFootprint([string[]]$Expected, [string[]]$Actual) {
  $actualSet = [Collections.Generic.HashSet[string]]::new([string[]]$Actual, [StringComparer]::Ordinal)
  return @($Expected | Where-Object { -not $actualSet.Contains($_) }).Count -eq 0
}

function Test-BatteryDiscoveryContract([string]$Source) {
  return (
    $Source.Contains("ls-tree -r --name-only", [StringComparison]::Ordinal) -and
    $Source.Contains('$ExpectedControllerHead', [StringComparison]::Ordinal) -and
    $Source.Contains('^\.orchestrator/.+\.test\.ps1$', [StringComparison]::Ordinal)
  )
}

$milestonePath = ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md"
$archivePath = ".orchestrator/controller-skills/milestone-orchestrator/references/rule-provenance-v2.24.md"
$routingPath = ".orchestrator/controller-skills/model-routing/SKILL.md"
$contractPath = ".orchestrator/contracts/planning-repair-v1.md"
$milestone = Get-RepoText $milestonePath
$baseMilestone = Get-BaseText $milestonePath
$archive = Get-RepoText $archivePath
$routing = Get-RepoText $routingPath
$contract = Get-RepoText $contractPath

$liveHead = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
Assert-6997 ($LASTEXITCODE -eq 0 -and $liveHead -cmatch "^[a-f0-9]{40}$") "live controller head is unreadable"
if ($ExpectedControllerHead) {
  Assert-6997 ($ExpectedControllerHead -ceq $liveHead) "expected controller head does not match live head"
}

foreach ($entry in $baseBlobs.GetEnumerator()) {
  $observed = (& git -C $controller rev-parse "${baseHead}:$($entry.Key)" 2>&1 | Out-String).Trim()
  Assert-6997 ($LASTEXITCODE -eq 0 -and $observed -ceq $entry.Value) "base blob drift for $($entry.Key)"
}
Assert-6997 (Test-ControllerBase $baseHead) "authenticated controller base does not resolve"
Add-MutantClaim "product-main-head" $true (Test-ControllerBase $productMainHead) "provenance head"
Add-MutantClaim "nonexistent-base-head" $true (Test-ControllerBase ("f" * 40)) "provenance head"

function Get-GitPathLines([string[]]$Arguments, [string]$FailureMessage) {
  $stdoutPath = [IO.Path]::GetTempFileName()
  $stderrPath = [IO.Path]::GetTempFileName()
  try {
    & git @Arguments 1> $stdoutPath 2> $stderrPath
    $exitCode = $LASTEXITCODE
    $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
    Assert-6997 ($exitCode -eq 0) "${FailureMessage}: $stderr"
    return @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue | Where-Object { $_ } | ForEach-Object { $_.Replace("\", "/") })
  }
  finally {
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
  }
}

$changed = @(Get-GitPathLines @('-C', $controller, 'diff', '--name-only', $baseHead, '--') 'base-to-candidate diff cannot be read')
$untracked = @(Get-GitPathLines @('-C', $controller, 'ls-files', '--others', '--exclude-standard') 'untracked footprint cannot be read')
$actualPaths = @($changed + $untracked | Sort-Object -Unique)
$missingProtectedFootprint = @($expectedPaths | Where-Object { $_ -notin $actualPaths })
Assert-6997 (Test-DescendantFootprint $expectedPaths $actualPaths) "protected #6997 footprint is missing tracked paths: $($missingProtectedFootprint -join ', ')"

# SYNTHETIC-DESCENDANT-6997-OUTSIDE-FOOTPRINT-v2: an unmistakably synthetic path
# outside the historical fixed footprint (#7203's real six paths, #7505's real
# three paths, and any other future descendant) must be accepted by the ratchet
# while every protected #6997 semantic/history/provenance control stays exact.
$syntheticDescendantPath = ".orchestrator/SYNTHETIC-UNRELATED-DESCENDANT-v2.txt"
Assert-6997 ($syntheticDescendantPath -notin $expectedPaths) "synthetic descendant fixture collides with the protected #6997 footprint"
$syntheticActualPaths = @($actualPaths + $syntheticDescendantPath | Sort-Object -Unique)
Assert-6997 (Test-DescendantFootprint $expectedPaths $syntheticActualPaths) "corrected ratchet must accept an unrelated descendant outside the historical #6997 footprint"
Assert-6997 (@(Compare-Object ($expectedPaths | Sort-Object) $syntheticActualPaths).Count -gt 0) "positive descendant fixture must actually differ from the frozen footprint, or it proves nothing against the old fixed-equality clause"

Assert-6997 (Test-PreservedSections $milestone $baseMilestone) "a milestone section title moved or a required statement is missing"
$section13Mutant = $milestone.Replace("## 13. Bookkeeping and digest", "## 13. Bookkeeping and altered digest")
Add-MutantClaim "unowned-byte" $true (Test-PreservedSections $section13Mutant $baseMilestone) "section 13 byte"
$astraParagraphMutant = $milestone.Replace(
  "rules; Astra evidence starts independently from every predecessor.",
  "rules; Astra evidence starts dependently from every predecessor.",
  [StringComparison]::Ordinal)
Add-MutantClaim "astra-section-1-paragraph" $true (Test-PreservedSections $astraParagraphMutant $baseMilestone) "exact reviewed Astra section-1 paragraph"
$spendCapMutant = $milestone.Replace(
  "Record spend per model-routing's telemetry rules; spend never opens a",
  "Apply model-routing's governing spend caps and notification ladder. Stop only",
  [StringComparison]::Ordinal)
Add-MutantClaim "spend-telemetry-section-12-delta" $true (Test-PreservedSections $spendCapMutant $baseMilestone) "exact reviewed v2.51 spend-telemetry deltas"
$attemptCeilingMutant = $milestone.Replace(
  "An artifact that accumulates more than four implementation attempts stops",
  "An artifact that accumulates more than eight attempt rounds across all lane roles stops",
  [StringComparison]::Ordinal)
Add-MutantClaim "attempt-ceiling-counts-implementation-only" $true (Test-PreservedSections $attemptCeilingMutant $baseMilestone) "v2.52 attempt ceiling statement"
$packetExemptionMutant = $milestone.Replace("there is no packet`nlifecycle and no weekly release train", "a packet lifecycle and a weekly`nrelease train remain", [StringComparison]::Ordinal)
Add-MutantClaim "release-packet-lifecycle-reintroduced" $true (Test-PreservedSections $packetExemptionMutant $baseMilestone) "v2.58 one review, no packets, no train"
$leaseRotationMutant = $milestone.Replace("rotates only`nwhen Todd says so", "rotates daily`nor at the session limit", [StringComparison]::Ordinal)
Add-MutantClaim "lease-rotation-reintroduced" $true (Test-PreservedSections $leaseRotationMutant $baseMilestone) "v2.58 host rotates only on Todd instruction"
$noiseBreakerMutant = $milestone.Replace("retry with backoff`nand open no breaker", "open the affected breaker`nand stop")
Add-MutantClaim "noise-breaker-reintroduced" $true (Test-PreservedSections $noiseBreakerMutant $baseMilestone) "v2.58 tooling noise opens no breaker"
$sweepCadenceMutant = $milestone.Replace("at most once per 24 hours", "every two hours", [StringComparison]::Ordinal)
Add-MutantClaim "protected-sweep-fixed-cadence" $true (Test-PreservedSections $sweepCadenceMutant $baseMilestone) "#6026 footprint-triggered, max-once-24h cadence"
$qualityVerdictMutant = $milestone.Replace("two-sided verdict on all twelve pairs", "one-sided verdict on any pair", [StringComparison]::Ordinal)
Add-MutantClaim "quality-verdict-partial" $true (Test-PreservedSections $qualityVerdictMutant $baseMilestone) "v2.56 two-sided verdict on all twelve pairs"
$qualityWeightMutant = $milestone.Replace("its profile sets", "any profile allows", [StringComparison]::Ordinal)
Add-MutantClaim "quality-weight-ignored" $true (Test-PreservedSections $qualityWeightMutant $baseMilestone) "v2.56 profile weight governs blocking"
$landingStallMutant = $milestone.Replace("is a controller P0: enqueue", "is a routine refusal: enqueue", [StringComparison]::Ordinal)
Add-MutantClaim "landing-refusal-not-p0" $true (Test-PreservedSections $landingStallMutant $baseMilestone) "v2.57 landing refusal of a complete-authority PR is a controller P0"
$breakerRepairMutant = $milestone.Replace("A breaker never blocks its own repair.", "A breaker blocks its own repair until cleared.", [StringComparison]::Ordinal)
Add-MutantClaim "breaker-blocks-own-repair" $true (Test-PreservedSections $breakerRepairMutant $baseMilestone) "v2.57 breaker-repair admission"
$outOfBandMutant = $milestone.Replace("ships out of band by default without a Todd ruling", "ships on the weekly train unless Todd rules P0", [StringComparison]::Ordinal)
Add-MutantClaim "controller-p0-waits-for-train" $true (Test-PreservedSections $outOfBandMutant $baseMilestone) "v2.57 controller P0 out-of-band default"
$parkRulingMutant = $milestone.Replace("is prohibited.", "is permitted when the product frontier is busy.", [StringComparison]::Ordinal)
Add-MutantClaim "ruling-implementation-parked" $true (Test-PreservedSections $parkRulingMutant $baseMilestone) "v2.57 ruling implementation never parked"
$noteDiscardMutant = $milestone.Replace("stay in the receipt; the controller`nfiles no issue, debt slice, or weekly review from them", "are discarded after landing", [StringComparison]::Ordinal)
Add-MutantClaim "non-blocking-findings-discarded" $true (Test-PreservedSections $noteDiscardMutant $baseMilestone) "v2.54 non-blocking finding consumption"
# v2.60: overhead removals pinned against reintroduction.
$diagnosisLaneMutant = $milestone.Replace("dispatches no diagnosis lane;`na failure gets one author lane", "dispatches a diagnosis lane;`na failure gets one diagnosis lane", [StringComparison]::Ordinal)
Add-MutantClaim "diagnosis-lane-reintroduced" $true (Test-PreservedSections $diagnosisLaneMutant $baseMilestone) "v2.60 host reads logs, no diagnosis lane"
$twoBlockReplanMutant = $milestone.Replace("force a third repair`nthat applies the reviewer's prescribed remedies verbatim, never a replan", "force replan;`ndo not buy a third repair with higher effort", [StringComparison]::Ordinal)
Add-MutantClaim "two-block-replan-reintroduced" $true (Test-PreservedSections $twoBlockReplanMutant $baseMilestone) "v2.60 third repair, never a replan"
$bookkeepingRowsMutant = $milestone.Replace("``bookkeeping``, ``note``, and ``flow-snapshot`` are not accepted", "``bookkeeping`` and ``note`` rows are accepted", [StringComparison]::Ordinal)
Add-MutantClaim "bookkeeping-rows-reintroduced" $true (Test-PreservedSections $bookkeepingRowsMutant $baseMilestone) "v2.60 no bookkeeping or note rows"
$toddEnqueueMutant = $milestone.Replace("Todd never enqueues on the`ncontroller's behalf", "a Todd enqueue is the bounded`nfallback of a controller landing P0", [StringComparison]::Ordinal)
Add-MutantClaim "todd-enqueue-fallback-reintroduced" $true (Test-PreservedSections $toddEnqueueMutant $baseMilestone) "v2.60 host enqueues on its own authority"
$decisionMachineMutant = $milestone.Replace("There are no`ntiers, modes, premise-freshness verdicts, or transition rules", "Decision autonomy has exactly two tiers and five modes", [StringComparison]::Ordinal)
Add-MutantClaim "decision-machine-reintroduced" $true (Test-PreservedSections $decisionMachineMutant $baseMilestone) "v2.60 decision is one comment"
$recalibrationCadenceMutant = $milestone.Replace("only when Todd asks for a recalibration", "on that evidence every two weeks", [StringComparison]::Ordinal)
Add-MutantClaim "recalibration-cadence-reintroduced" $true (Test-PreservedSections $recalibrationCadenceMutant $baseMilestone) "v2.60 recalibration on request only"
$opsTriggerMutant = $milestone.Replace("An ops-kind issue is dispatched only when a`nready product issue is blocked on it or Todd names it", "An ops-kind issue is dispatched whenever a`nlane is free", [StringComparison]::Ordinal)
Add-MutantClaim "ops-dispatch-trigger-removed" $true (Test-PreservedSections $opsTriggerMutant $baseMilestone) "v2.60 ops dispatch only when product is blocked or Todd names it"
$batteryTwiceMutant = $milestone.Replace("The selected battery runs once per candidate head, by the author lane,", "The selected battery runs twice per candidate head, by the author and the reviewer,", [StringComparison]::Ordinal)
Add-MutantClaim "battery-run-twice-reintroduced" $true (Test-PreservedSections $batteryTwiceMutant $baseMilestone) "v2.60 full battery once per head"
$qualityGateMutant = $milestone.Replace("Only confirmed correctness, security, or objective quality findings block", "Only confirmed correctness or security findings block", [StringComparison]::Ordinal)
Add-MutantClaim "quality-gate-removed" $true (Test-PreservedSections $qualityGateMutant $baseMilestone) "v2.54 objective quality blocking class"
$verdictRetroMutant = $milestone.Replace("Quality verdicts are retro input", "Quality verdicts are advisory only", [StringComparison]::Ordinal)
Add-MutantClaim "quality-verdict-not-retro-input" $true (Test-PreservedSections $verdictRetroMutant $baseMilestone) "v2.54 recalibration reads verdict counts"
$sectionTitleMutant = $milestone.Replace("## 8. Landing and deploy", "## 8. Landing, deploy, and manual attempts", [StringComparison]::Ordinal)
Add-MutantClaim "section-title-moved" $true (Test-PreservedSections $sectionTitleMutant $baseMilestone) "section titles preserved in order"

Assert-6997 (Test-ReleaseIdentity $milestone $routing) "v2.99/v4.20 release identity is invalid"
# v2.58: no live train authority. The only permitted mentions of a release train are the
# section-7 retirement sentence and the v2.58 header retirement list.
function Test-NoTrainAuthority([string]$Milestone) {
  $compact = Compact-Text $Milestone
  $compact = $compact.Replace("there is no packet lifecycle and no weekly release train", "")
  $compact = $compact.Replace("the three-packet lifecycle, the weekly release train, the #7495 bootstrap authority", "")
  $trainHit = [regex]::IsMatch($compact, "(?i)(weekly|next) (release )?train")
  return (-not $trainHit)
}
Assert-6997 (Test-NoTrainAuthority $milestone) "live skill retains release-train authority outside its retirement text"
$trainMutant = $milestone.Replace("is implemented within seven days; parking a", "is implemented by the next weekly train at the latest; parking a", [StringComparison]::Ordinal)
Add-MutantClaim "train-authority-reintroduced" (Test-NoTrainAuthority $milestone) (Test-NoTrainAuthority $trainMutant) "v2.58 no live train authority"
$oldPinMutant = $milestone.Replace("# Milestone Orchestrator (v2.99, 2026-10-04)", "# Milestone Orchestrator (v2.94, 2026-10-03)")
Add-MutantClaim "old-release-pin" $true (Test-ReleaseIdentity $oldPinMutant $routing) "milestone release header"

# MUTANT_AUTONOMY_SURFACE_ACCEPTED: the corrected footprint ratchet tolerating an
# unrelated descendant path must never widen into tolerating a corrupted protected
# autonomy vocabulary token; that stays governed by Test-Vocabulary alone.
$autonomySurfaceMutant = $archive.Replace('`hard-gated`', '`hard-gated-mutated`')
Add-MutantClaim "MUTANT_AUTONOMY_SURFACE_ACCEPTED" (Test-DescendantFootprint $expectedPaths $syntheticActualPaths) (Test-Vocabulary $autonomySurfaceMutant) "protected autonomy vocabulary token"

# MUTANT_UNRELATED_INVALID_DESCENDANT_ACCEPTED: retaining the accepted unrelated
# descendant path must never mask a genuine current release-provenance regression;
# that stays governed by Test-ReleaseIdentity alone.
Add-MutantClaim "MUTANT_UNRELATED_INVALID_DESCENDANT_ACCEPTED" (Test-DescendantFootprint $expectedPaths $syntheticActualPaths) (Test-ReleaseIdentity $oldPinMutant $routing) "current release provenance identity"

# MUTANT_PROTECTED_6997_HISTORY_REBOUND: the ratchet is a per-path subset check
# against the frozen historical list, not a count/size check, so silently dropping
# one protected #6997 path must still be rejected even though extra paths are
# tolerated.
$reboundActualPaths = @($actualPaths | Where-Object { $_ -ne ".orchestrator/controller-release-battery.ps1" })
Add-MutantClaim "MUTANT_PROTECTED_6997_HISTORY_REBOUND" (Test-DescendantFootprint $expectedPaths $actualPaths) (Test-DescendantFootprint $expectedPaths $reboundActualPaths) "protected #6997 historical path presence"

Assert-6997 (Test-Provenance $archive) "v2.45 provenance archive is incomplete or invents routing history"
$provenanceRoutingMutant = $archive.Replace("**v2.45 encoded two-tier decision autonomy", "**v2.45 encoded two-tier decision autonomy`nmodel-routing mutant", [StringComparison]::Ordinal)
Add-MutantClaim "provenance-routing-inside-block" $true (Test-Provenance $provenanceRoutingMutant) "extracted v2.45 provenance block"
Assert-6997 (Test-AcceptedReplanContract $contract) "accepted-replan contract boundary is incomplete"
# #8192: a recorded final independent decision-lane verdict may supply ceiling
# authority, but only already governing, exactly bound, and never self-supplied.
$ceilingSelfMutant = $contract -replace 'Neither\s+this\s+replan\s+nor\s+its\s+semantic\s+PASS\s+can\s+supply\s+it\.', 'This replan''s semantic PASS may supply it.'
Add-MutantClaim "8192-ceiling-self-authorized" $true (Test-AcceptedReplanContract $ceilingSelfMutant) "replan cannot supply its own ceiling authority"
$ceilingBindingMutant = $contract -replace 'bound\s+to that lineage root, terminal receipt, and exact absolute ceiling', 'bound to the issue'
Add-MutantClaim "8192-ceiling-decision-unbound" $true (Test-AcceptedReplanContract $ceilingBindingMutant) "decision-lane ceiling authority binds lineage root, terminal receipt, and absolute ceiling"
$ceilingSeparationMutant = $contract -replace 'That\s+decision\s+lane\s+is\s+separate\s+from\s+this\s+replan''s\s+author,\s+repairer,\s+and\s+reviewers\.', 'Any lane may decide it.'
Add-MutantClaim "8192-ceiling-decision-not-independent" $true (Test-AcceptedReplanContract $ceilingSeparationMutant) "ceiling decision lane is independent of the replan"
$ceilingResetMutant = $contract -replace 'resets\s+no\s+lineage\s+history\s+or\s+consumed\s+count', 'resets the consumed count'
Add-MutantClaim "8192-ceiling-resets-count" $true (Test-AcceptedReplanContract $ceilingResetMutant) "accepted replan resets no consumed count"

Assert-6997 (Test-Vocabulary $archive) "archived two-tier/five-mode/two-cause vocabulary is invalid"
foreach ($token in @('`adopt`', '`gate`', '`auto-adopted`', '`hard-gated`', '`ratified`', '`overridden`', '`superseded`', '`stale-premise`', '`judgment`')) {
  $mutated = $archive.Replace($token, $token.Trim('`') + "-deleted")
  Add-MutantClaim ("token-deletion-" + $token.Trim('`')) $true (Test-Vocabulary $mutated) "exact archived vocabulary token"
}
$spacedCause = $archive.Replace("stale-premise", "stale premise")
Add-MutantClaim "stale-premise-exact-token" $true (Test-Vocabulary $spacedCause) "ASCII hyphen versus one ASCII space"
$section11 = Get-Section $milestone 11
Assert-6997 ($null -ne $section11 -and -not (Compact-Text $section11).Contains("Decision autonomy has exactly two tiers", [StringComparison]::Ordinal) -and -not $section11.Contains('`auto-adopted`', [StringComparison]::Ordinal)) "live section 11 still carries the retired decision machine"

# v2.60 retired the override-rate telemetry with the decision machine; its
# in-test window/rate model went with it.
$milestoneCompact = Compact-Text $milestone
$routingCompact = Compact-Text $routing
$archiveCompact = Compact-Text $archive
# v2.58 moved the v2.48/v2.47 release paragraphs and the #7476 repair-frontier text to the archive; they are pinned there as history.
Assert-6997 ((Compact-Text $archive).Contains("The release added no event schema or telemetry implementation change.", [StringComparison]::Ordinal)) "v2.45 non-telemetry boundary was not preserved in provenance"
foreach ($token in @(
  "Version 2.48 repairs #7492's post-enqueue evidence boundary",
  "raw GraphQL stdout envelope, exit code/stderr",
  "complete paginated queue read is the first provider observation after an enqueue response",
  "response without an attributable ID terminates unknown/PARK",
  "Position, state, solo, and nullable generated commits remain typed diagnostics",
  "breaker-repair-frontier-retry-authority/v1",
  "activation-time workflow/tag-rules census",
  "exact empty complete",
  "deterministic ref name includes #7476 lineage, exact candidate head, attempt ordinal, and authority identity",
  "Spend remains recorded advisory telemetry and never changes admission",
  "Every named frontier and field predicate remains in the terminal record",
  "dequeues once by PR node ID and requires returned entry-ID equality"
)) {
  Assert-6997 ($archiveCompact.Contains($token, [StringComparison]::Ordinal)) "v2.48 stable-entry release omits $token from the archive"
}
foreach ($token in @(
  "Version 2.47 repairs #7490's collection boundaries without widening #7476's exact-instance admission",
  "Version 2.47 preserves v2.46's execution of P0 Bug #7476",
  "Complete zero-element dependency and label connections remain typed collections across PowerShell return boundaries",
  "top-level REST arrays preserve their 0/1/N token kind",
  "validated candidate paths remain a typed ordinal string collection through collision-set construction",
  "create-once, two-hour, fixed-path machine-local authority record",
  "complete open-PR file collision set",
  'expectedHeadOid` with `jump:false',
  "one pull-request-node-ID dequeue on compromise",
  "never retries",
  "Report stays non-mutating",
  "This is bounded detection and recovery, not a claim of GitHub-global atomicity",
  "records its live version, SHA-256, and byte length as observations without comparing them to a fixed release pin",
  "Construction-to-launch revalidation still requires the same exact executable"
)) {
  Assert-6997 ($archiveCompact.Contains($token, [StringComparison]::Ordinal) -or $milestoneCompact.Contains($token, [StringComparison]::Ordinal)) "v2.47 repair-frontier release omits $token from both the archive and the live skill"
}
Assert-6997 ($archiveCompact.Contains('the intervening interval is `not observed`, never zero', [StringComparison]::Ordinal)) "Packet C observation handoff missing from the archive"
Assert-6997 ($milestoneCompact.Contains("File genuine product, domain, legal, provider-contract, UX, data, and architecture Decisions", [StringComparison]::Ordinal)) "genuine Decision classes were removed"
Assert-6997 (-not $milestoneCompact.Contains("new-spend-authority", [StringComparison]::Ordinal)) "v2.51 retains the spend-authority Decision class"
Assert-6997 ($milestoneCompact.Contains("Do not file recurring cap-only, final-review, or park-or-continue Decisions after v2.45 cutover.", [StringComparison]::Ordinal)) "post-cutover cap-only Decision removal missing"
Assert-6997 ($archiveCompact.Contains('Product main is not authority for those `.orchestrator/` artifacts', [StringComparison]::Ordinal)) "controller premise-artifact authority missing from the archive"
Assert-6997 ($routingCompact.Contains("one idempotent terminal receipt with no cap-only Decision", [StringComparison]::Ordinal)) "v4.8 artifact-spend replacement incomplete"
Assert-6997 ($routingCompact.Contains("No per-dispatch, per-artifact, lineage, daily, or monthly USD limit exists", [StringComparison]::Ordinal)) "v4.8 spend telemetry statement missing"
Assert-6997 (-not $routingCompact.Contains("Per dispatch (binding)", [StringComparison]::Ordinal)) "v4.8 retains a binding per-dispatch cap"
Assert-6997 (-not $milestoneCompact.Contains('$50', [StringComparison]::Ordinal)) "v2.51 retains a USD ceiling literal"
Assert-6997 ($routingCompact.Contains("four-implementation-attempt ceiling", [StringComparison]::Ordinal)) "v4.9 lacks the four-implementation-attempt ceiling"
Assert-6997 (-not $routingCompact.Contains("eight-round", [StringComparison]::Ordinal)) "v4.9 retains the removed eight-round rule"
Assert-6997 (-not $routingCompact.Contains("spend authorization", [StringComparison]::Ordinal)) "v4.9 retains a spend authorization stop"
Assert-6997 ($routingCompact.Contains('Fable means Fable 5.1: pin `claude-fable-5-1` on every Fable dispatch', [StringComparison]::Ordinal)) "v4.10 lacks the Fable 5.1 in-place replacement"
Assert-6997 ($routingCompact.Contains('`claude-fable-5` is never selectable', [StringComparison]::Ordinal)) "v4.10 does not retire claude-fable-5"
Assert-6997 (-not $routingCompact.Contains("| Fable 5 |", [StringComparison]::Ordinal) -and -not $routingCompact.Contains("Fable 5 medium", [StringComparison]::Ordinal) -and -not $routingCompact.Contains("Fable 5 high", [StringComparison]::Ordinal)) "v4.10 still routes to Fable 5"
Assert-6997 ($routingCompact.Contains("| 12 | Precision-facing review | Opus 5.5 medium override-Todd; high for ambiguous/high-risk review; Sol 6.1 high independent fallback; Astra high independent reviewer (override-Todd). Never Luna", [StringComparison]::Ordinal)) "v4.17 lacks the Opus 5.5 row-12 precision placement or the independent Astra reviewer"
Assert-6997 ($routingCompact.Contains("| 11 | High-recall money/contracts/infra review | Sol 6.1 high provisional; Opus 5.5 high fallback; Astra high independent reviewer (override-Todd); never Fable", [StringComparison]::Ordinal)) "v4.17 lacks Sol 6 row-11 recall succession or the independent Astra reviewer"
function Test-ReviewHistoryExclusion([string]$Text) {
  foreach ($rule in @(
    "exclude every model on the artifact's author and repair history",
    'If no admitted reviewer remains, return to the host; never self-review or restore Sonnet to reach a reviewer count.',
    'FINAL nonterminal proof route only when all its predicates hold; otherwise return to independent decision.',
    'independently check code author/repair history and platform author ladders.',
    'Effort/session changes never cleanse model history.'
  )) {
    if (-not $Text.Contains($rule, [StringComparison]::Ordinal)) { return $false }
  }
  return (-not $Text.Contains('Sonnet 5 medium fallback', [StringComparison]::Ordinal))
}
Assert-6997 (Test-ReviewHistoryExclusion $routingCompact) 'v4.20 must preserve history exclusion and the bounded host-return route'
foreach ($boundary in @('never self-review', 'only when all its predicates hold', 'code author/repair history', 'never cleanse model history')) {
  Add-MutantClaim "review-exclusion-$boundary" $true (Test-ReviewHistoryExclusion ($routingCompact.Replace($boundary, 'MUTANT_REMOVED'))) 'exhausted brief roster never weakens independent code review'
}
Assert-6997 ($routingCompact.Contains("Core authorship stays Astra high / Fable 5.1 high under reserve", [StringComparison]::Ordinal) -and $routingCompact.Contains("Other work: Sol 6.1 high provisional; Fable admitted for named money/contract/event slices. No new Opus primary authorship", [StringComparison]::Ordinal)) "v4.16 changes row-7 upper-tier authorship or grants Opus new primary authorship"
Assert-6997 ($routingCompact.Contains("## Challenger quotas and rebalance", [StringComparison]::Ordinal) -and $routingCompact.Contains("Rebalance runs every two weeks and on any model release", [StringComparison]::Ordinal) -and $routingCompact.Contains("Between rebalances the row table is the only routing authority", [StringComparison]::Ordinal)) "v4.12 lacks the challenger-quota and rebalance rule"
Assert-6997 (-not $routingCompact.Contains("## Astra trial", [StringComparison]::Ordinal) -and $routingCompact.Contains("The legacy trial/shadow process, per-trial budgets, and experiment ledger are retired", [StringComparison]::Ordinal) -and $routingCompact.Contains('Quota and successor dispatches still require the `provisional` evidence label', [StringComparison]::Ordinal)) "v4.16 restores trial ceremony or drops provisional evidence labels"
Assert-6997 (-not $routingCompact.Contains("shadow trial", [StringComparison]::Ordinal) -and $routingCompact.Contains('The cost contract is the generated `measuredAt.byRowConfig[row, model, effort].usdPerRun`', [StringComparison]::Ordinal)) "v4.13 quota cost contract is not the generated per-configuration usdPerRun"
Assert-6997 ($routingCompact.Contains("Retain Astra high every-third quota across rows 4/5/10, aggregate n=10", [StringComparison]::Ordinal) -and $routingCompact.Contains("Retain Astra's own accumulated evidence", [StringComparison]::Ordinal)) "v4.17 drops Astra's row-table share or independent accumulated evidence"
# v4.13: the routing unit is a configuration (exact model + exact effort). The
# separate weighted effort score is gone, evidence is keyed per configuration,
# an effort step is a challenger like any other, and escalation branches by
# failure mode instead of always buying effort first.
Assert-6997 ($routingCompact.Contains("The routing unit is a configuration: one exact model version at one exact effort", [StringComparison]::Ordinal)) "v4.13 lacks the configuration-as-unit statement"
Assert-6997 (-not $routingCompact.Contains("D = 0.22", [StringComparison]::Ordinal) -and -not $routingCompact.Contains("Score each dimension 0", [StringComparison]::Ordinal)) "v4.13 still carries the standalone effort score"
Assert-6997 ($routingCompact.Contains('read `blockRateByRowConfig` by author configuration and row', [StringComparison]::Ordinal)) "v4.13 rebalance does not read per-configuration block rates"
Assert-6997 ($routingCompact.Contains("Sol 6.1 medium takes the next row-4 dispatch after Astra, then every third once Astra quota ends, until n=20", [StringComparison]::Ordinal) -and $routingCompact.Contains("threshold: no worse than Sol 6.1 high row 4 once both have n>=20", [StringComparison]::Ordinal)) "v4.16 lacks the fresh same-version row-4 effort-step quota"
Assert-6997 ($routingCompact.Contains("Knowledge or taste failure", [StringComparison]::Ordinal) -and $routingCompact.Contains("Effort does not buy knowledge", [StringComparison]::Ordinal)) "v4.13 escalation does not branch by failure mode"
Assert-6997 ($routingCompact.Contains('Log `authorEffort` on every review-complete and verify-complete receipt', [StringComparison]::Ordinal)) "v4.13 does not require author effort on receipts"
Assert-6997 ($routingCompact.Contains("## Price bands and effort ladders", [StringComparison]::Ordinal) -and $routingCompact.Contains("never a routing input", [StringComparison]::Ordinal)) "v4.13 lacks the price-band and effort-ladder rule"
Assert-6997 ($routingCompact.Contains('and its id is derived, never named: `<exact selector>/<effort>`', [StringComparison]::Ordinal)) "v4.13 lacks the derived configuration-id rule"
$matrixDocument = Get-RepoText ".orchestrator/controller-skills/model-routing/capability-matrix.json" | ConvertFrom-Json -Depth 20
$orchestrationDimension = @($matrixDocument.dimensions | Where-Object { $_.id -ceq "orchestration" })[0]
$orchestrationCurrentText = @(
  [string]$orchestrationDimension.governingEvidence,
  ($orchestrationDimension.registeredHostArms | ConvertTo-Json -Compress -Depth 5)
) + @($orchestrationDimension.cells.PSObject.Properties | Where-Object { $_.Name -cnotlike "claude-fable-5/*" } | ForEach-Object { [string]$_.Value.ref })
Assert-6997 ($null -ne $orchestrationDimension.registeredHostArms -and $null -eq $orchestrationDimension.PSObject.Properties["trialArms"] -and @($orchestrationCurrentText | Where-Object { $_ -match "(?i)trial" }).Count -eq 0) "v4.12 orchestration metadata still carries trial vocabulary"
Assert-6997 (-not $milestoneCompact.Contains("spend cap reached", [StringComparison]::Ordinal)) "v2.51 retains the spend breaker"
Assert-6997 (-not $routing.Contains('cumulative billed spend >$50 requires a decision issue', [StringComparison]::Ordinal)) "withdrawn v4.5 spend sentence survived"

$dispatchSource = Get-RepoText ".orchestrator/dispatch-lane.ps1"
$dispatchTestSource = Get-RepoText ".orchestrator/dispatch-lane.test.ps1"
$batterySource = Get-RepoText ".orchestrator/controller-release-battery.ps1"
Assert-6997 ($dispatchSource.Contains('"contracts/planning-repair-v1.md"', [StringComparison]::Ordinal)) "dispatch-lane planning contract reader missing"
Assert-6997 ($dispatchTestSource.Contains("planning-repair-v1.md", [StringComparison]::Ordinal)) "dispatch-lane contract consumer test missing"
Assert-6997 (Test-BatteryDiscoveryContract $batterySource) "battery test discovery missing"
$lsTreeMutant = $batterySource.Replace("ls-tree -r --name-only", "ls-tree", [StringComparison]::Ordinal)
Add-MutantClaim "battery-discovery-recursion-and-name-only" $true (Test-BatteryDiscoveryContract $lsTreeMutant) "ls-tree -r --name-only source contract"
$selectorAnchorMutant = $batterySource.Replace('^\.orchestrator/.+\.test\.ps1$', '\.test\.ps1', [StringComparison]::Ordinal)
Add-MutantClaim "battery-discovery-anchored-test-selector" $true (Test-BatteryDiscoveryContract $selectorAnchorMutant) "anchored tracked test selector"
foreach ($commandPath in @(
  ".orchestrator/issue-6997-autonomy-policy.test.ps1",
  ".orchestrator/premise-freshness.test.ps1",
  ".orchestrator/log-event.test.ps1",
  ".orchestrator/install-controller-skills.test.ps1",
  ".orchestrator/controller-release-battery.ps1"
)) {
  Assert-6997 (Test-Path -LiteralPath (Join-Path $controller $commandPath) -PathType Leaf) "verification command does not resolve: $commandPath"
}

Assert-6997 ($script:claims.Count -ge 25) "fail-closed claim matrix is incomplete"
Assert-6997 (@($script:claims | Where-Object { $_.candidate -cne "PASS" -or $_.bypassMutant -cne "FAIL" }).Count -eq 0) "fail-closed aggregate contains a survivor"
Write-Output "PASS issue-6997 exact #7495 footprint and incumbent base blobs"
Write-Output "PASS issue-6997 two-tier/five-mode/two-cause vocabulary archived by v2.60; #7154 continuation ceremony retired by v2.58"
Write-Output "PASS issue-6997 provenance, accepted replan, lifecycle, caller census, and retrospective interval"
Write-Output "PASS issue-6997 fail-closed aggregate claims=$($script:claims.Count) assertions=$script:assertions survivors=0"
