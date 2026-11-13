$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-query-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $source=Join-Path $PSScriptRoot 'dispatch-count-history.ps1'
  $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$errors)
  Check ($errors.Count -eq 0) 'runtime history source parses'
  Check (-not (Test-Path (Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1'))) 'retired catalog query stays absent'
  $redirect=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-DispatchCountHistory'},$true)
  $calls=@($redirect.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'dispatch-ledger-reader\Read-DispatchCountHistory'},$true))
  Check ($calls.Count -eq 1 -and $redirect.Extent.Text -notmatch 'IO\.File|GetTempFileName|ReadExactly|ConvertFrom-Json') 'runtime adapter delegates without a second reader'
  $payload='{"kind":"dispatch","issue":985}'+[char]10
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.',
    'dispatch-log.jsonl ','dispatch-log.jsonl:query','dispatch-log.jsonl.:query')
  foreach($layout in @('source','installed')) {
    $runtime=Join-Path $root $layout
    [void][IO.Directory]::CreateDirectory($runtime)
    $entry=Join-Path $runtime 'dispatch-count-history.ps1'
    Copy-Item -LiteralPath $source,(Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $runtime
    . $entry -Library
    foreach($alias in $aliases) {
      $path=Join-Path $runtime $alias
      [IO.File]::WriteAllText($path,$payload,[Text.UTF8Encoding]::new($false))
      $before=[IO.File]::ReadAllBytes($path)
      $history=Read-DispatchCountHistory $path -RequireTerminated
      Check ($history.complete -and $history.rows.Count -eq 1 -and $history.rows[0].value.issue -eq 985) "canonical dispatch history/$layout/$alias"
      Check ($history.snapshotLength -eq $before.Length -and $history.snapshotLines -eq 1 -and -not $history.partialTrailingRow) 'captured boundary preserved'
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToHexString($before)) 'history bytes unchanged'
    }
    $path=Join-Path $runtime 'dispatch-log.jsonl'
    [IO.File]::WriteAllText($path,$payload,[Text.UTF8Encoding]::new($false))
    $prefix=Read-DispatchCountHistory $path -RequireTerminated
    [IO.File]::AppendAllText($path,$payload,[Text.UTF8Encoding]::new($false))
    $history=Read-DispatchCountHistory $path -PrefixHistory $prefix -RequireTerminated
    Check ($history.complete -and $history.rows.Count -eq 2 -and $history.snapshotLines -eq 2) "prefix fold survives relocation/$layout"
    [IO.File]::WriteAllText($path,$payload+$payload.TrimEnd([char]10),[Text.UTF8Encoding]::new($false))
    $partial=Read-DispatchCountHistory $path
    Check ($partial.complete -and $partial.partialTrailingRow) 'permissive snapshot reports partial tail'
    Check ((Get-DispatchCountDecision $partial 985 open clear).state -ceq 'UNKNOWN') 'partial history never grants a decision'
    Check (-not (Read-DispatchCountHistory $path -RequireTerminated).complete) 'logger termination requirement preserved'
    [IO.File]::WriteAllText($path,('{broken'+[char]10),[Text.UTF8Encoding]::new($false))
    Check (-not (Read-DispatchCountHistory $path).complete) 'malformed history refuses'

    $missing=Join-Path $root "$layout-missing-owner"
    [void][IO.Directory]::CreateDirectory($missing)
    $missingEntry=Join-Path $missing 'dispatch-count-history.ps1'
    Copy-Item -LiteralPath $source -Destination $missingEntry
    $failure=''
    try { & {param($e,$p). $e -Library; Read-DispatchCountHistory $p} $missingEntry $path|Out-Null } catch {$failure=$_.Exception.Message}
    Check ($failure -match 'dispatch-ledger-reader.psm1') 'missing sibling owner refuses despite loaded modules; no runtime is borrowed'
  }
  Write-Output "PASS ledger-reader-query-paths checks=$checks runtimeAdapter=canonical layouts=2 aliases=7 prefix=preserved partial=refused missingOwners=REFUSED retiredQuery=absent"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-query-paths-*'){throw 'unsafe query path fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
