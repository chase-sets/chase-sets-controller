$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('dispatch-history-boundary-'+[guid]::NewGuid().ToString('N'))
$failures=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Message){if(-not $Condition){$failures.Add($Message);Write-Output "FAIL $Message"}else{Write-Output "PASS $Message"}}
$old=$null
try {
  [void][IO.Directory]::CreateDirectory($root)
  $text=& git -C (Split-Path -Parent $PSScriptRoot) show 'aa014ccc2026c339e3d09e598cfb5a343438d4c7:.orchestrator/dispatch-ledger-reader.psm1'
  if($LASTEXITCODE -ne 0){throw 'immutable boundary baseline unavailable'}
  $oldPath=Join-Path $root 'before.psm1'
  [IO.File]::WriteAllLines($oldPath,[string[]]$text,[Text.UTF8Encoding]::new($false))
  $old=Import-Module $oldPath -PassThru -DisableNameChecking
  $current=Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -PassThru -Force -DisableNameChecking
  $path=Join-Path $root 'dispatch-log.jsonl'
  [IO.File]::WriteAllBytes($path,[byte[]]@(255,10,123))
  foreach($strict in @($false,$true)) {
    $before=& $old {param($p,$s) Read-DispatchCountHistory -Path $p -RequireTerminated:$s} $path $strict
    $after=& $current {param($p,$s) Read-DispatchCountHistory -Path $p -RequireTerminated:$s} $path $strict
    Check (($before|ConvertTo-Json -Depth 20 -Compress) -ceq ($after|ConvertTo-Json -Depth 20 -Compress)) "invalid UTF8 plus partial tail strict=$strict preserves refusal metadata"
  }
  [IO.File]::WriteAllText($path,"{}`n",[Text.UTF8Encoding]::new($false))
  foreach($bad in @('hash','lines','rewind')) {
    $prefix=& $old {param($p) Read-DispatchCountHistory -Path $p} $path
    if($bad -ceq 'hash'){$prefix.snapshotHash='0'*64}
    elseif($bad -ceq 'lines'){$prefix.snapshotLines=2}
    else{$prefix.snapshotLength=4}
    $before=& $old {param($p,$h) Read-DispatchCountHistory -Path $p -PrefixHistory $h} $path $prefix
    $after=& $current {param($p,$h) Read-DispatchCountHistory -Path $p -PrefixHistory $h} $path $prefix
    Check (($before|ConvertTo-Json -Depth 20 -Compress) -ceq ($after|ConvertTo-Json -Depth 20 -Compress)) "bad prefix $bad preserves captured snapshot identity"
  }
  Add-Type -TypeDefinition @'
using System;
using System.IO;
public sealed class RewriteDispatchBoundary : Stream {
  byte[] data = new byte[] {123,125,10}; long position;
  public override bool CanRead => true; public override bool CanSeek => true; public override bool CanWrite => false;
  public override long Length => data.Length; public override long Position { get => position; set => position=value; }
  public override int Read(byte[] buffer,int offset,int count) {
    int n=(int)Math.Min(count,Length-position); Array.Copy(data,position,buffer,offset,n); position+=n;
    if(position==Length)data[2]=120; return n;
  }
  public override int ReadByte(){return position==Length?-1:data[position++];}
  public override long Seek(long offset,SeekOrigin origin){position=origin==SeekOrigin.Begin?offset:origin==SeekOrigin.End?Length+offset:position+offset;return position;}
  public override void Flush(){} public override void SetLength(long value){throw new NotSupportedException();}
  public override void Write(byte[] buffer,int offset,int count){throw new NotSupportedException();}
}
'@
  $probe=& $current {
    param($p)
    $original=${function:Open-DispatchLedgerReadStream}
    try {
      function script:Open-DispatchLedgerReadStream([string]$Path){return [RewriteDispatchBoundary]::new()}
      $snapshot=Read-DispatchLedgerSnapshot -Path $p
      $history=Read-DispatchCountHistory -Path $p
      [pscustomobject]@{snapshot=$snapshot;history=$history}
    } finally {Set-Item Function:script:Open-DispatchLedgerReadStream $original}
  } $path
  Check (-not $probe.snapshot.complete -and $probe.snapshot.reason -ceq 'HISTORY_UNREADABLE') 'unchanged snapshot catches controlled same-length boundary rewrite'
  Check (-not $probe.history.complete -and $probe.history.reason -ceq 'HISTORY_UNREADABLE') 'streaming count catches same controlled committed-boundary rewrite'
  if($failures.Count){throw "FAILED $($failures.Count) boundary regressions: $($failures -join '; ')"}
  Write-Output 'PASS boundary rewrite, strict invalid-UTF8 partial precedence and moved-prefix snapshot metadata'
} finally {
  if($old){Remove-Module $old -Force}
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotmatch '^dispatch-history-boundary-[a-f0-9]{32}$'){throw 'unsafe boundary fixture cleanup'}
  if(Test-Path $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
