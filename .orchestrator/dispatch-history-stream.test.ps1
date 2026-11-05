$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('dispatch-history-stream-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$old=$null
try {
  [void][IO.Directory]::CreateDirectory($root)
  $before=& git -C (Split-Path -Parent $PSScriptRoot) show 'aa014ccc2026c339e3d09e598cfb5a343438d4c7:.orchestrator/dispatch-ledger-reader.psm1'
  Check ($LASTEXITCODE -eq 0) 'immutable pre-stream owner unavailable'
  $oldPath=Join-Path $root 'before.psm1'
  [IO.File]::WriteAllLines($oldPath,[string[]]$before,[Text.UTF8Encoding]::new($false))
  $old=Import-Module $oldPath -PassThru -DisableNameChecking
  $current=Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -PassThru -Force -DisableNameChecking
  $path=Join-Path $root 'dispatch-log.jsonl'
  $unicode=[string][char]0xe9+[char]0x20ac+[char]::ConvertFromUtf32(0x1f600)
  $row='{"kind":"dispatch","issue":126,"note":"'+$unicode+'"}'
  foreach($bom in @($false,$true)) {
    foreach($text in @('',"`n",$row+"`n",$row+"`r`n`n{}`r`r`n",$row+"`n"+'{"partial":',
        ('{"padding":"'+('x'*65520)+$unicode+'"}'+"`r`n"+$row+"`n"),
        ('{"padding":"'+('x'*65536)+'"}'+"`n"+$row+"`n"),
        '{"a":1,"\u0061":2}'+"`n",'{"x":[{"a":1,"a":2}]}'+"`n",'{broken'+"`n")) {
      [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($bom))
      foreach($strict in @($false,$true)) {
        $baseline=& $old {param($p,$s) Read-DispatchCountHistory -Path $p -RequireTerminated:$s} $path $strict
        $metrics=$null
        $actual=& $current {param($p,$s,$m) Read-DispatchCountHistory -Path $p -RequireTerminated:$s -ReadMetrics $m} $path $strict ([ref]$metrics)
        Check (($actual | ConvertTo-Json -Depth 50 -Compress) -ceq ($baseline | ConvertTo-Json -Depth 50 -Compress)) "baseline identity BOM=$bom strict=$strict length=$($text.Length)"
        Check ($metrics.readPasses -eq 1 -and $metrics.bytesRead -eq (Get-Item $path).Length -and
          $metrics.readOperations -eq [math]::Ceiling((Get-Item $path).Length/65536.0)) 'one captured payload pass, no second full scan'
        $expectedProbes=if(($strict -and $actual.partialTrailingRow) -or -not $text.Contains("`n")){0}else{1}
        Check ($metrics.boundaryProbes -eq $expectedProbes) 'original single LF boundary probe counted separately from payload pass'
      }
    }
  }
  [IO.File]::WriteAllText($path,$row+"`n",[Text.UTF8Encoding]::new($true))
  $prefix=& $current {param($p) Read-DispatchCountHistory -Path $p} $path
  foreach($extra in @("`n{}`r`n",$row+"`n")) {
    [IO.File]::AppendAllText($path,$extra,[Text.UTF8Encoding]::new($false))
    $metrics=$null
    $fold=& $current {param($p,$h,$m) Read-DispatchCountHistory -Path $p -PrefixHistory $h -ReadMetrics $m} $path $prefix ([ref]$metrics)
    $whole=& $current {param($p) Read-DispatchCountHistory -Path $p} $path
    Check ($fold.complete -and ($fold|ConvertTo-Json -Depth 50 -Compress) -ceq ($whole|ConvertTo-Json -Depth 50 -Compress)) 'prefix fold equals full row/hash/line/audit projection'
    Check ($metrics.readPasses -eq 1 -and $metrics.bytesRead -eq (Get-Item $path).Length -and
      $metrics.prefixRows -eq $prefix.audit.parsedRows -and
      $metrics.tailParsedRows -eq $whole.audit.parsedRows-$prefix.audit.parsedRows) 'prefix parsed once, only appended rows parsed next'
    $prefix=$fold
  }
  foreach($bounds in @(@{MaxRows=1},@{MaxBytes=1})) {
    $history=& $current {param($p,$b) Read-DispatchCountHistory -Path $p @b} $path $bounds
    Check (-not $history.complete -and $history.reason -ceq 'HISTORY_TRUNCATED') 'explicit diagnostic cap still refuses'
  }
  [IO.File]::WriteAllText($path,"[]`n",[Text.UTF8Encoding]::new($false))
  $moved=& $current {param($p,$h) Read-DispatchCountHistory -Path $p -PrefixHistory $h} $path $prefix
  Check (-not $moved.complete -and $moved.reason -ceq 'HISTORY_UNTERMINATED_OR_MOVED') 'rewound prefix refused'
  Write-Output "PASS streaming history checks=$checks immutableBaseline=aa014cc completeProjection=equal capturedPasses=1 explicitCaps=retained"
} finally {
  if($old){Remove-Module $old -Force}
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotmatch '^dispatch-history-stream-[a-f0-9]{32}$'){throw 'unsafe streaming fixture cleanup'}
  if(Test-Path $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
