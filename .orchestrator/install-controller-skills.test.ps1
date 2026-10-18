$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingScope = Enter-RoutingDataTestScope

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

# Two repositories with unrelated histories, as on the host: a release
# repository that carries annotated controller-v* tags, and a container whose
# own history is private. The installer must fetch a release by URL into the
# container, never configure a remote, and never disturb a container tag that
# shares the release name.
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "controller-installer-$([guid]::NewGuid().ToString('N'))"
$publisher = Join-Path $sandbox "publisher"
$container = Join-Path $sandbox "container"
$destinationRoot = Join-Path $sandbox "live"
try {
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
  $runtimeFixtures = @(
    "landed-integration-evidence.psm1", "integration-dispatch-contract.ps1", "dispatch-lane.ps1",
    "rebase-integration.ps1", "landed-integration-consume.ps1", "landed-integration-dispatch.ps1",
    "orchestration-log-lock.psm1", "lease-contract.psm1", "lease.ps1", "review-head-reducer.ps1",
    "landing-preflight.ps1", "review-queue-health.ps1", "log-event.ps1", "harvest-observed-lanes.ps1",
    "cost-harvest.ps1", "matrix-refresh.ps1", "check-controller-skill-freshness.ps1",
    "controller-release-battery.ps1", "invoke-heavy-verifier.ps1", "native-db-admission.py",
    "heavy-slot.cjs", "heavy-nested-client.cjs", "heavy-nested-owner.cs", "fail-closed-guard-evidence.ps1",
    "fail-closed-guard-evidence.schema.json", "fail-closed-guard-suite-result.schema.json",
    "fail-closed-guard-evidence-aggregate.ps1"
  )
  $skillContractFixture = @"
# Milestone Orchestrator (v2.59)
exact-head-review-receipt/v1
exact-head-review-reducer/v1
landing-preflight/v1
"@

  function Initialize-Repository([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    & git -C $Path init -b main --quiet
    & git -C $Path config user.email "installer-test@example.invalid"
    & git -C $Path config user.name "Controller installer test"
    & git -C $Path config core.autocrlf false
  }
  function Write-ControllerTree([string]$Root) {
    $orchestrator = Join-Path $Root ".orchestrator"
    New-Item -ItemType Directory -Path $orchestrator -Force | Out-Null
    foreach ($name in @("install-controller-skills.ps1", "controller-install-lock.psm1", "review-head-contract.psm1",
        "routing-data.ps1", "controller-heavy-paths.psm1")) {
      Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $orchestrator
    }
    foreach ($runtimeFile in $runtimeFixtures) {
      Set-Content -LiteralPath (Join-Path $orchestrator $runtimeFile) -Value "released runtime fixture: $runtimeFile"
    }
    foreach ($relative in $relativeFiles) {
      $source = Join-Path $orchestrator "controller-skills/$relative"
      New-Item -ItemType Directory -Path (Split-Path -Parent $source) -Force | Out-Null
      Set-Content -LiteralPath $source -Value "released:$relative"
    }
    Set-Content -LiteralPath (Join-Path $orchestrator "controller-skills/milestone-orchestrator/SKILL.md") -Value $skillContractFixture
  }
  function Publish-Release([string]$Tag, [scriptblock]$Change) {
    if ($Change) { & $Change }
    & git -C $publisher add -A
    & git -C $publisher commit -q --allow-empty -m "release $Tag"
    & git -C $publisher tag -a $Tag -m "release $Tag"
    (& git -C $publisher rev-parse HEAD).Trim()
  }
  function Get-ContainerHead { (& git -C $container rev-parse HEAD).Trim() }
  function Invoke-Installer([string]$Tag) {
    $installer = Join-Path $container ".orchestrator/install-controller-skills.ps1"
    $output = @(& pwsh -NoProfile -NonInteractive -File $installer -ReleaseTag $Tag -ReleaseRepository $publisher -DestinationRoot $destinationRoot 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
  }
  function Assert-Refused([string]$Tag, [string]$Expected) {
    $result = Invoke-Installer $Tag
    Assert-True ($result.ExitCode -ne 0) "installer should refuse $($Tag): $Expected"
    Assert-True (($result.Output -replace '\s+', ' ') -match [regex]::Escape($Expected)) "refusal should explain: $Expected; output=$($result.Output)"
    $result
  }
  function Assert-Installed([string]$Tag, [string]$Commit) {
    foreach ($relative in $relativeFiles | Where-Object { $_ -ne "model-routing/capability-matrix.json" }) {
      $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $container ".orchestrator/controller-skills/$relative")).Hash
      $liveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $destinationRoot $relative)).Hash
      Assert-True ($sourceHash -eq $liveHash) "installed hash should match for $relative at $Tag"
    }
    $identity = Get-Content -LiteralPath (Join-Path $destinationRoot "native-db/identity.json") -Raw | ConvertFrom-Json
    $helper = Join-Path $destinationRoot "native-db/admission.py"
    Assert-True ($identity.head -ceq $Commit -and @($identity.PSObject.Properties.Name).Count -eq 2 -and
      $identity.digest -ceq (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()) "native helper identity names $Tag"
    $record = Get-Content -LiteralPath (Join-Path $destinationRoot "native-db/release.json") -Raw | ConvertFrom-Json -DateKind String
    $tagObject = (& git -C $publisher rev-parse "refs/tags/$Tag").Trim()
    Assert-True ($record.schemaVersion -ceq "controller-release/v1" -and $record.tag -ceq $Tag -and
      $record.commit -ceq $Commit -and $record.tagObject -ceq $tagObject) "release record names $Tag"
    Assert-True ((Get-ContainerHead) -ceq $Commit) "container checkout is $Tag"
    & git -C $container symbolic-ref -q HEAD | Out-Null
    Assert-True ($LASTEXITCODE -ne 0) "container checkout is detached"
    Assert-True (@(& git -C $container remote).Count -eq 0) "installer never configures a remote"
  }

  # --- release repository and private container --------------------------
  Initialize-Repository $publisher
  Write-ControllerTree $publisher
  $v11 = Publish-Release "controller-v1.1"

  Initialize-Repository $container
  Write-ControllerTree $container
  Set-Content -LiteralPath (Join-Path $container "private-history.txt") -Value "private container history"
  & git -C $container add -A
  & git -C $container commit -q -m "private container commit"
  $privateHead = Get-ContainerHead
  & git -C $container tag -a "controller-v1.1" -m "container-local tag sharing a release name"
  $containerTagObject = (& git -C $container rev-parse "refs/tags/controller-v1.1").Trim()
  foreach ($relative in $relativeFiles) {
    $destination = Join-Path $destinationRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Set-Content -LiteralPath $destination -Value "old:$relative"
  }

  # --- refusals before anything changes ----------------------------------
  $dirtySource = Join-Path $container ".orchestrator/controller-skills/model-routing/SKILL.md"
  Add-Content -LiteralPath $dirtySource -Value "dirty"
  [void](Assert-Refused "controller-v1.1" "tracked controller worktree is dirty")
  & git -C $container restore -- ".orchestrator/controller-skills/model-routing/SKILL.md"

  [void](Assert-Refused "controller-v9.9" "release tag controller-v9.9 not found")
  $badName = Invoke-Installer "v1.1"
  Assert-True ($badName.ExitCode -ne 0 -and $badName.Output -match "ReleaseTag") "a tag outside controller-v* is rejected by the parameter contract"

  & git -C $publisher tag "controller-v1.0" $v11
  [void](Assert-Refused "controller-v1.0" "controller-v1.0 is not an annotated tag")

  $legacy = Join-Path $publisher ".orchestrator/install-controller-skills.ps1"
  $current = [IO.File]::ReadAllText($legacy)
  [void](Publish-Release "controller-v0.9" { [IO.File]::WriteAllText($legacy, "# installer that predates tag installs`n") })
  [void](Publish-Release "controller-v1.1.1" { [IO.File]::WriteAllText($legacy, $current) })
  [void](Assert-Refused "controller-v0.9" "controller-v0.9 predates tag installs")
  Assert-True ((Get-ContainerHead) -ceq $privateHead) "refusals leave the container checkout unchanged"
  foreach ($relative in $relativeFiles) {
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $destinationRoot $relative)).Trim() -eq "old:$relative") "refusal must not copy $relative"
  }

  # --- first install by tag ------------------------------------------------
  $missingDirectory = Join-Path $destinationRoot "milestone-orchestrator"
  Remove-Item -LiteralPath $missingDirectory -Recurse -Force
  [void](Assert-Refused "controller-v1.1" "live skill directory missing")
  foreach ($relative in $relativeFiles | Where-Object { $_ -like "model-routing/*" }) {
    Assert-True ((Get-Content -Raw -LiteralPath (Join-Path $destinationRoot $relative)).Trim() -eq "old:$relative") "preflight refusal must not partially copy $relative"
  }
  New-Item -ItemType Directory -Path $missingDirectory -Force | Out-Null

  $success = Invoke-Installer "controller-v1.1"
  Assert-True ($success.ExitCode -eq 0 -and $success.Output -match "Installed controller release controller-v1\.1 \($v11\)") "annotated release installs: $($success.Output)"
  Assert-Installed "controller-v1.1" $v11
  Assert-True ((& git -C $container rev-parse "refs/tags/controller-v1.1").Trim() -ceq $containerTagObject) "container-local tag with the release name is untouched"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $container "private-history.txt"))) "release tree replaces the private checkout"
  & git -C $container cat-file -e "$privateHead^{commit}"
  Assert-True ($LASTEXITCODE -eq 0) "private history stays in the container"

  $again = Invoke-Installer "controller-v1.1"
  Assert-True ($again.ExitCode -eq 0) "re-installing the installed release is allowed: $($again.Output)"

  # --- native helper drift ---------------------------------------------------
  $nativeInstalled = Join-Path $destinationRoot 'native-db/admission.py'
  $nativeBytes = [IO.File]::ReadAllBytes($nativeInstalled)
  [IO.File]::WriteAllText($nativeInstalled, 'synthetic drift')
  [void](Assert-Refused "controller-v1.1" 'native helper drift')
  Assert-True ([IO.File]::ReadAllText($nativeInstalled) -ceq 'synthetic drift') 'drift refusal preserves live bytes'
  [IO.File]::WriteAllBytes($nativeInstalled, $nativeBytes)

  # --- heavy guard ----------------------------------------------------------
  $nativeLock = Join-Path $container '.orchestrator/verify-lock.d'
  [void][IO.Directory]::CreateDirectory($nativeLock)
  $ownerPath = Join-Path $nativeLock 'owner.json'
  $liveOwner = '{"schemaVersion":6,"pid":' + $PID + ',"native":{"linux":null},"synthetic":true}'
  [IO.File]::WriteAllText($ownerPath, $liveOwner)
  $lockCreated = (Get-Item -LiteralPath $nativeLock).CreationTimeUtc.Ticks
  $ownerWritten = (Get-Item -LiteralPath $ownerPath).LastWriteTimeUtc.Ticks
  $ownerBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerPath))
  $v12 = Publish-Release "controller-v1.2" { Add-Content -LiteralPath (Join-Path $publisher ".orchestrator/controller-skills/model-routing/SKILL.md") -Value "non-heavy revision" }
  $key = [IO.Path]::GetFullPath($container).TrimEnd('\','/').ToUpperInvariant()
  $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
  $heldAdmission = [Threading.Mutex]::new($false, "Global\chase-sets-heavy-verifier-$hash")
  $held = $heldAdmission.WaitOne(0)
  Assert-True $held 'private admission mutex acquired'
  try {
    $nonHeavy = Invoke-Installer "controller-v1.2"
    Assert-True ($nonHeavy.ExitCode -eq 0 -and $nonHeavy.Output -match 'heavy classification: non-heavy') "non-heavy release ignores both live holder and occupied product admission: $($nonHeavy.Output)"
  } finally {
    $heldAdmission.ReleaseMutex()
    $heldAdmission.Dispose()
  }
  Assert-Installed "controller-v1.2" $v12
  Assert-True ((Get-Item -LiteralPath $nativeLock).CreationTimeUtc.Ticks -eq $lockCreated -and
    (Get-Item -LiteralPath $ownerPath).LastWriteTimeUtc.Ticks -eq $ownerWritten -and
    [Convert]::ToBase64String([IO.File]::ReadAllBytes($ownerPath)) -ceq $ownerBytes -and
    @(Get-ChildItem -LiteralPath $nativeLock).Count -eq 1) 'non-heavy install preserves lock directory and exact owner bytes without rewrite'
  foreach ($owner in @('{"schemaVersion":5}', 'unreadable')) {
    [IO.File]::WriteAllText($ownerPath, $owner)
    $retainedNonHeavy = Invoke-Installer "controller-v1.2"
    Assert-True ($retainedNonHeavy.ExitCode -eq 0 -and [IO.File]::ReadAllText($ownerPath) -ceq $owner) 'non-heavy same-release install ignores retained/unreadable owners without touching them'
  }
  $identityPath = Join-Path $destinationRoot 'native-db/identity.json'
  $identityBytes = [IO.File]::ReadAllBytes($identityPath)
  $digest = (Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json).digest
  foreach ($invalidIdentity in @('{}', '{"head":"' + ('0' * 40) + '","digest":"' + $digest + '"}')) {
    [IO.File]::WriteAllText($identityPath, $invalidIdentity)
    [void](Assert-Refused "controller-v1.2" 'retained verifier owner')
  }
  [IO.File]::WriteAllBytes($identityPath, $identityBytes)

  $v13 = Publish-Release "controller-v1.3" { Add-Content -LiteralPath (Join-Path $publisher '.orchestrator/native-db-admission.py') -Value 'heavy helper revision' }
  function Assert-HeavyOwnerRefusal($Result) {
    Assert-True ($Result.ExitCode -ne 0 -and ($Result.Output -replace '\s+', ' ') -match 'retained verifier owner') 'heavy release must refuse live replacement/schema6 downgrade/retained owner'
  }
  foreach ($owner in @($liveOwner, '{"schemaVersion":6,"native":{"linux":null}}', '{"schemaVersion":5}', 'unreadable')) {
    [IO.File]::WriteAllText($ownerPath, $owner)
    $heavyRefusal = Invoke-Installer "controller-v1.3"
    Assert-HeavyOwnerRefusal $heavyRefusal
    Assert-True ($heavyRefusal.Output -match 'heavy classification: heavy') 'heavy release records shared classification'
    Assert-True ([IO.File]::ReadAllText($ownerPath) -ceq $owner) 'installer preserves exact retained owner, including schema6 downgrade'
  }
  Assert-True ((Get-ContainerHead) -ceq $v13) 'a refused heavy install leaves the release checked out for the next attempt'
  $record = Get-Content -LiteralPath (Join-Path $destinationRoot "native-db/release.json") -Raw | ConvertFrom-Json
  Assert-True ($record.tag -ceq "controller-v1.2") 'a refused install does not record the refused release'

  $installerPath = Join-Path $publisher '.orchestrator/install-controller-skills.ps1'
  $installerText = [IO.File]::ReadAllText($installerPath)
  $mutantText = $installerText.Replace("if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'verify-lock.d')) {", "if (`$false) {")
  Assert-True ($mutantText -cne $installerText) 'heavy-refusal mutant changes its exact target'
  [void](Publish-Release "controller-v1.4" { [IO.File]::WriteAllText($installerPath, $mutantText) })
  $mutantResult = Invoke-Installer "controller-v1.4"
  Assert-True ($mutantResult.ExitCode -eq 0) "refusal mutant reaches an install, not an unrelated failure: $($mutantResult.Output)"
  $mutantRejected = $false
  try { Assert-HeavyOwnerRefusal $mutantResult } catch { $mutantRejected = $_.Exception.Message -match '^FAIL: heavy release must refuse' }
  Assert-True $mutantRejected 'heavy-refusal regression assertion kills skipped-refusal mutant'
  [void](Publish-Release "controller-v1.4.1" { [IO.File]::WriteAllText($installerPath, $installerText) })

  # Rollback is the same command with an earlier tag.
  Remove-Item -LiteralPath $ownerPath -Force
  Remove-Item -LiteralPath $nativeLock -Force
  $rollback = Invoke-Installer "controller-v1.3"
  Assert-True ($rollback.ExitCode -eq 0) "rollback to an earlier release installs: $($rollback.Output)"
  Assert-Installed "controller-v1.3" $v13
  Write-Output 'PASS native helper installer: non-heavy live/retained holders untouched; heavy live/schema5/schema6/unreadable refusals; unknown baseline fail closed; skipped-refusal mutant killed; rollback by tag'

  # --- generated telemetry survives an install ------------------------------
  # capability-matrix.json has two owners: judgments are authored in the tracked
  # source, but measured/measuredAt/adjudicated are generated into the LIVE
  # file by matrix-refresh.ps1 and never committed. A straight copy would revert
  # the loop's own telemetry.
  $sourceMatrix = Join-Path $publisher ".orchestrator/controller-skills/model-routing/capability-matrix.json"
  $liveMatrix = Join-Path $destinationRoot "model-routing/capability-matrix.json"
  [void](Publish-Release "controller-v1.5" {
    Set-Content -LiteralPath $sourceMatrix -Value ([ordered]@{
      configs = @([ordered]@{ id = "sol-high"; model = "gpt-5.6-sol"; note = "authored revision" })
    } | ConvertTo-Json -Depth 10)
  })
  Set-Content -LiteralPath $liveMatrix -Value ([ordered]@{
    configs = @([ordered]@{
      id = "sol-high"; model = "gpt-5.6-sol"
      measured = [ordered]@{ usdPerRun = 7.69; n = 191 }
      adjudicated = [ordered]@{ usdPerRun = 7.57; at = "2026-07-24" }
    })
    measuredAt = [ordered]@{ at = "2026-07-27T15:37:46Z"; runsWithCost = 575 }
  } | ConvertTo-Json -Depth 10)
  $preserved = Invoke-Installer "controller-v1.5"
  Assert-True ($preserved.ExitCode -eq 0) "release with a revised authored matrix should install: $($preserved.Output)"
  $after = Get-Content -LiteralPath $liveMatrix -Raw | ConvertFrom-Json
  Assert-True ($after.configs[0].note -eq "authored revision") "the authored revision is installed"
  Assert-True ($after.configs[0].measured.n -eq 191) "generated measured block survives the install"
  Assert-True ($after.measuredAt.runsWithCost -eq 575) "generated measuredAt stamp survives the install"
  Assert-True ($after.configs[0].adjudicated.at -eq "2026-07-24") "the adjudicated baseline survives the install"
  Write-Output "PASS install-controller-skills preserves generated telemetry across an install"

  # --- generated telemetry survives a configuration-id rename ---------------
  # The join matches the configuration itself (model + effort), not only the
  # literal id. Across a generated-schema change the candidate's fresh blocks
  # and stamp win; only the human adjudicated snapshot transfers regardless.
  [void](Publish-Release "controller-v1.6" {
    Set-Content -LiteralPath $sourceMatrix -Value ([ordered]@{
      configs = @(
        [ordered]@{ id = "gpt-5.6-sol/high"; model = "gpt-5.6-sol"; effort = "high"; note = "derived id"
                    measured = [ordered]@{ usdPerRun = 18.86; n = 1402; basis = "model+effort" } }
        [ordered]@{ id = "gpt-5.6-sol/xhigh"; model = "gpt-5.6-sol"; effort = "xhigh" }
      )
      measuredAt = [ordered]@{ at = "2026-09-08T17:00:00Z"; generatedSchema = "measured-by-configuration/v1"; configsWithoutEffortEvidence = @("gpt-5.6-sol/xhigh") }
    } | ConvertTo-Json -Depth 10)
  })
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
  $renamed = Invoke-Installer "controller-v1.6"
  Assert-True ($renamed.ExitCode -eq 0) "install across a configuration-id rename should succeed: $($renamed.Output)"
  $after = Get-Content -LiteralPath $liveMatrix -Raw | ConvertFrom-Json -DateKind String
  $solHigh = $after.configs | Where-Object id -ceq "gpt-5.6-sol/high"
  $solXhigh = $after.configs | Where-Object id -ceq "gpt-5.6-sol/xhigh"
  Assert-True ($null -ne $solHigh -and $solHigh.adjudicated.at -eq "2026-07-24") "the adjudicated baseline follows the configuration across the rename"
  Assert-True ($solHigh.measured.n -eq 1402 -and $solHigh.measured.basis -eq "model+effort") "across a generated-schema change the candidate's per-configuration block wins over live's pooled block"
  Assert-True ($null -eq $solXhigh.PSObject.Properties["measured"]) "a live pooled block is not installed onto a configuration the candidate lists as having no evidence"
  Assert-True ($after.measuredAt.generatedSchema -eq "measured-by-configuration/v1" -and @($after.measuredAt.configsWithoutEffortEvidence) -ccontains "gpt-5.6-sol/xhigh") "the candidate's stamp is installed rather than an orphaned old-id stamp"

  # Same schema on both sides: live's newer generated blocks are preserved
  # through the rename, joined by configuration; a live stamp that still names
  # a pre-rename id is orphaned and the candidate's stamp is kept.
  [void](Publish-Release "controller-v1.7" {
    Set-Content -LiteralPath $sourceMatrix -Value ((Get-Content -LiteralPath $sourceMatrix -Raw).Replace('"derived id"', '"derived id, second revision"'))
  })
  Set-Content -LiteralPath $liveMatrix -Value ([ordered]@{
    configs = @(
      [ordered]@{ id = "sol-high"; model = "gpt-5.6-sol"; effort = "high"
        measured = [ordered]@{ usdPerRun = 19.10; n = 1450; basis = "model+effort" }
        adjudicated = [ordered]@{ usdPerRun = 7.57; at = "2026-07-24" } }
      [ordered]@{ id = "sol-xhigh"; model = "gpt-5.6-sol"; effort = "xhigh" }
    )
    measuredAt = [ordered]@{ at = "2026-09-08T18:00:00Z"; generatedSchema = "measured-by-configuration/v1"; configsWithoutEffortEvidence = @("sol-xhigh") }
  } | ConvertTo-Json -Depth 10)
  $sameSchema = Invoke-Installer "controller-v1.7"
  Assert-True ($sameSchema.ExitCode -eq 0) "same-schema install across a rename should succeed: $($sameSchema.Output)"
  $after = Get-Content -LiteralPath $liveMatrix -Raw | ConvertFrom-Json -DateKind String
  $solHigh = $after.configs | Where-Object id -ceq "gpt-5.6-sol/high"
  Assert-True ($solHigh.measured.n -eq 1450) "within one schema the live measured block follows the configuration across the rename"
  Assert-True ($after.measuredAt.at -eq "2026-09-08T17:00:00Z") "a live stamp naming a configuration absent from the merged matrix is orphaned and the candidate's stamp is kept"
  Write-Output "PASS install-controller-skills joins generated telemetry by configuration across an id rename and a schema change"

  # --- a moved release tag is refused ----------------------------------------
  $installedBeforeMove = Get-ContainerHead
  & git -C $publisher tag -d "controller-v1.6" | Out-Null
  & git -C $publisher tag -a "controller-v1.6" -m "moved release" $v11
  [void](Assert-Refused "controller-v1.6" "release tag controller-v1.6 moved")
  Assert-True ((Get-ContainerHead) -ceq $installedBeforeMove) "a moved tag leaves the checkout unchanged"

  Write-Output "PASS install-controller-skills release-tag authority, fetch-only container, and install coverage"
} finally {
  Exit-RoutingDataTestScope $routingScope
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
  }
}
