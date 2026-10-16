[CmdletBinding()]
param(
  [string]$SourceRevision = '',
  [ValidateSet('all', 'failure-attribution', 'cause-matrix', 'sanitization')][string]$Case = 'all',
  [ValidateSet('', 'attribution-omission', 'summary-omission', 'authority-omission', 'drain-omission',
    'shutdown-omission', 'isolation-stale', 'unknown-class', 'summary-validation')][string]$Mutant = ''
)

$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'
$controller = Split-Path -Parent $PSScriptRoot
function Assert-True($Condition, [string]$Name) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Name" }
}
function Read-Source([string]$Name) {
  if (-not $SourceRevision) { return [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name)) }
  $lines = @(& git -C $controller show "${SourceRevision}:.orchestrator/$Name")
  Assert-True ($LASTEXITCODE -eq 0) "source exists: $Name"
  return $lines -join "`n"
}
function Replace-Once([string]$Text, [string]$Old, [string]$New) {
  Assert-True ($Text.Split([string[]]@($Old), [StringSplitOptions]::None).Count -eq 2) 'unique mutant anchor'
  return $Text.Replace($Old, $New)
}
$native = Read-Source 'heavy-nested-owner.cs'
$wrapper = Read-Source 'invoke-heavy-verifier.ps1'
switch ($Mutant) {
  'attribution-omission' { $native = Replace-Once $native 'LastFailure = _statistics.LastFailure,' 'LastFailure = null,' }
  'summary-omission' { $wrapper = Replace-Once $wrapper ' $failure")' '")' }
  'authority-omission' { $native = Replace-Once $native 'RecordFailure(null, token, category);' '/* omitted authority attribution */' }
  'drain-omission' { $native = Replace-Once $native 'catch (OperationCanceledException error) { RecordFailure(error, token, null); }' 'catch (OperationCanceledException) { }' }
  'shutdown-omission' { $native = Replace-Once $native '_stop.IsCancellationRequested); // failure snapshot' 'false); // failure snapshot' }
  'isolation-stale' {
    $native = Replace-Once $native 'LastFailure = _statistics.LastFailure,' @'
LastFailure = _statistics.LastFailure == null ? null : new NestedOwnerFailure(_statistics.Connections,
  _statistics.LastFailure.Head, _statistics.LastFailure.ExceptionClass, _statistics.LastFailure.Category,
  _statistics.LastFailure.Phase, _statistics.LastFailure.ExchangeCancellationRequested, _statistics.LastFailure.OwnerShutdownRequested),
'@
  }
  'unknown-class' { $native = Replace-Once $native 'return "unknown"; // unrecognized exception class' 'return error.GetType().Name;' }
  'summary-validation' { $wrapper = Replace-Once $wrapper "if (-not `$valid) { return 'failure=unavailable' }" "if (`$false) { return 'failure=unavailable' }" }
}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'wrapper parses'
foreach ($name in @('Format-NestedFailure', 'Stop-NestedOwner')) {
  $definition = $ast.Find({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name
  }, $false)
  if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
Add-Type -TypeDefinition $native -ReferencedAssemblies @(
  'System.IO.Pipes', 'System.IO.FileSystem', 'System.Security.AccessControl',
  'System.Security.Principal.Windows', 'System.Security.Claims', 'System.Security.Cryptography',
  'System.Text.Json', 'System.Text.RegularExpressions', 'System.Runtime.InteropServices',
  'System.Threading', 'System.Threading.Thread', 'System.Collections', 'System.Memory',
  'System.Text.Encoding.Extensions', 'System.Diagnostics.Process'
)
$head = (& git -C $controller rev-parse HEAD).Trim()
$branch = & git -C $controller symbolic-ref -q --short HEAD
$branch = if ($LASTEXITCODE -eq 0 -and $branch) { ([string]$branch).Trim() } else { $null }
$identityMode = if ($branch) { 'branch' } else { 'immutable-head' }
$probe = [ChaseSets.HeavyAdmission.ProcessProbe]::Open($PID)
try { $start = [datetime]::new($probe.CreationTicks, [DateTimeKind]::Utc).ToString('O') } finally { $probe.Dispose() }
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('heavy-nested-attribution-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$servers = [Collections.Generic.List[object]]::new()
$retained = [Collections.Generic.List[string]]::new()
$marker = 'SYNTHETIC-REQUEST-SECRET-9742'
function New-Owner {
  $id = [guid]::NewGuid().ToString('N')
  $directory = Join-Path $root $id
  [IO.Directory]::CreateDirectory($directory) | Out-Null
  $owner = [ordered]@{
    lockId=$id; state='started'; gate='test:scripts'; commandIdentity='test:scripts'
    pid=$PID; processStartUtc=$start; childPid=$PID; childProcessStartUtc=$start
    lane='attribution-test'; worktree=$controller; branch=$branch; head=$head; identityMode=$identityMode; owner='synthetic-attribution'
  }
  $raw = $owner | ConvertTo-Json -Compress
  [IO.File]::WriteAllText((Join-Path $directory 'owner.json'), $raw)
  $binding = [ChaseSets.HeavyAdmission.NestedOwnerBinding]::new()
  $binding.HostVerifier = $true
  $binding.OwnerRaw = $raw; $binding.LockDirectory = $directory; $binding.LockId = $id
  $binding.OwnerIdentity = $owner.owner; $binding.Gate = $owner.gate; $binding.State = $owner.state
  $binding.CommandIdentity = $owner.commandIdentity; $binding.AllowedKinds = [string[]]@('script-battery')
  $binding.WrapperPid = $PID; $binding.WrapperStartUtc = $start; $binding.RootPid = $PID; $binding.RootStartUtc = $start
  $binding.Lane = $owner.lane; $binding.Worktree = $controller
  if ($branch) { $binding.Branch = $branch }
  $binding.Head = $head; $binding.IdentityMode = $identityMode
  $server = [ChaseSets.HeavyAdmission.NestedOwnerServer]::Reserve($id)
  $servers.Add($server)
  $server.Arm($binding)
  return [pscustomobject]@{ Server=$server; Binding=$binding; CompletedServiceMs=0.0 }
}
function Open-Client($Owner) {
  $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $Owner.Server.PipeName.Substring(9),
    [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
  $pipe.Connect(15000)
  return $pipe
}
function New-Request($Owner, [string]$Kind = 'script-battery') {
  return [ordered]@{
    schemaVersion=1; challenge=([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
    pid=$PID; kind=$Kind; lockId=$Owner.Binding.LockId; lane=$Owner.Binding.Lane
    worktree=$controller; branch=$branch; head=$head; identityMode=$identityMode; gate='test:scripts'; launchId=$null; laneRole=$null
  } | ConvertTo-Json -Compress
}
function Write-Request($Pipe, [string]$Text) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
  $Pipe.Write($bytes, 0, $bytes.Length)
}
function Read-Reply($Pipe) {
  $cancel = [Threading.CancellationTokenSource]::new(15000)
  try {
    $bytes = [byte[]]::new(16384)
    $count = 0
    do {
      $read = $Pipe.ReadAsync($bytes, $count, $bytes.Length - $count, $cancel.Token).GetAwaiter().GetResult()
      Assert-True ($read -gt 0) 'real pipe yields a reply'
      $count += $read
    } until ([Array]::IndexOf($bytes, [byte]10, 0, $count) -ge 0)
    return [Text.Encoding]::UTF8.GetString($bytes, 0, $count)
  } finally { $cancel.Dispose() }
}
function Wait-Terminal($Owner, [long]$Connections) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  do {
    $s = $Owner.Server.Statistics()
    if ($s.Connections -eq $Connections -and $s.TotalServiceMs -gt $Owner.CompletedServiceMs -and ($s.Served + $s.Refused) -ge $Connections) {
      $Owner.CompletedServiceMs = $s.TotalServiceMs
      return $s
    }
    [Threading.Thread]::Sleep(10)
  } while ($watch.ElapsedMilliseconds -lt 15000)
  throw 'ASSERTION FAILED: native terminal outcome not observed'
}
function Get-Summary($Owner, [string]$Observable = 'failure-attribution') {
  $nestedOwner = $Owner.Server
  $isHostVerifier = $true; $callerBinding = @{ Record=$null }; $nestedBinding = $null
  $commandIdentity = 'test:scripts'; $nestedInitialization = @{ compileMs=0; reserveMs=0; bindMs=0; armMs=0 }
  $sink = [IO.StringWriter]::new()
  $original = [Console]::Error
  try { [Console]::SetError($sink); Stop-NestedOwner } finally { [Console]::SetError($original) }
  $text = $sink.ToString().Trim()
  $retained.Add($text)
  [Console]::Out.WriteLine('SUMMARY ' + $text)
  Assert-True ($text -match ' failure=(\{.*\})$') "$Observable`: emitted Stop-NestedOwner contains native cause"
  return $Matches[1] | ConvertFrom-Json
}
function Assert-Failure($Failure, [long]$Connection, [string]$Phase, [bool]$Cancelled, [bool]$Shutdown) {
  Assert-True ($Failure.Connection -eq $Connection -and $Failure.Head -ceq $head) 'coherent connection/exact-head attribution'
  Assert-True ($Failure.Phase -ceq $Phase) "native phase is $Phase"
  Assert-True ($Failure.ExchangeCancellationRequested -is [bool] -and $Failure.ExchangeCancellationRequested -eq $Cancelled) 'actual exchange cancellation state'
  Assert-True ($Failure.OwnerShutdownRequested -is [bool] -and $Failure.OwnerShutdownRequested -eq $Shutdown) 'owner shutdown is distinct from exchange expiry'
}
function Assert-LastFailureUnchanged($Before, $After) {
  Assert-True (($Before | ConvertTo-Json -Compress) -ceq ($After | ConvertTo-Json -Compress)) 'failure-isolation: healthy connection does not relabel or overwrite last failure'
}
function Invoke-Healthy($Owner, [long]$Connections) {
  $pipe = Open-Client $Owner
  try {
    Write-Request $pipe ((New-Request $Owner) + "`n")
    $reply = Read-Reply $pipe
    $retained.Add($reply)
    Assert-True ($reply -match '^\{"payload":"' -and $reply -match '"signature":"') 'next healthy native connection receives signed acceptance'
  } finally { $pipe.Dispose() }
  return Wait-Terminal $Owner $Connections
}
try {
  if ($Case -in @('all', 'failure-attribution', 'cause-matrix')) {
    $owner = New-Owner
    $pipe = Open-Client $owner
    try {
      # All authority fields are valid; only the final newline is withheld.
      Write-Request $pipe (New-Request $owner)
      $s = Wait-Terminal $owner 1
    } finally { $pipe.Dispose() }
    $before = $s.LastFailure
    $s = Invoke-Healthy $owner 2
    Assert-True ($s.Served -eq 1) 'failure-isolation: cancellation does not taint next healthy connection'
    Assert-LastFailureUnchanged $before $s.LastFailure
    $failure = Get-Summary $owner
    Assert-Failure $failure 1 'request-read' $true $false
    Assert-True ($failure.ExceptionClass -cin @('OperationCanceledException', 'TaskCanceledException') -and $failure.Category -ceq 'cancellation') 'native cancellation class/category, not client EPIPE inference'
    Write-Output ('PASS failure-attribution ' + ($failure | ConvertTo-Json -Compress))
  }
  if ($Case -in @('all', 'cause-matrix')) {
    foreach ($mode in @('peer-disconnect', 'authority-refusal', 'drain-cancellation', 'owner-shutdown')) {
      $owner = New-Owner
      $healthy = Invoke-Healthy $owner 1
      Assert-True ($healthy.Served -eq 1 -and $healthy.Refused -eq 0) 'cause-matrix healthy authority control'
      $pipe = Open-Client $owner
      try {
        if ($mode -eq 'peer-disconnect') {
          Write-Request $pipe (New-Request $owner)
          $pipe.Dispose()
        } elseif ($mode -eq 'authority-refusal') {
          Write-Request $pipe ((New-Request $owner 'build') + "`n")
          $reply = Read-Reply $pipe
          $retained.Add($reply)
          Assert-True (($reply | ConvertFrom-Json).accepted -eq $false) 'authority refusal is terminal denied, no body execution'
          $pipe.Dispose()
        } elseif ($mode -eq 'drain-cancellation') {
          Write-Request $pipe ((New-Request $owner) + "`n")
          $reply = Read-Reply $pipe
          Assert-True ($reply -match '^\{"payload":"') 'drain control received signed reply before withholding close'
          # Do not close until the unchanged production exchange token cancels.
          $watch = [Diagnostics.Stopwatch]::StartNew()
          while ($owner.Server.Statistics().Served -ne 2 -and $watch.ElapsedMilliseconds -lt 15000) { [Threading.Thread]::Sleep(10) }
          Assert-True ($owner.Server.Statistics().Served -eq 2) 'drain reaches its native terminal outcome'
          $pipe.Dispose()
        } else {
          Write-Request $pipe (New-Request $owner)
          $watch = [Diagnostics.Stopwatch]::StartNew()
          while ($owner.Server.Statistics().Connections -ne 2 -and $watch.ElapsedMilliseconds -lt 15000) { [Threading.Thread]::Sleep(10) }
          Assert-True ($owner.Server.Statistics().Connections -eq 2) 'shutdown has an active native connection'
          $owner.Server.Stop()
        }
        $s = Wait-Terminal $owner 2
      } finally { $pipe.Dispose() }
      if ($mode -ne 'owner-shutdown') {
        $before = $s.LastFailure
        $s = Invoke-Healthy $owner 3
        Assert-True ($s.Served -eq $(if ($mode -eq 'drain-cancellation') { 3 } else { 2 })) 'failure-isolation: next healthy connection succeeds'
        Assert-LastFailureUnchanged $before $s.LastFailure
      }
      $failure = Get-Summary $owner "cause-matrix $mode"
      if ($mode -eq 'authority-refusal') {
        Assert-Failure $failure 2 'authority' $false $false
        Assert-True ($failure.ExceptionClass -ceq 'none' -and $failure.Category -ceq 'authority-refusal') 'authority refusal is not an exception or cancellation'
      } elseif ($mode -eq 'drain-cancellation') {
        Assert-Failure $failure 2 'reply-drain' $true $false
        Assert-True ($failure.Category -ceq 'cancellation') 'swallowed drain cancellation remains observable'
      } elseif ($mode -eq 'owner-shutdown') {
        Assert-Failure $failure 2 'request-read' $true $true
      } else {
        Assert-True ($failure.Connection -eq 2 -and $failure.Head -ceq $head -and $failure.Category -ceq 'peer-disconnect') 'peer disconnect has native EOF or broken-pipe cause'
        Assert-True (-not $failure.ExchangeCancellationRequested -and -not $failure.OwnerShutdownRequested) 'peer disconnect is not cancellation'
        Assert-True ($failure.ExceptionClass -cin @('none', 'IOException')) 'peer actual safe exception class'
      }
      Write-Output ('PASS cause-matrix ' + $mode + ' ' + ($failure | ConvertTo-Json -Compress))
    }
  }
  if ($Case -in @('all', 'sanitization')) {
    Assert-True ([bool](Get-Command Format-NestedFailure -ErrorAction SilentlyContinue)) 'closed diagnostic formatter exists'
    $good = [ordered]@{ Connection=[long]1; Head=$head; ExceptionClass='unknown'; Category='unknown'; Phase='authority'; ExchangeCancellationRequested=$false; OwnerShutdownRequested=$false }
    Assert-True ((Format-NestedFailure ([pscustomobject]$good) 1) -match '^failure=\{') 'closed typed diagnostic accepted'
    foreach ($negative in @(
      @{ Extra=$marker }, @{ Connection='1' }, @{ Connection=[long]0 }, @{ Connection=[long]2 },
      @{ Head=('a' * 41) }, @{ Head=(('a' * 40) + "`n") }, @{ ExceptionClass=$marker }, @{ Category=$marker }, @{ Phase=$marker },
      @{ ExchangeCancellationRequested='false' }, @{ OwnerShutdownRequested=1 }
    )) {
      $bad = [ordered]@{}; foreach ($key in $good.Keys) { $bad[$key] = $good[$key] }
      foreach ($key in $negative.Keys) { $bad[$key] = $negative[$key] }
      $text = Format-NestedFailure ([pscustomobject]$bad) 1
      $retained.Add($text)
      Assert-True ($text -ceq 'failure=unavailable') 'closed-field/type/bound negative refuses unsafe diagnostic'
    }
    $missing = [ordered]@{}; foreach ($key in $good.Keys) { if ($key -ne 'Phase') { $missing[$key]=$good[$key] } }
    Assert-True ((Format-NestedFailure ([pscustomobject]$missing) 1) -ceq 'failure=unavailable') 'missing diagnostic field refuses'
    # This test couples to the private SafeExceptionClass/RecordFailure names to avoid a production test seam.
    $method = [ChaseSets.HeavyAdmission.NestedOwnerServer].GetMethod('SafeExceptionClass', [Reflection.BindingFlags]'NonPublic,Static')
    Assert-True ($null -ne $method) 'actual exception sanitizer exists'
    $value = $method.Invoke($null, @([Exception]::new($marker)))
    Assert-True ($value -ceq 'unknown') 'unrecognized actual exception class is explicit unknown'
    $owner = New-Owner
    $pipe = Open-Client $owner
    try { Write-Request $pipe ($marker + "`n"); $reply = Read-Reply $pipe; $retained.Add($reply) } finally { $pipe.Dispose() }
    $s = Wait-Terminal $owner 1
    Assert-True ($s.LastFailure.Category -ceq 'protocol-refusal') 'request-marker control reaches native protocol refusal'
    # Exercise the real capture and emitted consumer with an unrecognized
    # exception carrying a sensitive message, without a production test seam.
    $capture = [ChaseSets.HeavyAdmission.NestedOwnerServer].GetMethod('RecordFailure', [Reflection.BindingFlags]'NonPublic,Instance')
    $capture.Invoke($owner.Server, @([Exception]::new($marker), [Threading.CancellationToken]::None, $null))
    $failure = Get-Summary $owner 'sanitization'
    Assert-True ($failure.ExceptionClass -ceq 'unknown' -and $failure.Category -ceq 'unknown') 'actual unknown exception message is excluded by native capture and emitted consumer'
    Assert-True (($retained -join "`n") -notmatch [regex]::Escape($marker)) 'retained output contains no secret/request marker'
    Write-Output 'PASS sanitization: closed fields/types/bounds, unknown exception, retained-output request/secret exclusion'
  }
} finally {
  foreach ($server in $servers) { $server.Stop() }
  $resolved = [IO.Path]::GetFullPath($root)
  Assert-True ($resolved.StartsWith($temp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'cleanup stays in owned temp root'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "PASS heavy-nested-attribution case=$Case mutant=$Mutant source=$SourceRevision runtimeHead=$head priority=BelowNormal"
