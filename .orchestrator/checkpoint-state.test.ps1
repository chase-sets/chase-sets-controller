[CmdletBinding()]
param([string]$SourcePath=(Join-Path $PSScriptRoot 'dispatch-history-checkpoint.psm1'),[string]$Case='*',
  [ValidateSet('','worker-error','deadline')][string]$DiagnosticFailureProbe='')
$ErrorActionPreference='Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass='BelowNormal'
Import-Module $SourcePath -Force
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force
$script:passed=0
$script:root=Join-Path ([IO.Path]::GetTempPath()) ('checkpoint-store-private-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:root)
$script:children=[Collections.Generic.List[object]]::new()
$script:failure=$null
function Assert([bool]$Value,[string]$Message) { if (-not $Value) { throw "ASSERT: $Message" } }
function Test-Case([string]$Name,[scriptblock]$Body) {
  if ($Name -notlike $Case) { return }
  & $Body
  $script:passed++
  "PASS $Name"
}
function New-Path {
  $directory=Join-Path $script:root ([guid]::NewGuid().ToString('N'))
  [void][IO.Directory]::CreateDirectory($directory)
  return (Join-Path $directory 'dispatch-log.jsonl')
}
function New-History([string]$Path,[int]$Count=2,[string]$Suffix='') {
  $lines=@(for($i=1;$i -le $Count;$i++){ '{"kind":"dispatch","lane":"fixture-'+$i+$Suffix+'","attempt":'+$i+'}' })
  [IO.File]::WriteAllText($Path,($lines -join "`n")+$(if($Count){"`n"}else{''}),[Text.UTF8Encoding]::new($false))
  $history=Read-DispatchCountHistory -Path $Path
  Assert $history.complete 'fixture reader refused'
  return $history
}
function Load-Envelope([string]$Path) {
  return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Get-DispatchHistoryCheckpointPath $Path))) -AsHashtable -DateKind String)
}
function Save-Envelope([string]$Path,$Envelope) {
  [IO.File]::WriteAllText((Get-DispatchHistoryCheckpointPath $Path),(ConvertTo-Json -InputObject $Envelope -Depth 100 -Compress))
}
function Assert-State([string]$Path,[string]$State,[string]$Reason) {
  $read=Read-DispatchHistoryCheckpoint -Path $Path
  Assert ($read.state -ceq $State -and $read.reason -ceq $Reason) "expected $State/$Reason, got $($read.state)/$($read.reason)"
  if($State -ne 'valid'){Assert ($null -eq $read.checkpoint) 'unusable state exposed a projection'}
}
function Remove-PrivateTree([string]$Path) {
  $full=[IO.Path]::GetFullPath($Path)
  $base=[IO.Path]::GetFullPath($script:root)+[IO.Path]::DirectorySeparatorChar
  if(-not $full.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)){throw 'test cleanup escaped private root'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
function Start-PrivateProcess([string]$Script,[string[]]$Arguments,[string]$Label,[string]$CheckpointPath) {
  $out=Join-Path $script:root ($Label+'.out');$err=Join-Path $script:root ($Label+'.err')
  $quoted=@('-NoProfile','-NonInteractive','-File',('"'+$Script+'"'))+@($Arguments|ForEach-Object {'"'+$_+'"'})
  $options=@{FilePath=(Get-Process -Id $PID).Path;ArgumentList=$quoted;PassThru=$true;RedirectStandardOutput=$out;RedirectStandardError=$err}
  if($IsWindows){$options.WindowStyle='Hidden'}
  $process=Start-Process @options
  $record=@{process=$process;out=$out;err=$err;label=$Label;checkpointPath=$CheckpointPath}
  $script:children.Add($record)
  return $record
}
function Wait-PrivateProcess($Record) {
  if(-not $Record.process.WaitForExit(20000)){throw 'private checkpoint worker exceeded 20 seconds'}
  $Record.process.WaitForExit()
  $Record.process.Refresh()
  Assert ($Record.process.ExitCode -eq 0) "private worker failed: pid=$($Record.process.Id) exitcode=$($Record.process.ExitCode)"
}
function Read-PrivateDiagnosticTail([string]$Path) {
  # Read at most 16 KiB, even if a still-running private worker keeps writing.
  $stream=$null
  try {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $length=$stream.Length
    [void]$stream.Seek([Math]::Max(0,$length-16384),[IO.SeekOrigin]::Begin)
    $buffer=[byte[]]::new(16384);$count=$stream.Read($buffer,0,$buffer.Length)
    $text=[Text.Encoding]::UTF8.GetString($buffer,0,$count)
    $truncated=$length -gt $count -or $text.Length -gt 4096
    if($text.Length -gt 4096){$text=$text.Substring($text.Length-4096)}
    return @{text=$text;truncated=$truncated;bytes=$length}
  } catch {return @{unavailable=$true}}
  finally {if($null -ne $stream){$stream.Dispose()}}
}
function Write-PrivateFailureDiagnostics {
  # These records contain only this test's synthetic workers, never shared runtime state.
  $message=[string]$script:failure
  if($message.Length -gt 512){$message=$message.Substring(0,512)}
  [Console]::Error.WriteLine('CHECKPOINT_FAILURE_DIAGNOSTIC '+(ConvertTo-Json -Compress -InputObject @{root=$script:root;failure=$message}))
  foreach($record in $script:children){
    try {
      $record.process.Refresh()
      $exited=$record.process.HasExited
      $exitcode=$null;if($exited){$exitcode=$record.process.ExitCode}
      $diagnostic=@{label=$record.label;pid=$record.process.Id;exited=$exited;exitcode=$exitcode;
        stdout=(Read-PrivateDiagnosticTail $record.out);stderr=(Read-PrivateDiagnosticTail $record.err);checkpoint=$null}
      if($record.checkpointPath){
        try {
          $read=Read-DispatchHistoryCheckpoint $record.checkpointPath
          $checkpoint=@{path=$read.path;state=$read.state;reason=$read.reason}
          if($null -ne $read.checkpoint){
            foreach($field in @('schemaVersion','sourceKey','sourcePath','cursor','snapshotLength','snapshotLines','snapshotHash')){
              $checkpoint[$field]=$read.checkpoint[$field]
            }
            $checkpoint.rows=$read.checkpoint.rows.Count
          }
          $diagnostic.checkpoint=$checkpoint
        } catch {$diagnostic.checkpoint=@{unavailable=$true}}
      }
      [Console]::Error.WriteLine('CHECKPOINT_WORKER_DIAGNOSTIC '+(ConvertTo-Json -Compress -Depth 6 -InputObject $diagnostic))
    } catch {
      # Diagnostic collection must not replace the original assertion/timeout.
      [Console]::Error.WriteLine('CHECKPOINT_WORKER_DIAGNOSTIC '+(ConvertTo-Json -Compress -InputObject @{label=$record.label;unavailable=$true}))
    }
  }
}
try {
Test-Case 'checkpoint-store-worker-failure-diagnostics' {
  if($DiagnosticFailureProbe){
    $path=New-Path;$history=New-History $path
    Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'diagnostic seed failed'
    $worker=Join-Path $script:root 'diagnostic-worker.ps1'
    [IO.File]::WriteAllText($worker,@'
param([int]$Code)
[Console]::Out.WriteLine(('x'*20000)+"private stdout exit=$Code")
[Console]::Error.WriteLine("private stderr exit=$Code")
exit $Code
'@)
    $success=Start-PrivateProcess $worker @('0') 'diagnostic-success' $path
    $failure=Start-PrivateProcess $worker @('17') 'diagnostic-failure' $path
    Wait-PrivateProcess $success
    if($DiagnosticFailureProbe -ceq 'deadline'){
      Assert ($failure.process.WaitForExit(20000)) 'diagnostic worker exceeded 20 seconds'
      # Inject the polling assertion after exit, rather than making the suite sleep 25 seconds.
      Assert $false 'concurrent workers exceeded bounded wait (injected diagnostic probe)'
    }
    Wait-PrivateProcess $failure
    throw 'diagnostic negative control unexpectedly returned'
  }
  foreach($mode in @('worker-error','deadline')){
  $probe=Start-PrivateProcess $PSCommandPath @('-SourcePath',$SourcePath,'-Case','checkpoint-store-worker-failure-diagnostics','-DiagnosticFailureProbe',$mode) "diagnostic-probe-$mode"
  Assert ($probe.process.WaitForExit(20000)) 'diagnostic probe exceeded 20 seconds'
  $probe.process.WaitForExit();$probe.process.Refresh()
  Assert ($probe.process.ExitCode -ne 0) 'diagnostic probe lost the worker failure'
  $lines=@([IO.File]::ReadAllLines($probe.err))
  $header=@($lines|Where-Object {$_ -like 'CHECKPOINT_FAILURE_DIAGNOSTIC *'}|ForEach-Object {ConvertFrom-Json $_.Substring(30) -AsHashtable})
  $workers=@($lines|Where-Object {$_ -like 'CHECKPOINT_WORKER_DIAGNOSTIC *'}|ForEach-Object {ConvertFrom-Json $_.Substring(29) -AsHashtable})
  $expected=if($mode -ceq 'worker-error'){'*private worker failed:*exitcode=17*'}else{'*concurrent workers exceeded bounded wait (injected diagnostic probe)*'}
  Assert ($header.Count -eq 1 -and $header[0].failure -like $expected) 'original failure lost'
  Assert ($workers.Count -eq 2) 'owned worker diagnostics missing'
  foreach($code in @(0,17)){
    $item=@($workers|Where-Object exitcode -eq $code)
    Assert ($item.Count -eq 1 -and $item[0].pid -gt 0 -and $item[0].exited) "worker status lost for exit=$code"
    Assert ($item[0].stdout.text.EndsWith("private stdout exit=$code"+[Environment]::NewLine) -and
      $item[0].stdout.truncated -and $item[0].stdout.text.Length -eq 4096 -and
      $item[0].stderr.text.Trim() -ceq "private stderr exit=$code") "bounded output lost for exit=$code"
    Assert ($item[0].checkpoint.state -ceq 'valid' -and $item[0].checkpoint.rows -eq 2 -and
      $item[0].checkpoint.cursor -gt 0 -and $item[0].checkpoint.snapshotHash -cmatch '^[a-f0-9]{64}$' -and
      $item[0].checkpoint.sourceKey -cmatch '^[a-f0-9]{64}$') 'final checkpoint identity missing'
  }
  $probeRoot=[IO.Path]::GetFullPath($header[0].root)
  Assert ($probeRoot.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and
    [IO.Path]::GetFileName($probeRoot) -like 'checkpoint-store-private-*') 'probe reported non-private root'
  Assert (-not [IO.Directory]::Exists($probeRoot)) 'diagnostics require retained fixture'
  Assert (@($lines|Where-Object {$_ -like "*ASSERT: $($expected.Trim('*'))*"}).Count -gt 0) 'original exception was swallowed'
  }
}
Test-Case 'checkpoint-store-bootstrap-roundtrip' {
  $path=New-Path
  Assert-State $path 'missing' 'CHECKPOINT_MISSING'
  $history=New-History $path
  $published=Publish-DispatchHistoryCheckpoint -Path $path -History $history
  Assert ($published.published -and $published.reason -ceq 'CHECKPOINT_PUBLISHED') 'bootstrap not published'
  Assert-State $path 'valid' 'CHECKPOINT_STRUCTURALLY_VALID'
  $read=Read-DispatchHistoryCheckpoint $path
  Assert ($read.checkpoint.cursor -eq $history.cursor -and $read.checkpoint.snapshotHash -ceq $history.snapshotHash) 'snapshot metadata lost'
  Assert ($read.checkpoint.rows.Count -eq 2 -and $read.checkpoint.rows[1].line -eq 2 -and
    $read.checkpoint.rows[1].raw -ceq $history.rows[1].raw -and $read.checkpoint.rows[1].rawSha256 -ceq $history.rows[1].rawSha256 -and
    $read.checkpoint.rows[1].byteLength -eq $history.rows[1].byteLength -and $read.checkpoint.audit.parsedRows -eq 2) 'full projection not preserved'
  Assert (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($published.path)) -Filter '*.tmp').Count -eq 0) 'temporary leaked'
  # Structural validity intentionally does not read or authenticate the source.
  [IO.File]::Delete($path)
  Assert-State $path 'valid' 'CHECKPOINT_STRUCTURALLY_VALID'
  $empty=New-History $path 0
  $emptyPath=New-Path
  Assert ((Publish-DispatchHistoryCheckpoint $emptyPath $empty).published) 'empty checkpoint refused'
}
Test-Case 'checkpoint-store-fullpath-key-and-isolation' {
  $path=New-Path;$history=New-History $path
  $other=New-Path
  $first=Get-DispatchHistoryCheckpointPath $path;$second=Get-DispatchHistoryCheckpointPath $other
  Assert ($first -cne $second) 'two roots collided'
  $canonical=[IO.Path]::GetFullPath($path);if($IsWindows){$canonical=$canonical.ToUpperInvariant()}
  $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
  Assert ([IO.Path]::GetFileName($first) -ceq "$key.json" -and [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($first)) -ceq '.dispatch-history-checkpoint.d') 'key or protected sibling name wrong'
  if($IsWindows){Assert ((Get-DispatchHistoryCheckpointPath $path.ToLowerInvariant()) -ceq $first) 'Windows case alias split mutex/key'}
  Assert ((Get-DispatchHistoryCheckpointPath (Join-Path ([IO.Path]::GetDirectoryName($path)) './dispatch-log.jsonl')) -ceq $first) 'dot segment alias split key'
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'first root publication failed'
  Assert-State $other 'missing' 'CHECKPOINT_MISSING'
  Assert ((Publish-DispatchHistoryCheckpoint $other $history).published) 'second root publication failed'
  Assert ((Load-Envelope $other).sourcePath -cne (Load-Envelope $path).sourcePath) 'source identity copied across roots'
  $sibling=Join-Path ([IO.Path]::GetDirectoryName($path)) 'other.jsonl'
  Assert ((Get-DispatchHistoryCheckpointPath $sibling) -cne $first) 'two sources in same root collided'
}
Test-Case 'checkpoint-store-typed-non-dispatch-read-guard' {
  $path=New-Path;$history=New-History $path
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'typed guard seed failed'
  $json=[IO.File]::ReadAllText((Get-DispatchHistoryCheckpointPath $path))
  [IO.File]::WriteAllText($path,$json)
  $module=Get-Module -Name dispatch-history-checkpoint
  $result=& $module {
    param($Source)
    $identity=Get-CheckpointIdentity $Source
    $identity.path=$Source
    Read-CheckpointFile $identity
  } $path
  Assert ($result.state -ceq 'invalid' -and $null -eq $result.checkpoint) 'store bypassed owner guard to read dispatch ledger'
  Assert ($Error[0].Exception.Message -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') 'typed guard did not cause refusal'
}
Test-Case 'checkpoint-store-version-discard-and-rebuild' {
  $path=New-Path;$history=New-History $path
  Assert ((Publish-DispatchHistoryCheckpoint $path $history -ReducerVersion 'old/v1').published) 'old version publication failed'
  Assert-State $path 'version' 'CHECKPOINT_VERSION_MISMATCH'
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'same-prefix version rebuild failed'
  Assert-State $path 'valid' 'CHECKPOINT_STRUCTURALLY_VALID'
  $read=Read-DispatchHistoryCheckpoint $path -ContractVersion 'other/v1'
  Assert ($read.state -ceq 'version' -and $null -eq $read.checkpoint) 'contract mismatch trusted'
  $e=Load-Envelope $path;$e.schemaVersion='dispatch-history-checkpoint/v0';Save-Envelope $path $e
  Assert-State $path 'version' 'CHECKPOINT_SCHEMA_VERSION'
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'schema rebuild failed'
}
Test-Case 'checkpoint-store-invalid-and-identity-discard' {
  $path=New-Path;$history=New-History $path
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'seed failed'
  $valid=[IO.File]::ReadAllText((Get-DispatchHistoryCheckpointPath $path))
  $mutations=@(
    {param($e)$e.sourceKey='0'*64}, {param($e)$e.sourcePath=$e.sourcePath+'.other'},
    {param($e)$e.extra=$true}, {param($e)$e.cursor++}, {param($e)$e.complete=$false},
    {param($e)$e.snapshotHash='UPPER'}, {param($e)$e.rows[1].line=$e.rows[0].line},
    {param($e)$e.rows[0].rawSha256='0'*64}, {param($e)$e.rows[0].byteLength++},
    {param($e)$e.rows[0].value.lane='forged'}, {param($e)$e.rows[0].line='1'},
    {param($e)$e.audit.parsedRows--}, {param($e)$e.audit.malformedRows=1},
    {param($e)$e.audit.truncated=$true}, {param($e)$e.partialTrailingRow='false'},
    {param($e)$e.rows=@($e.rows[1])}, {param($e)$e.rows[0].extra=$true},
    {param($e)$e.audit.extra=1}, {param($e)$e.rows[0].value=$null}
  )
  foreach($mutate in $mutations){
    $e=ConvertFrom-Json -InputObject $valid -AsHashtable -DateKind String
    & $mutate $e
    Save-Envelope $path $e
    Assert-State $path 'invalid' 'CHECKPOINT_INVALID'
    Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'invalid projection did not permit rebuild'
  }
  foreach($bad in @('{broken',($valid.Replace('"complete":true','"complete":true,"complete":true')),($valid.Replace('"complete":true','"complete":true,"Complete":true')))){
    [IO.File]::WriteAllText((Get-DispatchHistoryCheckpointPath $path),$bad)
    Assert-State $path 'invalid' 'CHECKPOINT_INVALID'
  }
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'malformed rebuild failed'
  $other=New-Path;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName((Get-DispatchHistoryCheckpointPath $other)))
  [IO.File]::Copy((Get-DispatchHistoryCheckpointPath $path),(Get-DispatchHistoryCheckpointPath $other))
  Assert-State $other 'invalid' 'CHECKPOINT_INVALID'
  $incomplete=New-History (New-Path);$incomplete.complete=$false
  Assert (-not (Publish-DispatchHistoryCheckpoint (New-Path) $incomplete).published) 'incomplete publication accepted'
}
Test-Case 'checkpoint-store-monotonic-and-equal-conflicts' {
  $path=New-Path;$low=New-History $path 1;$high=New-History $path 3
  Assert ((Publish-DispatchHistoryCheckpoint $path $high).published) 'high seed failed'
  $before=[IO.File]::ReadAllText((Get-DispatchHistoryCheckpointPath $path))
  $result=Publish-DispatchHistoryCheckpoint $path $low
  Assert (-not $result.published -and $result.reason -ceq 'CHECKPOINT_CURSOR_REGRESSION') 'lower cursor published'
  Assert ((Publish-DispatchHistoryCheckpoint $path $high).published) 'idempotent equal publication failed'
  $high.snapshotHash='a'*64
  $result=Publish-DispatchHistoryCheckpoint $path $high
  Assert (-not $result.published -and $result.reason -ceq 'CHECKPOINT_EQUAL_CURSOR_CONFLICT') 'equal cursor changed digest'
  $high=New-History $path 3 'x'
  # Same-length raw/value mutation, recomputed by the sole owner, with the old prefix digest.
  $changed=New-History $path 3 'y';$changed.snapshotHash=$high.snapshotHash
  $fresh=New-Path;Assert ((Publish-DispatchHistoryCheckpoint $fresh $high).published) 'projection conflict seed failed'
  $result=Publish-DispatchHistoryCheckpoint $fresh $changed
  Assert (-not $result.published -and $result.reason -ceq 'CHECKPOINT_EQUAL_CURSOR_CONFLICT') 'equal cursor changed projection'
  Assert ([IO.File]::ReadAllText((Get-DispatchHistoryCheckpointPath $path)) -ceq $before) 'refusal changed checkpoint'
  $versioned=New-Path;Assert ((Publish-DispatchHistoryCheckpoint $versioned (New-History (New-Path) 3) -ReducerVersion 'old/v1').published) 'version seed failed'
  Assert ((Publish-DispatchHistoryCheckpoint $versioned $low).reason -ceq 'CHECKPOINT_CURSOR_REGRESSION') 'version transition lowered cursor'
}
Test-Case 'checkpoint-store-partial-tail-blank-lines' {
  $path=New-Path
  [IO.File]::WriteAllText($path,"`n  `r`n"+'{"kind":"dispatch"}'+"`r`n"+'{"kind":')
  $history=Read-DispatchCountHistory $path
  Assert ($history.complete -and $history.partialTrailingRow) 'partial fixture not deferred by owner'
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'partial metadata refused'
  $e=Load-Envelope $path
  Assert ($e.rows.Count -eq 1 -and $e.rows[0].line -eq 3 -and $e.snapshotLines -eq 3 -and $e.audit.bytes -gt $e.cursor) 'blank/partial identity lost'
}
Test-Case 'checkpoint-store-root-recreation' {
  $path=New-Path;$history=New-History $path 3
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'seed failed'
  $directory=[IO.Path]::GetDirectoryName($path)
  Remove-PrivateTree $directory
  Assert-State $path 'missing' 'CHECKPOINT_MISSING'
  [void][IO.Directory]::CreateDirectory($directory)
  $small=New-History $path 1
  Assert ((Publish-DispatchHistoryCheckpoint $path $small).published) 'recreated root did not bootstrap'
  Assert ((Read-DispatchHistoryCheckpoint $path).checkpoint.cursor -eq $small.cursor) 'recreated root retained old cursor'
  Remove-PrivateTree ([IO.Path]::GetDirectoryName((Get-DispatchHistoryCheckpointPath $path)))
  Assert ((Publish-DispatchHistoryCheckpoint $path $small).published) 'deleted store directory did not recreate'
}
Test-Case 'checkpoint-store-held-reader-replace-and-delete' {
  $path=New-Path;$low=New-History $path 1;$high=New-History $path 2
  Assert ((Publish-DispatchHistoryCheckpoint $path $low).published) 'held-reader seed failed'
  $checkpoint=Get-DispatchHistoryCheckpointPath $path
  $share=[IO.FileShare]::Read -bor [IO.FileShare]::Delete
  $old=[IO.File]::Open($checkpoint,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
  $reader=[IO.StreamReader]::new($old)
  try {
    Assert ((Publish-DispatchHistoryCheckpoint $path $high).published) 'atomic replacement blocked a sharing reader'
    $oldEnvelope=ConvertFrom-Json -InputObject $reader.ReadToEnd() -AsHashtable -DateKind String
    Assert ($oldEnvelope.cursor -eq $low.cursor -and (Read-DispatchHistoryCheckpoint $path).checkpoint.cursor -eq $high.cursor) 'replacement changed old handle or exposed torn data'
  } finally {$reader.Dispose()}
  $held=[IO.File]::Open($checkpoint,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
  try {
    [IO.File]::Delete($checkpoint)
    $read=Read-DispatchHistoryCheckpoint $path
    Assert ($read.state -eq 'missing' -or $read.reason -eq 'CHECKPOINT_UNREADABLE') 'deleted open checkpoint exposed partial data'
    $result=Publish-DispatchHistoryCheckpoint $path $high
    Assert ($result.published -or $result.reason -in @('CHECKPOINT_UNREADABLE','CHECKPOINT_PUBLISH_FAILED')) 'concurrent deletion did not fail closed'
  } finally {$held.Dispose()}
  Assert ((Publish-DispatchHistoryCheckpoint $path $high).published) 'retry after deletion failed'
  Assert-State $path 'valid' 'CHECKPOINT_STRUCTURALLY_VALID'
  # An unreadable existing checkpoint cannot be treated as permission to lower its cursor.
  $exclusive=[IO.File]::Open($checkpoint,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  try {
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $result=Publish-DispatchHistoryCheckpoint $path $low
    Assert (-not $result.published -and $result.reason -ceq 'CHECKPOINT_UNREADABLE') 'unreadable state overwrote monotonic guard'
    Assert ($clock.Elapsed.TotalSeconds -lt 3) 'exclusive checkpoint sharing refusal was unbounded'
  } finally {$exclusive.Dispose()}
  Assert ((Read-DispatchHistoryCheckpoint $path).checkpoint.cursor -eq $high.cursor) 'locked refusal lowered cursor'
}
Test-Case 'checkpoint-store-shared-write-access-reader' {
  $path=New-Path;$history=New-History $path
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'sharing seed failed'
  $checkpoint=Get-DispatchHistoryCheckpointPath $path
  $before=[IO.File]::ReadAllText($checkpoint)
  $held=[IO.File]::Open($checkpoint,[IO.FileMode]::Open,[IO.FileAccess]::Write,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try {Assert-State $path 'valid' 'CHECKPOINT_STRUCTURALLY_VALID'} finally {$held.Dispose()}
  Assert ([IO.File]::ReadAllText($checkpoint) -ceq $before) 'read-only open changed checkpoint'
}
Test-Case 'checkpoint-store-repeated-replacement-readers' {
  $path=New-Path;$history=New-History $path 1
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'replacement seed failed'
  $inputFile=Join-Path $script:root 'replace.clixml';$history|Export-Clixml -LiteralPath $inputFile -Depth 100
  $worker=Join-Path $script:root 'replace.ps1'
  [IO.File]::WriteAllText($worker,@'
param($Module,$InputFile,$Path)
$ErrorActionPreference='Stop'
Import-Module $Module -Force
$history=Import-Clixml -LiteralPath $InputFile
for($i=0;$i -lt 30;$i++){
  $result=Publish-DispatchHistoryCheckpoint $Path $history
  if(-not $result.published){throw ('replacement refused: '+$result.reason)}
}
'PASS 30 replacements'
'@)
  $record=Start-PrivateProcess $worker @($SourcePath,$inputFile,$path) 'replacer' $path
  $clock=[Diagnostics.Stopwatch]::StartNew();$reads=0
  do {
    Assert ($clock.Elapsed.TotalSeconds -lt 25) 'replacement worker exceeded bounded wait'
    $read=Read-DispatchHistoryCheckpoint $path
    Assert ($read.state -in @('valid','missing')) "replacement read observed $($read.state)/$($read.reason): $($Error[0].Exception.Message)"
    if($read.state -ceq 'valid'){Assert ($read.checkpoint.cursor -eq $history.cursor -and $read.checkpoint.rows.Count -eq 1) 'replacement exposed changed projection'}
    $reads++
  } while(-not $record.process.HasExited)
  Wait-PrivateProcess $record
  Assert ($reads -gt 1) 'replacement reader did not overlap worker'
  Assert-State $path 'valid' 'CHECKPOINT_STRUCTURALLY_VALID'
}
Test-Case 'checkpoint-store-coherent-tampering-is-not-authority' {
  $path=New-Path;$history=New-History $path
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'coherent tamper seed failed'
  $e=Load-Envelope $path
  $e.rows[0].raw=$e.rows[0].raw.Replace('fixture-1','fixture-x')
  $e.rows[0].value.lane='fixture-x'
  $bytes=[Text.Encoding]::UTF8.GetBytes($e.rows[0].raw)
  $e.rows[0].byteLength=$bytes.Length
  $e.rows[0].rawSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
  Save-Envelope $path $e
  # Deliberately structural-only: even the stored prefix digest remains the original.
  # Consumers must bind projected rows to actual prefix bytes, not trust cache hashes.
  Assert-State $path 'valid' 'CHECKPOINT_STRUCTURALLY_VALID'
  $actual=Read-DispatchCountHistory $path
  Assert ($actual.rows[0].rawSha256 -cne (Read-DispatchHistoryCheckpoint $path).checkpoint.rows[0].rawSha256) 'control failed to distinguish cache from canonical authority'
}
Test-Case 'checkpoint-store-concurrent-publication-and-readers' {
  $path=New-Path
  $histories=@(for($i=1;$i -le 4;$i++){New-History $path $i})
  $inputFile=Join-Path $script:root 'histories.clixml';$histories|Export-Clixml -LiteralPath $inputFile -Depth 100
  $worker=Join-Path $script:root 'publish.ps1';$start=Join-Path $script:root 'start'
  [IO.File]::WriteAllText($worker,@'
param($Module,$InputFile,$Path,$Start,$Direction)
$ErrorActionPreference='Stop'
Import-Module $Module -Force
$histories=@(Import-Clixml -LiteralPath $InputFile)
if($Direction -eq 'reverse'){[array]::Reverse($histories)}
$clock=[Diagnostics.Stopwatch]::StartNew()
while(-not [IO.File]::Exists($Start)){if($clock.Elapsed.TotalSeconds -gt 10){throw 'barrier timeout'};Start-Sleep -Milliseconds 5}
foreach($history in $histories){
  $result=Publish-DispatchHistoryCheckpoint $Path $history
  if(-not $result.published -and $result.reason -notin @('CHECKPOINT_CURSOR_REGRESSION','CHECKPOINT_MUTEX_TIMEOUT')){throw ($result.reason+': '+$Error[0])}
  $read=Read-DispatchHistoryCheckpoint $Path
  if($read.state -ne 'valid'){throw ('torn read: '+$read.state+'/'+$read.reason)}
}
'PASS private publisher'
'@)
  $workers=@(for($i=0;$i -lt 3;$i++){Start-PrivateProcess $worker @($SourcePath,$inputFile,$path,$start,$(if($i%2){'reverse'}else{'forward'})) "publisher-$i" $path})
  [IO.File]::WriteAllText($start,'go')
  $clock=[Diagnostics.Stopwatch]::StartNew()
  do {
    Assert ($clock.Elapsed.TotalSeconds -lt 25) 'concurrent workers exceeded bounded wait'
    $read=Read-DispatchHistoryCheckpoint $path
    Assert ($read.state -in @('valid','missing')) "concurrent reader observed $($read.state)/$($read.reason): $($Error[0].Exception.Message)"
    Start-Sleep -Milliseconds 5
    $running=@($workers|Where-Object {-not $_.process.HasExited})
  } while($running.Count)
  foreach($record in $workers){Wait-PrivateProcess $record}
  $read=Read-DispatchHistoryCheckpoint $path
  Assert ($read.state -ceq 'valid' -and $read.checkpoint.cursor -eq $histories[-1].cursor -and $read.checkpoint.rows.Count -eq 4) 'concurrent publish lost high cursor'
  Assert (@(Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($read.path)) -Filter '*.tmp').Count -eq 0) 'concurrent temp leak'
}
Test-Case 'checkpoint-store-bounded-mutex-wait' {
  $path=New-Path;$history=New-History $path
  $key=[IO.Path]::GetFileNameWithoutExtension((Get-DispatchHistoryCheckpointPath $path))
  $name='ChaseSets.DispatchHistoryCheckpoint.'+$key;if($IsWindows){$name='Local\'+$name}
  $worker=Join-Path $script:root 'mutex.ps1';$ready=Join-Path $script:root 'mutex.ready';$release=Join-Path $script:root 'mutex.release'
  [IO.File]::WriteAllText($worker,@'
param($Name,$Ready,$Release)
$mutex=[Threading.Mutex]::new($false,$Name)
try {
  if(-not $mutex.WaitOne(5000)){throw 'mutex not acquired'}
  try {[IO.File]::WriteAllText($Ready,'ready');$clock=[Diagnostics.Stopwatch]::StartNew();while(-not [IO.File]::Exists($Release)){if($clock.Elapsed.TotalSeconds -gt 15){throw 'release timeout'};Start-Sleep -Milliseconds 5}}
  finally {$mutex.ReleaseMutex()}
} finally {$mutex.Dispose()}
'@)
  $record=Start-PrivateProcess $worker @($name,$ready,$release) 'mutex-holder' $path
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(-not [IO.File]::Exists($ready)){if($clock.Elapsed.TotalSeconds -gt 10){throw 'mutex holder did not start'};Start-Sleep -Milliseconds 5}
  try {
    $clock.Restart();$result=Publish-DispatchHistoryCheckpoint $path $history
    Assert (-not $result.published -and $result.reason -ceq 'CHECKPOINT_MUTEX_TIMEOUT' -and $clock.Elapsed.TotalSeconds -lt 8) 'mutex wait unbounded or ignored'
    Assert-State $path 'missing' 'CHECKPOINT_MISSING'
  } finally {[IO.File]::WriteAllText($release,'release')}
  Wait-PrivateProcess $record
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'post-timeout retry failed'
}
Test-Case 'checkpoint-store-native-retention-exclusion' {
  . (Join-Path $PSScriptRoot 'runtime-retention.ps1') -Library
  $fixture=Join-Path $script:root 'retention';$runtime=Join-Path $fixture '.orchestrator'
  [void][IO.Directory]::CreateDirectory($runtime)
  $path=Join-Path $runtime 'dispatch-log.jsonl';$history=New-History $path
  Assert ((Publish-DispatchHistoryCheckpoint $path $history).published) 'retention seed failed'
  $checkpoint=Get-DispatchHistoryCheckpointPath $path;$before=[IO.File]::ReadAllText($checkpoint)
  [IO.File]::SetLastWriteTimeUtc($checkpoint,[datetime]::UtcNow.AddDays(-30))
  [IO.Directory]::SetLastWriteTimeUtc([IO.Path]::GetDirectoryName($checkpoint),[datetime]::UtcNow.AddDays(-30))
  $context=@{tracked=@();references='';commands=@();complete=$true}
  $report=Invoke-RuntimeRetention -Root $fixture -Dependencies @{
    Context={param($r)$context}; Authority={@{openIssues=@();openPrs=@()}}
  }
  $item=@($report.items|Where-Object path -ceq '.dispatch-history-checkpoint.d')
  Assert ($item.Count -eq 1 -and $item[0].reason -ceq 'protected-name' -and $item[0].action -ceq 'retain') 'actual retention did not protect .d'
  Assert (@($item[0].snapshot.files).Count -eq 0 -and [IO.File]::ReadAllText($checkpoint) -ceq $before) 'retention walked or mutated checkpoint'
  # Discriminating control uses the real protected-name function, not a copied regex.
  $protection=@{trackedItems=[Collections.Generic.HashSet[string]]::new();complete=$true;liveMatches=@{};processText='';referenceMatches=@{};referenceText=''}
  $snapshot=@{files=@();directories=@();reason=$null;newest=[datetime]::UtcNow.AddDays(-30)}
  $authority=@{known=$true;numbers=[Collections.Generic.HashSet[long]]::new()}
  $protected=Get-RetentionReason @{path='.dispatch-history-checkpoint.d';snapshot=$snapshot} $protection $authority @{} ([datetime]::UtcNow)
  $unprotected=Get-RetentionReason @{path='.dispatch-history-checkpoint';snapshot=$snapshot} $protection $authority @{} ([datetime]::UtcNow)
  Assert ($protected -ceq 'protected-name' -and $unprotected -ceq 'eligible') 'retention .d negative control failed'
}
"PASS checkpoint-state: $script:passed cases"
} catch {
  $script:failure=$_.Exception.Message
  throw
} finally {
  # Only private workers started by this test are waited; no shared slot/process is touched.
  foreach($record in $script:children){
    if(-not $record.process.HasExited){[void]$record.process.WaitForExit(20000)}
    if($record.process.HasExited){$record.process.WaitForExit()}
  }
  if($null -ne $script:failure){Write-PrivateFailureDiagnostics}
  if(@($script:children|Where-Object {-not $_.process.HasExited}).Count -eq 0){
    foreach($child in Get-ChildItem -LiteralPath $script:root -Force){
      if($child.PSIsContainer){Remove-PrivateTree $child.FullName}else{[IO.File]::Delete($child.FullName)}
    }
    [IO.Directory]::Delete($script:root)
  }
}
