function Test-DispatchLedgerConsumerCompatibility {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Consumer,[Parameter(Mandatory)][string]$RuntimeRoot)
  # All consumer suites exercise the same immutable LF/CRLF snapshot against
  # the actual implementation-base parser, not a second expected-value parser.
  $root=Split-Path -Parent $RuntimeRoot
  $temporary=Join-Path ([IO.Path]::GetTempPath()) ('ledger-compat-'+[guid]::NewGuid().ToString('N'))
  $baseline=$null
  try {
    [void][IO.Directory]::CreateDirectory($temporary)
    $path=Join-Path $temporary 'dispatch-log.jsonl'
    $text="{`"kind`":`"dispatch`",`"issue`":985,`"lane`":`"synthetic`"}`r`n`n{`"kind`":`"landed`",`"issue`":985,`"pr`":985,`"head`":`"$('a'*40)`"}`n"
    [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false))
    $baselineSource=@(& git -C $root show 'f9f3a83a22b74484436519e3d29581efb8077e1d:.orchestrator/review-head-contract.psm1')
    if ($LASTEXITCODE -ne 0) { throw 'compatibility baseline unavailable' }
    $modulePath=Join-Path $temporary 'implementation-base.psm1'
    Copy-Item -LiteralPath (Join-Path $RuntimeRoot 'routing-data.ps1') -Destination $temporary
    Copy-Item -LiteralPath (Join-Path $RuntimeRoot 'dispatch-ledger-reader.psm1') -Destination $temporary
    [IO.File]::WriteAllLines($modulePath,$baselineSource,[Text.UTF8Encoding]::new($false))
    $baseline=Import-Module $modulePath -Force -PassThru -DisableNameChecking
    $before=& $baseline {param($p) Read-ExactHeadReviewHistory -Path $p} $path
    Import-Module (Join-Path $RuntimeRoot 'review-head-contract.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $RuntimeRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
    $exact=Read-ExactHeadReviewHistory -Path $path
    $owned=dispatch-ledger-reader\Read-DispatchCountHistory -Path $path
    foreach ($emitBom in @($false,$true)) {
      $bomPath=Join-Path $temporary "bom-$emitBom.jsonl"
      [IO.File]::WriteAllText($bomPath,$text,[Text.UTF8Encoding]::new($emitBom))
      $oldBom=& $baseline {param($p) Read-ExactHeadReviewHistory -Path $p} $bomPath
      $newBom=dispatch-ledger-reader\Read-DispatchCountHistory -Path $bomPath
      if (-not $newBom.complete -or $newBom.audit.parsedRows -ne 2 -or
          ($newBom.rows | ConvertTo-Json -Depth 30 -Compress) -cne ($oldBom.rows | ConvertTo-Json -Depth 30 -Compress) -or
          ($newBom.audit | ConvertTo-Json -Compress) -cne ($oldBom.audit | ConvertTo-Json -Compress)) {
        throw "$Consumer BOM=$emitBom first-row preservation failed"
      }
    }
    $query=& {
      param($runtime,$p)
      . (Join-Path $runtime 'dispatch-count-history.ps1') -Library -RuntimeRoot $runtime
      Read-DispatchCountHistory -Path $p
    } $RuntimeRoot $path
    if ($Consumer -eq 'board') {
      . (Join-Path $RuntimeRoot 'board-reconcile.ps1') -FunctionsOnly
      $oldSource=(@(& git -C $root show 'f9f3a83a22b74484436519e3d29581efb8077e1d:.orchestrator/board-reconcile.ps1') -join "`n")
      if ($LASTEXITCODE -ne 0) { throw 'board implementation-base oracle unavailable' }
      $tokens=$null;$errors=$null
      $ast=[Management.Automation.Language.Parser]::ParseInput($oldSource,[ref]$tokens,[ref]$errors)
      $function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-BoardHistory'},$true)
      if ($errors.Count -or -not $function) { throw 'board oracle shape unavailable' }
      $body=$function.Body.Extent.Text
      $oracle=[scriptblock]::Create('param([string]$Path)'+"`n"+$body.Substring(1,$body.Length-2))
      $oldBoard=& $oracle $path
      $newBoard=Get-BoardHistory $path
      foreach ($field in @('rows','specs','errors','count','indexes','unlinkedSpecs')) {
        if (($oldBoard[$field] | ConvertTo-Json -Depth 50 -Compress) -cne ($newBoard[$field] | ConvertTo-Json -Depth 50 -Compress)) { throw "board reduction compatibility failed: $field" }
      }
    }
    if ($Consumer -eq 'velocity') { . (Join-Path $RuntimeRoot 'velocity-metrics.ps1') }
    foreach ($history in @($exact,$owned,$query)) {
      if (-not $history.complete -or ($history.rows | ConvertTo-Json -Depth 30 -Compress) -cne ($before.rows | ConvertTo-Json -Depth 30 -Compress) -or
          ($history.audit | ConvertTo-Json -Compress) -cne ($before.audit | ConvertTo-Json -Compress)) { throw "$Consumer snapshot/row/hash/global-line compatibility failed" }
      if ($history.cursor -ne [Text.Encoding]::UTF8.GetByteCount($text) -or $history.snapshotLines -ne 3 -or $history.partialTrailingRow) { throw "$Consumer cursor contract failed" }
      $oldReduction=Reduce-ExactHeadReview -Pr 985 -CurrentHead ('a'*40) -History $before
      $newReduction=Reduce-ExactHeadReview -Pr 985 -CurrentHead ('a'*40) -History $history
      if (($oldReduction | ConvertTo-Json -Depth 40 -Compress) -cne ($newReduction | ConvertTo-Json -Depth 40 -Compress)) { throw "$Consumer review/landing reduction changed" }
      $oldAuthority=Reduce-LandedIntegrationAuthority -History $before -Pr 985 -Branch 'synthetic' -Head ('a'*40)
      $newAuthority=Reduce-LandedIntegrationAuthority -History $history -Pr 985 -Branch 'synthetic' -Head ('a'*40)
      if (($oldAuthority | ConvertTo-Json -Depth 40 -Compress) -cne ($newAuthority | ConvertTo-Json -Depth 40 -Compress)) { throw "$Consumer landed reduction changed" }
      $decisions=& {
        param($runtime,$old,$new)
        . (Join-Path $runtime 'dispatch-count-history.ps1') -Library -RuntimeRoot $runtime
        @((Get-DispatchCountDecision $old 985 open clear),(Get-DispatchCountDecision $new 985 open clear))
      } $RuntimeRoot $before $history
      if (($decisions[0] | ConvertTo-Json -Depth 20 -Compress) -cne ($decisions[1] | ConvertTo-Json -Depth 20 -Compress)) { throw "$Consumer dispatch/query reduction changed" }
      if ($Consumer -eq 'velocity') {
        $oldVelocity=Get-VelocityDispatchRows @($before.rows) -HistoryRows
        $newVelocity=Get-VelocityDispatchRows @($history.rows) -HistoryRows
        if (($oldVelocity | ConvertTo-Json -Depth 30 -Compress) -cne ($newVelocity | ConvertTo-Json -Depth 30 -Compress)) { throw 'velocity dispatch projection changed' }
      }
    }
    # Malformed rows, decoded duplicate names and missing paths never become
    # successful empty-history authority through either compatibility adapter.
    foreach ($invalid in @('{broken', '{"a":1,"\u0061":2}')) {
      [IO.File]::WriteAllText($path,$invalid+"`n")
      foreach ($history in @((Read-ExactHeadReviewHistory -Path $path),(dispatch-ledger-reader\Read-DispatchCountHistory -Path $path))) {
        if ($history.complete -or $history.reason -cne 'HISTORY_MALFORMED') { throw "$Consumer malformed refusal lost" }
      }
    }
    if ((Read-ExactHeadReviewHistory -Path (Join-Path $temporary 'missing')).complete) { throw "$Consumer missing refusal lost" }
    Write-Output "PASS sole-reader compatibility consumer=$Consumer baseline=f9f3a83 snapshots=query,review,owner reductions=review,landing,landed rawSha256/globalLine=identical"
  } finally {
    if ($baseline) { Remove-Module $baseline }
    $full=[IO.Path]::GetFullPath($temporary)
    if ((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-compat-*') { throw 'unsafe compatibility cleanup' }
    Remove-Item -LiteralPath $full -Recurse -Force
  }
}
