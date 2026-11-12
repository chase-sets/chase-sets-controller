[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-history-checkpoint.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('checkpoint-projection-private-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$failures=[Collections.Generic.List[string]]::new()
$checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Json($Value){
  $context=[Microsoft.PowerShell.Commands.JsonObject+ConvertToJsonContext]::new(1032,$false,$true)
  return [Microsoft.PowerShell.Commands.JsonObject]::ConvertToJson($Value,[ref]$context)
}
$cases=[ordered]@{
  ordinary='{"attemptId":"a","nested":{"flag":true},"items":[1,2]}'
  rounded='{"n":1.0000000000000001}'
  fractional='{"n":9007199254740993.5}'
  integer='{"n":9223372036854775809}'
  exponent='{"n":1e400,"negativeZero":-0.0}'
  singleton='[1]'
  empty='[]'
  nestedArrays='[[1],[2,3],[]]'
  singletonNested='[[1,2]]'
  emptyNested='[[]]'
  scalar='true'
  null='null'
  string='"value"'
}
foreach($depth in @(62,65,101,200,1020,1024)){$cases['depth'+$depth]=('{"x":'*$depth)+'0'+('}'*$depth)}
try {
  foreach($case in $cases.GetEnumerator()){
    try {
      $directory=Join-Path $root $case.Key;[void][IO.Directory]::CreateDirectory($directory)
      $path=Join-Path $directory 'dispatch-log.jsonl'
      [IO.File]::WriteAllText($path,$case.Value+"`n",[Text.UTF8Encoding]::new($false))
      $history=Read-DispatchCountHistory $path
      Assert ($history.complete -and $history.rows.Count -eq 1) 'sole owner refused fixture'
      $publish=Publish-DispatchHistoryCheckpoint $path $history
      Assert $publish.published ("owner-valid publication refused: "+$publish.reason)
      $read=Read-DispatchHistoryCheckpoint $path
      Assert ($read.state -ceq 'valid') ("checkpoint read refused: "+$read.reason)
      Assert ((Json $read.checkpoint.rows) -ceq (Json $history.rows)) 'ordered row projection changed'
      Assert ((Json $read.checkpoint.audit) -ceq (Json $history.audit)) 'audit changed'
      Assert ($read.checkpoint.cursor -eq $history.cursor -and $read.checkpoint.snapshotHash -ceq $history.snapshotHash) 'snapshot identity changed'
      $expected=$history.rows[0].value;$actual=$read.checkpoint.rows[0].value
      if($null -ne $expected){Assert ($actual.GetType() -eq $expected.GetType()) 'projection CLR type changed'}
      if($case.Key -ceq 'ordinary'){Assert ($null -ne $actual.PSObject.Properties['attemptId']) 'contract property lookup changed'}
      Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'equal-cursor idempotent publication refused'
      Assert ((Publish-DispatchHistoryCheckpoint $path $history -ReducerVersion 'next/v2').published) 'equal-cursor version transition refused'
      Assert ((Read-DispatchHistoryCheckpoint $path).state -ceq 'version') 'version mismatch accepted'
      Assert ((Read-DispatchHistoryCheckpoint $path -ReducerVersion 'next/v2').state -ceq 'valid') 'versioned projection refused'
      $checkpoint=Get-DispatchHistoryCheckpointPath $path
      $before=[IO.File]::ReadAllText($checkpoint)
      $history.rows[0].value='forged projection'
      Assert (-not (Publish-DispatchHistoryCheckpoint $path $history).published) 'mismatched raw/value published'
      Assert ([IO.File]::ReadAllText($checkpoint) -ceq $before) 'refusal overwrote checkpoint'
      $checks++;"PASS checkpoint projection $($case.Key)"
    } catch {$failures.Add("$($case.Key): $($_.Exception.Message)");"FAIL checkpoint projection $($case.Key): $($_.Exception.Message)"}
  }
  if($failures.Count){throw ($failures -join '; ')}
  "PASS checkpoint projection cases=$checks ownerTypes=retained rawIdentity=retained depth=1024"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
  if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'checkpoint-projection-private-*'){throw 'cleanup escaped private fixture'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
