[CmdletBinding()]
param(
  [ValidatePattern('^$|^[a-f0-9]{40}$')][string]$SupportRevision = '',
  [ValidateSet('none','factor','passes','overhead','headroom','floor','cap','budget-cpu','verdict-cpu',
    'positive-deadline','event-deadline','accept-bad-cpu','inert-factor','inert-overhead',
    'event-factor','event-overhead','wall-headroom','final-reference','cpu-bracket','record-cpu')][string]$Mutant = 'none'
)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'

function Assert-Derivation([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "BOARD_SCALE_DERIVATION: $Message" }
}
function Read-DerivationAst([string]$Source) {
  $tokens = $null; $errors = $null
  $ast = [Management.Automation.Language.Parser]::ParseInput($Source, [ref]$tokens, [ref]$errors)
  Assert-Derivation ($errors.Count -eq 0) 'support parses'
  return $ast
}
function Get-DerivationFunction($Ast, [string]$Name) {
  $nodes = @($Ast.FindAll({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name
  }, $false))
  Assert-Derivation ($nodes.Count -eq 1) "one $Name function"
  return $nodes[0]
}
function Get-DerivationAssignment($Function, [string]$Name) {
  $nodes = @($Function.Body.FindAll({ param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $Name
  }, $true))
  Assert-Derivation ($nodes.Count -eq 1) "one $Name assignment"
  return $nodes[0].Extent.Text
}
function Replace-DerivationAnchor([string]$Source, [string]$Old, [string]$New) {
  Assert-Derivation (($Source.Split([string[]]@($Old), [StringSplitOptions]::None).Count - 1) -eq 1) "unique mutant anchor: $Old"
  return $Source.Replace($Old, $New)
}

$baselineBlob = 'cf9bb1ec621c6ebae1497a13b0e30b71f1408c8c'
$hourlyBlob = '4eedaa85619279fa8b30595045acf95a6137e802'
$baseline = (@(& git -C $PSScriptRoot cat-file blob $baselineBlob) -join "`n")
Assert-Derivation ($LASTEXITCODE -eq 0) 'immutable B support blob available'
$source = if ($SupportRevision) {
  $text = @(& git -C $PSScriptRoot show "${SupportRevision}:.orchestrator/board-scale-test-support.ps1") -join "`n"
  Assert-Derivation ($LASTEXITCODE -eq 0) 'requested support revision available'
  $text
} else { [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'board-scale-test-support.ps1')).Replace("`r`n", "`n") }

# Mutation is in memory only. Each command runs this same oracle, never a
# weakened assertion or a rewritten checkout. Each name changes one decision.
$anchor = switch ($Mutant) {
  'factor' { @('return 1.4 * 21 *', 'return 1.3 * 21 *') }
  'passes' { @('return 1.4 * 21 *', 'return 1.4 * 20 *') }
  'overhead' { @(')) + 30', ')) + 29') }
  'headroom' { @('1.5 * [Math]::Min($Before, $BeforeCpu)', '1.4 * [Math]::Min($Before, $BeforeCpu)') }
  'floor' { @('[Math]::Max($Before, 1.5 * [Math]::Min($Before, $BeforeCpu))', '(1.5 * [Math]::Min($Before, $BeforeCpu))') }
  'cap' { @('[Math]::Min($Before, $BeforeCpu)', '$BeforeCpu') }
  'budget-cpu' { @('$reference = [Math]::Max($before, $after)', '$reference = [Math]::Max($beforeCpu, $afterCpu)') }
  'verdict-cpu' { @('$elapsed -le $budget', '$beforeCpu -le $budget') }
  'positive-deadline' { @("-not `$Event -and `$Arm -in @('baseline','issue-scan','no-linkage')", "-not `$Event -and `$Arm -in @('candidate','baseline','issue-scan','no-linkage')") }
  'event-deadline' { @("-not `$Event -and `$Arm -in @('baseline','issue-scan','no-linkage')", "`$Arm -in @('baseline','issue-scan','no-linkage')") }
  'accept-bad-cpu' { @('if (-not [double]::IsFinite($BeforeCpu) -or $BeforeCpu -le 0)', 'if ($false)') }
  'inert-factor' { @('2 * $reference + 10', '1 * $reference + 10') }
  'inert-overhead' { @('2 * $reference + 10', '2 * $reference + 9') }
  'event-factor' { @('3 * $reference + 10', '2 * $reference + 10') }
  'event-overhead' { @('3 * $reference + 10', '3 * $reference + 9') }
  'wall-headroom' { @('$headroomReference = 1.5 * $before', '$headroomReference = 1.5 * $beforeCpu') }
  'final-reference' { @('$reference = [Math]::Max($before, $after)', '$reference = $before') }
  'cpu-bracket' { @('$cpuStart = $process.TotalProcessorTime.TotalSeconds', '$cpuStart = 0') }
  'record-cpu' { @('beforeCpuSeconds = $beforeCpu', 'beforeCpuSeconds = $before') }
}
if ($Mutant -ne 'none') { $source = Replace-DerivationAnchor $source $anchor[0] $anchor[1] }
$bAst = Read-DerivationAst $baseline
$ast = Read-DerivationAst $source
$deadline = Get-DerivationFunction $ast 'Get-BoardScaleDeadline'
. ([scriptblock]::Create($deadline.Extent.Text))

# Predeclared Cartesian grid: tiny/large walls, CPU below/at/above the
# floor knee (CPU/wall = 2/3), equality and cap. No timing sample selection.
$walls = @(0.001, 0.1, 1.0, 4.86, 10.0, 100.0, 10000.0)
$ratios = @(0.001, 0.1, 0.5, (2.0 / 3 - 0.000001), (2.0 / 3), (2.0 / 3 + 0.000001), 0.9, 1.0, 1.5, 10.0)
$count = 0
foreach ($wall in $walls) {
  foreach ($ratio in $ratios) {
    $cpu = $wall * $ratio
    $actual = Get-BoardScaleDeadline $wall $cpu
    $floor = 1.4 * 21 * $wall + 30
    $cap = 1.4 * 21 * 1.5 * $wall + 30
    $expected = 1.4 * 21 * [Math]::Max($wall, 1.5 * [Math]::Min($wall, $cpu)) + 30
    $epsilon = 1e-9 * [Math]::Max(1, $expected)
    Assert-Derivation ([double]::IsFinite($actual) -and $actual -ge $floor - $epsilon -and $actual -le $cap + $epsilon) "deadline bounds wall=$wall cpu=$cpu actual=$actual"
    Assert-Derivation ([Math]::Abs($actual - $expected) -le $epsilon) "frozen deadline formula wall=$wall cpu=$cpu actual=$actual"
    if ($cpu -ge $wall) { Assert-Derivation ([Math]::Abs($actual - $cap) -le $epsilon) 'CPU cap equals B deadline' }
    $count++
  }
}
Write-Output "PASS AC2 predeclared deadline grid cells=$count floor=provisional-wall-budget cap=B-installed-deadline"
foreach ($bad in @($null, 0.0, -1.0, [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity)) {
  $refused = $false
  try { $null = Get-BoardScaleDeadline 1 $bad } catch { $refused = $_.Exception.Message -ceq 'BOARD_SCALE_BEFORE_CPU_INVALID' }
  Assert-Derivation $refused "named fail-closed beforeCpu=$bad"
}
$refused = $false
try { $null = Get-BoardScaleDeadline 1 } catch { $refused = $_.Exception.Message -ceq 'BOARD_SCALE_BEFORE_CPU_INVALID' }
Assert-Derivation $refused 'named fail-closed missing beforeCpu'
Write-Output 'PASS AC2 missing/non-finite/non-positive beforeCpu refused'

$bArmFunction = Get-DerivationFunction $bAst 'Invoke-BoardScaleArm'
$armFunction = Get-DerivationFunction $ast 'Invoke-BoardScaleArm'
$deadlineIf = @($armFunction.Body.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('$env:BOARD_SCALE_DEADLINE = [string]$start.AddSeconds')
})
Assert-Derivation ($deadlineIf.Count -eq 1) 'one negative-arm deadline branch'
$savedDeadline = $env:BOARD_SCALE_DEADLINE
try {
  foreach ($Arm in @('candidate','inert','ten-item-scan','baseline','issue-scan','no-linkage')) {
    foreach ($Event in @('','dispatch','lane-complete','review-complete','landed')) {
      $before = 4.86; $beforeCpu = 3.0; $start = [datetimeoffset]::UtcNow
      $env:BOARD_SCALE_DEADLINE = ''
      . ([scriptblock]::Create((Get-DerivationAssignment $armFunction '$budgetBefore')))
      $headroomReference = $null; $cooperativeDeadlineSeconds = $null
      . ([scriptblock]::Create($deadlineIf[0].Extent.Text))
      $negative = -not $Event -and $Arm -in @('baseline','issue-scan','no-linkage')
      Assert-Derivation ([bool]$env:BOARD_SCALE_DEADLINE -eq [bool]$negative) "deadline routing $Arm/$Event"
      if ($negative) {
        Assert-Derivation ($cooperativeDeadlineSeconds -eq (Get-BoardScaleDeadline $before $beforeCpu)) 'real branch uses bounded deadline'
        Assert-Derivation ($headroomReference -eq 1.5 * $before) 'verdict headroom remains wall time'
      } else { Assert-Derivation ($null -eq $cooperativeDeadlineSeconds) 'positive/event deadline remains null' }
    }
  }
} finally { $env:BOARD_SCALE_DEADLINE = $savedDeadline }
Write-Output 'PASS AC2 deadline routing negative-only; all positive/event combinations uncensored'

# Freeze complete statements, not arithmetic reimplementations. Event routing,
# elapsed handling and the cooperative wall censor remain byte-identical to B.
foreach ($name in @('$before','$after','$reference','$budgetBefore','$budget','$start','$finish','$entry','$elapsed')) {
  $bNodes = @($bArmFunction.Body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $name }, $true))
  $nodes = @($armFunction.Body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $name }, $true))
  Assert-Derivation ($bNodes.Count -gt 0 -and $nodes.Count -eq $bNodes.Count) "B assignment count $name"
  for ($i = 0; $i -lt $nodes.Count; $i++) {
    Assert-Derivation ($nodes[$i].Extent.Text -ceq $bNodes[$i].Extent.Text) "B statement identical $name/$i"
  }
}
$bVerdict = @($bArmFunction.Body.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains("`$record.verdict = 'EXCEEDED (censored)'")
})
$verdict = @($armFunction.Body.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains("`$record.verdict = 'EXCEEDED (censored)'")
})
Assert-Derivation ($bVerdict.Count -eq 1 -and $verdict.Count -eq 1 -and $verdict[0].Extent.Text -ceq $bVerdict[0].Extent.Text) 'B verdict statements identical'
foreach ($testVerdict in @($bVerdict[0], $verdict[0])) {
  $Arm = 'candidate'; $exitCode = 0; $censored = $false; $Event = ''
  $before = 2.0; $after = 2.0; $beforeCpu = 40.0; $afterCpu = 40.0; $elapsed = 100.0
  $reference = [Math]::Max($before, $after); $headroomReference = 1.5 * $before
  . ([scriptblock]::Create((Get-DerivationAssignment $bArmFunction '$budget')))
  $record = @{ verdict = 'INCONCLUSIVE'; timingVerdict = 'FAIL' }
  . ([scriptblock]::Create($testVerdict.Extent.Text))
  Assert-Derivation ($record.timingVerdict -ceq 'FAIL') 'D1 100 wall-s / 40 CPU-s positive rejected by B and candidate'
}
Write-Output 'PASS AC2 B and candidate reject D1 wait-bound 100-wall/40-CPU positive'
foreach ($after in @(2.0, 2.5)) {
  $Arm = 'issue-scan'; $Event = ''; $exitCode = 0; $censored = $true
  $before = 2.0; $beforeCpu = 1.0; $headroomReference = 1.5 * $before
  $elapsed = (Get-BoardScaleDeadline $before $beforeCpu) + 0.001
  . ([scriptblock]::Create((Get-DerivationAssignment $armFunction '$reference')))
  . ([scriptblock]::Create((Get-DerivationAssignment $armFunction '$budget')))
  $record = @{ verdict = 'INCONCLUSIVE'; timingVerdict = 'FAIL' }
  . ([scriptblock]::Create($verdict[0].Extent.Text))
  $expected = if ($after -eq 2.0) { 'EXCEEDED (censored)' } else { 'INCONCLUSIVE' }
  Assert-Derivation ($record.verdict -ceq $expected -and $record.timingVerdict -ceq 'FAIL') "negative wall verdict/fail-closed after=$after"
}
Write-Output 'PASS AC2 negative wall verdict and rising-after INCONCLUSIVE corner retained'

$bMeasure = Get-DerivationFunction $bAst 'Measure-BoardReference'
$measure = Get-DerivationFunction $ast 'Measure-BoardReference'
foreach ($name in @('$oracle','$start','$end','$body','$referenceBody','$clock','$result','$seconds','$script:BoardReferenceCounts')) {
  Assert-Derivation ((Get-DerivationAssignment $measure $name) -ceq (Get-DerivationAssignment $bMeasure $name)) "B reference statement identical $name"
}
# CPU is sampled only in this bracket and copied into the two additive record
# fields. The original wall reference function still returns only seconds.
$cpuStart = Get-DerivationAssignment $measure '$cpuStart'
Assert-Derivation ($cpuStart -ceq '$cpuStart = $process.TotalProcessorTime.TotalSeconds') 'CPU bracket starts at current process CPU'
$cpuEnd = Get-DerivationAssignment $measure '$script:BoardReferenceCpuSeconds'
Assert-Derivation ($cpuEnd -ceq '$script:BoardReferenceCpuSeconds = $process.TotalProcessorTime.TotalSeconds - $cpuStart') 'CPU bracket delta'
$measureText = $measure.Extent.Text
Assert-Derivation ($measureText.IndexOf($cpuStart) -lt $measureText.IndexOf('$clock =') -and
  $measureText.IndexOf($cpuEnd) -gt $measureText.IndexOf('$seconds =')) 'CPU and wall surround the same reference invocation'
foreach ($phase in @('before','after')) {
  Assert-Derivation ((Get-DerivationAssignment $armFunction ('$' + $phase + 'Cpu')) -ceq ('$' + $phase + 'Cpu = $script:BoardReferenceCpuSeconds')) "fresh $phase CPU sample"
  Assert-Derivation ((Get-DerivationAssignment $armFunction ('$' + $phase + 'Diagnostics')) -ceq ('$' + $phase + 'Diagnostics = $script:BoardReferenceDiagnostics')) "fresh $phase diagnostics"
}
$tables = @()
foreach ($fn in @($bArmFunction, $armFunction)) {
  $recordAssignment = Get-DerivationAssignment $fn '$record'
  $recordAst = Read-DerivationAst $recordAssignment
  $tables += $recordAst.Find({ param($n) $n -is [Management.Automation.Language.HashtableAst] }, $true)
}
$additive = @('beforeCpuSeconds','afterCpuSeconds','beforeDiagnostics','afterDiagnostics')
$bPairs = @($tables[0].KeyValuePairs)
$pairs = @($tables[1].KeyValuePairs | Where-Object { $_.Item1.Value -cnotin $additive })
Assert-Derivation ($pairs.Count -eq $bPairs.Count) 'B record field count unchanged'
for ($i = 0; $i -lt $bPairs.Count; $i++) {
  Assert-Derivation ($pairs[$i].Item1.Extent.Text -ceq $bPairs[$i].Item1.Extent.Text -and
    $pairs[$i].Item2.Extent.Text -ceq $bPairs[$i].Item2.Extent.Text) "B record field identical $($bPairs[$i].Item1.Value)"
}
foreach ($key in $additive) {
  $pair = @($tables[1].KeyValuePairs | Where-Object { $_.Item1.Value -ceq $key })
  $value = switch ($key) {
    'beforeCpuSeconds' { '$beforeCpu' }; 'afterCpuSeconds' { '$afterCpu' }
    'beforeDiagnostics' { '$beforeDiagnostics' }; 'afterDiagnostics' { '$afterDiagnostics' }
  }
  Assert-Derivation ($pair.Count -eq 1 -and $pair[0].Item2.Extent.Text -ceq $value) "additive receipt $key"
}
Write-Output 'PASS AC1 instrumentation CPU bracket and additive receipt fields (not hosted variance proof)'

$probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('board-scale-derivation-' + [guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $probeRoot 'fixtures'))
  # A small synthetic oracle exercises only the measurement wrapper, not board
  # scale, its immutable fixture or a hosted timing/variance assertion.
  [IO.File]::WriteAllText((Join-Path $probeRoot 'fixtures/board-history-v289.ps1'), @'
  $rows = [object[]]::new(20000)
  $count = 24500; $specs = [object[]]::new(3415); $errors = @()
  $work = [Diagnostics.Stopwatch]::StartNew()
  while ($work.ElapsedMilliseconds -lt 30) { $null = [Math]::Sqrt(123456.0) }
  Start-Sleep -Milliseconds 30
  foreach ($label in $specs.Keys) {}
'@)
  $probeSource = @'
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
function Assert-Derivation([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Board([bool]$Condition, [string]$Message) { Assert-Derivation $Condition $Message }
'@ + "`n" + $measure.Extent.Text + "`n" + @'
    $wall = Measure-BoardReference 'SYNTHETIC-reference-path'
    Assert-Derivation ($wall -gt 0 -and [double]::IsFinite($script:BoardReferenceCpuSeconds) -and
      $script:BoardReferenceCpuSeconds -gt 0) 'real parent CPU delta and wall return'
    foreach ($key in @('gen2GcCount','processAgeSeconds','uptimeSeconds')) {
      Assert-Derivation ($script:BoardReferenceDiagnostics.ContainsKey($key) -and
        [double]::IsFinite($script:BoardReferenceDiagnostics[$key]) -and
        $script:BoardReferenceDiagnostics[$key] -ge 0) "measured diagnostic $key"
    }
'@
  $probePath = Join-Path $probeRoot 'probe.ps1'
  [IO.File]::WriteAllText($probePath, $probeSource)
  $probeOutput = & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $probePath 2>&1
  Assert-Derivation ($LASTEXITCODE -eq 0) "synthetic measurement wrapper: $probeOutput"
} finally {
  $resolved = [IO.Path]::GetFullPath($probeRoot)
  if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetTempPath().TrimEnd('\','/') -or
      (Split-Path -Leaf $resolved) -notlike 'board-scale-derivation-*') { throw 'unsafe derivation cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output 'PASS AC1 synthetic measurement wrapper CPU/GC/process-age/uptime (not hosted variance proof)'

foreach ($function in @($bAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))) {
  if ($function.Name -in @('Measure-BoardReference','Invoke-BoardScaleArm')) { continue }
  Assert-Derivation ((Get-DerivationFunction $ast $function.Name).Extent.Text -ceq $function.Extent.Text) "B function identical $($function.Name)"
}
$hourlyPath = Join-Path $PSScriptRoot 'board-hourly-scale.test.ps1'
$actualHourlyBlob = @(& git -C $PSScriptRoot hash-object --path=.orchestrator/board-hourly-scale.test.ps1 $hourlyPath) -join ''
Assert-Derivation ($LASTEXITCODE -eq 0 -and $actualHourlyBlob -ceq $hourlyBlob) 'B hourly arm list/assertions unchanged'
Write-Output "PASS AC3 B statements/censor/event/fixtures identical support=$baselineBlob hourly=$hourlyBlob"
Write-Output 'PASS board-scale derivation (hosted AC1 and full-path board-history proof remain separate)'
