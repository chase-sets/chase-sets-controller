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
foreach ($name in @('log-event.ps1','lease-contract.psm1','lane-stall-watchdog.ps1','matrix-refresh.ps1')) {
  Test-ByteHygiene (Read-Bytes $name) $name
}
$matrix = Read-Strict 'controller-skills/model-routing/capability-matrix.json' | ConvertFrom-Json
$retiredSelectors = @('gpt-5.6-luna','gpt-5.6-terra','gpt-5.6-sol','claude-opus-5','claude-sonnet-5','gpt-6-sol')
foreach ($config in @($matrix.configs | Where-Object { $_.model -cin $retiredSelectors })) {
  Assert-Enforced ($config.historicalOnly -eq $true -and $config.selectable -ne $true) "retired matrix config $($config.id) is historical-only"
}

$milestoneText = Read-Strict "controller-skills/milestone-orchestrator/SKILL.md"
$reviewContract = Read-Strict "contracts/review-v2.md"
function Test-BatteryInstallProof([string]$Skill, [string]$Review) {
  $section = [regex]::Match($Skill, '(?ms)^## 7\.[^\r\n]*\r?\n.*?(?=^## \d+\.|\z)')
  # v2.116: controller release proof belongs to the controller repository; the
  # product skill only applies released tags and must say so in section 7.
  # The release ownership sentence moved to orchestrator-shared Releases.
  $skillRule = 'Controller releases are not part of this loop.'
  $contractRule = 'The initial candidate always uses the installed controller baseline and full runtime proof.'
  Assert-Enforced ($section.Success -and (Compact-Text $section.Value).Contains($skillRule, [StringComparison]::Ordinal)) 'skill section 7 lacks the controller release boundary'
  Assert-Enforced ((Compact-Text $Review).Contains($contractRule, [StringComparison]::Ordinal)) 'review-v2 lacks initial full install proof'
  Assert-Enforced ((Compact-Text $Review).Contains('any runtime-script change selects the full plan.', [StringComparison]::Ordinal)) 'review-v2 lacks repair runtime full plan'
}
Test-BatteryInstallProof $milestoneText $reviewContract
Assert-Mutant 'skill-release-boundary-deleted' { Test-BatteryInstallProof ($milestoneText -replace 'Controller releases are not part of this loop\.\s+', '') $reviewContract }
Assert-Mutant 'review-initial-full-proof-deleted' { Test-BatteryInstallProof $milestoneText ($reviewContract -replace 'The initial candidate always\s+uses the installed controller baseline and full runtime proof\.', '') }
$sharedText = Read-Strict 'controller-skills/orchestrator-shared/SKILL.md'
function Test-SharedReleaseOwnership([string]$Shared) {
  $section = [regex]::Match($Shared, '(?ms)^## Releases\r?\n(.*?)(?=^## |\z)')
  Assert-Enforced $section.Success 'orchestrator-shared has a Releases section'
  $text = Compact-Text $section.Groups[1].Value
  foreach ($rule in @(
      'The controller loop authors, verifies and tags it once its independent review passes and the release scan is clean; it does not wait for Todd''s approval.',
      'The controller loop never waits for a product install: it keeps building and releasing, and tags may accumulate.',
      'The product loop installs only the newest tag, at the start of the first cycle that can take an install, with `.orchestrator/install-controller-skills.ps1 -ReleaseTag <tag>`; it skips older tags it never applied and does nothing else with releases.',
      'Release tags are the only install authority: never install an untagged commit or by any other path, never edit the product container checkout (it changes only through tag installs), and never copy a live edit over a mismatch.',
      'Rollback is the product loop reinstalling the previous tag with the same command.')) {
    Assert-Enforced ($text.Contains($rule, [StringComparison]::Ordinal)) "orchestrator-shared Releases lacks: $rule"
  }
}
Test-SharedReleaseOwnership $sharedText
Assert-Mutant 'shared-release-ownership-deleted' { Test-SharedReleaseOwnership ($sharedText -replace 'The controller loop authors, verifies and\s+tags it once its independent review passes and the release scan is clean; it\s+does not wait for Todd''s approval\.\s*', '') }
Assert-Mutant 'shared-release-approval-gate-restored' { Test-SharedReleaseOwnership ($sharedText -replace 'once its independent review passes and the release scan is clean; it\s+does not wait for Todd''s approval\.', 'and Todd approves it.') }
Assert-Mutant 'shared-install-newest-only-deleted' { Test-SharedReleaseOwnership ($sharedText -replace 'installs only the newest tag', 'installs each tag in order') }
Assert-Mutant 'shared-install-authority-deleted' { Test-SharedReleaseOwnership ($sharedText -replace 'Release tags are the only install authority', 'Release tags are one install path') }
Assert-Enforced (($milestoneText.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count -gt 0) "mutant needs a non-ASCII character in the milestone skill"
Assert-Mutant "cp1252-encoded-skill" { Test-ByteHygiene ([Text.Encoding]::GetEncoding(1252).GetBytes($milestoneText)) "mutant" }
Assert-Mutant "bare-lf" { Test-ByteHygiene ($strictUtf8.GetBytes($milestoneText.Remove($milestoneText.IndexOf("`r`n"), 1))) "mutant" }
Assert-Mutant "bom" { Test-ByteHygiene ([byte[]](0xEF, 0xBB, 0xBF) + $strictUtf8.GetBytes($milestoneText)) "mutant" }
Assert-Mutant "replacement-character" { Test-ByteHygiene ($strictUtf8.GetBytes($milestoneText + [char]0xFFFD)) "mutant" }

# --- 2. contract markers the launcher requires ---------------------------------

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

# Policy-only boundary: pins are section-scoped and whitespace-insensitive.
# Each negative control removes one permission boundary, not a runtime fixture.
$platformRules = @(
  # The platform loop and its migration belong to the controller thread. The
  # product loop applies orchestrator-shared Platform handoff by label each
  # cycle; milestone membership never grants the platform loop an issue.
  @(3, 'The orchestration platform loop and its migration belong to the controller thread.', 'The orchestration platform loop belongs to this orchestrator.'),
  @(3, 'This orchestrator does not observe, start, stop, resume, unpark, upgrade or repair platform runs, supervisors or executors, never labels a platform issue `ready`, and never touches the platform checkout.', 'This orchestrator supervises, restarts and repairs platform executors.'),
  @(3, 'Once per cycle, before step 7, it applies `orchestrator-shared` Platform handoff from `.orchestrator/platform-handoff.json` and complete issue reads:', 'Once per cycle it reads the platform register:'),
  @(3, 'it resumes unfinished take-backs, takes back held issues that meet a take-back reason, files one controller defect for each return not acknowledged within `releaseHours`, returns acknowledged issues to normal delivery, then hands off new ones.', 'it hands off new issues.'),
  @(3, 'handle it as usual and leave platform-side causes to the controller thread.', 'repair platform-side causes directly.'),
  @(3, 'Renew the host identity record and apply any newer controller release (§2).', 'Renew the host identity record.'),
  @(4, '`orchestrator-shared` Platform handoff decides which issues the platform loop holds; milestone membership never does.', 'The ownership register decides which milestones the platform loop owns.'),
  @(4, 'Selection already excludes issues carrying `dispatch:platform` or `dispatch:platform-return` (`PLATFORM_HELD`).', 'Selection excludes platform milestones.'),
  @(4, 'On such an issue, its PR or its branch, the host never dispatches, reviews, enqueues, rebases, closes, reclaims worktrees, runs its watchdog, or kills processes', 'On such an issue the host may dispatch, review, enqueue, rebase, close, reclaim, watchdog, or kill platform work'),
  @(4, 'a taken-back issue is runnable again only when that contract returns it', 'a taken-back issue is runnable at once'),
  @(4, 'All platform-repo issues belong to its self loop; the host never dispatches lanes there.', 'Host dispatches platform-repo lanes.'),
  @(4, 'Unknown label state is not mutation authority; retry the read while unrelated work continues.', 'Unknown label state counts as unlabeled.'),
  @(6, 'watchdog and termination rules below apply only to incumbent-owned lanes', 'watchdog and termination apply to both loops'),
  @(8, 'Enqueue, repair, and landed-integration actions below never touch an issue carrying either platform handoff label (section 4), its PR or its branch, including the direct-enqueue fallback.', 'Enqueue, repair, and landed-integration actions below apply to any scope, including platform direct-enqueue fallback.'),
  @(8, 'The landed-integration census records such a target and never rebases it; the platform loop refreshes its own branch.', 'The landed-integration census dispatches an incumbent rebase into the platform branch.'),
  @(8, 'do not invoke a dispatch path that would mutate one', 'invoke unrestricted auto-integration'),
  @(9, 'never remove a worktree, branch or process of an issue carrying either platform handoff label (`platform-held-issue`), even after idle, park, or merge, until `orchestrator-shared` Platform handoff returns the issue.', 'remove idle or merged platform worktrees and processes.'),
  @(9, 'Read each candidate''s issue labels and newest path-bound dispatch identity each run; unknown retains.', 'Read each candidate''s newest path-bound dispatch identity each run; unknown retains.'),
  @(11, 'A platform handoff or take-back is a host decision under `orchestrator-shared` Platform handoff, never a Todd question.', 'A platform handoff or take-back needs a Todd comment and a register change.'),
  @(13, 'excluding issues carrying either platform handoff label, the policy''s named CI/controller-evidence milestones and parked issues.', 'excluding platform milestones, the policy''s named CI/controller-evidence milestones and parked issues.'),
  @(15, 'When automation replaces a host duty, remove the redundant routine in the same reviewed adoption change after its replacement coverage is exercised.', 'Keep old and new routines running indefinitely after adoption.'),
  @(15, 'Use existing issue/PR and execution evidence to check whether the action, wait or failure disappeared; add no report, approval stage or delivery gate.', 'Require a new report and approval gate before continuing delivery.')
)

function Test-PlatformPolicy([string]$Skill) {
  $Skill = $Skill -replace '[ \t]+', ' '
  foreach ($rule in $platformRules) {
    $section = [regex]::Match($Skill, "(?ms)^## $($rule[0])\.[^\r\n]*\r?\n(.*?)(?=^## \d+\.|\z)")
    if (-not $section.Success -or -not (Compact-Text $section.Value).Contains($rule[1], [StringComparison]::Ordinal)) {
      throw "ASSERTION FAILED: platform policy section $($rule[0]) lacks boundary: $($rule[1])"
    }
    $script:assertions += 1
  }
  $cycle = [regex]::Match($Skill, '(?ms)^## 3\..*?^7\. Backfill').Value
  if (-not $cycle -or (Compact-Text $cycle).Contains('platform loops')) {
    throw 'ASSERTION FAILED: the product cycle must not supervise platform loops'
  }
}

Test-PlatformPolicy $milestoneText
Test-PlatformPolicy ($milestoneText.Replace(' ', '  '))
Assert-Mutant 'platform-supervision-restored' { Test-PlatformPolicy ($milestoneText.Replace('6. Validate completed lanes and run independent review.', '6. Validate completed lanes and run independent review; supervise both platform loops as below before step 7.')) }
foreach ($rule in $platformRules) {
  $match = [regex]::Match($milestoneText, (([regex]::Escape($rule[1])) -replace '\\ ', '\s+'))
  Assert-Enforced $match.Success "platform negative control must change its boundary: $($rule[1])"
  $mutant = $milestoneText.Replace($match.Value, $rule[2])
  Assert-Mutant "platform-section-$($rule[0]):$($rule[1])" { Test-PlatformPolicy $mutant }
}

function Test-CapacityPolicy([string]$Milestone,[string]$Routing) {
  foreach($text in @($Milestone,$Routing)) {
    Assert-Enforced ((Compact-Text $text).Contains('fresh lane and session with no shared transcript or conversation state')) 'review independence is a fresh lane/session, not a family exclusion'
    Assert-Enforced ((Compact-Text $text).Contains('capacityShadowFlip')) 'capacity shadow policy is explicit'
    # #9282: planning and review lanes are capacity-eligible; the role exemption is removed from both skills.
    Assert-Enforced (-not (Compact-Text $text).Contains('Review/planning, row 0')) 'capacity role exemption removed (#9282)'
    Assert-Enforced ((Compact-Text $text).Contains('override-todd')) 'strict controller tuples bind override-todd'
    Assert-Enforced ((Compact-Text $text).Contains('prepared, prelogged, then launched')) 'strict review prepare-prelog-launch order'
    Assert-Enforced ((Compact-Text $text).Contains('strictPrelogV1')) 'strict review exact v1 prelog (#9382)'
    Assert-Enforced ((Compact-Text $text).Contains('voids never-launched prelogs')) 'strict refusal void recovery (#9382)'
    Assert-Enforced ((Compact-Text $text).Contains('`-Label` and `-ReviewerAttempt`')) 'strict recovery uses fresh label and reviewer attempt (#9382)'
  }
  Assert-Enforced ((Compact-Text $Routing).Contains('Codex [3,13,10,4]')) 'capacity Codex ordered prefix retained'
  Assert-Enforced (-not (Compact-Text $Routing).Contains('Claude [13,10,4,5]')) 'capacity Claude prefix superseded (#9282)'
  Assert-Enforced ((Compact-Text $Routing).Contains('every lane a Claude model can admissibly take goes to Claude')) 'capacity toward-Claude rule'
  Assert-Enforced ((Compact-Text $Routing).Contains('`modelLimits`, scope `Fable`, window `limit:2`')) 'Fable quota window comes from live provider data'
  Assert-Enforced ((Compact-Text $Routing).Contains('No blanket Sol/Opus exclusion')) 'capacity route-derived continuation replaces blanket exclusion'
  Assert-Enforced ((Compact-Text $Routing).Contains('Any lane routed off its slot records the reason in its dispatch row, the same for every model.')) 'off-slot reasons apply equally to every model'
  Assert-Enforced (-not (Compact-Text $Routing).Contains('Never use it as an automatic fallback')) 'capacity removes contradictory blanket Fable fallback prohibition'
  Assert-Enforced ((Compact-Text $Milestone).Contains('-ReviewArtifact brief|code')) 'review dispatch names its artifact'
}
$routingSkill=Read-Strict 'controller-skills/model-routing/SKILL.md'
Test-CapacityPolicy $milestoneText $routingSkill
Assert-Mutant 'strict-prelog-hand-projection-restored' {Test-CapacityPolicy ($milestoneText.Replace('strictPrelogV1','strictTuple')) $routingSkill}
Assert-Mutant 'strict-prelog-void-recovery-omitted' {Test-CapacityPolicy $milestoneText ($routingSkill.Replace('voids never-launched prelogs','refuses without recovery'))}
Assert-Mutant 'capacity-fresh-session-omitted' {Test-CapacityPolicy ([regex]::Replace($milestoneText,'fresh\s+lane\s+and\s+session','same lane and session')) $routingSkill}
Assert-Mutant 'capacity-role-exemption-restored' {Test-CapacityPolicy $milestoneText ($routingSkill.Replace('lanes are eligible. Row 0, relaunches','lanes are eligible. Review/planning, row 0, relaunches'))}
Assert-Mutant 'capacity-claude-prefix-restored' {Test-CapacityPolicy $milestoneText ($routingSkill.Replace('Codex [3,13,10,4]','Claude [13,10,4,5] and Codex [3,13,10,4]'))}
Assert-Mutant 'capacity-fable-window-omitted' {Test-CapacityPolicy $milestoneText ($routingSkill.Replace('`modelLimits`, scope `Fable`, window `limit:2`','the Fable window'))}
function Test-OrdinaryModelPolicy([string]$Text) {
  $compact=Compact-Text $Text
  Assert-Enforced ($compact.Contains('Astra and Fable are ordinary candidates')) 'ordinary model candidacy is explicit'
  Assert-Enforced ($compact.Contains('The row''s policy slot is the measured default.')) 'policy slot is the measured default'
  Assert-Enforced ($compact -notmatch '(?i)Fable (?:stays at or below|is capped at|must not exceed) half|Fable (?:is eligible only|flips only|only when Sol and Opus)|Fable availability reserve|HOST_FABLE_ROUTING_REASON_RECORDED|No new Opus primary authorship') 'no model-specific share cap, row restriction or reserve policy'
  Assert-Enforced ($compact -notmatch '(?i)(?:authorship|authors?)[^.]*must use a third model|both Sol and Opus excluded|exclude every model on the artifact') 'authorship never requires a third model'
}
Test-OrdinaryModelPolicy $routingSkill
Assert-Mutant 'fable-share-cap-restored' {Test-OrdinaryModelPolicy ($routingSkill + ' Fable stays at or below half of Claude usage.')}
Assert-Mutant 'fable-row-restriction-restored' {Test-OrdinaryModelPolicy ($routingSkill + ' Fable is eligible only for rows 7/14/15.')}
Assert-Mutant 'third-model-authorship-restored' {Test-OrdinaryModelPolicy ($routingSkill + ' Authorship must use a third model.')}
Assert-Mutant 'off-slot-reason-omitted' {Test-CapacityPolicy $milestoneText ([regex]::Replace($routingSkill,'Any lane\s+routed off its slot','A lane follows its slot'))}
Assert-Mutant 'capacity-prepare-order-omitted' {Test-CapacityPolicy ([regex]::Replace($milestoneText,'prepared,\s+prelogged,\s+then\s+launched','launched, then prelogged')) $routingSkill}
function Test-PacingPolicy([string]$Skill,[string]$Reducer) {
  # #9316: section 10 states the pacing condition; capacity-pacing.ps1 is its runtime counterpart.
  $section=[regex]::Match($Skill,'(?ms)^## 10\.[^\r\n]*\r?\n(.*?)(?=^## \d+\.|\z)')
  Assert-Enforced $section.Success 'skill section 10 present'
  $text=Compact-Text $section.Value
  foreach($rule in @(
      'run `capacity-pacing.ps1` once with the cycle''s `-NowUtc` and add no fresh lane on a provider beyond its `newLaneAllowance`; respect live quota windows for every model.',
      'Relaunches, resumes, review of in-flight work and landing are not counted against it.',
      'A zero allowance is a valid section 10 deferral reason, including in #9283''s spend mode.',
      '`status: unknown` (an unreachable, malformed or stale status, or an unknown census) is zero allowance on every provider: pacing never authorizes dispatch on missing evidence.',
      'less the 0.10 reserve',
      'The pace target (`targetUnitsPerHour`) spends banked credits before they lapse; the pace budget (`paceBudget`) raises the headroom budget by at most two new lanes per run.',
      'A positive allowance with ready work is a reason to dispatch, not a ceiling to stay under.',
      'replaces the hand-read AgentPools dashboard routine of 4388/6101785942, which is superseded.')) {
    Assert-Enforced ($text.Contains($rule,[StringComparison]::Ordinal)) "section 10 lacks pacing rule: $rule"
  }
  foreach($needle in @("'capacity-pacing/v1'",'reserve = 0.10','claude = 0.015; codex = 0.009','minLaneHours = 24','windowHours = 168')) {
    Assert-Enforced ($Reducer.Contains($needle,[StringComparison]::Ordinal)) "capacity-pacing.ps1 lacks runtime counterpart: $needle"
  }
  Assert-Enforced (-not $Reducer.Contains('[Math]::Floor($laneBudget / 2)',[StringComparison]::Ordinal)) 'Fable pacing reports only provider-window capacity'
}
$pacingReducer=Read-Strict 'capacity-pacing.ps1'
Assert-Enforced ((Compact-Text (Read-Strict 'controller-skills/milestone-orchestrator/references/rule-provenance-v2.24.md')).Contains('supersedes 4388/6101785942',[StringComparison]::Ordinal)) 'release note names 4388/6101785942 as superseded for the rule-change row'
Test-PacingPolicy $milestoneText $pacingReducer
Assert-Mutant 'pacing-allowance-omitted' {Test-PacingPolicy ([regex]::Replace($milestoneText,'add no fresh\s+lane on a provider beyond its `newLaneAllowance`','add lanes freely')) $pacingReducer}
Assert-Mutant 'pacing-deferral-omitted' {Test-PacingPolicy ([regex]::Replace($milestoneText,'A zero allowance is a valid section 10 deferral\s+reason','A zero allowance is advisory')) $pacingReducer}
Assert-Mutant 'pacing-supersession-omitted' {Test-PacingPolicy ($milestoneText.Replace('4388/6101785942','4388/0')) $pacingReducer}
Assert-Mutant 'pacing-unknown-authorizes' {Test-PacingPolicy ([regex]::Replace($milestoneText,'pacing never authorizes dispatch on missing\s+evidence','pacing may authorize dispatch on missing evidence')) $pacingReducer}
Assert-Mutant 'pacing-reserve-drifted' {Test-PacingPolicy $milestoneText ($pacingReducer.Replace('reserve = 0.10','reserve = 0.05'))}
Assert-Mutant 'pacing-credit-raise-omitted' {Test-PacingPolicy ([regex]::Replace($milestoneText,'(?s)The pace target\s+.*?per run\.','')) $pacingReducer}
Assert-Mutant 'pacing-dispatch-duty-omitted' {Test-PacingPolicy ([regex]::Replace($milestoneText,'A positive allowance with ready work is a reason to dispatch,\s+not a ceiling to stay under\.','')) $pacingReducer}
# --- checkout identity and container bootstrap --------------------------------
# One AGENTS.md serves both the product container (tag install target) and every
# controller development checkout, so it must open by telling them apart.
$repoRoot = Split-Path -Parent $controller
function Read-RootStrict([string]$Name) { return $strictUtf8.GetString([IO.File]::ReadAllBytes((Join-Path $repoRoot $Name))) }
function Test-CheckoutIdentity([string]$Agents, [string]$Claude, [string]$Bootstrap) {
  $lines = @($Agents -split "\r?\n" | Where-Object { $_.Trim() -ne '' })
  Assert-Enforced ($lines.Count -gt 0 -and $lines[0] -ceq '## Which checkout is this') 'AGENTS.md opens with the checkout identity section'
  $section = [regex]::Match($Agents, '(?ms)\A## Which checkout is this\r?\n(.*?)(?=^#{1,2} |\z)')
  Assert-Enforced $section.Success 'checkout identity section present'
  $text = Compact-Text $section.Groups[1].Value
  Assert-Enforced ($text.Contains('In the product container, `main/` beside this file is a chase-sets checkout', [StringComparison]::Ordinal)) 'checkout identity names the observable fact'
  Assert-Enforced ($text.Contains('never edit or install into the product container from a development checkout', [StringComparison]::Ordinal)) 'checkout identity forbids product-container edits'
  Assert-Enforced ($text.Contains('An issue lives in the repository its change merges into (Repository routing in the chase-sets `docs/contributing/backlog-model.md`).', [StringComparison]::Ordinal)) 'checkout identity states the routing rule'
  Assert-Enforced ($text -notmatch '#\d|\b\d{4}-\d{2}-\d{2}\b|\bv\d+\.\d+') 'checkout identity carries no issue numbers, dates or versions'
  Assert-Enforced ((Compact-Text $Agents).Contains('# chase-sets container', [StringComparison]::Ordinal)) 'product-container guidance kept'
  $claudeFirst = ($Claude -split "\r?\n")[0]
  Assert-Enforced ($claudeFirst -ceq 'In the product container this directory is the chase-sets container, not the repo itself; elsewhere it is a controller checkout (see the opening section of AGENTS.md).') 'CLAUDE.md first line names both checkouts'
  Assert-Enforced ($Claude.Contains('@AGENTS.md') -and $Claude.Contains('@main/AGENTS.md')) 'CLAUDE.md keeps both imports'
  $junctions = @([regex]::Matches($Bootstrap, '@\{ Path = Join-Path \$Root "([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
  Assert-Enforced ($junctions.Count -eq 1 -and $junctions[0] -ceq '.agents') "bootstrap creates only the .agents junction (found: $($junctions -join ','))"
}
$agentsRoot = Read-RootStrict 'AGENTS.md'
$claudeRoot = Read-RootStrict 'CLAUDE.md'
$bootstrapRoot = Read-RootStrict 'bootstrap-container.ps1'
Test-CheckoutIdentity $agentsRoot $claudeRoot $bootstrapRoot
Assert-Mutant 'checkout-identity-section-not-first' { Test-CheckoutIdentity ($agentsRoot -replace '\A## Which checkout is this', '## Something else') $claudeRoot $bootstrapRoot }
Assert-Mutant 'checkout-identity-routing-deleted' { Test-CheckoutIdentity ($agentsRoot -replace 'An issue lives in the repository its change merges into', 'Issues live anywhere') $claudeRoot $bootstrapRoot }
Assert-Mutant 'checkout-identity-dated' { Test-CheckoutIdentity ($agentsRoot -replace 'Tell the checkouts apart', 'As of 2026-10-18, tell the checkouts apart') $claudeRoot $bootstrapRoot }
Assert-Mutant 'claude-line-reverted' { Test-CheckoutIdentity $agentsRoot ($claudeRoot -replace '\A[^\r\n]*', 'This directory is the chase-sets container, not the repo itself.') $bootstrapRoot }
Assert-Mutant 'bootstrap-codex-junction-restored' { Test-CheckoutIdentity $agentsRoot $claudeRoot ($bootstrapRoot.Replace('@{ Path = Join-Path $Root ".agents"; Target = Join-Path $MainPath ".agents" }', '@{ Path = Join-Path $Root ".agents"; Target = Join-Path $MainPath ".agents" },' + "`r`n" + '  @{ Path = Join-Path $Root ".codex"; Target = Join-Path $MainPath ".codex" }')) }

# --- controller-orchestrator ships in tags but is never installed by the product --
# The controller thread's skill is tracked so releases review it. The product
# install inventory is the exact list the product container receives.
Import-Module (Join-Path $controller 'controller-install-lock.psm1') -Force
$installInventory = @(Get-ControllerSkillInstallInventory)
function Test-ControllerSkillPlacement([string]$Skill, [object[]]$Inventory) {
  Assert-Enforced ($Skill -match '(?m)^name: controller-orchestrator\r?$') 'controller-orchestrator skill is tracked with its name'
  $backlog = [regex]::Match($Skill, '(?ms)^## \d+\. Backlog\r?\n(.*?)(?=^## |\z)')
  Assert-Enforced $backlog.Success 'controller-orchestrator has a Backlog section'
  Assert-Enforced ((Compact-Text $backlog.Groups[1].Value).StartsWith('Plan controller issues with the planning skill: the same brief standard and the same pressure test.', [StringComparison]::Ordinal)) 'Backlog section opens with the planning rule'
  Assert-Enforced ((Compact-Text $backlog.Groups[1].Value).Contains('Check each issue against Repository routing in `main/docs/contributing/backlog-model.md` before filing it.', [StringComparison]::Ordinal)) 'Backlog section applies repository routing'
  $listed = @($Inventory | Where-Object { $_.source -like 'controller-orchestrator/*' -or $_.destination -like 'controller-orchestrator/*' })
  Assert-Enforced ($listed.Count -eq 0) 'product install inventory excludes controller-orchestrator'
}
$controllerSkill = Read-Strict 'controller-skills/controller-orchestrator/SKILL.md'
# Skill text states rules plainly: no dated rulings or attributions that go stale.
# The version header is the one dated line.
function Test-ControllerSkillUndated([string]$Skill) {
  $body = [regex]::Replace($Skill, '(?m)^# Controller Orchestrator \(v\d+\.\d+, \d{4}-\d{2}-\d{2}\)\r?$', '')
  Assert-Enforced ($body -notmatch '\b\d{4}-\d{2}-\d{2}\b|\bTodd,\s+\d') 'controller-orchestrator body carries no dates or dated Todd attributions'
}
Test-ControllerSkillUndated $controllerSkill
# This loop decides fixes, repairs, reruns, sequencing and releases itself.
function Test-ControllerOwnsDecisions([string]$Skill, [string]$Supervision) {
  $section = [regex]::Match($Skill, '(?ms)^## \d+\. Defects and rulings\r?\n(.*?)(?=^## |\z)')
  Assert-Enforced $section.Success 'controller-orchestrator has a Defects and rulings section'
  $text = Compact-Text $section.Groups[1].Value
  Assert-Enforced ($text.Contains("Fixes, test repairs, reruns, sequencing and releases are this loop's decisions; make them and report, never ask Todd to approve them. Ask Todd only for a scope or ownership change.", [StringComparison]::Ordinal)) 'fixes and releases are decided by this loop'
  $approvalAsk = '(?i)(?<!never )ask todd (to|for) [^.]{0,40}?(approv|permission|ruling|decision|decide|sign[- ]?off|go[- ]?ahead)|(?<!not |not a |never |without )wait\w* (for|on) (a |the |any |todd''s )?(todd|ruling|approval|decision)'
  Assert-Enforced ((Compact-Text $Skill) -notmatch $approvalAsk) 'no skill step asks Todd to approve or waits on a ruling'
  Assert-Enforced ((Compact-Text $Supervision) -notmatch $approvalAsk) 'no supervision step asks Todd to approve or waits on a ruling'
  Assert-Enforced ((Compact-Text $Supervision).Contains('A stop cap or chain stop is not a wait for Todd: this loop picks the fix', [StringComparison]::Ordinal)) 'stop cap is recovered by this loop'
}
$supervisionText = Read-Strict 'controller-skills/controller-orchestrator/references/platform-supervision.md'
Test-ControllerOwnsDecisions $controllerSkill $supervisionText
Assert-Mutant 'controller-decision-rule-deleted' { Test-ControllerOwnsDecisions ([regex]::Replace($controllerSkill, 'Fixes, test repairs, reruns, sequencing and releases are this loop''s\s+decisions;', 'Fixes are proposed;')) $supervisionText }
Assert-Mutant 'controller-approval-ask-returns' { Test-ControllerOwnsDecisions ($controllerSkill.Replace('7. Read `check-controller-skill-freshness.ps1 -Json`', '7. Ask Todd to approve the fix, then read `check-controller-skill-freshness.ps1 -Json`')) $supervisionText }
Assert-Mutant 'controller-waits-on-ruling' { Test-ControllerOwnsDecisions ($controllerSkill.Replace('7. Read `check-controller-skill-freshness.ps1 -Json`', '7. Wait for a ruling, then read `check-controller-skill-freshness.ps1 -Json`')) $supervisionText }
Assert-Mutant 'controller-waits-on-the-ruling' { Test-ControllerOwnsDecisions ($controllerSkill + "`r`nWait for the ruling before rerunning tests.`r`n") $supervisionText }
Assert-Mutant 'supervision-approval-ask-appended' { Test-ControllerOwnsDecisions $controllerSkill ($supervisionText + "`r`nAsk Todd to approve the rerun.`r`n") }
Assert-Mutant 'controller-asks-for-his-approval' { Test-ControllerOwnsDecisions ($controllerSkill + "`r`nAsk Todd for his approval before rerunning tests.`r`n") $supervisionText }
Assert-Mutant 'controller-asks-for-a-decision' { Test-ControllerOwnsDecisions ($controllerSkill + "`r`nAsk Todd for a decision before rerunning tests.`r`n") $supervisionText }
Assert-Mutant 'controller-asks-for-the-go-ahead' { Test-ControllerOwnsDecisions ($controllerSkill + "`r`nAsk Todd for the go ahead before rerunning tests.`r`n") $supervisionText }
Assert-Mutant 'supervision-stop-cap-waits' { Test-ControllerOwnsDecisions $controllerSkill ($supervisionText.Replace('A stop cap or chain stop is not a wait for Todd', 'A stop cap waits for Todd')) }
Assert-Mutant 'controller-skill-dated' { Test-ControllerSkillUndated ($controllerSkill.Replace('clear review and the scan.', 'clear review and the scan (Todd, 2026-10-19).')) }
Assert-Mutant 'controller-skill-dated-plain' { Test-ControllerSkillUndated ($controllerSkill + "`r`nUpdated 2026-10-19.`r`n") }
Test-ControllerSkillPlacement $controllerSkill $installInventory
Assert-Mutant 'controller-skill-installed-by-product' { Test-ControllerSkillPlacement $controllerSkill ($installInventory + [pscustomobject]@{ source = 'controller-orchestrator/SKILL.md'; destination = 'controller-orchestrator/SKILL.md' }) }
Assert-Mutant 'controller-backlog-planning-deleted' { Test-ControllerSkillPlacement ($controllerSkill -replace 'Plan controller issues with the planning skill', 'Plan controller issues freely') $installInventory }
Assert-Mutant 'controller-backlog-routing-deleted' { Test-ControllerSkillPlacement ($controllerSkill -replace 'Check each issue against Repository routing', 'Check each issue') $installInventory }

# --- per-issue platform handoff (orchestrator-shared Platform handoff) ----------
# Labels and markers are the only transport between the product and platform
# loops. Pins are whitespace-insensitive. Each mutant is probed against one
# check and removes one boundary (a take-back trigger, a write order, the
# return bound, the holder's process check) or restores milestone ownership, a
# merge-queue exception, a date or an issue identity.
$handoffRules = @(
  'Labels and markers are the only transport between the product and platform loops; milestones play no part.',
  'An issue is held while it carries `dispatch:platform` without `dispatch:platform-return`, and returning while it carries `dispatch:platform-return`.',
  'The product loop chooses handoffs and requests returns. Beyond the handoff and take-back writes below, it never touches an issue carrying either label, or that issue''s PR or branch.',
  'The platform loop works only issues with `dispatch:platform` and without `dispatch:platform-return`.',
  'The controller loop owns `.orchestrator/platform-handoff.json`; every orchestration platform run, the platform''s self loop included: starts, resumes, unparks, `ready` labels on platform issues, recovery and the choice of the next platform fix; acknowledgment when no platform supervisor runs; and platform fixes from take-back causes.',
  'The product loop does none of these.',
  'When the controller loop asks for a quiet window before a platform gate, the product loop holds new heavy admissions until it is released.',
  '`.orchestrator/platform-handoff.json` has exactly the fields `schemaVersion` (`platform-handoff/v1`), `accepting` (boolean), `maxInFlight` (an integer of zero or more), and `idleHours`, `maxHours` and `releaseHours` (positive integers). Only the controller loop writes it. An absent, unreadable or invalid file means not accepting.',
  'Authorities come from complete paginated reads, and an incomplete read makes no handoff and no clock-based take-back for that issue this cycle.',
  'Label age is the newest `LabeledEvent` for `dispatch:platform`; return age is the newest `LabeledEvent` for `dispatch:platform-return`.',
  'Activity is the newest of label age, the `updatedAt` of every PR in the issue''s `closedByPullRequestsReferences(includeClosedPrs: true)`, and comments containing `<!-- loop-`.',
  'Handoff: while the file is accepting and fewer than `maxInFlight` open issues carry either label, the product loop adds `dispatch:platform` to the lowest-ranked issue that has a current ready receipt (`issue-readiness/v1`), `priority:p2` or `priority:p3`, a fast-path tier in its brief and one `<!-- routing:` marker in its body; has no `risk:*`, `kind:ops` or `kind:security` label, no open linked PR and no live lane; blocks no open issue; and has never had a `platform-take-back` marker.',
  'Take-back: the product loop takes back an open held issue for one of these reasons, named in its marker:',
  'The merge queue is no exception.',
  'A take-back writes in order, skipping each step already done: (a) one comment `<!-- platform-take-back: {"version":1,"reason":"<reason>"} -->` with a one-line cause; (b) add `dispatch:platform-return`; (c) remove `dispatch:platform`.',
  'Each cycle, a take-back marker newer than the newest `dispatch:platform` labeled event resumes at the first undone step, unless a release marker newer than it exists.',
  'Acknowledgment is the holder''s alone: the live platform supervisor, or the controller loop when none runs.',
  'In order, the holder (1) confirms by a fresh read that no linked platform PR is in the merge queue, dequeuing and re-reading until it is out or merged; (2) removes `dispatch:platform`; (3) posts `<!-- platform-released: {"version":1,"by":"platform"|"controller","outcome":"released"|"merged"} -->`, with `merged` when the platform PR merged; (4) removes `dispatch:platform-return`.',
  'The product loop owns the issue again only when neither label is present and a release marker is newer than its take-back.',
  'It then delivers normally: a closed issue needs nothing; an open platform PR is adopted after an exact-head independent review, or closed.',
  'A return not acknowledged within `releaseHours` of its return label gets one controller defect from the product loop, and the issue stays untouched.'
)
$takeBackReasons = [ordered]@{
  'needs-replan' = 'the issue gained `status:needs-replan`.'
  'needs-operator' = 'the issue gained `status:needs-operator`.'
  'handoff-closed' = 'the handoff file is not accepting.'
  'idle' = 'no activity for `idleHours`.'
  'max-age' = 'label age is older than `maxHours`.'
  'priority' = 'the issue is now `priority:p0` or `priority:p1`.'
  'dependent' = 'the issue now blocks an open issue.'
}
$takeBackWriteOrder = @('(a) one comment `<!-- platform-take-back:', '(b) add `dispatch:platform-return`', '(c) remove `dispatch:platform`')
$acknowledgmentOrder = @('(1) confirms by a fresh read that no linked platform PR is in the merge queue', '(2) removes `dispatch:platform`;', '(3) posts `<!-- platform-released:', '(4) removes `dispatch:platform-return`')
$supervisionRules = @(
  'This thread alone writes the product container''s `.orchestrator/platform-handoff.json`.',
  'Set `accepting: true` only while a Chase Sets supervisor started with a `handoff` object naming both labels is live.',
  'Write `accepting: false` before stopping that supervisor, and as soon as it is found stopped.',
  'Raise `maxInFlight` from the weekly platform scorecard (`platform-scorecard.ps1`) and that week''s `platform-take-back` markers.',
  'The tunable numbers live only in that file, never in skill text.',
  'Start or resume a platform run only from Windows through the platform checkout''s `scripts/executor/start-loop.ps1 <config>`, recording the config path, run name, executor SHA and supervisor PID.',
  'Start or resume a Chase Sets run only with a `handoff` object naming `dispatch:platform` and `dispatch:platform-return`.',
  'Observe runs and their PRs read-only.',
  'A historical log line or a matching PID alone is not liveness, and alert silence is not health.',
  'Never hand-edit the platform checkout or the WSL executor checkout; platform defects go to the platform''s self loop, which owns every platform-repository issue.',
  'This thread chooses the next platform fix, labels a platform issue `ready` only after an independent readiness review, and decides each unpark and resume, recording the decision on the platform issue.',
  'Upgrade the executor only while no Chase Sets supervisor is live.',
  'Each cycle, read the Chase Sets issues carrying `dispatch:platform-return` from a complete paginated read.',
  'While no Chase Sets supervisor is live, this thread is their holder: acknowledge each one (`by: controller`) only after confirming that no process of the run remains, the supervisor and every descendant, and after the shared acknowledgment''s merge-queue check; then make the remaining acknowledgment writes in order.',
  'When a live holder has not acknowledged a return within `releaseHours`, write `accepting: false`, stop the run, and acknowledge the same way.',
  'For each distinct platform cause named in `platform-take-back` comments, file one platform issue through the platform repository''s planning path.',
  'Criteria for retiring the host loop live in the platform roadmap.'
)
$milestonePlatformText = @(
  '(?ms)^### Orchestration platform\r?\n.*?(?=^## )',
  '(?ms)^`orchestrator-shared` Platform handoff decides.*?(?=\r?\n\r?\n)',
  '(?ms)^Enqueue, repair, and landed-integration actions below never touch.*?(?=\r?\n\r?\n)',
  '(?ms)^These reclamation rules never remove a worktree.*?(?=\r?\n\r?\n)'
)
$registerOwnership = 'ownership register|platform-owned|register edit|platform-handoff\.md'

function Edit-Policy([string]$Text, [string]$Old, [string]$New) {
  # Builds a mutant outside its probe, so a stale anchor fails loudly instead of
  # counting as a killed mutant.
  $match = [regex]::Match($Text, (([regex]::Escape($Old)) -replace '\\ ', '\s+'))
  if (-not $match.Success) { throw "MUTANT ANCHOR MISSING: $Old" }
  return $Text.Replace($match.Value, $New)
}
function Test-PlatformTimeless([string]$Text, [string]$Name) {
  # Schema versions (`platform-handoff/v1`) and section references pass.
  Assert-Enforced ($Text -notmatch '(?i)\b\d{4}-\d{2}-\d{2}\b|#\d|\bISS-\d|\b\d+/\d{6,}\b|\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b') "$Name carries no date, issue, comment, ISS or commit identity"
}
function Assert-InOrder([string]$Text, [string[]]$Steps, [string]$Name) {
  $last = -1
  foreach ($step in $Steps) {
    $index = $Text.IndexOf($step, [StringComparison]::Ordinal)
    Assert-Enforced ($index -gt $last) "$Name writes keep their order: $step"
    $last = $index
  }
}
function Test-SharedPlatformHandoff([string]$Shared) {
  $section = [regex]::Match($Shared, '(?ms)^## Platform handoff\r?\n(.*?)(?=^## |\z)')
  Assert-Enforced $section.Success 'orchestrator-shared has a Platform handoff section'
  $raw = $section.Groups[1].Value
  $text = Compact-Text $raw
  foreach ($rule in $handoffRules) {
    Assert-Enforced ($text.Contains($rule, [StringComparison]::Ordinal)) "orchestrator-shared Platform handoff lacks: $rule"
  }
  $reasons = @([regex]::Matches($raw, '(?m)^- `([a-z-]+)`: ([^\r\n]+?)\r?$'))
  Assert-Enforced ((@($reasons | ForEach-Object { $_.Groups[1].Value }) -join ',') -ceq (@($takeBackReasons.Keys) -join ',')) "take-back reasons are exactly $(@($takeBackReasons.Keys) -join ', ')"
  foreach ($reason in $reasons) {
    Assert-Enforced ($reason.Groups[2].Value -ceq $takeBackReasons[$reason.Groups[1].Value]) "take-back reason $($reason.Groups[1].Value) keeps its trigger"
  }
  Assert-InOrder $text $takeBackWriteOrder 'take-back'
  Assert-InOrder $text $acknowledgmentOrder 'acknowledgment'
  Assert-Enforced ([regex]::Matches($text, 'merge queue').Count -eq 2 -and $text -notmatch '(?i)\b(en)?queued\b') 'the merge queue is no take-back exception; only the acknowledgment reads it'
  Assert-Enforced ($raw -cnotmatch $registerOwnership) 'Platform handoff reads no ownership register'
  Test-PlatformTimeless $raw 'orchestrator-shared Platform handoff'
}
function Test-PlatformSupervisionHandoff([string]$Supervision) {
  $text = Compact-Text $Supervision
  foreach ($rule in $supervisionRules) {
    Assert-Enforced ($text.Contains($rule, [StringComparison]::Ordinal)) "platform-supervision lacks: $rule"
  }
  Assert-Enforced ($Supervision -cnotmatch $registerOwnership -and $Supervision -notmatch '(?i)\bmilestone|\bpartition|\broll ?back|\bincumbent') 'platform-supervision carries no register, milestone, partition, rollback or incumbent text'
  Test-PlatformTimeless $Supervision 'platform-supervision'
}
function Test-MilestonePlatformText([string]$Milestone) {
  foreach ($pattern in $milestonePlatformText) {
    $paragraph = [regex]::Match($Milestone, $pattern)
    Assert-Enforced $paragraph.Success "milestone-orchestrator keeps its platform text: $pattern"
    Assert-Enforced ($paragraph.Value -cnotmatch $registerOwnership) 'milestone-orchestrator platform text reads no ownership register'
    Test-PlatformTimeless $paragraph.Value 'milestone-orchestrator platform text'
  }
}
# AC3 inside the battery: no controller skill file reads or names the register.
$skillFiles = [ordered]@{}
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $controller 'controller-skills') -Recurse -File | Sort-Object FullName)) {
  $skillFiles[$file.FullName] = $strictUtf8.GetString([IO.File]::ReadAllBytes($file.FullName))
}
function Test-NoRegisterOwnership([Collections.IDictionary]$Files) {
  Assert-Enforced ($Files.Count -ge 10) "skill census found only $($Files.Count) files"
  foreach ($entry in $Files.GetEnumerator()) {
    Assert-Enforced ($entry.Value -cnotmatch $registerOwnership) "$($entry.Key) carries no ownership register text"
  }
}
function Copy-SkillFiles([Collections.IDictionary]$Files, [string]$Path, [string]$Text) {
  $copy = [ordered]@{}
  foreach ($entry in $Files.GetEnumerator()) { $copy[$entry.Key] = $entry.Value }
  if (-not $copy.Contains($Path)) { throw "MUTANT TARGET MISSING: $Path" }
  $copy[$Path] = $Text
  return $copy
}

$handoffMutantsBefore = $script:mutants
Test-SharedPlatformHandoff $sharedText
Test-PlatformSupervisionHandoff $supervisionText
Test-MilestonePlatformText $milestoneText
Test-NoRegisterOwnership $skillFiles
Test-PlatformTimeless ('Schema `platform-handoff/v1` and `issue-readiness/v1`, marker version 1, section 4 and ' + [char]0x00A7 + '9.') 'schema and section-reference control'

$sharedHandoffMutants = [ordered]@{}
foreach ($reason in @($takeBackReasons.Keys)) {
  $sharedHandoffMutants["take-back-trigger-removed-$reason"] = [regex]::Replace($sharedText, '(?m)^- `' + [regex]::Escape($reason) + '`:[^\r\n]*\r?\n', '')
}
$sharedHandoffMutants['merge-queue-exception-restored'] = Edit-Policy $sharedText 'The merge queue is no exception.' 'An issue whose platform PR is in the merge queue is not taken back.'
$sharedHandoffMutants['merge-queue-wait-appended'] = Edit-Policy $sharedText 'The merge queue is no exception.' 'The merge queue is no exception. Wait while its PR is in the merge queue.'
$sharedHandoffMutants['queued-pr-exception-appended'] = Edit-Policy $sharedText 'The merge queue is no exception.' 'The merge queue is no exception. A queued platform PR finishes first.'
$sharedHandoffMutants['max-age-queue-exception'] = Edit-Policy $sharedText 'label age is older than `maxHours`.' 'label age is older than `maxHours` and no PR is queued.'
$sharedHandoffMutants['take-back-labels-swapped'] = Edit-Policy $sharedText '(b) add `dispatch:platform-return`; (c) remove `dispatch:platform`.' '(b) remove `dispatch:platform`; (c) add `dispatch:platform-return`.'
$sharedHandoffMutants['take-back-comment-last'] = Edit-Policy $sharedText '(a) one comment `<!-- platform-take-back: {"version":1,"reason":"<reason>"} -->` with a one-line cause; (b) add `dispatch:platform-return`; (c) remove `dispatch:platform`.' '(a) add `dispatch:platform-return`; (b) remove `dispatch:platform`; (c) one comment `<!-- platform-take-back: {"version":1,"reason":"<reason>"} -->` with a one-line cause.'
$sharedHandoffMutants['take-back-resume-overrides-release'] = Edit-Policy $sharedText 'resumes at the first undone step, unless a release marker newer than it exists.' 'resumes at the first undone step.'
$sharedHandoffMutants['acknowledgment-return-label-before-marker'] = Edit-Policy $sharedText '(3) posts `<!-- platform-released: {"version":1,"by":"platform"|"controller","outcome":"released"|"merged"} -->`, with `merged` when the platform PR merged; (4) removes `dispatch:platform-return`.' '(3) removes `dispatch:platform-return`; (4) posts `<!-- platform-released: {"version":1,"by":"platform"|"controller","outcome":"released"|"merged"} -->`, with `merged` when the platform PR merged.'
$sharedHandoffMutants['acknowledgment-queue-check-after-label'] = Edit-Policy $sharedText '(1) confirms by a fresh read that no linked platform PR is in the merge queue, dequeuing and re-reading until it is out or merged; (2) removes `dispatch:platform`;' '(1) removes `dispatch:platform`; (2) confirms by a fresh read that no linked platform PR is in the merge queue, dequeuing and re-reading until it is out or merged;'
$sharedHandoffMutants['product-owns-before-acknowledgment'] = Edit-Policy $sharedText 'The product loop owns the issue again only when neither label is present and a release marker is newer than its take-back.' 'The product loop owns the issue again once it adds `dispatch:platform-return`.'
$sharedHandoffMutants['product-owns-without-release-marker'] = Edit-Policy $sharedText 'only when neither label is present and a release marker is newer than its take-back.' 'only when neither label is present.'
$sharedHandoffMutants['controller-acknowledges-beside-live-supervisor'] = Edit-Policy $sharedText 'the live platform supervisor, or the controller loop when none runs.' 'the live platform supervisor or the controller loop.'
$sharedHandoffMutants['return-wait-unbounded'] = Edit-Policy $sharedText 'A return not acknowledged within `releaseHours` of its return label gets one controller defect from the product loop, and the issue stays untouched.' 'The product loop waits for the acknowledgment.'
$sharedHandoffMutants['missing-file-keeps-handoffs'] = Edit-Policy $sharedText 'An absent, unreadable or invalid file means not accepting.' 'An absent file keeps the current handoffs.'
$sharedHandoffMutants['incomplete-read-counts-as-idle'] = Edit-Policy $sharedText 'an incomplete read makes no handoff and no clock-based take-back for that issue this cycle.' 'an incomplete read counts as no activity.'
$sharedHandoffMutants['re-handoff-after-take-back'] = Edit-Policy $sharedText '; and has never had a `platform-take-back` marker.' '.'
$sharedHandoffMutants['milestone-ownership-appended'] = Edit-Policy $sharedText 'milestones play no part.' 'milestones play no part. The platform loop also keeps each platform-owned milestone in the ownership register.'
$sharedHandoffMutants['milestone-partition-restored'] = Edit-Policy $sharedText 'Labels and markers are the only transport between the product and platform loops; milestones play no part.' 'The platform loop owns whole milestones assigned to it.'
$sharedHandoffMutants['product-loop-labels-ready'] = Edit-Policy $sharedText 'The product loop does none of these.' 'The product loop may also label platform issues `ready`.'
$sharedHandoffMutants['self-loop-excluded'] = Edit-Policy $sharedText 'every orchestration platform run, the platform''s self loop included:' 'every Chase Sets platform run:'
$sharedHandoffMutants['quiet-window-ignored'] = Edit-Policy $sharedText 'the product loop holds new heavy admissions until it is released.' 'the product loop continues admitting heavy work.'
$sharedHandoffMutants['section-dated'] = Edit-Policy $sharedText 'milestones play no part.' 'milestones play no part. Adopted 2026-10-21.'
$sharedHandoffMutants['section-issue-number'] = Edit-Policy $sharedText 'milestones play no part.' 'milestones play no part. See #192.'
$sharedHandoffMutants['section-iss-identity'] = Edit-Policy $sharedText 'milestones play no part.' 'milestones play no part. Platform side: ISS-258.'
foreach ($entry in $sharedHandoffMutants.GetEnumerator()) {
  Assert-Enforced ($entry.Value -cne $sharedText) "shared handoff mutant changes the text: $($entry.Key)"
  Assert-Mutant "shared-handoff-$($entry.Key)" { Test-SharedPlatformHandoff $entry.Value }
}

$supervisionHandoffMutants = [ordered]@{}
$supervisionHandoffMutants['acknowledgment-without-process-check'] = Edit-Policy $supervisionText 'only after confirming that no process of the run remains, the supervisor and every descendant, and after the shared acknowledgment''s merge-queue check;' 'after the shared acknowledgment''s merge-queue check;'
$supervisionHandoffMutants['acknowledgment-supervisor-only-check'] = Edit-Policy $supervisionText 'no process of the run remains, the supervisor and every descendant,' 'the supervisor has exited,'
$supervisionHandoffMutants['acknowledgment-without-queue-check'] = Edit-Policy $supervisionText ', and after the shared acknowledgment''s merge-queue check;' ';'
$supervisionHandoffMutants['accepting-without-live-supervisor'] = Edit-Policy $supervisionText 'Set `accepting: true` only while a Chase Sets supervisor started with a `handoff` object naming both labels is live.' 'Set `accepting: true` whenever the platform has capacity.'
$supervisionHandoffMutants['accepting-left-open-on-stop'] = Edit-Policy $supervisionText 'Write `accepting: false` before stopping that supervisor, and as soon as it is found stopped.' 'Leave `accepting` unchanged when the supervisor stops.'
$supervisionHandoffMutants['run-without-handoff-object'] = Edit-Policy $supervisionText 'Start or resume a Chase Sets run only with a `handoff` object naming `dispatch:platform` and `dispatch:platform-return`.' 'Start or resume a Chase Sets run with its usual config.'
$supervisionHandoffMutants['run-noncanonical-start'] = Edit-Policy $supervisionText 'only from Windows through the platform checkout''s `scripts/executor/start-loop.ps1 <config>`, recording the config path, run name, executor SHA and supervisor PID.' 'by any available means.'
$supervisionHandoffMutants['overdue-holder-left-running'] = Edit-Policy $supervisionText 'write `accepting: false`, stop the run, and acknowledge the same way.' 'file a platform issue.'
$supervisionHandoffMutants['executor-hand-patched'] = Edit-Policy $supervisionText 'Never hand-edit the platform checkout or the WSL executor checkout;' 'Hand-patch the WSL executor checkout when a run stops;'
$supervisionHandoffMutants['executor-upgraded-while-live'] = Edit-Policy $supervisionText 'Upgrade the executor only while no Chase Sets supervisor is live.' 'Upgrade the executor at any time.'
$supervisionHandoffMutants['ready-without-review'] = Edit-Policy $supervisionText 'labels a platform issue `ready` only after an independent readiness review,' 'labels platform issues `ready` as they arrive,'
$supervisionHandoffMutants['observation-mutates'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and repair their PRs.'
$supervisionHandoffMutants['one-issue-per-take-back'] = Edit-Policy $supervisionText 'For each distinct platform cause named in `platform-take-back` comments, file one platform issue' 'For each take-back, file one platform issue'
$supervisionHandoffMutants['max-in-flight-unbounded'] = Edit-Policy $supervisionText 'Raise `maxInFlight` from the weekly platform scorecard (`platform-scorecard.ps1`) and that week''s `platform-take-back` markers.' 'Raise `maxInFlight` whenever the queue is short.'
$supervisionHandoffMutants['retirement-criteria-restated'] = Edit-Policy $supervisionText 'Criteria for retiring the host loop live in the platform roadmap.' 'Retire the host loop after one zero-touch delivery.'
$supervisionHandoffMutants['register-read-restored'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and their PRs read-only. Read the ownership register in `.orchestrator/platform-handoff.md` first.'
$supervisionHandoffMutants['milestone-idle-restored'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and their PRs read-only. An idle run completes its milestone.'
$supervisionHandoffMutants['rollback-restored'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and their PRs read-only. Rollback follows the runbook.'
$supervisionHandoffMutants['incumbent-partition-restored'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and their PRs read-only. The incumbent keeps its partition.'
$supervisionHandoffMutants['dated'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and their PRs read-only. Since 2026-10-21.'
$supervisionHandoffMutants['issue-number'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and their PRs read-only. Tracked on #368.'
$supervisionHandoffMutants['iss-identity'] = Edit-Policy $supervisionText 'Observe runs and their PRs read-only.' 'Observe runs and their PRs read-only. Use the ISS-136 status command.'
foreach ($entry in $supervisionHandoffMutants.GetEnumerator()) {
  Assert-Enforced ($entry.Value -cne $supervisionText) "supervision handoff mutant changes the text: $($entry.Key)"
  Assert-Mutant "supervision-handoff-$($entry.Key)" { Test-PlatformSupervisionHandoff $entry.Value }
}

$milestonePlatformMutants = [ordered]@{}
$milestonePlatformMutants['cycle-text-dated'] = Edit-Policy $milestoneText 'then hands off new ones.' 'then hands off new ones (2026-10-21).'
$milestonePlatformMutants['selection-text-issue-number'] = Edit-Policy $milestoneText 'milestone membership never does.' 'milestone membership never does (#192).'
$milestonePlatformMutants['landing-text-iss-identity'] = Edit-Policy $milestoneText 'the platform loop refreshes its own branch.' 'the platform loop refreshes its own branch (ISS-142).'
$milestonePlatformMutants['reclamation-text-register'] = Edit-Policy $milestoneText 'until `orchestrator-shared` Platform handoff returns the issue.' 'until the ownership register changes.'
foreach ($entry in $milestonePlatformMutants.GetEnumerator()) {
  Assert-Enforced ($entry.Value -cne $milestoneText) "milestone platform mutant changes the text: $($entry.Key)"
  Assert-Mutant "milestone-platform-$($entry.Key)" { Test-MilestonePlatformText $entry.Value }
}

$milestoneSkillPath = [IO.Path]::GetFullPath((Join-Path $controller 'controller-skills/milestone-orchestrator/SKILL.md'))
$supervisionPath = [IO.Path]::GetFullPath((Join-Path $controller 'controller-skills/controller-orchestrator/references/platform-supervision.md'))
Assert-Mutant 'skill-platform-owned-rows-restored' { Test-NoRegisterOwnership (Copy-SkillFiles $skillFiles $milestoneSkillPath ($milestoneText + "`r`nThe protected set equals the platform-owned milestone rows.`r`n")) }
Assert-Mutant 'skill-register-edit-restored' { Test-NoRegisterOwnership (Copy-SkillFiles $skillFiles $milestoneSkillPath ($milestoneText + "`r`nOwnership changes need a Todd comment and the register edit.`r`n")) }
Assert-Mutant 'skill-register-read-restored' { Test-NoRegisterOwnership (Copy-SkillFiles $skillFiles $supervisionPath ($supervisionText + "`r`n" + 'Read the container''s `.orchestrator/platform-handoff.md` each cycle.' + "`r`n")) }
$handoffMutants = $script:mutants - $handoffMutantsBefore

# --- the controller loop never waits for a product install -----------------------
# The release step ends at the tag: release/ moves then and the next change starts.
# The product install is evidence to read, never a gate on the next release.
function Test-ControllerReleaseCadence([string]$Skill) {
  $release = [regex]::Match($Skill, '(?ms)^## \d+\. Change and release\r?\n(.*?)(?=^## |\z)')
  Assert-Enforced $release.Success 'controller-orchestrator has a Change and release section'
  $text = Compact-Text $release.Groups[1].Value
  $gateStep = [regex]::Match($text, '5\. (.*?) 6\. ')
  Assert-Enforced ($gateStep.Success -and $gateStep.Groups[1].Value.StartsWith('Release without waiting for approval once steps 2-4 pass; a failed review or any scan finding stops the release.', [StringComparison]::Ordinal)) 'release step 5 releases on review and scan without approval'
  Assert-Enforced ($text -notmatch '(?i)ask todd to approve|on approval') 'no release step waits on Todd''s approval'
  $tagStep = [regex]::Match($text, '6\. Release: (.*?) 7\. ')
  Assert-Enforced $tagStep.Success 'release step 6 present'
  Assert-Enforced ($tagStep.Groups[1].Value.Contains('move the dev container''s `release/` worktree to it (`git -C release checkout --detach <tag>`)', [StringComparison]::Ordinal)) 'release/ moves at tagging'
  Assert-Enforced ($tagStep.Groups[1].Value.EndsWith('Then start the next change.', [StringComparison]::Ordinal)) 'tag step ends by starting the next change'
  Assert-Enforced ($text.Contains('A tag not yet installed is not a blocker', [StringComparison]::Ordinal)) 'uninstalled tag is not a blocker'
  Assert-Enforced ($text.Contains('Any other refused or failed install the product loop reports is a controller defect.', [StringComparison]::Ordinal)) 'unexpected install failure is a controller defect'
  Assert-Enforced ($text -notmatch '(?i)(after|until|wait\w*( for)?) (its|the|a) (product )?install') 'no release step waits on the product install'
}
Test-ControllerReleaseCadence $controllerSkill
Assert-Mutant 'controller-release-waits-for-install' { Test-ControllerReleaseCadence ($controllerSkill.Replace('7. Read `check-controller-skill-freshness.ps1 -Json`', '7. Verify after its install: `check-controller-skill-freshness.ps1 -Json`')) }
Assert-Mutant 'controller-release-move-deferred' { Test-ControllerReleaseCadence ([regex]::Replace($controllerSkill, 'move the dev container''s\s+`release/` worktree to it\s+\(`git -C release checkout --detach <tag>`\),\s+', '')) }
Assert-Mutant 'controller-release-not-blocker-deleted' { Test-ControllerReleaseCadence ($controllerSkill.Replace('A tag not yet installed is not a blocker', 'An uninstalled tag is noted')) }
Assert-Mutant 'controller-release-install-failure-ignored' { Test-ControllerReleaseCadence ([regex]::Replace($controllerSkill, 'Any other refused or failed install the product loop\s+reports is a controller defect\.', 'Install failures are the product loop''s concern.')) }
Assert-Mutant 'controller-release-approval-gate-restored' { Test-ControllerReleaseCadence ([regex]::Replace($controllerSkill, '5\. Release without waiting for approval once steps 2-4 pass;', '5. Ask Todd to approve the release once steps 2-4 pass;')) }
Assert-Mutant 'controller-release-scan-gate-deleted' { Test-ControllerReleaseCadence ([regex]::Replace($controllerSkill, 'a failed\s+review or any scan finding stops the release\.', 'review and scan findings are noted.')) }
Assert-Mutant 'controller-release-next-change-deleted' { Test-ControllerReleaseCadence ([regex]::Replace($controllerSkill, '\s+Then start the next\s+change\.', '')) }

# --- both loop skills point to the shared contract -------------------------------
$sharedPointer = 'Read `orchestrator-shared` first (`~/.claude/skills/orchestrator-shared/SKILL.md`); its contract applies here and is not restated.'
function Test-SharedPointers([string]$Milestone, [string]$Controller) {
  foreach ($pair in @(@('milestone-orchestrator', $Milestone, '# Milestone Orchestrator'), @('controller-orchestrator', $Controller, '# Controller Orchestrator'))) {
    $lines = @($pair[1] -split "\r?\n" | Where-Object { $_.Trim() -ne '' })
    $title = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l.StartsWith($pair[2], [StringComparison]::Ordinal) })
    Assert-Enforced ($title -ge 0 -and $title + 1 -lt $lines.Count -and $lines[$title + 1] -ceq $sharedPointer) "$($pair[0]) opens with the orchestrator-shared pointer"
  }
  Assert-Enforced ($Milestone -match '(?m)^description: "Product loop only \(Chase Sets delivery from the product container\): ') 'milestone-orchestrator description says product loop only'
  Assert-Enforced ((Compact-Text $Milestone).Contains('then re-read this skill and `orchestrator-shared`.', [StringComparison]::Ordinal)) 'post-install re-read includes orchestrator-shared'
  Assert-Enforced ((Compact-Text $Controller).Contains('Never load milestone-orchestrator; it is the product loop''s skill.', [StringComparison]::Ordinal)) 'controller-orchestrator never loads milestone-orchestrator'
}
Test-SharedPointers $milestoneText $controllerSkill
Assert-Mutant 'milestone-shared-pointer-deleted' { Test-SharedPointers ($milestoneText.Replace($sharedPointer, '')) $controllerSkill }
Assert-Mutant 'controller-shared-pointer-deleted' { Test-SharedPointers $milestoneText ($controllerSkill.Replace($sharedPointer, '')) }
Assert-Mutant 'milestone-product-only-deleted' { Test-SharedPointers ($milestoneText.Replace('Product loop only (Chase Sets delivery from the product container): ', '')) $controllerSkill }
Assert-Mutant 'controller-loads-milestone' { Test-SharedPointers $milestoneText ($controllerSkill.Replace('Never load milestone-orchestrator; it is the product loop''s skill. ', '')) }

Write-Output 'PASS 9737 AC5 pace-raise-pin=PASS dispatch-duty-pin=PASS mutants=2 survivors=0'
Write-Output "PASS platform-supervision boundaries=$($platformRules.Count) whitespace-control=PASS"
Write-Output "PASS platform-handoff shared-rules=$($handoffRules.Count) take-back-reasons=$($takeBackReasons.Count) supervision-rules=$($supervisionRules.Count) skill-files=$($skillFiles.Count) mutants=$handoffMutants survivors=0"
Write-Output "PASS contract-enforcement files=$($hygieneFiles.Count) assertions=$($script:assertions) mutants=$($script:mutants) survivors=0"
