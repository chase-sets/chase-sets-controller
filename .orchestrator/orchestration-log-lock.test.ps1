[CmdletBinding()]
param(
  # none runs the candidate. A mutant name (or all) first runs its bound cases on
  # the unmutated candidate as the in-control arm, then requires each bound case
  # to fail on the mutant for the bound reason: KILLED.
  [ValidateSet('none', 'all', 'machine-name', 'module-dir-selector', 'leaf-selector', 'root-from-scriptroot', 'relative-base', 'omit-lock', 'container-hashed', 'archive-global')]
  [string]$Mutant = 'none'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Import-Module (Join-Path $PSScriptRoot 'orchestration-log-lock.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'routing-data-test-support.ps1')
. (Join-Path $PSScriptRoot 'integration-dispatch-test-support.ps1')

# #122: the writer lock is named from the root it protects. Every cross-process
# case runs real pwsh children: holders keep a mutex until the test closes their
# stdin, which it does only after the producer or worker under test has exited.
$script:RawName = 'Global\ChaseSetsOrchLog'
$script:ContainerRoot = 'D:\Users\ToddS\Source\Repos\chase-sets\.orchestrator'
$script:Refusal = 'orchestration log lock refused: exclusive writer lock timed out'
# AC6 extracts the archived runtimes the two carriers extract, plus the last
# public pre-change release, whose module hard-codes the same machine-wide name.
$script:ArchivedRuntimes = [ordered]@{
  'b3b4ac2d' = 'b3b4ac2d0d6e3d1aa6666e5b6179178ebcfaa780'
  '8106d4e1' = '8106d4e12c4b3329e3b59372366c5a57e8dfacc1'
  'controller-v2.122' = '76dd98f6652a7d9d46393010cc1f5c8e9117c399'
}
$script:Controller = Split-Path -Parent $PSScriptRoot
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('orchestration-log-lock-test-' + [guid]::NewGuid().ToString('N'))
$script:Transcripts = Join-Path $script:TestRoot 'transcripts'
$script:Children = [Collections.Generic.List[object]]::new()
$script:Checks = 0

# ---- mutants and their bound cases -------------------------------------------
function New-LockEdit([string]$File, [string]$Anchor, [string]$Replacement) {
  [pscustomobject]@{ file = $File; anchor = $Anchor; replacement = $Replacement }
}
function New-LockBinding([string]$Case, [string[]]$Expect) {
  [pscustomobject]@{ case = $Case; expect = $Expect }
}
$script:Selector = '  if ($canonical -ceq $script:OrchestrationLogContainerRoot) { return "Global\ChaseSetsOrchLog" }'
$script:MutantEdits = @{
  # The B rule: one name for every root. The name is synthetic so no mutant arm
  # ever holds the live name; only AC4 holds it, for one refusal.
  'machine-name' = @(New-LockEdit 'orchestration-log-lock.psm1' $script:Selector "  return 'Global\ChaseSetsOrchLog-SYNTHETIC-MACHINE-$([guid]::NewGuid().ToString('N'))' # MUTANT machine-name")
  'module-dir-selector' = @(New-LockEdit 'orchestration-log-lock.psm1' $script:Selector '  if ($canonical -ceq $PSScriptRoot.TrimEnd(''\'', ''/'').ToLowerInvariant()) { return "Global\ChaseSetsOrchLog" } # MUTANT module-dir-selector')
  'leaf-selector' = @(New-LockEdit 'orchestration-log-lock.psm1' $script:Selector '  if ([IO.Path]::GetFileName($canonical) -ceq ''.orchestrator'') { return "Global\ChaseSetsOrchLog" } # MUTANT leaf-selector')
  'root-from-scriptroot' = @(
    New-LockEdit 'log-event.ps1' 'Invoke-WithOrchestrationLogLock -Root $targetParent -Body {' 'Invoke-WithOrchestrationLogLock -Root $PSScriptRoot -Body { # MUTANT root-from-scriptroot'
    New-LockEdit 'cost-harvest.ps1' 'Invoke-WithOrchestrationLogLock -Root $ledgerRoot -Body {' 'Invoke-WithOrchestrationLogLock -Root $PSScriptRoot -Body { # MUTANT root-from-scriptroot'
  )
  # Resolves a relative ledger against the process directory instead of the
  # provider location Add-Content writes through.
  'relative-base' = @(New-LockEdit 'cost-harvest.ps1' '$ledgerRoot = Split-Path -Parent ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Ledger))' '$ledgerRoot = Split-Path -Parent ([IO.Path]::GetFullPath($Ledger)) # MUTANT relative-base')
  'omit-lock' = @(
    New-LockEdit 'orchestration-log-lock.psm1' 'try { $owned = $mutex.WaitOne($Timeout) }' 'try { $owned = $false } # MUTANT omit-lock'
    New-LockEdit 'orchestration-log-lock.psm1' 'if (-not $owned) { throw "orchestration log lock refused: exclusive writer lock timed out" }' '# MUTANT omit-lock: no refusal'
  )
  'container-hashed' = @(New-LockEdit 'orchestration-log-lock.psm1' $script:Selector '  # MUTANT container-hashed')
  # Skips the archive rewrite; the candidate subject is otherwise unchanged.
  'archive-global' = @()
}
$refused = "observed 'REFUSED $($script:Refusal)' rows=0"
$rawObserved = "observed 'Global\ChaseSetsOrchLog'"
$script:Bindings = [ordered]@{
  'machine-name' = @(
    New-LockBinding 'AC1' @('AC1 distinct roots get distinct names')
    New-LockBinding 'AC3b' @("AC3b a worker on a distinct root runs once while another root is held; $refused")
  )
  'module-dir-selector' = @(New-LockBinding 'AC1' @("AC1 a temp module copy keyed to its own .orchestrator directory, which holds a ledger, is hashed; $rawObserved"))
  'leaf-selector' = @(New-LockBinding 'AC1' @("AC1 a temp module copy keyed to its own .orchestrator directory, which holds a ledger, is hashed; $rawObserved", "AC1 <container>\lane-01\.orchestrator is hashed; $rawObserved"))
  'root-from-scriptroot' = @(
    New-LockBinding 'AC2-R1' @("AC2 log-event appends exactly one row to R2 while its own R1 is held; $refused", "AC2 cost-harvest appends exactly one row to R2 while its own R1 is held; $refused")
    New-LockBinding 'AC2-R2' @("AC2 log-event refuses exactly with zero rows while R2 is held; observed 'COMPLETED' rows=1", "AC2 cost-harvest refuses exactly with zero rows while R2 is held; observed 'COMPLETED' rows=1")
  )
  'relative-base' = @(New-LockBinding 'AC2-R2' @("AC2 cost-harvest-relative refuses exactly with zero rows while R2 is held; observed 'COMPLETED' rows=1"))
  'omit-lock' = @(New-LockBinding 'AC3a' @("AC3a a worker on the held root refuses exactly with zero body; observed 'RAN' rows=1"))
  'container-hashed' = @(New-LockBinding 'AC4' @("AC4 a container-root worker refuses exactly with zero body while raw Global\ChaseSetsOrchLog is held; observed 'RAN' rows=1"))
  'archive-global' = @(New-LockBinding 'AC6' @("worker runs once while raw Global\ChaseSetsOrchLog is held; $refused"))
}

# ---- child scripts -------------------------------------------------------------
$script:HolderSource = @'
param([string]$Name, [string]$Module, [string]$Root)
$ErrorActionPreference = 'Stop'
if ($Module) {
  Import-Module $Module -Force -DisableNameChecking
  $Name = Get-OrchestrationLogMutexName -Root $Root
}
$mutex = [Threading.Mutex]::new($false, $Name)
$owned = $false
try {
  try { $owned = $mutex.WaitOne([timespan]::FromSeconds(30)) }
  catch [Threading.AbandonedMutexException] { $owned = $true }
  if (-not $owned) { [Console]::Out.WriteLine('BUSY ' + $Name); exit 4 }
  [Console]::Out.WriteLine('HELD ' + $Name)
  # Held until the test closes stdin, which it does only after the producer or
  # worker under test has exited. Never released on a timer.
  [void][Console]::In.ReadToEnd()
} finally {
  if ($owned) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
[Console]::Out.WriteLine('RELEASED ' + $Name)
'@
$script:WorkerSource = @'
param([string]$Module, [string]$Marker, [string]$Root, [switch]$Archived)
$ErrorActionPreference = 'Stop'
Import-Module $Module -Force -DisableNameChecking
if (-not (Get-Command Invoke-WithOrchestrationLogLock).Parameters.ContainsKey('Timeout')) {
  [Console]::Out.WriteLine('UNSUPPORTED Invoke-WithOrchestrationLogLock has no -Timeout')
  exit 5
}
# An archived module predates -Root and names its writer lock itself.
$name = if ($Archived) { Get-OrchestrationLogMutexName } else { Get-OrchestrationLogMutexName -Root $Root }
[Console]::Out.WriteLine('READY ' + $name)
if ([Console]::In.ReadLine() -cne 'go') { exit 6 }
$arguments = @{ Body = { [IO.File]::AppendAllText($Marker, 'body' + [Environment]::NewLine) }; Timeout = [timespan]::FromMilliseconds(250) }
if (-not $Archived) { $arguments.Root = $Root }
try {
  Invoke-WithOrchestrationLogLock @arguments
  [Console]::Out.WriteLine('RAN')
} catch {
  [Console]::Out.WriteLine('REFUSED ' + $_.Exception.Message)
  exit 3
}
'@
$script:NamesSource = @'
param([string]$Module, [string]$RootsFile, [string]$Marker, [string]$OutFile)
$ErrorActionPreference = 'Stop'
Import-Module $Module -Force -DisableNameChecking
$names = @(foreach ($root in [IO.File]::ReadAllLines($RootsFile)) { Get-OrchestrationLogMutexName -Root $root })
$omittedName = 'RETURNED'
try { [void](Get-OrchestrationLogMutexName) } catch { $omittedName = $_.FullyQualifiedErrorId }
$omittedInvoke = 'RAN'
try { Invoke-WithOrchestrationLogLock -Body { [IO.File]::AppendAllText($Marker, 'body' + [Environment]::NewLine) } -Timeout ([timespan]::FromMilliseconds(250)) }
catch { $omittedInvoke = $_.FullyQualifiedErrorId }
$document = [ordered]@{ names = $names; omittedName = $omittedName; omittedInvoke = $omittedInvoke }
[IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $document -Depth 4), [Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine('NAMES')
'@
$script:ProducerSource = @'
param([string]$Producer, [string]$ArgumentsFile, [string]$Location)
$ErrorActionPreference = 'Stop'
$arguments = @{}
foreach ($property in ([IO.File]::ReadAllText($ArgumentsFile) | ConvertFrom-Json).PSObject.Properties) { $arguments[$property.Name] = $property.Value }
# A provider location that differs from the process directory, as after any
# Set-Location: a relative ledger resolves against the provider location.
if ($Location) { Set-Location -LiteralPath $Location }
try {
  & $Producer @arguments | Out-Null
  [Console]::Out.WriteLine('COMPLETED')
} catch {
  [Console]::Out.WriteLine('REFUSED ' + $_.Exception.Message)
  exit 3
}
'@

# ---- results ---------------------------------------------------------------------
function New-LockResult([string]$Case, [string]$Subject) {
  [pscustomobject]@{ case = $Case; subject = $Subject; checks = 0; failures = [Collections.Generic.List[string]]::new(); blocked = [Collections.Generic.List[string]]::new(); harness = $null }
}
function Add-LockCheck($Result, [bool]$Condition, [string]$Message) {
  $script:Checks++
  $Result.checks++
  if (-not $Condition) { $Result.failures.Add("ASSERTION FAILED: $Message") }
}
function Test-LockPassed($Result) { -not $Result.harness -and $Result.failures.Count -eq 0 }
function Write-LockResult($Result, [string]$Prefix = '') {
  if ($Result.harness) { Write-Output "$($Prefix)ERROR $($Result.case) $($Result.subject): $($Result.harness)" }
  foreach ($failure in $Result.failures) { Write-Output "$($Prefix)FAIL $($Result.case) $($Result.subject): $failure" }
  foreach ($item in $Result.blocked) { Write-Output "$($Prefix)BLOCKED $($Result.case) $($Result.subject): $item" }
  if ((Test-LockPassed $Result) -and $Result.checks -gt 0) {
    Write-Output "$($Prefix)PASS $($Result.case) $($Result.subject) checks=$($Result.checks)$(if ($Result.blocked.Count) { ' (evaluated parts only)' })"
  }
}
function Get-MutantOutcome($Result, [string[]]$Expect) {
  if ($Result.harness) { return 'ERROR' }
  if ($Result.failures.Count -eq 0) { if ($Result.blocked.Count) { return 'NOT_EVALUATED' } return 'SURVIVED' }
  $text = $Result.failures -join ' || '
  foreach ($fragment in $Expect) { if (-not $text.Contains($fragment, [StringComparison]::Ordinal)) { return 'FAILED_FOR_ANOTHER_REASON' } }
  return 'KILLED'
}
function Write-MutantOutcome([string]$Name, $Binding, $Result, [string]$Outcome) {
  $detail = if ($Result.harness) { $Result.harness }
    elseif ($Outcome -ceq 'KILLED') { @($Result.failures | Where-Object { $failure = $_; @($Binding.expect | Where-Object { $failure.Contains($_, [StringComparison]::Ordinal) }).Count }) -join ' || ' }
    elseif ($Result.failures.Count) { $Result.failures -join ' || ' }
    elseif ($Result.blocked.Count) { 'nothing evaluated' }
    else { 'every assertion passed' }
  Write-Output "$Outcome $Name at $($Binding.case): $detail"
  foreach ($item in $Result.blocked) { Write-Output "BLOCKED $Name at $($Binding.case): $item" }
}

# AC1 stated independently of the module: the full path, trailing separators
# trimmed except on a drive root, lower-cased; the container keeps the raw name.
function Get-ExpectedLogMutexName([string]$Root) {
  $full = [IO.Path]::GetFullPath($Root)
  $pathRoot = [IO.Path]::GetPathRoot($full)
  $canonical = if ($full.Length -gt $pathRoot.Length) { $full.TrimEnd([char[]]@([char]'\', [char]'/')) } else { $pathRoot }
  $canonical = $canonical.ToLowerInvariant()
  if ($canonical -ceq $script:ContainerRoot.ToLowerInvariant()) { return $script:RawName }
  $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))
  return $script:RawName + '-' + [Convert]::ToHexString($digest).ToLowerInvariant()
}
function Get-LockRows([string]$Path) {
  if (-not [IO.File]::Exists($Path)) { return 0 }
  return @([IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() }).Count
}

# ---- child processes ---------------------------------------------------------------
function Start-LockChild([string]$Label, [string]$Script, [string[]]$Arguments) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = [Environment]::ProcessPath
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  $start.WorkingDirectory = $script:TestRoot
  foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Script)) { $start.ArgumentList.Add($argument) }
  foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($start)
  $child = [pscustomobject]@{
    label = $Label; process = $process; stderrTask = $process.StandardError.ReadToEndAsync(); pending = $null
    lines = [Collections.Generic.List[string]]::new(); closed = $false; exitCode = $null; stderr = ''
    clock = [Diagnostics.Stopwatch]::StartNew(); elapsedMs = $null; heldName = $null; readyName = $null
  }
  $script:Children.Add($child)
  return $child
}
function Get-LockChildTail($Child) {
  $tail = @(([string]$Child.stderr) -split '\r?\n' | Where-Object { $_.Trim() } | Select-Object -Last 6) -join ' | '
  return " [$($Child.label) exit=$($Child.exitCode) stdout=$(@($Child.lines) -join ' | ') stderrTail=$tail]"
}
# Returns the first stdout line that starts with an expected word; any other
# line is kept for diagnostics. The deadline only bounds a broken harness.
function Read-LockChildLine($Child, [string[]]$Expected, [int]$TimeoutMs) {
  if ($Child.closed) { throw "HARNESS FAILED: $($Child.label) is already closed" }
  $clock = [Diagnostics.Stopwatch]::StartNew()
  while ($true) {
    if ($null -eq $Child.pending) { $Child.pending = $Child.process.StandardOutput.ReadLineAsync() }
    $remaining = [math]::Max(0, $TimeoutMs - [int]$clock.ElapsedMilliseconds)
    if (-not $Child.pending.Wait($remaining)) {
      throw "HARNESS FAILED: $($Child.label) wrote no $($Expected -join '/') line within $TimeoutMs ms; stdout=$(@($Child.lines) -join ' | ')"
    }
    $line = $Child.pending.Result
    $Child.pending = $null
    if ($null -eq $line) { throw "HARNESS FAILED: $($Child.label) ended before a $($Expected -join '/') line; stdout=$(@($Child.lines) -join ' | ')" }
    $Child.lines.Add($line)
    foreach ($word in $Expected) {
      if ($line -ceq $word -or $line.StartsWith($word + ' ', [StringComparison]::Ordinal)) { return $line }
    }
  }
}
function Send-LockChildGo($Child) {
  $Child.process.StandardInput.WriteLine('go')
  $Child.process.StandardInput.Flush()
}
# Closes stdin, waits for the exit, drains both streams and disposes the
# process on every path. Only this test's own unresponsive child is stopped,
# and that always fails the run.
function Close-LockChild($Child, [int]$TimeoutMs = 60000) {
  if ($Child.closed) { return }
  $Child.closed = $true
  $stopped = $false
  try {
    try { $Child.process.StandardInput.Close() } catch { }
    if (-not $Child.process.WaitForExit($TimeoutMs)) {
      $stopped = $true
      try { $Child.process.Kill($true) } catch { }
      [void]$Child.process.WaitForExit(10000)
    }
    if ($null -ne $Child.pending -and $Child.pending.Wait(10000)) {
      if ($null -ne $Child.pending.Result) { $Child.lines.Add($Child.pending.Result) }
      $Child.pending = $null
    }
    if ($null -eq $Child.pending) {
      $rest = $Child.process.StandardOutput.ReadToEndAsync()
      if ($rest.Wait(10000)) { foreach ($line in ($rest.Result -split '\r?\n')) { if ($line) { $Child.lines.Add($line) } } }
    }
    if ($Child.stderrTask.Wait(10000)) { $Child.stderr = $Child.stderrTask.Result }
    if ($Child.process.HasExited) { $Child.exitCode = $Child.process.ExitCode }
    $Child.elapsedMs = $Child.clock.ElapsedMilliseconds
  } finally {
    $Child.process.Dispose()
  }
  if ($stopped) { throw "HARNESS FAILED: $($Child.label) did not exit within $TimeoutMs ms of its stdin closing and was stopped$(Get-LockChildTail $Child)" }
}
function Stop-LockChildQuietly($Child) {
  if ($null -eq $Child) { return }
  try { Close-LockChild $Child 15000 } catch { }
}
function Start-LockHolder([string]$Label, $Subject, [string]$Root, [string]$Name = '') {
  $arguments = if ($Name) { @('-Name', $Name) } else { @('-Module', $Subject.module, '-Root', $Root) }
  $holder = Start-LockChild $Label $script:HolderScript $arguments
  $line = Read-LockChildLine $holder @('HELD', 'BUSY') 60000
  if (-not $line.StartsWith('HELD ', [StringComparison]::Ordinal)) { throw "HARNESS FAILED: $Label could not take its mutex within 30 s: $line" }
  $holder.heldName = $line.Substring(5)
  return $holder
}
function Close-LockHolder($Holder) {
  Close-LockChild $Holder
  if ($Holder.exitCode -ne 0 -or -not $Holder.lines.Contains('RELEASED ' + $Holder.heldName)) {
    throw "HARNESS FAILED: $($Holder.label) did not release cleanly$(Get-LockChildTail $Holder)"
  }
}
function Start-LockWorker([string]$Label, [string]$Module, [string]$Marker, [string]$Root, [switch]$Archived) {
  $arguments = @('-Module', $Module, '-Marker', $Marker)
  if ($Archived) { $arguments += '-Archived' } else { $arguments += @('-Root', $Root) }
  $worker = Start-LockChild $Label $script:WorkerScript $arguments
  $line = Read-LockChildLine $worker @('READY', 'UNSUPPORTED') 60000
  if (-not $line.StartsWith('READY', [StringComparison]::Ordinal)) { throw "HARNESS FAILED: $Label is not constructible: $line" }
  $worker.readyName = $line.Substring(5).Trim()
  return $worker
}
function Complete-LockWorker($Worker, [int]$TimeoutMs = 60000) {
  $line = Read-LockChildLine $Worker @('RAN', 'REFUSED') $TimeoutMs
  Close-LockChild $Worker $TimeoutMs
  return $line
}

# ---- subjects ------------------------------------------------------------------------
# R1 is the subject directory holding dependency-complete producer copies (as
# log-event.test.ps1 and cost-harvest.test.ps1 copy them); R2 is where they write.
function New-LockSubject([string]$Label, [object[]]$Edits) {
  $root = Join-Path $script:TestRoot "subject-$Label"
  $r2 = Join-Path $script:TestRoot "ledgers-$Label"
  foreach ($directory in @($root, $r2)) { [void][IO.Directory]::CreateDirectory($directory) }
  foreach ($file in @('orchestration-log-lock.psm1', 'log-event.ps1', 'cost-harvest.ps1', 'review-head-contract.psm1', 'routing-data.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $root
  }
  foreach ($edit in $Edits) {
    $path = Join-Path $root $edit.file
    $text = [IO.File]::ReadAllText($path)
    $count = [regex]::Matches($text, [regex]::Escape($edit.anchor)).Count
    if ($count -ne 1) { throw "HARNESS FAILED: mutant $Label anchor occurs $count times in $($edit.file): $($edit.anchor)" }
    [IO.File]::WriteAllText($path, $text.Replace($edit.anchor, $edit.replacement), [Text.UTF8Encoding]::new($false))
  }
  [pscustomobject]@{
    label = $Label; root = $root; r2 = $r2; module = (Join-Path $root 'orchestration-log-lock.psm1')
    logEvent = (Join-Path $root 'log-event.ps1'); costHarvest = (Join-Path $root 'cost-harvest.ps1')
  }
}

# ---- in-process and static checks ------------------------------------------------------
function Test-InProcessContract($Result) {
  Add-LockCheck $Result ((Get-OrchestrationLogMutexName -Root $script:ContainerRoot) -ceq $script:RawName) 'governed log mutex name moved for the installed container root'
  $trace = [Collections.Generic.List[string]]::new()
  $value = Invoke-WithOrchestrationLogLock -Root (Join-Path $script:TestRoot 'exactly-once') -Body { $trace.Add('inside'); 'held' }
  Add-LockCheck $Result ($value -ceq 'held' -and $trace.Count -eq 1 -and $trace[0] -ceq 'inside') 'governed log lock did not execute exactly once'
}
# Every caller passes the parent of the one file its locked body writes,
# resolved as that write resolves it, computed before acquisition.
function Test-WriterCallers($Result) {
  $resolution = [ordered]@{
    'log-event.ps1' = 'Split-Path -Parent ([IO.Path]::GetFullPath($target))'
    'cost-harvest.ps1' = 'Split-Path -Parent ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Ledger))'
    'lease.ps1' = 'Split-Path -Parent ([IO.Path]::GetFullPath($Lease))'
  }
  foreach ($writer in $resolution.Keys) {
    $path = Join-Path $PSScriptRoot $writer
    $text = [IO.File]::ReadAllText($path)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $calls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Invoke-WithOrchestrationLogLock' }, $true))
    $rootArgument = $null
    if ($calls.Count -eq 1) {
      $elements = $calls[0].CommandElements
      for ($i = 1; $i -lt $elements.Count; $i++) {
        if ($elements[$i] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -ceq 'Root') {
          $rootArgument = if ($null -ne $elements[$i].Argument) { $elements[$i].Argument } elseif ($i + 1 -lt $elements.Count) { $elements[$i + 1] } else { $null }
        }
      }
    }
    $rootVariable = if ($rootArgument -is [Management.Automation.Language.VariableExpressionAst]) { $rootArgument.VariablePath.UserPath } else { '' }
    $assignments = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq $rootVariable }, $true))
    Add-LockCheck $Result ($errors.Count -eq 0 -and $text.Contains('orchestration-log-lock.psm1', [StringComparison]::Ordinal) -and -not $text.Contains($script:RawName, [StringComparison]::Ordinal)) "$writer imports the governed log lock and never names the writer mutex itself"
    Add-LockCheck $Result ($calls.Count -eq 1 -and $rootVariable -and $rootVariable -cne 'PSScriptRoot') "$writer passes -Root from a variable other than PSScriptRoot on its one Invoke-WithOrchestrationLogLock call; observed calls=$($calls.Count) root='$rootVariable'"
    Add-LockCheck $Result ($assignments.Count -eq 1 -and $assignments[0].Right.Extent.Text -ceq $resolution[$writer] -and $assignments[0].Extent.EndOffset -lt $calls[0].Extent.StartOffset) "$writer computes -Root before acquisition as $($resolution[$writer])"
  }
}
function Get-RawLiteralCount([string]$Text) {
  @([regex]::Matches($Text, 'Global\\ChaseSetsOrchLog[-\w]*') | Where-Object { $_.Value -ceq $script:RawName }).Count
}
# AC6: the one shared rewrite throws unless exactly one literal is replaced.
function Test-ArchivedRewriteGuard($Result) {
  $cases = [ordered]@{
    'none' = 'function Get-OrchestrationLogMutexName { param() "Global\Other" }'
    'one' = 'function Get-OrchestrationLogMutexName { param() "Global\ChaseSetsOrchLog" }'
    'two' = 'function Get-OrchestrationLogMutexName { param() "Global\ChaseSetsOrchLog"; "Global\ChaseSetsOrchLog" }'
    'post-change' = 'function Get-OrchestrationLogMutexName { param($Root) if ($Root) { "Global\ChaseSetsOrchLog" } else { "Global\ChaseSetsOrchLog-" + $Root } }'
  }
  foreach ($case in $cases.Keys) {
    $runtime = Join-Path $script:TestRoot "rewrite-guard-$case\.orchestrator"
    [void][IO.Directory]::CreateDirectory($runtime)
    $module = Join-Path $runtime 'orchestration-log-lock.psm1'
    $text = $cases[$case] + [Environment]::NewLine
    [IO.File]::WriteAllText($module, $text, [Text.UTF8Encoding]::new($false))
    $message = ''
    $returned = $null
    try { $returned = Set-ArchivedOrchestrationLogMutexName $runtime } catch { $message = $_.Exception.Message }
    $after = [IO.File]::ReadAllText($module)
    if ($case -ceq 'one') {
      Add-LockCheck $Result ($message -ceq '' -and $returned -ceq (Get-ExpectedLogMutexName $runtime) -and $after -ceq $text.Replace($script:RawName, $returned) -and (Get-RawLiteralCount $after) -eq 0) "AC6 the shared rewrite replaces the one literal with the extracted root's AC1 name; observed '$returned' error='$message'"
      $again = ''
      try { [void](Set-ArchivedOrchestrationLogMutexName $runtime) } catch { $again = $_.Exception.Message }
      Add-LockCheck $Result ($again.StartsWith('ARCHIVED_LOG_LOCK_REWRITE:', [StringComparison]::Ordinal) -and [IO.File]::ReadAllText($module) -ceq $after) "AC6 a second rewrite of an already private module refuses and leaves it unchanged; observed error='$again'"
    } else {
      Add-LockCheck $Result ($message.StartsWith('ARCHIVED_LOG_LOCK_REWRITE:', [StringComparison]::Ordinal) -and $after -ceq $text) "AC6 the shared rewrite refuses a $case module and leaves it unchanged; observed error='$message'"
    }
  }
}

# ---- AC1: one lexical name per root ------------------------------------------------------
function Test-RootNames($Subject, $Result) {
  # A copied runtime matches every non-lexical selector: its module directory,
  # its .orchestrator leaf and a ledger. It must still be hashed.
  $copyRoot = Join-Path $script:TestRoot "copy-$($Subject.label)\.orchestrator"
  [void][IO.Directory]::CreateDirectory($copyRoot)
  Copy-Item -LiteralPath $Subject.module -Destination $copyRoot
  [IO.File]::WriteAllText((Join-Path $copyRoot 'dispatch-log.jsonl'), '{"kind":"gc"}' + [Environment]::NewLine)
  $alias = Join-Path $script:TestRoot 'alias-root\runtime'
  $missing = Join-Path $script:TestRoot ('missing-' + [guid]::NewGuid().ToString('N') + '\.orchestrator')
  $lane = 'D:\Users\ToddS\Source\Repos\chase-sets\lane-01\.orchestrator'
  $roots = [ordered]@{
    alias = @($alias, $alias.ToUpperInvariant(), $alias.Replace('\', '/'), "$alias\", "$alias/", "$alias\.", "$alias\sub\..", (Join-Path (Split-Path -Parent $alias) '.\runtime'))
    distinct = @((Join-Path $script:TestRoot 'alias-root\other'), "$alias\sub")
    copy = @($copyRoot)
    lane = @($lane)
    missing = @($missing)
    drive = @('D:\', 'D:/', 'd:\')
    container = @($script:ContainerRoot, ($script:ContainerRoot.ToLowerInvariant().Replace('\', '/') + '/'), 'D:\Users\ToddS\Source\Repos\chase-sets\main\..\.orchestrator', "$($script:ContainerRoot)\.", "$($script:ContainerRoot.ToUpperInvariant())\")
  }
  $list = [Collections.Generic.List[string]]::new()
  foreach ($group in $roots.Values) { foreach ($root in $group) { $list.Add($root) } }
  $rootsFile = Join-Path $script:TestRoot "names-$($Subject.label).roots"
  $outFile = Join-Path $script:TestRoot "names-$($Subject.label).json"
  $marker = Join-Path $script:TestRoot "names-$($Subject.label).marker"
  [IO.File]::WriteAllLines($rootsFile, $list)
  $child = Start-LockChild "$($Subject.label)-names" $script:NamesScript @('-Module', (Join-Path $copyRoot 'orchestration-log-lock.psm1'), '-RootsFile', $rootsFile, '-Marker', $marker, '-OutFile', $outFile)
  [void](Read-LockChildLine $child @('NAMES') 60000)
  Close-LockChild $child
  $document = [IO.File]::ReadAllText($outFile) | ConvertFrom-Json
  $names = @($document.names)
  if ($names.Count -ne $list.Count) { throw "HARNESS FAILED: names child returned $($names.Count) names for $($list.Count) roots" }
  $byGroup = @{}
  $index = 0
  foreach ($key in $roots.Keys) {
    $byGroup[$key] = @($names[$index..($index + $roots[$key].Count - 1)])
    $index += $roots[$key].Count
  }
  $aliasName = $byGroup.alias[0]
  $distinct = @($aliasName) + @($byGroup.distinct)
  Write-Host "AC1 $($Subject.label) alias=$aliasName copy=$($byGroup.copy[0]) lane=$($byGroup.lane[0]) missing=$($byGroup.missing[0]) drive=$($byGroup.drive[0]) container=$($byGroup.container[0])"
  Add-LockCheck $Result (@($distinct | Sort-Object -Unique -CaseSensitive).Count -eq 3) "AC1 distinct roots get distinct names; observed $($distinct -join ', ')"
  Add-LockCheck $Result (@($byGroup.alias | Where-Object { $_ -cne $aliasName }).Count -eq 0 -and $aliasName -ceq (Get-ExpectedLogMutexName $alias)) "AC1 case, slash, trailing-separator, . and .. aliases give the one hashed name $(Get-ExpectedLogMutexName $alias); observed $($byGroup.alias -join ', ')"
  Add-LockCheck $Result ($byGroup.copy[0] -ceq (Get-ExpectedLogMutexName $copyRoot) -and $byGroup.copy[0] -cmatch '^Global\\ChaseSetsOrchLog-[0-9a-f]{64}$') "AC1 a temp module copy keyed to its own .orchestrator directory, which holds a ledger, is hashed; observed '$($byGroup.copy[0])'"
  # Known answer: lower-case hex SHA256 of the UTF-8 canonical lane root.
  Add-LockCheck $Result ($byGroup.lane[0] -ceq (Get-ExpectedLogMutexName $lane) -and $byGroup.lane[0] -ceq 'Global\ChaseSetsOrchLog-04c6798db941230944e8232149bf9ba186121b4f1f6d3042c77ff6f94561b978') "AC1 <container>\lane-01\.orchestrator is hashed; observed '$($byGroup.lane[0])'"
  Add-LockCheck $Result ($byGroup.missing[0] -ceq (Get-ExpectedLogMutexName $missing) -and -not [IO.Directory]::Exists((Split-Path -Parent $missing))) "AC1 a nonexistent root is hashed lexically and never created; observed '$($byGroup.missing[0])'"
  Add-LockCheck $Result (@($byGroup.drive | Where-Object { $_ -cne (Get-ExpectedLogMutexName 'D:\') }).Count -eq 0) "AC1 drive-root aliases keep the root separator and give one name; observed $($byGroup.drive -join ', ')"
  Add-LockCheck $Result (@($byGroup.container | Where-Object { $_ -cne $script:RawName }).Count -eq 0) "AC1 container aliases get the cutover name $($script:RawName); observed $($byGroup.container -join ', ')"
  Add-LockCheck $Result ($document.omittedName -ceq 'MissingMandatoryParameter,Get-OrchestrationLogMutexName' -and $document.omittedInvoke -ceq 'MissingMandatoryParameter,Invoke-WithOrchestrationLogLock' -and (Get-LockRows $marker) -eq 0) "AC2 an omitted -Root fails before acquisition; observed name='$($document.omittedName)' invoke='$($document.omittedInvoke)' bodyRows=$(Get-LockRows $marker)"
}

# ---- AC2: producers pass the parent of the file they write -------------------------------
function Invoke-ProducerPhase($Subject, [string]$Phase, [string]$HeldRoot) {
  $specs = @(
    [pscustomobject]@{ id = 'log-event'; producer = $Subject.logEvent; location = ''; out = (Join-Path $Subject.r2 "$Phase-dispatch.jsonl")
      arguments = [ordered]@{ Log = 'dispatch'; Kind = 'gc'; Note = "synthetic 122 $Phase"; OutFile = (Join-Path $Subject.r2 "$Phase-dispatch.jsonl"); NoBoard = $true } }
    [pscustomobject]@{ id = 'cost-harvest'; producer = $Subject.costHarvest; location = ''; out = (Join-Path $Subject.r2 "$Phase-cost-ledger.jsonl")
      arguments = [ordered]@{ TranscriptDir = $script:Transcripts; Ledger = (Join-Path $Subject.r2 "$Phase-cost-ledger.jsonl"); Backfill = $true } }
    # The ledger is relative and the provider location is R2 while the process
    # directory is the test root: Add-Content writes into R2.
    [pscustomobject]@{ id = 'cost-harvest-relative'; producer = $Subject.costHarvest; location = $Subject.r2; out = (Join-Path $Subject.r2 "$Phase-relative-ledger.jsonl")
      arguments = [ordered]@{ TranscriptDir = $script:Transcripts; Ledger = "$Phase-relative-ledger.jsonl"; Backfill = $true } }
  )
  $holder = Start-LockHolder "$($Subject.label)-$Phase-holder" $Subject $HeldRoot
  $runs = [Collections.Generic.List[object]]::new()
  $completed = $false
  try {
    foreach ($spec in $specs) {
      $argumentsFile = Join-Path $script:TestRoot "$($Subject.label)-$Phase-$($spec.id).json"
      [IO.File]::WriteAllText($argumentsFile, ($spec.arguments | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
      $arguments = @('-Producer', $spec.producer, '-ArgumentsFile', $argumentsFile)
      if ($spec.location) { $arguments += @('-Location', $spec.location) }
      $runs.Add([pscustomobject]@{ spec = $spec; child = (Start-LockChild "$($Subject.label)-$Phase-$($spec.id)" $script:ProducerScript $arguments); outcome = $null; rows = $null })
    }
    # The producers run concurrently, each at its default 30 s writer timeout.
    foreach ($run in $runs) {
      $run.outcome = Read-LockChildLine $run.child @('COMPLETED', 'REFUSED') 180000
      Close-LockChild $run.child
      $run.rows = Get-LockRows $run.spec.out
      Write-Host "AC2 $Phase $($Subject.label) $($run.spec.id) outcome='$($run.outcome)' rows=$($run.rows) exit=$($run.child.exitCode) elapsedMs=$($run.child.elapsedMs)"
    }
    $completed = $true
  } finally {
    foreach ($run in $runs) { Stop-LockChildQuietly $run.child }
    # The holder releases only after every producer has exited.
    if ($completed) { Close-LockHolder $holder } else { Stop-LockChildQuietly $holder }
  }
  return $runs
}
function Test-ProducersWhileOwnRootHeld($Subject, $Result) {
  foreach ($run in @(Invoke-ProducerPhase $Subject 'r1-held' $Subject.root)) {
    Add-LockCheck $Result ($run.outcome -ceq 'COMPLETED' -and $run.rows -eq 1 -and $run.child.exitCode -eq 0) "AC2 $($run.spec.id) appends exactly one row to R2 while its own R1 is held; observed '$($run.outcome)' rows=$($run.rows)$(Get-LockChildTail $run.child)"
  }
}
function Test-ProducersWhileTargetRootHeld($Subject, $Result) {
  foreach ($run in @(Invoke-ProducerPhase $Subject 'r2-held' $Subject.r2)) {
    Add-LockCheck $Result ($run.outcome -ceq "REFUSED $($script:Refusal)" -and $run.rows -eq 0 -and $run.child.exitCode -eq 3) "AC2 $($run.spec.id) refuses exactly with zero rows while R2 is held; observed '$($run.outcome)' rows=$($run.rows)$(Get-LockChildTail $run.child)"
  }
}

# ---- AC3: one root serializes, distinct roots do not ---------------------------------------
function Test-SameRootSerializes($Subject, $Result) {
  $root = Join-Path $script:TestRoot "ac3-$($Subject.label)\same"
  $marker = Join-Path $script:TestRoot "ac3-$($Subject.label)\same.marker"
  [void][IO.Directory]::CreateDirectory($root)
  $worker = Start-LockWorker "$($Subject.label)-ac3a-worker" $Subject.module $marker $root
  $holder = $null
  $completed = $false
  try {
    $holder = Start-LockHolder "$($Subject.label)-ac3a-holder" $Subject $root
    Send-LockChildGo $worker
    $during = Complete-LockWorker $worker
    $completed = $true
  } finally {
    Stop-LockChildQuietly $worker
    # The holder releases only after the worker has exited.
    if ($holder -and $completed) { Close-LockHolder $holder } else { Stop-LockChildQuietly $holder }
  }
  $rowsDuring = Get-LockRows $marker
  $after = Start-LockWorker "$($Subject.label)-ac3a-after" $Subject.module $marker $root
  Send-LockChildGo $after
  $afterOutcome = Complete-LockWorker $after
  $rowsAfter = Get-LockRows $marker
  Write-Host "AC3a $($Subject.label) held='$($holder.heldName)' during='$during' rows=$rowsDuring after='$afterOutcome' rows=$rowsAfter"
  Add-LockCheck $Result ($during -ceq "REFUSED $($script:Refusal)" -and $rowsDuring -eq 0 -and $worker.exitCode -eq 3) "AC3a a worker on the held root refuses exactly with zero body; observed '$during' rows=$rowsDuring$(Get-LockChildTail $worker)"
  Add-LockCheck $Result ($afterOutcome -ceq 'RAN' -and $rowsAfter -eq 1 -and $after.exitCode -eq 0) "AC3a the worker runs once after release; observed '$afterOutcome' rows=$rowsAfter$(Get-LockChildTail $after)"
}
function Test-DistinctRootsRunConcurrently($Subject, $Result) {
  $held = Join-Path $script:TestRoot "ac3-$($Subject.label)\held"
  $other = Join-Path $script:TestRoot "ac3-$($Subject.label)\other"
  $marker = Join-Path $script:TestRoot "ac3-$($Subject.label)\other.marker"
  foreach ($directory in @($held, $other)) { [void][IO.Directory]::CreateDirectory($directory) }
  $worker = Start-LockWorker "$($Subject.label)-ac3b-worker" $Subject.module $marker $other
  $holder = $null
  $completed = $false
  try {
    $holder = Start-LockHolder "$($Subject.label)-ac3b-holder" $Subject $held
    Send-LockChildGo $worker
    $outcome = Complete-LockWorker $worker
    $completed = $true
  } finally {
    Stop-LockChildQuietly $worker
    if ($holder -and $completed) { Close-LockHolder $holder } else { Stop-LockChildQuietly $holder }
  }
  $rows = Get-LockRows $marker
  Write-Host "AC3b $($Subject.label) held='$($holder.heldName)' worker='$($worker.readyName)' outcome='$outcome' rows=$rows"
  Add-LockCheck $Result ($outcome -ceq 'RAN' -and $rows -eq 1 -and $worker.exitCode -eq 0) "AC3b a worker on a distinct root runs once while another root is held; observed '$outcome' rows=$rows$(Get-LockChildTail $worker)"
}

# ---- AC4 and AC6: the raw name, held once per run -----------------------------------------------
function New-ArchivedLockRuntime([string]$Key, [string]$Commit, [bool]$Rewrite, [string]$Label) {
  & git -C $script:Controller cat-file -e "$Commit^{commit}" 2>$null
  if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ label = $Key; blocked = "archived commit $Commit is not in this clone; no evidence is claimed for it" } }
  $directory = Join-Path $script:TestRoot "archived-$Label-$Key"
  $zip = "$directory.zip"
  & git -C $script:Controller archive --format=zip "--output=$zip" $Commit .orchestrator
  if ($LASTEXITCODE -ne 0) { throw "HARNESS FAILED: git archive $Commit failed" }
  $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
  Expand-Archive -LiteralPath $zip -DestinationPath $directory
  $runtime = Join-Path $directory '.orchestrator'
  $module = Join-Path $runtime 'orchestration-log-lock.psm1'
  $rawBefore = Get-RawLiteralCount ([IO.File]::ReadAllText($module))
  $returned = $null
  if ($Rewrite) { $returned = Set-ArchivedOrchestrationLogMutexName $runtime }
  [pscustomobject]@{
    label = $Key; blocked = $null; commit = $Commit; runtime = $runtime; module = $module; rewritten = $Rewrite
    expectedName = (Get-ExpectedLogMutexName $runtime); candidateName = (Get-OrchestrationLogMutexName -Root $runtime)
    returnedName = $returned; rawBefore = $rawBefore
    survivingRaw = Get-RawLiteralCount ([IO.File]::ReadAllText($module))
    zipUnchanged = ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ceq $zipHash)
  }
}
function New-RawParticipant([string]$Kind, [string]$Label, $Subject, $Runtime) {
  [pscustomobject]@{
    kind = $Kind; label = $Label; subject = $Subject; runtime = $Runtime; marker = (Join-Path $script:TestRoot "raw-$Label.marker")
    worker = $null; outcome = $null; rows = $null; after = $null; afterOutcome = $null; afterRows = $null
  }
}
# A plan is one result's share of the run's single raw-name window: a
# container-root worker (AC4), extracted archived workers (AC6), or both.
function New-RawPlan([string]$Case, $Subject, [string]$Label, [bool]$Container, [bool]$Archived, [bool]$Rewrite) {
  $plan = [pscustomobject]@{ result = (New-LockResult $Case $Label); participants = [Collections.Generic.List[object]]::new() }
  try {
    if ($Container) { $plan.participants.Add((New-RawParticipant 'container' "$Label-container" $Subject $null)) }
    if ($Archived) {
      foreach ($key in $script:ArchivedRuntimes.Keys) {
        $runtime = New-ArchivedLockRuntime $key $script:ArchivedRuntimes[$key] $Rewrite $Label
        if ($runtime.blocked) { $plan.result.blocked.Add("AC6 $key $($runtime.blocked)") }
        else { $plan.participants.Add((New-RawParticipant 'archived' "$Label-$key" $null $runtime)) }
      }
    }
  } catch {
    $plan.result.harness = $_.Exception.Message
    $plan.participants.Clear()
  }
  return $plan
}
# Every participant of the run is preloaded first; the real name is then taken
# once, every worker attempts it once, and the holder releases only after every
# worker exited. Container workers then run once more after the release.
function Invoke-RawNameWindow([object[]]$Plans) {
  $all = @($Plans | ForEach-Object { $_.participants })
  if ($all.Count -eq 0) { return 'EMPTY' }
  $holder = $null
  $released = $false
  try {
    foreach ($participant in $all) {
      if ($participant.kind -ceq 'container') {
        $participant.worker = Start-LockWorker "$($participant.label)-worker" $participant.subject.module $participant.marker $script:ContainerRoot
        $participant.after = Start-LockWorker "$($participant.label)-after" $participant.subject.module $participant.marker $script:ContainerRoot
      } else {
        $participant.worker = Start-LockWorker "$($participant.label)-worker" $participant.runtime.module $participant.marker '' -Archived
      }
    }
    $holder = Start-LockChild 'raw-holder' $script:HolderScript @('-Name', $script:RawName)
    $line = Read-LockChildLine $holder @('HELD', 'BUSY') 60000
    # The holder waits as long as a live writer would (the 30 s default).
    if (-not $line.StartsWith('HELD ', [StringComparison]::Ordinal)) { return 'LIVE_CONTENTION' }
    $holder.heldName = $line.Substring(5)
    $heldClock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($participant in $all) { Send-LockChildGo $participant.worker }
    foreach ($participant in $all) { $participant.outcome = Read-LockChildLine $participant.worker @('RAN', 'REFUSED') 15000 }
    foreach ($participant in $all) { Close-LockChild $participant.worker 15000 }
    foreach ($participant in $all) { $participant.rows = Get-LockRows $participant.marker }
    Close-LockHolder $holder
    $released = $true
    Write-Host "RAW window: raw $($script:RawName) held once for $($heldClock.ElapsedMilliseconds) ms (until its holder exited) across $($all.Count) worker attempts"
    $after = @($all | Where-Object { $null -ne $_.after })
    foreach ($participant in $after) { Send-LockChildGo $participant.after }
    foreach ($participant in $after) {
      $participant.afterOutcome = Read-LockChildLine $participant.after @('RAN', 'REFUSED') 15000
      Close-LockChild $participant.after 15000
      $participant.afterRows = Get-LockRows $participant.marker
    }
    return 'EVALUATED'
  } finally {
    # On any failure the real name is released before anything else.
    if ($null -ne $holder -and -not $released) { Stop-LockChildQuietly $holder }
    foreach ($participant in $all) { Stop-LockChildQuietly $participant.worker; Stop-LockChildQuietly $participant.after }
  }
}
function Add-RawNameChecks($Plan) {
  $result = $Plan.result
  foreach ($participant in $Plan.participants) {
    $worker = $participant.worker
    if ($participant.kind -ceq 'container') {
      Write-Host "AC4 $($participant.label) ready='$($worker.readyName)' held='$($participant.outcome)' rows=$($participant.rows) after='$($participant.afterOutcome)' rows=$($participant.afterRows)"
      Add-LockCheck $result ($participant.outcome -ceq "REFUSED $($script:Refusal)" -and $participant.rows -eq 0 -and $worker.exitCode -eq 3) "AC4 a container-root worker refuses exactly with zero body while raw $($script:RawName) is held; observed '$($participant.outcome)' rows=$($participant.rows)$(Get-LockChildTail $worker)"
      # The test holder verifiably released and exited; only another holder of
      # the raw name, a live writer, can refuse this attempt.
      if ($participant.afterOutcome -ceq "REFUSED $($script:Refusal)" -and $participant.after.readyName -ceq $script:RawName -and $participant.afterRows -eq 0) {
        $result.blocked.Add("LIVE_CONTENTION: a live writer held raw $($script:RawName) during the 250 ms attempt after the verified release, so 'runs once after release' was not evaluated and no PASS is claimed")
      } else {
        Add-LockCheck $result ($participant.afterOutcome -ceq 'RAN' -and $participant.afterRows -eq 1 -and $participant.after.exitCode -eq 0) "AC4 the container-root worker runs once after release; observed '$($participant.afterOutcome)' rows=$($participant.afterRows)$(Get-LockChildTail $participant.after)"
      }
    } else {
      $runtime = $participant.runtime
      Write-Host "AC6 $($participant.label) commit=$($runtime.commit) rewritten=$($runtime.rewritten) ready='$($worker.readyName)' expected=$($runtime.expectedName) held='$($participant.outcome)' rows=$($participant.rows) literalsBefore=$($runtime.rawBefore) literalsAfter=$($runtime.survivingRaw) zipUnchanged=$($runtime.zipUnchanged)"
      Add-LockCheck $result ($participant.outcome -ceq 'RAN' -and $participant.rows -eq 1 -and $worker.exitCode -eq 0) "AC6 archived $($runtime.label) worker runs once while raw $($script:RawName) is held; observed '$($participant.outcome)' rows=$($participant.rows)$(Get-LockChildTail $worker)"
      Add-LockCheck $result ($worker.readyName -ceq $runtime.expectedName -and $runtime.candidateName -ceq $runtime.expectedName) "AC6 a child loading the extracted $($runtime.label) module gets that root's AC1 name $($runtime.expectedName); observed '$($worker.readyName)'"
      Add-LockCheck $result ($runtime.rawBefore -eq 1 -and $runtime.survivingRaw -eq 0 -and $runtime.returnedName -ceq $runtime.expectedName) "AC6 the extracted $($runtime.label) module had one literal and none survives the rewrite; observed before=$($runtime.rawBefore) after=$($runtime.survivingRaw) returned='$($runtime.returnedName)'"
      Add-LockCheck $result $runtime.zipUnchanged "AC6 the $($runtime.label) zip is untouched by extraction and rewrite"
    }
  }
}
function Invoke-RawPlans([object[]]$Plans) {
  $first = $script:Children.Count
  try {
    $state = Invoke-RawNameWindow $Plans
  } catch {
    $tails = [Collections.Generic.List[string]]::new()
    for ($i = $first; $i -lt $script:Children.Count; $i++) {
      if ($script:Children[$i].exitCode -ne 0) { $tails.Add((Get-LockChildTail $script:Children[$i])) }
    }
    foreach ($plan in $Plans) { if ($plan.participants.Count) { $plan.result.harness = $_.Exception.Message + ($tails -join '') } }
    return
  }
  if ($state -ceq 'LIVE_CONTENTION') {
    foreach ($plan in $Plans) {
      if ($plan.participants.Count) { $plan.result.blocked.Add("LIVE_CONTENTION: live writers held raw $($script:RawName) for the whole 30 s writer default, so the raw-name window was not evaluated and no PASS is claimed") }
    }
    return
  }
  foreach ($plan in $Plans) { Add-RawNameChecks $plan }
}

function Invoke-LockCase([string]$Case, $Subject) {
  $result = New-LockResult $Case $Subject.label
  $first = $script:Children.Count
  try {
    switch -CaseSensitive ($Case) {
      'AC1' { $null = Test-RootNames $Subject $result }
      'AC2-R1' { $null = Test-ProducersWhileOwnRootHeld $Subject $result }
      'AC2-R2' { $null = Test-ProducersWhileTargetRootHeld $Subject $result }
      'AC3a' { $null = Test-SameRootSerializes $Subject $result }
      'AC3b' { $null = Test-DistinctRootsRunConcurrently $Subject $result }
      default { throw "unknown case $Case" }
    }
  } catch {
    # A child failure reports its exit code and stderr tail.
    $tails = [Collections.Generic.List[string]]::new()
    for ($i = $first; $i -lt $script:Children.Count; $i++) {
      $child = $script:Children[$i]
      Stop-LockChildQuietly $child
      if ($child.exitCode -ne 0) { $tails.Add((Get-LockChildTail $child)) }
    }
    $result.harness = $_.Exception.Message + ($tails -join '')
  }
  return $result
}
function Remove-LockTestRoot {
  $resolved = [IO.Path]::GetFullPath($script:TestRoot)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -cne $temp -or (Split-Path -Leaf $resolved) -notmatch '^orchestration-log-lock-test-[0-9a-f]{32}$') { throw 'unsafe lock test cleanup' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}

# ---- run ---------------------------------------------------------------------------------------
$failed = $false
$blocked = $false
$routingScope = $null
[void][IO.Directory]::CreateDirectory($script:TestRoot)
try {
  $routingScope = Enter-RoutingDataTestScope
  $script:HolderScript = Join-Path $script:TestRoot 'holder.ps1'
  $script:WorkerScript = Join-Path $script:TestRoot 'worker.ps1'
  $script:NamesScript = Join-Path $script:TestRoot 'names.ps1'
  $script:ProducerScript = Join-Path $script:TestRoot 'producer.ps1'
  foreach ($pair in @(@($script:HolderScript, $script:HolderSource), @($script:WorkerScript, $script:WorkerSource), @($script:NamesScript, $script:NamesSource), @($script:ProducerScript, $script:ProducerSource))) {
    [IO.File]::WriteAllText($pair[0], $pair[1], [Text.UTF8Encoding]::new($false))
  }
  [void][IO.Directory]::CreateDirectory($script:Transcripts)
  [IO.File]::WriteAllLines((Join-Path $script:Transcripts 'synthetic-122-lock.jsonl'), [string[]]@(
    '{"type":"system","subtype":"init","cwd":"C:\\x","model":"claude-opus-5"}',
    '{"type":"result","subtype":"success","is_error":false,"duration_ms":1000,"duration_api_ms":500,"num_turns":1,"total_cost_usd":0.01,"result":"done"}'))
  $candidate = New-LockSubject 'candidate' @()
  $rawCases = @('AC4', 'AC6')
  if ($Mutant -ceq 'none') {
    $static = New-LockResult 'static' 'candidate'
    Test-InProcessContract $static
    Test-WriterCallers $static
    Test-ArchivedRewriteGuard $static
    Write-LockResult $static
    if (-not (Test-LockPassed $static)) { $failed = $true }
    foreach ($case in @('AC1', 'AC2-R1', 'AC2-R2', 'AC3a', 'AC3b')) {
      $result = Invoke-LockCase $case $candidate
      Write-LockResult $result
      if (-not (Test-LockPassed $result)) { $failed = $true }
      if ($result.blocked.Count) { $blocked = $true }
    }
    $plan = New-RawPlan 'AC4+AC6' $candidate 'candidate' $true $true $true
    Invoke-RawPlans @($plan)
    Write-LockResult $plan.result
    if (-not (Test-LockPassed $plan.result)) { $failed = $true }
    if ($plan.result.blocked.Count) { $blocked = $true }
  } else {
    $selected = if ($Mutant -ceq 'all') { @($script:Bindings.Keys) } else { @($Mutant) }
    $bindings = @(foreach ($name in $selected) { foreach ($binding in $script:Bindings[$name]) { [pscustomobject]@{ name = $name; binding = $binding } } })
    $cases = @($bindings | ForEach-Object { $_.binding.case } | Where-Object { $_ -cnotin $rawCases } | Select-Object -Unique)
    # In-control arm: every bound case passes on the unmutated candidate.
    foreach ($case in $cases) {
      $control = Invoke-LockCase $case $candidate
      Write-LockResult $control 'CONTROL '
      if (-not (Test-LockPassed $control)) { $failed = $true }
      if ($control.blocked.Count) { $blocked = $true }
    }
    $subjects = @{}
    foreach ($name in $selected) { $subjects[$name] = if ($name -ceq 'archive-global') { $candidate } else { New-LockSubject $name $script:MutantEdits[$name] } }
    foreach ($entry in @($bindings | Where-Object { $_.binding.case -cnotin $rawCases })) {
      $result = Invoke-LockCase $entry.binding.case $subjects[$entry.name]
      $outcome = Get-MutantOutcome $result $entry.binding.expect
      Write-MutantOutcome $entry.name $entry.binding $result $outcome
      if ($result.blocked.Count) { $blocked = $true }
      if ($outcome -cne 'KILLED' -and $outcome -cne 'NOT_EVALUATED') { $failed = $true }
    }
    # Raw-name controls and mutants share the run's one raw-name window.
    $rawBindings = @($bindings | Where-Object { $_.binding.case -cin $rawCases })
    if ($rawBindings.Count) {
      $needContainer = [bool]@($rawBindings | Where-Object { $_.binding.case -ceq 'AC4' }).Count
      $needArchived = [bool]@($rawBindings | Where-Object { $_.binding.case -ceq 'AC6' }).Count
      $controlCase = (@(@('AC4') * [int]$needContainer) + @(@('AC6') * [int]$needArchived)) -join '+'
      $controlPlan = New-RawPlan $controlCase $candidate 'candidate' $needContainer $needArchived $true
      $mutantPlans = @(foreach ($entry in $rawBindings) {
        [pscustomobject]@{ entry = $entry; plan = (New-RawPlan $entry.binding.case $subjects[$entry.name] $entry.name ($entry.binding.case -ceq 'AC4') ($entry.binding.case -ceq 'AC6') ($entry.name -cne 'archive-global')) }
      })
      Invoke-RawPlans (@($controlPlan) + @($mutantPlans | ForEach-Object { $_.plan }))
      Write-LockResult $controlPlan.result 'CONTROL '
      if (-not (Test-LockPassed $controlPlan.result)) { $failed = $true }
      if ($controlPlan.result.blocked.Count) { $blocked = $true }
      foreach ($mutantPlan in $mutantPlans) {
        $outcome = Get-MutantOutcome $mutantPlan.plan.result $mutantPlan.entry.binding.expect
        Write-MutantOutcome $mutantPlan.entry.name $mutantPlan.entry.binding $mutantPlan.plan.result $outcome
        if ($mutantPlan.plan.result.blocked.Count) { $blocked = $true }
        if ($outcome -cne 'KILLED' -and $outcome -cne 'NOT_EVALUATED') { $failed = $true }
      }
    }
  }
} catch {
  $failed = $true
  Write-Output "ERROR orchestration log lock tests: $($_.Exception.Message)"
} finally {
  foreach ($child in $script:Children) { Stop-LockChildQuietly $child }
  if ($routingScope) { Exit-RoutingDataTestScope $routingScope }
}
if ($failed) {
  Write-Output "FAIL orchestration log lock tests mutant=$Mutant checks=$($script:Checks) evidence=$($script:TestRoot)"
  exit 1
}
Remove-LockTestRoot
if ($blocked) {
  Write-Output "BLOCKED orchestration log lock tests mutant=$Mutant checks=$($script:Checks): evidence above is not complete (missing archived commit or live contention); no PASS is claimed"
  exit 2
}
Write-Output "PASS orchestration log lock tests writers=3 mutant=$Mutant checks=$($script:Checks)"
