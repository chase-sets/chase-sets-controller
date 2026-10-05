<#
.SYNOPSIS
Install the exact independently-reviewed controller skill release.

.EXAMPLE
./install-controller-skills.ps1 -ReviewedCommit <40-char-sha>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [ValidatePattern("^[a-f0-9]{40}$")]
  [string]$ReviewedCommit,
  # Test seams: production callers omit both and use the canonical receipt log
  # and live user skill root.
  [Parameter(DontShow)]
  [string]$ReceiptLog,
  [Parameter(DontShow)]
  [string]$DestinationRoot
)

$ErrorActionPreference = "Stop"
$container = Split-Path -Parent $PSScriptRoot
$installLockModule = Join-Path $PSScriptRoot "controller-install-lock.psm1"
Import-Module $installLockModule -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "controller-heavy-paths.psm1") -Force -DisableNameChecking

$head = (& git -C $container rev-parse HEAD).Trim().ToLowerInvariant()
if ($head -ne $ReviewedCommit.ToLowerInvariant()) {
  throw "controller skill install refused: HEAD $head does not equal reviewed commit $ReviewedCommit"
}
if ((& git -C $container status --porcelain --untracked-files=no)) {
  throw "controller skill install refused: tracked controller worktree is dirty"
}

$receiptPath = if ($ReceiptLog) { [IO.Path]::GetFullPath($ReceiptLog) } else { Join-Path $PSScriptRoot "dispatch-log.jsonl" }
$markerPath = Join-Path $PSScriptRoot "controller-review-strict-v1-capability.json"
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
  throw "controller skill install refused: strict controller review capability marker is missing"
}
$directHistory = Read-ExactHeadReviewHistory -Path $receiptPath
if (-not $directHistory.complete) { throw "controller skill install refused: review history is not complete" }
$candidateIssues = @(Get-ControllerReviewClassifiedHistory -History $directHistory | ForEach-Object { $_.classification } | Where-Object {
  $_.strict -and $_.valid -and $_.controllerHead -ceq $ReviewedCommit
} | ForEach-Object { [int]$_.issue } | Sort-Object -Unique)
if ($candidateIssues.Count -ne 1) { throw "controller skill install refused: exact positive controller issue identity is ambiguous" }
$directReduction = Reduce-ControllerReleaseReview -Issue $candidateIssues[0] -ControllerHead $ReviewedCommit -Mode strict-v1 -History $directHistory
if ($directReduction.state -cne "authorized") {
  throw "controller skill install refused: shared controller review reduction is $($directReduction.state)/$($directReduction.reason)"
}

# capability-matrix.json is the only installed file with TWO owners. Its cell
# scores, vetoes and bars are authored in the tracked source and reviewed like
# code; its `measured` blocks and `measuredAt` stamp are GENERATED into the LIVE
# file by matrix-refresh.ps1 after every cost harvest, and are never committed.
#
# A straight copy therefore reverts the loop's own telemetry to whatever was
# last committed — silently, and worst at the worst moment, since an install
# follows a review, which is exactly when a fresh recompute exists. The drift
# alarm would then measure against a resurrected baseline and report calm.
#
# `adjudicated` is preserved for the same reason: matrix-refresh -Adjudicate is
# its only writer, and it writes to the live file.
#
# The transfer is joined by configuration (exact model + effort), not by the
# literal config id, so an id rename does not drop it; and `measured` plus the
# stamp move only between matrices stamped with the same
# `measuredAt.generatedSchema`, so a refresh-script schema change does not
# resurrect blocks keyed the old way. `adjudicated` moves regardless. See
# Merge-ControllerGeneratedMatrixBytes in controller-install-lock.psm1.
function Merge-GeneratedBlocks {
  param([string]$SourcePath, [string]$DestinationPath)
  $bytes = Merge-ControllerGeneratedMatrixBytes `
    -CandidateBytes ([IO.File]::ReadAllBytes($SourcePath)) `
    -LiveBytes ([IO.File]::ReadAllBytes($DestinationPath))
  [Text.UTF8Encoding]::new($false, $true).GetString($bytes).TrimEnd("`r", "`n")
}

$sourceRoot = Join-Path $PSScriptRoot "controller-skills"
$destinationRoot = if ($DestinationRoot) { [IO.Path]::GetFullPath($DestinationRoot) } else { Join-Path $HOME ".claude/skills" }

# The skill is the human-governing contract and these scripts are the execution
# surface. They ship from one exact reviewed container commit, but semantic
# constants could still drift inside that commit unless the installer binds
# them. Runtime is canonical; every marker below is derived from its object.
$runtimeFiles = @(
  "integration-dispatch-contract.ps1",
  "controller-install-lock.psm1",
  "orchestration-log-lock.psm1",
  "lease-contract.psm1",
  "lease.ps1",
  "review-head-contract.psm1",
  "landed-integration-evidence.psm1",
  "dispatch-lane.ps1",
  "rebase-integration.ps1",
  "landed-integration-consume.ps1",
  "landed-integration-dispatch.ps1",
  "review-head-reducer.ps1",
  "landing-preflight.ps1",
  "review-queue-health.ps1",
  "log-event.ps1",
  "cost-harvest.ps1",
  "matrix-refresh.ps1",
  "check-controller-skill-freshness.ps1",
  "controller-release-battery.ps1",
  "invoke-heavy-verifier.ps1",
  "native-db-admission.py",
  "heavy-slot.cjs",
  "heavy-nested-client.cjs",
  "heavy-nested-owner.cs",
  "fail-closed-guard-evidence.ps1",
  "fail-closed-guard-evidence.schema.json",
  "fail-closed-guard-suite-result.schema.json",
  "fail-closed-guard-evidence-aggregate.ps1"
)
foreach ($runtimeFile in $runtimeFiles) {
  $runtimePath = Join-Path $PSScriptRoot $runtimeFile
  if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
    throw "controller skill install refused: canonical controller runtime missing: $runtimePath"
  }
}
$reviewContract = Get-ExactHeadReviewContract
$milestoneSkillPath = Join-Path $sourceRoot "milestone-orchestrator/SKILL.md"
if (-not (Test-Path -LiteralPath $milestoneSkillPath -PathType Leaf)) {
  throw "controller skill install refused: source missing: $milestoneSkillPath"
}
$milestoneSkillText = Get-Content -LiteralPath $milestoneSkillPath -Raw
$reviewMarkers = @(
  $reviewContract.receiptSchema,
  $reviewContract.reducerSchema,
  "landing-preflight/v1"
)
foreach ($marker in @($reviewMarkers)) {
  if (-not $milestoneSkillText.Contains($marker, [StringComparison]::Ordinal)) {
    throw "controller skill install refused: staged skill/runtime controller contract drift (missing marker '$marker')"
  }
}

$files = @(Get-ControllerSkillInstallInventory | ForEach-Object {
  @{ Source = $_.source; Destination = $_.destination; PreserveGenerated = [bool]$_.preserveGenerated }
})

$installPlan = @()
foreach ($file in $files) {
  $source = Join-Path $sourceRoot $file.Source
  $destination = Join-Path $destinationRoot $file.Destination
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "controller skill install refused: source missing: $source"
  }
  $skillName = ($file.Destination -split "[/\\]")[0]
  $liveSkillRoot = Join-Path $destinationRoot $skillName
  if (-not (Test-Path -LiteralPath $liveSkillRoot -PathType Container)) {
    throw "controller skill install refused: live skill directory missing: $liveSkillRoot"
  }
  $installPlan += [pscustomobject]@{
    Source = $source
    Destination = $destination
    PreserveGenerated = [bool]$file.PreserveGenerated
    MergedContent = $null
    SourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
  }
}

# Merging runs only after EVERY refusal check has passed, so a malformed matrix
# can never pre-empt a refusal that should have fired first, and nothing is
# written until the whole plan is known-good.
Invoke-WithControllerInstallLock -Body {
  # Only a proven non-heavy diff may avoid product admission. Missing identity,
  # helper drift or unavailable Git history retains the existing fail-closed guard.
  $delta = $null
  try {
    $delta = Get-ControllerInstalledHeavyDelta -ContainerRoot $container -DestinationRoot $destinationRoot -CandidateHead $ReviewedCommit
  } catch {
    Write-Output 'Controller install heavy classification: unknown; retaining product admission and owner refusal'
  }
  $requiresHeavyGuard = $null -eq $delta -or $delta.classification -cne 'non-heavy'
  if ($delta) {
    Write-Output "Controller install heavy classification: $($delta.classification); installed=$($delta.installedHead); candidate=$ReviewedCommit; heavyPaths=$($delta.heavyPaths -join ',')"
  }
  $admissionMutex = $null
  $admissionHeld = $false
  try {
    if ($requiresHeavyGuard) {
      # Never replace the cleanup implementation under any owner, including
      # unreadable/schema6 owners and retained interrupted launches.
      $key = [IO.Path]::GetFullPath($container).TrimEnd('\','/').ToUpperInvariant()
      $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key))).ToLowerInvariant()
      $admissionMutex = [Threading.Mutex]::new($false, "Global\chase-sets-heavy-verifier-$hash")
      try { $admissionHeld = $admissionMutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $admissionHeld = $true }
      if (-not $admissionHeld) { throw 'controller skill install refused: product admission unavailable' }
      if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'verify-lock.d')) {
        throw 'controller skill install refused: retained verifier owner; no live replacement or schema6 downgrade'
      }
    }
    $helperPath = Join-Path $PSScriptRoot 'native-db-admission.py'
    $helperBytes = [IO.File]::ReadAllBytes($helperPath)
    $helperDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($helperBytes)).ToLowerInvariant()
    if ($DestinationRoot) {
      # The existing destination seam remains entirely machine-local and inert.
      $helperDestination = Join-Path $destinationRoot 'native-db/admission.py'
      $identityDestination = Join-Path $destinationRoot 'native-db/identity.json'
      if (Test-Path -LiteralPath $helperDestination) {
        if (-not (Test-Path -LiteralPath $identityDestination)) { throw 'controller skill install refused: native helper identity missing' }
        $prior = Get-Content -LiteralPath $identityDestination -Raw | ConvertFrom-Json
        if ((Get-FileHash -LiteralPath $helperDestination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $prior.digest) {
          throw 'controller skill install refused: native helper drift'
        }
      }
      if ($PSCmdlet.ShouldProcess($helperDestination, 'install exact reviewed native helper')) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $helperDestination))
        [IO.File]::WriteAllBytes($helperDestination, $helperBytes)
        [IO.File]::WriteAllText($identityDestination, (@{head=$ReviewedCommit;digest=$helperDigest} | ConvertTo-Json -Compress))
        if ((Get-FileHash -LiteralPath $helperDestination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $helperDigest) { throw 'native helper install verification failed' }
      }
    } elseif ($PSCmdlet.ShouldProcess('/opt/chase-sets-native-db/admission.py', 'install exact reviewed native helper')) {
      $installPython = @'
import base64, hashlib, json, os, pathlib, stat, sys
value = json.loads(sys.stdin.buffer.read(1048577))
assert set(value) == {'head','digest','bytes'}
payload = base64.b64decode(value['bytes'], validate=True)
assert hashlib.sha256(payload).hexdigest() == value['digest']
root = pathlib.Path('/opt/chase-sets-native-db')
for path in (pathlib.Path('/'), pathlib.Path('/opt')):
    info = path.lstat()
    assert stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022
if not root.exists(): root.mkdir(mode=0o755)
info = root.lstat()
assert stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022 and root.resolve() == root
target, identity = root/'admission.py', root/'identity.json'
for path in (target, identity):
    if path.exists() or path.is_symlink():
        info = path.lstat()
        assert stat.S_ISREG(info.st_mode) and info.st_uid == 0 and not info.st_mode & 0o022
if target.exists():
    prior = json.loads(identity.read_text())
    assert set(prior) == {'head','digest'} and hashlib.sha256(target.read_bytes()).hexdigest() == prior['digest'], 'native helper drift'
temporary = root / ('admission.'+value['head']+'.tmp')
with temporary.open('xb') as stream:
    stream.write(payload); stream.flush(); os.fsync(stream.fileno())
os.chmod(temporary, 0o644)
os.replace(temporary, target)
identity.write_text(json.dumps({'head':value['head'],'digest':value['digest']},separators=(',',':')))
os.chmod(identity, 0o644)
assert hashlib.sha256(target.read_bytes()).hexdigest() == value['digest']
print('native helper installed '+value['head']+' '+value['digest'])
'@
      $start = [Diagnostics.ProcessStartInfo]::new()
      $start.FileName = 'C:\Windows\System32\wsl.exe'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
      $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
      $start.Environment.Clear()
      foreach ($name in @('SystemRoot','WINDIR','SystemDrive')) { $start.Environment[$name] = [Environment]::GetEnvironmentVariable($name) }
      $start.Environment['WSLENV'] = ''
      foreach ($argument in @('-d','Ubuntu','--exec','/usr/bin/env','-i','PATH=/usr/bin:/bin','LANG=C','/usr/bin/python3','-c',$installPython)) { $start.ArgumentList.Add($argument) }
      $installer = [Diagnostics.Process]::Start($start)
      $output = $installer.StandardOutput.ReadToEndAsync(); $errors = $installer.StandardError.ReadToEndAsync()
      $installer.StandardInput.WriteLine((@{head=$ReviewedCommit;digest=$helperDigest;bytes=[Convert]::ToBase64String($helperBytes)} | ConvertTo-Json -Compress))
      $installer.StandardInput.Close()
      if (-not $installer.WaitForExit(30000)) { $installer.Kill(); [void]$installer.WaitForExit(30000); throw 'native helper install expired' }
      if ($installer.ExitCode -ne 0) { throw "native helper install refused: $($errors.GetAwaiter().GetResult())" }
      Write-Output $output.GetAwaiter().GetResult()
    }
foreach ($file in $installPlan) {
  if (-not $file.PreserveGenerated) { continue }
  if (-not (Test-Path -LiteralPath $file.Destination -PathType Leaf)) { continue }
  try {
    $file.MergedContent = Merge-GeneratedBlocks -SourcePath $file.Source -DestinationPath $file.Destination
  }
  catch {
    # Nothing readable to preserve. Copying is then correct — but say so, because
    # a silent fallback here is indistinguishable from the clobber this prevents.
    Write-Warning "generated blocks not preserved for $($file.Destination) (unreadable as JSON): $($_.Exception.Message)"
    $file.MergedContent = $null
  }
}

  foreach ($file in $installPlan) {
    $source = $file.Source
    $destination = $file.Destination
    if ($PSCmdlet.ShouldProcess($destination, "install reviewed controller skill file")) {
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    if ($file.MergedContent) {
      Set-Content -LiteralPath $destination -Encoding utf8 -Value $file.MergedContent
      # Verified by content rather than by source hash: the installed file is
      # deliberately not byte-identical to the source here.
      $written = (Get-Content -LiteralPath $destination -Raw)
      if ($written.Trim() -ne $file.MergedContent.Trim()) {
        throw "controller skill install verification failed for $destination"
      }
    }
    else {
      Copy-Item -LiteralPath $source -Destination $destination -Force
      $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
      if ($file.SourceHash -ne $destinationHash) {
        throw "controller skill install verification failed for $destination"
      }
    }
    }
  }
  } finally {
    if ($admissionHeld) { $admissionMutex.ReleaseMutex() }
    if ($admissionMutex) { $admissionMutex.Dispose() }
  }
}

Write-Output "Installed reviewed controller skills from $ReviewedCommit"
