$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-unterminated-lines-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $path=Join-Path $root 'dispatch-log.jsonl'
  $unicode=[string][char]0xe9+[char]0x20ac+[char]::ConvertFromUtf32(0x1f600)
  $row='{"kind":"dispatch","issue":1}'
  $tail='{"kind":"dispatch","issue":2,"note":"'+$unicode+'"}'
  foreach($bom in @($false,$true)) {
    foreach($text in @($tail,($row+"`n"+$tail),($row+"`r`n"+$tail),($row+"`n`r"+$tail))) {
      [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($bom))
      $bytes=[IO.File]::ReadAllBytes($path)
      $expected=@(Get-Content -LiteralPath $path)
      $lines=@(Read-DispatchLedgerLines -Path $path -IncludeUnterminated)
      Check ($expected.Count -gt 0 -and ($lines|ConvertTo-Json -Compress) -ceq ($expected|ConvertTo-Json -Compress)) 'explicit raw-line projection matches Get-Content including UTF8 tail'
      $snapshot=Read-DispatchLedgerSnapshot -Path $path -IncludeUnterminated
      Check ($snapshot.complete -and $snapshot.partialTrailingRow -and $snapshot.cursor -eq $bytes.Length -and
        $snapshot.snapshotLength -eq $bytes.Length -and [Convert]::ToHexString($snapshot.bytes) -ceq [Convert]::ToHexString($bytes)) 'raw snapshot covers captured EOF, preserves exact bytes and reports unterminated tail'
      $boundary=0
      for($i=0;$i -lt $bytes.Length;$i++){if($bytes[$i] -eq 10){$boundary=$i+1}}
      $history=Read-DispatchCountHistory -Path $path
      $default=Read-DispatchLedgerSnapshot -Path $path
      Check ($history.complete -and $history.cursor -eq $boundary -and $history.partialTrailingRow -and
        $default.cursor -eq $boundary -and $default.snapshotLength -eq $boundary) 'default authority/count projection still excludes every unterminated tail'
      $strict=Read-DispatchLedgerSnapshot -Path $path -RequireTerminated
      Check (-not $strict.complete -and $strict.reason -ceq 'HISTORY_UNTERMINATED_OR_MOVED') 'strict termination refusal unchanged'
      $failure=''
      try {Read-DispatchLedgerLines -Path $path -RequireTerminated -IncludeUnterminated|Out-Null}catch{$failure=$_.Exception.Message}
      Check ($failure -match 'INCOMPATIBLE_HISTORY_TERMINATION_OPTIONS') 'raw option cannot relax strict termination'
      $held=[IO.File]::Open($path,'Open','ReadWrite','None')
      try {
        $failure=''
        try {Read-DispatchLedgerLines -Path $path -IncludeUnterminated|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -match 'HISTORY_UNREADABLE') 'raw option does not bypass real owner sharing refusal'
      } finally {$held.Dispose()}
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToHexString($bytes)) 'all reads/refusals leave exact bytes untouched'
    }
  }
  [IO.File]::WriteAllText($path,$row,[Text.UTF8Encoding]::new($false))
  $writer=[IO.File]::Open($path,'Open','Write','ReadWrite')
  try {
    [void]$writer.Seek(0,[IO.SeekOrigin]::End)
    Check (@(Read-DispatchLedgerLines -Path $path -IncludeUnterminated)[0] -ceq $row) 'real append writer may remain open during raw snapshot'
    $writer.WriteByte(10);$writer.Flush($true)
    $history=Read-DispatchCountHistory -Path $path -RequireTerminated
    Check ($history.complete -and $history.rows.Count -eq 1 -and -not $history.partialTrailingRow) 'same writer commits tail with LF for strict authority reader'
  } finally {$writer.Dispose()}
  $capped=Read-DispatchLedgerSnapshot -Path $path -MaxBytes 1 -IncludeUnterminated
  Check (-not $capped.complete -and $capped.reason -ceq 'HISTORY_TRUNCATED' -and $capped.bytes.Length -eq 0) 'raw projection cannot relax the byte cap'
  [IO.File]::WriteAllBytes($path,[byte[]]@(123,34,195))
  $invalid=Read-DispatchLedgerSnapshot -Path $path -IncludeUnterminated
  Check (-not $invalid.complete -and $invalid.reason -ceq 'HISTORY_UNREADABLE') 'raw tail still refuses incomplete UTF8 scalars'
  [IO.File]::WriteAllBytes($path,[byte[]]@())
  Check (@(Read-DispatchLedgerLines -Path $path -IncludeUnterminated).Count -eq 0) 'empty raw projection unchanged'
  Write-Output "PASS ledger-reader-unterminated-lines checks=$checks explicitRawOnly=true defaultCountPrefixUnchanged=true strictConflict=REFUSED"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-unterminated-lines-*'){throw 'unsafe unterminated fixture cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
