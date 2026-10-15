[CmdletBinding()]
param([string]$SourceRevision = '')

# Focused, hermetic collector coverage. No live ownership or GitHub probes.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot 'velocity-metrics.ps1')
if ($SourceRevision) {
  $source = (& git -C (Split-Path $PSScriptRoot -Parent) show "${SourceRevision}:.orchestrator/velocity-metrics.ps1") -join "`n"
  if ($LASTEXITCODE -ne 0) { throw 'cannot read requested baseline' }
  # Dynamic scriptblocks have no file-backed PSScriptRoot. Bind dependency
  # paths explicitly while retaining each complete baseline function/param list.
  . ([scriptblock]::Create($source.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")))
}
$failures = [Collections.Generic.List[string]]::new()
function Assert-Gap([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output "PASS $Name" }
  catch { $failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function Save-Json([string]$Path, $Value) {
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30 -Compress))
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('velocity-floor-gaps-' + [guid]::NewGuid().ToString('N'))
$runtime = Join-Path $root '.orchestrator'
$null = [IO.Directory]::CreateDirectory($runtime)
$now = [datetime]::UtcNow
# The collector reads the capacity forecast; never the machine's AgentPools state.
$savedRoutingRoot = $env:CHASE_SETS_ROUTING_DATA_ROOT
$env:CHASE_SETS_ROUTING_DATA_ROOT = $root
try {
  [IO.File]::WriteAllText((Join-Path $runtime 'platform-handoff.md'), '')
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-ownership.ps1'), @'
function Get-LiveDispatchOwnership($RuntimeRoot, $TempRoot, $ContainerRoot, [int]$MaxRecords=64, [int]$DeadlineMs=5000) {
  $count = @([IO.Directory]::EnumerateFiles($RuntimeRoot, 'dispatch-launch-*.json')).Count
  $script:ownershipBounds = @{deadline=$DeadlineMs; cap=$MaxRecords; candidates=$count}
  $status = if ($DeadlineMs -ge 30000 -and $MaxRecords -ge $count) { 'ok' } else { 'partial' }
  if ($script:forcePartial) { $status = 'partial' }
  [pscustomobject]@{health=[pscustomobject]@{status=$status};activeLanes=@()}
}
'@)
  foreach ($i in 1..70) { Save-Json (Join-Path $runtime "dispatch-launch-$i.json") @{} }
  $null = Update-MergeHoldState -Path (Join-Path $runtime 'merge-hold-state.json') -Action Initialize -ExpectedRevision 0 -Reconciled -Now $now.AddMinutes(-10)
  $script:largeConnections = $true
  $script:forcePartial = $false
  $script:control = 'complete'
  $script:tailRequests = @()
  function Connection([string]$Name, [int]$Offset=0) {
    $total = if ($script:control -ceq 'page-cap') { 4000 } elseif ($script:largeConnections) { 32 } else { 1 }
    $end = [math]::Min($Offset + 30, $total)
    $nodes = @($Offset..($end-1) | ForEach-Object {
      if ($Name -ceq 'labels') { [pscustomobject]@{name=$(if ($_ -eq 31) {'status:parked'} else {"label-$_"})} }
      else { [pscustomobject]@{id="blocker-$_";state=$(if ($_ -eq 31) {'OPEN'} else {'CLOSED'})} }
    })
    if ($Offset -gt 0) {
      switch ($script:control) {
        'moving' { $total++ }
        'duplicate' { $nodes[0] = if ($Name -ceq 'labels') {[pscustomobject]@{name='label-0'}} else {[pscustomobject]@{id='blocker-0';state='CLOSED'}} }
        'truncated' { $nodes = @($nodes | Select-Object -First 1) }
        'page-cap' { $total=4000; $end=$Offset+30 }
      }
    } elseif ($script:control -ceq 'page-cap') { $total=4000 }
    $next = if ($script:control -ceq 'stuck' -and $Offset) { [string]$Offset } else { [string]$end }
    $more = $end -lt $total
    if ($script:control -ceq 'stuck' -and $Offset) { $more=$true }
    if ($script:control -ceq 'pageinfo-bool' -and $Offset) { $more='false' }
    if ($script:control -ceq 'missing-page-info') { return [pscustomobject]@{totalCount=$total;nodes=$nodes} }
    [pscustomobject]@{totalCount=$total;nodes=$nodes;pageInfo=[pscustomobject]@{hasNextPage=$more;endCursor=$next}}
  }
  function IssueNode([int]$Number) {
    [pscustomobject]@{number=$Number;title='Synthetic product';body='';labels=(Connection 'labels');blockedBy=(Connection 'blockedBy');milestone=[pscustomobject]@{number=148;state='OPEN';description='<!-- outcome: {"track":"commerce","status":"committed"} -->'}}
  }
  function Invoke-VelocityGraphQL([string]$Query, [hashtable]$Variables) {
    if ($Query -match '(labels|blockedBy)\(first:30,after:\$c\)') {
      $name=$Matches[1]
      Assert-Gap ($Query.Contains('pageInfo{hasNextPage endCursor}')) 'tail query lacks pageInfo'
      $script:tailRequests += $name
      $number=[int][regex]::Match($Query, 'issue\(number:(\d+)\)').Groups[1].Value
      if ($script:control -ceq 'unresolved') { $number++ }
      return [pscustomobject]@{repository=[pscustomobject]@{issue=[pscustomobject]@{number=$number; $name=(Connection $name ([int]$Variables.c))}}}
    }
    if ($Query.Contains('issues(states:OPEN,first:100,after:$c)')) {
      return [pscustomobject]@{repository=[pscustomobject]@{issues=[pscustomobject]@{totalCount=1;nodes=@((IssueNode 4062));pageInfo=[pscustomobject]@{hasNextPage=$false;endCursor=$null}}}}
    }
    if ($Query.Contains('issueOrPullRequest(number:')) { return [pscustomobject]@{repository=[pscustomobject]@{i4063=(IssueNode 4063)}} }
    if ($Query.Contains('i4062: issue(number:')) { return [pscustomobject]@{repository=[pscustomobject]@{i4062=(IssueNode 4062)}} }
    if ($Variables.ContainsKey('q')) {
      $nodes=@()
      if ($Variables.q -like '*is:merged*' -and $script:referenceMode -cne 'none') {
        $references=@(if ($script:referenceMode -ceq 'nested') { IssueNode 4062 })
        $nodes=@([pscustomobject]@{number=9001;body='Refs #4062';repository=[pscustomobject]@{nameWithOwner='chase-sets/chase-sets'};mergedAt=$now.AddHours(-1).ToString('o');closingIssuesReferences=[pscustomobject]@{totalCount=$references.Count;nodes=$references}})
      }
      if ($Variables.q -like '*is:pr is:open*' -and $script:referenceMode -ceq 'open') {
        $nodes=@([pscustomobject]@{number=9002;body='Refs #4062';repository=[pscustomobject]@{nameWithOwner='chase-sets/chase-sets'};headRefOid=('a'*40);closingIssuesReferences=[pscustomobject]@{totalCount=1;nodes=@((IssueNode 4062))};commits=[pscustomobject]@{nodes=@([pscustomobject]@{commit=[pscustomobject]@{oid=('a'*40)}})}})
      }
      return [pscustomobject]@{search=[pscustomobject]@{issueCount=$nodes.Count;nodes=$nodes;pageInfo=[pscustomobject]@{hasNextPage=$false;endCursor=$null}}}
    }
    throw 'unexpected synthetic GraphQL query'
  }
  function Collect {
    $script:tailRequests=@()
    Get-VelocityFacts $root $now
  }
  $script:referenceMode='none'
  [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'), '')
  Case 'blockers-and-labels-over-30' {
    $facts=Collect
    $issue=$facts.productIssues[0]
    Assert-Gap ($issue.labels.Count -eq 32 -and $issue.openBlockers -eq 1 -and $issue.terminalState -ceq 'parked') "tail inputs missing: labels=$($issue.labels.Count), blockers=$($issue.openBlockers)"
    Assert-Gap (@($facts.gaps | Where-Object {$_ -like '*issue*'}).Count -eq 0) ($facts.gaps -join ',')
    Assert-Gap (($script:tailRequests -join ',') -ceq 'labels,blockedBy') 'both connections must advance independently'
  }
  Case 'reporting-ownership-bounds' {
    $script:largeConnections=$false
    $facts=Collect
    Assert-Gap ($script:ownershipBounds.deadline -ge 30000 -and $script:ownershipBounds.cap -ge 70) "reporting bounds too small: deadline=$($script:ownershipBounds.deadline), cap=$($script:ownershipBounds.cap)"
    Assert-Gap ($facts.complete -and $facts.ownershipStatus -ceq 'ok') ($facts.gaps -join ',')
  }
  Case 'capacity-forecast-captured-once' {
    $script:largeConnections=$false
    $forecastPath = Join-Path $root 'capacity-forecast.json'
    function Set-Forecast($Value) {
      if ($null -eq $Value) { if (Test-Path -LiteralPath $forecastPath) { Remove-Item -LiteralPath $forecastPath } }
      elseif ($Value -is [string]) { [IO.File]::WriteAllText($forecastPath, $Value) }
      else { [IO.File]::WriteAllText($forecastPath, ($Value | ConvertTo-Json -Depth 20)) }
    }
    function New-Forecast([string]$Mode='active', [string]$Codex='normal', [string]$Claude='spend', [int]$StaleMinutes=9) {
      [ordered]@{format='capacity-forecast/v1';mode=$Mode;generatedAt=$now.AddMinutes(-1).ToString('o');staleAfter=$now.AddMinutes($StaleMinutes).ToString('o')
        decisionDigest='0123456789abcdef';providers=[ordered]@{codex=@{state=$Codex};claude=@{state=$Claude}};balance=@{toward='claude';steps=1}}
    }
    try {
      $valid = New-Forecast
      Set-Forecast $valid
      $facts = Collect
      $p = $facts.capacityForecast
      Assert-Gap ($facts.complete -and $p.status -ceq 'in-force' -and $p.decisionDigest -ceq '0123456789abcdef' -and $p.generatedAt -ceq $valid.generatedAt -and
        $p.staleAfter -ceq $valid.staleAfter -and $p.providers.codex.state -ceq 'normal' -and $p.providers.claude.state -ceq 'spend') "collector projection incomplete: $($p | ConvertTo-Json -Depth 8 -Compress)"
      Assert-Gap ((Get-VelocityReport $facts $now @()).metrics.floorMode -ceq 'spend') 'collected in-force spend forecast is spend at the collector instant'
      $factsPath = Join-Path $root 'captured.facts.json'
      [IO.File]::WriteAllText($factsPath, ($facts | ConvertTo-Json -Depth 64))
      function Replay([datetime]$At) { (& (Join-Path $PSScriptRoot 'velocity-metrics.ps1') -ContainerRoot $root -FactsPath $factsPath -NowUtc $At.ToString('o') -NoRecord) | ConvertFrom-Json -DateKind String }
      Set-Forecast (New-Forecast -Claude 'normal')
      Assert-Gap ((Replay $now).metrics.floorMode -ceq 'spend') 'FactsPath replay never rereads a changed forecast'
      Set-Forecast $null
      Assert-Gap ((Replay $now).metrics.floorMode -ceq 'spend') 'FactsPath replay never rereads a removed forecast'
      Assert-Gap ((Replay $now.AddMinutes(9)).metrics.floorMode -ceq 'two-lane') 'FactsPath replay at staleAfter is two-lane'
      $controls = [ordered]@{
        absent = $null
        stale = (New-Forecast -StaleMinutes 0)
        malformed = '{synthetic malformed forecast'
        shadow = (New-Forecast -Mode 'shadow')
        unknown = (New-Forecast -Codex 'unknown')
      }
      foreach ($status in $controls.Keys) {
        Set-Forecast $controls[$status]
        $facts = Collect
        $report = Get-VelocityReport $facts $now @()
        Assert-Gap ($facts.complete -and $facts.capacityForecast.status -ceq $status -and $report.metrics.floorMode -ceq 'two-lane') "$status forecast is captured as $status, two-lane, with no facts gap: $($facts.capacityForecast.status)"
      }
      Assert-Gap ($null -eq $facts.capacityForecast.providers -and $null -eq $facts.capacityForecast.decisionDigest) 'unknown projection never invents provider states'
    } finally { Set-Forecast $null }
  }
  if (-not $SourceRevision) {
    Case 'referenced-issue-label-pagination' {
      $script:largeConnections=$true
      foreach ($mode in @('nested','body','open')) {
        $script:referenceMode=$mode
        $facts=Collect
        Assert-Gap $facts.complete "$mode references incomplete: $($facts.gaps -join ',')"
        if ($mode -cne 'open') { Assert-Gap ($facts.merges[0].issues[0].labels.Count -eq 32) "$mode merged labels incomplete" }
      }
      $script:referenceMode='none'
      Save-Json (Join-Path $runtime 'dispatch-log.jsonl') @{ts=$now.ToString('o');kind='lane-complete';issue=4063;lane='synthetic-closed'}
      $facts=Collect
      Assert-Gap ($facts.complete -and $facts.issueDetails.'4063'.labels.Count -eq 32) "dispatch issue labels incomplete: $($facts.gaps -join ',')"
      [IO.File]::WriteAllText((Join-Path $runtime 'dispatch-log.jsonl'), '')
    }
    Case 'connection-fail-closed-controls' {
      $gapCodes=[ordered]@{
        moving='census-changed'
        duplicate='identity-invalid'
        truncated='incomplete'
        stuck='cursor-invalid'
        'page-cap'='page-cap-exceeded'
        'pageinfo-bool'='page-info-invalid'
        unresolved='unresolved'
      }
      foreach ($control in $gapCodes.Keys) {
        $script:control=$control
        $facts=Collect
        $expectedGap="product-issues: issue-connection-$($gapCodes[$control]):4062:labels"
        Assert-Gap (-not $facts.complete -and $facts.gaps -ccontains $expectedGap) "$control must fail closed with ${expectedGap}; actual: $($facts.gaps -join ',')"
      }
      $script:control='complete'
      $script:largeConnections=$false
      $script:forcePartial=$true
      $facts=Collect
      Assert-Gap (-not $facts.complete -and $facts.gaps -contains 'ownership-not-complete') 'larger budget must not waive partial ownership'
      $script:forcePartial=$false
    }
    Case 'missing-page-info-retains-existing-gap-names' {
      $script:largeConnections=$true
      $script:control='missing-page-info'
      $script:referenceMode='body'
      $facts=Collect
      Assert-Gap (-not $facts.complete -and $facts.gaps -contains 'issue-connections-incomplete:4062' -and $facts.gaps -contains 'merged-issue-labels-incomplete:4062') 'existing incomplete-connection gap names must remain intact'
      $script:control='complete'
      $script:referenceMode='none'
    }
    Case 'single-page-mutant-killed' {
      $saved=(Get-Item Function:Complete-VelocityIssueConnections).ScriptBlock
      try {
        function Complete-VelocityIssueConnections($Issue, $Connections) { }
        $script:largeConnections=$true
        $facts=Collect
        Assert-Gap ($facts.productIssues[0].labels.Count -eq 30 -and $facts.productIssues[0].openBlockers -eq 0 -and -not $facts.complete) 'single-page mutant must reproduce the missing tail and refusal'
        Write-Output 'KILLED single-page mutant'
      } finally { Set-Item Function:Complete-VelocityIssueConnections $saved }
    }
    Case 'reporting-deadline-mutant-killed' {
      $saved=(Get-Item Function:Get-VelocityFacts).ScriptBlock
      try {
        Assert-Gap ($saved.ToString().Contains('-DeadlineMs 30000')) 'deadline mutant anchor absent'
        Set-Item Function:Get-VelocityFacts ([scriptblock]::Create($saved.ToString().Replace('-DeadlineMs 30000','-DeadlineMs 5000')))
        $script:largeConnections=$false
        $facts=Collect
        Assert-Gap (-not $facts.complete -and $facts.gaps -contains 'ownership-not-complete' -and $script:ownershipBounds.deadline -eq 5000) 'deadline mutant must reproduce partial ownership'
        Write-Output 'KILLED reporting-deadline mutant'
      } finally { Set-Item Function:Get-VelocityFacts $saved }
    }
  }
} finally {
  $env:CHASE_SETS_ROUTING_DATA_ROOT = $savedRoutingRoot
  $resolved=[IO.Path]::GetFullPath($root)
  if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe fixture cleanup path' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
if ($failures.Count) { throw ($failures -join "`n") }
Write-Output 'PASS velocity-floor-gaps'
