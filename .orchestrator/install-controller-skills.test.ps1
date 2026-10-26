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
$codexRoot = Join-Path $sandbox "codex-skills"
$realCodexRoot = Join-Path $HOME ".codex/skills"
function Get-CodexRootSnapshot([string]$Root) {
  if (-not (Test-Path -LiteralPath $Root)) { return '' }
  (@(Get-ChildItem -LiteralPath $Root -Force | Sort-Object Name | ForEach-Object { "$($_.Name)|$($_.LinkType)|$(@($_.Target)[0])" }) -join "`n")
}
$realCodexBefore = Get-CodexRootSnapshot $realCodexRoot
  $reusedProcess = $null
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
    "milestone-orchestrator/agents/openai.yaml",
    "orchestrator-shared/SKILL.md",
    "orchestrator-shared/agents/openai.yaml"
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
    $output = @(& pwsh -NoProfile -NonInteractive -File $installer -ReleaseTag $Tag -ReleaseRepository $publisher -DestinationRoot $destinationRoot -CodexSkillRoot $codexRoot 2>&1)
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
  }
  function Assert-Refused([string]$Tag, [string]$Expected) {
    $result = Invoke-Installer $Tag
    Assert-True ($result.ExitCode -ne 0) "installer should refuse $($Tag): $Expected"
    $plainOutput = ($result.Output -replace '(?m)^\s*\|\s?', '') -replace '\s+', ' '
    Assert-True ($plainOutput -match [regex]::Escape($Expected)) "refusal should explain: $Expected; output=$($result.Output)"
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

  # An entry the user already has in the Codex skill root is never replaced.
  $userCodexEntry = Join-Path $codexRoot "model-routing"
  New-Item -ItemType Directory -Path $userCodexEntry -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $userCodexEntry "user.txt") -Value "user entry"

  # --- first install by tag ------------------------------------------------
  $missingDirectory = Join-Path $destinationRoot "milestone-orchestrator"
  Remove-Item -LiteralPath $missingDirectory -Recurse -Force
  [void](Assert-Refused "controller-v1.1" "live skill directory missing")
  [void](Assert-Refused "controller-v1.1" "cannot prove the skill is new: no installed release record")
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
  $installerText = [IO.File]::ReadAllText((Join-Path $publisher '.orchestrator/install-controller-skills.ps1'))
  $handoverMutantText = [regex]::Replace($installerText,
    '(?ms)  \$handoverExit = \$LASTEXITCODE\r?\n.*?  exit \$handoverExit',
    '  exit $LASTEXITCODE')
  Assert-True ($handoverMutantText -cne $installerText) 'handover-restore mutant changes its exact target'

  # Control: install the same candidate through an outer installer with the
  # restore block removed. The refusal is expected to leave candidate bytes and
  # the candidate HEAD, proving this regression test detects the pre-fix defect.
  $controlContainer = Join-Path $sandbox 'control-container'
  $controlDestination = Join-Path $sandbox 'control-live'
  $controlCodexRoot = Join-Path $sandbox 'control-codex-skills'
  & git clone --quiet --no-hardlinks $container $controlContainer
  & git -C $controlContainer remote remove origin
  [IO.File]::WriteAllText((Join-Path $controlContainer '.orchestrator/install-controller-skills.ps1'), $handoverMutantText)
  & git -C $controlContainer add .orchestrator/install-controller-skills.ps1
  & git -C $controlContainer commit -q -m 'control mutant'
  Copy-Item -LiteralPath $destinationRoot -Destination $controlDestination -Recurse -Force
  $controlOwnerPath = Join-Path $controlContainer '.orchestrator/verify-lock.d/owner.json'
  [void][IO.Directory]::CreateDirectory((Split-Path -Parent $controlOwnerPath))
  [IO.File]::WriteAllText($controlOwnerPath, $liveOwner)
  $controlInstalledHead = (& git -C $controlContainer rev-parse HEAD).Trim()
  $controlInstaller = Join-Path $controlContainer '.orchestrator/install-controller-skills.ps1'
  $controlOutput = @(& pwsh -NoProfile -NonInteractive -File $controlInstaller -ReleaseTag 'controller-v1.3' -ReleaseRepository $publisher -DestinationRoot $controlDestination -CodexSkillRoot $controlCodexRoot 2>&1)
  $controlExit = $LASTEXITCODE
  $controlHead = (& git -C $controlContainer rev-parse HEAD).Trim()
  & git -C $controlContainer diff --quiet $controlInstalledHead -- .orchestrator
  $controlTreeChanged = $LASTEXITCODE -ne 0
  Assert-True ($controlExit -ne 0 -and $controlHead -ceq $v13 -and $controlTreeChanged) 'pre-fix handover mutant leaves candidate HEAD and bytes'
  Write-Output 'PASS control mutant: without handover restore, refusal leaves candidate HEAD and tracked candidate bytes'

  # A valid dead legacy owner is reclaimable under the same mutex used by the
  # heavy verifier. The candidate then installs and removes only its lock.
  $deadStarted = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
  $deadOwner = [ordered]@{
    schemaVersion = [long]4; lockId = ('a' * 32); owner = 'dead@test'; lane = 'dead-owner'; branch = $null
    pid = 2147483647; processStartUtc = '2020-01-01T00:00:00Z'; startedUtc = $deadStarted
    gate = 'verify:test'; commandIdentity = ('b' * 64); worktree = (Resolve-Path $container).Path
    head = $v12; identityMode = 'immutable-head'; state = 'started'; childPid = 2147483646; childProcessStartUtc = $deadStarted
  }
  [IO.File]::WriteAllText($ownerPath, ($deadOwner | ConvertTo-Json -Compress))
  [void](Publish-Release "controller-v1.3.2" { [IO.File]::WriteAllText((Join-Path $publisher '.orchestrator/install-controller-skills.ps1'), $installerText) })
  $reclaimed = Invoke-Installer 'controller-v1.3.2'
  Assert-True ($reclaimed.ExitCode -eq 0 -and $reclaimed.Output -match 'Installed controller release controller-v1\.3\.2') "dead owner is reclaimed and heavy install proceeds: $($reclaimed.Output)"
  Assert-True (-not (Test-Path -LiteralPath $nativeLock)) 'dead owner reclaim removes verify-lock.d'
  $installedHeadBeforeHeavy = Get-ContainerHead
  $v14 = Publish-Release "controller-v1.4" { Add-Content -LiteralPath (Join-Path $publisher '.orchestrator/native-db-admission.py') -Value 'second heavy helper revision' }
  $schema5Root = Join-Path ([IO.Path]::GetTempPath()) 'chase-sets-heavy-admission-207-f1'
  [void][IO.Directory]::CreateDirectory($schema5Root)
  [IO.File]::WriteAllText((Join-Path $schema5Root 'sentinel.txt'), 'retain this root')
  $reusedScript = Join-Path $sandbox 'reused-child.vbs'
  [IO.File]::WriteAllText($reusedScript, 'WScript.Sleep 60000')
  $reusedProcess = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32/wscript.exe') -ArgumentList @('//B', '//Nologo', $reusedScript) -WindowStyle Hidden -PassThru
  $schema5Owner = [ordered]@{
    schemaVersion = [long]5; lockId = ('c' * 32); owner = 'reused@test'; lane = 'reused-child'; branch = 'main'
    pid = 2147483647; processStartUtc = '2020-01-01T00:00:00Z'; startedUtc = $deadStarted
    gate = 'verify:test'; commandIdentity = ('d' * 64); worktree = (Resolve-Path $container).Path
    head = $v13; identityMode = 'branch'; state = 'attached'; childPid = $reusedProcess.Id
    childProcessStartUtc = '2020-01-01T00:00:00Z'; admissionRoot = $schema5Root
  }
  [void][IO.Directory]::CreateDirectory($nativeLock)
  [IO.File]::WriteAllText($ownerPath, ($schema5Owner | ConvertTo-Json -Compress))
  $reusedChild = Invoke-Installer 'controller-v1.4'
  Assert-True ($reusedChild.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $nativeLock)) "schema-5 reused child owner is reclaimed and install proceeds: $($reusedChild.Output)"
  Assert-True ((Test-Path -LiteralPath $schema5Root) -and (Test-Path -LiteralPath (Join-Path $schema5Root 'sentinel.txt'))) 'schema-5 reused child preserves its admission root'
  Remove-Item -LiteralPath $schema5Root -Recurse -Force
  $installedHeadBeforeHeavy = Get-ContainerHead
  $v15 = Publish-Release "controller-v1.5.1" { Add-Content -LiteralPath (Join-Path $publisher '.orchestrator/native-db-admission.py') -Value 'third heavy helper revision' }
  function Assert-HeavyOwnerRefusal($Result) {
    Assert-True ($Result.ExitCode -ne 0 -and ($Result.Output -replace '\s+', ' ') -match 'retained verifier owner') 'heavy release must refuse live replacement/schema6 downgrade/retained owner'
  }
  foreach ($owner in @($liveOwner, '{"schemaVersion":6,"native":{"linux":null}}', '{"schemaVersion":5}', 'unreadable')) {
    [void][IO.Directory]::CreateDirectory($nativeLock)
    [IO.File]::WriteAllText($ownerPath, $owner)
    $heavyRefusal = Invoke-Installer "controller-v1.5.1"
    Assert-HeavyOwnerRefusal $heavyRefusal
    Assert-True ($heavyRefusal.Output -match 'heavy classification: heavy') 'heavy release records shared classification'
    Assert-True ([IO.File]::ReadAllText($ownerPath) -ceq $owner) 'installer preserves exact retained owner, including schema6 downgrade'
    Assert-True ((Get-ContainerHead) -ceq $installedHeadBeforeHeavy) 'a refused heavy install restores the installed head'
    & git -C $container diff --quiet $installedHeadBeforeHeavy -- .orchestrator
    Assert-True ($LASTEXITCODE -eq 0) 'a refused heavy install leaves no candidate bytes in tracked .orchestrator'
  }
  Assert-True ((Get-ContainerHead) -ceq $installedHeadBeforeHeavy) 'all refused heavy installs leave the installed release checked out'
  $record = Get-Content -LiteralPath (Join-Path $destinationRoot "native-db/release.json") -Raw | ConvertFrom-Json
  Assert-True ($record.tag -ceq "controller-v1.4") 'a refused install does not record the refused release'

  $liveSchema4Start = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
  $liveSchema4Owner = [ordered]@{
    schemaVersion = [long]4; lockId = ('e' * 32); owner = 'live@test'; lane = 'live-owner'; branch = $null
    pid = $PID; processStartUtc = $liveSchema4Start; startedUtc = $liveSchema4Start
    gate = 'verify:test'; commandIdentity = ('f' * 64); worktree = (Resolve-Path $container).Path
    head = $installedHeadBeforeHeavy; identityMode = 'immutable-head'; state = 'launching'; childPid = $null; childProcessStartUtc = $null
  }
  $liveSchema4Raw = $liveSchema4Owner | ConvertTo-Json -Compress
  [void][IO.Directory]::CreateDirectory($nativeLock)
  [IO.File]::WriteAllText($ownerPath, $liveSchema4Raw)
  $liveSchema4Refusal = Invoke-Installer 'controller-v1.5.1'
  Assert-HeavyOwnerRefusal $liveSchema4Refusal
  Assert-True ([IO.File]::ReadAllText($ownerPath) -ceq $liveSchema4Raw) 'valid schema-4 live owner is refused without rewriting owner bytes'

  foreach ($schemaVersion in @([double]4.0, '4')) {
    $numericOwner = [ordered]@{
      schemaVersion = $schemaVersion; lockId = ('1' * 32); owner = 'numeric@test'; lane = 'numeric-owner'; branch = $null
      pid = 2147483647; processStartUtc = '2020-01-01T00:00:00Z'; startedUtc = $deadStarted
      gate = 'verify:test'; commandIdentity = ('2' * 64); worktree = (Resolve-Path $container).Path
      head = $installedHeadBeforeHeavy; identityMode = 'immutable-head'; state = 'launching'; childPid = $null; childProcessStartUtc = $null
    }
    $numericRaw = $numericOwner | ConvertTo-Json -Compress
    [void][IO.Directory]::CreateDirectory($nativeLock)
    [IO.File]::WriteAllText($ownerPath, $numericRaw)
    $numericRefusal = Invoke-Installer 'controller-v1.5.1'
    Assert-HeavyOwnerRefusal $numericRefusal
    Assert-True ([IO.File]::ReadAllText($ownerPath) -ceq $numericRaw) "schemaVersion $schemaVersion is refused without reclaiming the owner"
  }

  $installerPath = Join-Path $publisher '.orchestrator/install-controller-skills.ps1'
  $mutantText = $installerText.Replace("if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'verify-lock.d')) {", "if (`$false) {")
  Assert-True ($mutantText -cne $installerText) 'heavy-refusal mutant changes its exact target'
  [void](Publish-Release "controller-v1.4.1" { [IO.File]::WriteAllText($installerPath, $mutantText) })
  $mutantResult = Invoke-Installer "controller-v1.4.1"
  Assert-True ($mutantResult.ExitCode -eq 0) "refusal mutant reaches an install, not an unrelated failure: $($mutantResult.Output)"
  $mutantRejected = $false
  try { Assert-HeavyOwnerRefusal $mutantResult } catch { $mutantRejected = $_.Exception.Message -match '^FAIL: heavy release must refuse' }
  Assert-True $mutantRejected 'heavy-refusal regression assertion kills skipped-refusal mutant'
  [void](Publish-Release "controller-v1.4.2" { [IO.File]::WriteAllText($installerPath, $installerText) })

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

  # --- a skill new to the release inventory ----------------------------------
  # The installed release decides what is new: a directory is created only for a
  # skill the installed release's inventory did not list.
  $lockModule = Join-Path $publisher ".orchestrator/controller-install-lock.psm1"
  $lockText = [IO.File]::ReadAllText($lockModule)
  $withoutShared = [regex]::Replace($lockText, ',\r?\n[ \t]*\[pscustomobject\]\[ordered\]@\{ source = "orchestrator-shared/SKILL\.md"[^\r\n]*\r?\n[ \t]*\[pscustomobject\]\[ordered\]@\{ source = "orchestrator-shared/agents/openai\.yaml"[^\r\n]*', '')
  Assert-True ($withoutShared -cne $lockText -and -not $withoutShared.Contains('orchestrator-shared')) 'fixture removes orchestrator-shared from the earlier inventory'
  $v20 = Publish-Release "controller-v2.0" { [IO.File]::WriteAllText($lockModule, $withoutShared) }
  # Keep this fixture's manual directory removal and new-skill checks unchanged.
  Set-Content -LiteralPath (Join-Path $destinationRoot 'orchestrator-shared/user.txt') -Value 'user file'
  $earlier = Invoke-Installer "controller-v2.0"
  Assert-True ($earlier.ExitCode -eq 0) "release without the shared skill installs: $($earlier.Output)"
  $sharedLive = Join-Path $destinationRoot "orchestrator-shared"
  Remove-Item -LiteralPath $sharedLive -Recurse -Force
  $sharedCodexPath = Join-Path $codexRoot "orchestrator-shared"
  if (Get-Item -LiteralPath $sharedCodexPath -Force -ErrorAction SilentlyContinue) { [IO.Directory]::Delete($sharedCodexPath) }
  $v21 = Publish-Release "controller-v2.1" { [IO.File]::WriteAllText($lockModule, $lockText) }
  $added = Invoke-Installer "controller-v2.1"
  Assert-True ($added.ExitCode -eq 0) "a skill new to the inventory installs: $($added.Output)"
  Assert-Installed "controller-v2.1" $v21
  $sharedCodex = Get-Item -LiteralPath (Join-Path $codexRoot "orchestrator-shared") -Force
  Assert-True ($sharedCodex.LinkType -eq "Junction" -and [IO.Path]::GetFullPath(@($sharedCodex.Target)[0]).TrimEnd('\') -ieq [IO.Path]::GetFullPath($sharedLive).TrimEnd('\')) "the new skill is linked into the Codex skill root"
  $userEntry = Get-Item -LiteralPath $userCodexEntry -Force
  Assert-True (-not $userEntry.LinkType -and (Get-Content -Raw -LiteralPath (Join-Path $userCodexEntry "user.txt")).Trim() -eq "user entry") "an existing Codex entry is left alone"

  # A shipped skill whose directory is missing is still refused.
  $routingLive = Join-Path $destinationRoot "model-routing"
  $routingAside = Join-Path $sandbox "model-routing-aside"
  Move-Item -LiteralPath $routingLive -Destination $routingAside
  [void](Assert-Refused "controller-v2.1" "live skill directory missing")
  Assert-True (-not (Test-Path -LiteralPath $routingLive)) "refusal does not create a shipped skill's directory"
  Move-Item -LiteralPath $routingAside -Destination $routingLive

  # Without a release record nothing proves a skill is new.
  $recordPath = Join-Path $destinationRoot "native-db/release.json"
  $recordAside = Join-Path $sandbox "release-aside.json"
  Move-Item -LiteralPath $recordPath -Destination $recordAside
  Remove-Item -LiteralPath $sharedLive -Recurse -Force
  [void](Assert-Refused "controller-v2.1" "no installed release record")
  Assert-True (-not (Test-Path -LiteralPath $sharedLive)) "refusal without a release record creates no directory"
  Move-Item -LiteralPath $recordAside -Destination $recordPath
  Write-Output 'PASS install-controller-skills new skill directory and Codex link; shipped-skill and no-record refusals; user Codex entry kept'

  # --- dropped destinations -------------------------------------------------
  # These releases and install surfaces are private fixtures, including malicious
  # historical inventories. Never install those inventories as candidates.
  $originalDestinationRoot = $destinationRoot
  $originalCodexRoot = $codexRoot
  $destinationRoot = Join-Path $sandbox 'removal-live'
  $codexRoot = Join-Path $sandbox 'removal-codex'
  Import-Module (Join-Path $PSScriptRoot 'controller-install-lock.psm1') -Force -DisableNameChecking
  $baseInventory = @(Get-ControllerSkillInstallInventory)
  function New-InventoryEntry([string]$Destination, [bool]$PreserveGenerated = $false) {
    [pscustomobject]@{ source = 'model-routing/references/experiments.md'; destination = $Destination; preserveGenerated = $PreserveGenerated; transportText = $true }
  }
  function Publish-InventoryRelease([string]$Tag, [object[]]$Inventory) {
    $json = ConvertTo-Json -InputObject @($Inventory) -Depth 5 -Compress
    $inventoryFunction = "function Get-ControllerSkillInstallInventory {`n  @'`n$json`n'@ | ConvertFrom-Json`n}"
    $start = $lockText.IndexOf('function Get-ControllerSkillInstallInventory {', [StringComparison]::Ordinal)
    $end = $lockText.IndexOf('function Get-ControllerTransportNormalizedBytes {', $start, [StringComparison]::Ordinal)
    Assert-True ($start -ge 0 -and $end -gt $start) 'fixture locates the inventory function'
    Publish-Release $Tag {
      [IO.File]::WriteAllText($lockModule, $lockText.Substring(0, $start) + $inventoryFunction + "`n`n" + $lockText.Substring($end))
      Add-Content -LiteralPath (Join-Path $publisher '.orchestrator/native-db-admission.py') -Value "revision $Tag"
    }
  }
  function Get-InstallSurfaceSnapshot {
    $rows = foreach ($root in @($destinationRoot, $codexRoot)) {
      if (-not (Test-Path -LiteralPath $root)) { continue }
      (@(Get-Item -LiteralPath $root -Force) + @(Get-ChildItem -LiteralPath $root -Recurse -Force)) | Sort-Object FullName | ForEach-Object {
        # Enumeration can cache a parent's pre-junction timestamp on Windows.
        $_.Refresh()
        $content = if ($_.LinkType) { "$($_.LinkType)|$(@($_.Target)[0])" }
          elseif ($_.PSIsContainer) { 'directory' }
          else { [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) }
        "$($_.FullName)|$content|$($_.CreationTimeUtc.Ticks)|$($_.LastWriteTimeUtc.Ticks)"
      }
    }
    $rows -join "`n"
  }
  function Assert-RemovalInstall([string]$Tag) {
    $result = Invoke-Installer $Tag
    Assert-True ($result.ExitCode -eq 0) "removal release installs $($Tag): $($result.Output)"
  }
  function Assert-RemovalRecord([string]$Tag, [string]$Commit) {
    $record = Get-Content -LiteralPath (Join-Path $destinationRoot 'native-db/release.json') -Raw | ConvertFrom-Json
    Assert-True ($record.tag -ceq $Tag -and $record.commit -ceq $Commit) "removal record names $Tag"
    $identity = Get-Content -LiteralPath (Join-Path $destinationRoot 'native-db/identity.json') -Raw | ConvertFrom-Json
    Assert-True ($identity.head -ceq $Commit) 'native identity advances to the candidate'
    $helperHash = (Get-FileHash -LiteralPath (Join-Path $destinationRoot 'native-db/admission.py')).Hash
    Assert-True ($helperHash -ieq $identity.digest -and $helperHash -ceq (Get-FileHash -LiteralPath (Join-Path $container '.orchestrator/native-db-admission.py')).Hash) 'native helper and digest receive the candidate bytes'
  }
  try {
    foreach ($entry in $baseInventory) {
      [void][IO.Directory]::CreateDirectory((Join-Path $destinationRoot (($entry.destination -split '[/\\]')[0])))
    }
    $dropEntries = @(
      (New-InventoryEntry 'removed-skill/nested/old.txt'),
      (New-InventoryEntry 'user-kept-skill/old.txt'),
      (New-InventoryEntry 'model-routing/old.txt'),
      (New-InventoryEntry 'model-routing/generated.json' $true),
      (New-InventoryEntry 'native-db2/old.txt')
    )
    $retainedEntry = New-InventoryEntry 'model-routing/keep.txt'
    # Do not inherit the earlier telemetry fixture's extra trailing newline.
    Set-Content -LiteralPath $sourceMatrix -Value ([ordered]@{ configs = @() } | ConvertTo-Json -Depth 10)
    $v30 = Publish-InventoryRelease 'controller-v3.0' ($baseInventory + $dropEntries + $retainedEntry)
    # First install requires existing skill directories without a release record.
    foreach ($entry in $dropEntries) {
      [void][IO.Directory]::CreateDirectory((Join-Path $destinationRoot (($entry.destination -split '/')[0])))
    }
    Assert-RemovalInstall 'controller-v3.0'
    [IO.File]::WriteAllText((Join-Path $destinationRoot 'user-kept-skill/user.txt'), 'user-owned bytes')
    [void][IO.Directory]::CreateDirectory((Join-Path $destinationRoot 'user-skill'))
    [IO.File]::WriteAllText((Join-Path $destinationRoot 'user-skill/SKILL.md'), 'user skill bytes')
    [IO.File]::WriteAllText((Join-Path $destinationRoot 'native-db/sentinel'), 'native state bytes')
    [IO.File]::WriteAllText((Join-Path $destinationRoot 'model-routing/generated.json'), 'generated live bytes')
    $pathsBeforeDrop = @(foreach ($root in @($destinationRoot, $codexRoot)) { Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object FullName })
    $v31 = Publish-InventoryRelease 'controller-v3.1' ($baseInventory + $retainedEntry)
    Assert-RemovalInstall 'controller-v3.1'
    $pathsAfterDrop = @(foreach ($root in @($destinationRoot, $codexRoot)) { Get-ChildItem -LiteralPath $root -Recurse -Force | ForEach-Object FullName })
    $removedPaths = @($pathsBeforeDrop | Where-Object { $_ -notin $pathsAfterDrop })
    $expectedRemoved = @($dropEntries | ForEach-Object { Join-Path $destinationRoot $_.destination }) + @(
      (Join-Path $destinationRoot 'removed-skill/nested'), (Join-Path $destinationRoot 'removed-skill'),
      (Join-Path $destinationRoot 'native-db2'), (Join-Path $codexRoot 'removed-skill'), (Join-Path $codexRoot 'native-db2')
    )
    Assert-True (@(Compare-Object $expectedRemoved $removedPaths).Count -eq 0) 'only exact declared drops, their empty parents and their matching Codex junctions are removed'
    foreach ($entry in $dropEntries) {
      Assert-True (-not (Test-Path -LiteralPath (Join-Path $destinationRoot $entry.destination))) "dropped destination removed: $($entry.destination)"
    }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $destinationRoot 'removed-skill'))) 'empty dropped skill root is removed'
    Assert-True ($null -eq (Get-Item -LiteralPath (Join-Path $codexRoot 'removed-skill') -Force -ErrorAction SilentlyContinue)) 'matching dropped skill Codex junction is removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $codexRoot 'user-kept-skill')) 'Codex junction remains when a user file keeps the skill root'
    foreach ($sentinel in @(@('user-kept-skill/user.txt', 'user-owned bytes'), @('user-skill/SKILL.md', 'user skill bytes'), @('native-db/sentinel', 'native state bytes'))) {
      Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $destinationRoot $sentinel[0]))) -ceq
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sentinel[1]))) "non-inventory bytes survive: $($sentinel[0])"
    }
    foreach ($entry in @($baseInventory + $retainedEntry)) {
      Assert-True ((Get-FileHash -LiteralPath (Join-Path $destinationRoot $entry.destination)).Hash -ceq
        (Get-FileHash -LiteralPath (Join-Path $container ".orchestrator/controller-skills/$($entry.source)")).Hash) "retained file is byte-identical to B: $($entry.destination)"
    }
    Assert-RemovalRecord 'controller-v3.1' $v31
    Write-Output 'PASS dropped destinations: whole skill and matching Codex junction, single file, preserveGenerated drop, native-db2; non-inventory state and normal native-db updates'

    $renameOld = New-InventoryEntry 'model-routing/rename-old.txt'
    [void](Publish-InventoryRelease 'controller-v3.2' ($baseInventory + $retainedEntry + $renameOld))
    Assert-RemovalInstall 'controller-v3.2'
    $unrelatedBefore = [IO.File]::ReadAllBytes((Join-Path $destinationRoot 'model-routing/keep.txt'))
    $renameHashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $destinationRoot -Recurse -File -Force) {
      if ($file.FullName -eq (Join-Path $destinationRoot $renameOld.destination) -or
          $file.FullName -in @('admission.py', 'identity.json', 'release.json' | ForEach-Object { Join-Path $destinationRoot "native-db/$_" })) { continue }
      $renameHashes[$file.FullName] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    $renameNew = New-InventoryEntry 'model-routing/rename-new.txt'
    $renameNew.source = 'model-routing/references/capability-recalibration.md'
    # The same retained destination differs in both case and separator spelling.
    $spelledRetained = New-InventoryEntry 'MODEL-ROUTING\KEEP.TXT'
    [void](Publish-InventoryRelease 'controller-v3.3' ($baseInventory + $spelledRetained + $renameNew))
    Assert-RemovalInstall 'controller-v3.3'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $destinationRoot $renameOld.destination))) 'renamed old destination is gone'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $destinationRoot $renameNew.destination)).Hash -ceq
      (Get-FileHash -LiteralPath (Join-Path $container ".orchestrator/controller-skills/$($renameNew.source)")).Hash) 'renamed new destination has B bytes'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $destinationRoot 'model-routing/keep.txt'))) -ceq [Convert]::ToBase64String($unrelatedBefore)) 'case/separator-retained destination and unrelated bytes survive'
    foreach ($path in $renameHashes.Keys) {
      Assert-True ((Get-FileHash -LiteralPath $path).Hash -ceq $renameHashes[$path]) "rename leaves unrelated file bytes unchanged: $path"
    }
    Write-Output 'PASS dropped destinations: rename by destination only; ordinal case-insensitive separator-normalized retention'

    $removalRecordPath = Join-Path $destinationRoot 'native-db/release.json'
    $validRecordBytes = [IO.File]::ReadAllBytes($removalRecordPath)
    $record = Get-Content -LiteralPath $removalRecordPath -Raw | ConvertFrom-Json
    $record.commit = '0' * 40
    [IO.File]::WriteAllText($removalRecordPath, ($record | ConvertTo-Json -Compress))
    $before = Get-InstallSurfaceSnapshot
    [void](Assert-Refused 'controller-v3.3' "controller skill install refused: cannot compute dropped files: installed release $('0' * 40) is unreadable")
    Assert-True ((Get-InstallSurfaceSnapshot) -ceq $before) 'unreadable inventory refusal leaves all install surfaces unchanged'
    [IO.File]::WriteAllBytes($removalRecordPath, $validRecordBytes)
    Write-Output 'PASS dropped destinations: unreadable installed commit refuses before any install-surface write'

    $outside = Join-Path $sandbox 'outside'
    [IO.File]::WriteAllText($outside, 'outside bytes')
    $sibling = "$($destinationRoot)2"
    [void][IO.Directory]::CreateDirectory($sibling)
    [IO.File]::WriteAllText((Join-Path $sibling 'old.txt'), 'sibling bytes')
    $junction = Join-Path $destinationRoot 'model-routing/redirect'
    New-Item -ItemType Junction -Path $junction -Target $sibling | Out-Null
    $droppedJunction = Join-Path $destinationRoot 'linked-skill'
    New-Item -ItemType Junction -Path $droppedJunction -Target $sibling | Out-Null
    $unsafeCases = @(
      @('../outside', 'is outside the destination root'),
      @('../removal-live2/old.txt', 'is outside the destination root'),
      @('native-db/sentinel', 'is native-db state'),
      @('model-routing/redirect/old.txt', 'traverses a reparse point'),
      @('linked-skill', 'traverses a reparse point'),
      @('user-skill', 'is a directory, not a file'),
      @('.', 'is outside the destination root'),
      @('model-routing/./keep.txt', 'resolves to a retained destination'),
      @('model-routing//keep.txt', 'resolves to a retained destination'),
      @('model-routing/references', 'resolves to a retained destination')
    )
    for ($i = 0; $i -lt $unsafeCases.Count; $i++) {
      $unsafeDestination, $reason = $unsafeCases[$i]
      $unsafeCommit = Publish-InventoryRelease "controller-v4.$i" ($baseInventory + $spelledRetained + $renameNew + (New-InventoryEntry $unsafeDestination))
      # Make the historical inventory readable without installing its unsafe paths.
      & git -C $container fetch --no-tags --quiet $publisher "refs/tags/controller-v4.$($i):refs/controller-releases/controller-v4.$i"
      Assert-True ($LASTEXITCODE -eq 0) 'unsafe historical release is available to the container'
      $record.commit = $unsafeCommit
      [IO.File]::WriteAllText($removalRecordPath, ($record | ConvertTo-Json -Compress))
      $before = Get-InstallSurfaceSnapshot
      [void](Assert-Refused 'controller-v3.3' "controller skill install refused: cannot compute dropped files: dropped destination $reason")
      $after = Get-InstallSurfaceSnapshot
      $snapshotDelta = @(Compare-Object ($before -split "`n") ($after -split "`n") | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join "`n"
      Assert-True ($after -ceq $before) "unsafe destination refuses without writes: $unsafeDestination; snapshot delta: $snapshotDelta"
      Assert-True ([IO.File]::ReadAllText($outside) -ceq 'outside bytes' -and [IO.File]::ReadAllText((Join-Path $sibling 'old.txt')) -ceq 'sibling bytes') 'outside and sibling bytes survive refusal'
    }
    [IO.File]::WriteAllBytes($removalRecordPath, $validRecordBytes)
    [IO.Directory]::Delete($junction)
    [IO.Directory]::Delete($droppedJunction)
    Write-Output 'PASS dropped destinations: traversal, sibling-prefix, native-db, reparse-point, directory, root and retained-alias refusals preserve all install surfaces'

    $lockedEntry = New-InventoryEntry 'locked-skill/old.txt'
    $userCodexDrop = New-InventoryEntry 'user-codex-skill/old.txt'
    $otherJunctionDrop = New-InventoryEntry 'other-junction-skill/old.txt'
    [void](Publish-InventoryRelease 'controller-v5.0' ($baseInventory + $lockedEntry + $userCodexDrop + $otherJunctionDrop))
    Assert-RemovalInstall 'controller-v5.0'
    $userCodexPath = Join-Path $codexRoot 'user-codex-skill'
    [IO.Directory]::Delete($userCodexPath)
    [void][IO.Directory]::CreateDirectory($userCodexPath)
    [IO.File]::WriteAllText((Join-Path $userCodexPath 'user.txt'), 'own Codex entry')
    $otherJunctionPath = Join-Path $codexRoot 'other-junction-skill'
    [IO.Directory]::Delete($otherJunctionPath)
    New-Item -ItemType Junction -Path $otherJunctionPath -Target $sibling | Out-Null
    $v51 = Publish-InventoryRelease 'controller-v5.1' $baseInventory
    $lockedPath = Join-Path $destinationRoot $lockedEntry.destination
    $oldRecord = [Convert]::ToBase64String([IO.File]::ReadAllBytes($removalRecordPath))
    $copyTarget = Join-Path $destinationRoot 'model-routing/SKILL.md'
    $copyHandle = [IO.File]::Open($copyTarget, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
      $failedCopy = Invoke-Installer 'controller-v5.1'
      Assert-True ($failedCopy.ExitCode -ne 0 -and $failedCopy.Output -match 'SKILL.md') 'copy obstacle fails before removal'
      Assert-True (Test-Path -LiteralPath $lockedPath) 'no dropped file is removed before the entire copy loop succeeds'
      Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($removalRecordPath)) -ceq $oldRecord) 'copy failure keeps exact old release record'
    } finally { $copyHandle.Dispose() }
    $handle = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
      $failedRemoval = Invoke-Installer 'controller-v5.1'
      Assert-True ($failedRemoval.ExitCode -ne 0 -and $failedRemoval.Output -match 'locked-skill[\\/]old\.txt') "locked dropped file fails removal: $($failedRemoval.Output)"
      Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($removalRecordPath)) -ceq $oldRecord) 'failed removal keeps exact old release record'
      $identity = Get-Content -LiteralPath (Join-Path $destinationRoot 'native-db/identity.json') -Raw | ConvertFrom-Json
      Assert-True ($identity.head -ceq $v51) 'failed removal leaves candidate native identity in place'
    } finally { $handle.Dispose() }
    $skipRemoval = $installerText.Replace('Remove-Item -LiteralPath $dropped.Path -Force', '# skipped removal mutant')
    Assert-True ($skipRemoval -cne $installerText) 'post-removal verification mutant changes its exact target'
    [void](Publish-Release 'controller-v5.1.1' { [IO.File]::WriteAllText($installerPath, $skipRemoval) })
    [void](Assert-Refused 'controller-v5.1.1' 'controller skill install verification failed: dropped path remains:')
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($removalRecordPath)) -ceq $oldRecord) 'a leftover path prevents writing the candidate record even when removal reports success'
    Assert-RemovalInstall 'controller-v5.1'
    Assert-True (-not (Test-Path -LiteralPath $lockedPath)) 'same-tag rerun removes the previously locked file'
    Assert-RemovalRecord 'controller-v5.1' $v51
    Assert-True ([IO.File]::ReadAllText((Join-Path $userCodexPath 'user.txt')) -ceq 'own Codex entry') 'dropped skill never removes a user Codex directory'
    $otherJunction = Get-Item -LiteralPath $otherJunctionPath -Force
    Assert-True ($otherJunction.LinkType -eq 'Junction' -and $otherJunction.Target -ieq $sibling) 'dropped skill never removes a Codex junction targeting another directory'
    Write-Output 'PASS dropped destinations: deletion failure keeps old release record; same-tag rerun completes removal; user Codex entry survives'
    Write-Output 'PASS dropped destinations: copy failure precedes removal; leftover-path verification kills skipped-removal mutant; unrelated Codex junction survives'
  } finally {
    $destinationRoot = $originalDestinationRoot
    $codexRoot = $originalCodexRoot
    if ($reusedProcess -and -not $reusedProcess.HasExited) { Stop-Process -Id $reusedProcess.Id -Force -ErrorAction SilentlyContinue }
  }

  Assert-True ((Get-CodexRootSnapshot $realCodexRoot) -ceq $realCodexBefore) "the real Codex skill root is unchanged"
  Write-Output "PASS install-controller-skills release-tag authority, fetch-only container, and install coverage"
} finally {
  Exit-RoutingDataTestScope $routingScope
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
  }
}
