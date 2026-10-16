param([switch]$ProductCensusOnly)
$ErrorActionPreference = "Stop"

$modulePath = Join-Path $PSScriptRoot "fleet-exclusive-admission.psm1"
$ownershipPath = Join-Path $PSScriptRoot "dispatch-ownership.ps1"
Import-Module $modulePath -Force -DisableNameChecking
. $ownershipPath
. (Join-Path $PSScriptRoot 'product-census-test-support.ps1')
Test-ProductCensusFleetAdmission
if ($ProductCensusOnly) { return }

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Denied([scriptblock]$Body, [string]$Expected, [string]$Message) {
  $observed = $null
  try { & $Body | Out-Null } catch { $observed = $_.Exception.Message }
  Assert-True ($null -ne $observed -and $observed -like "*$Expected*") "$Message (observed '$observed')"
}

$controls = [Collections.Generic.List[string]]::new()
function Pass-Control([string]$Name) {
  if ($controls.Contains($Name)) { throw "duplicate named control: $Name" }
  $controls.Add($Name)
  Write-Output "CONTROL|$Name|PASS"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("fleet-exclusive-admission-test-" + [guid]::NewGuid().ToString("N"))
$testRootResolved = [IO.Path]::GetFullPath($testRoot)
$tempResolved = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$container = Join-Path $testRoot "container"
$runtime = Join-Path $container ".orchestrator"
$probeTemp = Join-Path $testRoot "probe-temp"
$lane = Join-Path $container "lane-77"
$head = $null
$branch = "codex/fleet-test"

function Write-JsonNoBom([string]$Path, $Value) {
  [IO.File]::WriteAllText(
    $Path,
    ($Value | ConvertTo-Json -Depth 8 -Compress),
    [Text.UTF8Encoding]::new($false)
  )
}

function New-TestOwner([hashtable]$Extra = @{}) {
  $arguments = @{
    RuntimeRoot = $runtime
    LeaseHolder = "holder-fleet-test-0001"
    Issue = 7203
    Attempt = "7203-fleet-test-a1"
    ControllerRoot = $container
    ControllerHead = ("a" * 40)
    Worktree = $lane
    Branch = $branch
    ClaimedHead = $head
    Gate = "test:scripts"
  }
  foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
  Enter-FleetExclusiveAdmission @arguments
}

function Restore-And-Release($Owner, $Record = $Owner.record) {
  $paths = Get-FleetAdmissionPaths $runtime
  Write-JsonNoBom $paths.record $Record
  $Owner.record = $Record
  Assert-True (Exit-FleetExclusiveAdmission $Owner) "fixture lease releases exactly"
}

function New-DispatchRecord([string]$LaunchId, [string]$Label) {
  $prompt = Join-Path $runtime "dispatch-heavy-verifier-$LaunchId.prompt.txt"
  $transcript = Join-Path $runtime "$Label.jsonl"
  [IO.File]::WriteAllText($prompt, "fixture", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllBytes($transcript, [byte[]]::new(0))
  $record = [ordered]@{
    schemaVersion = 4
    launchId = $LaunchId
    laneRole = "implementation"
    promptPath = [IO.Path]::GetFullPath($prompt)
    reviewIsolationRoot = $null
    launcherPid = $PID
    launcherStartIdentity = Get-DispatchProcessStartIdentity $PID
    recordedAt = [DateTime]::UtcNow.ToString("o")
    state = "started"
    childPid = $PID
    childStartIdentity = Get-DispatchProcessStartIdentity $PID
    worktree = [IO.Path]::GetFullPath($lane).TrimEnd("\", "/")
    lane = "lane-77"
    identityMode = "branch"
    branch = $branch
    head = $head
    label = $Label
    transcriptPath = [IO.Path]::GetFullPath($transcript)
  }
  $path = Join-Path $runtime "dispatch-launch-$LaunchId.json"
  Write-DispatchOwnershipRecord $path $record -CreateNew
  [pscustomobject]@{ path = $path; prompt = $prompt; transcript = $transcript; record = [pscustomobject]$record }
}

function Remove-DispatchFixture($Fixture) {
  Remove-Item -LiteralPath $Fixture.path, $Fixture.prompt, $Fixture.transcript -Force -ErrorAction SilentlyContinue
}

try {
  [IO.Directory]::CreateDirectory($runtime) | Out-Null
  [IO.Directory]::CreateDirectory($probeTemp) | Out-Null
  [IO.Directory]::CreateDirectory($lane) | Out-Null
  & git -C $lane init --initial-branch=$branch --quiet
  & git -C $lane config user.name "Fleet Admission Test"
  & git -C $lane config user.email "fleet-admission@example.invalid"
  [IO.File]::WriteAllText((Join-Path $lane "seed.txt"), "seed", [Text.UTF8Encoding]::new($false))
  & git -C $lane add seed.txt
  & git -C $lane commit --quiet -m seed
  $head = (& git -C $lane rev-parse HEAD | Out-String).Trim().ToLowerInvariant()

  $owner = New-TestOwner
  Assert-True ($owner.record.state -ceq "claiming" -and
    $null -ne (Get-ValidatedFleetAdmissionRecord $runtime)) "new lease publishes one exact claiming owner"
  Assert-Denied { New-TestOwner } "fleet-lease-owner-not-proven-dead" "live owner cannot be stolen"
  Assert-True (Exit-FleetExclusiveAdmission $owner) "live owner releases only its exact record"
  Assert-True (-not (Test-Path -LiteralPath (Get-FleetAdmissionPaths $runtime).directory)) "exact release leaves no directory"
  Pass-Control "live owner denies and exact owner release is residue-free"

  $owner = New-TestOwner
  $dead = New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $false } }
  Assert-True ($dead.record.leaseId -cne $owner.record.leaseId) "dead owner is deleted and reacquired, never adopted"
  Assert-True (Exit-FleetExclusiveAdmission $dead) "reacquired dead-owner lease releases"
  Pass-Control "dead owner is delete-and-reacquire only"

  $owner = New-TestOwner
  Assert-Denied {
    New-TestOwner @{ ProcessStateResolver = { "ambiguous" }; PendingChildResolver = { $false } }
  } "not-proven-dead" "ambiguous owner denies"
  Assert-True (Exit-FleetExclusiveAdmission $owner) "ambiguous fixture cleanup"
  Pass-Control "ambiguous owner denies without age steal"

  $owner = New-TestOwner
  $reused = New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $false } }
  Assert-True ($reused.record.leaseId -cne $owner.record.leaseId) "PID-reused identity is treated as exact owner death"
  Assert-True (Exit-FleetExclusiveAdmission $reused) "PID-reused fixture cleanup"
  Pass-Control "PID-reused holder reclaims only after exact-start mismatch proves death"

  $owner = New-TestOwner
  $owner = Set-FleetExclusiveAdmissionChild $owner $PID (Get-DispatchProcessStartIdentity $PID)
  Assert-Denied {
    New-TestOwner @{ ProcessStateResolver = { "live" }; PendingChildResolver = { $false } }
  } "not-proven-dead" "live holder and child deny"
  $reclaimed = New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $false } }
  Assert-True ($reclaimed.record.leaseId -cne $owner.record.leaseId) "running lease requires both exact identities dead"
  Assert-True (Exit-FleetExclusiveAdmission $reclaimed) "running dead fixture cleanup"
  Pass-Control "running holder and child must both be proven dead"

  $owner = New-TestOwner
  Assert-Denied {
    New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $true } }
  } "not-proven-dead" "possible pending child denies"
  Assert-Denied {
    New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $null } }
  } "not-proven-dead" "unknown pending child denies"
  Assert-True (Exit-FleetExclusiveAdmission $owner) "pending-child fixture cleanup"
  Pass-Control "possible or unknown pending child denies reclamation"

  $paths = Get-FleetAdmissionPaths $runtime
  [IO.Directory]::CreateDirectory($paths.directory) | Out-Null
  [IO.File]::WriteAllText($paths.record, "{malformed", [Text.UTF8Encoding]::new($false))
  Assert-Denied { New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $false } } } "fleet-lease-invalid" "malformed lease denies"
  Remove-Item -LiteralPath $paths.directory -Recurse -Force
  Pass-Control "malformed lease denies"

  [IO.Directory]::CreateDirectory($paths.directory) | Out-Null
  Assert-Denied { New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $false } } } "fleet-lease-invalid" "partial-write lease denies"
  Remove-Item -LiteralPath $paths.directory -Recurse -Force
  Pass-Control "partial-write lease denies"

  $owner = New-TestOwner
  $beforeReclaim = {
    param($Record, $Directory)
    $changed = [ordered]@{}
    foreach ($property in $Record.PSObject.Properties) { $changed[$property.Name] = $property.Value }
    $changed.leaseHolder = "holder-fleet-changed-0002"
    Write-JsonNoBom (Join-Path $Directory "owner.json") $changed
  }
  Assert-Denied {
    New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $false }; BeforeReclaim = $beforeReclaim }
  } "changed after proven-dead validation" "changed-after-validation denies"
  Restore-And-Release $owner
  Pass-Control "changed-after-validation denies and preserves the record"

  $owner = New-TestOwner
  $skewed = [ordered]@{}
  foreach ($property in $owner.record.PSObject.Properties) { $skewed[$property.Name] = $property.Value }
  $skewed.recordedAt = [DateTime]::UtcNow.AddHours(1).ToString("o")
  Write-JsonNoBom $paths.record $skewed
  Assert-Denied { New-TestOwner @{ ProcessStateResolver = { "dead" }; PendingChildResolver = { $false } } } "clock-skew" "future clock skew denies"
  Restore-And-Release $owner
  Pass-Control "clock-skewed record denies without age reasoning"

  $owner = New-TestOwner
  $changed = [ordered]@{}
  foreach ($property in $owner.record.PSObject.Properties) { $changed[$property.Name] = $property.Value }
  $changed.leaseHolder = "holder-fleet-release-0003"
  Write-JsonNoBom $paths.record $changed
  Assert-True (-not (Exit-FleetExclusiveAdmission $owner)) "exact release refuses a changed record"
  Assert-True (Test-Path -LiteralPath $paths.directory) "changed release record is preserved"
  Restore-And-Release $owner
  Pass-Control "exact-record release refuses changed owner bytes"

  $owner = New-TestOwner
  $foreignHost = [ordered]@{}
  foreach ($property in $owner.record.PSObject.Properties) { $foreignHost[$property.Name] = $property.Value }
  $foreignHost.host = "synthetic-foreign-host"
  Write-JsonNoBom $paths.record $foreignHost
  Assert-Denied { Assert-FleetExclusiveLeaseVacantForDispatch $runtime } "foreign-host-fleet-lease" "foreign-host lease denies ordinary dispatch"
  Restore-And-Release $owner
  Pass-Control "foreign-host lease bypass denies"

  $owner = New-TestOwner
  $foreignRoot = [ordered]@{}
  foreach ($property in $owner.record.PSObject.Properties) { $foreignRoot[$property.Name] = $property.Value }
  $foreignRoot.controllerRuntimeRoot = Join-Path $testRoot "foreign-runtime"
  Write-JsonNoBom $paths.record $foreignRoot
  Assert-Denied { Assert-FleetExclusiveLeaseVacantForDispatch $runtime } "fleet-lease-invalid" "foreign runtime lease denies ordinary dispatch"
  Restore-And-Release $owner
  Pass-Control "foreign controller-runtime-root lease bypass denies"

  $capA = Join-Path $runtime "dispatch-launch-00000000-0000-0000-0000-000000000001.json"
  $capB = Join-Path $runtime "dispatch-launch-00000000-0000-0000-0000-000000000002.json"
  [IO.File]::WriteAllText($capA, "{}", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($capB, "{}", [Text.UTF8Encoding]::new($false))
  Assert-Denied {
    Assert-FleetExclusiveLaneCensusVacant $runtime $probeTemp $container -MaxRecords 1
  } "truncated=1" "record cap denies with shipped counter"
  $capCensus = Get-LiveDispatchOwnership $runtime $probeTemp $container -MaxRecords 1
  Assert-True (@($capCensus.health.diagnostics | Where-Object { $_.code -ceq "ownership-record-cap-truncated" }).Count -eq 1) "record cap emits shipped diagnostic"
  Remove-Item -LiteralPath $capA, $capB -Force
  Pass-Control "ownership-record-cap-truncated denies with truncated counter"

  [IO.File]::WriteAllText($capA, "{}", [Text.UTF8Encoding]::new($false))
  Assert-Denied {
    Assert-FleetExclusiveLaneCensusVacant $runtime $probeTemp $container -DeadlineMs 0
  } "truncated=1" "deadline denies with shipped counter"
  $deadlineCensus = Get-LiveDispatchOwnership $runtime $probeTemp $container -DeadlineMs 0
  Assert-True (@($deadlineCensus.health.diagnostics | Where-Object { $_.code -ceq "ownership-deadline-truncated" }).Count -eq 1) "deadline emits shipped diagnostic"
  Remove-Item -LiteralPath $capA -Force
  Pass-Control "ownership-deadline-truncated denies with truncated counter"

  $duplicateA = New-DispatchRecord ([guid]::NewGuid().ToString()) "duplicate-a"
  $duplicateB = New-DispatchRecord ([guid]::NewGuid().ToString()) "duplicate-b"
  $duplicateResolver = {
    param($Runtime, $Temp, $Container, $Cap, $Deadline)
    Get-LiveDispatchOwnership $Runtime $Temp $Container -MaxRecords $Cap -DeadlineMs $Deadline `
      -ProcessStateResolver { "live" } `
      -AttemptStateResolver { New-DispatchAttemptState "active" "fixture" 0 0 0 }
  }
  Assert-Denied {
    Assert-FleetExclusiveLaneCensusVacant $runtime $probeTemp $container -CensusResolver $duplicateResolver
  } "rejected=1" "duplicate owner denies with rejected counter"
  $duplicateCensus = & $duplicateResolver $runtime $probeTemp $container 64 5000
  Assert-True (@($duplicateCensus.health.diagnostics | Where-Object { $_.code -ceq "duplicate-live-ownership" }).Count -eq 1) "duplicate emits shipped diagnostic"
  Remove-DispatchFixture $duplicateA
  Remove-DispatchFixture $duplicateB
  Pass-Control "duplicate-live-ownership denies with rejected counter"

  $moduleSource = [IO.File]::ReadAllText($modulePath)
  $counterBlock = [regex]::Match($moduleSource, '(?ms)\$script:FleetAdmissionCountNames\s*=\s*@\((.*?)\)').Groups[1].Value
  $sourceCounters = @([regex]::Matches($counterBlock, '"([A-Za-z]+)"') | ForEach-Object { $_.Groups[1].Value })
  $expectedCounters = @("candidates","examined","active","legacyLiveOwners","lingeringAttempts","inactive","rejected","probeFailures","truncated")
  Assert-True (@(Compare-Object $expectedCounters $sourceCounters -CaseSensitive).Count -eq 0) "claimant names only the closed shipped counters"
  Assert-True (-not $moduleSource.Contains("duplicateCount", [StringComparison]::OrdinalIgnoreCase)) "claimant invents no duplicate counter"
  Pass-Control "claimant source uses only shipped census counter vocabulary"

  $ordinaryScript = Join-Path $testRoot "race-ordinary.ps1"
  $claimantScript = Join-Path $testRoot "race-claimant.ps1"
  @'
param($ModulePath,$OwnershipPath,$Runtime,$Temp,$Container,$Lane,$Branch,$Head,$Barrier,$Result,$PeerResult)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force -DisableNameChecking
. $OwnershipPath
while(-not(Test-Path -LiteralPath $Barrier)){Start-Sleep -Milliseconds 5}
$id=[guid]::NewGuid().ToString();$label='race-ordinary-'+$id
$prompt=Join-Path $Runtime "dispatch-heavy-verifier-$id.prompt.txt";$transcript=Join-Path $Runtime "$label.jsonl";$path=Join-Path $Runtime "dispatch-launch-$id.json"
[IO.File]::WriteAllText($prompt,'race',[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllBytes($transcript,[byte[]]::new(0))
$record=[ordered]@{schemaVersion=4;launchId=$id;laneRole='implementation';promptPath=[IO.Path]::GetFullPath($prompt);reviewIsolationRoot=$null;launcherPid=$PID;launcherStartIdentity=Get-DispatchProcessStartIdentity $PID;recordedAt=[DateTime]::UtcNow.ToString('o');state='started';childPid=$PID;childStartIdentity=Get-DispatchProcessStartIdentity $PID;worktree=[IO.Path]::GetFullPath($Lane).TrimEnd('\','/');lane=(Split-Path -Leaf $Lane);identityMode='branch';branch=$Branch;head=$Head;label=$label;transcriptPath=[IO.Path]::GetFullPath($transcript)}
try{Write-DispatchOwnershipRecord $path $record -CreateNew;try{Assert-FleetExclusiveLeaseVacantForDispatch $Runtime;Assert-FleetExclusiveLeaseVacantForDispatch $Runtime;[IO.File]::WriteAllText($Result,'PROCEED');$deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not(Test-Path -LiteralPath $PeerResult)-and[DateTime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 5};if(-not(Test-Path -LiteralPath $PeerResult)){throw 'peer outcome missing'}}catch{[IO.File]::WriteAllText($Result,'DENY')}}finally{Remove-DispatchLaunchResources $path ([pscustomobject]$record) $Runtime $Temp|Out-Null;Remove-Item -LiteralPath $transcript -Force -ErrorAction SilentlyContinue}
'@ | Set-Content -LiteralPath $ordinaryScript
  @'
param($ModulePath,$Runtime,$Temp,$Container,$Lane,$Branch,$Head,$Barrier,$Result,$PeerResult)
$ErrorActionPreference='Stop';Import-Module $ModulePath -Force -DisableNameChecking
while(-not(Test-Path -LiteralPath $Barrier)){Start-Sleep -Milliseconds 5}
$owner=$null
try{$owner=Enter-FleetExclusiveAdmission -RuntimeRoot $Runtime -LeaseHolder 'holder-race-0001' -Issue 7203 -Attempt '7203-race-a1' -ControllerRoot $Container -ControllerHead ('a'*40) -Worktree $Lane -Branch $Branch -ClaimedHead $Head -Gate test:scripts;try{Assert-FleetExclusiveLaneCensusVacant $Runtime $Temp $Container|Out-Null;Assert-FleetExclusiveLaneCensusVacant $Runtime $Temp $Container|Out-Null;[IO.File]::WriteAllText($Result,'PROCEED');$deadline=[DateTime]::UtcNow.AddSeconds(10);while(-not(Test-Path -LiteralPath $PeerResult)-and[DateTime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 5};if(-not(Test-Path -LiteralPath $PeerResult)){throw 'peer outcome missing'}}catch{[IO.File]::WriteAllText($Result,'DENY')}}catch{[IO.File]::WriteAllText($Result,'DENY')}finally{if($owner){Exit-FleetExclusiveAdmission $owner|Out-Null}}
'@ | Set-Content -LiteralPath $claimantScript

  $tally = [ordered]@{ exactlyOne = 0; bothDeny = 0; bothProceed = 0 }
  foreach ($trial in 1..12) {
    $barrier = Join-Path $testRoot "race-$trial.barrier"
    $ordinaryResult = Join-Path $testRoot "race-$trial-ordinary.txt"
    $claimantResult = Join-Path $testRoot "race-$trial-claimant.txt"
    $common = @($modulePath,$ownershipPath,$runtime,$probeTemp,$container,$lane,$branch,$head,$barrier,$ordinaryResult,$claimantResult)
    $ordinary = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") -ArgumentList (@("-NoProfile","-NonInteractive","-File",$ordinaryScript)+$common) -WindowStyle Hidden -PassThru
    $claimantArgs = @("-NoProfile","-NonInteractive","-File",$claimantScript,$modulePath,$runtime,$probeTemp,$container,$lane,$branch,$head,$barrier,$claimantResult,$ordinaryResult)
    $claimant = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") -ArgumentList $claimantArgs -WindowStyle Hidden -PassThru
    [IO.File]::WriteAllText($barrier, "go", [Text.UTF8Encoding]::new($false))
    $ordinary.WaitForExit();$claimant.WaitForExit()
    Assert-True ($ordinary.ExitCode -eq 0 -and $claimant.ExitCode -eq 0) "race processes exit cleanly"
    $ordinaryOutcome = [IO.File]::ReadAllText($ordinaryResult)
    $claimantOutcome = [IO.File]::ReadAllText($claimantResult)
    $proceeds = @($ordinaryOutcome,$claimantOutcome | Where-Object { $_ -ceq "PROCEED" }).Count
    if ($proceeds -eq 2) { $tally.bothProceed++ } elseif ($proceeds -eq 1) { $tally.exactlyOne++ } else { $tally.bothDeny++ }
    Assert-True (@(Get-ChildItem -LiteralPath $runtime -Filter "dispatch-launch-*.json" -File).Count -eq 0) "race leaves no lane owner record"
    Assert-True (-not (Test-Path -LiteralPath $paths.directory)) "race leaves no fleet lease"
  }
  Assert-True ($tally.bothProceed -eq 0 -and ($tally.exactlyOne + $tally.bothDeny) -eq 12) "race permits exactly-one or both-deny only"
  Write-Output "RACE_TALLY|trials=12|exactlyOne=$($tally.exactlyOne)|bothDeny=$($tally.bothDeny)|bothProceed=$($tally.bothProceed)"
  Pass-Control "two-process race makes both-proceed impossible"

  Assert-True (-not (Test-Path -LiteralPath $paths.directory)) "suite leaves zero lease residue"
  Assert-True (@(Get-ChildItem -LiteralPath $runtime -Filter "dispatch-launch-*.json" -File).Count -eq 0) "suite leaves zero lane residue"
  Write-Output "RESIDUE|lease=0|lane=0"
  Write-Output "PASS fleet-exclusive admission race, reclamation, census, and exact-owner coverage ($($controls.Count) controls)"
} finally {
  if ((Split-Path -Parent $testRootResolved).TrimEnd("\", "/") -ne $tempResolved -or
      (Split-Path -Leaf $testRootResolved) -notlike "fleet-exclusive-admission-test-*") {
    throw "refusing unsafe fleet admission test cleanup target: $testRootResolved"
  }
  Remove-Item -LiteralPath $testRootResolved -Recurse -Force -ErrorAction SilentlyContinue
}
