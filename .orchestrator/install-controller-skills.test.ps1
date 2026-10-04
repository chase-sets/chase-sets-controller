$ErrorActionPreference = "Stop"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

function New-Receipt([string]$Outcome, [string]$Head) {
  $script:reviewPair += 1
  $label = "installer-$($script:reviewPair)"
  $common = [ordered]@{
    issue = 6400; controllerHead = $Head; authorAttempt = "$label-author"; reviewerAttempt = "$label-reviewer"
    reviewAuthority = "governing"; lane = "$label-lane"; transcript = "$label.jsonl"
    reviewerModel = "gpt-5.6-sol"; authorModel = "gpt-5.6-sol"; effort = "high"; row = "7"
    placement = "measured"; harness = "codex"
  }
  $dispatch = [ordered]@{ ts = "2026-08-01T12:00:$($script:reviewPair.ToString('00')).000Z"; kind = "dispatch"; controllerReviewSchema = "controller-review-dispatch/v1" }
  foreach ($key in $common.Keys) { $dispatch[$key] = $common[$key] }
  $receipt = [ordered]@{ ts = "2026-08-01T12:00:$($script:reviewPair.ToString('00')).001Z"; kind = "review-complete"; controllerReviewSchema = "controller-review-receipt/v1" }
  foreach ($key in $common.Keys) { $receipt[$key] = $common[$key] }
  $blocking = if ($Outcome -in @("BLOCK_FIXABLE","BLOCK_REPLAN")) { 1 } else { 0 }
  $receipt.reviewContract = "review-contract/v2"; $receipt.completeSweep = $true; $receipt.outcome = $Outcome
  if ($blocking) { $receipt.findingIds = [object[]]@("INSTALLER_BLOCK_$($script:reviewPair)") }
  else { $receipt.findingIds = [object[]]@() }
  $receipt.findings = [ordered]@{ blocking = $blocking; candidates = 0; nonBlocking = 0 }
  $dispatch | ConvertTo-Json -Compress -Depth 10
  $receipt | ConvertTo-Json -Compress -Depth 10
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "controller-installer-$([guid]::NewGuid().ToString('N'))"
$destinationRoot = "$sandbox-live"
try {
  $orchestrator = Join-Path $sandbox ".orchestrator"
  $sourceRoot = Join-Path $orchestrator "controller-skills"
  $relativeFiles = @(
    "model-routing/SKILL.md",
    "model-routing/capability-matrix.json",
    "model-routing/references/capability-recalibration.md",
    "model-routing/references/experiments.md",
    "model-routing/agents/openai.yaml",
    "milestone-orchestrator/SKILL.md",
    "milestone-orchestrator/references/rule-provenance-v2.24.md",
    "milestone-orchestrator/references/controller-defect-classes.md",
    "milestone-orchestrator/scripts/query-ledgers.ps1",
    "milestone-orchestrator/scripts/query-ledgers.test.ps1",
    "milestone-orchestrator/agents/openai.yaml"
  )

  New-Item -ItemType Directory -Path $orchestrator -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "install-controller-skills.ps1") -Destination $orchestrator
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "controller-install-lock.psm1") -Destination $orchestrator
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "review-head-contract.psm1") -Destination $orchestrator
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot "controller-heavy-paths.psm1") -Destination $orchestrator
  foreach ($runtimeFile in @(
      "landed-integration-evidence.psm1",
      "integration-dispatch-contract.ps1",
      "dispatch-lane.ps1",
      "rebase-integration.ps1",
      "landed-integration-consume.ps1",
      "landed-integration-dispatch.ps1",
      "orchestration-log-lock.psm1",
      "lease-contract.psm1",
      "lease.ps1",
      "review-head-reducer.ps1",
      "landing-preflight.ps1",
      "review-queue-health.ps1",
      "log-event.ps1",
      "cost-harvest.ps1",
      "matrix-refresh.ps1",
      "check-controller-skill-freshness.ps1",
      "controller-release-battery.ps1",
      "invoke-heavy-verifier.ps1",
      "native-db-admission.py",
      "heavy-slot.cjs",
      "heavy-nested-client.cjs",
      "heavy-nested-owner.cs",
      "fail-closed-guard-evidence.ps1",
      "fail-closed-guard-evidence.schema.json",
      "fail-closed-guard-suite-result.schema.json",
      "fail-closed-guard-evidence-aggregate.ps1"
    )) {
    Set-Content -LiteralPath (Join-Path $orchestrator $runtimeFile) -Value "reviewed runtime fixture: $runtimeFile"
  }
  foreach ($relative in $relativeFiles) {
    $source = Join-Path $sourceRoot $relative
    $destination = Join-Path $destinationRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $source),(Split-Path -Parent $destination) -Force | Out-Null
    Set-Content -LiteralPath $source -Value "reviewed:$relative"
    Set-Content -LiteralPath $destination -Value "old:$relative"
  }
  $skillContractFixture = @"
# Milestone Orchestrator (v2.59)
exact-head-review-receipt/v1
exact-head-review-reducer/v1
landing-preflight/v1
"@
  Set-Content -LiteralPath (Join-Path $sourceRoot "milestone-orchestrator/SKILL.md") -Value $skillContractFixture

  & git -C $sandbox init -b main --quiet
  & git -C $sandbox config user.email "installer-test@example.invalid"
  & git -C $sandbox config user.name "Controller installer test"
  & git -C $sandbox add .
  & git -C $sandbox commit -m "fixture" --quiet
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  $installer = Join-Path $orchestrator "install-controller-skills.ps1"
  $receiptLog = Join-Path $sandbox "receipts.jsonl"
  $script:reviewPair = 0
  Set-Content -LiteralPath (Join-Path $orchestrator "controller-review-strict-v1-capability.json") -Value '{"schemaVersion":"controller-review-strict-v1-capability/v1"}'

  function Invoke-Installer([string]$ReviewedHead = $head) {
    $output = @(& pwsh -NoProfile -NonInteractive -File $installer -ReviewedCommit $ReviewedHead -ReceiptLog $receiptLog -DestinationRoot $destinationRoot 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
  }
  function Assert-Refused([string]$Expected) {
    $result = Invoke-Installer
    Assert-True ($result.ExitCode -ne 0) "installer should refuse: $Expected"
    $normalizedOutput = $result.Output -replace '\s+', ' '
    Assert-True ($normalizedOutput -match [regex]::Escape($Expected)) "refusal should explain: $Expected; output=$($result.Output)"
  }

  Set-Content -LiteralPath $receiptLog -Value ""
  Assert-Refused "exact positive controller issue identity is ambiguous"

  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "PASS" ("0" * 40))
  Assert-Refused "exact positive controller issue identity is ambiguous"

  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "BLOCK_FIXABLE" $head)
  Import-Module (Join-Path $orchestrator "review-head-contract.psm1") -Force -DisableNameChecking
  $blockProbe = Reduce-ControllerReleaseReview -Issue 6400 -ControllerHead $head -Mode strict-v1 -History (Read-ExactHeadReviewHistory -Path $receiptLog)
  Assert-True ($blockProbe.state -ceq "blocked" -and $blockProbe.reason -ceq "GOVERNING_BLOCK") "blocking strict fixture must reduce as blocked: $($blockProbe | ConvertTo-Json -Compress -Depth 20)"
  Assert-Refused "GOVERNING_BLOCK"

  Set-Content -LiteralPath $receiptLog -Value @(
    (New-Receipt "BLOCK_FIXABLE" $head),
    (New-Receipt "PASS" $head)
  )
  Assert-Refused "GOVERNING_BLOCK"

  Set-Content -LiteralPath $receiptLog -Value @(
    (New-Receipt "PASS" $head),
    (New-Receipt "BLOCK_FIXABLE" $head)
  )
  Assert-Refused "GOVERNING_BLOCK"

  Set-Content -LiteralPath $receiptLog -Value @(
    (New-Receipt "PASS" $head),
    (New-Receipt "SKIP" $head)
  )
  Assert-Refused "MALFORMED_RELEVANT_STRICT_ROW"

  $spoofedReceipt = [ordered]@{
    kind = "review-complete"
    outcome = "PASS"
    reviewContract = "review-contract/v2"
    completeSweep = $true
    note = "rebased onto baseControllerHead=$head"
  } | ConvertTo-Json -Compress
  Set-Content -LiteralPath $receiptLog -Value $spoofedReceipt
  Assert-Refused "exact positive controller issue identity is ambiguous"

  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "PASS" $head)
  $wrongHead = Invoke-Installer ("0" * 40)
  Assert-True ($wrongHead.ExitCode -ne 0 -and $wrongHead.Output -match "does not equal reviewed commit") "wrong exact head must be refused"

  $dirtySource = Join-Path $sourceRoot "model-routing/SKILL.md"
  Add-Content -LiteralPath $dirtySource -Value "dirty"
  Assert-Refused "tracked controller worktree is dirty"
  & git -C $sandbox restore -- ".orchestrator/controller-skills/model-routing/SKILL.md"

  $milestoneSkill = Join-Path $sourceRoot "milestone-orchestrator/SKILL.md"
  Set-Content -LiteralPath $milestoneSkill -Value ($skillContractFixture -replace "landing-preflight/v1", "landing-preflight/v2")
  & git -C $sandbox add ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md" | Out-Null
  & git -C $sandbox commit -q -m "fixture review contract drift" | Out-Null
  $reviewDriftHead = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "PASS" $reviewDriftHead)
  $reviewDrift = Invoke-Installer $reviewDriftHead
  Assert-True ($reviewDrift.ExitCode -ne 0 -and
    $reviewDrift.Output -match "staged skill/runtime controller contract drift") "installer refuses exact-head/preflight contract drift"

  Set-Content -LiteralPath $milestoneSkill -Value $skillContractFixture
  & git -C $sandbox add ".orchestrator/controller-skills/milestone-orchestrator/SKILL.md" | Out-Null
  & git -C $sandbox commit -q -m "restore fixture review contract" | Out-Null
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "PASS" $head)

  $missingDirectory = Join-Path $destinationRoot "milestone-orchestrator"
  Remove-Item -LiteralPath $missingDirectory -Recurse -Force
  Assert-Refused "live skill directory missing"
  foreach ($relative in $relativeFiles | Where-Object { $_ -like "model-routing/*" }) {
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $destinationRoot $relative)).Trim() -eq "old:$relative") "preflight refusal must not partially copy $relative"
  }
  New-Item -ItemType Directory -Path $missingDirectory -Force | Out-Null
  foreach ($relative in $relativeFiles | Where-Object { $_ -like "milestone-orchestrator/*" }) {
    $destination = Join-Path $destinationRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Set-Content -LiteralPath $destination -Value "old:$relative"
  }

  $success = Invoke-Installer
  Assert-True ($success.ExitCode -eq 0) "PASS-only exact-head receipt should install: $($success.Output)"
  $nativeInstalled = Join-Path $destinationRoot 'native-db/admission.py'
  $nativeIdentity = Get-Content -LiteralPath (Join-Path $destinationRoot 'native-db/identity.json') -Raw | ConvertFrom-Json
  Assert-True ($nativeIdentity.head -ceq $head -and
    $nativeIdentity.digest -ceq (Get-FileHash -LiteralPath $nativeInstalled -Algorithm SHA256).Hash.ToLowerInvariant()) 'native helper exact reviewed head and bytes'
  $nativeBytes = [IO.File]::ReadAllBytes($nativeInstalled)
  [IO.File]::WriteAllText($nativeInstalled, 'synthetic drift')
  Assert-Refused 'native helper drift'
  Assert-True ([IO.File]::ReadAllText($nativeInstalled) -ceq 'synthetic drift') 'drift refusal preserves live bytes'
  [IO.File]::WriteAllBytes($nativeInstalled, $nativeBytes)
  $nativeLock = Join-Path $orchestrator 'verify-lock.d'
  [void][IO.Directory]::CreateDirectory($nativeLock)
  $ownerPath = Join-Path $nativeLock 'owner.json'
  $liveOwner = '{"schemaVersion":6,"pid":' + $PID + ',"native":{"linux":null},"synthetic":true}'
  [IO.File]::WriteAllText($ownerPath, $liveOwner)
  $lockCreated = (Get-Item -LiteralPath $nativeLock).CreationTimeUtc.Ticks
  $ownerWritten = (Get-Item -LiteralPath $ownerPath).LastWriteTimeUtc.Ticks
  $ownerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerPath))
  Add-Content -LiteralPath $dirtySource -Value 'non-heavy fixture revision'
  & git -C $sandbox add '.orchestrator/controller-skills/model-routing/SKILL.md'
  & git -C $sandbox commit -q -m 'non-heavy install under synthetic live holder'
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt 'PASS' $head)
  $key = [IO.Path]::GetFullPath($sandbox).TrimEnd('\','/').ToUpperInvariant()
  $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
  $heldAdmission = [Threading.Mutex]::new($false, "Global\chase-sets-heavy-verifier-$hash")
  $held = $heldAdmission.WaitOne(0)
  Assert-True $held 'private admission mutex acquired'
  try {
    $nonHeavy = Invoke-Installer
    Assert-True ($nonHeavy.ExitCode -eq 0 -and $nonHeavy.Output -match 'heavy classification: non-heavy') 'non-heavy install ignores both live holder and occupied product admission'
  } finally {
    $heldAdmission.ReleaseMutex()
    $heldAdmission.Dispose()
  }
  Assert-True ((Get-Item -LiteralPath $nativeLock).CreationTimeUtc.Ticks -eq $lockCreated -and
    (Get-Item -LiteralPath $ownerPath).LastWriteTimeUtc.Ticks -eq $ownerWritten -and
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerPath)) -ceq $ownerBytes -and
    @(Get-ChildItem -LiteralPath $nativeLock).Count -eq 1) 'non-heavy install preserves lock directory and exact owner bytes without rewrite'
  foreach ($owner in @('{"schemaVersion":5}', 'unreadable')) {
    [IO.File]::WriteAllText($ownerPath, $owner)
    $retainedNonHeavy = Invoke-Installer
    Assert-True ($retainedNonHeavy.ExitCode -eq 0 -and [IO.File]::ReadAllText($ownerPath) -ceq $owner) 'non-heavy same-head install ignores retained/unreadable owners without touching them'
  }
  $identityPath = Join-Path $destinationRoot 'native-db/identity.json'
  $identityBytes = [IO.File]::ReadAllBytes($identityPath)
  foreach ($invalidIdentity in @('{}', '{"head":"' + ('0' * 40) + '","digest":"' + $nativeIdentity.digest + '"}')) {
    [IO.File]::WriteAllText($identityPath, $invalidIdentity)
    Assert-Refused 'retained verifier owner'
  }
  [IO.File]::WriteAllBytes($identityPath, $identityBytes)

  Add-Content -LiteralPath (Join-Path $orchestrator 'native-db-admission.py') -Value 'heavy helper revision'
  & git -C $sandbox add '.orchestrator/native-db-admission.py'
  & git -C $sandbox commit -q -m 'heavy install candidate'
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt 'PASS' $head)
  function Assert-HeavyOwnerRefusal($Result) {
    Assert-True ($Result.ExitCode -ne 0 -and ($Result.Output -replace '\s+', ' ') -match 'retained verifier owner') 'heavy candidate must refuse live replacement/schema6 downgrade/retained owner'
  }
  foreach ($owner in @($liveOwner, '{"schemaVersion":6,"native":{"linux":null}}', '{"schemaVersion":5}', 'unreadable')) {
    [IO.File]::WriteAllText((Join-Path $nativeLock 'owner.json'), $owner)
    $heavyRefusal = Invoke-Installer
    Assert-HeavyOwnerRefusal $heavyRefusal
    Assert-True ($heavyRefusal.Output -match 'heavy classification: heavy') 'heavy candidate records shared classification'
    Assert-True ([IO.File]::ReadAllText((Join-Path $nativeLock 'owner.json')) -ceq $owner) 'installer preserves exact retained owner, including schema6 downgrade'
  }
  $installerText = [IO.File]::ReadAllText($installer)
  $mutantText = $installerText.Replace("if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'verify-lock.d')) {", "if (`$false) {")
  Assert-True ($mutantText -cne $installerText) 'heavy-refusal mutant changes its exact target'
  [IO.File]::WriteAllText($installer, $mutantText)
  & git -C $sandbox add '.orchestrator/install-controller-skills.ps1'
  & git -C $sandbox commit -q -m 'synthetic skipped heavy refusal mutant'
  $mutantHead = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt 'PASS' $mutantHead)
  $mutantResult = Invoke-Installer $mutantHead
  Assert-True ($mutantResult.ExitCode -eq 0) 'refusal mutant reaches an install, not an unrelated failure'
  $mutantRejected = $false
  try { Assert-HeavyOwnerRefusal $mutantResult } catch { $mutantRejected = $_.Exception.Message -match '^FAIL: heavy candidate must refuse' }
  Assert-True $mutantRejected 'heavy-refusal regression assertion kills skipped-refusal mutant'
  [IO.File]::WriteAllText($installer, $installerText)
  & git -C $sandbox add '.orchestrator/install-controller-skills.ps1'
  & git -C $sandbox commit -q -m 'restore installer after synthetic mutant'
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt 'PASS' $head)
  Remove-Item -LiteralPath (Join-Path $nativeLock 'owner.json') -Force
  Remove-Item -LiteralPath $nativeLock -Force
  $success = Invoke-Installer
  Assert-True ($success.ExitCode -eq 0) 'heavy install resumes after private holder removal'
  Write-Output 'PASS native helper installer: non-heavy live/retained holders untouched; heavy live/schema5/schema6/unreadable refusals; unknown baseline fail closed; skipped-refusal mutant killed; inert destination only'
  foreach ($relative in $relativeFiles) {
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $sourceRoot $relative)).Hash
    $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $destinationRoot $relative)).Hash
    Assert-True ($sourceHash -eq $destinationHash) "installed hash should match for $relative"
  }

  # --- generated telemetry survives an install ------------------------------
  # capability-matrix.json has two owners: judgments are authored in the tracked
  # source, but `measured`/`measuredAt`/`adjudicated` are generated into the LIVE
  # file by matrix-refresh.ps1 and never committed. A straight copy reverts the
  # loop's own telemetry — worst at the worst moment, since an install follows a
  # review, which is exactly when a fresh recompute exists.
  $sourceMatrix = Join-Path $sourceRoot "model-routing/capability-matrix.json"
  $liveMatrix = Join-Path $destinationRoot "model-routing/capability-matrix.json"
  Set-Content -LiteralPath $sourceMatrix -Value ([ordered]@{
    configs = @([ordered]@{ id = "sol-high"; model = "gpt-5.6-sol"; note = "authored revision" })
  } | ConvertTo-Json -Depth 10)
  # Stage ONLY the matrix: receipts.jsonl lives in the sandbox and must stay
  # untracked, or writing the next receipt dirties the tracked worktree and the
  # installer refuses (correctly) before this scenario can run.
  & git -C $sandbox add ".orchestrator/controller-skills/model-routing/capability-matrix.json" | Out-Null
  & git -C $sandbox commit -q -m "revise authored matrix" | Out-Null
  $revisedHead = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "PASS" $revisedHead)

  Set-Content -LiteralPath $liveMatrix -Value ([ordered]@{
    configs = @([ordered]@{
      id = "sol-high"; model = "gpt-5.6-sol"
      measured = [ordered]@{ usdPerRun = 7.69; n = 191 }
      adjudicated = [ordered]@{ usdPerRun = 7.57; at = "2026-07-24" }
    })
    measuredAt = [ordered]@{ at = "2026-07-27T15:37:46Z"; runsWithCost = 575 }
  } | ConvertTo-Json -Depth 10)

  $preserved = Invoke-Installer $revisedHead
  Assert-True ($preserved.ExitCode -eq 0) "install with a revised authored matrix should succeed"
  $after = Get-Content -LiteralPath $liveMatrix -Raw | ConvertFrom-Json
  Assert-True ($after.configs[0].note -eq "authored revision") "the authored revision is installed"
  Assert-True ($after.configs[0].measured.n -eq 191) "generated measured block survives the install"
  Assert-True ($after.measuredAt.runsWithCost -eq 575) "generated measuredAt stamp survives the install"
  Assert-True ($after.configs[0].adjudicated.at -eq "2026-07-24") "the adjudicated baseline survives the install"

  Write-Output "PASS install-controller-skills preserves generated telemetry across an install"

  # --- generated telemetry survives a configuration-id rename ---------------
  # model-routing v4.13 derives every config id from model + effort and renamed
  # all twenty. A merge keyed on the literal id alone would then join nothing:
  # live's measured/adjudicated blocks silently dropped, and live's old-id
  # stamp installed beside new-id configs. The join must also match the
  # configuration itself (model + effort). Across a generated-schema change the
  # candidate's fresh blocks and stamp win; only the human adjudicated
  # snapshot transfers regardless.
  Set-Content -LiteralPath $sourceMatrix -Value ([ordered]@{
    configs = @(
      [ordered]@{ id = "gpt-5.6-sol/high"; model = "gpt-5.6-sol"; effort = "high"; note = "derived id"
                  measured = [ordered]@{ usdPerRun = 18.86; n = 1402; basis = "model+effort" } }
      [ordered]@{ id = "gpt-5.6-sol/xhigh"; model = "gpt-5.6-sol"; effort = "xhigh" }
    )
    measuredAt = [ordered]@{ at = "2026-09-08T17:00:00Z"; generatedSchema = "measured-by-configuration/v1"; configsWithoutEffortEvidence = @("gpt-5.6-sol/xhigh") }
  } | ConvertTo-Json -Depth 10)
  & git -C $sandbox add ".orchestrator/controller-skills/model-routing/capability-matrix.json" | Out-Null
  & git -C $sandbox commit -q -m "derive configuration ids" | Out-Null
  $renamedHead = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "PASS" $renamedHead)
  Set-Content -LiteralPath $liveMatrix -Value ([ordered]@{
    configs = @(
      [ordered]@{ id = "sol-high"; model = "gpt-5.6-sol"; effort = "high"
        measured = [ordered]@{ usdPerRun = 7.69; n = 191 }
        adjudicated = [ordered]@{ usdPerRun = 7.57; at = "2026-07-24" } }
      [ordered]@{ id = "sol-xhigh"; model = "gpt-5.6-sol"; effort = "xhigh"
        measured = [ordered]@{ usdPerRun = 7.69; n = 191 } }
    )
    measuredAt = [ordered]@{ at = "2026-07-27T15:37:46Z"; runsWithCost = 575 }
  } | ConvertTo-Json -Depth 10)
  $renamed = Invoke-Installer $renamedHead
  Assert-True ($renamed.ExitCode -eq 0) "install across a configuration-id rename should succeed"
  $after = Get-Content -LiteralPath $liveMatrix -Raw | ConvertFrom-Json -DateKind String
  $solHigh = $after.configs | Where-Object id -ceq "gpt-5.6-sol/high"
  $solXhigh = $after.configs | Where-Object id -ceq "gpt-5.6-sol/xhigh"
  Assert-True ($null -ne $solHigh -and $solHigh.adjudicated.at -eq "2026-07-24") "the adjudicated baseline follows the configuration across the rename"
  Assert-True ($solHigh.measured.n -eq 1402 -and $solHigh.measured.basis -eq "model+effort") "across a generated-schema change the candidate's per-configuration block wins over live's pooled block"
  Assert-True ($null -eq $solXhigh.PSObject.Properties["measured"]) "a live pooled block is not installed onto a configuration the candidate lists as having no evidence"
  Assert-True ($after.measuredAt.generatedSchema -eq "measured-by-configuration/v1" -and @($after.measuredAt.configsWithoutEffortEvidence) -ccontains "gpt-5.6-sol/xhigh") "the candidate's stamp is installed rather than an orphaned old-id stamp"

  # Same schema on both sides: live's newer generated blocks are preserved
  # through the rename, joined by configuration; a live stamp that still names
  # a pre-rename id is orphaned and the candidate's stamp is kept. A fresh
  # reviewed head is needed because an install at an already-installed head
  # is a no-op.
  Set-Content -LiteralPath $sourceMatrix -Value ((Get-Content -LiteralPath $sourceMatrix -Raw).Replace('"derived id"', '"derived id, second revision"'))
  & git -C $sandbox add ".orchestrator/controller-skills/model-routing/capability-matrix.json" | Out-Null
  & git -C $sandbox commit -q -m "derive configuration ids, second revision" | Out-Null
  $renamedHead = (& git -C $sandbox rev-parse HEAD).Trim()
  Set-Content -LiteralPath $receiptLog -Value (New-Receipt "PASS" $renamedHead)
  Set-Content -LiteralPath $liveMatrix -Value ([ordered]@{
    configs = @(
      [ordered]@{ id = "sol-high"; model = "gpt-5.6-sol"; effort = "high"
        measured = [ordered]@{ usdPerRun = 19.10; n = 1450; basis = "model+effort" }
        adjudicated = [ordered]@{ usdPerRun = 7.57; at = "2026-07-24" } }
      [ordered]@{ id = "sol-xhigh"; model = "gpt-5.6-sol"; effort = "xhigh" }
    )
    measuredAt = [ordered]@{ at = "2026-09-08T18:00:00Z"; generatedSchema = "measured-by-configuration/v1"; configsWithoutEffortEvidence = @("sol-xhigh") }
  } | ConvertTo-Json -Depth 10)
  $sameSchema = Invoke-Installer $renamedHead
  Assert-True ($sameSchema.ExitCode -eq 0) "same-schema install across a rename should succeed"
  $after = Get-Content -LiteralPath $liveMatrix -Raw | ConvertFrom-Json -DateKind String
  $solHigh = $after.configs | Where-Object id -ceq "gpt-5.6-sol/high"
  Assert-True ($solHigh.measured.n -eq 1450) "within one schema the live measured block follows the configuration across the rename"
  Assert-True ($after.measuredAt.at -eq "2026-09-08T17:00:00Z") "a live stamp naming a configuration absent from the merged matrix is orphaned and the candidate's stamp is kept"
  Write-Output "PASS install-controller-skills joins generated telemetry by configuration across an id rename and a schema change"

  Write-Output "PASS install-controller-skills review receipt and install coverage"
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
  }
  if (Test-Path -LiteralPath $destinationRoot) {
    Remove-Item -LiteralPath $destinationRoot -Recurse -Force
  }
}
