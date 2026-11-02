# Static probe: every prose rule in the controller skills and injected contracts
# that has a runtime counterpart matches that counterpart, and every installed
# file is strict UTF-8 with CRLF endings and no BOM. Added after the v2.52
# release, where a cp1252-encoded byte and two contract/runtime conflicts passed
# the policy pin. Any tracked *.test.ps1 joins the controller release battery.
$ErrorActionPreference = "Stop"
$controller = $PSScriptRoot
$script:assertions = 0
$script:mutants = 0
$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Assert-Enforced([bool]$Condition, [string]$Message) {
  $script:assertions += 1
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Mutant([string]$Name, [scriptblock]$Probe) {
  # The probe must fail its own assertion on the mutant. A silent pass means the
  # probe is dead; any other exception means the probe itself is broken.
  $script:mutants += 1
  $failure = $null
  try { & $Probe | Out-Null } catch { $failure = $_.Exception.Message }
  if ($null -eq $failure) { throw "MUTANT SURVIVED: $Name" }
  if (-not $failure.StartsWith("ASSERTION FAILED:", [StringComparison]::Ordinal)) { throw "MUTANT PROBE BROKEN: ${Name}: $failure" }
}

function Read-Bytes([string]$Relative) { return [IO.File]::ReadAllBytes((Join-Path $controller $Relative)) }
function Read-Strict([string]$Relative) { return $strictUtf8.GetString((Read-Bytes $Relative)) }
function Compact-Text([string]$Text) { return (($Text -replace "\s+", " ").Trim()) }

# --- 1. byte hygiene -----------------------------------------------------------

function Test-ByteHygiene([byte[]]$Bytes, [string]$Name) {
  if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
    throw "ASSERTION FAILED: $Name carries a UTF-8 BOM"
  }
  $text = $null
  try { $text = $strictUtf8.GetString($Bytes) } catch { throw "ASSERTION FAILED: $Name is not strict UTF-8: $($_.Exception.Message)" }
  if ($text.IndexOf([char]0xFFFD) -ge 0) { throw "ASSERTION FAILED: $Name contains U+FFFD" }
  $bareLf = [regex]::Matches($text, "(?<!\r)\n").Count
  $bareCr = [regex]::Matches($text, "\r(?!\n)").Count
  if ($bareLf -ne 0 -or $bareCr -ne 0) {
    throw "ASSERTION FAILED: $Name has non-CRLF endings (bare LF=$bareLf, bare CR=$bareCr)"
  }
  $script:assertions += 1
}

$hygieneFiles = @(foreach ($root in @("controller-skills", "contracts")) {
  Get-ChildItem -LiteralPath (Join-Path $controller $root) -Recurse -File
})
Assert-Enforced ($hygieneFiles.Count -ge 10) "hygiene census found only $($hygieneFiles.Count) files"
foreach ($file in $hygieneFiles) {
  Test-ByteHygiene ([IO.File]::ReadAllBytes($file.FullName)) $file.FullName.Substring($controller.Length + 1)
}

$milestoneText = Read-Strict "controller-skills/milestone-orchestrator/SKILL.md"
Assert-Enforced (($milestoneText.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -gt 0) "mutant needs a non-ASCII character in the milestone skill"
Assert-Mutant "cp1252-encoded-skill" { Test-ByteHygiene ([Text.Encoding]::GetEncoding(1252).GetBytes($milestoneText)) "mutant" }
Assert-Mutant "bare-lf" { Test-ByteHygiene ($strictUtf8.GetBytes($milestoneText.Remove($milestoneText.IndexOf("`r`n"), 1))) "mutant" }
Assert-Mutant "bom" { Test-ByteHygiene ([byte[]](0xEF, 0xBB, 0xBF) + $strictUtf8.GetBytes($milestoneText)) "mutant" }
Assert-Mutant "replacement-character" { Test-ByteHygiene ($strictUtf8.GetBytes($milestoneText + [char]0xFFFD)) "mutant" }

# --- 2. contract markers the launcher requires ---------------------------------

$reviewContract = Read-Strict "contracts/review-v2.md"
$planningContract = Read-Strict "contracts/planning-repair-v1.md"
$launcher = Read-Strict "dispatch-lane.ps1"
$reviewRuntime = Read-Strict "review-head-contract.psm1"
$landing = Read-Strict "landing-preflight.ps1"

function Test-ContractMarkers([string]$Launcher, [hashtable]$Contracts) {
  $markers = @([regex]::Matches($Launcher, '-notmatch "([A-Z_]+_CONTRACT_VERSION: ([a-z-]+)/v\d+)"') |
    ForEach-Object { [pscustomobject]@{ marker = $_.Groups[1].Value; family = $_.Groups[2].Value } })
  if ($markers.Count -ne $Contracts.Count) {
    throw "ASSERTION FAILED: launcher declares $($markers.Count) contract markers for $($Contracts.Count) contracts"
  }
  foreach ($marker in $markers) {
    if (-not $Contracts.ContainsKey($marker.family)) { throw "ASSERTION FAILED: no contract for launcher marker family $($marker.family)" }
    if (-not $Contracts[$marker.family].Contains($marker.marker)) { throw "ASSERTION FAILED: $($marker.family) contract lacks launcher marker $($marker.marker)" }
  }
  $script:assertions += 1
}

$contracts = @{ "review-contract" = $reviewContract; "planning-repair" = $planningContract }
Test-ContractMarkers $launcher $contracts
Assert-Mutant "review-marker-drift" {
  Test-ContractMarkers $launcher @{ "review-contract" = $reviewContract.Replace("review-contract/v2", "review-contract/v3"); "planning-repair" = $planningContract }
}

# --- 3. dispositions the reducer recognizes ------------------------------------

function Test-Dispositions([string]$Contract, [string]$Runtime) {
  $section = [regex]::Match($Contract, "(?s)## Disposition\r?\n(.*?)\r?\n## ").Groups[1].Value
  $declared = @([regex]::Matches($section, '(?m)^- `([A-Z_]+)`:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
  $terminalText = [regex]::Match($Runtime, '\$script:TerminalReviewOutcomes\s*=\s*@\(([^)]*)\)').Groups[1].Value
  $terminal = @([regex]::Matches($terminalText, '"([A-Z_]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
  $reduced = @([regex]::Matches($Runtime, '(?m)^\s*"([A-Z_]+)"\s*\{\s*return New-ReviewReduction') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
  if ($declared.Count -lt 3) { throw "ASSERTION FAILED: contract disposition list unreadable" }
  foreach ($runtimeSet in @(@{ name = "TerminalReviewOutcomes"; values = $terminal }, @{ name = "reducer switch"; values = $reduced })) {
    if (($declared -join ",") -cne ($runtimeSet.values -join ",")) {
      throw "ASSERTION FAILED: contract dispositions [$($declared -join ',')] differ from runtime $($runtimeSet.name) [$($runtimeSet.values -join ',')]"
    }
  }
  if (-not $Contract.Contains('Plain `BLOCK` is invalid')) { throw "ASSERTION FAILED: contract no longer rejects plain BLOCK" }
  $script:assertions += 1
}

Test-Dispositions $reviewContract $reviewRuntime
Assert-Mutant "extra-disposition" { Test-Dispositions ($reviewContract.Replace('- `SKIP`:', ('- `BLOCK`: plain block.' + "`r`n" + '- `SKIP`:'))) $reviewRuntime }
Assert-Mutant "dropped-disposition" { Test-Dispositions ($reviewContract -replace '(?m)^- `SKIP`:.*\r?\n(  .*\r?\n)*', '') $reviewRuntime }

# --- 4. completion report fields the receipt validator requires ---------------

$reportFieldForKey = @{
  reviewContract = "REVIEW_CONTRACT_VERSION"; outcome = "DISPOSITION"; completeSweep = "COMPLETE_SWEEP"
  reviewedHead = "EXACT_HEAD"; reviewerAttempt = "REVIEWER_ATTEMPT"; authorAttempt = "AUTHOR_ATTEMPT"
  model = "REPORTED_MODEL"; findingIds = "FINDING_IDS"; findings = "FINDINGS"
}
# Keys the controller writes from the dispatch tuple, never from the report.
$controllerSuppliedKeys = @("ts", "kind", "pr", "receiptSchema", "authorModel")

function Test-ReportBlock([string]$Contract, [string]$Runtime) {
  $compact = Compact-Text $Contract
  foreach ($required in @(
    'Semantic implementation identity and strict participant identity are separate.',
    'The lane name identifies the current author or reviewer execution and is unique while live through ownership-v4, not globally single-use across historical receipts.',
    'Author and reviewer values remain distinct inside one tuple, and its causal dispatch and terminal repeat the same exact issue/head/lane/transcript tuple.'
  )) {
    if (-not $compact.Contains($required)) { throw "ASSERTION FAILED: strict participant guidance missing: $required" }
  }
  $block = [regex]::Match($Contract, '(?s)```text\r?\n(.*?)```').Groups[1].Value
  $fields = @([regex]::Matches($block, "(?m)^([A-Z_]+):") | ForEach-Object { $_.Groups[1].Value })
  $requiredText = [regex]::Match($Runtime, '(?s)\$required = @\((.*?)\)').Groups[1].Value
  $required = @([regex]::Matches($requiredText, '"([A-Za-z]+)"') | ForEach-Object { $_.Groups[1].Value })
  if ($required.Count -lt 10) { throw "ASSERTION FAILED: runtime required receipt keys unreadable" }
  foreach ($key in $required) {
    if ($controllerSuppliedKeys -ccontains $key) { continue }
    if (-not $reportFieldForKey.ContainsKey($key)) { throw "ASSERTION FAILED: receipt key $key has no completion-report field" }
    if ($fields -cnotcontains $reportFieldForKey[$key]) { throw "ASSERTION FAILED: completion report lacks $($reportFieldForKey[$key]) for receipt key $key" }
  }
  if ($block -notmatch "(?m)^COMPLETE_SWEEP: true\r?$") { throw "ASSERTION FAILED: completion report must state COMPLETE_SWEEP: true" }
  if ($Contract.Contains("COMPLETE_SWEEP: false")) { throw "ASSERTION FAILED: contract offers COMPLETE_SWEEP: false, which the runtime refuses as INCOMPLETE_SWEEP" }
  if ($Runtime -notmatch 'completeSweep -ne \$true\) \{ \$errors\.Add\("INCOMPLETE_SWEEP"\)') { throw "ASSERTION FAILED: runtime no longer enforces completeSweep" }
  $script:assertions += 1
}

Test-ReportBlock $reviewContract $reviewRuntime
Assert-Mutant "report-drops-exact-head" { Test-ReportBlock ($reviewContract.Replace("EXACT_HEAD: <40-char sha>`r`n", "")) $reviewRuntime }
Assert-Mutant "report-drops-live-lane-identity" { Test-ReportBlock ($reviewContract.Replace("unique while live", "reusable while live")) $reviewRuntime }
Assert-Mutant "report-allows-partial-sweep" { Test-ReportBlock ($reviewContract.Replace("COMPLETE_SWEEP: true`r`nREVIEW_SCOPE", "COMPLETE_SWEEP: true | false`r`nREVIEW_SCOPE")) $reviewRuntime }
Assert-Mutant "runtime-drops-sweep-guard" { Test-ReportBlock $reviewContract ($reviewRuntime.Replace('$errors.Add("INCOMPLETE_SWEEP")', '$null')) }

function Test-StrictIdentityConsistency([string]$Contract, [string]$Skill) {
  $contractText = Compact-Text $Contract
  $skillText = Compact-Text $Skill
  $identityRule = 'unique while live through ownership-v4, not globally single-use across historical receipts.'
  if (-not $contractText.Contains($identityRule) -or -not $skillText.Contains($identityRule)) {
    throw "ASSERTION FAILED: review contract and live skill do not share the lane-identity retirement rule"
  }
  if ($contractText.Contains('is globally single-use for one immutable review tuple') -or
      $skillText.Contains('is globally single-use for one immutable review tuple')) {
    throw "ASSERTION FAILED: retired global strict-participant identity remains live"
  }
  $script:assertions += 1
}

Test-StrictIdentityConsistency $reviewContract $milestoneText
Assert-Mutant "contract-restores-global-strict-identity" {
  Test-StrictIdentityConsistency ($reviewContract + "`r`nEach strict participant identity is globally single-use for one immutable review tuple.`r`n") $milestoneText
}
Assert-Mutant "skill-restores-global-strict-identity" {
  Test-StrictIdentityConsistency $reviewContract ($milestoneText + "`r`nEach strict participant identity is globally single-use for one immutable review tuple.`r`n")
}

function Test-LegacyReviewDomainConsistency([string]$Skill, [string]$Runtime) {
  $skillText = Compact-Text $Skill
  foreach ($rule in @(
    "Historical rows that structurally claim neither a PR nor any exact-head receipt identity",
    "A row claiming exact-head receipt identity with a missing, nonnumeric, fractional, overflowed, or otherwise ambiguous PR remains fail-closed uncertainty",
    "This boundary uses closed fields only, never dates, issue lists, prose, lanes, or model aliases."
  )) {
    if (-not $skillText.Contains($rule)) { throw "ASSERTION FAILED: legacy review-domain rule missing: $rule" }
  }
  $function = [regex]::Match(
    $Runtime,
    '(?s)function Test-LegacyNonPrReviewIdentity\(\$Row\) \{(.*?)\r?\n\}'
  ).Groups[1].Value
  foreach ($field in @("issue", "pr", "receiptSchema", "reviewedHead", "reviewerAttempt", "authorAttempt")) {
    if (-not $function.Contains("Test-JsonProperty `$Row `"$field`"")) {
      throw "ASSERTION FAILED: legacy review-domain runtime boundary omits $field"
    }
  }
  if (-not $Runtime.Contains('reason = "LEGACY_NON_PR_NON_EXACT_HEAD_REVIEW"')) {
    throw "ASSERTION FAILED: legacy review-domain audit reason missing"
  }
  $script:assertions += 1
}

Test-LegacyReviewDomainConsistency $milestoneText $reviewRuntime
Assert-Mutant "skill-widens-legacy-review-domain" {
  Test-LegacyReviewDomainConsistency ($milestoneText.Replace(
      "neither a PR nor any`r`nexact-head receipt identity",
      "no exact PR identity"
    )) $reviewRuntime
}
Assert-Mutant "runtime-drops-legacy-reviewed-head-boundary" {
  Test-LegacyReviewDomainConsistency $milestoneText ($reviewRuntime.Replace(
      '-not (Test-JsonProperty $Row "reviewedHead") -and',
      '$true -and # mutant omitted reviewedHead boundary'
    ))
}

# --- 5. lane roles the launcher accepts ----------------------------------------

function Test-LaneRoles([string]$Skill, [string]$Launcher) {
  $validate = [regex]::Match($Launcher, '\[ValidateSet\(([^)]*)\)\]\[string\]\$LaneRole').Groups[1].Value
  $enforced = @([regex]::Matches($validate, '"([a-z]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
  $section = [regex]::Match($Skill, '(?s)Set `-LaneRole` to:\r?\n\r?\n(.*?)\r?\n\r?\n').Groups[1].Value
  $declared = @([regex]::Matches($section, '(?m)^- `([a-z]+)`:') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
  if ($enforced.Count -lt 2 -or ($declared -join ",") -cne ($enforced -join ",")) {
    throw "ASSERTION FAILED: skill lane roles [$($declared -join ',')] differ from launcher ValidateSet [$($enforced -join ',')]"
  }
  $script:assertions += 1
}

Test-LaneRoles $milestoneText $launcher
Assert-Mutant "skill-invents-lane-role" { Test-LaneRoles ($milestoneText.Replace('- `planning`:', ('- `audit`: read-only audit.' + "`r`n" + '- `planning`:'))) $launcher }

# --- 6. reviewer mutation and the review lane environment ----------------------
# The contract lets a reviewer apply mechanical remedies on the reviewed branch,
# so the launcher's review policy must keep GitHub authentication for pushes.

function Test-ReviewMutationPolicy([string]$Contract, [string]$Launcher) {
  $compactContract = Compact-Text $Contract
  if (-not $compactContract.Contains("directly on the reviewed branch")) { throw "ASSERTION FAILED: contract no longer describes reviewer-applied remedies" }
  $policy = [regex]::Match($Launcher, '(?s)if \(\$LaneRole -eq "review"\) \{\s*\[ordered\]@\{(.*?)\}').Groups[1].Value
  if ($policy -notmatch 'preservesGitHubAuthentication = \$true') { throw "ASSERTION FAILED: review lane policy drops GitHub authentication while the contract expects reviewer pushes" }
  $script:assertions += 1
}

Test-ReviewMutationPolicy $reviewContract $launcher
Assert-Mutant "review-lane-loses-github-auth" { Test-ReviewMutationPolicy $reviewContract ($launcher.Replace('preservesGitHubAuthentication = $true', 'preservesGitHubAuthentication = $false')) }

# --- 7. the sole enqueue path ---------------------------------------------------

function Test-LandingAction([string]$Skill, [string]$Landing) {
  $actions = [regex]::Match($Landing, '\[ValidateSet\(([^)]*)\)\]\[string\]\$Action').Groups[1].Value
  if ($actions -notmatch '"Apply"') { throw "ASSERTION FAILED: landing-preflight has no Apply action" }
  if (-not $Skill.Contains('`landing-preflight.ps1 -Action Apply`')) { throw "ASSERTION FAILED: skill no longer names Apply as the sole enqueue path" }
  $script:assertions += 1
}

Test-LandingAction $milestoneText $landing
Assert-Mutant "skill-renames-enqueue-path" { Test-LandingAction ($milestoneText.Replace('`landing-preflight.ps1 -Action Apply`', '`landing-preflight.ps1 -Action Enqueue`')) $landing }

# --- 8. quality matrix keys, profiles, and verdict fields --------------------
# The review contract's verdict lists the quality contract's pair keys in table
# order; the profile table covers every key with High/Med/Low for six profiles;
# the completion report carries the gate, profile, verdict, and non-blocking IDs.

$qualityContract = Read-Strict "contracts/quality-v2.md"
$script:qualityProfiles = @("prototype", "product-feature", "core-library", "hot-path", "migration", "contract")

function Get-QualityTableKeys([string]$Quality, [string]$Heading, [string]$NextHeading) {
  $table = [regex]::Match($Quality, "(?s)## $Heading\r?\n(.*?)\r?\n## $NextHeading").Groups[1].Value
  return @([regex]::Matches($table, "(?m)^\| ([A-Z]+) \|") | ForEach-Object { $_.Groups[1].Value })
}

function Test-QualityKeys([string]$Quality, [string]$Review) {
  if (-not $Quality.Contains('`QUALITY_CONTRACT_VERSION: quality-contract/v2`')) { throw "ASSERTION FAILED: quality contract version marker missing" }
  if ($Quality -notmatch "(?m)^## Gate\r?$") { throw "ASSERTION FAILED: quality contract lacks the G0 gate section" }
  $keys = Get-QualityTableKeys $Quality "Pairs" "Verdict"
  if ($keys.Count -ne 12) { throw "ASSERTION FAILED: quality contract declares $($keys.Count) pair keys, expected 12" }
  $profileKeys = Get-QualityTableKeys $Quality "Profiles" "Pairs"
  if (($profileKeys -join ",") -cne ($keys -join ",")) { throw "ASSERTION FAILED: profile table keys [$($profileKeys -join ',')] differ from pair keys [$($keys -join ',')]" }
  $profileTable = [regex]::Match($Quality, "(?s)## Profiles\r?\n(.*?)\r?\n## Pairs").Groups[1].Value
  $header = [regex]::Match($profileTable, "(?m)^\| Key \|(.*)\|\r?$").Groups[1].Value
  $profiles = @($header -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if (($profiles -join ",") -cne ($script:qualityProfiles -join ",")) { throw "ASSERTION FAILED: profile columns [$($profiles -join ',')] differ from the six declared profiles" }
  foreach ($row in [regex]::Matches($profileTable, "(?m)^\| [A-Z]+ \|(.*)\|\r?$")) {
    $cells = @($row.Groups[1].Value -split "\|" | ForEach-Object { $_.Trim() })
    if ($cells.Count -ne 6 -or @($cells | Where-Object { $_ -cnotin @("High", "Med", "Low") }).Count -gt 0) { throw "ASSERTION FAILED: profile row has a weight outside High/Med/Low: $($row.Value)" }
  }
  $verdict = [regex]::Match($Review, "(?s)## Quality verdict\r?\n(.*?)\r?\n## ").Groups[1].Value
  $listed = @(([regex]::Match((Compact-Text $verdict), "table order: ([A-Z, ]+)\.").Groups[1].Value) -split ",\s*")
  if (($keys -join ",") -cne ($listed -join ",")) { throw "ASSERTION FAILED: review contract verdict keys [$($listed -join ',')] differ from quality contract [$($keys -join ',')]" }
  if (-not (Compact-Text $verdict).Contains('answers the `G0` gate')) { throw "ASSERTION FAILED: review contract verdict no longer requires the G0 gate" }
  $block = [regex]::Match($Review, '(?s)```text\r?\n(.*?)```').Groups[1].Value
  if ($block -notmatch "(?m)^QUALITY_VERDICT:\r?$") { throw "ASSERTION FAILED: completion report lacks QUALITY_VERDICT" }
  $profileLine = "QUALITY_PROFILE: " + ($script:qualityProfiles -join " | ")
  if (-not $block.Contains($profileLine)) { throw "ASSERTION FAILED: completion report QUALITY_PROFILE does not list the six profiles" }
  if ($block -notmatch "(?m)^G0: PASS") { throw "ASSERTION FAILED: completion report lacks the G0 verdict line" }
  if ($block -notmatch "(?m)^NON_BLOCKING_IDS:") { throw "ASSERTION FAILED: completion report lacks NON_BLOCKING_IDS" }
  $script:assertions += 1
}

Test-QualityKeys $qualityContract $reviewContract
$script:subjectiveTokens = @("cannot be followed", "past recognition", "reviewer read", "clear to", "obvious", "feels", "looks", "seems")
function Test-ObjectiveSubcases([string]$Quality) {
  $table = [regex]::Match($Quality, "(?s)## Pairs\r?\n(.*?)\r?\n## Verdict").Groups[1].Value
  $rows = @([regex]::Matches($table, "(?m)^\| ([A-Z]+) \|(.*)\|\r?$"))
  if ($rows.Count -ne 12) { throw "ASSERTION FAILED: objective-subcase probe read $($rows.Count) pair rows" }
  foreach ($row in $rows) {
    $cells = @($row.Groups[2].Value -split "\|" | ForEach-Object { $_.Trim() })
    # cells: pair name, too-little, too-much, evidence
    foreach ($cell in @($cells[1], $cells[2])) {
      foreach ($token in $script:subjectiveTokens) {
        if ($cell.IndexOf($token, [StringComparison]::OrdinalIgnoreCase) -ge 0) { throw "ASSERTION FAILED: $($row.Groups[1].Value) blocking cell carries subjective predicate '$token'" }
      }
    }
  }
  $script:assertions += 1
}

Test-ObjectiveSubcases $qualityContract
Assert-Mutant "subjective-subcase-little" { Test-ObjectiveSubcases ($qualityContract.Replace("opens more than three non-test files", "cannot be followed by a new teammate")) }
Assert-Mutant "subjective-subcase-much" { Test-ObjectiveSubcases ($qualityContract.Replace("restates the adjacent code token for token", "seems padded")) }

Assert-Mutant "quality-key-dropped" { Test-QualityKeys ($qualityContract -replace '(?m)^\| DEPTH \| Depth vs.*\r?\n', '') $reviewContract }
Assert-Mutant "profile-row-dropped" { Test-QualityKeys ($qualityContract -replace '(?m)^\| DEPTH \| Med \|.*\r?\n', '') $reviewContract }
Assert-Mutant "profile-weight-invented" { Test-QualityKeys ($qualityContract.Replace("| SCOPE | Med | High |", "| SCOPE | Ultra | High |")) $reviewContract }
Assert-Mutant "gate-section-dropped" { Test-QualityKeys ($qualityContract.Replace("## Gate`r`n", "## Entry`r`n")) $reviewContract }
Assert-Mutant "verdict-key-order-drift" { Test-QualityKeys $qualityContract ($reviewContract.Replace("READABILITY, TESTS", "TESTS, READABILITY")) }
Assert-Mutant "report-drops-quality-verdict" { Test-QualityKeys $qualityContract ($reviewContract.Replace("QUALITY_VERDICT:`r`n", "")) }
Assert-Mutant "report-drops-profile" { Test-QualityKeys $qualityContract ($reviewContract -replace '(?m)^QUALITY_PROFILE:.*\r?\n', '') }
Assert-Mutant "report-drops-gate-line" { Test-QualityKeys $qualityContract ($reviewContract -replace '(?m)^G0: PASS.*\r?\n', '') }
Assert-Mutant "report-drops-non-blocking-ids" { Test-QualityKeys $qualityContract ($reviewContract -replace '(?m)^NON_BLOCKING_IDS:.*\r?\n', '') }

Write-Output "PASS contract-enforcement files=$($hygieneFiles.Count) assertions=$($script:assertions) mutants=$($script:mutants) survivors=0"
