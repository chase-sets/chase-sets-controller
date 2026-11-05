$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-board-history-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  . (Join-Path $PSScriptRoot 'board-reconcile.ps1') -FunctionsOnly
  $candidate=${function:Get-BoardHistory}
  $source=(& git -C (Split-Path -Parent $PSScriptRoot) show 'f9f3a83a22b74484436519e3d29581efb8077e1d:.orchestrator/board-reconcile.ps1') -join "`n"
  Check ($LASTEXITCODE -eq 0) 'exact implementation-base board oracle available'
  $errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$null,[ref]$errors)
  $definition=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-BoardHistory'},$true)
  Check ($errors.Count -eq 0 -and $null -ne $definition) 'original board history function extracted'
  $body=$definition.Body.Extent.Text
  $oracle=[scriptblock]::Create('param([string]$Path)'+"`n"+$body.Substring(1,$body.Length-2))
  $row='{"kind":"dispatch","issue":985,"lane":"synthetic","transcript":"synthetic.jsonl"}'
  $cases=[ordered]@{empty='';terminated="$row`n";crlf="`r`n$row`r`n`r`n";
    validTail=$row;malformedTail='{broken';errorOrdinal="$row`n`n{broken`n{} `n";
    duplicateCase="{`"kind`":`"dispatch`",`"Kind`":`"landed`"}`n";array="[]`n"}
  $path=Join-Path $root 'dispatch-log.jsonl'
  foreach($bom in @($false,$true)) {
    foreach($name in $cases.Keys) {
      [IO.File]::WriteAllText($path,$cases[$name],[Text.UTF8Encoding]::new($bom))
      $before=[Convert]::ToHexString([IO.File]::ReadAllBytes($path))
      $expected=& $oracle $path
      $actual=& $candidate $path
      foreach($field in @('rows','records','specs','errors','count','indexes','unlinkedSpecs')) {
        Check (($actual[$field]|ConvertTo-Json -Depth 60 -Compress) -ceq ($expected[$field]|ConvertTo-Json -Depth 60 -Compress)) "original board field $field/$name/BOM=$bom"
      }
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq $before) "board read unchanged bytes $name/BOM=$bom"
    }
  }
  [IO.File]::WriteAllText($path,"$row`n",[Text.UTF8Encoding]::new($false))
  $expected=& $oracle $path
  $held=[IO.File]::Open($path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try {
    $blank=[Text.Encoding]::UTF8.GetBytes("`n")
    $held.Write($blank,0,$blank.Length);$held.Flush()
    $actual=& $candidate $path
    foreach($field in @('rows','specs','errors','count','indexes','unlinkedSpecs')) {
      Check (($actual[$field]|ConvertTo-Json -Depth 60 -Compress) -ceq ($expected[$field]|ConvertTo-Json -Depth 60 -Compress)) "genuine append writer retains original board $field"
    }
  } finally {$held.Dispose()}
  $current=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'board-reconcile.ps1'),[ref]$null,[ref]$errors)
  $history=$current.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-BoardHistory'},$true)
  $calls=@($history.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'dispatch-ledger-reader\Read-DispatchLedgerSnapshot'},$true))
  Check ($calls.Count -eq 1 -and $calls[0].Extent.Text -ceq 'dispatch-ledger-reader\Read-DispatchLedgerSnapshot -Path $Path -IncludeUnterminated') 'explicit sole-owner raw board policy'
  Check ($history.Extent.Text -notmatch 'Read-DispatchCountHistory|ReadAllText|ReadAllLines|StreamReader') 'no second canonical parser or native history read'
  Write-Output "PASS ledger-reader-board-history checks=$checks originalCases=16 genuineAppendWriter=True"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-board-history-*'){throw 'unsafe board history fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
