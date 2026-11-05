$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'routing-data.ps1') -Library
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-routing-history-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $path=Join-Path $root 'dispatch-log.jsonl'
  $registry='{"families":{"alpha":{"current":"model-a","historical":[],"provider":"codex"},"beta":{"current":"model-b","historical":[],"provider":"claude"}}}'|ConvertFrom-Json
  $row='{"kind":"dispatch","laneRole":"implementation","branch":"synthetic","issue":1,"model":"model-a"}'
  $second=$row.Replace('model-a','model-b')
  [IO.File]::WriteAllText($path,$row+"`n",[Text.UTF8Encoding]::new($false))
  $writer=[IO.File]::Open($path,'Open','Write','ReadWrite')
  try {
    $history=Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry
    Check ($history.complete -and ($history.models -join ',') -ceq 'model-a') 'complete author lineage remains readable while a genuine append writer holds the canonical ledger'
    [void]$writer.Seek(0,[IO.SeekOrigin]::End)
    $append=[Text.Encoding]::UTF8.GetBytes($second+"`n");$writer.Write($append,0,$append.Length);$writer.Flush($true)
    $history=Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry
    Check ($history.complete -and (@($history.models|Sort-Object) -join ',') -ceq 'model-a,model-b') 'same held writer persists another author without losing or duplicating lineage'
  } finally {$writer.Dispose()}
  $old=@(& git -C (Split-Path $PSScriptRoot -Parent) show 'd0b12cc7d6b0012e98c26d89c6530b6259286a89:.orchestrator/routing-data.ps1') -join "`n"
  Check ($LASTEXITCODE -eq 0) 'exact pre-change history oracle available'
  $errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($old,[ref]$null,[ref]$errors)
  $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CapacityAuthorHistory'},$true)
  Check ($errors.Count -eq 0 -and $null -ne $function) 'complete original history body selected'
  . ([scriptblock]::Create($function.Extent.Text.Replace('function Get-CapacityAuthorHistory {','function Get-OriginalCapacityAuthorHistory {')))
  foreach($bom in @($false,$true)) {
    foreach($text in @(($row+"`n"),($row+"`r`n`n"+$second+"`r`n"),($row+"`n"+$second),($row+"`n{malformed`n"),($row.Replace('"kind":','"KIND":"dispatch","kind":')+"`n"),'')) {
      [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($bom))
      $bytes=[IO.File]::ReadAllBytes($path)
      foreach($scope in @(@{Branch='synthetic'},@{Issue=1;Artifact='all'})) {
        $before=Get-OriginalCapacityAuthorHistory -Path $path @scope -Registry $registry
        $after=Get-CapacityAuthorHistory -Path $path @scope -Registry $registry
        Check (($before|ConvertTo-Json -Compress) -ceq ($after|ConvertTo-Json -Compress)) 'complete raw history fold preserves branch/issue results and strict unknowns against original native reader'
      }
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToHexString($bytes)) 'all projections leave exact bytes unchanged'
    }
  }
  [IO.File]::WriteAllText($path,$row+"`n",[Text.UTF8Encoding]::new($false))
  $held=[IO.File]::Open($path,'Open','ReadWrite','None')
  try {Check (-not (Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry).complete) 'exclusive real handle still produces UNKNOWN'} finally {$held.Dispose()}
  [IO.File]::WriteAllBytes($path,[byte[]]@(123,34,255,34,125,10))
  Check (-not (Get-CapacityAuthorHistory -Path $path -Branch synthetic -Registry $registry).complete) 'invalid UTF8 remains UNKNOWN'
  $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'routing-data.ps1'))
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$null)
  $function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-CapacityAuthorHistory'},$true)
  Check ($function.Extent.Text -match 'dispatch-ledger-reader\\Read-DispatchLedgerSnapshot -Path \$Path -RequireTerminated' -and $function.Extent.Text -notmatch 'StreamReader|BaseStream|IncludeUnterminated') 'canonical history has only a strict owner snapshot, never a non-dispatch guard or raw-tail opt-in'
  Write-Output "PASS ledger-reader-routing-history checks=$checks realHeldWriter=true originalFold=preserved strictUnknowns=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-routing-history-*'){throw 'unsafe routing history fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
