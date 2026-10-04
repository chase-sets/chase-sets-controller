$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope

$wrapperSourcePath = Join-Path $PSScriptRoot "invoke-fleet-exclusive-gate.ps1"
$moduleSourcePath = Join-Path $PSScriptRoot "fleet-exclusive-admission.psm1"
$ownershipSourcePath = Join-Path $PSScriptRoot "dispatch-ownership.ps1"
$leaseContractSourcePath = Join-Path $PSScriptRoot "lease-contract.psm1"
$verifierSourcePath = Join-Path $PSScriptRoot "invoke-heavy-verifier.ps1"

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

$controls = [Collections.Generic.List[string]]::new()
function Pass-Control([string]$Name) {
  if ($controls.Contains($Name)) { throw "duplicate named control: $Name" }
  $controls.Add($Name)
  Write-Output "CONTROL|$Name|PASS"
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("invoke-fleet-exclusive-gate-test-" + [guid]::NewGuid().ToString("N"))
$testRootResolved = [IO.Path]::GetFullPath($testRoot)
$tempResolved = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
$controller = Join-Path $testRoot "controller"
$runtime = Join-Path $controller ".orchestrator"
$lane = Join-Path $controller "lane-88"
$holder = "holder-wrapper-test-0001"
$attempt = "7203-wrapper-test-a1"
$branch = "codex/wrapper-test"
$head = $null
$wrapper = Join-Path $runtime "invoke-fleet-exclusive-gate.ps1"
$resultCounter = 0

function Invoke-Git([string]$Root, [string[]]$Arguments) {
  $output = @(& git -C $Root @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "git failed in $Root`: git $($Arguments -join ' ')`n$($output -join "`n")" }
  ($output -join "`n").Trim()
}

function Write-OrchestrationLease([datetimeoffset]$At = [datetimeoffset]::UtcNow) {
  $now = $At.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
  $value = [ordered]@{
    version = "orchestration-lease/v2"
    holder = $holder
    harness = "codex"
    model = "gpt-5.6-sol"
    effort = "high"
    acquiredAt = $now
    renewedAt = $now
  }
  [IO.File]::WriteAllText(
    (Join-Path $runtime "lease.json"),
    ($value | ConvertTo-Json -Compress),
    [Text.UTF8Encoding]::new($false)
  )
}

function Invoke-Wrapper(
  [int]$Issue = 7203,
  [string]$LeaseHolder = $holder,
  [string]$Attempt = $attempt,
  [string]$Worktree = $lane,
  [string]$Branch = $branch,
  [string]$ClaimedHead = $head,
  [string]$Gate = "test:scripts",
  [int]$VerifierExit = 0,
  [hashtable]$ExtraEnvironment = @{}
) {
  $script:resultCounter++
  $stem = "wrapper-$($script:resultCounter)"
  $stdout = Join-Path $testRoot "$stem.out"
  $stderr = Join-Path $testRoot "$stem.err"
  $result = Join-Path $testRoot "$stem.json"
  $environment = @{
    FLEET_TEST_RESULT = $result
    FLEET_TEST_EXIT = $VerifierExit.ToString()
  }
  foreach ($key in $ExtraEnvironment.Keys) { $environment[$key] = $ExtraEnvironment[$key] }
  $arguments = @(
    "-NoProfile", "-NonInteractive", "-File", $wrapper,
    "-Issue", $Issue.ToString(), "-LeaseHolder", $LeaseHolder,
    "-Attempt", $Attempt, "-Worktree", $Worktree, "-Branch", $Branch,
    "-ClaimedHead", $ClaimedHead, "-Gate", $Gate
  )
  $process = Start-Process -FilePath (Join-Path $PSHOME "pwsh.exe") -ArgumentList $arguments `
    -Environment $environment -WindowStyle Hidden -Wait -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  [pscustomobject]@{
    exitCode = $process.ExitCode
    stdout = $(if (Test-Path $stdout) { [IO.File]::ReadAllText($stdout) } else { "" })
    stderr = $(if (Test-Path $stderr) { [IO.File]::ReadAllText($stderr) } else { "" })
    resultPath = $result
    result = $(if (Test-Path $result) { Get-Content -LiteralPath $result -Raw | ConvertFrom-Json -DateKind String } else { $null })
  }
}

function Assert-NoAdmissionResidue([string]$Message) {
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $runtime "fleet-admission.d"))) "$Message leaves no fleet lease"
}

function Commit-WrapperSource([string]$Source, [string]$Message) {
  [IO.File]::WriteAllText($wrapper, $Source, [Text.UTF8Encoding]::new($false))
  Invoke-Git $controller @("add", ".orchestrator/invoke-fleet-exclusive-gate.ps1") | Out-Null
  Invoke-Git $controller @("commit", "--quiet", "-m", $Message) | Out-Null
}

try {
  [IO.Directory]::CreateDirectory($runtime) | Out-Null
  foreach ($file in @(
    $moduleSourcePath,
    $ownershipSourcePath,
    $leaseContractSourcePath,
    (Join-Path $PSScriptRoot 'routing-data.ps1')
  )) {
    Copy-Item -LiteralPath $file -Destination (Join-Path $runtime (Split-Path -Leaf $file))
  }
  Copy-Item -LiteralPath $wrapperSourcePath -Destination $wrapper
  $heavyStub = @'
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Gate,
  [Parameter(Mandatory)][string]$Worktree,
  [Parameter(Mandatory)][string]$Lane,
  [Parameter(Mandatory)][string]$Branch,
  [Parameter(Mandatory)][string]$ClaimedHead
)
$leasePath=Join-Path $PSScriptRoot 'fleet-admission.d/owner.json'
$lease=Get-Content -LiteralPath $leasePath -Raw|ConvertFrom-Json -DateKind String
$token=$env:CHASE_SETS_FLEET_ADMISSION_TOKEN
$tokenSha=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$token)))).ToLowerInvariant()
[ordered]@{leasePresent=(Test-Path -LiteralPath $leasePath);tokenPresent=(-not[string]::IsNullOrWhiteSpace($token));tokenMatches=($tokenSha-ceq$lease.ownerTokenSha256);schemaVersion=$lease.schemaVersion;leaseHolder=$lease.leaseHolder;issue=$lease.issue;attempt=$lease.attempt;host=$lease.host;controllerRoot=$lease.controllerRoot;controllerRuntimeRoot=$lease.controllerRuntimeRoot;controllerHead=$lease.controllerHead;worktree=$lease.worktree;branch=$lease.branch;claimedHead=$lease.claimedHead;gate=$lease.gate;state=$lease.state;childPid=$lease.childPid;arguments=[ordered]@{Gate=$Gate;Worktree=$Worktree;Lane=$Lane;Branch=$Branch;ClaimedHead=$ClaimedHead}}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $env:FLEET_TEST_RESULT
exit [int]$env:FLEET_TEST_EXIT
'@
  [IO.File]::WriteAllText((Join-Path $runtime "invoke-heavy-verifier.ps1"), $heavyStub, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $controller ".gitignore"), "/lane-88/`n/.orchestrator/*.json`n/.orchestrator/*/`n", [Text.UTF8Encoding]::new($false))
  Invoke-Git $controller @("init", "--initial-branch=main", "--quiet") | Out-Null
  Invoke-Git $controller @("config", "user.name", "Fleet Wrapper Test") | Out-Null
  Invoke-Git $controller @("config", "user.email", "fleet-wrapper@example.invalid") | Out-Null
  Invoke-Git $controller @("add", ".") | Out-Null
  Invoke-Git $controller @("commit", "--quiet", "-m", "controller fixture") | Out-Null

  [IO.Directory]::CreateDirectory($lane) | Out-Null
  Invoke-Git $lane @("init", "--initial-branch=$branch", "--quiet") | Out-Null
  Invoke-Git $lane @("config", "user.name", "Fleet Wrapper Lane") | Out-Null
  Invoke-Git $lane @("config", "user.email", "fleet-wrapper-lane@example.invalid") | Out-Null
  [IO.File]::WriteAllText((Join-Path $lane "seed.txt"), "seed", [Text.UTF8Encoding]::new($false))
  Invoke-Git $lane @("add", "seed.txt") | Out-Null
  Invoke-Git $lane @("commit", "--quiet", "-m", "lane fixture") | Out-Null
  $head = (Invoke-Git $lane @("rev-parse", "HEAD")).ToLowerInvariant()
  Write-OrchestrationLease

  $success = Invoke-Wrapper -VerifierExit 37
  Assert-True ($success.exitCode -eq 37) "wrapper preserves verifier exit code 37 (exit=$($success.exitCode); stderr=$($success.stderr); stdout=$($success.stdout))"
  Assert-True ($success.result.leasePresent -and $success.result.tokenPresent -and $success.result.tokenMatches) "verifier starts only after exact lease and child token publication"
  Assert-True ($success.result.schemaVersion -ceq "fleet-exclusive-admission/v1" -and
    $success.result.leaseHolder -ceq $holder -and [int]$success.result.issue -eq 7203 -and
    $success.result.attempt -ceq $attempt -and
    $success.result.controllerRoot -ceq [IO.Path]::GetFullPath($controller).TrimEnd("\", "/") -and
    $success.result.controllerRuntimeRoot -ceq [IO.Path]::GetFullPath($runtime).TrimEnd("\", "/") -and
    $success.result.worktree -ceq [IO.Path]::GetFullPath($lane).TrimEnd("\", "/") -and
    $success.result.branch -ceq $branch -and $success.result.claimedHead -ceq $head -and
    $success.result.gate -ceq "test:scripts" -and $success.result.state -ceq "running") "lease authenticates every wrapper identity field"
  Assert-True ($success.result.arguments.Lane -ceq $attempt -and
    $success.result.arguments.ClaimedHead -ceq $head) "wrapper passes the fixed identity vector to the unchanged verifier interface"
  Assert-NoAdmissionResidue "exit-code passthrough control"
  Pass-Control "wrapper authenticates identity, publishes lease first, and preserves verifier exit code"

  foreach ($row in @(
    [pscustomobject]@{name="host identity holder";invoke={ Invoke-Wrapper -LeaseHolder "holder-wrong-0002" };match="host identity record"},
    [pscustomobject]@{name="issue";invoke={ Invoke-Wrapper -Issue 7204 };match="attempt does not bind"},
    [pscustomobject]@{name="attempt";invoke={ Invoke-Wrapper -Attempt "7204-wrapper-test-a1" };match="attempt does not bind"},
    [pscustomobject]@{name="branch";invoke={ Invoke-Wrapper -Branch "codex/wrong" };match="branch identity mismatch"},
    [pscustomobject]@{name="claimed head";invoke={ Invoke-Wrapper -ClaimedHead ("0"*40) };match="claimed immutable head mismatch"}
  )) {
    $receipt = & $row.invoke
    Assert-True ($receipt.exitCode -eq 73 -and $receipt.stderr -like "*$($row.match)*") "$($row.name) mismatch denies with exit 73"
    Assert-True ($null -eq $receipt.result) "$($row.name) mismatch never starts verifier"
    Assert-NoAdmissionResidue "$($row.name) mismatch"
    Pass-Control "wrapper refuses mismatched $($row.name)"
  }

  $foreign = Join-Path $testRoot "foreign-lane"
  [IO.Directory]::CreateDirectory($foreign) | Out-Null
  $foreignReceipt = Invoke-Wrapper -Worktree $foreign
  Assert-True ($foreignReceipt.exitCode -eq 73 -and $foreignReceipt.stderr -like "*direct child*") "foreign root denies before Git or verifier"
  Assert-NoAdmissionResidue "foreign root"
  Pass-Control "wrapper refuses foreign worktree root"

  [IO.File]::WriteAllText((Join-Path $lane "dirty.txt"), "dirty", [Text.UTF8Encoding]::new($false))
  $dirty = Invoke-Wrapper
  Assert-True ($dirty.exitCode -eq 73 -and $dirty.stderr -like "*not clean*") "dirty exact-head worktree denies"
  Remove-Item -LiteralPath (Join-Path $lane "dirty.txt") -Force
  Assert-NoAdmissionResidue "dirty worktree"
  Pass-Control "wrapper refuses dirty candidate worktree"

  $originalWrapper = [IO.File]::ReadAllText($wrapper)
  [IO.File]::WriteAllText($wrapper, $originalWrapper + "`n", [Text.UTF8Encoding]::new($false))
  $movedController = Invoke-Wrapper
  Assert-True ($movedController.exitCode -eq 73 -and $movedController.stderr -like "*controller release identity mismatch*") "moved controller member denies"
  [IO.File]::WriteAllText($wrapper, $originalWrapper, [Text.UTF8Encoding]::new($false))
  Assert-NoAdmissionResidue "moved controller"
  Pass-Control "wrapper refuses moved controller release bytes"

  $nested = Invoke-Wrapper -ExtraEnvironment @{ CHASE_SETS_FLEET_ADMISSION_TOKEN = "synthetic-nested-token" }
  Assert-True ($nested.exitCode -eq 73 -and $nested.stderr -like "*nested fleet admission*") "nested invocation denies"
  Assert-NoAdmissionResidue "nested invocation"
  Pass-Control "wrapper refuses nested admission token"

  $wrapperCommand = Get-Command $wrapper
  Assert-True ($wrapperCommand.Parameters.Keys -cnotcontains "Command" -and
    $wrapperCommand.Parameters.Keys -cnotcontains "CommandPath" -and
    $wrapperCommand.Parameters.Keys -cnotcontains "ArgumentList") "wrapper exposes no arbitrary command parameter"
  $invalidGate = Invoke-Wrapper -Gate "synthetic-command"
  Assert-True ($invalidGate.exitCode -ne 0 -and $null -eq $invalidGate.result) "gate parameter binder refuses arbitrary command text"
  Assert-NoAdmissionResidue "arbitrary gate"
  Pass-Control "wrapper exposes only the closed gate inventory"

  Write-OrchestrationLease ([datetimeoffset]::UtcNow.AddDays(-30))
  $oldIdentity = Invoke-Wrapper
  Assert-True ($oldIdentity.exitCode -eq 0 -and $null -ne $oldIdentity.result) "old host identity record is admitted without freshness interpretation"
  Assert-NoAdmissionResidue "old host identity record"
  $identityAnchor = 'if ($orchestrationLease.status -cne "ok" -or $null -eq $orchestrationLease.record -or'
  $freshnessMutant = $identityAnchor + "`n      ([datetimeoffset]::UtcNow - [datetimeoffset]`$orchestrationLease.record.renewedAt).TotalMinutes -gt 60 -or"
  $candidateWrapper = [IO.File]::ReadAllText($wrapper)
  Assert-True ($candidateWrapper.Split([string[]]@($identityAnchor), [StringSplitOptions]::None).Count -eq 2) "freshness refusal mutant has one exact carrier"
  Commit-WrapperSource ($candidateWrapper.Replace($identityAnchor, $freshnessMutant)) "freshness refusal mutant"
  $freshnessRefusal = Invoke-Wrapper
  Assert-True ($freshnessRefusal.exitCode -eq 73 -and $null -eq $freshnessRefusal.result -and
    $freshnessRefusal.stderr -like "*host identity record*") "reintroduced freshness refusal is observably red"
  Commit-WrapperSource $candidateWrapper "restore age-neutral host identity admission"
  Write-OrchestrationLease
  Pass-Control "freshness-refusal mutant is killed while old identity remains admissible"

  $wrapperSource = [IO.File]::ReadAllText($wrapperSourcePath)
  foreach ($credentialNeedle in @("DIGITALOCEAN", "AWS_SECRET", "SPACES_SECRET", "GH_TOKEN", "GITHUB_TOKEN", "KUBECONFIG")) {
    Assert-True (-not $wrapperSource.Contains($credentialNeedle, [StringComparison]::OrdinalIgnoreCase)) "wrapper does not read credential surface $credentialNeedle"
  }
  Pass-Control "wrapper reads no provider or GitHub credential"

  $publishBlock = @'
  $fleetOwner = Enter-FleetExclusiveAdmission `
    -RuntimeRoot $runtimeRoot -LeaseHolder $LeaseHolder -Issue $Issue -Attempt $Attempt `
    -ControllerRoot $controllerRoot -ControllerHead $controllerHead -Worktree $worktreeFull `
    -Branch $Branch -ClaimedHead $ClaimedHead -Gate $Gate # FLEET_ADMISSION_GUARD_LEASE_PUBLISHED_BEFORE_CENSUS
'@
  $publishMutant = @'
  $mutantRecord = Get-ValidatedFleetAdmissionRecord $runtimeRoot
  $fleetOwner = [pscustomobject]@{runtimeRoot=$runtimeRoot;directory=(Join-Path $runtimeRoot "fleet-admission.d");recordPath=(Join-Path $runtimeRoot "fleet-admission.d/owner.json");token="mutant-unowned-token";record=$mutantRecord} # MUTANT_REMOVED_LEASE_PUBLICATION_BEFORE_CENSUS
'@
  Assert-True ([regex]::Matches($wrapperSource, [regex]::Escape($publishBlock)).Count -eq 1) "lease-publication mutant has one exact carrier"
  Import-Module (Join-Path $runtime "fleet-exclusive-admission.psm1") -Force -DisableNameChecking
  $foreignOwner = Enter-FleetExclusiveAdmission -RuntimeRoot $runtime -LeaseHolder $holder -Issue 7203 -Attempt $attempt `
    -ControllerRoot $controller -ControllerHead (Invoke-Git $controller @("rev-parse","HEAD")) -Worktree $lane `
    -Branch $branch -ClaimedHead $head -Gate "test:scripts"
  $controlWithLease = Invoke-Wrapper
  Assert-True ($controlWithLease.exitCode -eq 73 -and $null -eq $controlWithLease.result) "real wrapper refuses an already-live fleet lease"
  Commit-WrapperSource ($wrapperSource.Replace($publishBlock, $publishMutant)) "lease publication mutant"
  $publicationMutant = Invoke-Wrapper
  Assert-True ($publicationMutant.exitCode -eq 0 -and $null -ne $publicationMutant.result) "removing lease publication makes the real non-DryRun carrier observably unsafe (exit=$($publicationMutant.exitCode); stderr=$($publicationMutant.stderr); stdout=$($publicationMutant.stdout))"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $runtime "fleet-admission.d"))) "publication mutant consumed the foreign owner's lease and exposes the killed edge"
  Pass-Control "MUTANT_REMOVED_LEASE_PUBLICATION_BEFORE_CENSUS is killed by a real carrier"

  $firstCensus = @'
  Assert-FleetExclusiveLaneCensusVacant `
    -RuntimeRoot $runtimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $controllerRoot | Out-Null # FLEET_ADMISSION_GUARD_LANE_CENSUS_INSPECTION
'@
  $secondCensus = @'
  Assert-FleetExclusiveLaneCensusVacant `
    -RuntimeRoot $runtimeRoot -TempRoot ([IO.Path]::GetTempPath()) -ContainerRoot $controllerRoot | Out-Null # FLEET_ADMISSION_GUARD_LANE_CENSUS_REREAD
'@
  Assert-True ([regex]::Matches($wrapperSource, [regex]::Escape($firstCensus)).Count -eq 1 -and
    [regex]::Matches($wrapperSource, [regex]::Escape($secondCensus)).Count -eq 1) "census ordering seams each occur once"
  $instrumentedFirst = $firstCensus + "`n" + @'
  [IO.File]::WriteAllText((Join-Path $runtimeRoot "dispatch-launch-00000000-0000-0000-0000-000000000099.json"), "{}", [Text.UTF8Encoding]::new($false))
'@
  $instrumented = $wrapperSource.Replace($firstCensus, $instrumentedFirst)
  Commit-WrapperSource $instrumented "census reread control"
  $rereadControl = Invoke-Wrapper
  Assert-True ($rereadControl.exitCode -eq 73 -and $null -eq $rereadControl.result) "second census catches an owner appearing after first inspection (exit=$($rereadControl.exitCode); stderr=$($rereadControl.stderr); stdout=$($rereadControl.stdout))"
  Remove-Item -LiteralPath (Join-Path $runtime "dispatch-launch-00000000-0000-0000-0000-000000000099.json") -Force
  $rereadMutantSource = $instrumented.Replace($secondCensus, "  # MUTANT_REMOVED_LANE_CENSUS_REREAD`n")
  Commit-WrapperSource $rereadMutantSource "census reread mutant"
  $rereadMutant = Invoke-Wrapper
  Assert-True ($rereadMutant.exitCode -eq 0 -and $null -ne $rereadMutant.result) "removing opposite-side reread makes the real non-DryRun carrier observably unsafe"
  Remove-Item -LiteralPath (Join-Path $runtime "dispatch-launch-00000000-0000-0000-0000-000000000099.json") -Force
  Assert-NoAdmissionResidue "claimant ordering mutants"
  Pass-Control "MUTANT_REMOVED_LANE_CENSUS_REREAD is killed by a real carrier"

  Write-Output "RESIDUE|lease=0|lane=0"
  Write-Output "PASS fleet-exclusive wrapper identity, ordering, bypass, and verifier coverage ($($controls.Count) controls)"
} finally {
  if ((Split-Path -Parent $testRootResolved).TrimEnd("\", "/") -ne $tempResolved -or
      (Split-Path -Leaf $testRootResolved) -notlike "invoke-fleet-exclusive-gate-test-*") {
    throw "refusing unsafe fleet wrapper test cleanup target: $testRootResolved"
  }
  Remove-Item -LiteralPath $testRootResolved -Recurse -Force -ErrorAction SilentlyContinue
  Exit-RoutingDataTestScope $routingTestScope
}
