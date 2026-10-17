[CmdletBinding()]
param(
  [ValidateSet('','machine-name','module-dir-selector','leaf-selector','root-from-scriptroot','omit-lock','container-hashed','archive-global','prefix-parse','all')]
  [string]$Mutant = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$runtime = $PSScriptRoot
$module = Join-Path $runtime 'orchestration-log-lock.psm1'
Import-Module $module -Force -DisableNameChecking
. (Join-Path $runtime 'interrupted-integration-test-support.ps1')

$containerRoot = 'D:\Users\ToddS\Source\Repos\chase-sets'
$containerRuntime = Join-Path $containerRoot '.orchestrator'
$archives = @('b3b4ac2d0d6e3d1aa6666e5b6179178ebcfaa780', '8106d4e12c4b3329e3b59372366c5a57e8dfacc1')
$cutoverName = 'Global\ChaseSetsOrchLog'
$privateName = '^Global\\ChaseSetsOrchLog-[0-9a-f]{64}$'
$refusal = 'orchestration log lock refused: exclusive writer lock timed out'
# A producer's post-go bound: its default 30 s lock wait plus 30 s of its own work.
$producerMilliseconds = 60000
$temp = Join-Path ([IO.Path]::GetTempPath()) ('orchestration-log-lock-' + [guid]::NewGuid().ToString('N'))
$children = [Collections.Generic.List[object]]::new()

function Assert($Condition, [string]$Message) { if (-not [bool]$Condition) { throw "ASSERTION FAILED: $Message" } }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }
function New-Directory([string]$Path) { [void][IO.Directory]::CreateDirectory($Path); $Path }
function New-LegRoot([string]$Name) { New-Directory (Join-Path $temp ($Name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))) }
function Get-Rows([string]$Path) { if (Test-Path -LiteralPath $Path) { @(Get-Content -LiteralPath $Path).Count } else { 0 } }
function Get-LastLine([string]$Text) {
  $lines = @("$Text" -split "`r?`n" | Where-Object { $_.Trim() })
  if ($lines.Count) { $lines[-1].Trim() } else { '' }
}
function Get-Tail([string]$Text) {
  $trimmed = "$Text".Trim()
  $trimmed.Substring([Math]::Max(0, $trimmed.Length - 400))
}

# Child lifecycle. Every lock child preloads (pwsh start, module import), writes
# a preloaded marker and waits for a go marker under its own deadline counted
# from its start, so start-up never runs inside a parent clock. The parent's
# bounds cover only post-go work. Streams are read asynchronously from start.
function Start-Child([string]$Label, [string]$Script, [string[]]$Arguments, [string]$WorkingDirectory = '', [string]$Ready = '', [string]$Release = '', [switch]$Plain) {
  $id = [guid]::NewGuid().ToString('N')
  $preloaded = Join-Path $temp "$id.preloaded"
  $go = Join-Path $temp "$id.go"
  $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
  $all = @('-NoProfile', '-NonInteractive', '-File', $Script) + $Arguments
  if (-not $Plain) { $all += @('-Preloaded', $preloaded, '-Go', $go) }
  foreach ($argument in $all) { [void]$psi.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($psi)
  $child = [pscustomobject]@{
    Label = $Label
    Process = $process
    Out = $process.StandardOutput.ReadToEndAsync()
    Err = $process.StandardError.ReadToEndAsync()
    Preloaded = $preloaded
    Go = $go
    Ready = $Ready
    Release = $Release
    Sent = $false
    Done = $false
    TimedOut = $false
    Exit = $null
    Stdout = ''
    Stderr = ''
  }
  $children.Add($child)
  $child
}

# Waits only for each child's preloaded marker or its exit, never a parent clock.
function Wait-Preloaded([object[]]$Batch) {
  foreach ($child in $Batch) {
    while (-not (Test-Path -LiteralPath $child.Preloaded) -and -not $child.Process.HasExited) { Start-Sleep -Milliseconds 20 }
    if (-not (Test-Path -LiteralPath $child.Preloaded)) {
      $result = Complete-Child $child 0
      Assert $false "$($child.Label) exited before preloading; exit=$($result.Exit), stderr tail=$(Get-Tail $result.Stderr)"
    }
  }
}

function Send-Go([object[]]$Batch) {
  foreach ($child in $Batch) {
    Write-Utf8 $child.Go 'go'
    $child.Sent = $true
  }
}

# Waits a bounded time for exit and kills on timeout, then collects the exit
# code and both streams and disposes the process exactly once.
function Complete-Child([object]$Child, [int]$Milliseconds = 10000) {
  if (-not $Child.Done) {
    if (-not $Child.Process.WaitForExit($Milliseconds)) {
      $Child.TimedOut = $true
      try { $Child.Process.Kill($true) } catch {}
      [void]$Child.Process.WaitForExit(3000)
    }
    [void]$Child.Out.Wait(3000)
    [void]$Child.Err.Wait(3000)
    $Child.Exit = if ($Child.Process.HasExited) { $Child.Process.ExitCode } else { 'running' }
    $Child.Stdout = if ($Child.Out.IsCompleted) { $Child.Out.Result } else { '' }
    $Child.Stderr = if ($Child.Err.IsCompleted) { $Child.Err.Result } else { '' }
    $Child.Process.Dispose()
    $Child.Done = $true
  }
  $Child
}

function Assert-Child([object]$Child, [int]$ExpectedExit, [int]$Milliseconds = 10000) {
  $result = Complete-Child $Child $Milliseconds
  Assert (-not $result.TimedOut) "$($result.Label) timed out and was killed; exit=$($result.Exit), stderr tail=$(Get-Tail $result.Stderr)"
  Assert ($result.Exit -eq $ExpectedExit) "$($result.Label) exit=$($result.Exit), stderr tail=$(Get-Tail $result.Stderr)"
  $result
}

# Post-go readiness: the holder announces acquisition from inside its body.
function Wait-Ready([object]$Child, [int]$Milliseconds = 10000) {
  $timer = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $Child.Ready) -and -not $Child.Process.HasExited -and $timer.ElapsedMilliseconds -lt $Milliseconds) { Start-Sleep -Milliseconds 20 }
  if (-not (Test-Path -LiteralPath $Child.Ready)) {
    $result = Complete-Child $Child 0
    Assert $false "$($Child.Label) did not reach its readiness marker; exit=$($result.Exit), stderr tail=$(Get-Tail $result.Stderr)"
  }
}

function Release-Holder([object]$Holder) {
  Write-Utf8 $Holder.Release 'release'
  [void](Assert-Child $Holder 0)
}

# Every exit path: release go'd holders first so no mutex is abandoned, then
# wait a bounded time, kill what remains and dispose everything.
function Stop-Children([int]$From) {
  for ($i = $From; $i -lt $children.Count; $i++) {
    $child = $children[$i]
    if (-not $child.Done -and $child.Sent -and $child.Release) { try { Write-Utf8 $child.Release 'release' } catch {} }
  }
  for ($i = $children.Count - 1; $i -ge $From; $i--) {
    $child = $children[$i]
    try { [void](Complete-Child $child $(if ($child.Sent) { 5000 } else { 0 })) } catch {}
    $children.RemoveAt($i)
  }
}

$childPrelude = @'
$ErrorActionPreference = 'Stop'
$lifetime = [Diagnostics.Stopwatch]::StartNew()
function Wait-Go {
  [IO.File]::WriteAllText($Preloaded, 'preloaded')
  # Own deadline from this child's start: an orphan exits if the parent dies.
  while (-not (Test-Path -LiteralPath $Go) -and $lifetime.Elapsed.TotalSeconds -lt 300) { Start-Sleep -Milliseconds 20 }
  if (-not (Test-Path -LiteralPath $Go)) { throw 'go marker deadline expired' }
}
'@

$workerBody = @'
try {
  Import-Module $Module -Force -DisableNameChecking
  $lock = @{ Timeout = [timespan]::FromMilliseconds($TimeoutMs) }
  # Archived modules predate -Root; every candidate worker passes it.
  if ($Root) { $lock.Root = $Root }
  Wait-Go
  Invoke-WithOrchestrationLogLock @lock -Body {
    if ($Ready) { [IO.File]::WriteAllText($Ready, 'acquired') }
    if ($Marker) { [IO.File]::AppendAllText($Marker, "row`n") }
    if ($Release) {
      $held = [Diagnostics.Stopwatch]::StartNew()
      while (-not (Test-Path -LiteralPath $Release) -and $held.Elapsed.TotalSeconds -lt $HoldSeconds) { Start-Sleep -Milliseconds 20 }
      if (-not (Test-Path -LiteralPath $Release)) { throw 'holder deadline expired' }
    }
  }
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
'@

# AC4's raw holder of the live name: 10 s to acquire, 15 s self-deadline.
$rawHolderBody = @'
$code = 1
$mutex = $null
$owned = $false
try {
  $mutex = [Threading.Mutex]::new($false, 'Global\ChaseSetsOrchLog')
  Wait-Go
  try { $owned = $mutex.WaitOne([timespan]::FromSeconds(10)) }
  catch [Threading.AbandonedMutexException] { $owned = $true }
  if (-not $owned) { throw 'raw holder could not acquire the live name' }
  [IO.File]::WriteAllText($Ready, 'acquired')
  $held = [Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path -LiteralPath $Release) -and $held.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 20 }
  if (-not (Test-Path -LiteralPath $Release)) { throw 'raw holder deadline expired' }
  $code = 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
} finally {
  if ($owned) { $mutex.ReleaseMutex() }
  if ($mutex) { $mutex.Dispose() }
}
exit $code
'@

$probeBody = @'
try {
  Import-Module $Module -Force -DisableNameChecking
  Wait-Go
  # Archived modules predate -Root.
  if ($Root) { Get-OrchestrationLogMutexName -Root $Root } else { Get-OrchestrationLogMutexName }
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
'@

$producerBody = @'
try {
  $arguments = $Parameters | ConvertFrom-Json -AsHashtable
  # A PowerShell location that differs from the process working directory is
  # where a relative ledger's two resolutions diverge.
  if ($Location) { Set-Location -LiteralPath $Location }
  Wait-Go
  & $Script @arguments | Out-Null
  exit 0
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
'@

function Write-ChildScript([string]$Name, [string]$Parameters, [string]$Body) {
  $path = Join-Path (New-Directory (Join-Path $temp 'children')) "$Name.ps1"
  Write-Utf8 $path ("param($Parameters, [string]`$Preloaded, [string]`$Go)`n" + $childPrelude + "`n" + $Body)
  $path
}

function Start-Worker([string]$Label, [string]$LockModule, [string]$Root, [string]$Ready = '', [string]$Release = '', [string]$Marker = '', [int]$TimeoutMs = 250, [int]$HoldSeconds = 15) {
  $arguments = @('-Module', $LockModule, '-TimeoutMs', [string]$TimeoutMs, '-HoldSeconds', [string]$HoldSeconds)
  if ($Root) { $arguments += @('-Root', $Root) }
  if ($Ready) { $arguments += @('-Ready', $Ready) }
  if ($Release) { $arguments += @('-Release', $Release) }
  if ($Marker) { $arguments += @('-Marker', $Marker) }
  Start-Child $Label $workerScript $arguments -Ready $Ready -Release $Release
}

function Start-NameProbe([string]$Label, [string]$LockModule, [string]$Root = '') {
  $arguments = @('-Module', $LockModule)
  if ($Root) { $arguments += @('-Root', $Root) }
  Start-Child $Label $probeScript $arguments
}

function Read-ScriptAst([string]$Path) {
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  Assert (@($errors).Count -eq 0) "$([IO.Path]::GetFileName($Path)) must parse"
  $ast
}

function Find-Commands([Management.Automation.Language.Ast]$Ast, [string]$Name) {
  @($Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true) | Where-Object { $_.GetCommandName() -ceq $Name })
}

function Get-ArgumentText([Management.Automation.Language.CommandAst]$Command, [string]$Parameter) {
  $elements = $Command.CommandElements
  for ($i = 1; $i -lt $elements.Count; $i++) {
    $element = $elements[$i]
    if ($element -is [Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -ceq $Parameter) {
      if ($element.Argument) { return $element.Argument.Extent.Text }
      if ($i + 1 -lt $elements.Count) { return $elements[$i + 1].Extent.Text }
      return ''
    }
  }
  $null
}

# AC1: one lexical name per root. The rule runs in-process on the module under
# test; a copy of that module is loaded in a child from its own directory.
function Test-RootRule([string]$LockModule) {
  $mark = $children.Count
  try {
    Import-Module $LockModule -Force -DisableNameChecking
    $leg = New-LegRoot 'ac1'
    $root = Join-Path $leg 'Root'
    $name = Get-OrchestrationLogMutexName -Root $root
    $aliases = [ordered]@{
      'case' = $root.ToUpperInvariant()
      'separator' = $root.Replace('\', '/')
      'trailing separator' = $root + '\'
      'parent segment' = Join-Path $leg 'x\..\Root'
      'current segment' = Join-Path $leg '.\Root\.'
    }
    foreach ($alias in $aliases.GetEnumerator()) {
      Assert ((Get-OrchestrationLogMutexName -Root $alias.Value) -ceq $name) "$($alias.Key) alias must share one name"
    }
    Assert ($name -cne (Get-OrchestrationLogMutexName -Root (Join-Path $leg 'Other'))) 'distinct roots must not share a name'
    Assert ($name -cmatch $privateName) 'non-container roots must use lowercase SHA256'
    Assert ((Get-OrchestrationLogMutexName -Root $containerRuntime) -ceq $cutoverName) 'exact container runtime retains cutover name'
    foreach ($alias in @($containerRuntime.ToLowerInvariant(), ($containerRuntime + '\.'), ($containerRuntime.Replace('\', '/') + '/'))) {
      Assert ((Get-OrchestrationLogMutexName -Root $alias) -ceq $cutoverName) "container alias retains cutover name: $alias"
    }
    Assert ((Get-OrchestrationLogMutexName -Root (Join-Path $containerRoot 'lane-01\.orchestrator')) -cmatch $privateName) 'lane runtime must be private'
    Assert ((Get-OrchestrationLogMutexName -Root (Join-Path $leg 'does-not-exist')) -cmatch $privateName) 'nonexistent root must be private'

    $copyDirectory = New-Directory (Join-Path $leg 'module-copy')
    $copy = Join-Path $copyDirectory 'orchestration-log-lock.psm1'
    Copy-Item -LiteralPath $LockModule -Destination $copy
    $probe = Start-NameProbe 'module copy name probe' $copy $copyDirectory
    Wait-Preloaded @($probe)
    Send-Go @($probe)
    $copyName = (Assert-Child $probe 0).Stdout.Trim()
    Assert ($copyName -cmatch $privateName) "module copy keyed to its own directory must be private: $copyName"

    # The governed body runs exactly once on a temp root.
    $trace = [Collections.Generic.List[string]]::new()
    $value = Invoke-WithOrchestrationLogLock -Root $root -Body { $trace.Add('inside'); 'held' }
    Assert ($value -ceq 'held' -and $trace.Count -eq 1 -and $trace[0] -ceq 'inside') 'governed log lock executes exactly once'
    $accepted = $true
    try { Invoke-WithOrchestrationLogLock -Body {} } catch { $accepted = $false; Assert ($_.Exception.Message -cmatch 'Root') 'missing Root diagnostic' }
    Assert (-not $accepted) 'missing Root must be refused before acquisition'
  } finally { Stop-Children $mark }
}

# AC2 writer check (H5's, extended to lease and -Root): each producer imports
# the governed module, never names or opens the mutex itself, and passes -Root
# on every lock call.
function Test-WriterWiring {
  foreach ($writer in 'log-event.ps1', 'cost-harvest.ps1', 'lease.ps1') {
    $path = Join-Path $runtime $writer
    $text = [IO.File]::ReadAllText($path)
    $ast = Read-ScriptAst $path
    $imports = @(Find-Commands $ast 'Import-Module' | Where-Object { $_.Extent.Text.Contains('orchestration-log-lock.psm1', [StringComparison]::Ordinal) })
    $calls = @(Find-Commands $ast 'Invoke-WithOrchestrationLogLock')
    $raw = $text.Contains('ChaseSetsOrchLog', [StringComparison]::Ordinal) -or $text.Contains('Threading.Mutex', [StringComparison]::Ordinal)
    Assert ($imports.Count -eq 1 -and $calls.Count -ge 1 -and -not $raw) "$writer does not use the governed log lock"
    foreach ($call in $calls) { Assert ($null -ne (Get-ArgumentText $call 'Root')) "$writer lock call must pass -Root" }
  }
}

# A dependency-complete producer copy. Its runtime directory is R1 (what a
# $PSScriptRoot root would lock); its output directory is R2 (the parent of
# the one file its locked body writes).
function New-ProducerRun([string]$Producer, [string]$Source, [string]$Base) {
  $runtimeCopy = New-Directory (Join-Path $Base 'runtime')
  $dependencies = switch ($Producer) {
    'log-event' { @('review-head-contract.psm1', 'routing-data.ps1') }
    'cost-harvest' { @('routing-data.ps1') }
    'lease' { @('lease-contract.psm1', 'routing-data.ps1') }
  }
  Copy-Item -LiteralPath $Source -Destination (Join-Path $runtimeCopy "$Producer.ps1")
  Copy-Item -LiteralPath $module -Destination $runtimeCopy
  foreach ($file in $dependencies) { Copy-Item -LiteralPath (Join-Path $runtime $file) -Destination $runtimeCopy }
  $run = [pscustomobject]@{
    Producer = $Producer
    Base = $Base
    Script = Join-Path $runtimeCopy "$Producer.ps1"
    RuntimeRoot = $runtimeCopy
    OutputRoot = ''
    Location = ''
    WorkingDirectory = $Base
    Parameters = $null
    Ledger = ''
    StrayLedger = ''
    Holder = $null
    Child = $null
    Result = $null
  }
  switch ($Producer) {
    'log-event' {
      $run.OutputRoot = New-Directory (Join-Path $Base 'output')
      $run.Ledger = Join-Path $run.OutputRoot 'events.jsonl'
      $run.Parameters = @{ Log = 'dispatch'; Kind = 'lane-complete'; Issue = 909830; LaneRole = 'implementation'; Pr = 909831; OutFile = $run.Ledger; NoBoard = $true }
    }
    'cost-harvest' {
      # A relative ledger written after Set-Location to a provider directory
      # that differs from the process working directory.
      $transcripts = New-Directory (Join-Path $Base 'transcripts')
      $transcript = @(
        '{"type":"system","subtype":"init","cwd":"C:\\x","model":"claude-opus-5"}'
        '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"num_turns":1,"total_cost_usd":0.01,"result":"done"}'
      )
      Write-Utf8 (Join-Path $transcripts 'synthetic-9830-lock.jsonl') (($transcript -join "`n") + "`n")
      $run.Location = New-Directory (Join-Path $Base 'provider')
      $run.OutputRoot = New-Directory (Join-Path $run.Location 'ledger')
      $run.WorkingDirectory = New-Directory (Join-Path $Base 'process-cwd')
      $run.Ledger = Join-Path $run.OutputRoot 'cost.jsonl'
      $run.StrayLedger = Join-Path (New-Directory (Join-Path $run.WorkingDirectory 'ledger')) 'cost.jsonl'
      $run.Parameters = @{ TranscriptDir = $transcripts; Ledger = 'ledger\cost.jsonl'; Backfill = $true }
    }
    'lease' {
      $run.OutputRoot = New-Directory (Join-Path $Base 'output')
      $run.Parameters = @{
        Action = 'HandoffCutoverRecovery'; Lease = (Join-Path $run.OutputRoot 'lease.json'); Holder = 'synthetic-9830'; Harness = 'claude'; Model = 'claude-opus-5-5'
        CurrentRecordPath = (Join-Path $run.OutputRoot 'current.json'); RecoveryCapabilityPath = (Join-Path $run.OutputRoot 'capability.json')
        HandoffReceiptPath = (Join-Path $run.OutputRoot 'receipt.json'); TransactionId = '0123456789abcdef0123456789abcdef'
      }
    }
  }
  $run
}

function Assert-ProducerOutcome([object]$Run, [string]$Held) {
  $result = $Run.Result
  Assert (-not $result.TimedOut) "$($result.Label) timed out and was killed; exit=$($result.Exit), stderr tail=$(Get-Tail $result.Stderr)"
  $stderr = Get-LastLine $result.Stderr
  $rows = Get-Rows $Run.Ledger
  $stray = Get-Rows $Run.StrayLedger
  switch ("$($Run.Producer)/$Held") {
    'log-event/runtime' {
      Assert ($result.Exit -eq 0 -and $rows -eq 1) "log-event appends once while its runtime root is held: exit=$($result.Exit) rows=$rows stderr=$stderr"
    }
    'cost-harvest/runtime' {
      Assert ($result.Exit -eq 0 -and $rows -eq 1 -and $stray -eq 0) "cost-harvest appends once to its provider-relative ledger while its runtime root is held: exit=$($result.Exit) rows=$rows cwdRows=$stray stderr=$stderr"
    }
    'lease/runtime' {
      # The handoff body calls the retired Handoff-CutoverRecoveryLease (a
      # non-goal); reaching that call is the observable proof of acquisition.
      $reached = $result.Stderr.Contains("The term 'Handoff-CutoverRecoveryLease' is not recognized", [StringComparison]::Ordinal)
      Assert ($result.Exit -eq 1 -and $reached -and -not $result.Stderr.Contains($refusal, [StringComparison]::Ordinal)) "lease reaches its locked body while its runtime root is held: exit=$($result.Exit) stderr=$stderr"
    }
    'log-event/output' {
      Assert ($result.Exit -eq 1 -and $stderr -ceq $refusal -and $rows -eq 0) "log-event refuses exactly with zero rows while its output root is held: exit=$($result.Exit) rows=$rows stderr=$stderr"
    }
    'cost-harvest/output' {
      Assert ($result.Exit -eq 1 -and $stderr -ceq $refusal -and $rows -eq 0 -and $stray -eq 0) "cost-harvest refuses exactly with zero rows while its provider ledger root is held: exit=$($result.Exit) rows=$rows cwdRows=$stray stderr=$stderr"
    }
    'lease/output' {
      Assert ($result.Exit -eq 1 -and $stderr -ceq $refusal) "lease refuses exactly before its body while its lease root is held: exit=$($result.Exit) stderr=$stderr"
    }
  }
}

# AC2: real producer copies. With R1 held each still writes once; with R2 held
# all three refuse concurrently at the default 30 s, and each holder releases
# only when its producer has exited.
function Test-ProducerRoots([hashtable]$Sources) {
  $mark = $children.Count
  try {
    $leg = New-LegRoot 'ac2'
    foreach ($held in 'runtime', 'output') {
      $runs = @(foreach ($producer in 'log-event', 'cost-harvest', 'lease') { New-ProducerRun $producer $Sources[$producer] (Join-Path $leg "$held-$producer") })
      foreach ($run in $runs) {
        $root = if ($held -ceq 'runtime') { $run.RuntimeRoot } else { $run.OutputRoot }
        # The self-deadline outlasts the producer bound; release is on producer exit.
        $ready = Join-Path $run.Base 'holder.ready'
        $release = Join-Path $run.Base 'holder.release'
        $run.Holder = Start-Worker "$($run.Producer) $held-root holder" $module $root -Ready $ready -Release $release -TimeoutMs 30000 -HoldSeconds 90
        $arguments = @('-Script', $run.Script, '-Parameters', ($run.Parameters | ConvertTo-Json -Compress))
        if ($run.Location) { $arguments += @('-Location', $run.Location) }
        $run.Child = Start-Child "$($run.Producer) with its $held root held" $producerScript $arguments $run.WorkingDirectory
      }
      Wait-Preloaded (@($runs.Holder) + @($runs.Child))
      foreach ($run in $runs) {
        Send-Go @($run.Holder)
        Wait-Ready $run.Holder
      }
      Send-Go @($runs.Child)
      foreach ($run in $runs) {
        $run.Result = Complete-Child $run.Child $producerMilliseconds
        Release-Holder $run.Holder
      }
      foreach ($run in $runs) { Assert-ProducerOutcome $run $held }
    }
  } finally { Stop-Children $mark }
}

# AC3: preloaded workers with -Timeout 250ms. (a) While a holder holds R, a
# worker on R refuses exactly with zero body, then runs once after release.
# (b) While R is held, a worker on a distinct root runs once. Holders release
# only after the worker exits.
function Test-Serialization([string]$LockModule) {
  $mark = $children.Count
  try {
    $leg = New-LegRoot 'ac3'
    $root = Join-Path $leg 'root'
    $sameMarker = Join-Path $leg 'same.jsonl'
    $otherMarker = Join-Path $leg 'other.jsonl'
    $holder = Start-Worker 'same-root holder' $LockModule $root -Ready (Join-Path $leg 'holder.ready') -Release (Join-Path $leg 'holder.release') -TimeoutMs 30000
    $contender = Start-Worker 'same-root contender' $LockModule $root -Marker $sameMarker
    $after = Start-Worker 'same-root worker after release' $LockModule $root -Marker $sameMarker
    $holder2 = Start-Worker 'second same-root holder' $LockModule $root -Ready (Join-Path $leg 'holder2.ready') -Release (Join-Path $leg 'holder2.release') -TimeoutMs 30000
    $other = Start-Worker 'distinct-root worker' $LockModule (Join-Path $leg 'other-root') -Marker $otherMarker
    Wait-Preloaded @($holder, $contender, $after, $holder2, $other)

    Send-Go @($holder)
    Wait-Ready $holder
    Send-Go @($contender)
    $refused = Assert-Child $contender 1
    Assert ((Get-LastLine $refused.Stderr) -ceq $refusal) 'same-root refusal text'
    Assert ((Get-Rows $sameMarker) -eq 0) 'refused contender must not write'
    Release-Holder $holder
    Send-Go @($after)
    [void](Assert-Child $after 0)
    Assert ((Get-Rows $sameMarker) -eq 1) 'same-root worker runs once after release'

    Send-Go @($holder2)
    Wait-Ready $holder2
    Send-Go @($other)
    [void](Assert-Child $other 0)
    Assert ((Get-Rows $otherMarker) -eq 1) 'distinct root writes once while the first root is held'
    Release-Holder $holder2
  } finally { Stop-Children $mark }
}

# AC6: both historical carriers rewrite exactly the archive they extract.
function Test-CarrierWiring {
  $carriers = @(
    [pscustomobject]@{ File = 'interrupted-integration-test-support.ps1'; Function = 'Test-7963ResumeCarrier' }
    [pscustomobject]@{ File = 'integration-dispatch-test-support.ps1'; Function = 'Test-7962NativeControls' }
  )
  foreach ($carrier in $carriers) {
    $ast = Read-ScriptAst (Join-Path $runtime $carrier.File)
    $definition = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -ceq $carrier.Function })
    Assert ($definition.Count -eq 1) "$($carrier.Function) carrier must exist once"
    $expand = @(Find-Commands $definition[0] 'Expand-Archive')
    $repair = @(Find-Commands $definition[0] 'Repair-ExtractedOrchestrationLogLock')
    $bound = $expand.Count -eq 1 -and $repair.Count -eq 1 -and $repair[0].Extent.StartOffset -gt $expand[0].Extent.StartOffset -and
      (Get-ArgumentText $repair[0] 'ExtractedRoot') -ceq (Get-ArgumentText $expand[0] 'DestinationPath')
    Assert $bound "$($carrier.Function) must rewrite the archive it extracts"
  }
}

# AC4 keep-name and AC6 archived modules under one bounded raw holder of the
# live name: the container worker refuses exactly with zero body, each archived
# worker (extracted through the shared helper) runs once on its private name,
# and after release the container worker runs once. The live name is held only
# for that window.
function Test-CutoverAndArchives([switch]$SkipArchiveRewrite) {
  $mark = $children.Count
  try {
    $leg = New-LegRoot 'ac4-ac6'
    $extracted = @(foreach ($commit in $archives) {
      $zip = Join-Path $leg "$commit.zip"
      $root = Join-Path $leg $commit
      $archiveOutput = & git -C (Split-Path -Parent $runtime) archive --format=zip "--output=$zip" $commit .orchestrator 2>&1
      Assert ($LASTEXITCODE -eq 0) "archive $commit failed: $archiveOutput"
      Expand-Archive -LiteralPath $zip -DestinationPath $root
      # archive-global skips the rewrite, so the archived literal survives.
      if (-not $SkipArchiveRewrite) { Repair-ExtractedOrchestrationLogLock -ExtractedRoot $root | Out-Null }
      [pscustomobject]@{ Commit = $commit; Root = $root; Module = Join-Path $root '.orchestrator\orchestration-log-lock.psm1'; Marker = Join-Path $leg "$commit.jsonl" }
    })
    $cutMarker = Join-Path $leg 'cutover.jsonl'
    $afterMarker = Join-Path $leg 'after-release.jsonl'
    $rawReady = Join-Path $leg 'raw.ready'
    $rawRelease = Join-Path $leg 'raw.release'
    $raw = Start-Child 'raw live-name holder' $rawHolderScript @('-Ready', $rawReady, '-Release', $rawRelease) -Ready $rawReady -Release $rawRelease
    $cut = Start-Worker 'container cutover contender' $module $containerRuntime -Marker $cutMarker
    $archived = @(foreach ($archive in $extracted) { Start-Worker "archived worker $($archive.Commit)" $archive.Module '' -Marker $archive.Marker })
    # Live writers share the cutover name, so the run after release waits as a
    # container writer does (the 30 s default) instead of racing them at 250 ms.
    $after = Start-Worker 'container worker after release' $module $containerRuntime -Marker $afterMarker -TimeoutMs 250
    $probes = @(foreach ($archive in $extracted) { Start-NameProbe "archive name probe $($archive.Commit)" $archive.Module })
    Wait-Preloaded (@($raw, $cut) + $archived + @($after) + $probes)

    Send-Go @($raw)
    # A live writer may hold the name: wait out the holder's own 10 s acquire
    # plus the 10 s finish, so its refusal is reported rather than killed.
    Wait-Ready $raw 20000
    Send-Go @($cut)
    $cutResult = Assert-Child $cut 1
    Assert ((Get-LastLine $cutResult.Stderr) -ceq $refusal -and (Get-Rows $cutMarker) -eq 0) "container cutover contender refuses exactly with zero body: stderr=$(Get-LastLine $cutResult.Stderr) rows=$(Get-Rows $cutMarker)"
    Send-Go $archived
    $outcomes = @(for ($i = 0; $i -lt $archived.Count; $i++) {
      $result = Complete-Child $archived[$i]
      $rows = Get-Rows $extracted[$i].Marker
      $exit = if ($result.TimedOut) { 'timeout' } else { $result.Exit }
      [pscustomobject]@{ Ok = ($exit -eq 0 -and $rows -eq 1); Text = "$($extracted[$i].Commit) exit=$exit rows=$rows stderr=$(Get-LastLine $result.Stderr)" }
    })
    Assert (@($outcomes | Where-Object { -not $_.Ok }).Count -eq 0) "archived workers run once under the live-name holder: $(@($outcomes.Text) -join '; ')"
    Release-Holder $raw
    Send-Go @($after)
    # Its own 30 s lock wait plus the 10 s finish.
    [void](Assert-Child $after 0 10000)
    Assert ((Get-Rows $afterMarker) -eq 1) 'container worker runs once after release'

    # A child loading each extracted module gets that root's AC1 name.
    Send-Go $probes
    for ($i = 0; $i -lt $probes.Count; $i++) {
      $archiveName = (Assert-Child $probes[$i] 0).Stdout.Trim()
      $expected = Get-OrchestrationLogMutexName -Root (Join-Path $extracted[$i].Root '.orchestrator')
      Assert ($archiveName -ceq $expected -and $archiveName -cmatch $privateName) "archive $($extracted[$i].Commit) must use its extracted root's private name: $archiveName"
    }
  } finally { Stop-Children $mark }
}

# AC5: dispatch-count-policy's F2 regression run with the given writer.
function Test-WriterPrefixParse([string]$Logger) {
  $mark = $children.Count
  try {
    $evidence = New-LegRoot 'f2'
    $arguments = @('-ControllerRoot', (Split-Path -Parent $runtime), '-EvidenceRoot', $evidence, '-LoggerScriptPath', $Logger, '-RegressionOnly', 'F2', '-SkipMutants')
    $f2 = Start-Child 'F2 regression' (Join-Path $runtime 'dispatch-count-policy.test.ps1') $arguments -Plain
    $result = Complete-Child $f2 300000
    Assert (-not $result.TimedOut) "F2 regression timed out and was killed; exit=$($result.Exit), stderr tail=$(Get-Tail $result.Stderr)"
    $failed = @($result.Stdout -split "`r?`n" | Where-Object { $_ -clike 'FAIL *' } | ForEach-Object { $_.Trim() })
    $summary = $result.Stdout -cmatch 'dispatch-count-regression F2 checks=\d+ failures=0'
    Assert ($result.Exit -eq 0 -and $failed.Count -eq 0 -and $summary) "F2 writer prefix parse failed: $($failed -join ' | ')"
  } finally { Stop-Children $mark }
}

# Mutants: each transformation applies exactly once to a temp copy, the AC's
# governing leg runs against that copy, and KILLED prints only when that leg's
# exact assertion is observed failing.
function New-Mutant([string]$Source, [string]$Old, [string]$New, [string]$Label) {
  $count = [regex]::Matches($Source, [regex]::Escape($Old)).Count
  Assert ($count -eq 1) "$Label mutant anchor must occur once, found $count"
  $Source.Replace($Old, $New)
}

function Write-Mutant([string]$Name, [string]$FileName, [string]$Text) {
  $path = Join-Path (New-LegRoot "mutant-$Name") $FileName
  Write-Utf8 $path $Text
  $path
}

function Assert-Killed([string]$Name, [string]$Pattern, [scriptblock]$Leg) {
  $observed = $null
  try { & $Leg | Out-Null } catch { $observed = $_.Exception.Message }
  if ($null -eq $observed) { throw "SURVIVED ${Name}: its governing leg passed" }
  if ($observed -cnotmatch $Pattern) { throw "SURVIVED ${Name}: failed outside its governing assertion: $observed" }
  Write-Output "KILLED ${Name}: $observed"
}

# prefix-parse moves log-event's prefix parse (the $dispatchHistory block)
# inside the lock body, after the target-parent check.
function New-PrefixParseMutant {
  $source = [IO.File]::ReadAllText((Join-Path $runtime 'log-event.ps1'))
  $newline = if ($source.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = [Collections.Generic.List[string]]::new([string[]]($source -split "`r?`n"))
  $starts = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].StartsWith('$dispatchHistory = ', [StringComparison]::Ordinal)) { $i } })
  Assert ($starts.Count -eq 1) 'prefix-parse block must occur once'
  $end = $starts[0]
  while ($end -lt $lines.Count -and $lines[$end] -cne '} }') { $end++ }
  Assert ($end -lt $lines.Count) 'prefix-parse block must close'
  $block = $lines.GetRange($starts[0], $end - $starts[0] + 1)
  $lines.RemoveRange($starts[0], $end - $starts[0] + 1)
  $check = '  if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {'
  $anchors = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -ceq $check) { $i } })
  Assert ($anchors.Count -eq 1 -and $lines[$anchors[0] + 2] -ceq '  }') 'prefix-parse lock body anchor must occur once'
  $lines.InsertRange($anchors[0] + 3, $block)
  $mutated = $lines -join $newline
  $tokens = $null
  $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($mutated, [ref]$tokens, [ref]$errors)
  Assert (@($errors).Count -eq 0) "prefix-parse mutant must parse: $(@($errors | ForEach-Object Message) -join '; ')"
  $lock = @(Find-Commands $ast 'Invoke-WithOrchestrationLogLock')
  $assignments = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] }, $true) | Where-Object { $_.Left.Extent.Text -ceq '$dispatchHistory' })
  $inside = $lock.Count -eq 1 -and $assignments.Count -eq 1 -and
    $assignments[0].Extent.StartOffset -gt $lock[0].Extent.StartOffset -and $assignments[0].Extent.EndOffset -lt $lock[0].Extent.EndOffset
  Assert $inside 'prefix-parse mutant must move the prefix parse inside the lock body'
  $mutated
}

New-Item -ItemType Directory -Path $temp -Force | Out-Null
try {
  $workerScript = Write-ChildScript 'worker' '[string]$Module, [string]$Root, [string]$Ready, [string]$Release, [string]$Marker, [int]$TimeoutMs = 250, [int]$HoldSeconds = 15' $workerBody
  $rawHolderScript = Write-ChildScript 'raw-holder' '[string]$Ready, [string]$Release' $rawHolderBody
  $probeScript = Write-ChildScript 'name-probe' '[string]$Module, [string]$Root' $probeBody
  $producerScript = Write-ChildScript 'producer' '[string]$Script, [string]$Location, [string]$Parameters' $producerBody
  $producers = @{
    'log-event' = Join-Path $runtime 'log-event.ps1'
    'cost-harvest' = Join-Path $runtime 'cost-harvest.ps1'
    'lease' = Join-Path $runtime 'lease.ps1'
  }

  Test-RootRule $module
  Write-Output 'PASS AC1 one lexical name per root; exact container keeps the cutover name; lane, nonexistent and self-keyed module copy roots are private'
  Test-WriterWiring
  Test-ProducerRoots $producers
  Write-Output 'PASS AC2 log-event, cost-harvest and lease lock the parent they write: runtime root held appends, output root held refuses exactly with zero rows'
  Test-Serialization $module
  Write-Output 'PASS AC3 same root serializes across processes; distinct roots run concurrently'
  Test-CarrierWiring
  Test-CutoverAndArchives
  Write-Output 'PASS AC4 live-name holder refuses the container worker exactly with zero body; it runs once after release'
  Write-Output 'PASS AC6 both archives rewritten by the shared helper: archived workers run once under the live-name holder on private names'

  if ($Mutant) {
    $registered = @('machine-name', 'module-dir-selector', 'leaf-selector', 'root-from-scriptroot', 'omit-lock', 'container-hashed', 'archive-global', 'prefix-parse')
    $selected = if ($Mutant -ceq 'all') { $registered } else { @($Mutant) }
    $lockSource = [IO.File]::ReadAllText($module)
    $selector = "  if (`$canonical -ceq `$containerRuntime) { return 'Global\ChaseSetsOrchLog' }"
    $refusalPattern = [regex]::Escape($refusal)
    foreach ($mutantName in $selected) {
      try {
        switch ($mutantName) {
          'machine-name' {
            $copy = Write-Mutant $mutantName 'orchestration-log-lock.psm1' (New-Mutant $lockSource '  $canonical = [IO.Path]::GetFullPath($Root)' "  `$canonical = 'C:\\mutant-machine'" $mutantName)
            Assert-Killed "$mutantName AC1" '^ASSERTION FAILED: distinct roots must not share a name$' { Test-RootRule $copy }
            Assert-Killed "$mutantName AC3(b)" "^ASSERTION FAILED: distinct-root worker exit=1, stderr tail=$refusalPattern$" { Test-Serialization $copy }
          }
          'module-dir-selector' {
            $new = "  if (`$canonical -ceq `$containerRuntime -or `$canonical -ceq `$PSScriptRoot.ToLowerInvariant()) { return 'Global\ChaseSetsOrchLog' }"
            $copy = Write-Mutant $mutantName 'orchestration-log-lock.psm1' (New-Mutant $lockSource $selector $new $mutantName)
            Assert-Killed "$mutantName AC1" '^ASSERTION FAILED: module copy keyed to its own directory must be private: Global\\ChaseSetsOrchLog$' { Test-RootRule $copy }
          }
          'leaf-selector' {
            $new = "  if (`$canonical.EndsWith('\.orchestrator')) { return 'Global\ChaseSetsOrchLog' }"
            $copy = Write-Mutant $mutantName 'orchestration-log-lock.psm1' (New-Mutant $lockSource $selector $new $mutantName)
            Assert-Killed "$mutantName AC1" '^ASSERTION FAILED: lane runtime must be private$' { Test-RootRule $copy }
          }
          'container-hashed' {
            $copy = Write-Mutant $mutantName 'orchestration-log-lock.psm1' (New-Mutant $lockSource $selector '  # MUTANT container hashed' $mutantName)
            Assert-Killed "$mutantName AC1" '^ASSERTION FAILED: exact container runtime retains cutover name$' { Test-RootRule $copy }
          }
          'omit-lock' {
            $text = New-Mutant $lockSource '    try { $owned = $mutex.WaitOne($Timeout) }' '    try { $owned = $false }' $mutantName
            $text = New-Mutant $text '    if (-not $owned) { throw "orchestration log lock refused: exclusive writer lock timed out" }' '    # MUTANT refusal removed' $mutantName
            $copy = Write-Mutant $mutantName 'orchestration-log-lock.psm1' $text
            Assert-Killed "$mutantName AC3(a)" '^ASSERTION FAILED: same-root contender exit=0, stderr tail=$' { Test-Serialization $copy }
          }
          'root-from-scriptroot' {
            $variants = @(
              [pscustomobject]@{
                Producer = 'log-event'
                Old = '$targetParent = Split-Path -Parent ([IO.Path]::GetFullPath($target))'
                New = '$targetParent = $PSScriptRoot'
                Pattern = "^ASSERTION FAILED: log-event appends once while its runtime root is held: exit=1 rows=0 stderr=$refusalPattern$"
              }
              [pscustomobject]@{
                Producer = 'cost-harvest'
                Old = '$ledgerParent = Split-Path -Parent ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Ledger))'
                New = '$ledgerParent = $PSScriptRoot'
                Pattern = "^ASSERTION FAILED: cost-harvest appends once to its provider-relative ledger while its runtime root is held: exit=1 rows=0 cwdRows=0 stderr=$refusalPattern$"
              }
              [pscustomobject]@{
                Producer = 'lease'
                Old = '$leaseParent = Split-Path -Parent ([IO.Path]::GetFullPath($Lease))'
                New = '$leaseParent = $PSScriptRoot'
                Pattern = "^ASSERTION FAILED: lease reaches its locked body while its runtime root is held: exit=1 stderr=$refusalPattern$"
              }
            )
            foreach ($variant in $variants) {
              $sources = $producers.Clone()
              $text = New-Mutant ([IO.File]::ReadAllText($producers[$variant.Producer])) $variant.Old $variant.New "$mutantName $($variant.Producer)"
              $sources[$variant.Producer] = Write-Mutant "$mutantName-$($variant.Producer)" "$($variant.Producer).ps1" $text
              Assert-Killed "$mutantName $($variant.Producer) AC2" $variant.Pattern { Test-ProducerRoots $sources }
            }
          }
          'archive-global' {
            $pattern = '^ASSERTION FAILED: archived workers run once under the live-name holder: ' + (@($archives | ForEach-Object { [regex]::Escape("$_ exit=1 rows=0 stderr=$refusal") }) -join '; ') + '$'
            Assert-Killed "$mutantName AC6" $pattern { Test-CutoverAndArchives -SkipArchiveRewrite }
          }
          'prefix-parse' {
            $copy = Write-Mutant $mutantName 'log-event.ps1' (New-PrefixParseMutant)
            # Control: the same F2 leg passes with the candidate writer.
            Test-WriterPrefixParse $producers['log-event']
            $modes = 'logger', 'logger-tail', 'logger-rewrite', 'logger-unterminated'
            $pattern = '^ASSERTION FAILED: F2 writer prefix parse failed: ' + (@($modes | ForEach-Object { [regex]::Escape("FAIL F2-${_}: ASSERTION FAILED: $_ prefix parse must not hold the writer mutex") }) -join ' \| ') + '$'
            Assert-Killed "$mutantName AC5" $pattern { Test-WriterPrefixParse $copy }
          }
        }
      } finally {
        Import-Module $module -Force -DisableNameChecking
      }
    }
    Write-Output "PASS mutants killed at their governing assertions: $($selected -join ',')"
  }
} finally {
  Stop-Children 0
  if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
