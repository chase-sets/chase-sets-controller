$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
$oldRoutingRoot=$env:CHASE_SETS_ROUTING_DATA_ROOT;$oldRoutingLkg=$env:CHASE_SETS_ROUTING_LKG_PATH
Import-Module (Join-Path $PSScriptRoot 'lease-contract.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'review-head-contract.psm1') -Force -DisableNameChecking
$root = Join-Path ([IO.Path]::GetTempPath()) ('astra-selection-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Assert-Throws([scriptblock]$Body, [string]$Pattern) {
  $caught = $null
  try { & $Body | Out-Null } catch { $caught = $_ }
  Assert-True ($null -ne $caught -and "$caught" -match $Pattern) "Expected refusal matching $Pattern; got $caught"
}
try {
  $matrix = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json') -Raw | ConvertFrom-Json
  $fixture=New-RoutingMatrixFixture -Root (Join-Path $root 'routing-state') -Snapshot $matrix
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$fixture.stateRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$fixture.lkgPath
  Assert-True ($matrix.coverage.configs -eq $matrix.configs.Count -and $matrix.coverage.cellsPossible -eq ($matrix.configs.Count * $matrix.dimensions.Count)) 'Matrix coverage matches registered configurations and dimensions'
  $astraConfigs = @($matrix.configs | Where-Object model -CEQ 'gpt-6-astra')
  Assert-True ($astraConfigs.Count -eq 5) 'Astra has exactly the five supported effort configurations'
  $astraBenchmarkCells = [Collections.Generic.List[string]]::new()
  Assert-True ($null -ne $matrix.PSObject.Properties['measuredAt'] -and $null -ne $matrix.measuredAt) 'The tracked matrix carries a generated measuredAt stamp'
  $withoutEffortEvidence = @($matrix.measuredAt.configsWithoutEffortEvidence)
  foreach ($config in $astraConfigs) {
    # Astra inherits nothing: no adjudicated baseline ever, and a measured block
    # only from its own exact configuration's runs (model-routing v4.13 keys
    # every measured block by model + effort), never a pooled or predecessor
    # figure. A configuration the refresh lists as having no effort-resolved
    # evidence must carry no block at all.
    Assert-True (-not $config.PSObject.Properties['adjudicated']) 'New Astra configuration inherits no adjudicated history'
    if ($config.PSObject.Properties['measured']) {
      Assert-True ([string]$config.measured.basis -ceq 'model+effort' -and [int]$config.measured.n -ge 1 -and $withoutEffortEvidence -cnotcontains $config.id) `
        'An Astra measured block is that exact configuration''s own generated evidence, never pooled or inherited'
    } else {
      Assert-True ($withoutEffortEvidence -ccontains $config.id) 'An Astra configuration without a measured block is listed as having no effort-resolved evidence'
    }
    foreach ($dimension in $matrix.dimensions) {
      $cell = $dimension.cells.PSObject.Properties[$config.id].Value
      Assert-True ($null -ne $cell) 'Every Astra configuration has an explicit cell in every dimension'
      if ($null -eq $cell.score) {
        Assert-True ($null -eq $cell.src) 'An unknown Astra cell has no evidence provenance'
      } else {
        Assert-True ($config.id -ceq 'gpt-6-astra/high' -and $cell.score -is [long] -and
          [long]$cell.score -ge -4 -and [long]$cell.score -le 3 -and
          [string]$cell.src -ceq 'B' -and -not [string]::IsNullOrWhiteSpace([string]$cell.ref)) `
          'A populated Astra cell is bounded authored benchmark evidence for exact gpt-6-astra/high, never inherited measurement'
        $astraBenchmarkCells.Add([string]$dimension.id)
      }
    }
  }
  Assert-True ((@($astraBenchmarkCells | Sort-Object)-join ',') -ceq 'agentic-coding,computer-use,debugging,long-horizon-execution') `
    'Astra authored benchmark evidence is confined to the four v4.12 capability cells'
  $lease = Join-Path $root 'lease.json'
  $at = [datetimeoffset]'2026-09-04T12:00:00Z'
  $a = Acquire-OrchestrationLease -Path $lease -Holder 'astra-synthetic-host' -Harness codex -Model gpt-6-astra -Effort high -NowUtc $at
  $r = Renew-OrchestrationLease -Path $lease -Holder 'astra-synthetic-host' -Harness codex -Model gpt-6-astra -Effort high -NowUtc $at.AddMinutes(1)
  Assert-True ($r.record.model -ceq 'gpt-6-astra' -and $r.record.acquiredAt -ceq $a.record.acquiredAt) 'Astra host identity renewal preserves acquiredAt'
  $takeover = Acquire-OrchestrationLease -Path $lease -Holder 'sol-synthetic-other' -Harness codex -Model gpt-6.1-sol -Effort high -NowUtc $at.AddMinutes(2)
  Assert-True ($takeover.previousHolder -ceq 'astra-synthetic-host' -and
    $takeover.record.holder -ceq 'sol-synthetic-other' -and
    $takeover.record.model -ceq 'gpt-6.1-sol') 'Host identity acquisition overwrites Astra and reports its previous holder'
  $astraReturn = Renew-OrchestrationLease -Path $lease -Holder 'astra-synthetic-host' -Harness codex -Model gpt-6-astra -Effort high -NowUtc $at.AddMinutes(3)
  Assert-True ($astraReturn.previousHolder -ceq 'sol-synthetic-other' -and
    $astraReturn.record.holder -ceq 'astra-synthetic-host' -and
    $astraReturn.record.acquiredAt -ceq $astraReturn.record.renewedAt) 'Cross-holder renewal overwrites identity and resets acquiredAt'
  foreach ($model in @('astra', 'gpt-6', 'gpt-6-astra-future', 'GPT-6-ASTRA')) {
    Assert-Throws { Acquire-OrchestrationLease -Path (Join-Path $root 'invalid.json') -Holder 'invalid-synthetic-host' -Harness codex -Model $model -Effort high -NowUtc $at } 'model'
  }
  Write-Output 'PASS Astra host identity overwrite, renewal, previous-holder, and alias rejection'

  $trialLease = Join-Path $root 'trial-lease.json'
  $trial = & (Join-Path $PSScriptRoot 'start-host-trial.ps1') -Arm astra-high -Lease $trialLease -Holder astra-synthetic-trial | Out-String
  Assert-True ($trial -match 'codex --model gpt-6-astra' -and $trial -match 'model_reasoning_effort=high') 'Astra host option prints exact model and effort'
  Assert-True (-not (Test-Path -LiteralPath $trialLease)) 'Selecting a host arm does not acquire a lease'

  $trialLog = Join-Path $root 'trial-events.jsonl'
  $registered = & (Join-Path $PSScriptRoot 'start-host-trial.ps1') -Arm astra-high -Lease $trialLease -Holder astra-synthetic-trial -Register -DispatchLog $trialLog | Out-String
  Assert-True (-not (Test-Path -LiteralPath $trialLog) -and $registered -match 'lease.ps1 records the live host identity') 'Host-arm registration wrote a retired note row instead of leaving identity to the lease'

  $log = Join-Path $root 'events.jsonl'
  $logger = Join-Path $PSScriptRoot 'log-event.ps1'
  $dispatch = & $logger -Log dispatch -Kind dispatch -Issue 7700 -Harness codex -Model gpt-6-astra -Effort high -Row 4 -Placement provisional -OutFile $log | ConvertFrom-Json
  Assert-True ($dispatch.model -ceq 'gpt-6-astra') 'Dispatch log preserves Astra'
  $receipt = & $logger -Log dispatch -Kind review-complete -Issue 7700 -Pr 7701 -Model gpt-6-astra -AuthorModel gpt-6.1-sol -Effort high -Row 11 -Placement provisional -Outcome PASS -ReviewContract review-contract/v2 -CompleteSweep -ReviewedHead ('a' * 40) -ReviewerAttempt synthetic-astra-review -AuthorAttempt synthetic-sol-author -Blocking 0 -Candidates 0 -NonBlocking 0 -RepairOwner none -OutFile $log | ConvertFrom-Json
  Assert-True ($receipt.model -ceq 'gpt-6-astra' -and $receipt.authorModel -ceq 'gpt-6.1-sol') 'Review retains distinct exact author and reviewer identities'
  $reduction = & (Join-Path $PSScriptRoot 'review-head-reducer.ps1') -Pr 7701 -CurrentHead ('a' * 40) -HistoryPath $log | ConvertFrom-Json
  Assert-True ($reduction.state -eq 'authorized') 'Astra exact-head PASS survives the review consumer allowlist'
  Assert-Throws { & $logger -Log dispatch -Kind dispatch -Model astra -OutFile $log } 'exact selectable'
  Write-Output 'PASS Astra host selection and dispatch/review logging'

  # Exercise the real dispatcher plan with a synthetic Git repository and no child launch.
  $worktree = Join-Path $root 'repo'
  & git init --quiet $worktree
  & git -C $worktree -c user.name=Synthetic -c user.email=synthetic@example.invalid commit --allow-empty -m synthetic --quiet
  if ($LASTEXITCODE -ne 0) { throw 'Synthetic Git fixture failed' }
  $prompt = Join-Path $root 'prompt.txt'
  [IO.File]::WriteAllText($prompt, 'Synthetic selection test. No model is launched.')
  $launcher = Join-Path $PSScriptRoot 'dispatch-lane.ps1'
  $exe = (Get-Process -Id $PID).Path
  foreach ($effort in @('low', 'medium', 'high', 'xhigh', 'max')) {
    $plan = & $launcher -Harness codex -Model gpt-6-astra -Effort $effort -LaneRole implementation -Row 4 -Placement measured -PromptFile $prompt -Worktree $worktree -Label "synthetic-astra6-$effort" -DryRun -ExecutablePath $exe -TestRuntimeRoot $root -TestTempRoot $root | ConvertFrom-Json
    Assert-True (@($plan.arguments) -ccontains 'gpt-6-astra') 'Dispatcher forwards exact Astra identity'
    Assert-True (@($plan.arguments) -ccontains "model_reasoning_effort=$effort") 'Dispatcher forwards supported effort'
  }
  Assert-Throws { & $launcher -Harness codex -Model gpt-6-astra -Effort minimal -PromptFile $prompt -Worktree $worktree -Label synthetic-minimal -DryRun -ExecutablePath $exe } 'EFFORT_NOT_ADMITTED'
  Assert-Throws { & $launcher -Harness claude -Model gpt-6-astra -Effort high -PromptFile $prompt -Worktree $worktree -Label synthetic-wrong-harness -DryRun -ExecutablePath $exe } 'MODEL_HARNESS_MISMATCH'
  Write-Output 'PASS Astra task dispatch and unsupported effort/harness rejection'
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT=$oldRoutingRoot;$env:CHASE_SETS_ROUTING_LKG_PATH=$oldRoutingLkg
  $resolved = [IO.Path]::GetFullPath($root)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing cleanup outside temporary root' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
