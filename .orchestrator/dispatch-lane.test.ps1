param([switch]$ValidatorOnly,[Parameter(DontShow)][switch]$FleetPreClosureOnly,[switch]$NativeBranchOnly,[switch]$ProductCensusOnly,[switch]$CapacityOnly,[switch]$RoutingIssueOnly,[switch]$VerificationPolicyOnly,[string]$GuardRevision='',[ValidateSet('','universal-preamble','local-product-gate')][string]$PolicyMutant='')

$ErrorActionPreference = "Stop"
if ($VerificationPolicyOnly) {
  $source = if ($GuardRevision) { (@(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/dispatch-lane.ps1") -join "`n") } else { [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-lane.ps1')) }
  if($PolicyMutant -eq 'universal-preamble'){$source=$source.Replace("if (`$Role -cne 'implementation' -or `$RoutingRow -eq 13)",'if ($false)')}
  if($PolicyMutant -eq 'local-product-gate'){$source=$source.Replace('product proof is exact-head hosted CI','product proof requires full local verify')}
  $tokens=$null; $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
  $definition=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HeavyVerificationPreamble'},$false))
  if($definition.Count -ne 1){throw 'ASSERTION FAILED: role-specific verification preamble absent'}
  . ([scriptblock]::Create($definition[0].Extent.Text))
  foreach($harness in @('codex','claude')) {
    foreach($role in @('planning','review','implementation')) {
      foreach($row in @(7,13)) {
        $preamble=Get-HeavyVerificationPreamble $role $row 'synthetic-wrapper'
        if($role -ne 'implementation' -or $row -eq 13) {
          if($preamble -notmatch 'cheap focused checks only' -or $preamble -notmatch 'exit 73' -or $preamble -notmatch 'never through ControllerBattery or ControllerPrecursor'){throw "denied prompt failed $harness/$role/$row"}
        } elseif($preamble -notmatch 'product proof is exact-head hosted CI' -or $preamble -notmatch 'scoped refusal never escalates' -or $preamble -notmatch 'Controller authors retain baseline-aware' -or $preamble -notmatch 'unchanged exclusive admission') {throw "author prompt failed $harness/$role/$row"}
        if($preamble -match 'for every full gate|must run.*verify:static'){throw 'universal/full-local product instruction restored'}
        Write-Output "PASS verification policy $harness/$role/row-$row"
      }
    }
  }
  if($source -notmatch 'preamble = \$gatePreamble' -or $source -notmatch '\$gatePreamble \+ \$boundedRetrievalPreamble'){throw 'DryRun/live preamble diverged'}
  $skill=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md')) -replace '\s+',' '
  if($skill -notmatch 'directly as focused tests, never through ControllerBattery, ControllerPrecursor or a battery rerun'){throw 'section 7 reviewer rerun route missing'}
  return
}
if(-not ($ValidatorOnly -or $FleetPreClosureOnly -or $NativeBranchOnly -or $ProductCensusOnly)){ & $PSCommandPath -VerificationPolicyOnly }
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
try {
# Execute the exact routing statement with inert launcher inputs and the real
# logger. No model subprocess, ownership census or live runtime is involved.
$routingRoot=Join-Path ([IO.Path]::GetTempPath()) ('synthetic-8526-routing-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($routingRoot)|Out-Null
try {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'dispatch-lane.ps1'),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw 'launcher parse failed'}
  $calls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text.Contains('-DispatchRoutingSchema $routingSchema')},$true))
  if($calls.Count -ne 1){throw 'routing call must have one canonical owner'}
  $block=$calls[0].Parent
  while($block -isnot [Management.Automation.Language.IfStatementAst]){$block=$block.Parent}
  $routingScriptRoot=$PSScriptRoot
  foreach($role in @('implementation','planning','review')){
    & {
      param($LaneRole)
      $PSScriptRoot=$routingScriptRoot
      $runtimeRoot=$routingRoot;$worktreeResolved=$routingRoot;$admissionLane='synthetic-seat';$admissionBranch='synthetic/8526';$admissionHead='a'*40
      $Label='123-impl-g1';$SemanticAttemptId='123-impl-g1';$stdoutPath=Join-Path $routingRoot "$Label.jsonl"
      $Harness='codex';$Model='gpt-6.1-sol';$Effort='high';$Row=4;$Placement='provisional'
      if($LaneRole -cne 'implementation'){$Row=0;$Placement='';$admissionBranch=''}
      $Issue=908526;$PSBoundParameters['Issue']=$Issue
      $capacity=[pscustomobject]@{forecastBytes=$null;capacityForecastStatus='not-evaluated';capacityDecisionDigest=$null;capacityFlip=$null;capacityShadowFlip=$null;capacityFlipSkip=$null}
      $dispatchRouting=[pscustomobject]@{policyGeneration=1L;registryAuthorityDigest='synthetic';family='sol';slot='explicit';usedLastKnownGood=$false}
      $RoutingStateRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$RoutingLkgPath=$env:CHASE_SETS_ROUTING_LKG_PATH
      $launcherStartedAt=[datetime]::UtcNow.ToString('o')
      & ([scriptblock]::Create("param(`$Issue)`n`$PSScriptRoot='$($routingScriptRoot.Replace("'","''"))';`n"+$block.Extent.Text)) -Issue $Issue
      $recordedAt=[datetime]::UtcNow.ToString('o')
      $rows=@(Get-Content -LiteralPath (Join-Path $routingRoot 'dispatch-log.jsonl')|ConvertFrom-Json -DateKind String)
      $start=[datetime]::Parse($launcherStartedAt).ToUniversalTime();$routeTime=[datetime]::Parse($rows[-1].ts).ToUniversalTime()
      if($routeTime -lt $start.AddTicks(-($start.Ticks % [timespan]::TicksPerMillisecond)) -or $routeTime -ge [datetime]::Parse($recordedAt).ToUniversalTime()){throw 'launch-route-before-ownership-record: real statement timing no longer brackets routing'}
      if($rows[-1].laneRole -cne $LaneRole -or $rows[-1].issue -ne 908526){throw "launch-label-issue-resolution: $LaneRole routing did not preserve explicit Issue over label"}
      if($LaneRole -ceq 'implementation') {
        . (Join-Path $routingScriptRoot 'dispatch-ownership.ps1')
        if($rows[-1].dispatchRoutingSchema -cne 'watchdog-dispatch-routing/v3' -or -not (Test-DispatchRoutingLedgerEvidence $rows[-1])){throw 'launch-label-issue-resolution: capacity v3 issue evidence was not preserved'}
      } elseif($rows[-1].dispatchRoutingSchema -cne 'watchdog-dispatch-routing/v2'){throw 'non-implementation routing schema changed'}
      if($LaneRole -cne 'implementation' -and ($null -ne $rows[-1].placement -or $rows[-1].placementSource -cne 'row-0-explicit' -or $rows[-1].branch -cne '' -or $rows[-1].head -cne $admissionHead)){throw 'launch-label-issue-resolution: absent placement or detached head was fabricated'}
      . (Join-Path $routingScriptRoot 'velocity-metrics.ps1')
      $instant=[datetime]::UtcNow;$stamp=$instant.ToString('o')
      $facts=[pscustomobject]@{complete=$true;gaps=@();platformMilestones=@();merges=@();lastProductMergeAt=$stamp;productPrs=@();issueKinds=[pscustomobject]@{};ownershipStatus='ok';dispatchRows=$rows
        productIssues=@([pscustomobject]@{number=908526;labels=@('kind:product');milestone=[pscustomobject]@{number=148;committed=$true;state='OPEN';track='commerce'};openBlockers=0})
        activeLanes=@([pscustomobject]@{lane='synthetic-seat';label=$Label;laneRole=$LaneRole;launchHead=$admissionHead;worktree=$worktreeResolved;launcherStartedAt=$launcherStartedAt;startedAt=$recordedAt})
        holdState=[pscustomobject]@{schema='merge-hold-state/v1';revision=1;initializedAt=$stamp;records=@()}
        }
      $report=Get-VelocityReport $facts $instant @()
      if(@($report.metrics.flowingProductIssues).Count -ne 1 -or $report.metrics.flowingProductIssues[0] -ne 908526 -or @($report.metrics.readyNotInFlight).Count){throw "launch-issue-no-host-row: role=$LaneRole flowing=$($report.metrics.flowingProductIssues -join ',') idle=$($report.metrics.readyNotInFlight -join ',') gaps=$($report.gaps -join ',')"}
      Write-Output "PASS launch-route-before-ownership-record real launcher role=$LaneRole issue=908526"
    } $role
  }
  Write-Output 'PASS launch-label-issue-resolution real launcher statement -> logger, all roles, explicit Issue wins (synthetic)'
} finally {
  if([IO.Path]::GetFullPath($routingRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $routingRoot -Recurse -Force}
}
if($RoutingIssueOnly){return}
if($CapacityOnly){
  & (Join-Path $PSScriptRoot 'dispatch-routing-data.test.ps1') -Case capacity-override
  & (Join-Path $PSScriptRoot 'dispatch-routing-data.test.ps1') -Case capacity-exemptions
  return
}
if ($ProductCensusOnly -or (-not $ValidatorOnly -and -not $FleetPreClosureOnly -and -not $NativeBranchOnly)) {
  . (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
  . (Join-Path $PSScriptRoot 'product-census-integration-test-support.ps1')
  Test-PlatformSeatNativePublication
  if ($ProductCensusOnly) { return }
}
if ($NativeBranchOnly) {
  . (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')
  Invoke-7963ResumeCarriers @('native-branch')
  return
}

$launcher = Join-Path $PSScriptRoot "dispatch-lane.ps1"
$ownershipHelper = Join-Path $PSScriptRoot "dispatch-ownership.ps1"
$claudeAuditHelper = Join-Path $PSScriptRoot "dispatch-claude-stream-audit.ps1"
$fleetHelper = Join-Path $PSScriptRoot "fleet-exclusive-admission.psm1"
. $ownershipHelper
. $claudeAuditHelper
Import-Module $fleetHelper -Force -DisableNameChecking
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dispatch-lane-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Throws([scriptblock]$Block, [string]$MatchText, [string]$Message) {
  $threw = $false
  try { & $Block | Out-Null } catch { $threw = $true; if ($MatchText -and $_.Exception.Message -notlike "*$MatchText*") { throw "ASSERTION FAILED: $Message — threw wrong error: $($_.Exception.Message)" } }
  if (-not $threw) { throw "ASSERTION FAILED: $Message — did not throw" }
}

function Invoke-DispatchGit([string[]]$Arguments) {
  $output = @(& git -C $worktree @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "fixture git command failed: git $($Arguments -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}

$testRootResolved = [System.IO.Path]::GetFullPath($testRoot)
$tempRootResolved = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd("\", "/")
Assert-True (((Split-Path -Parent $testRootResolved).TrimEnd("\", "/")) -eq $tempRootResolved) "test root is directly under the system temp directory"
Assert-True ((Split-Path -Leaf $testRootResolved) -like "dispatch-lane-test-*") "test root has the expected safety prefix"

$prompt = Join-Path $testRoot "prompt.txt"
Set-Content -LiteralPath $prompt -Value "do the work"
$emptyPrompt = Join-Path $testRoot "empty.txt"
Set-Content -LiteralPath $emptyPrompt -Value $null
$worktree = Join-Path $testRoot "lane-99"
New-Item -ItemType Directory -Path $worktree | Out-Null
$dispatchSeed = Join-Path $worktree "dispatch-seed.txt"
Invoke-DispatchGit @("init", "--initial-branch=codex/dispatch-test") | Out-Null
Invoke-DispatchGit @("config", "user.name", "Dispatch Lane Test") | Out-Null
Invoke-DispatchGit @("config", "user.email", "dispatch-lane-test@example.invalid") | Out-Null
Set-Content -LiteralPath $dispatchSeed -Value "dispatch identity seed"
Invoke-DispatchGit @("add", "--", $dispatchSeed) | Out-Null
Invoke-DispatchGit @("commit", "-m", "dispatch identity seed") | Out-Null
$dispatchBranch = Invoke-DispatchGit @("branch", "--show-current")
$dispatchHead = Invoke-DispatchGit @("rev-parse", "HEAD")
$fakeExe = Join-Path $testRoot "fake-harness.exe"
Set-Content -LiteralPath $fakeExe -Value ""
$fakeShim = Join-Path $testRoot "fake-harness.cmd"
Set-Content -LiteralPath $fakeShim -Value ""
$launcherOutputFiles = @()
$ownershipRoot = Join-Path $testRoot "dispatch-runtime"
$providerTempRoot = Join-Path $testRoot "provider-temp"
New-Item -ItemType Directory -Path $ownershipRoot, $providerTempRoot | Out-Null
$forcedLauncherProcess = $null
$forcedChildPid = $null
$forcedChildStartIdentity = $null
$realGit = Get-Command git -CommandType Application -ErrorAction Stop |
  Select-Object -First 1 -ExpandProperty Source
$admissionMatrixRoot = Join-Path $testRoot "admission-matrix"
New-Item -ItemType Directory -Path $admissionMatrixRoot | Out-Null

function Invoke-AdmissionFixtureGit(
  [string]$Repository,
  [string[]]$Arguments
) {
  $output = @(& $realGit -C $Repository @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "admission fixture git command failed: git $($Arguments -join ' ')`n$($output -join "`n")"
  }
  return ($output -join "`n").Trim()
}

function New-AdmissionMatrixFixture(
  [int]$Row,
  [string]$State
) {
  $caseRoot = Join-Path $admissionMatrixRoot "row-$Row"
  $target = Join-Path $caseRoot "target"
  New-Item -ItemType Directory -Path $target | Out-Null
  $branch = "case-$Row"
  Invoke-AdmissionFixtureGit $target @("init", "--initial-branch=$branch") | Out-Null
  Invoke-AdmissionFixtureGit $target @("config", "user.name", "Admission Matrix") | Out-Null
  Invoke-AdmissionFixtureGit $target @("config", "user.email", "admission-matrix@example.invalid") | Out-Null
  $tracked = Join-Path $target "tracked.txt"
  Set-Content -LiteralPath $tracked -Value "seed"
  Set-Content -LiteralPath (Join-Path $target ".gitignore") -Value "dist/"
  Invoke-AdmissionFixtureGit $target @("add", "--", "tracked.txt", ".gitignore") | Out-Null
  Invoke-AdmissionFixtureGit $target @("commit", "-m", "seed") | Out-Null
  $headA = Invoke-AdmissionFixtureGit $target @("rev-parse", "HEAD")
  $headB = $null
  $foreign = $null
  $gitWrapperRoot = $null

  switch ($Row) {
    1 {
      New-Item -ItemType Directory -Path (Join-Path $target "dist") | Out-Null
      Set-Content -LiteralPath (Join-Path $target "dist/ignored-build-output.txt") -Value "ordinary ignored output"
    }
    2 {
      Invoke-AdmissionFixtureGit $target @("checkout", "-b", "builder-$Row") | Out-Null
      Set-Content -LiteralPath $tracked -Value "moved branch tree"
      Set-Content -LiteralPath (Join-Path $target "new-at-tip.txt") -Value "new at tip"
      Invoke-AdmissionFixtureGit $target @("add", "--", "tracked.txt", "new-at-tip.txt") | Out-Null
      Invoke-AdmissionFixtureGit $target @("commit", "-m", "new branch tree") | Out-Null
      $headB = Invoke-AdmissionFixtureGit $target @("rev-parse", "HEAD")
      Invoke-AdmissionFixtureGit $target @("checkout", $branch) | Out-Null
      Invoke-AdmissionFixtureGit $target @("update-ref", "refs/heads/$branch", $headB, $headA) | Out-Null
    }
    3 {
      Set-Content -LiteralPath $tracked -Value "ordinary staged change"
      Invoke-AdmissionFixtureGit $target @("add", "--", "tracked.txt") | Out-Null
    }
    4 {
      Set-Content -LiteralPath $tracked -Value "ordinary unstaged change"
    }
    5 {
      Invoke-AdmissionFixtureGit $target @("config", "status.showUntrackedFiles", "no") | Out-Null
      Set-Content -LiteralPath (Join-Path $target "untracked.txt") -Value "must still be observed"
    }
    6 {
      $foreign = Join-Path $caseRoot "foreign-holder"
      Invoke-AdmissionFixtureGit $target @("worktree", "add", "--detach", $foreign, $headA) | Out-Null
      Invoke-AdmissionFixtureGit $foreign @("symbolic-ref", "HEAD", "refs/heads/$branch") | Out-Null
    }
    7 {
      Invoke-AdmissionFixtureGit $target @("checkout", "-b", "builder-$Row") | Out-Null
      Invoke-AdmissionFixtureGit $target @("commit", "--allow-empty", "-m", "same-tree alternate tip") | Out-Null
      $headB = Invoke-AdmissionFixtureGit $target @("rev-parse", "HEAD")
      Invoke-AdmissionFixtureGit $target @("checkout", $branch) | Out-Null
      $gitWrapperRoot = Join-Path $caseRoot "git-wrapper"
      New-Item -ItemType Directory -Path $gitWrapperRoot | Out-Null
      $wrapper = @"
@echo off
if /I "%~3"=="rev-parse" if /I "%~4"=="--verify" if /I not "%~5"=="HEAD" (
  echo $headB
  exit /b 0
)
"$realGit" %*
"@
      Set-Content -LiteralPath (Join-Path $gitWrapperRoot "git.cmd") -Value $wrapper
    }
    8 {
      Invoke-AdmissionFixtureGit $target @("checkout", "--detach", $headA) | Out-Null
    }
  }

  [pscustomobject]@{
    Row = $Row
    State = $State
    Worktree = $target
    Branch = $branch
    HeadA = $headA
    HeadB = $headB
    ForeignWorktree = $foreign
    GitWrapperRoot = $gitWrapperRoot
  }
}

function New-AdmissionLauncherSubject(
  [string]$Name,
  [string]$Source
) {
  $subjectRoot = Join-Path $admissionMatrixRoot "subject-$Name"
  $scriptRoot = Join-Path $subjectRoot ".orchestrator"
  New-Item -ItemType Directory -Path (Join-Path $scriptRoot "contracts") -Force | Out-Null
  foreach ($relative in @(
    "dispatch-ownership.ps1",
    "landed-integration-evidence.psm1",
    "integration-dispatch-contract.ps1",
    "dispatch-claude-stream-audit.ps1",
    "fleet-exclusive-admission.psm1",
    "heavy-admission-preload.cjs",
    "invoke-heavy-verifier.ps1",
    "log-event.ps1",
    "orchestration-log-lock.psm1",
    "review-head-contract.psm1",
    "routing-data.ps1"
  )) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $relative) -Destination (Join-Path $scriptRoot $relative)
  }
  foreach ($relative in @("review-v2.md", "planning-repair-v1.md")) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "contracts/$relative") -Destination (Join-Path $scriptRoot "contracts/$relative")
  }
  $launcherPath = Join-Path $scriptRoot "dispatch-lane.ps1"
  [IO.File]::WriteAllText($launcherPath, $Source, [Text.UTF8Encoding]::new($false))
  $fakeHarness = Join-Path $subjectRoot "fake-harness.exe"
  Set-Content -LiteralPath $fakeHarness -Value ""
  [pscustomobject]@{
    Name = $Name
    Root = $subjectRoot
    ScriptRoot = $scriptRoot
    Launcher = $launcherPath
    FakeHarness = $fakeHarness
  }
}

function Invoke-AdmissionMatrixCase(
  [pscustomobject]$Subject,
  [pscustomobject]$Fixture,
  [string]$LaneRole = "review"
) {
  $invocation = [guid]::NewGuid().ToString("N")
  $runtime = Join-Path $Subject.Root "runtime-$($Fixture.Row)-$invocation"
  $providerTemp = Join-Path $Subject.Root "provider-$($Fixture.Row)-$invocation"
  New-Item -ItemType Directory -Path $runtime, $providerTemp | Out-Null
  $label = "matrix-$($Subject.Name)-$($Fixture.Row)-$invocation"
  $oldPath = $env:PATH
  try {
    if ($Fixture.GitWrapperRoot) {
      $env:PATH = "$($Fixture.GitWrapperRoot)$([IO.Path]::PathSeparator)$oldPath"
    }
    try {
      # The immutable baseline predates successor admission. Test its native
      # selector rather than mutating the archived admission control.
      $selection=if($Subject.Name-ceq'base'){'gpt-5.6-sol'}else{'gpt-6.1-sol'}
      $parameters=@{Harness='codex';Model=$selection;Effort='high';LaneRole=$LaneRole;PromptFile=$prompt;Worktree=$Fixture.Worktree;Label=$label;DryRun=$true;ExecutablePath=$Subject.FakeHarness;TestRuntimeRoot=$runtime;TestTempRoot=$providerTemp}
      if((Get-Command $Subject.Launcher).Parameters.ContainsKey('Row')){$parameters.Row=4;$parameters.Placement='provisional'}
      $json = & $Subject.Launcher @parameters
      $plan = ($json -join "`n") | ConvertFrom-Json
      $planHead = if ($plan.heavyAdmission.identityMode -ceq "immutable-head") {
        $plan.heavyAdmission.immutableHead
      } else {
        $plan.heavyAdmission.head
      }
      Assert-True ($planHead -cmatch "^[a-f0-9]{40}$") "admitted matrix row emits a valid plan"
      return [pscustomobject]@{ Outcome = "admitted"; Diagnostic = "none" }
    } catch {
      return [pscustomobject]@{
        Outcome = "refused"
        Diagnostic = $_.Exception.Message
      }
    }
  } finally {
    $env:PATH = $oldPath
  }
}

function Get-AdmissionSha256([byte[]]$Bytes) {
  return ([Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData($Bytes)
  )).ToLowerInvariant()
}

function Get-AdmissionRepositorySnapshot([pscustomobject]$Fixture) {
  $status = @(
    & $realGit --no-optional-locks -C $Fixture.Worktree status --porcelain=v1 --untracked-files=normal 2>&1
  )
  if ($LASTEXITCODE -ne 0) { throw "snapshot status probe failed" }
  $tree = Invoke-AdmissionFixtureGit $Fixture.Worktree @("--no-optional-locks", "write-tree")
  $refs = Invoke-AdmissionFixtureGit $Fixture.Worktree @("show-ref", "--head")
  $worktreeTable = Invoke-AdmissionFixtureGit $Fixture.Worktree @("worktree", "list", "--porcelain")
  $indexProbe = Invoke-AdmissionFixtureGit $Fixture.Worktree @("rev-parse", "--git-path", "index")
  $indexPath = if ([IO.Path]::IsPathRooted($indexProbe)) {
    $indexProbe
  } else {
    Join-Path $Fixture.Worktree $indexProbe
  }
  $paths = @(
    & $realGit -C $Fixture.Worktree ls-files --cached --others --exclude-standard 2>&1
  )
  if ($LASTEXITCODE -ne 0) { throw "snapshot working-tree probe failed" }
  $workingRows = foreach ($path in @($paths | Sort-Object -CaseSensitive)) {
    $file = Join-Path $Fixture.Worktree $path
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      "$path=$(Get-AdmissionSha256 ([IO.File]::ReadAllBytes($file)))"
    } else {
      "$path=<absent>"
    }
  }
  $indexItem = Get-Item -LiteralPath $indexPath -Force
  $indexBytes = [IO.File]::ReadAllBytes($indexPath)
  $utf8 = [Text.UTF8Encoding]::new($false)
  [pscustomobject]@{
    IndexSize = $indexBytes.Length
    IndexSha256 = Get-AdmissionSha256 $indexBytes
    IndexMtimeUtcTicks = $indexItem.LastWriteTimeUtc.Ticks
    IndexTree = $tree
    StatusSha256 = Get-AdmissionSha256 ($utf8.GetBytes(($status -join "`n")))
    StatusText = ($status -join " ; ")
    WorkingTreeSha256 = Get-AdmissionSha256 ($utf8.GetBytes(($workingRows -join "`n")))
    RefsSha256 = Get-AdmissionSha256 ($utf8.GetBytes($refs))
    WorktreeTableSha256 = Get-AdmissionSha256 ($utf8.GetBytes($worktreeTable))
  }
}

function Get-AdmissionPathInventory([string]$Root) {
  return @(
    Get-ChildItem -LiteralPath $Root -Recurse -Force |
      ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\','/')
        if ($_.PSIsContainer) {
          "$relative|directory"
        } else {
          "$relative|file|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)|$(Get-AdmissionSha256 ([IO.File]::ReadAllBytes($_.FullName)))"
        }
      } |
      Sort-Object -CaseSensitive
  ) -join "`n"
}

function Get-AdmissionProcessSet([string]$Needle) {
  return @(
    Get-CimInstance Win32_Process |
      Where-Object {
        ([string]$_.ExecutablePath).Contains($Needle, [StringComparison]::OrdinalIgnoreCase) -or
        ([string]$_.CommandLine).Contains($Needle, [StringComparison]::OrdinalIgnoreCase)
      } |
      Select-Object -ExpandProperty ProcessId |
      Sort-Object
  ) -join ","
}

function Assert-AdmissionRefusalInert(
  [pscustomobject]$Subject,
  [pscustomobject]$Fixture,
  [string]$ExpectedDiagnostic
) {
  $invocation = [guid]::NewGuid().ToString("N")
  $runtime = Join-Path $Subject.Root "inert-runtime-$($Fixture.Row)-$invocation"
  $providerTemp = Join-Path $Subject.Root "inert-provider-$($Fixture.Row)-$invocation"
  New-Item -ItemType Directory -Path $runtime, $providerTemp | Out-Null
  $label = "inert-$($Fixture.Row)-$invocation"
  Set-Content -LiteralPath (Join-Path $runtime "$label.jsonl") -Value "preexisting stdout bytes"
  Set-Content -LiteralPath (Join-Path $runtime "$label.err.log") -Value "preexisting stderr bytes"
  Set-Content -LiteralPath (Join-Path $runtime "dispatch-launch-preexisting.json") -Value "preexisting ownership bytes"
  Set-Content -LiteralPath (Join-Path $runtime "dispatch-heavy-verifier-preexisting.prompt.txt") -Value "preexisting prompt bytes"
  $providerSentinel = Join-Path $providerTemp "preexisting-provider-state"
  New-Item -ItemType Directory -Path $providerSentinel | Out-Null
  Set-Content -LiteralPath (Join-Path $providerSentinel "sentinel.txt") -Value "preexisting provider bytes"
  $before = Get-AdmissionRepositorySnapshot $Fixture
  $runtimeBefore = Get-AdmissionPathInventory $runtime
  $providerBefore = Get-AdmissionPathInventory $providerTemp
  $processBefore = Get-AdmissionProcessSet $label
  $oldPath = $env:PATH
  $diagnostic = $null
  try {
    if ($Fixture.GitWrapperRoot) {
      $env:PATH = "$($Fixture.GitWrapperRoot)$([IO.Path]::PathSeparator)$oldPath"
    }
    try {
      & $Subject.Launcher -Harness codex -Model gpt-6.1-sol -Effort high `
        -LaneRole review -PromptFile $prompt -Worktree $Fixture.Worktree `
        -Label $label -ExecutablePath $Subject.FakeHarness `
        -TestRuntimeRoot $runtime -TestTempRoot $providerTemp | Out-Null
      throw "refusal control unexpectedly admitted"
    } catch {
      $diagnostic = $_.Exception.Message
    }
  } finally {
    $env:PATH = $oldPath
  }
  Assert-True ($diagnostic -ceq $ExpectedDiagnostic) "inert refusal emits the exact expected diagnostic"
  $after = Get-AdmissionRepositorySnapshot $Fixture
  foreach ($property in @(
    "IndexSize",
    "IndexSha256",
    "IndexMtimeUtcTicks",
    "IndexTree",
    "StatusSha256",
    "StatusText",
    "WorkingTreeSha256",
    "RefsSha256",
    "WorktreeTableSha256"
  )) {
    Assert-True ($before.$property -ceq $after.$property) "refusal preserves $property"
  }
  Assert-True ((Get-AdmissionPathInventory $runtime) -ceq $runtimeBefore) "refusal creates no ownership record, prompt transcript, or output file"
  Assert-True ((Get-AdmissionPathInventory $providerTemp) -ceq $providerBefore) "refusal creates no provider isolation directory"
  Assert-True ((Get-AdmissionProcessSet $label) -ceq $processBefore) "refusal creates no surviving harness process"
  Assert-True (@(Get-ChildItem -LiteralPath $runtime -Filter "dispatch-launch-*.json").Count -eq 1) "refusal publishes no ownership record"
  Assert-True (@(Get-ChildItem -LiteralPath $runtime -Filter "dispatch-heavy-verifier-*.prompt.txt").Count -eq 1) "refusal creates no generated prompt"
  Write-Output (
    "INERTNESS|row=$($Fixture.Row)|indexSize=$($before.IndexSize)->$($after.IndexSize)" +
    "|indexSha256=$($before.IndexSha256)->$($after.IndexSha256)" +
    "|indexMtimeUtcTicks=$($before.IndexMtimeUtcTicks)->$($after.IndexMtimeUtcTicks)" +
    "|indexTree=$($before.IndexTree)->$($after.IndexTree)" +
    "|statusSha256=$($before.StatusSha256)->$($after.StatusSha256)" +
    "|workingTreeSha256=$($before.WorkingTreeSha256)->$($after.WorkingTreeSha256)" +
    "|refsSha256=$($before.RefsSha256)->$($after.RefsSha256)" +
    "|worktreeTableSha256=$($before.WorktreeTableSha256)->$($after.WorktreeTableSha256)" +
    "|runtimeInventory=unchanged|providerInventory=unchanged|processSet=$processBefore->$((Get-AdmissionProcessSet $label))"
  )
}

function Invoke-AdmissionContractControls {
  $states = [ordered]@{
    "1" = "clean, uniquely attached, branch tip equals HEAD"
    "2" = "retained older tree after shared branch ref moved externally"
    "3" = "ordinary staged change"
    "4" = "ordinary unstaged change to a tracked file"
    "5" = "untracked not-ignored file with local untracked display suppressed"
    "6" = "clean current branch also held by a second worktree"
    "7" = "branch mode claimed tip does not equal resolved HEAD"
    "8" = "detached clean worktree at exact head, review role"
  }
  $fixtures = @{}
  foreach ($row in $states.Keys) {
    $fixtures[$row] = New-AdmissionMatrixFixture ([int]$row) $states[$row]
  }

  $candidateSource = [IO.File]::ReadAllText($launcher)
  $controllerRoot = Split-Path -Parent $PSScriptRoot
  $baseHead = "20228cf4f2d3e5e0e31a65fac1b0f3b2d4f5f1a5"
  $baseObject = "$baseHead`:.orchestrator/dispatch-lane.ps1"
  $baseLines = @(& $realGit -C $controllerRoot show $baseObject 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "unable to materialize exact base launcher $baseObject"
  }
  $baseSource = ($baseLines -join "`n") + "`n"
  $cleanCall = 'Assert-DispatchAdmissionClean $worktreeResolved # ADMISSION_GUARD_CLEANLINESS'
  $occupancyCall = 'Assert-DispatchAdmissionExclusiveBranchAttachment $admissionIdentityBefore # ADMISSION_GUARD_EXCLUSIVE_BRANCH'
  Assert-True ([regex]::Matches($candidateSource, [regex]::Escape($cleanCall)).Count -eq 1) "cleanliness mutant removes exactly one load-bearing call"
  Assert-True ([regex]::Matches($candidateSource, [regex]::Escape($occupancyCall)).Count -eq 1) "occupancy mutant removes exactly one load-bearing call"

  $subjects = [ordered]@{
    base = New-AdmissionLauncherSubject "base" $baseSource
    candidate = New-AdmissionLauncherSubject "candidate" $candidateSource
    cleanlinessMutant = New-AdmissionLauncherSubject "cleanliness-mutant" (
      $candidateSource.Replace($cleanCall, "# MUTANT_REMOVED_CLEANLINESS_GUARD")
    )
    occupancyMutant = New-AdmissionLauncherSubject "occupancy-mutant" (
      $candidateSource.Replace($occupancyCall, "# MUTANT_REMOVED_EXCLUSIVE_BRANCH_GUARD")
    )
  }

  $unclean = "dispatch-lane: admission refused because the target worktree is not clean (admission-unclean-worktree); commit and relaunch"
  $identity = "dispatch-lane: admission refused because the target HEAD/index/worktree identity is inconsistent (admission-identity-inconsistency)"
  $occupancy = "dispatch-lane: admission refused because branch '$($fixtures["6"].Branch)' is attached to another worktree (admission-branch-occupancy): $([IO.Path]::GetFullPath($fixtures["6"].ForeignWorktree).TrimEnd('\','/'))"
  $candidateExpected = @{
    "1" = [pscustomobject]@{ Outcome = "admitted"; Diagnostic = "none" }
    "2" = [pscustomobject]@{ Outcome = "refused"; Diagnostic = $unclean }
    "3" = [pscustomobject]@{ Outcome = "refused"; Diagnostic = $unclean }
    "4" = [pscustomobject]@{ Outcome = "refused"; Diagnostic = $unclean }
    "5" = [pscustomobject]@{ Outcome = "refused"; Diagnostic = $unclean }
    "6" = [pscustomobject]@{ Outcome = "refused"; Diagnostic = $occupancy }
    "7" = [pscustomobject]@{ Outcome = "refused"; Diagnostic = $identity }
    "8" = [pscustomobject]@{ Outcome = "admitted"; Diagnostic = "none" }
  }
  $observed = @{}
  foreach ($row in $states.Keys) {
    $base = Invoke-AdmissionMatrixCase $subjects.base $fixtures[$row]
    $candidate = Invoke-AdmissionMatrixCase $subjects.candidate $fixtures[$row]
    Assert-True ($base.Outcome -ceq "admitted" -and $base.Diagnostic -ceq "none") "base launcher admits matrix row $row (diagnostic: $($base.Diagnostic))"
    Assert-True (
      $candidate.Outcome -ceq $candidateExpected[$row].Outcome -and
      $candidate.Diagnostic -ceq $candidateExpected[$row].Diagnostic
    ) "candidate launcher produces the exact matrix result for row $row"
    $observed[$row] = [pscustomobject]@{ Base = $base; Candidate = $candidate }
    Write-Output "MATRIX|row=$row|state=$($states[$row])|base=$($base.Outcome)|candidate=$($candidate.Outcome)|candidateDiagnostic=$($candidate.Diagnostic)"
  }
  $ignoredOutput = Join-Path $fixtures["1"].Worktree "dist/ignored-build-output.txt"
  $ignoredStatus = Invoke-AdmissionFixtureGit $fixtures["1"].Worktree @(
    "--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=normal"
  )
  Assert-True ((Test-Path -LiteralPath $ignoredOutput -PathType Leaf) -and
    [string]::IsNullOrEmpty($ignoredStatus)) "ordinary ignored build output remains admissible"
  Write-Output "IGNORED_OUTPUT_FENCE|base=admitted|candidate=admitted|porcelain=empty"

  foreach ($role in @("review", "planning", "implementation")) {
    foreach ($subjectName in @("base", "candidate")) {
      $result = Invoke-AdmissionMatrixCase $subjects[$subjectName] $fixtures["1"] $role
      Assert-True ($result.Outcome -ceq "admitted") "$subjectName clean unique $role fence stays admitted"
      Write-Output "ROLE_FENCE|subject=$subjectName|role=$role|outcome=$($result.Outcome)"
    }
  }
  foreach ($subjectName in @("base", "candidate")) {
    $detached = Invoke-AdmissionMatrixCase $subjects[$subjectName] $fixtures["8"] "review"
    Assert-True ($detached.Outcome -ceq "admitted") "$subjectName detached exact-head review fence stays admitted"
    Write-Output "ROLE_FENCE|subject=$subjectName|role=detached-exact-head-review|outcome=$($detached.Outcome)"
  }

  $cleanlinessMutant = @{}
  $occupancyMutant = @{}
  foreach ($row in $states.Keys) {
    $cleanlinessMutant[$row] = Invoke-AdmissionMatrixCase $subjects.cleanlinessMutant $fixtures[$row]
    $occupancyMutant[$row] = Invoke-AdmissionMatrixCase $subjects.occupancyMutant $fixtures[$row]
    Write-Output "MUTANT_OBSERVED|row=$row|cleanliness=$($cleanlinessMutant[$row].Outcome)|cleanlinessDiagnostic=$($cleanlinessMutant[$row].Diagnostic)|occupancy=$($occupancyMutant[$row].Outcome)|occupancyDiagnostic=$($occupancyMutant[$row].Diagnostic)"
  }
  foreach ($row in @(2, 3, 4, 5)) {
    $rowKey = [string]$row
    Assert-True ($cleanlinessMutant[$rowKey].Outcome -ceq "admitted") "cleanliness mutant turns intended row $row red"
    Assert-True (
      $occupancyMutant[$rowKey].Outcome -ceq "refused" -and
      $occupancyMutant[$rowKey].Diagnostic -ceq $unclean
    ) "occupancy mutant leaves unrelated cleanliness row $row green"
  }
  Assert-True (
    $cleanlinessMutant["6"].Outcome -ceq "refused" -and
    $cleanlinessMutant["6"].Diagnostic -ceq $occupancy
  ) "cleanliness mutant leaves occupancy control green"
  Assert-True (
    $occupancyMutant["6"].Outcome -ceq "admitted"
  ) "occupancy mutant turns only the occupancy row red"
  foreach ($row in @(1, 8)) {
    $rowKey = [string]$row
    Assert-True ($cleanlinessMutant[$rowKey].Outcome -ceq "admitted") "cleanliness mutant preserves fence row $row"
    Assert-True ($occupancyMutant[$rowKey].Outcome -ceq "admitted") "occupancy mutant preserves fence row $row"
  }
  Assert-True (
    $cleanlinessMutant["7"].Outcome -ceq "refused" -and
    $cleanlinessMutant["7"].Diagnostic -ceq $identity
  ) "cleanliness mutant leaves identity control green"
  Assert-True (
    $occupancyMutant["7"].Outcome -ceq "refused" -and
    $occupancyMutant["7"].Diagnostic -ceq $identity
  ) "occupancy mutant leaves identity control green"
  Write-Output "MUTANT|name=cleanliness-guard-removal|turnedRed=rows-2,3,4,5|unrelatedGreen=rows-1,6,7,8"
  Write-Output "MUTANT|name=exclusive-branch-guard-removal|turnedRed=row-6|unrelatedGreen=rows-1,2,3,4,5,7,8"

  Assert-AdmissionRefusalInert $subjects.candidate $fixtures["2"] $unclean
  Assert-AdmissionRefusalInert $subjects.candidate $fixtures["6"] $occupancy
  Assert-AdmissionRefusalInert $subjects.candidate $fixtures["7"] $identity
}

function Invoke-FleetLauncherOrderingControls {
  $candidateSource = [IO.File]::ReadAllText($launcher)
  $publishSeam = 'Write-DispatchOwnershipRecord $ownershipRecordPath $ownershipRecord -CreateNew <# FLEET_ADMISSION_GUARD_LANE_OWNER_PUBLISHED_BEFORE_LEASE #>'
  $inspectSeam = 'Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $runtimeRoot <# FLEET_ADMISSION_GUARD_FLEET_LEASE_INSPECTION #>'
  $rereadSeam = 'Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot $runtimeRoot <# FLEET_ADMISSION_GUARD_FLEET_LEASE_REREAD #>'
  $orderingLine = "  $publishSeam`r`n  if (-not `$integrationResume) {`r`n    $inspectSeam; $rereadSeam"
  foreach ($seam in @($publishSeam,$inspectSeam,$rereadSeam)) {
    Assert-True ([regex]::Matches($candidateSource,[regex]::Escape($seam)).Count-eq1) "launcher fleet ordering seam occurs exactly once: $seam"
  }
  $childScript = Join-Path $testRoot 'fleet-ordering-child.ps1'
  [IO.File]::WriteAllText($childScript,'[IO.File]::WriteAllText($env:FLEET_ORDERING_CHILD_MARKER,"started",[Text.UTF8Encoding]::new($false));exit 0',[Text.UTF8Encoding]::new($false))
  $orderingRunner = Join-Path $testRoot 'fleet-ordering-runner.ps1'
  [IO.File]::WriteAllText($orderingRunner,@'
param($Launcher,$Role,$Prompt,$Worktree,$Label,$Child,$Runtime,$Temp)
& $Launcher -Harness codex -Model gpt-6.1-sol -Effort high -LaneRole $Role `
  -Row 4 -Placement provisional -PromptFile $Prompt -Worktree $Worktree -Label $Label `
  -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') `
  -TestArgumentList @('-NoProfile','-NonInteractive','-File',$Child) `
  -TestRuntimeRoot $Runtime -TestTempRoot $Temp
exit $LASTEXITCODE
'@,[Text.UTF8Encoding]::new($false))

  function Set-OrderingModule([pscustomobject]$Subject,[string]$Source) {
    [IO.File]::WriteAllText((Join-Path $Subject.ScriptRoot 'fleet-exclusive-admission.psm1'),$Source,[Text.UTF8Encoding]::new($false))
  }
  function Invoke-OrderingSubject([pscustomobject]$Subject,[string]$Role='implementation',[switch]$PlantLease) {
    $id=[guid]::NewGuid().ToString('N');$runtime=Join-Path $Subject.Root "ordering-runtime-$id";$temp=Join-Path $Subject.Root "ordering-temp-$id"
    [IO.Directory]::CreateDirectory($runtime)|Out-Null;[IO.Directory]::CreateDirectory($temp)|Out-Null
    if($PlantLease){[IO.Directory]::CreateDirectory((Join-Path $runtime 'fleet-admission.d'))|Out-Null}
    $marker=Join-Path $Subject.Root "ordering-marker-$id.txt";$stdout=Join-Path $Subject.Root "ordering-runner-$id.out";$stderr=Join-Path $Subject.Root "ordering-runner-$id.err"
    $arguments=@('-NoProfile','-NonInteractive','-File',$orderingRunner,$Subject.Launcher,$Role,$prompt,$worktree,"ordering-$id",$childScript,$runtime,$temp)
    $process=Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -Environment @{FLEET_ORDERING_CHILD_MARKER=$marker} -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    [pscustomobject]@{exitCode=$process.ExitCode;started=(Test-Path -LiteralPath $marker);runtime=$runtime;temp=$temp;stdout=$(if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''});stderr=$(if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''})}
  }
  function Clear-OrderingLease([pscustomobject]$Receipt) {
    $lease=Join-Path $Receipt.runtime 'fleet-admission.d'
    if(Test-Path -LiteralPath $lease){Remove-Item -LiteralPath $lease -Recurse -Force}
  }

  $moduleSource=[IO.File]::ReadAllText($fleetHelper)
  $observationLine='  $observation = Get-FleetAdmissionObservation $RuntimeRoot $ExpectedHost'
  Assert-True ([regex]::Matches($moduleSource,[regex]::Escape($observationLine)).Count-eq1) 'ordering fixture instruments one lease observation site'

  $publicationControl=New-AdmissionLauncherSubject 'fleet-publication-control' $candidateSource
  $publicationMutantSource=$candidateSource.Replace($orderingLine,"  if (-not `$integrationResume) {`r`n    Assert-FleetExclusiveLeaseVacantForDispatch -RuntimeRoot `$runtimeRoot <# MUTANT_REMOVED_LANE_OWNER_PUBLICATION_BEFORE_LEASE #>; $publishSeam; $rereadSeam")
  Assert-True ($publicationMutantSource-cne$candidateSource) 'publication mutant reorders exactly the publication/inspection edge'
  $publicationMutant=New-AdmissionLauncherSubject 'fleet-publication-mutant' $publicationMutantSource
  $publicationInstrument=$moduleSource.Replace($observationLine,"  if (@(Get-ChildItem -LiteralPath `$RuntimeRoot -Filter 'dispatch-launch-*.json' -File).Count -eq 0) { throw 'ORDERING_OWNER_NOT_PUBLISHED' }`r`n$observationLine")
  Set-OrderingModule $publicationControl $publicationInstrument
  Set-OrderingModule $publicationMutant $publicationInstrument
  $publicationPositive=Invoke-OrderingSubject $publicationControl
  $publicationNegative=Invoke-OrderingSubject $publicationMutant
  Assert-True ($publicationPositive.exitCode-eq0-and$publicationPositive.started) "positive real non-DryRun carrier reaches owner publication before lease inspection (exit=$($publicationPositive.exitCode); stderr=$($publicationPositive.stderr); stdout=$($publicationPositive.stdout))"
  Assert-True ($publicationNegative.exitCode-ne0-and-not$publicationNegative.started-and$publicationNegative.stderr-like'*ORDERING_OWNER_NOT_PUBLISHED*') 'MUTANT_REMOVED_LANE_OWNER_PUBLICATION_BEFORE_LEASE turns the real carrier red'
  Assert-True (@(Get-ChildItem -LiteralPath $publicationPositive.runtime -Filter 'dispatch-launch-*.json').Count-eq0-and@(Get-ChildItem -LiteralPath $publicationNegative.runtime -Filter 'dispatch-launch-*.json').Count-eq0) 'publication carriers leave zero lane record residue'
  Write-Output 'MUTANT|name=MUTANT_REMOVED_LANE_OWNER_PUBLICATION_BEFORE_LEASE|carrier=non-DryRun|positiveRecordPublication=true|mutantChildStarted=false'

  $rereadControl=New-AdmissionLauncherSubject 'fleet-reread-control' $candidateSource
  $rereadMutant=New-AdmissionLauncherSubject 'fleet-reread-mutant' ($candidateSource.Replace($rereadSeam,'$null = $true <# MUTANT_REMOVED_FLEET_LEASE_REREAD #>'))
  $rereadInstrument=$moduleSource.Replace($observationLine,$observationLine+"`r`n  `$priorFleetOrderingReadCount = Get-Variable -Name FleetOrderingReadCount -Scope Script -ValueOnly -ErrorAction SilentlyContinue`r`n  `$script:FleetOrderingReadCount = 1 + [int]`$priorFleetOrderingReadCount`r`n  if (`$script:FleetOrderingReadCount -eq 1) { [IO.Directory]::CreateDirectory((Join-Path `$RuntimeRoot 'fleet-admission.d')) | Out-Null }")
  Set-OrderingModule $rereadControl $rereadInstrument
  Set-OrderingModule $rereadMutant $rereadInstrument
  $rereadPositive=Invoke-OrderingSubject $rereadControl
  $rereadNegative=Invoke-OrderingSubject $rereadMutant
  Assert-True ($rereadPositive.exitCode-ne0-and-not$rereadPositive.started) 'opposite-side reread catches a lease appearing after first inspection'
  Assert-True ($rereadNegative.exitCode-eq0-and$rereadNegative.started) 'MUTANT_REMOVED_FLEET_LEASE_REREAD turns the real carrier red'
  Clear-OrderingLease $rereadPositive;Clear-OrderingLease $rereadNegative
  Write-Output 'MUTANT|name=MUTANT_REMOVED_FLEET_LEASE_REREAD|carrier=non-DryRun|positiveChildStarted=false|mutantChildStarted=true'

  $noCheckSource=$candidateSource.Replace($inspectSeam,'$null = $true <# MUTANT_REMOVED_FLEET_LEASE_INSPECTION #>').Replace($rereadSeam,'$null = $true <# MUTANT_REMOVED_FLEET_LEASE_REREAD #>')
  $noCheck=New-AdmissionLauncherSubject 'fleet-no-check-bypass' $noCheckSource
  $noCheckReceipt=Invoke-OrderingSubject $noCheck -PlantLease
  Assert-True ($noCheckReceipt.exitCode-eq0-and$noCheckReceipt.started) 'lane launched without the fleet check is an executable bypass shape killed by production guards'
  Clear-OrderingLease $noCheckReceipt
  Write-Output 'BYPASS|shape=lane-launched-without-fleet-check|mutantChildStarted=true|production=denied'

  $roleSubject=New-AdmissionLauncherSubject 'fleet-role-matrix' $candidateSource
  foreach($role in @('review','planning','implementation')){
    $receipt=Invoke-OrderingSubject $roleSubject $role -PlantLease
    Assert-True ($receipt.exitCode-ne0-and-not$receipt.started) "fleet lease denies $role lane before child creation"
    Clear-OrderingLease $receipt
    Write-Output "BYPASS|shape=lane-role-$role|outcome=denied"
  }
}

try {
  # Controller prelaunch uses the public producer and the real inert launcher.
  $controllerSubject=New-AdmissionLauncherSubject 'strict-controller' ([IO.File]::ReadAllText($launcher))
  $controllerLauncher=$controllerSubject.Launcher
  $controllerProducer=Join-Path $controllerSubject.ScriptRoot 'log-event.ps1'
  $controllerRuntime=Join-Path $testRoot 'controller-review-runtime'
  $controllerTemp=Join-Path $testRoot 'controller-review-temp'
  New-Item -ItemType Directory -Path $controllerRuntime,$controllerTemp|Out-Null
  $controllerLog=Join-Path $controllerSubject.ScriptRoot 'dispatch-log.jsonl'
  $controllerLabel='synthetic-strict-review'
  $controllerArgs=@{Harness='codex';Model='gpt-6.1-sol';Effort='high';LaneRole='review';ReviewTarget='controller';ControllerIssue=900002;ControllerHead=$dispatchHead;AuthorAttempt='synthetic-author';ReviewerAttempt='synthetic-reviewer';AuthorModel='gpt-6-astra';ReviewAuthority='governing';Row=11;Placement='provisional';PromptFile=$prompt;Worktree=$worktree;Label=$controllerLabel;ExecutablePath=(Join-Path $PSHOME 'pwsh.exe');TestRuntimeRoot=$controllerRuntime;TestTempRoot=$controllerTemp;TestArgumentList=@('-NoProfile','-NonInteractive','-Command','Write-Output SYNTHETIC_CONTROLLER_STARTED')}
  $strictLogArgs=@{Log='dispatch';Kind='dispatch';Issue=900002;ControllerHead=$dispatchHead;Lane='lane-99';LaneRole='review';Transcript="$controllerLabel.jsonl";Model='gpt-6.1-sol';AuthorModel='gpt-6-astra';Effort='high';Row='11';Placement='provisional';Harness='codex';AuthorAttempt='synthetic-author';ReviewerAttempt='synthetic-reviewer';ReviewAuthority='governing';OutFile=$controllerLog;NoBoard=$true}
  # Plant authority only in the caller-selected output root, never canonical history.
  $noncanonicalLog=Join-Path $controllerRuntime 'dispatch-log.jsonl'
  $noncanonicalLogArgs=$strictLogArgs.Clone();$noncanonicalLogArgs.OutFile=$noncanonicalLog
  & $controllerProducer @noncanonicalLogArgs|Out-Null
  $beforeNames=@(Get-ChildItem -LiteralPath $controllerSubject.Root,$controllerRuntime,$controllerTemp -Recurse -Force|ForEach-Object{$_.FullName})-join"`n"
  $beforeHash=(Get-FileHash $noncanonicalLog).Hash
  Assert-True (-not(Test-Path $controllerLog)) 'noncanonical authority control requires absent canonical history'
  Assert-Throws {&$controllerLauncher @controllerArgs} 'strict controller prelaunch tuple refused: HISTORY_MISSING' 'caller-selected output history must never authorize a controller launch'
  Assert-True ($beforeNames-ceq(@(Get-ChildItem -LiteralPath $controllerSubject.Root,$controllerRuntime,$controllerTemp -Recurse -Force|ForEach-Object{$_.FullName})-join"`n")-and$beforeHash-ceq(Get-FileHash $noncanonicalLog).Hash) 'noncanonical authority refusal created ownership/isolation/transcript/child artifacts or changed history'
  Write-Output 'PASS F2 noncanonical exact tuple with absent canonical history refuses (zero side effects)'
  # Omitting OutFile exercises the copied producer's canonical log identity.
  $strictLogArgs.Remove('OutFile')
  & $controllerProducer @strictLogArgs|Out-Null
  $strictRow=Get-Content -LiteralPath $controllerLog -Raw|ConvertFrom-Json -DateKind String
  foreach($case in @('missing','generic','receipt-only','wrong-issue','wrong-authority','wrong-head','wrong-lane','wrong-author','wrong-reviewer','wrong-transcript','wrong-model','wrong-author-model','wrong-effort','wrong-row','wrong-placement','wrong-harness','conflict','duplicate','terminal','future','malformed')){
    $changed=$strictRow.PSObject.Copy()
    switch($case){
      'missing' {$testRows=@()}
      'generic' {$changed.PSObject.Properties.Remove('controllerReviewSchema')}
      'receipt-only' {$changed.kind='review-complete';$changed.controllerReviewSchema='controller-review-receipt/v1';$changed|Add-Member reviewContract 'review-contract/v2';$changed|Add-Member completeSweep $true;$changed|Add-Member outcome 'PASS';$changed|Add-Member findingIds @();$changed|Add-Member findings ([pscustomobject]@{blocking=0;candidates=0;nonBlocking=0})}
      'wrong-issue' {$changed.issue=900003}
      'wrong-authority' {$changed.reviewAuthority='shadow'}
      'wrong-head' {$changed.controllerHead='f'*40}
      'wrong-lane' {$changed.lane='synthetic-other-lane'}
      'wrong-author' {$changed.authorAttempt='synthetic-other-author'}
      'wrong-reviewer' {$changed.reviewerAttempt='synthetic-other-reviewer'}
      'wrong-transcript' {$changed.transcript='synthetic-other.jsonl'}
      'wrong-model' {$changed.reviewerModel='gpt-6-astra'}
      'wrong-author-model' {$changed.authorModel='gpt-6.1-sol'}
      'wrong-effort' {$changed.effort='medium'}
      'wrong-row' {$changed.row='12'}
      'wrong-placement' {$changed.placement='measured'}
      'wrong-harness' {$changed.harness='claude'}
      'conflict' {$changed.authorAttempt='synthetic-conflict'}
      'terminal' {$changed.kind='review-complete';$changed.controllerReviewSchema='controller-review-receipt/v1';$changed|Add-Member reviewContract 'review-contract/v2';$changed|Add-Member completeSweep $true;$changed|Add-Member outcome 'PASS';$changed|Add-Member findingIds @();$changed|Add-Member findings ([pscustomobject]@{blocking=0;candidates=0;nonBlocking=0})}
      'future' {$changed.ts=[datetimeoffset]::UtcNow.AddDays(1).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")}
      'malformed' {$changed|Add-Member unexpected 'no'}
    }
    $testRows=if($case-eq'missing'){@()}elseif($case-in@('conflict','duplicate','terminal')){@($strictRow,$changed)}else{@($changed)}
    [IO.File]::WriteAllLines($controllerLog,@($testRows|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 10}),[Text.UTF8Encoding]::new($false))
    $beforeNames=@(Get-ChildItem -LiteralPath $controllerRuntime,$controllerTemp -Recurse -Force|ForEach-Object{$_.FullName})-join"`n"
    $beforeHash=(Get-FileHash $controllerLog).Hash
    Assert-Throws {&$controllerLauncher @controllerArgs} 'strict controller prelaunch tuple refused' "controller $case must refuse"
    Assert-True ($beforeNames-ceq(@(Get-ChildItem -LiteralPath $controllerRuntime,$controllerTemp -Recurse -Force|ForEach-Object{$_.FullName})-join"`n")-and$beforeHash-ceq(Get-FileHash $controllerLog).Hash) "controller $case created ownership/isolation/transcript/harness side effects or wrote history"
    Write-Output "PASS controller prelaunch refusal: $case (zero side effects)"
  }
  $duplicateRaw=($strictRow|ConvertTo-Json -Compress).Replace('"authorAttempt":"synthetic-author"','"authorAttempt":"synthetic-ambiguous-first","authorAttempt":"synthetic-author"')
  [IO.File]::WriteAllText($controllerLog,$duplicateRaw+"`n",[Text.UTF8Encoding]::new($false))
  $beforeNames=@(Get-ChildItem -LiteralPath $controllerSubject.Root,$controllerRuntime,$controllerTemp -Recurse -Force|ForEach-Object{$_.FullName})-join"`n"
  $beforeHash=(Get-FileHash $controllerLog).Hash
  Assert-Throws {&$controllerLauncher @controllerArgs} 'strict controller prelaunch tuple refused: HISTORY_MALFORMED' 'duplicate decoded strict tuple property must refuse at raw history boundary'
  Assert-True ($beforeNames-ceq(@(Get-ChildItem -LiteralPath $controllerSubject.Root,$controllerRuntime,$controllerTemp -Recurse -Force|ForEach-Object{$_.FullName})-join"`n")-and$beforeHash-ceq(Get-FileHash $controllerLog).Hash) 'duplicate tuple refusal created ownership/isolation/transcript/child artifacts or changed history'
  Write-Output 'PASS F1 duplicate strict tuple property refuses as HISTORY_MALFORMED (zero side effects)'
  [IO.File]::WriteAllText($controllerLog,'')
  & $controllerProducer @strictLogArgs|Out-Null
  $strictRow=Get-Content -LiteralPath $controllerLog -Raw|ConvertFrom-Json -DateKind String
  $beforeHash=(Get-FileHash $controllerLog).Hash
  & $controllerLauncher @controllerArgs|Out-Null
  $controllerOutput=Get-Content (Join-Path $controllerRuntime "$controllerLabel.jsonl") -Raw
  Assert-True ($LASTEXITCODE-eq0-and[regex]::Matches($controllerOutput,'SYNTHETIC_CONTROLLER_STARTED').Count-eq1) 'one unique canonically produced strict tuple did not start the inert reviewer exactly once'
  Assert-True ($beforeHash-ceq(Get-FileHash $controllerLog).Hash-and-not(Test-Path (Join-Path $controllerSubject.ScriptRoot "$controllerLabel.jsonl"))) 'canonical authority bytes or caller-selected output isolation changed'
  foreach($authority in @('shadow','advisory')){
    $argsForAuthority=$controllerArgs.Clone()
    $argsForAuthority.ReviewAuthority=$authority;$argsForAuthority.Label="synthetic-$authority-review"
    $rowForAuthority=$strictRow.PSObject.Copy()
    $rowForAuthority.reviewAuthority=$authority;$rowForAuthority.transcript="$($argsForAuthority.Label).jsonl"
    $other=$strictRow.PSObject.Copy()
    $other.lane='synthetic-other-lane';$other.transcript='synthetic-other.jsonl';$other.reviewerAttempt='synthetic-other-reviewer'
    [IO.File]::WriteAllLines($controllerLog,@($other,$rowForAuthority|ForEach-Object{$_|ConvertTo-Json -Compress}),[Text.UTF8Encoding]::new($false))
    &$controllerLauncher @argsForAuthority|Out-Null
    Assert-True ($LASTEXITCODE-eq0-and(Get-Content (Join-Path $controllerRuntime "$($argsForAuthority.Label).jsonl") -Raw)-match'SYNTHETIC_CONTROLLER_STARTED') "exact $authority tuple was blocked by independent governing history"
  }
  $productArgs=$controllerArgs.Clone()
  foreach($field in @('ReviewTarget','ControllerIssue','ControllerHead','AuthorAttempt','ReviewerAttempt','AuthorModel','ReviewAuthority')){$productArgs.Remove($field)}
  $productArgs.Label='synthetic-product-review'
  [IO.File]::WriteAllText($controllerLog,'')
  &$controllerLauncher @productArgs|Out-Null
  Assert-True ($LASTEXITCODE-eq0-and(Test-Path (Join-Path $controllerRuntime 'synthetic-product-review.jsonl'))) 'ordinary product review was made dependent on controller dispatch history'
  $metaFixture=New-AdmissionMatrixFixture 97 'controller-source'
  $metaRoot=$metaFixture.Worktree
  # A tracked runtime entrypoint is structural identity, not a lane/title heuristic.
  New-Item -ItemType Directory -Path (Join-Path $metaRoot '.orchestrator')|Out-Null
  Set-Content (Join-Path $metaRoot '.orchestrator/controller-release-battery.ps1') 'synthetic controller source'
  Invoke-AdmissionFixtureGit $metaRoot @('add','.')|Out-Null
  Invoke-AdmissionFixtureGit $metaRoot @('commit','-m','synthetic controller identity')|Out-Null
  $productArgs.Worktree=$metaRoot;$productArgs.Label='synthetic-unmarked-controller'
  Assert-Throws {&$controllerLauncher @productArgs} 'requires -ReviewTarget controller' 'controller source cannot omit the closed review target'
  Write-Output 'PASS controller prelaunch unique exact tuple starts; product review unaffected; structural controller target cannot omit inputs'
  Invoke-FleetLauncherOrderingControls
  # --- direct ownership validator: no launcher, provider, or live runtime -----
  function New-OwnershipFixture(
    [string]$State = "started",
    [string]$LaneRole = "review",
    [int]$LauncherPid = 999999,
    [string]$LauncherStartIdentity = "2000-01-01T00:00:00.0000000Z",
    [AllowNull()][object]$ChildPid = 999998,
    [AllowNull()][object]$ChildStartIdentity = "2000-01-01T00:00:00.0000000Z",
    [int]$SchemaVersion = 4
  ) {
    $launchId = [guid]::NewGuid().ToString()
    $recordPath = Join-Path $ownershipRoot "dispatch-launch-$launchId.json"
    $promptPath = Join-Path $ownershipRoot "dispatch-heavy-verifier-$launchId.prompt.txt"
    $isolationRoot = if ($LaneRole -in @("review", "planning")) { Join-Path $providerTempRoot "chase-sets-$LaneRole-$launchId" } else { $null }
    $recordValues = [ordered]@{
      schemaVersion = $SchemaVersion
      launchId = $launchId
      laneRole = $LaneRole
      promptPath = [IO.Path]::GetFullPath($promptPath)
      reviewIsolationRoot = if ($isolationRoot) { [IO.Path]::GetFullPath($isolationRoot) } else { $null }
      launcherPid = $LauncherPid
      launcherStartIdentity = $LauncherStartIdentity
      recordedAt = [DateTime]::UtcNow.ToString("o")
      state = $State
      childPid = $ChildPid
      childStartIdentity = $ChildStartIdentity
    }
    if ($SchemaVersion -in @(3, 4)) {
      $recordValues.worktree = [IO.Path]::GetFullPath($worktree).TrimEnd("\", "/")
      $recordValues.lane = "lane-99"
      $recordValues.identityMode = "branch"
      $recordValues.branch = $dispatchBranch
      $recordValues.head = $dispatchHead
    }
    if ($SchemaVersion -eq 4) {
      $recordValues.label = "test-$launchId"
      $recordValues.transcriptPath = [IO.Path]::GetFullPath(
        (Join-Path $ownershipRoot "$($recordValues.label).jsonl")
      )
    }
    $record = [pscustomobject]$recordValues
    Set-Content -LiteralPath $promptPath -Value "inert generated prompt"
    if ($isolationRoot) { New-Item -ItemType Directory -Path $isolationRoot | Out-Null }
    Write-DispatchOwnershipRecord $recordPath $record -CreateNew
    return [pscustomobject]@{
      record = $record
      recordPath = $recordPath
      promptPath = $promptPath
      isolationRoot = $isolationRoot
    }
  }

  $deadResolver = { param($ProcessId, $StartIdentity) "dead" }
  $validDead = New-OwnershipFixture
  $validatedDead = Get-ValidatedDispatchOwnershipRecord $validDead.recordPath $ownershipRoot $providerTempRoot
  Assert-True ($null -ne $validatedDead) "exact schema-v3 ownership record validates in isolated roots"
  $deadResult = Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot $deadResolver
  Assert-True ($deadResult.removed -eq 1) "direct validator reclaims one proven-dead exact record"
  Assert-True (-not (Test-Path -LiteralPath $validDead.recordPath)) "direct validator removes the proven-dead record"
  Assert-True (-not (Test-Path -LiteralPath $validDead.promptPath)) "direct validator removes only its exact generated prompt"
  Assert-True (-not (Test-Path -LiteralPath $validDead.isolationRoot)) "direct validator removes only its exact provider-isolation root"

  $currentStart = Get-DispatchProcessStartIdentity $PID
  $liveOwner = New-OwnershipFixture -LauncherPid $PID -LauncherStartIdentity $currentStart
  $liveResult = Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot
  Assert-True ($liveResult.preserved -eq 1) "live exact launcher identity is preserved"
  Assert-True ((Test-Path -LiteralPath $liveOwner.recordPath) -and
      (Test-Path -LiteralPath $liveOwner.promptPath) -and
      (Test-Path -LiteralPath $liveOwner.isolationRoot)) "live launcher keeps its record and resources"

  $orphanChild = New-OwnershipFixture -ChildPid $PID -ChildStartIdentity $currentStart
  $orphanResult = Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot
  Assert-True ($orphanResult.preserved -ge 2) "live orphan child identity is preserved"
  Assert-True ((Test-Path -LiteralPath $orphanChild.recordPath) -and
      (Test-Path -LiteralPath $orphanChild.promptPath) -and
      (Test-Path -LiteralPath $orphanChild.isolationRoot)) "orphan child keeps its record and resources"

  $ambiguousOwner = New-OwnershipFixture
  $ambiguousResolver = { param($ProcessId, $StartIdentity) "ambiguous" }
  Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot $ambiguousResolver | Out-Null
  Assert-True ((Test-Path -LiteralPath $ambiguousOwner.recordPath) -and
      (Test-Path -LiteralPath $ambiguousOwner.promptPath)) "ambiguous process identity fails closed"

  $pendingOwner = New-OwnershipFixture -State "launching" -ChildPid $null -ChildStartIdentity $null
  $pendingResolver = { param($Record) $true }
  Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot $deadResolver $pendingResolver | Out-Null
  Assert-True ((Test-Path -LiteralPath $pendingOwner.recordPath) -and
      (Test-Path -LiteralPath $pendingOwner.promptPath)) "ambiguous launching record with a possible child fails closed"

  $noPendingOwner = New-OwnershipFixture -State "launching" -ChildPid $null -ChildStartIdentity $null
  $noPendingResolver = { param($Record) $false }
  $noPendingResult = Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot $deadResolver $noPendingResolver
  Assert-True (-not (Test-Path -LiteralPath $noPendingOwner.recordPath)) "dead launching record is reclaimed only after absence of a pending child is proven (removed=$($noPendingResult.removed) rejected=$($noPendingResult.rejected) preserved=$($noPendingResult.preserved))"

  $pidReuse = New-OwnershipFixture -LauncherPid $PID -LauncherStartIdentity "2000-01-01T00:00:00.0000000Z" `
    -ChildPid $PID -ChildStartIdentity "2000-01-01T00:00:00.0000000Z"
  Assert-True ((Get-DispatchProcessIdentityState $PID $pidReuse.record.launcherStartIdentity) -eq "dead") "PID reuse with a different start identity is not the recorded owner"
  Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $pidReuse.recordPath)) "PID-reuse mismatch permits only exact stale-record recovery"

  $mismatchedOwner = New-OwnershipFixture
  $originalOwnerRecord = $mismatchedOwner.record
  $replacementOwnerRecord = $originalOwnerRecord.PSObject.Copy()
  $replacementOwnerRecord.recordedAt = [DateTime]::UtcNow.AddSeconds(1).ToString("o")
  Write-DispatchOwnershipRecord $mismatchedOwner.recordPath $replacementOwnerRecord
  Assert-True (-not (Remove-DispatchLaunchResources $mismatchedOwner.recordPath $originalOwnerRecord $ownershipRoot $providerTempRoot)) "cleanup refuses a record changed after validation"
  Assert-True ((Test-Path -LiteralPath $mismatchedOwner.recordPath) -and
      (Test-Path -LiteralPath $mismatchedOwner.promptPath) -and
      (Test-Path -LiteralPath $mismatchedOwner.isolationRoot)) "mismatched owner resources remain untouched"

  $poisoned = New-OwnershipFixture
  $protectedPath = Join-Path $testRoot "must-not-delete.txt"
  Set-Content -LiteralPath $protectedPath -Value "protected"
  $poisoned.record.promptPath = $protectedPath
  Write-DispatchOwnershipRecord $poisoned.recordPath $poisoned.record
  Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot $deadResolver | Out-Null
  Assert-True ((Test-Path -LiteralPath $protectedPath) -and
      (Test-Path -LiteralPath $poisoned.recordPath)) "poisoned path is rejected and never becomes a deletion key"

  $invalidIdentity = New-OwnershipFixture
  $invalidIdentity.record.launcherStartIdentity = "not-a-process-time"
  Write-DispatchOwnershipRecord $invalidIdentity.recordPath $invalidIdentity.record
  Assert-True ($null -eq (Get-ValidatedDispatchOwnershipRecord $invalidIdentity.recordPath $ownershipRoot $providerTempRoot)) "invalid process identity is rejected"

  $invalidSchema = New-OwnershipFixture
  $invalidSchema.record.schemaVersion = 5
  Write-DispatchOwnershipRecord $invalidSchema.recordPath $invalidSchema.record
  Assert-True ($null -eq (Get-ValidatedDispatchOwnershipRecord $invalidSchema.recordPath $ownershipRoot $providerTempRoot)) "unknown ownership schema is rejected"

  $legacyOwner = New-OwnershipFixture -SchemaVersion 2
  Assert-True ($null -ne (Get-ValidatedDispatchOwnershipRecord $legacyOwner.recordPath $ownershipRoot $providerTempRoot)) "legacy schema-v2 ownership remains valid for exact cleanup"
  Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot $deadResolver | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $legacyOwner.recordPath)) "legacy schema-v2 ownership remains reclaimable"

  $implementationOwner = New-OwnershipFixture -LaneRole "implementation"
  Invoke-DispatchOwnershipScavenge $ownershipRoot $providerTempRoot $deadResolver | Out-Null
  Assert-True (-not (Test-Path -LiteralPath $implementationOwner.recordPath)) "implementation record cleanup removes its generated prompt without inventing a provider root"

  if ($ValidatorOnly) {
    Write-Output "PASS dispatch-lane direct ownership validator"
    return
  }
  Invoke-AdmissionContractControls
  Remove-Item -LiteralPath $ownershipRoot -Recurse -Force
  Remove-Item -LiteralPath $providerTempRoot -Recurse -Force
  New-Item -ItemType Directory -Path $ownershipRoot, $providerTempRoot | Out-Null

  # --- lane-record bypass shapes deny through the shipped ownership census ---
  function Assert-LaneRecordDenied([pscustomobject]$Fixture,[string]$Shape) {
    if($Fixture.record.PSObject.Properties['transcriptPath']){
      [IO.File]::WriteAllBytes([string]$Fixture.record.transcriptPath,[byte[]]::new(0))
    }
    $diagnostic=$null
    try{Assert-FleetExclusiveLaneCensusVacant $ownershipRoot $providerTempRoot $testRoot|Out-Null}catch{$diagnostic=$_.Exception.Message}
    Assert-True ($diagnostic-like'ADMISSION_DENIED:*') "$Shape lane-record bypass is denied (observed '$diagnostic')"
    Write-Output "BYPASS|shape=$Shape|outcome=denied|diagnostic=$diagnostic"
    Remove-DispatchLaunchResources $Fixture.recordPath $Fixture.record $ownershipRoot $providerTempRoot|Out-Null
    if($Fixture.record.PSObject.Properties['transcriptPath']){Remove-Item -LiteralPath ([string]$Fixture.record.transcriptPath) -Force -ErrorAction SilentlyContinue}
  }
  $liveStart=Get-DispatchProcessStartIdentity $PID
  $withoutCheck=New-OwnershipFixture -LaneRole implementation -LauncherPid $PID -LauncherStartIdentity $liveStart -ChildPid $PID -ChildStartIdentity $liveStart
  Assert-LaneRecordDenied $withoutCheck 'lane-launched-without-fleet-check'
  $legacyBypass=New-OwnershipFixture -SchemaVersion 2 -LaneRole implementation -LauncherPid $PID -LauncherStartIdentity $liveStart -ChildPid $PID -ChildStartIdentity $liveStart
  Assert-LaneRecordDenied $legacyBypass 'legacy-owner-record'
  $aliasAnchor=Join-Path $testRoot 'alias-anchor';New-Item -ItemType Directory -Path $aliasAnchor|Out-Null
  $aliasBypass=New-OwnershipFixture -LaneRole implementation -LauncherPid $PID -LauncherStartIdentity $liveStart -ChildPid $PID -ChildStartIdentity $liveStart
  $aliasBypass.record.worktree=Join-Path $aliasAnchor '..\lane-99'
  Write-DispatchOwnershipRecord $aliasBypass.recordPath $aliasBypass.record
  Assert-LaneRecordDenied $aliasBypass 'aliased-noncanonical-worktree'
  foreach($role in @('review','planning','implementation')){
    $roleBypass=New-OwnershipFixture -LaneRole $role -LauncherPid $PID -LauncherStartIdentity $liveStart -ChildPid $PID -ChildStartIdentity $liveStart
    Assert-LaneRecordDenied $roleBypass "lane-role-$role"
  }
  Assert-True (@(Get-ChildItem -LiteralPath $ownershipRoot -Filter 'dispatch-launch-*.json').Count-eq0) 'lane bypass matrix leaves zero ownership residue'
  if($FleetPreClosureOnly){Write-Output 'PASS dispatch lane fleet pre-closure focused controls';return}

  # --- normal completion cleans ownership before propagating the child exit ---
  # This provider-free, non-DryRun probe covers the success/failure path that
  # remains distinct from forced-termination recovery.
  $cleanupChildProbe = Join-Path $testRoot "cleanup-child-probe.ps1"
  @'
[ordered]@{
  isolationRoot = $env:APPDATA
} | ConvertTo-Json | Set-Content -LiteralPath $env:DISPATCH_CLEANUP_RESULT
exit [int]$env:DISPATCH_CLEANUP_CHILD_EXIT_CODE
'@ | Set-Content -LiteralPath $cleanupChildProbe
  $cleanupRunner = Join-Path $testRoot "cleanup-runner.ps1"
  @'
& $env:DISPATCH_CLEANUP_LAUNCHER -Harness codex -Model gpt-6.1-sol -Effort high -Issue 908526 `
  -PromptFile $env:DISPATCH_CLEANUP_PROMPT -Worktree $env:DISPATCH_CLEANUP_WORKTREE `
  -Label $env:DISPATCH_CLEANUP_LABEL -ExecutablePath (Join-Path $PSHOME "pwsh.exe") `
  -TestArgumentList @("-NoProfile", "-NonInteractive", "-File", $env:DISPATCH_CLEANUP_CHILD_PROBE) `
  -TestRuntimeRoot $env:DISPATCH_TEST_RUNTIME_ROOT -TestTempRoot $env:DISPATCH_TEST_TEMP_ROOT
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $cleanupRunner
  foreach ($cleanupChildExitCode in @(0, 37)) {
    $cleanupLabel = "test-cleanup-$cleanupChildExitCode-$([guid]::NewGuid())"
    $cleanupResult = Join-Path $testRoot "cleanup-$cleanupChildExitCode.json"
    $launcherOutputFiles += Join-Path $ownershipRoot "$cleanupLabel.jsonl"
    $launcherOutputFiles += Join-Path $ownershipRoot "$cleanupLabel.err.log"
    $cleanupEnvironment = @{
      DISPATCH_CLEANUP_LAUNCHER = $launcher
      DISPATCH_CLEANUP_PROMPT = $prompt
      DISPATCH_CLEANUP_WORKTREE = $worktree
      DISPATCH_CLEANUP_LABEL = $cleanupLabel
      DISPATCH_CLEANUP_CHILD_PROBE = $cleanupChildProbe
      DISPATCH_CLEANUP_RESULT = $cleanupResult
      DISPATCH_CLEANUP_CHILD_EXIT_CODE = $cleanupChildExitCode.ToString()
      DISPATCH_TEST_RUNTIME_ROOT = $ownershipRoot
      DISPATCH_TEST_TEMP_ROOT = $providerTempRoot
    }
    $cleanupRunnerOutput = Join-Path $testRoot "$cleanupLabel-runner.out"
    $cleanupRunnerError = Join-Path $testRoot "$cleanupLabel-runner.err"
    $cleanupProcess = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") `
      -ArgumentList @("-NoProfile", "-NonInteractive", "-File", $cleanupRunner) `
      -Environment $cleanupEnvironment -WindowStyle Hidden -Wait -PassThru `
      -RedirectStandardOutput $cleanupRunnerOutput -RedirectStandardError $cleanupRunnerError
    Assert-True ($cleanupProcess.ExitCode -eq $cleanupChildExitCode) "cleanup probe preserves child exit code $cleanupChildExitCode"
    Assert-True (Test-Path -LiteralPath $cleanupResult) "cleanup child entered: $((Get-Content -LiteralPath $cleanupRunnerError -Tail 12) -join ' ')"
    $cleanupChild = Get-Content -Raw -LiteralPath $cleanupResult | ConvertFrom-Json
    Assert-True (-not (Test-Path -LiteralPath $cleanupChild.isolationRoot)) "review isolation root is cleaned after child exit $cleanupChildExitCode"
    $cleanupRouting=@(Get-Content (Join-Path $ownershipRoot 'dispatch-log.jsonl') | ConvertFrom-Json -DateKind String | Where-Object label -CEQ $cleanupLabel)
    Assert-True ($cleanupRouting.Count -eq 1 -and $cleanupRouting[0].issue -eq 908526 -and $cleanupRouting[0].laneRole -ceq 'review') 'real default-review child records Issue once without a HOST row'
    Assert-True ($null -ne $cleanupRouting[0].PSObject.Properties['placement'] -and $null -eq $cleanupRouting[0].placement -and $cleanupRouting[0].placementSource -ceq 'row-0-explicit' -and $cleanupRouting[0].head -ceq $dispatchHead) 'real default-review child preserves absent placement and exact head'
    $remainingPrompts = @(Get-ChildItem -LiteralPath $ownershipRoot -Filter "dispatch-heavy-verifier-*.prompt.txt" -File)
    Assert-True ($remainingPrompts.Count -eq 0) "injected launch prompt is cleaned after child exit $cleanupChildExitCode"
    $remainingRecords = @(Get-ChildItem -LiteralPath $ownershipRoot -Filter "dispatch-launch-*.json" -File)
    Assert-True ($remainingRecords.Count -eq 0) "ownership record is cleaned after child exit $cleanupChildExitCode"
  }

  $ackChild=Join-Path $testRoot 'start-ack-child.ps1';Set-Content -LiteralPath $ackChild -Value 'exit 0'
  $ackIdentity='a'*64;$ackPath=Join-Path $ownershipRoot "dispatch-start-$ackIdentity.json";$ackLabel="test-start-ack-$([guid]::NewGuid())"
  $launcherOutputFiles+=Join-Path $ownershipRoot "$ackLabel.jsonl";$launcherOutputFiles+=Join-Path $ownershipRoot "$ackLabel.err.log"
  & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -LaneRole implementation -Row 4 -Placement provisional `
    -PromptFile $prompt -Worktree $worktree -Label $ackLabel -ExecutablePath (Join-Path $PSHOME 'pwsh.exe') `
    -TestArgumentList @('-NoProfile','-NonInteractive','-File',$ackChild) -TestRuntimeRoot $ownershipRoot -TestTempRoot $providerTempRoot `
    -StartRequestIdentity $ackIdentity -StartAcknowledgementPath $ackPath
  Assert-True ($LASTEXITCODE-eq0-and(Test-Path $ackPath)) 'exact start acknowledgement was not published by the real launcher'
  $ack=Get-Content -LiteralPath $ackPath -Raw|ConvertFrom-Json -DateKind String
  Assert-True ($ack.schemaVersion-ceq'dispatch-start-ack/v1'-and$ack.requestIdentity-ceq$ackIdentity-and$ack.label-ceq$ackLabel-and$ack.state-ceq'started'-and$ack.row-eq4-and$ack.placement-ceq'provisional'-and$ack.ownershipRecordPath-ceq(Join-Path $ownershipRoot "dispatch-launch-$($ack.launchId).json")) 'real launcher acknowledgement did not bind exact request, launch, owner, route, and started state'

  # --- forced termination: the next inert dispatch reclaims only exact dead ---
  $longChild = Join-Path $testRoot "long-child.ps1"
  @'
Start-Sleep -Seconds 300
'@ | Set-Content -LiteralPath $longChild
  $longRunner = Join-Path $testRoot "long-runner.ps1"
  @'
& $env:DISPATCH_CLEANUP_LAUNCHER -Harness codex -Model gpt-6.1-sol -Effort high `
  -PromptFile $env:DISPATCH_CLEANUP_PROMPT -Worktree $env:DISPATCH_CLEANUP_WORKTREE `
  -Label $env:DISPATCH_LONG_LABEL -ExecutablePath (Join-Path $PSHOME "pwsh.exe") `
  -TestArgumentList @("-NoProfile", "-NonInteractive", "-File", $env:DISPATCH_LONG_CHILD) `
  -TestRuntimeRoot $env:DISPATCH_TEST_RUNTIME_ROOT -TestTempRoot $env:DISPATCH_TEST_TEMP_ROOT
'@ | Set-Content -LiteralPath $longRunner
  function Invoke-InertRecoveryDispatch {
    $recoveryLabel = "test-recovery-$([guid]::NewGuid())"
    $recoveryResult = Join-Path $testRoot "$recoveryLabel.json"
    $script:launcherOutputFiles += Join-Path $ownershipRoot "$recoveryLabel.jsonl"
    $script:launcherOutputFiles += Join-Path $ownershipRoot "$recoveryLabel.err.log"
    $recoveryEnvironment = @{
      DISPATCH_CLEANUP_LAUNCHER = $launcher
      DISPATCH_CLEANUP_PROMPT = $prompt
      DISPATCH_CLEANUP_WORKTREE = $worktree
      DISPATCH_CLEANUP_LABEL = $recoveryLabel
      DISPATCH_CLEANUP_CHILD_PROBE = $cleanupChildProbe
      DISPATCH_CLEANUP_RESULT = $recoveryResult
      DISPATCH_CLEANUP_CHILD_EXIT_CODE = "0"
      DISPATCH_TEST_RUNTIME_ROOT = $ownershipRoot
      DISPATCH_TEST_TEMP_ROOT = $providerTempRoot
    }
    $recoveryProcess = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") `
      -ArgumentList @("-NoProfile", "-NonInteractive", "-File", $cleanupRunner) `
      -Environment $recoveryEnvironment -WindowStyle Hidden -Wait -PassThru
    Assert-True ($recoveryProcess.ExitCode -eq 0) "next inert recovery dispatch exits successfully"
  }

  $longLabel = "test-forced-$([guid]::NewGuid())"
  $launcherOutputFiles += Join-Path $ownershipRoot "$longLabel.jsonl"
  $launcherOutputFiles += Join-Path $ownershipRoot "$longLabel.err.log"
  $longEnvironment = @{
    DISPATCH_CLEANUP_LAUNCHER = $launcher
    DISPATCH_CLEANUP_PROMPT = $prompt
    DISPATCH_CLEANUP_WORKTREE = $worktree
    DISPATCH_LONG_LABEL = $longLabel
    DISPATCH_LONG_CHILD = $longChild
    DISPATCH_TEST_RUNTIME_ROOT = $ownershipRoot
    DISPATCH_TEST_TEMP_ROOT = $providerTempRoot
  }
  $forcedLauncherProcess = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") `
    -ArgumentList @("-NoProfile", "-NonInteractive", "-File", $longRunner) `
    -Environment $longEnvironment -WindowStyle Hidden -PassThru
  $recordDeadline = [DateTime]::UtcNow.AddSeconds(15)
  do {
    Start-Sleep -Milliseconds 100
    $forcedRecords = @(Get-ChildItem -LiteralPath $ownershipRoot -Filter "dispatch-launch-*.json" -File)
    $forcedRecord = if ($forcedRecords.Count -eq 1) {
      Get-ValidatedDispatchOwnershipRecord $forcedRecords[0].FullName $ownershipRoot $providerTempRoot
    } else {
      $null
    }
  } while (($null -eq $forcedRecord -or $forcedRecord.state -ne "started") -and [DateTime]::UtcNow -lt $recordDeadline)
  Assert-True ($null -ne $forcedRecord -and $forcedRecord.state -eq "started") "long-lived inert launch publishes an exact child identity"
  Assert-True ($forcedRecord.schemaVersion -eq 4 -and
    $forcedRecord.worktree -eq [IO.Path]::GetFullPath($worktree).TrimEnd("\", "/") -and
    $forcedRecord.lane -eq "lane-99" -and
    $forcedRecord.identityMode -eq "branch" -and
    $forcedRecord.branch -eq $dispatchBranch -and
    $forcedRecord.head -eq $dispatchHead -and
    $forcedRecord.label -eq $longLabel -and
    $forcedRecord.transcriptPath -eq [IO.Path]::GetFullPath(
      (Join-Path $ownershipRoot "$longLabel.jsonl")
    )) "live ownership publishes exact worktree, branch, HEAD, label, and transcript binding"
  $watchdogSpecPath = Join-Path $ownershipRoot "watchdog-lane-$longLabel.json"
  $watchdogSpec = Get-Content -LiteralPath $watchdogSpecPath -Raw | ConvertFrom-Json -DateKind String
  Assert-True ($watchdogSpec.schemaVersion -ceq 'watchdog-lane/v2' -and
    $watchdogSpec.state -ceq 'running' -and $watchdogSpec.launchId -ceq $forcedRecord.launchId -and
    $watchdogSpec.childPid -eq $forcedRecord.childPid -and
    $watchdogSpec.childStartIdentity -ceq $forcedRecord.childStartIdentity -and
    $watchdogSpec.partialReportPath -ceq $forcedRecord.transcriptPath -and
    $watchdogSpec.attemptId -ceq $longLabel -and $watchdogSpec.relaunchCount -eq 0) `
    "canonical dispatch entrypoint did not publish exact watchdog resume provenance"
  $forcedRecordPath = $forcedRecords[0].FullName
  $forcedChildPid = [int]$forcedRecord.childPid
  $forcedChildStartIdentity = [string]$forcedRecord.childStartIdentity
  Assert-True ((Test-Path -LiteralPath $forcedRecord.promptPath) -and
      (Test-Path -LiteralPath $forcedRecord.reviewIsolationRoot)) "forced-launch fixture owns its exact resources"

  Invoke-InertRecoveryDispatch
  Assert-True ((Test-Path -LiteralPath $forcedRecordPath) -and
      (Test-Path -LiteralPath $forcedRecord.promptPath) -and
      (Test-Path -LiteralPath $forcedRecord.reviewIsolationRoot)) "next inert dispatch refuses cleanup while launcher and child identities are live"

  Stop-Process -Id $forcedLauncherProcess.Id -Force
  $forcedLauncherProcess.WaitForExit()
  if ((Get-DispatchProcessIdentityState $forcedChildPid $forcedChildStartIdentity) -eq "live") {
    Stop-Process -Id $forcedChildPid -Force
  }
  $processDeadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 50
    $launcherGone = @(Get-Process -Id $forcedRecord.launcherPid -ErrorAction SilentlyContinue).Count -eq 0
    $childGone = @(Get-Process -Id $forcedChildPid -ErrorAction SilentlyContinue).Count -eq 0
  } while ((-not $launcherGone -or -not $childGone) -and [DateTime]::UtcNow -lt $processDeadline)
  Assert-True ($launcherGone -and $childGone) "forced-launch record has absent recorded launcher and child PIDs"

  Invoke-InertRecoveryDispatch
  Assert-True (-not (Test-Path -LiteralPath $forcedRecordPath)) "next real inert dispatch reclaims terminated launch record"
  Assert-True (-not (Test-Path -LiteralPath $forcedRecord.promptPath)) "next real inert dispatch reclaims the terminated launch prompt"
  Assert-True (-not (Test-Path -LiteralPath $forcedRecord.reviewIsolationRoot)) "next real inert dispatch reclaims the terminated provider-isolation root"

  # --- omission is least-authority; implementation requires explicit opt-in --
  $codex = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high `
    -PromptFile $prompt -Worktree $worktree -Label "test-codex-$([guid]::NewGuid())" `
    -DryRun -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True ($codex.laneRole -eq "review") "omitted lane role defaults to review without prompting"
  Assert-True ($codex.environmentPolicy.mode -eq "digitalocean-review-isolation") "omitted lane role selects review isolation"
  Assert-True (@($codex.environmentPolicy.removedVariables) -contains "DIGITALOCEAN_ACCESS_TOKEN") "omitted lane role removes the live DigitalOcean token"
  Assert-True ($codex.environmentPolicy.kubeconfigPolicy -eq "nonexistent-path-inside-isolated-temp-root") "omitted lane role disables kubectl's default kubeconfig fallback"
  Assert-True ($codex.reviewContract.version -eq "review-contract/v2" -and
    $codex.reviewContract.injected) "review role injects the versioned repair-ready review contract"

  $implementation = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high `
    -LaneRole implementation -Row 4 -Placement provisional -PromptFile $prompt -Worktree $worktree `
    -Label "test-implementation-$([guid]::NewGuid())" -DryRun `
    -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True ($implementation.laneRole -eq "implementation") "implementation role can be selected explicitly"
  Assert-True ($implementation.environmentPolicy.mode -eq "inherit") "explicit implementation role inherits the environment"
  Assert-True (@($implementation.environmentPolicy.removedVariables).Count -eq 0) "explicit implementation mode removes no environment variables"
  Assert-True ($implementation.environmentPolicy.kubeconfigPolicy -eq "inherit") "explicit implementation role preserves kubeconfig behavior"

  # --- codex plan encodes native-exe, finite stdin, effort config, lane cwd ---
  Assert-True ($codex.arguments[0] -eq "exec") "codex launches exec mode"
  Assert-True (@($codex.arguments) -contains "gpt-6.1-sol") "codex model threads through"
  Assert-True (@($codex.arguments) -contains "model_reasoning_effort=high") "codex effort threads through as config"
  $appsFlagIndex = [Array]::IndexOf(@($codex.arguments), "features.apps=false")
  Assert-True ($appsFlagIndex -gt 0 -and $codex.arguments[$appsFlagIndex - 1] -eq "-c") "Codex review lanes disable only built-in Apps MCP through a process-local override"
  Assert-True (@($implementation.arguments) -contains "features.apps=false") "Codex implementation lanes also skip unused Apps MCP"
  $providerIndex = [Array]::IndexOf(@($codex.arguments), "model_provider=account_pool")
  Assert-True ($providerIndex -gt 0 -and $codex.arguments[$providerIndex - 1] -eq "-c") "Codex review lanes pin the account pool provider through a process-local override"
  Assert-True (@($implementation.arguments) -contains "model_provider=account_pool") "Codex implementation lanes also pin the account pool provider"
  Assert-True (@($codex.arguments) -contains "--dangerously-bypass-approvals-and-sandbox") "codex bypass flag present"
  Assert-True (@($codex.arguments)[-1] -eq "-") "codex reads the prompt from stdin"
  Assert-True ($codex.stdin -eq $prompt) "codex stdin is the finite prompt file (EOF gotcha)"
  Assert-True ($codex.heavyVerifier.entrypoint -eq (Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1")) "launcher advertises the sole heavy-verifier entrypoint"
  Assert-True (@($codex.heavyVerifier.supportedGates) -contains "verify:static") "launcher enumerates full static verification as guarded"
  Assert-True ($codex.heavyAdmission.mode -eq "node-preload-and-pnpm-script-shell-existing-lock") "launcher declares machine-enforced direct-command admission through the existing lock"
  Assert-True ($codex.heavyAdmission.identityMode -ceq "branch" -and
    $codex.heavyAdmission.branch -ceq $dispatchBranch -and
    $codex.heavyAdmission.head -ceq $dispatchHead) "launcher plan captures the exact dispatch-time branch and HEAD"
  Assert-True (@($codex.heavyAdmission.guardedShapes) -contains "Playwright test entrypoints") "launcher inventory includes direct Playwright"
  Assert-True (@($codex.heavyAdmission.guardedShapes) -contains "full Vitest runs without explicit test files") "launcher inventory distinguishes full from focused Vitest"
  Assert-True (@($codex.heavyAdmission.unguardedShapes) -contains "focused Vitest files") "launcher preserves focused Vitest outside the slot"
  Assert-True ($codex.heavyAdmission.refusalExitCode -eq 73) "launcher advertises the bounded admission refusal code"
  Assert-True ($codex.workingDirectory -eq $worktree) "codex runs in the lane worktree"

  # A detached review is explicitly admitted by immutable HEAD. Mutable roles
  # still require a branch identity.
  Invoke-DispatchGit @("checkout", "--detach", $dispatchHead) | Out-Null
  try {
    $detachedReview = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high `
      -LaneRole review -PromptFile $prompt -Worktree $worktree `
      -Label "test-detached-review-$([guid]::NewGuid())" -DryRun `
      -ExecutablePath $fakeExe | ConvertFrom-Json
    Assert-True ($detachedReview.heavyAdmission.identityMode -ceq "immutable-head" -and
      $detachedReview.heavyAdmission.immutableHead -ceq $dispatchHead -and
      $null -eq $detachedReview.heavyAdmission.branch) "detached review is admitted only by its exact immutable HEAD"
    Assert-Throws {
      & $launcher -Harness codex -Model gpt-6.1-sol -Effort high `
        -LaneRole implementation -Row 4 -Placement provisional -PromptFile $prompt -Worktree $worktree `
        -Label "test-detached-implementation-$([guid]::NewGuid())" -DryRun `
        -ExecutablePath $fakeExe
    } "detached worktrees are admitted only" "detached implementation cannot borrow review admission"
  } finally {
    Invoke-DispatchGit @("checkout", $dispatchBranch) | Out-Null
  }

  # --- Claude plan carries exact permission and background-tool guards --------
  $claude = & $launcher -Harness claude -Model claude-sonnet-5-5 -Effort medium -Placement override-Todd `
    -PromptFile $prompt -Worktree $worktree -Label "test-claude-$([guid]::NewGuid())" `
    -DryRun -ExecutablePath $fakeExe | ConvertFrom-Json
  $expectedClaudeArguments = @(
    "--model", "claude-sonnet-5-5",
    "--effort", "medium",
    "--print",
    "--output-format", "stream-json",
    "--verbose",
    "--dangerously-skip-permissions",
    "--disallowedTools",
    "Monitor", "ScheduleWakeup", "CronCreate", "CronDelete", "CronList"
  )
  Assert-True (
    (@($claude.arguments) | ConvertTo-Json -Compress) -ceq
    ($expectedClaudeArguments | ConvertTo-Json -Compress)
  ) "Claude launch arguments exactly deny only the supported session-scoped orchestration tools"
  Assert-True ($claude.stdin -eq $prompt) "claude prompt arrives via stdin, never argument quoting"
  Assert-True ($claude.laneRole -ceq 'review') 'Sonnet Row 0 retains the existing review envelope, not implementation routing'
  $sonnetPlanning = & $launcher -Harness claude -Model claude-sonnet-5-5 -Effort medium -Placement override-Todd `
    -LaneRole planning -PromptFile $prompt -Worktree $worktree -Label "test-sonnet-planning-$([guid]::NewGuid())" `
    -DryRun -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True ($sonnetPlanning.laneRole -ceq 'planning') 'Sonnet Row 0 planning envelope is legal'
  foreach ($reviewRow in @(11,12)) {
    Assert-Throws {
      & $launcher -Harness claude -Model claude-sonnet-5-5 -Effort medium -Placement override-Todd `
        -LaneRole review -Row $reviewRow -PromptFile $prompt -Worktree $worktree -Label synthetic-sonnet-review `
        -DryRun -ExecutablePath $fakeExe
    } 'not an admitted' 'Row 0 compatibility must not admit Sonnet as a row-11/12 reviewer'
  }

  # Parse the exact configured arguments through the installed CLI with --help.
  # --help is bounded and exits before session creation, authentication, or a
  # model request; the IDs themselves are the built-ins reported by CLI init.
  $installedClaude = Get-Command claude -CommandType Application -ErrorAction Stop |
    Select-Object -First 1
  $claudeHelpOutput = Join-Path $testRoot "claude-argument-fixture.out"
  $claudeHelpError = Join-Path $testRoot "claude-argument-fixture.err"
  $claudeHelpProcess = $null
  try {
    $claudeHelpProcess = Start-Process -FilePath $installedClaude.Source `
      -ArgumentList @($expectedClaudeArguments + "--help") -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput $claudeHelpOutput -RedirectStandardError $claudeHelpError
    $claudeHelpExited = $claudeHelpProcess.WaitForExit(10000)
    if (-not $claudeHelpExited) {
      $claudeHelpProcess.Kill($true)
      [void]$claudeHelpProcess.WaitForExit(5000)
    }
    Assert-True ($claudeHelpExited) "installed Claude argument fixture exits within 10 seconds without launching a model"
    Assert-True ($claudeHelpProcess.ExitCode -eq 0) "installed Claude CLI accepts the exact disallowed-tool argument shape"
    Assert-True ((Get-Content -Raw -LiteralPath $claudeHelpOutput) -match "--disallowedTools") "installed Claude help confirms the supported disallowed-tools option"
  } finally {
    if ($claudeHelpProcess) { $claudeHelpProcess.Dispose() }
  }

  # --- Claude stream-json task-state audit and exact injected preamble ---------
  $transcriptChild = Join-Path $testRoot "transcript-child.ps1"
  @'
$capturedPrompt = [Console]::In.ReadToEnd()
[IO.File]::WriteAllText($env:DISPATCH_TRANSCRIPT_PROMPT_CAPTURE, $capturedPrompt, [Text.UTF8Encoding]::new($false))
Get-Content -LiteralPath $env:DISPATCH_TRANSCRIPT_FIXTURE
exit [int]$env:DISPATCH_TRANSCRIPT_CHILD_EXIT_CODE
'@ | Set-Content -LiteralPath $transcriptChild
  $transcriptRunner = Join-Path $testRoot "transcript-runner.ps1"
  @'
& $env:DISPATCH_TRANSCRIPT_LAUNCHER -Harness $env:DISPATCH_TRANSCRIPT_HARNESS `
  -Model $env:DISPATCH_TRANSCRIPT_MODEL -Effort high -Row $(if($env:DISPATCH_TRANSCRIPT_HARNESS -eq 'claude'){10}else{4}) -Placement $(if($env:DISPATCH_TRANSCRIPT_HARNESS -eq 'claude'){'override-Todd'}else{'provisional'}) -LaneRole $env:DISPATCH_TRANSCRIPT_LANE_ROLE `
  -PromptFile $env:DISPATCH_TRANSCRIPT_PROMPT -Worktree $env:DISPATCH_TRANSCRIPT_WORKTREE `
  -Label $env:DISPATCH_TRANSCRIPT_LABEL -ExecutablePath (Join-Path $PSHOME "pwsh.exe") `
  -TestArgumentList @("-NoProfile", "-NonInteractive", "-File", $env:DISPATCH_TRANSCRIPT_CHILD) `
  -TestRuntimeRoot $env:DISPATCH_TEST_RUNTIME_ROOT -TestTempRoot $env:DISPATCH_TEST_TEMP_ROOT
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $transcriptRunner

  function Write-TranscriptFixture(
    [string]$Path,
    [object[]]$Events,
    [string]$PartialLine = ""
  ) {
    $jsonLines = @($Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 })
    [IO.File]::WriteAllLines($Path, $jsonLines, [Text.UTF8Encoding]::new($false))
    if ($PartialLine) {
      [IO.File]::AppendAllText($Path, $PartialLine, [Text.UTF8Encoding]::new($false))
    }
  }

  function Invoke-TranscriptScenario(
    [string]$Name,
    [object[]]$Events,
    [string]$Harness = "claude",
    [string]$LaneRole = "implementation",
    [string]$PartialLine = "",
    [int]$ChildExitCode = 0
  ) {
    $label = "test-$Name-$([guid]::NewGuid())"
    $fixture = Join-Path $testRoot "$label-fixture.jsonl"
    $promptCapture = Join-Path $testRoot "$label-prompt.txt"
    $runnerOutput = Join-Path $testRoot "$label-runner.out"
    $runnerError = Join-Path $testRoot "$label-runner.err"
    Write-TranscriptFixture -Path $fixture -Events $Events -PartialLine $PartialLine
    $script:launcherOutputFiles += Join-Path $ownershipRoot "$label.jsonl"
    $script:launcherOutputFiles += Join-Path $ownershipRoot "$label.err.log"
    $scenarioEnvironment = @{
      DISPATCH_TRANSCRIPT_LAUNCHER = $launcher
      DISPATCH_TRANSCRIPT_HARNESS = $Harness
      DISPATCH_TRANSCRIPT_MODEL = $(if ($Harness -eq "claude") { "claude-sonnet-5-5" } else { "gpt-6.1-sol" })
      DISPATCH_TRANSCRIPT_LANE_ROLE = $LaneRole
      DISPATCH_TRANSCRIPT_PROMPT = $prompt
      DISPATCH_TRANSCRIPT_WORKTREE = $worktree
      DISPATCH_TRANSCRIPT_LABEL = $label
      DISPATCH_TRANSCRIPT_CHILD = $transcriptChild
      DISPATCH_TRANSCRIPT_FIXTURE = $fixture
      DISPATCH_TRANSCRIPT_PROMPT_CAPTURE = $promptCapture
      DISPATCH_TRANSCRIPT_CHILD_EXIT_CODE = $ChildExitCode.ToString()
      DISPATCH_TEST_RUNTIME_ROOT = $ownershipRoot
      DISPATCH_TEST_TEMP_ROOT = $providerTempRoot
    }
    $scenarioProcess = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") `
      -ArgumentList @("-NoProfile", "-NonInteractive", "-File", $transcriptRunner) `
      -Environment $scenarioEnvironment -WindowStyle Hidden -Wait -PassThru `
      -RedirectStandardOutput $runnerOutput -RedirectStandardError $runnerError
    $scenarioResult = [pscustomobject]@{
      exitCode = $scenarioProcess.ExitCode
      diagnostics = if (Test-Path -LiteralPath $runnerError) { Get-Content -Raw -LiteralPath $runnerError } else { "" }
      prompt = Get-Content -Raw -LiteralPath $promptCapture
    }
    $scenarioProcess.Dispose()
    $scenarioResult
  }

  function Invoke-DirectAuditScenario(
    [string]$Name,
    [object[]]$Events,
    [string]$PartialLine = ""
  ) {
    $fixture = Join-Path $testRoot "direct-$Name-$([guid]::NewGuid()).jsonl"
    Write-TranscriptFixture -Path $fixture -Events $Events -PartialLine $PartialLine
    Test-ClaudeStreamJsonCompletion $fixture
  }

  $successResult = [ordered]@{ type = "result"; subtype = "success"; is_error = $false; result = "done" }
  $activeEvents = @(
    [ordered]@{
      type = "system"
      subtype = "background_tasks_changed"
      tasks = @([ordered]@{ task_id = "bg-active"; task_type = "local_bash"; description = "Run terminal verification" })
    },
    $successResult
  )
  $activeScenario = Invoke-TranscriptScenario -Name "claude-active" -Events $activeEvents
  Assert-True ($activeScenario.exitCode -ne 0) "Claude nominal success fails closed while a tracked task remains active"
  Assert-True ($activeScenario.diagnostics -match "bg-active" -and $activeScenario.diagnostics -match "active at delivery success") "active-task diagnostic names the task identity and state"
  Assert-True ($activeScenario.diagnostics -match "lane ownership remains incomplete") "active-task diagnostic leaves lane ownership explicit"

  # Match the real #3422/#3426 ordering: result success is followed by shutdown
  # snapshots and killed/stopped notifications.
  $terminatedEvents = @(
    [ordered]@{
      type = "system"
      subtype = "background_tasks_changed"
      tasks = @([ordered]@{ task_id = "bg-terminated"; task_type = "local_bash"; description = "Run final static gate" })
    },
    $successResult,
    [ordered]@{ type = "system"; subtype = "background_tasks_changed"; tasks = @() },
    [ordered]@{ type = "system"; subtype = "task_updated"; task_id = "bg-terminated"; patch = [ordered]@{ status = "killed" } },
    [ordered]@{ type = "system"; subtype = "task_notification"; task_id = "bg-terminated"; status = "stopped"; summary = "Run final static gate" }
  )
  $terminatedAudit = Invoke-DirectAuditScenario -Name "claude-terminated" -Events $terminatedEvents
  $terminatedDiagnostics = @($terminatedAudit.diagnostics) -join [Environment]::NewLine
  Assert-True (-not $terminatedAudit.accepted) "Claude nominal success fails closed when a tracked task is killed/stopped during session exit"
  Assert-True ($terminatedDiagnostics -match "bg-terminated" -and $terminatedDiagnostics -match "killed/stopped") "terminated-task diagnostic names the task identity and both observed states"

  $untrackedStoppedEvents = @(
    [ordered]@{ type = "system"; subtype = "task_notification"; task_id = "bg-snapshot-missed"; status = "stopped"; summary = "Terminal task with a missing active snapshot" },
    $successResult
  )
  $untrackedStoppedAudit = Invoke-DirectAuditScenario -Name "claude-untracked-stopped" -Events $untrackedStoppedEvents
  $untrackedStoppedDiagnostics = @($untrackedStoppedAudit.diagnostics) -join [Environment]::NewLine
  Assert-True (-not $untrackedStoppedAudit.accepted) "Claude nominal success fails closed on a stopped task even when a schema/order variant omitted its active snapshot"
  Assert-True ($untrackedStoppedDiagnostics -match "bg-snapshot-missed" -and $untrackedStoppedDiagnostics -match "stopped") "untracked stopped-task diagnostic still names the identity and state"

  $clearedEvents = @(
    [ordered]@{ type = "system"; subtype = "task_started"; task_id = "fg-cleared-case"; description = "Ordinary foreground Bash/PowerShell command" },
    [ordered]@{ type = "system"; subtype = "task_notification"; task_id = "fg-cleared-case"; status = "completed" },
    [ordered]@{
      type = "system"
      subtype = "background_tasks_changed"
      tasks = @([ordered]@{ taskId = "bg-cleared"; taskType = "local_powershell"; summary = "Run bounded foreground-compatible fixture" })
    },
    [ordered]@{ type = "system"; subtype = "task_notification"; taskId = "bg-cleared"; state = "completed" },
    [ordered]@{ type = "system"; subtype = "background_tasks_changed"; tasks = @() },
    $successResult
  )
  $clearedScenario = Invoke-TranscriptScenario -Name "claude-cleared" -Events $clearedEvents
  Assert-True ($clearedScenario.exitCode -eq 0) "Claude success passes when all tracked tasks are explicitly cleared before result success"

  $foregroundEvents = @(
    [ordered]@{ type = "system"; subtype = "task_started"; task_id = "fg-command"; description = "Ordinary foreground PowerShell" },
    [ordered]@{ type = "system"; subtype = "task_notification"; task_id = "fg-command"; status = "completed" },
    $successResult
  )
  $foregroundAudit = Invoke-DirectAuditScenario -Name "claude-foreground" -Events $foregroundEvents
  Assert-True ($foregroundAudit.accepted) "ordinary foreground terminal task events are not misclassified as background ownership"

  $malformedAudit = Invoke-DirectAuditScenario -Name "claude-partial" `
    -Events @($successResult) -PartialLine '{"type":"system","subtype":"background_tasks_changed","tasks":['
  $malformedDiagnostics = @($malformedAudit.diagnostics) -join [Environment]::NewLine
  Assert-True (-not $malformedAudit.accepted) "partial stream-json fails closed after nominal Claude success"
  Assert-True ($malformedDiagnostics -match "malformed stream-json") "partial stream-json diagnostic identifies the malformed state without echoing content"

  $supportedGates = @("verify:static", "check:static", "test:scripts", "verify:test", "test", "test:fast", "build", "verify", "verify:build", "verify:test-db")
  $expectedHeavyPreamble = "Heavy verification contract: product proof is exact-head hosted CI. Retain scoped pre-push checks and focused tests; local full/harness runs and focused DB diagnostics are optional, never publication or landing gates. A scoped refusal never escalates to a full gate: preserve and disclose the defect, never fabricate PASS. Controller authors retain baseline-aware controller-release-battery.ps1 proof; product CI is not controller release proof. Any eligible heavy reproduction uses '$(Join-Path $PSScriptRoot 'invoke-heavy-verifier.ps1')', foreground and under unchanged exclusive admission, including direct Node, Playwright, full Vitest, script-battery and build commands. Exit 73 means not executed, not PASS or a consumed attempt. A timeout is load-sensitive only after an unchanged isolated timing collapse and a complete one-worker/file-serial gate; never raise timeouts, edit product files, or skip tests.`r`n`r`n"
  $expectedDeniedPreamble = "Heavy verification contract: planning, review and row-13 documentation lanes use evidence inspection and cheap focused checks only. Heavy commands refuse with exit 73 before reservation; this is non-execution, not PASS or a consumed attempt. Return heavy reproduction to the host for an attributed implementation/verifier lane. Controller reviewers rerun changed tests directly, never through ControllerBattery or ControllerPrecursor.`r`n`r`n"
  $expectedClaudePreamble = "Claude foreground-only execution contract: keep every terminal gate and poll in this turn's foreground and bounded. Do not use Monitor, ScheduleWakeup, any Cron tool (CronCreate, CronDelete, or CronList), long --watch commands, or long sleep/poll loops. When waiting is necessary, use repeated short bounded foreground calls, let each call return, and do not report delivery complete until all terminal work is finished.`r`n`r`n"
  $expectedRetrievalPreamble = "Bounded retrieval contract: prefer exact named paths and bounded line ranges. Scope searches and inventories to the needed paths and patterns, and bound displayed output with -First/-Tail, line-width limits or selected fields. This bounds output, not necessary caller discovery, exact ownership/history checks or complete evidence inspection; inspect all required evidence in bounded slices. Fetch hosted CI logs to a file, then search that file. Keep polls short, bounded and in the foreground; when waiting is necessary, repeat short bounded foreground calls and let each return. Complete evidence stays on disk; cite paths and exact lines rather than dumping raw output. Heavy-verifier, harness, role and review contracts remain authoritative.`r`n`r`n"
  $originalPrompt = [IO.File]::ReadAllText($prompt)
  Assert-True ($clearedScenario.prompt -ceq ($expectedHeavyPreamble + $expectedRetrievalPreamble + $expectedClaudePreamble + $originalPrompt)) "every Claude launch receives the exact canonical foreground-only preamble after the unchanged heavy-gate and bounded-retrieval preambles"

  $codexTranscriptScenario = Invoke-TranscriptScenario -Name "codex-non-regression" `
    -Events $foregroundEvents -Harness codex
  Assert-True ($codexTranscriptScenario.exitCode -eq 0) "Codex result handling remains unchanged by Claude stream-json auditing"
  Assert-True ($codexTranscriptScenario.prompt -ceq ($expectedHeavyPreamble + $expectedRetrievalPreamble + $originalPrompt)) "Codex launches receive the heavy-gate and bounded-retrieval preambles and not the Claude-only preamble"

  $reviewContractText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "contracts/review-v2.md")).TrimEnd() + "`r`n`r`n"
  $reviewTranscriptScenario = Invoke-TranscriptScenario -Name "codex-review-contract" `
    -Events $foregroundEvents -Harness codex -LaneRole review
  Assert-True ($reviewTranscriptScenario.exitCode -eq 0) "review contract fixture launches successfully"
  Assert-True ($reviewTranscriptScenario.prompt -ceq ($expectedDeniedPreamble + $expectedRetrievalPreamble + $reviewContractText + $originalPrompt)) "every review launch receives the exact versioned review contract before the task prompt"
  Assert-True ($reviewTranscriptScenario.prompt.Contains('A lane must not launch model CLIs or subprocess reviewers itself') -and
    $reviewTranscriptScenario.prompt.Contains('PENDING_HOST_REVIEW')) 'review role must inject the host-only independent review handoff'

  # --- review plan declares provider isolation without secret values ----------
  $reviewPlan = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high `
    -LaneRole review -PromptFile $prompt -Worktree $worktree `
    -Label "test-review-plan-$([guid]::NewGuid())" -DryRun `
    -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True ($reviewPlan.laneRole -eq "review") "review role is explicit"
  Assert-True ($reviewPlan.reviewContract.version -eq "review-contract/v2" -and
    $reviewPlan.reviewContract.path -eq (Join-Path $PSScriptRoot "contracts/review-v2.md")) "review plan identifies the exact injected contract"
  Assert-True ($reviewPlan.environmentPolicy.mode -eq "digitalocean-review-isolation") "review role selects DigitalOcean isolation"
  Assert-True (@($reviewPlan.environmentPolicy.removedVariables) -contains "DIGITALOCEAN_ACCESS_TOKEN") "review policy removes the live DigitalOcean token"
  foreach ($credentialName in @(
      "DIGITALOCEAN_TOKEN",
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "AWS_SESSION_TOKEN",
      "AWS_PROFILE",
      "AWS_SHARED_CREDENTIALS_FILE",
      "SPACES_ACCESS_KEY_ID",
      "SPACES_SECRET_ACCESS_KEY"
    )) {
    Assert-True (@($reviewPlan.environmentPolicy.removedVariables) -contains $credentialName) "review policy removes $credentialName"
  }
  Assert-True (@($reviewPlan.environmentPolicy.isolatedConfigRoots) -contains "APPDATA") "review policy isolates the native Windows doctl config root"
  Assert-True (@($reviewPlan.environmentPolicy.isolatedConfigRoots) -contains "XDG_CONFIG_HOME") "review policy isolates the POSIX doctl config root"
  Assert-True ($reviewPlan.environmentPolicy.kubeconfigPolicy -eq "nonexistent-path-inside-isolated-temp-root") "review policy declares kubectl default-config isolation"
  Assert-True ($reviewPlan.environmentPolicy.preservesGitHubAuthentication) "review policy preserves GitHub authentication"

  # --- planning role: credential-isolated, GitHub-capable, contract-injected --
  $planningContractText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "contracts/planning-repair-v1.md")).TrimEnd() + "`r`n`r`n"
  $planningTranscriptScenario = Invoke-TranscriptScenario -Name "codex-planning-contract" `
    -Events $foregroundEvents -Harness codex -LaneRole planning
  Assert-True ($planningTranscriptScenario.exitCode -eq 0) "planning contract fixture launches successfully"
  Assert-True ($planningTranscriptScenario.prompt -ceq ($expectedDeniedPreamble + $expectedRetrievalPreamble + $planningContractText + $originalPrompt)) "every planning launch receives the exact versioned planning contract before the task prompt"
  Assert-True ($planningTranscriptScenario.prompt.Contains('A lane must not launch model CLIs or subprocess reviewers itself') -and
    $planningTranscriptScenario.prompt.Contains('PENDING_HOST_REVIEW')) 'planning role must inject the host-only independent review handoff'

  $planningPlan = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high `
    -LaneRole planning -PromptFile $prompt -Worktree $worktree `
    -Label "test-planning-plan-$([guid]::NewGuid())" -DryRun `
    -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True ($planningPlan.laneRole -eq "planning") "planning role is explicit"
  Assert-True ($planningPlan.planningContract.version -eq "planning-repair/v1" -and
    $planningPlan.planningContract.path -eq (Join-Path $PSScriptRoot "contracts/planning-repair-v1.md")) "planning plan identifies the exact injected contract"
  Assert-True ($null -eq $planningPlan.reviewContract) "a planning lane is not handed the review contract"
  Assert-True ($planningPlan.environmentPolicy.mode -eq "planning-repair-isolation") "planning role selects its own isolation mode"
  foreach ($credentialName in @(
      "DIGITALOCEAN_ACCESS_TOKEN",
      "DIGITALOCEAN_TOKEN",
      "AWS_ACCESS_KEY_ID",
      "AWS_SECRET_ACCESS_KEY",
      "SPACES_ACCESS_KEY_ID",
      "SPACES_SECRET_ACCESS_KEY"
    )) {
    Assert-True (@($planningPlan.environmentPolicy.removedVariables) -contains $credentialName) "planning policy removes $credentialName"
  }
  Assert-True ($planningPlan.environmentPolicy.kubeconfigPolicy -eq "nonexistent-path-inside-isolated-temp-root") "planning policy disables kubectl's default kubeconfig fallback"
  # This one is load-bearing: filing the replacement issue IS the deliverable.
  Assert-True ($planningPlan.environmentPolicy.preservesGitHubAuthentication) "planning policy preserves GitHub authentication so the lane can file replacements"

  $implementationPlanNoContract = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high `
    -LaneRole implementation -Row 4 -Placement provisional -PromptFile $prompt -Worktree $worktree `
    -Label "test-impl-nocontract-$([guid]::NewGuid())" -DryRun `
    -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True ($null -eq $implementationPlanNoContract.planningContract) "implementation lanes are not handed the planning contract"

  # --- WSL watchdog hint translates the drive path ----------------------------
  Assert-True ($codex.watchdogWatchPath -like "/mnt/*") "watch hint is a /mnt path (WSL path-blindness gotcha)"
  Assert-True ($codex.watchdogWatchPath -notlike "*\*") "watch hint has no backslashes"

  # --- negative controls: each guard actually refuses --------------------------
  Assert-Throws { & $launcher -Harness claude -Model opus -Effort high -PromptFile $prompt -Worktree $worktree -Label "model-alias" -DryRun -ExecutablePath $fakeExe } "EXPLICIT_MODEL_NOT_CURRENT" "unversioned model aliases must refuse"
  Assert-Throws { & $launcher -Harness claude -Model claude-opus-4-8 -Effort high -PromptFile $prompt -Worktree $worktree -Label "deprecated-opus" -DryRun -ExecutablePath $fakeExe } "EXPLICIT_MODEL_NOT_CURRENT" "deprecated Opus 4.8 must refuse"
  $exactOpus5 = & $launcher -Harness claude -Model claude-opus-5-5 -Effort high -PromptFile $prompt -Worktree $worktree -Label "exact-opus5" -DryRun -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True (@($exactOpus5.arguments) -contains "claude-opus-5-5") "exact Opus 5 remains selectable independently of Opus 4.8"
  $exactFable51 = & $launcher -Harness claude -Model claude-fable-5-1 -Effort high -PromptFile $prompt -Worktree $worktree -Label "exact-fable51" -DryRun -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True (@($exactFable51.arguments) -contains "claude-fable-5-1") "Fable 5.1 is passed to the harness with its exact version"
  $automaticRow7 = & $launcher -Harness codex -Row 7 -LaneRole implementation -PromptFile $prompt -Worktree $worktree -Label "automatic-row7-$([guid]::NewGuid())" -DryRun -ExecutablePath $fakeExe | ConvertFrom-Json
  $automaticRow14 = & $launcher -Harness claude -Row 14 -LaneRole implementation -PromptFile $prompt -Worktree $worktree -Label "automatic-row14-$([guid]::NewGuid())" -DryRun -ExecutablePath $fakeExe | ConvertFrom-Json
  Assert-True ($automaticRow7.routing.model-ceq'gpt-6-astra'-and$automaticRow7.routing.placement-ceq'override-Todd') 'automatic row-7 Codex author route was not closed as override-Todd'
  Assert-True ($automaticRow14.routing.model-ceq'claude-fable-5-1'-and$automaticRow14.routing.placement-ceq'override-Todd') 'automatic row-14 Claude author route was not closed as override-Todd'
  $lifecycleRuntime=Join-Path $testRoot 'automatic-watchdog-lifecycle';New-Item -ItemType Directory -Path $lifecycleRuntime|Out-Null
  foreach($plan in @($automaticRow7,$automaticRow14)){
    $label="automatic-watchdog-row$($plan.routing.row)";$launchId=[guid]::NewGuid().ToString();$now=[datetimeoffset]::UtcNow
    $partial=Join-Path $lifecycleRuntime "$label.jsonl";$lifecycleError=Join-Path $lifecycleRuntime "$label.err.log";$observation=Join-Path $lifecycleRuntime "$label.obs.json"
    Set-Content $partial 'synthetic partial';Set-Content $lifecycleError 'synthetic owner';$selection=$plan.routing
    $spec=[ordered]@{schemaVersion='watchdog-lane/v2';label=$label;attemptId='synthetic-automatic-placement';relaunchCount=[long]0;resumeOfLaunchId=$null;harness=$plan.harness;model=$selection.model;effort=$selection.effort;row=[long]$selection.row;placement=$selection.placement;laneRole='implementation';originalPromptPath=$prompt;partialReportPath=$partial;errorPath=$lifecycleError;worktree=$worktree;branch='synthetic/branch';head=('a'*40);launchId=$launchId;ownershipRecordPath=(Join-Path $lifecycleRuntime "dispatch-launch-$launchId.json");launcherPid=[long]999991;launcherStartIdentity='2000-01-01T00:00:00.0000000Z';childPid=[long]999992;childStartIdentity='2000-01-01T00:00:01.0000000Z';state='running';exitCode=$null;updatedAt=$now.AddMinutes(-1).ToString('o');policyGeneration=[long]$selection.policyGeneration;registryAuthorityDigest=$selection.registryAuthorityDigest;family=$selection.family;slot=$selection.slot;usedLastKnownGood=$selection.usedLastKnownGood}
    [IO.File]::WriteAllText((Join-Path $lifecycleRuntime "watchdog-lane-$label.json"),($spec|ConvertTo-Json -Compress))
    [IO.File]::WriteAllText($observation,(@{ownerState='live';descendantState='none';transcriptStopped=$true;observedAt=$now.AddSeconds(-10).ToString('o');nowUtc=$now.ToString('o')}|ConvertTo-Json -Compress))
    $observed=& (Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1') -Label $label -RuntimeRoot $lifecycleRuntime -HistoryPath (Join-Path $lifecycleRuntime 'history.jsonl') -TranscriptPath $partial -ObservationFixture $observation -DispatchScript (Join-Path $lifecycleRuntime 'no-dispatch.ps1') -SynchronousDispatch|ConvertFrom-Json
    Assert-True ($observed.status-ceq'LIVE_SLOW') "automatic row-$($selection.row) plan was not accepted by the watchdog"
    Write-Output "PASS F3 automatic row=$($selection.row) harness=$($plan.harness) placement=$($selection.placement) watchdog=$($observed.status)"
  }
  $placementMutantRoot=Join-Path $testRoot 'dispatch-placement-mutant';New-Item -ItemType Directory -Force -Path $placementMutantRoot|Out-Null
  Get-ChildItem $PSScriptRoot -File|Copy-Item -Destination $placementMutantRoot
  $placementMutant=Join-Path $placementMutantRoot 'dispatch-lane.ps1';$placementSource=Get-Content -LiteralPath $launcher -Raw
  $placementNeedle="`$Placement = 'override-Todd'";Assert-True (([regex]::Matches($placementSource,[regex]::Escape($placementNeedle))).Count-eq1) 'F3 keep-reserve mutation anchor is not unique'
  [IO.File]::WriteAllText($placementMutant,$placementSource.Replace($placementNeedle,"`$Placement = [string]`$dispatchRouting.placement"),[Text.UTF8Encoding]::new($false))
  Assert-Throws { & $placementMutant -Harness codex -Row 7 -LaneRole implementation -PromptFile $prompt -Worktree $worktree -Label "keep-reserve-$([guid]::NewGuid())" -DryRun -ExecutablePath $fakeExe } 'ROUTING_PLACEMENT_UNSUPERVISED' 'keep-reserve mutant must refuse before launch'
  Write-Output 'MUTANT F3 keep-reserve RED (ROUTING_PLACEMENT_UNSUPERVISED)'
  Assert-Throws { & $launcher -Harness claude -Model claude-fable-5 -Effort high -PromptFile $prompt -Worktree $worktree -Label "historical-fable5" -DryRun -ExecutablePath $fakeExe } "EXPLICIT_HISTORICAL_OR_RETIRED_MODEL" "historical Fable 5 is no longer dispatchable"
  Assert-Throws { & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -PromptFile (Join-Path $testRoot "missing.txt") -Worktree $worktree -Label "t1" -DryRun -ExecutablePath $fakeExe } "not found" "missing prompt file must refuse"
  Assert-Throws { & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -PromptFile $emptyPrompt -Worktree $worktree -Label "t2" -DryRun -ExecutablePath $fakeExe } "empty" "empty prompt file must refuse (stdin EOF gotcha)"
  Assert-Throws { & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -PromptFile $prompt -Worktree (Join-Path $testRoot "no-such-lane") -Label "t3" -DryRun -ExecutablePath $fakeExe } "worktree" "missing worktree must refuse"
  Assert-Throws { & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -PromptFile $prompt -Worktree $worktree -Label "t4" -DryRun -ExecutablePath $fakeShim } "native" "shim executable must refuse (codex shim gotcha)"
  Assert-Throws { & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -PromptFile $prompt -Worktree $worktree -Label "t5" -DryRun -TestArgumentList @("--test") } "requires" "test arguments cannot alter a production-resolved harness"
  Assert-Throws { & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -LaneRole implementaton -PromptFile $prompt -Worktree $worktree -Label "t6" -DryRun -ExecutablePath $fakeExe } "" "mistyped lane role must refuse instead of inheriting provider authority"

  # --- incident controls: omission isolates; explicit implementation inherits -
  # The fake defaults contain doctl, kubeconfig, and GitHub config markers. All
  # inherited credential variables are synthetic. A copied cmd.exe named
  # doctl.exe stands in for an installed native provider binary and can only
  # write authorized/blocked markers; no provider binary or API is reachable.
  $syntheticProviderVariables = @(
    "DIGITALOCEAN_ACCESS_TOKEN",
    "DIGITALOCEAN_TOKEN",
    "DIGITALOCEAN_CONTEXT",
    "TF_VAR_digitalocean_token",
    "DIGITALOCEAN_SPACES_ACCESS_KEY",
    "DIGITALOCEAN_SPACES_SECRET",
    "SPACES_ACCESS_ID",
    "SPACES_SECRET_KEY",
    "SPACES_ACCESS_KEY_ID",
    "SPACES_SECRET_ACCESS_KEY",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AWS_PROFILE",
    "AWS_SHARED_CREDENTIALS_FILE",
    "RELEASE_EVIDENCE_SPACES_ACCESS_ID",
    "RELEASE_EVIDENCE_SPACES_SECRET_KEY"
  )
  $fakeAppData = Join-Path $testRoot "original-appdata"
  $fakeDoctlConfigDir = Join-Path $fakeAppData "doctl"
  $fakeGitHubConfigDir = Join-Path $fakeAppData "GitHub CLI"
  New-Item -ItemType Directory -Path $fakeDoctlConfigDir, $fakeGitHubConfigDir | Out-Null
  Set-Content -LiteralPath (Join-Path $fakeDoctlConfigDir "config.yaml") -Value "synthetic-default-doctl-config-marker"
  Set-Content -LiteralPath (Join-Path $fakeGitHubConfigDir "hosts.yml") -Value "synthetic-github-config-marker"
  $fakeDefaultKubeconfig = Join-Path $testRoot "default-kubeconfig"
  Set-Content -LiteralPath $fakeDefaultKubeconfig -Value "synthetic-default-kubeconfig-marker"

  $gitBashTmp = Join-Path $testRoot "git-bash-tmp"
  $installedBin = Join-Path $testRoot "installed-bin"
  New-Item -ItemType Directory -Path $gitBashTmp, $installedBin | Out-Null
  $shimMarker = Join-Path $testRoot "shim-called.txt"
  $posixShim = Join-Path $gitBashTmp "doctl.cmd"
  $gitBashStyleShimDir = "/tmp/$((Split-Path -Leaf $testRoot))/git-bash-tmp"
  Set-Content -LiteralPath $posixShim -Value "@echo shim-called>$shimMarker"

  $fakeInstalledDoctl = Join-Path $installedBin "doctl.exe"
  Copy-Item -LiteralPath $env:ComSpec -Destination $fakeInstalledDoctl
  $fakeDoctlProbe = Join-Path $testRoot "fake-doctl-probe.cmd"
  @"
@echo off
set "authorized="
if defined DIGITALOCEAN_ACCESS_TOKEN set "authorized=1"
if exist "%APPDATA%\doctl\config.yaml" set "authorized=1"
if defined authorized (
  >"%DOCTL_PROBE_OUTPUT%" echo installed-authorized
) else (
  >"%DOCTL_PROBE_OUTPUT%" echo installed-blocked
)
"@ | Set-Content -LiteralPath $fakeDoctlProbe

  $childProbe = Join-Path $testRoot "review-child-probe.ps1"
  @"
`$credentialPresence = [ordered]@{}
foreach (`$credentialName in (`$env:DISPATCH_TEST_CREDENTIAL_NAMES -split ",")) {
  `$credentialPresence[`$credentialName] = Test-Path "Env:`$credentialName"
}
`$defaultDoctlConfigVisible = Test-Path -LiteralPath (Join-Path `$env:APPDATA "doctl\config.yaml")
`$githubTokenPreserved = `$env:GITHUB_TOKEN -ceq "synthetic-github-token-marker"
`$githubConfigRoot = if (`$env:GH_CONFIG_DIR) { `$env:GH_CONFIG_DIR } else { Join-Path `$env:APPDATA "GitHub CLI" }
`$githubConfigPreserved = Test-Path -LiteralPath (Join-Path `$githubConfigRoot "hosts.yml")
`$kubeConfigPresent = Test-Path "Env:KUBECONFIG"
`$defaultKubeConfigVisible = `$kubeConfigPresent -and (Test-Path -LiteralPath `$env:KUBECONFIG)
`$heavyAdmissionConfigPresent = Test-Path "Env:CHASE_SETS_HEAVY_ADMISSION_CONFIG"
`$heavyAdmissionConfig = if (`$heavyAdmissionConfigPresent) {
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$env:CHASE_SETS_HEAVY_ADMISSION_CONFIG)) |
    ConvertFrom-Json
} else {
  `$null
}
`$heavyAdmissionNodeOptionsPresent = `$env:NODE_OPTIONS -match "heavy-admission-preload\.cjs"
`$heavyAdmissionScriptShellPresent = `$env:npm_config_script_shell -match "(?i)(?:^|[\\/])node\.exe$"
`$heavyAdmissionScriptShellMarkerPresent = `$env:CHASE_SETS_HEAVY_ADMISSION_PNPM_SCRIPT_SHELL -ceq "node-check-proxy"
`$kubeConfigUsesIsolatedRoot = `$false
if (`$kubeConfigPresent) {
  `$appDataRoot = [System.IO.Path]::GetFullPath(`$env:APPDATA).TrimEnd("\", "/")
  `$kubeConfigParent = (Split-Path -Parent ([System.IO.Path]::GetFullPath(`$env:KUBECONFIG))).TrimEnd("\", "/")
  `$kubeConfigUsesIsolatedRoot = `$kubeConfigParent -eq `$appDataRoot
}
`$psi = [System.Diagnostics.ProcessStartInfo]::new()
`$psi.FileName = "doctl"
`$psi.UseShellExecute = `$false
[void]`$psi.ArgumentList.Add("/d")
[void]`$psi.ArgumentList.Add("/c")
[void]`$psi.ArgumentList.Add(`$env:FAKE_DOCTL_PROBE)
`$child = [System.Diagnostics.Process]::Start(`$psi)
`$child.WaitForExit()
[ordered]@{
  credentialPresence = `$credentialPresence
  defaultDoctlConfigVisible = `$defaultDoctlConfigVisible
  defaultKubeConfigVisible = `$defaultKubeConfigVisible
  heavyAdmissionConfigPresent = `$heavyAdmissionConfigPresent
  heavyAdmissionBranch = if (`$heavyAdmissionConfig) { `$heavyAdmissionConfig.branch } else { `$null }
  heavyAdmissionHead = if (`$heavyAdmissionConfig) { `$heavyAdmissionConfig.head } else { `$null }
  heavyAdmissionNodeOptionsPresent = `$heavyAdmissionNodeOptionsPresent
  heavyAdmissionScriptShellPresent = `$heavyAdmissionScriptShellPresent
  heavyAdmissionScriptShellMarkerPresent = `$heavyAdmissionScriptShellMarkerPresent
  kubeConfigUsesIsolatedRoot = `$kubeConfigUsesIsolatedRoot
  githubTokenPreserved = `$githubTokenPreserved
  githubConfigPreserved = `$githubConfigPreserved
  doctlExitCode = `$child.ExitCode
  isolationRoot = `$env:APPDATA
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath `$env:DISPATCH_CHILD_RESULT
exit [int]`$env:DISPATCH_TEST_CHILD_EXIT_CODE
"@ | Set-Content -LiteralPath $childProbe
  $launcherRunner = Join-Path $testRoot "launcher-runner.ps1"
  @'
$launchParameters = @{
  Harness = "codex"
  Model = "gpt-6.1-sol"
  Effort = "high"
  PromptFile = $env:DISPATCH_TEST_PROMPT
  Worktree = $env:DISPATCH_TEST_WORKTREE
  Label = $env:DISPATCH_TEST_LABEL
  ExecutablePath = Join-Path $PSHOME "pwsh.exe"
  TestArgumentList = @("-NoProfile", "-NonInteractive", "-File", $env:DISPATCH_TEST_CHILD_PROBE)
  TestRuntimeRoot = $env:DISPATCH_TEST_RUNTIME_ROOT
  TestTempRoot = $env:DISPATCH_TEST_TEMP_ROOT
}
if (Test-Path "Env:DISPATCH_TEST_LANE_ROLE") {
  $launchParameters["LaneRole"] = $env:DISPATCH_TEST_LANE_ROLE
  if ($env:DISPATCH_TEST_LANE_ROLE -eq 'implementation') {
    $launchParameters['Row'] = 4
    $launchParameters['Placement'] = 'provisional'
  }
}
& $env:DISPATCH_TEST_LAUNCHER @launchParameters
exit $LASTEXITCODE
'@ | Set-Content -LiteralPath $launcherRunner

  $baseScenarioEnvironment = @{
    APPDATA = $fakeAppData
    GH_CONFIG_DIR = $null
    GITHUB_TOKEN = "synthetic-github-token-marker"
    KUBECONFIG = $fakeDefaultKubeconfig
    PATH = "$gitBashStyleShimDir;$installedBin"
    FAKE_DOCTL_PROBE = $fakeDoctlProbe
    DISPATCH_TEST_LAUNCHER = $launcher
    DISPATCH_TEST_PROMPT = $prompt
    DISPATCH_TEST_WORKTREE = $worktree
    DISPATCH_TEST_CHILD_PROBE = $childProbe
    DISPATCH_TEST_CREDENTIAL_NAMES = $syntheticProviderVariables -join ","
    DISPATCH_TEST_RUNTIME_ROOT = $ownershipRoot
    DISPATCH_TEST_TEMP_ROOT = $providerTempRoot
  }
  foreach ($credentialName in $syntheticProviderVariables) {
    $baseScenarioEnvironment[$credentialName] = "synthetic-provider-authority-marker"
  }

  function Invoke-IncidentScenario(
    [AllowNull()][string]$LaneRole,
    [string]$Label,
    [string]$ResultPath,
    [string]$ProviderProbePath,
    [int]$ChildExitCode
  ) {
    $scenarioEnvironment = $baseScenarioEnvironment.Clone()
    $scenarioEnvironment["DISPATCH_TEST_LANE_ROLE"] = if ($LaneRole) { $LaneRole } else { $null }
    $scenarioEnvironment["DISPATCH_TEST_LABEL"] = $Label
    $scenarioEnvironment["DISPATCH_CHILD_RESULT"] = $ResultPath
    $scenarioEnvironment["DOCTL_PROBE_OUTPUT"] = $ProviderProbePath
    $scenarioEnvironment["DISPATCH_TEST_CHILD_EXIT_CODE"] = $ChildExitCode.ToString()
    $runnerOutput = Join-Path $testRoot "$Label-runner.out"
    $runnerError = Join-Path $testRoot "$Label-runner.err"
    Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") `
      -ArgumentList @("-NoProfile", "-NonInteractive", "-File", $launcherRunner) `
      -Environment $scenarioEnvironment -WindowStyle Hidden -Wait -PassThru `
      -RedirectStandardOutput $runnerOutput -RedirectStandardError $runnerError
  }

  # The first PATH entry intentionally has Git Bash /tmp syntax even though its
  # doctl.cmd lives at the corresponding test seam. Native Windows resolution
  # skips it and selects the inert copied doctl.exe second.
  $reviewLabel = "test-review-child-$([guid]::NewGuid())"
  $reviewResult = Join-Path $testRoot "review-child-result.json"
  $reviewProviderProbe = Join-Path $testRoot "review-installed-doctl-result.txt"
  $launcherOutputFiles += Join-Path $ownershipRoot "$reviewLabel.jsonl"
  $launcherOutputFiles += Join-Path $ownershipRoot "$reviewLabel.err.log"
  $reviewProcess = Invoke-IncidentScenario -LaneRole $null -Label $reviewLabel `
    -ResultPath $reviewResult -ProviderProbePath $reviewProviderProbe -ChildExitCode 0
  Assert-True ($reviewProcess.ExitCode -eq 0) "omitted-role review child exits successfully"

  $reviewChild = Get-Content -Raw -LiteralPath $reviewResult | ConvertFrom-Json
  foreach ($credentialName in $syntheticProviderVariables) {
    Assert-True (-not $reviewChild.credentialPresence.$credentialName) "omitted-role review child cannot observe $credentialName"
  }
  Assert-True (-not $reviewChild.defaultDoctlConfigVisible) "omitted-role review child cannot fall back to the user's default doctl config"
  Assert-True (-not $reviewChild.defaultKubeConfigVisible) "omitted-role review child cannot fall back to the user's default kubeconfig"
  Assert-True ($reviewChild.kubeConfigUsesIsolatedRoot) "review KUBECONFIG points inside the unique isolation root"
  Assert-True ($reviewChild.heavyAdmissionConfigPresent -and
    $reviewChild.heavyAdmissionNodeOptionsPresent -and
    $reviewChild.heavyAdmissionScriptShellPresent -and
    $reviewChild.heavyAdmissionScriptShellMarkerPresent) "review child receives both machine admission hooks independently of provider isolation"
  Assert-True ($reviewChild.heavyAdmissionBranch -ceq $dispatchBranch -and
    $reviewChild.heavyAdmissionHead -ceq $dispatchHead) "review child receives the dispatch-time branch and exact HEAD"
  Assert-True ($reviewChild.githubTokenPreserved) "required GitHub token remains available without exposing its value"
  Assert-True ($reviewChild.githubConfigPreserved) "stored GitHub CLI authentication remains reachable through GH_CONFIG_DIR"
  Assert-True ($reviewChild.doctlExitCode -eq 0) "inert installed doctl stand-in executed"
  Assert-True ((Get-Content -Raw -LiteralPath $reviewProviderProbe).Trim() -eq "installed-blocked") "native doctl.exe resolution drift remains unauthorized"
  Assert-True (-not (Test-Path -LiteralPath $reviewChild.isolationRoot)) "review isolation root is cleaned after child success"
  Assert-True (-not (Test-Path -LiteralPath $shimMarker)) "Git Bash doctl.cmd shim was not mistaken for native resolution proof"

  $failureLabel = "test-review-failure-$([guid]::NewGuid())"
  $failureResult = Join-Path $testRoot "review-failure-result.json"
  $failureProviderProbe = Join-Path $testRoot "review-failure-doctl-result.txt"
  $launcherOutputFiles += Join-Path $ownershipRoot "$failureLabel.jsonl"
  $launcherOutputFiles += Join-Path $ownershipRoot "$failureLabel.err.log"
  $failureProcess = Invoke-IncidentScenario -LaneRole $null -Label $failureLabel `
    -ResultPath $failureResult -ProviderProbePath $failureProviderProbe -ChildExitCode 37
  Assert-True ($failureProcess.ExitCode -eq 37) "review launcher returns the child failure code (actual: $($failureProcess.ExitCode))"
  $failureChild = Get-Content -Raw -LiteralPath $failureResult | ConvertFrom-Json
  Assert-True (-not (Test-Path -LiteralPath $failureChild.isolationRoot)) "review isolation root is cleaned after child failure"

  $implementationLabel = "test-implementation-child-$([guid]::NewGuid())"
  $implementationResult = Join-Path $testRoot "implementation-child-result.json"
  $implementationProviderProbe = Join-Path $testRoot "implementation-installed-doctl-result.txt"
  $launcherOutputFiles += Join-Path $ownershipRoot "$implementationLabel.jsonl"
  $launcherOutputFiles += Join-Path $ownershipRoot "$implementationLabel.err.log"
  $implementationProcess = Invoke-IncidentScenario -LaneRole "implementation" `
    -Label $implementationLabel -ResultPath $implementationResult `
    -ProviderProbePath $implementationProviderProbe -ChildExitCode 0
  Assert-True ($implementationProcess.ExitCode -eq 0) "explicit implementation child exits successfully"

  $implementationChild = Get-Content -Raw -LiteralPath $implementationResult | ConvertFrom-Json
  foreach ($credentialName in $syntheticProviderVariables) {
    Assert-True ($implementationChild.credentialPresence.$credentialName) "explicit implementation child retains $credentialName"
  }
  Assert-True ($implementationChild.defaultDoctlConfigVisible) "explicit implementation role retains the default doctl config location"
  Assert-True ($implementationChild.defaultKubeConfigVisible) "explicit implementation role retains the inherited kubeconfig"
  Assert-True ($implementationChild.heavyAdmissionConfigPresent -and
    $implementationChild.heavyAdmissionNodeOptionsPresent -and
    $implementationChild.heavyAdmissionScriptShellPresent -and
    $implementationChild.heavyAdmissionScriptShellMarkerPresent) "implementation child receives the same machine admission path"
  Assert-True ($implementationChild.heavyAdmissionBranch -ceq $dispatchBranch -and
    $implementationChild.heavyAdmissionHead -ceq $dispatchHead) "implementation child receives the dispatch-time branch and exact HEAD"
  Assert-True ($implementationChild.githubTokenPreserved) "explicit implementation role retains GitHub authentication"
  Assert-True ($implementationChild.githubConfigPreserved) "explicit implementation role retains GitHub CLI config"
  Assert-True ((Get-Content -Raw -LiteralPath $implementationProviderProbe).Trim() -eq "installed-authorized") "negative control proves the synthetic incident shape is live only with explicit implementation authority"

  # --- clobber guard: a live label's non-empty output refuses without -Force ---
  $busyLabel = "test-busy-$([guid]::NewGuid())"
  $busyOut = Join-Path $PSScriptRoot "$busyLabel.jsonl"
  Set-Content -LiteralPath $busyOut -Value "lane output in progress"
  try {
    Assert-Throws { & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -PromptFile $prompt -Worktree $worktree -Label $busyLabel -DryRun -ExecutablePath $fakeExe } "non-empty" "non-empty output stem must refuse without -Force"
    $forced = & $launcher -Harness codex -Model gpt-6.1-sol -Effort high -PromptFile $prompt -Worktree $worktree -Label $busyLabel -DryRun -ExecutablePath $fakeExe -Force | ConvertFrom-Json
    Assert-True ($forced.harness -eq "codex") "-Force permits an intentional same-label resume"
  } finally {
    Remove-Item -LiteralPath $busyOut -Force -ErrorAction SilentlyContinue
  }

  Write-Output "PASS dispatch-lane launcher coverage"
} finally {
  if ($forcedLauncherProcess -and -not $forcedLauncherProcess.HasExited) {
    Stop-Process -Id $forcedLauncherProcess.Id -Force -ErrorAction SilentlyContinue
  }
  if ($forcedChildPid -and $forcedChildStartIdentity -and
      (Get-DispatchProcessIdentityState $forcedChildPid $forcedChildStartIdentity) -eq "live") {
    Stop-Process -Id $forcedChildPid -Force -ErrorAction SilentlyContinue
  }
  foreach ($outputFile in $launcherOutputFiles) {
    Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue
  }
  if (((Split-Path -Parent $testRootResolved).TrimEnd("\", "/")) -ne $tempRootResolved -or
      (Split-Path -Leaf $testRootResolved) -notlike "dispatch-lane-test-*") {
    throw "refusing unsafe test cleanup target: $testRootResolved"
  }
  Remove-Item -LiteralPath $testRootResolved -Recurse -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')

# ---- #8102: fleet load and the timed 8076 dispatch fixture ----
# Every leg below runs the dispatch carrier from a committed copy of this
# checkout's tracked .orchestrator inventory inside its own temp container, so
# the synthetic verify-lock.d holder (a CPU-heavy child owned and stopped by this
# test) and every source replacement exist only there. The live container's
# verify-lock.d is never read for these legs, never created and never touched.
# All legs end at the 8076 control, whose armed window is 30 s; the stall below
# holds the candidate's release until that window has been missed.
$stall8102Needle='      $binding=Resume8076 $record $path $Owner $Seed $Obligation $Runtime $Label'
$stall8102=@('      while([datetimeoffset]::UtcNow-lt([datetimeoffset]$record.hold.armedReceipt.deadline).AddSeconds(1)){[Threading.Thread]::Sleep(100)} # SYNTHETIC_8102_STALL: miss the armed 30 s window',$stall8102Needle) -join "`n"
$unconditional8102Needle='if($boundMissed-and$Record.hold.releaseAbsent-and$window.held){'
$unconditional8102='if($boundMissed-and$Record.hold.releaseAbsent){ # SYNTHETIC_8102_MUTANT: MEASURED_LOAD without a concurrent holder'
$treeGuard8102Needle='function Assert-InterruptedIntegrationTreeDead($Owner) {'
$treeGuard8102="function Assert-InterruptedIntegrationTreeDead(`$Owner) {`n  return # Synthetic omission (#8102 AC3): actual prior tree death."

function Invoke-8102DispatchLeg([string]$Test,[string]$Label,[hashtable]$Edits,[bool]$WithHolder) {
  $copy=New-8102FixtureCopy $Label $Edits
  $holder=$null;$holderIdentity='none'
  try {
    if($WithHolder){$holder=Start-SyntheticFleetHolder $copy.container;$holderIdentity=$holder.identity}
    $run=Invoke-8102CarrierCopy $copy 'dispatch'
  } finally { Stop-SyntheticFleetHolder $holder }
  $lines=@($run.stdout -split "\r?\n")
  $measured=@($lines|Where-Object{$_-clike'MEASURED_LOAD *'})
  $finished=[bool]@($lines|Where-Object{$_-clike'RETAINED 7963 dispatch *finished=True'}).Count
  $text=$run.stdout+"`n"+$run.stderr
  # Write-Host keeps the leg object the function's only pipeline output.
  Write-Host "CONTROL 8102 $Test $Label holder=$holderIdentity exit=$($run.exit) elapsedSeconds=$([int]$run.elapsedSeconds) measuredLines=$($measured.Count) finished=$finished stdout=$($run.stdoutPath) stderr=$($run.stderrPath)"
  return [pscustomobject]@{label=$Label;copy=$copy;run=$run;holder=$holderIdentity;measured=$measured;finished=$finished;exit=$run.exit;text=$text}
}
function Assert-8102([bool]$Condition,[string]$Test,[string]$Name,$Leg) {
  if(-not$Condition){throw "8102 $Test ASSERTION FAILED: $Name; leg=$($Leg.label) exit=$($Leg.exit) stdout=$($Leg.run.stdoutPath) stderr=$($Leg.run.stderrPath)"}
  Write-Output "PROOF 8102 $Test $Name"
}

# AC1 (dispatch): a miss of the 8076 fixture's timed bound is MEASURED_LOAD,
# with holder identity and elapsed time, only while the synthetic holder is live
# for the whole window; the same miss on a vacant fleet stays FAIL; a fixture
# that classifies the miss MEASURED_LOAD without a holder fails the vacant
# control; with no holder and no miss the unmodified carrier passes.
function Test-TimedFixtureUnderFleetLoadMeasuresLoad {
  $test='timed-fixture-under-fleet-load-measures-load'
  # Classifier legs are proof arms (Test-BatteryProofRelevant); the unmodified
  # dispatch carrier below always runs.
  if(-not(Test-BatteryProofRelevant @('landed-integration-evidence.psm1','dispatch-lane.test.ps1'))){
    Write-Output "SKIPPED 8102 $test classifier legs: classifier files unchanged in impact battery"
    Invoke-7963ResumeCarriers @('dispatch')
    return
  }
  $stallEdits=@{'interrupted-integration-test-support.ps1'=@(,@($stall8102Needle,$stall8102))}
  $loaded=Invoke-8102DispatchLeg $test 'stalled-held' $stallEdits $true
  Assert-8102 ($loaded.holder-cne'none'-and$loaded.exit-eq75-and$loaded.measured.Count-eq1-and-not$loaded.finished) $test "missed bound under a live holder exits 75 with one MEASURED_LOAD line and an unfinished carrier (actual exit=$($loaded.exit) measuredLines=$($loaded.measured.Count))" $loaded
  $measuredLine=[regex]::Match($loaded.measured[0],'^MEASURED_LOAD 8076 dispatch fleetHolder='+[regex]::Escape($loaded.holder)+' elapsedSeconds=(\d+(\.\d+)?) boundSeconds=30 armedAt=\S+ deadline=\S+ releaseStartedAt=\S+ projection=\S+$')
  Assert-8102 $measuredLine.Success $test "MEASURED_LOAD line names the synthetic holder identity and the measured elapsed time: $($loaded.measured[0])" $loaded
  $elapsed=[double]$measuredLine.Groups[1].Value
  Assert-8102 ($elapsed-ge30) $test "measured elapsed ${elapsed}s reached the 30 s bound" $loaded
  Assert-8102 ($loaded.text.Contains('MEASUREMENT 8076 dispatch classification=MEASURED_LOAD')-and-not$loaded.text.Contains('classification=MEASURED_STALE')-and-not$loaded.text.Contains('NOT_CONSTRUCTIBLE')) $test 'projection records MEASURED_LOAD, not a settled PASS and not the vacant-fleet FAIL' $loaded
  $vacant=Invoke-8102DispatchLeg $test 'stalled-vacant' $stallEdits $false
  Assert-8102 ($vacant.exit-eq1-and$vacant.measured.Count-eq0-and-not$vacant.finished-and$vacant.text.Contains('8076 AC3 NOT_CONSTRUCTIBLE: holder not live and unreleased before armed deadline at release')) $test "missed bound with no holder stays FAIL exit=1 with no MEASURED_LOAD line (actual exit=$($vacant.exit) measuredLines=$($vacant.measured.Count))" $vacant
  $mutantEdits=@{'interrupted-integration-test-support.ps1'=@(@($stall8102Needle,$stall8102),@($unconditional8102Needle,$unconditional8102))}
  $mutant=Invoke-8102DispatchLeg $test 'stalled-vacant-unconditional-mutant' $mutantEdits $false
  Assert-8102 ($mutant.exit-eq75-and$mutant.measured.Count-eq1-and$mutant.measured[0]-clike'MEASURED_LOAD 8076 dispatch fleetHolder=none elapsedSeconds=*') $test "fixture mutant that classifies MEASURED_LOAD without a concurrent holder reports fleetHolder=none on a vacant fleet (actual exit=$($mutant.exit))" $mutant
  Assert-8102 (-not($mutant.exit-eq1-and$mutant.measured.Count-eq0-and$mutant.text.Contains('8076 AC3 NOT_CONSTRUCTIBLE: holder not live and unreleased before armed deadline at release'))) $test 'vacant-fleet FAIL control rejects that mutant' $mutant
  Invoke-7963ResumeCarriers @('dispatch')
  Write-Output "PASS 8102 $test held-miss=MEASURED_LOAD vacant-miss=FAIL vacant-mutant=CAUGHT vacant=PASS"
  foreach($leg in @($loaded,$vacant,$mutant)){Remove-8102FixtureCopy $leg.copy}
}

# AC3 (dispatch): an existing omission arm, the prior-owner tree-death guard,
# run under the synthetic holder is never PASS and never MEASURED_LOAD; the
# vacant-fleet rerun catches the same omission as FAIL.
function Test-RegressionUnderLoadIsNotMasked {
  $test='regression-under-load-is-not-masked'
  if(-not(Test-BatteryProofRelevant @('landed-integration-evidence.psm1','dispatch-lane.test.ps1'))){
    Write-Output "SKIPPED 8102 $test classifier legs: classifier files unchanged in impact battery"
    return
  }
  $edits=@{'landed-integration-evidence.psm1'=@(,@($treeGuard8102Needle,$treeGuard8102))}
  $held=Invoke-8102DispatchLeg $test 'tree-guard-omitted-held' $edits $true
  Assert-8102 ($held.holder-cne'none'-and$held.exit-ne0-and$held.exit-ne75-and$held.measured.Count-eq0-and-not$held.finished-and$held.text.Contains('8076 AC3 NOT_CONSTRUCTIBLE: held wait-omitted mutant did not refuse at psm1:615')) $test "omitted tree-death guard under a live holder is FAIL, never PASS and never MEASURED_LOAD (actual exit=$($held.exit) measuredLines=$($held.measured.Count))" $held
  $vacant=Invoke-8102DispatchLeg $test 'tree-guard-omitted-vacant' $edits $false
  Assert-8102 ($vacant.exit-eq1-and$vacant.measured.Count-eq0-and-not$vacant.finished-and$vacant.text.Contains('8076 AC3 NOT_CONSTRUCTIBLE: held wait-omitted mutant did not refuse at psm1:615')) $test "same omission on a vacant fleet is caught as FAIL exit=1 (actual exit=$($vacant.exit))" $vacant
  Write-Output "PASS 8102 $test held=FAIL vacant=FAIL"
  foreach($leg in @($held,$vacant)){Remove-8102FixtureCopy $leg.copy}
}

# ---- #8103: prior-owner liveness by process identity ----
# Both tests use only this test process and an idle child pwsh it owns and
# stops; no live holder and no container verify-lock.d is read or touched. The
# synthetic owner records have the shape of the retained 070 seed: a live PID
# recorded with a start identity one second before that process was born, which
# is exactly a reused PID. Simulated inventories project the real Win32_Process
# rows with one change each inside the module scope, as 7926 F2 does.
function New-8103Owner([long]$LauncherPid,[datetime]$LauncherStart,[long]$ChildPid,[datetime]$ChildStart) {
  [pscustomobject]@{schemaVersion='watchdog-lane/v2';launcherPid=$LauncherPid;launcherStartIdentity=$LauncherStart.ToUniversalTime().ToString('o');childPid=$ChildPid;childStartIdentity=$ChildStart.ToUniversalTime().ToString('o');state='exited'}
}
function Start-8103IdleChild {
  $psi=[Diagnostics.ProcessStartInfo]::new();$psi.FileName=(Join-Path $PSHOME 'pwsh.exe');$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardInput=$true
  foreach($argument in @('-NoProfile','-NonInteractive','-Command','[Console]::In.ReadToEnd()|Out-Null')){[void]$psi.ArgumentList.Add($argument)}
  [Diagnostics.Process]::Start($psi)
}
function Stop-8103IdleChild($Child) {
  if($null-eq$Child){return}
  try{$Child.StandardInput.Close();if(-not$Child.WaitForExit(5000)){$Child.Kill()}}finally{$Child.Dispose()}
}
function Get-8103GuardError([scriptblock]$Block) {
  try{& $Block|Out-Null;return $null}catch{return [pscustomobject]@{message=$_.Exception.Message;stack=$_.ScriptStackTrace}}
}

# AC1: a root held by a live process with a different, readable start identity
# is a reused PID and dead; an exact-identity live owner refuses live root; a
# null CreationDate or a duplicated row refuses ambiguous root; a child of the
# reused holder born after the holder is not a possible descendant, and a child
# born between the recorded owner start and the holder start still is.
function Test-ReusedPidRootIsDeadByIdentity {
  $test='reused-pid-root-is-dead-by-identity'
  $psm=Join-Path $PSScriptRoot 'landed-integration-evidence.psm1'
  $module=Import-Module $psm -Force -DisableNameChecking -PassThru
  $child=$null
  try {
    $child=Start-8103IdleChild
    $selfStart=(Get-Process -Id $PID).StartTime.ToUniversalTime();$childStart=$child.StartTime.ToUniversalTime()
    $selfRow=@(Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop);$childRow=@(Get-CimInstance Win32_Process -Filter "ProcessId = $($child.Id)" -ErrorAction Stop)
    Assert-True ($selfRow.Count-eq1-and$childRow.Count-eq1-and$childRow[0].ParentProcessId-eq$PID-and([datetimeoffset]$childRow[0].CreationDate)-ge([datetimeoffset]$selfRow[0].CreationDate)) "$test`: the idle child is this process's own child, born after it"
    $reused=New-8103Owner $PID $selfStart.AddSeconds(-1) $child.Id $childStart.AddSeconds(-1)
    $refusal=Get-8103GuardError { Assert-InterruptedIntegrationTreeDead $reused }
    Assert-True ($null-eq$refusal) "$test`: reused launcher and child PIDs are dead by identity and the holder's own child is not a possible descendant (actual: $($refusal.message))"
    Write-Output "PROOF 8103 $test reused-roots=dead launcherPid=$PID childPid=$($child.Id) holder-child=not-descendant"
    foreach($case in @(@{name='exact launcher';owner=(New-8103Owner $PID $selfStart $child.Id $childStart.AddSeconds(-1))},@{name='exact child';owner=(New-8103Owner $PID $selfStart.AddSeconds(-1) $child.Id $childStart)})){
      $owner=$case.owner
      $refusal=Get-8103GuardError { Assert-InterruptedIntegrationTreeDead $owner }
      Assert-True ($refusal.message-ceq'INTEGRATION_RESUME_PRIOR_OWNER: live root') "$test`: $($case.name) identity refuses live root (actual: $($refusal.message))"
    }
    Write-Output "PROOF 8103 $test exact-identity=live-root"
    $simulated=& $module {
      param([long]$Root,[long]$ChildId,[string]$RecordedLauncherStart,[string]$RecordedChildStart)
      $script:project8103={param($Rows) $Rows}
      function script:Get-CimInstance { [CmdletBinding()]param([Parameter(Position=0)]$ClassName,$Filter)
        $rows=@(if($Filter){CimCmdlets\Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop}else{CimCmdlets\Get-CimInstance -ClassName $ClassName -ErrorAction Stop})
        $projected=@($rows|ForEach-Object{[pscustomobject]@{ProcessId=[int]$_.ProcessId;ParentProcessId=[int]$_.ParentProcessId;CreationDate=$_.CreationDate}})
        @(& $script:project8103 $projected)
      }
      $owner=[pscustomobject]@{launcherPid=$Root;launcherStartIdentity=$RecordedLauncherStart;childPid=$ChildId;childStartIdentity=$RecordedChildStart}
      $holderBirth=[datetimeoffset](CimCmdlets\Get-CimInstance Win32_Process -Filter "ProcessId = $Root" -ErrorAction Stop).CreationDate
      $cases=@(
        [pscustomobject]@{name='null CreationDate';expected='INTEGRATION_RESUME_PRIOR_OWNER: ambiguous root';project={param($Rows) @($Rows|ForEach-Object{if($_.ProcessId-eq$ChildId){$_.CreationDate=$null};$_})}},
        [pscustomobject]@{name='duplicated row';expected='INTEGRATION_RESUME_PRIOR_OWNER: ambiguous root';project={param($Rows) @($Rows+@($Rows|Where-Object{$_.ProcessId-eq$ChildId}))}},
        [pscustomobject]@{name='child born between the recorded owner start and the holder start';expected='INTEGRATION_RESUME_PRIOR_OWNER: possible descendant';project={param($Rows) @($Rows|ForEach-Object{if($_.ProcessId-eq$ChildId){$_.CreationDate=$holderBirth.AddMilliseconds(-500).LocalDateTime};$_})}},
        [pscustomobject]@{name='child born before the recorded owner start';expected=$null;project={param($Rows) @($Rows|ForEach-Object{if($_.ProcessId-eq$ChildId){$_.CreationDate=$holderBirth.AddSeconds(-2).LocalDateTime};$_})}}
      )
      foreach($case in $cases){
        $script:project8103=$case.project
        $actual=$null;try{Assert-InterruptedIntegrationTreeDead $owner}catch{$actual=$_.Exception.Message}
        [pscustomobject]@{name=$case.name;expected=$case.expected;actual=$actual}
      }
    } $PID $child.Id $reused.launcherStartIdentity $reused.childStartIdentity
    foreach($case in @($simulated)){
      Assert-True ($case.actual-ceq$case.expected) "$test`: $($case.name) -> $(if($case.expected){$case.expected}else{'dead'}) (actual: $($case.actual))"
    }
    Write-Output "PASS 8103 $test reused=dead exact=live-root null-or-duplicate=ambiguous-root holder-child=not-descendant window-child=possible-descendant"
  } finally { Stop-8103IdleChild $child; Remove-Module $module -Force -ErrorAction SilentlyContinue; Import-Module $psm -Force -DisableNameChecking }
}

# AC3: the #8076 AC3 omission control still refuses at the renamed refusal
# line with live root: the real guard refuses an exact-identity live owner at
# the line and with the string the control pins, the omitted guard (the #8102
# AC3 mutant) passes the same owner, and no control is pinned to the retired
# refusal. The 7906 discriminator chain that produced mutant 070 completes on a
# vacant fleet in this file's dispatch carrier run below.
function Test-TreeDeathOmissionStillRefuses {
  $test='tree-death-omission-still-refuses'
  $psm=Join-Path $PSScriptRoot 'landed-integration-evidence.psm1'
  $module=Import-Module $psm -Force -DisableNameChecking -PassThru
  $child=$null;$mutantDir=Join-Path ([IO.Path]::GetTempPath()) ("8103-omission-"+[guid]::NewGuid().ToString('N'))
  try {
    $child=Start-8103IdleChild
    $exact=New-8103Owner $PID (Get-Process -Id $PID).StartTime $child.Id $child.StartTime
    $refusal=Get-8103GuardError { Assert-InterruptedIntegrationTreeDead $exact }
    Assert-True ($refusal.message-ceq'INTEGRATION_RESUME_PRIOR_OWNER: live root') "$test`: exact-identity live owner refuses live root (actual: $($refusal.message))"
    $site=[regex]::Match([string]$refusal.stack,'landed-integration-evidence\.psm1: line ([0-9]+)')
    Assert-True $site.Success "$test`: the refusal stack names the guard line ($($refusal.stack))"
    $line=[int]$site.Groups[1].Value
    $psmLines=[IO.File]::ReadAllLines($psm)
    Assert-True ($psmLines[$line-1].Trim()-ceq"throw 'INTEGRATION_RESUME_PRIOR_OWNER: live root'") "$test`: psm1:$line is the live root refusal"
    $callSites=@(1..$psmLines.Count|Where-Object{$psmLines[$_-1]-ceq'  Assert-InterruptedIntegrationTreeDead $sources.owner # RESUME_GUARD_PRIOR_DEATH'})
    Assert-True ($callSites.Count-eq1) "$test`: one RESUME_GUARD_PRIOR_DEATH call site"
    $support=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1'))
    foreach($pin in @("if(`$pair.mutantError-cne'INTEGRATION_RESUME_PRIOR_OWNER: live root'-or`$pair.mutantStack-notmatch'landed-integration-evidence\.psm1: line $line'){","throw '8076 AC3 NOT_CONSTRUCTIBLE: held wait-omitted mutant did not refuse at psm1:$line'","guardRefusalSite='landed-integration-evidence.psm1:$line'","guardCallSite='landed-integration-evidence.psm1:$($callSites[0])'")){
      Assert-True ([regex]::Matches($support,[regex]::Escape($pin)).Count-eq1) "$test`: the #8076 AC3 omission control pins $pin"
    }
    Assert-True (-not$support.Contains('live, reused or ambiguous root')) "$test`: no control is pinned to the retired refusal"
    $text=[IO.File]::ReadAllText($psm)
    Assert-True ([regex]::Matches($text,[regex]::Escape($treeGuard8102Needle)).Count-eq1) "$test`: the omission needle is unique"
    New-Item -ItemType Directory -Path $mutantDir|Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ownership.ps1') -Destination $mutantDir
    [IO.File]::WriteAllText((Join-Path $mutantDir 'landed-integration-evidence.psm1'),$text.Replace($treeGuard8102Needle,$treeGuard8102),[Text.UTF8Encoding]::new($false))
    Remove-Module $module -Force
    $mutant=Import-Module (Join-Path $mutantDir 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
    $omitted=Get-8103GuardError { Assert-InterruptedIntegrationTreeDead $exact }
    Remove-Module $mutant -Force
    Assert-True ($null-eq$omitted) "$test`: the omitted guard passes the same live owner, so the control discriminates (actual: $($omitted.message))"
    Write-Output "PASS 8103 $test refusal=live-root line=$line callSite=$($callSites[0]) omitted-guard=passes control=pinned"
  } finally { Stop-8103IdleChild $child; Import-Module $psm -Force -DisableNameChecking; if(Test-Path -LiteralPath $mutantDir){Remove-Item -LiteralPath $mutantDir -Recurse -Force -ErrorAction SilentlyContinue} }
}

Test-ReusedPidRootIsDeadByIdentity
Test-TreeDeathOmissionStillRefuses

Test-TimedFixtureUnderFleetLoadMeasuresLoad
Test-RegressionUnderLoadIsNotMasked
Invoke-7963ResumeCarriers @('native-branch')
} finally {
  Exit-RoutingDataTestScope $routingTestScope
}
