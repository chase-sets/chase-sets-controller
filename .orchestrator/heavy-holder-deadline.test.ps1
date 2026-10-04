[CmdletBinding()]
param(
  [string]$GuardRevision = '',
  [ValidateSet('', 'hard-coded-15s', 'ceiling-removed')][string]$Mutant = ''
)

$ErrorActionPreference = 'Stop'
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'
function Assert-True($Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Read-Source([string]$Name) {
  if (-not $GuardRevision) { return [IO.File]::ReadAllText((Join-Path $PSScriptRoot $Name)) }
  $lines = @(& git -C (Split-Path -Parent $PSScriptRoot) show "${GuardRevision}:.orchestrator/$Name")
  if ($LASTEXITCODE -ne 0) { throw "cannot read $Name at $GuardRevision" }
  return $lines -join "`n"
}
$guard = Read-Source 'invoke-heavy-verifier.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($guard, [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) 'guard parses'
foreach ($definition in $ast.FindAll({ param($n)
    $n -is [Management.Automation.Language.FunctionDefinitionAst]
  }, $false)) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
$budget = Get-HeavyOwnershipCensusDeadlineMs 12
Assert-True ($budget -eq 24000) 'fixture uses the actual 12-candidate holder budget'

# The VM executes the complete production acquire path with synthetic OS/time
# boundaries. No holder process, heavy body, real admission or lock is created.
$inputJson = @{ source = (Read-Source 'heavy-slot.cjs'); budgetMs = $budget; mutant = $Mutant } | ConvertTo-Json -Compress
$inputJson | & node (Join-Path $PSScriptRoot 'fixtures/heavy-holder-deadline.cjs')
if ($LASTEXITCODE -ne 0) { throw "holder deadline controls failed (exit $LASTEXITCODE)" }

# Exercise the actual publisher and actual binding call site, not a parallel
# test implementation. The census stops at a sentinel before any OS authority.
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$root = Join-Path $temp ('heavy-holder-deadline-' + [guid]::NewGuid().ToString('N'))
try {
  [IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator')) | Out-Null
  foreach ($number in 1..12) {
    [IO.File]::WriteAllText((Join-Path $root ".orchestrator/dispatch-launch-$number.json"), '{}')
  }
  $container = $root
  $isAttachedAdmission = $true
  $GuardedPid = 9012
  $GuardedProcessStartUtc = '2026-01-01T00:00:00Z'
  $AdmissionNonce = 'b' * 32
  $admissionResultFull = Join-Path $root 'result.json'
  $script:admissionPendingSequence = 0
  function Get-LiveDispatchOwnership {
    param($RuntimeRoot, $TempRoot, $ContainerRoot, $DeadlineMs, $GitIdentityResolver)
    $pending = Get-Content -LiteralPath "$admissionResultFull.pending" -Raw | ConvertFrom-Json
    Assert-True ($pending.nonce -ceq $AdmissionNonce) 'pending nonce is bound to this holder'
    Assert-True ($pending.budgetMs -eq $DeadlineMs) 'pending carries the exact census budget'
    Assert-True ($pending.budgetMs -eq $budget) 'publisher and waiter fixture use the same fleet budget'
    Assert-True ($pending.sequence -eq $script:expectedSequence) 'each census publishes fresh progress'
    Assert-True (-not (Test-Path -LiteralPath $admissionResultFull)) 'pending never publishes acceptance'
    throw 'fixture-census-observed'
  }
  foreach ($script:expectedSequence in 1..2) {
    $binding = Get-HeavyCallerBinding
    Assert-True ($binding.Reason -like '*fixture-census-observed*') "binding publishes before census: $($binding.Reason)"
  }
  $isAttachedAdmission = $false
  Write-AdmissionPending 24000
  $pending = Get-Content -LiteralPath "$admissionResultFull.pending" -Raw | ConvertFrom-Json
  Assert-True ($pending.sequence -eq 2) 'non-attached callers do not publish pending'
  Write-Output 'PASS actual holder publisher: nonce, exact budget, increasing sequence, non-attached no-op'
} finally {
  $resolved = [IO.Path]::GetFullPath($root)
  Assert-True ($resolved.StartsWith($temp + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'cleanup remains in owned temp root'
  Assert-True ((Split-Path -Leaf $resolved) -like 'heavy-holder-deadline-*') 'cleanup has owned prefix'
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
