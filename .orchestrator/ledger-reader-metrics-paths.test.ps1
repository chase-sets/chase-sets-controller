$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
function Write-Json([string]$Path,$Value) {
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-metrics-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $entry=Join-Path $PSScriptRoot 'velocity-metrics.ps1'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) 'metrics parses'
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $imports=@($ast.EndBlock.Statements|Where-Object{$_.Extent.Text -ceq $import})
  Check ($imports.Count -eq 1) 'literal unconditional sole-owner import'
  $reads=@($ast.FindAll({param($node)
    ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Content') -or
    ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -ceq 'ReadAllText')
  },$true))
  $paths=@('$path','$QualificationPath','$_.ownershipRecordPath','$FactsPath')
  Check ($reads.Count -eq $paths.Count) 'four native authority reads, not dispatch history'
  $historyCalls=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Read-ExactHeadReviewHistory'
  },$true))
  Check ($historyCalls.Count -eq 1 -and $historyCalls[0].Extent.Text -ceq "Read-ExactHeadReviewHistory -Path (Join-Path `$Container '.orchestrator/dispatch-log.jsonl')") 'actual dispatch history remains on snapshot API, not non-dispatch guard'
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $json='{"synthetic":"authority","items":[1,2]}'
  $positive=Join-Path $root 'authority.json';[IO.File]::WriteAllText($positive,$json)
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.',
    'dispatch-log.jsonl ','dispatch-log.jsonl:authority','dispatch-log.jsonl.:authority')
  for($index=0;$index -lt $reads.Count;$index++) {
    $read=$reads[$index]
    Check ($read.Extent.Text.Contains("(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $($paths[$index]))",[StringComparison]::Ordinal)) "frozen original path $($paths[$index])"
    Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "import precedes read $index"
    # Execute the exact production expression. Aliases do not exist, so an
    # owner error rather than a native missing-file error proves pre-I/O refusal.
    $probe=Join-Path $root 'probe.ps1'
    $bindings='$path=$QualificationPath=$FactsPath=$InputPath; $_=[pscustomobject]@{ownershipRecordPath=$InputPath}'
    [IO.File]::WriteAllText($probe,('param([string]$InputPath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
    Check ((& $probe $positive) -ceq $json) "native positive bytes $index"
    foreach($alias in $aliases) {
      $failure=''
      try { & $probe (Join-Path $root $alias)|Out-Null } catch {$failure=$_.Exception.Message}
      Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "pre-I/O refusal $index/$alias : $failure"
    }
  }

  . $entry
  $now=[datetime]'2030-01-01T12:00:00Z'
  $runtime=Join-Path $root '.orchestrator';[void][IO.Directory]::CreateDirectory($runtime)
  $register=Join-Path $runtime 'platform-handoff.md'
  [IO.File]::WriteAllText($register,@'
## 1. Ownership register
| Scope | Owner | Note |
| --- | --- | --- |
| every other chase-sets milestone, issue, PR, worktree, and the merge queue | incumbent | synthetic |
## 2. Other
'@)
  $failure=''
  try {Assert-VelocityLegacyPlatformRegisterInactive $root} catch {$failure=$_.Exception.Message}
  Check (-not $failure) 'real legacy-register body accepts genuine inactive Markdown'
  [IO.File]::WriteAllText($register,'invalid register')
  try {Assert-VelocityLegacyPlatformRegisterInactive $root} catch {$failure=$_.Exception.Message}
  Check ($failure -ceq 'LEGACY_PLATFORM_REGISTER_ACTIVE') 'real register preserves malformed fail-closed policy'

  # Only external authority providers are synthetic; exercise the complete real
  # collector body, including both JSON reads and ownership projection.
  $hold=[pscustomobject]@{schema='merge-hold-state/v1';revision=1;initializedAt='2030-01-01T12:00:00Z';records=@()}
  function Read-MergeHoldState { [pscustomobject]@{status='KNOWN';state=$hold} }
  function Get-VelocityLandingCandidates {
    [pscustomobject]@{productIssues=@();dispatchRows=@();legacyDispatchRows=@();nonPositiveIssueDispatchRows=@();authorityHistory=$null;gaps=@();candidates=@()}
  }
  function Invoke-VelocitySearch { @() }
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-ownership.ps1'),@'
function Get-LiveDispatchOwnership {
  [pscustomobject]@{health=[pscustomobject]@{status='ok'};activeLanes=@(
    [pscustomobject]@{lane='synthetic';laneRole='implementation';worktree='synthetic';head=('a'*40);launchId='synthetic-launch';ownershipRecordPath=$script:recordPath}
  )}
}
'@)
  $script:recordPath=Join-Path $root 'ownership.json'
  Write-Json $script:recordPath @{launchId='synthetic-launch';label='synthetic';head=('a'*40);recordedAt=$now.ToString('o');launcherStartIdentity='synthetic-start'}
  $qualification=Join-Path $root 'qualification.json'
  Write-Json $qualification @{kind='synthetic';candidates=@()}
  $facts=Get-VelocityFacts $root $now $qualification
  Check ($facts.complete -and $facts.dispatchQualificationSource.kind -ceq 'synthetic' -and $facts.activeLanes.Count -eq 1 -and $facts.activeLanes[0].launcherStartedAt -ceq 'synthetic-start') 'real collector preserves qualification and ownership JSON projection'
  $cliFacts=$facts.PSObject.Copy();$cliFacts.activeLanes=@()
  $factsPath=Join-Path $root 'facts.json';Write-Json $factsPath $cliFacts
  $report=(& $entry -ContainerRoot $root -FactsPath $factsPath -NoRecord -NowUtc $now.ToString('o'))|ConvertFrom-Json -DateKind String
  Check ($report.factsComplete -and $report.now -ceq '2030-01-01T12:00:00Z') "real CLI consumes genuine collected facts: $($report|ConvertTo-Json -Depth 10 -Compress)"

  $script:aliasReads=0;$script:deniedPath=''
  function Get-Content {
    param($LiteralPath,[switch]$Raw)
    if($LiteralPath -ceq $script:deniedPath){$script:aliasReads++;throw 'UNGUARDED_NATIVE_READ'}
    Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw
  }
  & {
    $registerAlias=''
    function Join-Path {
      param($Path,$ChildPath)
      if($registerAlias -and $ChildPath -ceq '.orchestrator/platform-handoff.md'){return $registerAlias}
      Microsoft.PowerShell.Management\Join-Path -Path $Path -ChildPath $ChildPath
    }
    function Test-Path {
      param($LiteralPath)
      if($registerAlias -and $LiteralPath -ceq $registerAlias){return $true}
      Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    foreach($alias in $aliases) {
      $registerAlias=Join-Path $root $alias;$failure=''
      try {Assert-VelocityLegacyPlatformRegisterInactive $root} catch {$failure=$_.Exception.Message}
      Check ($failure -ceq 'LEGACY_PLATFORM_REGISTER_ACTIVE') "real legacy body preserves fail-closed alias policy: $alias"
    }
  }
  foreach($alias in $aliases) {
    $script:deniedPath=Join-Path $root $alias
    $facts=Get-VelocityFacts $root $now $script:deniedPath
    Check ($facts.dispatchQualificationSource.reasonCode -ceq 'QUALIFICATION_SOURCE_UNREADABLE' -and $script:aliasReads -eq 0) "real qualification catch refuses before I/O: $alias"
    $savedRecord=$script:recordPath;$script:recordPath=$script:deniedPath
    $facts=Get-VelocityFacts $root $now $qualification
    Check (-not $facts.complete -and ($facts.gaps -join ',') -like '*ownership: *DISPATCH_LEDGER_OWNER_REQUIRED*' -and $facts.activeLanes.Count -eq 0 -and $script:aliasReads -eq 0) "real ownership catch refuses before I/O: $alias"
    $script:recordPath=$savedRecord
    $failure=''
    try {& $entry -ContainerRoot $root -FactsPath $script:deniedPath -NoRecord|Out-Null} catch {$failure=$_.Exception.Message}
    Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*' -and $script:aliasReads -eq 0) "real CLI refuses before I/O: $alias failure=$failure reads=$script:aliasReads"
  }
  Write-Output "PASS ledger-reader-metrics-paths checks=$script:checks"
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $resolved) -notlike 'ledger-metrics-paths-*'){throw 'unsafe metrics fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
