$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'dispatch-history-checkpoint.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('checkpoint-prefix-private-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Clone($Value){return ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Value -Depth 30 -Compress) -DateKind String}
$bad=[Collections.Generic.List[string]]::new()
try {
  $path=Join-Path $root 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($path,"`n"+'{"kind":"dispatch","lane":"a"}'+"`r`n  `n"+'{"kind":"dispatch","lane":"b"}'+"`n",[Text.UTF8Encoding]::new($false))
  $prefix=Read-DispatchCountHistory $path
  Assert ($prefix.complete -and $prefix.rows.Count -eq 2 -and $prefix.snapshotLines -eq 4) 'bad prefix fixture'
  Assert ((Publish-DispatchHistoryCheckpoint $path $prefix).published) 'checkpoint seed refused'
  [IO.File]::AppendAllText($path,'{"kind":"dispatch","lane":"c"}'+"`n",[Text.UTF8Encoding]::new($false))
  $full=Read-DispatchCountHistory $path
  $cached=(Read-DispatchHistoryCheckpoint $path).checkpoint
  $metrics=$null
  $fold=Read-DispatchCountHistory $path -PrefixHistory $cached -ReadMetrics ([ref]$metrics)
  Assert ($fold.complete -and $fold.rows.Count -eq 3 -and $metrics.tailParsedRows -eq 1 -and $metrics.readPasses -eq 1) 'valid checkpoint fold refused or reparsed prefix'
  Assert ((ConvertTo-Json $fold.rows -Depth 30 -Compress) -ceq (ConvertTo-Json $full.rows -Depth 30 -Compress)) 'valid fold projection changed'
  foreach($cap in @(0,1,2,3,4)){
    $capped=Read-DispatchCountHistory $path -PrefixHistory $cached -MaxRows $cap
    if($capped.complete -or $capped.reason -cne 'HISTORY_TRUNCATED' -or -not $capped.audit.truncated){$bad.Add('cap'+$cap);"FAIL prefix binding valid cap=$cap mislabeled"}
  }
  foreach($mutation in @('drop','shift','coherent-raw','hash','length','extra')){
    $forged=Clone $cached
    switch($mutation){
      drop {$forged.rows=@($forged.rows[0]);$forged.audit.rows=1;$forged.audit.parsedRows=1}
      shift {$forged.rows[0].line=1}
      coherent-raw {
        $forged.rows[0].raw=$forged.rows[0].raw.Replace('"a"','"z"');$forged.rows[0].value.lane='z'
        $bytes=[Text.Encoding]::UTF8.GetBytes($forged.rows[0].raw)
        $forged.rows[0].byteLength=$bytes.Length
        $forged.rows[0].rawSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
      }
      hash {$forged.rows[0].rawSha256='a'*64}
      length {$forged.rows[0].byteLength++}
      extra {$extra=Clone $forged.rows[0];$extra.line=3;$forged.rows=@($forged.rows[0],$extra,$forged.rows[1]);$forged.audit.rows=3;$forged.audit.parsedRows=3}
    }
    $metrics=$null
    $result=Read-DispatchCountHistory $path -PrefixHistory $forged -ReadMetrics ([ref]$metrics)
    if($result.complete -or $result.reason -cne 'HISTORY_UNTERMINATED_OR_MOVED' -or $result.rows.Count -ne 0){$bad.Add($mutation);"FAIL prefix binding $mutation accepted or wrong refusal"}
    else {
      Assert ($result.snapshotHash -ceq $full.snapshotHash -and $result.snapshotLength -eq $full.snapshotLength) 'refusal lost captured snapshot identity'
      Assert ($metrics.readPasses -eq 1 -and $metrics.bytesRead -eq $full.audit.bytes -and $metrics.tailParsedRows -le 1) 'binding reread payload or parsed prefix'
      "PASS prefix binding $mutation"
    }
  }
  if($bad.Count){throw ('unbound checkpoint prefix: '+($bad -join ','))}
  'PASS checkpoint prefix binding mutations=6 oneCapturedPass=true tailOnly=true'
} finally {
  $full=[IO.Path]::GetFullPath($root)
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
  if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'checkpoint-prefix-private-*'){throw 'cleanup escaped private fixture'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
