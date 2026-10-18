<#
.SYNOPSIS
Install a released controller: an annotated controller-v* tag on the public
controller repository.

.DESCRIPTION
controller-release-install/v1. Release tags are the only install authority.
Todd approves each release on the controller repository; this script never
reads review receipts. It fetches the tag into the container (fetch only,
never a remote and never a push), checks the tagged commit out detached, then
re-runs the installer from that commit so the release installs itself.
Rollback is the same command with the previous tag.

.EXAMPLE
./install-controller-skills.ps1 -ReleaseTag controller-v2.116
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^controller-v\d+\.\d+(\.\d+)?$')]
  [string]$ReleaseTag,
  [string]$ReleaseRepository = 'https://github.com/chase-sets/chase-sets-controller.git',
  # Test seam: production callers omit it and install into the live user skill root.
  [Parameter(DontShow)]
  [string]$DestinationRoot,
  # Test seam: production callers omit it and link skills into the user Codex skill root.
  [Parameter(DontShow)]
  [string]$CodexSkillRoot
)

$ErrorActionPreference = "Stop"
$container = Split-Path -Parent $PSScriptRoot
$releaseMarker = 'controller-release-install/v1'
$releaseRef = "refs/controller-releases/$ReleaseTag"

function Invoke-ContainerGit {
  param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
  $output = @(& git -C $container @Arguments 2>&1)
  $code = $LASTEXITCODE
  if ($code -ne 0 -and -not $AllowFailure) {
    throw "controller skill install refused: git $($Arguments[0]) failed: $(($output | Select-Object -First 3) -join ' ')"
  }
  [pscustomobject]@{ ExitCode = $code; Lines = @($output | ForEach-Object { [string]$_ }) }
}

if ((Invoke-ContainerGit @('status', '--porcelain', '--untracked-files=no')).Lines) {
  throw "controller skill install refused: tracked controller worktree is dirty"
}

# Resolve the release. The tag must exist on the release repository as an
# annotated tag, and a previously fetched copy must not differ from it: a
# moved release tag is refused, never followed.
$remote = Invoke-ContainerGit @('ls-remote', '--tags', '--refs', $ReleaseRepository, "refs/tags/$ReleaseTag") -AllowFailure
if ($remote.ExitCode -ne 0) { throw "controller skill install refused: release repository unreadable: $ReleaseRepository" }
$remoteLines = @($remote.Lines | Where-Object { $_ -match '^[a-f0-9]{40}\trefs/tags/' })
if ($remoteLines.Count -ne 1) { throw "controller skill install refused: release tag $ReleaseTag not found on $ReleaseRepository" }
$remoteObject = ($remoteLines[0] -split '\t')[0]
$existing = Invoke-ContainerGit @('rev-parse', '--verify', '--quiet', $releaseRef) -AllowFailure
if ($existing.ExitCode -eq 0 -and $existing.Lines[0] -cne $remoteObject) {
  throw "controller skill install refused: release tag $ReleaseTag moved (local $($existing.Lines[0]), remote $remoteObject)"
}
if ($existing.ExitCode -ne 0) {
  # Fetch by URL into a private namespace: no remote is configured, nothing is
  # pushed, and a container-local tag with the same name is never touched.
  [void](Invoke-ContainerGit @('fetch', '--no-tags', '--quiet', $ReleaseRepository, "refs/tags/$($ReleaseTag):$releaseRef"))
}
$localObject = (Invoke-ContainerGit @('rev-parse', '--verify', $releaseRef)).Lines[0]
if ($localObject -cne $remoteObject) { throw "controller skill install refused: fetched release $ReleaseTag does not match the release repository" }
if ((Invoke-ContainerGit @('cat-file', '-t', $localObject)).Lines[0] -cne 'tag') {
  throw "controller skill install refused: $ReleaseTag is not an annotated tag"
}
$releaseCommit = (Invoke-ContainerGit @('rev-parse', '--verify', "$releaseRef^{commit}")).Lines[0].ToLowerInvariant()

$head = (Invoke-ContainerGit @('rev-parse', 'HEAD')).Lines[0].ToLowerInvariant()
if ($head -cne $releaseCommit) {
  # The release installs itself: check it out, then hand over to its own
  # installer, so its inventory and checks apply rather than this script's.
  $targetInstaller = Invoke-ContainerGit @('show', "$($releaseCommit):.orchestrator/install-controller-skills.ps1") -AllowFailure
  if ($targetInstaller.ExitCode -ne 0 -or -not (($targetInstaller.Lines -join ' ').Contains($releaseMarker, [StringComparison]::Ordinal))) {
    throw "controller skill install refused: $ReleaseTag predates tag installs ($releaseMarker); it cannot be installed by tag"
  }
  if (-not $PSCmdlet.ShouldProcess($container, "check out $ReleaseTag ($releaseCommit) detached and install it")) { return }
  [void](Invoke-ContainerGit @('checkout', '--quiet', '--detach', $releaseCommit))
  $handover = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'install-controller-skills.ps1'),
    '-ReleaseTag', $ReleaseTag, '-ReleaseRepository', $ReleaseRepository)
  if ($DestinationRoot) { $handover += @('-DestinationRoot', $DestinationRoot) }
  if ($CodexSkillRoot) { $handover += @('-CodexSkillRoot', $CodexSkillRoot) }
  & (Get-Process -Id $PID).Path @handover
  exit $LASTEXITCODE
}

$installLockModule = Join-Path $PSScriptRoot "controller-install-lock.psm1"
Import-Module $installLockModule -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "review-head-contract.psm1") -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot "controller-heavy-paths.psm1") -Force -DisableNameChecking

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
$codexSkillRoot = if ($CodexSkillRoot) { [IO.Path]::GetFullPath($CodexSkillRoot) } else { Join-Path $HOME ".codex/skills" }

# A skill directory may be created only for a skill the installed release did
# not ship. Its inventory is read from the installed release commit, which the
# container already holds. Any failure to prove the skill is new refuses, so a
# missing directory for a shipped skill is still reported, never papered over.
$script:previousReleaseSkills = $null
function Get-PreviousReleaseSkills {
  if ($null -ne $script:previousReleaseSkills) { return $script:previousReleaseSkills }
  $recordPath = Join-Path $destinationRoot 'native-db/release.json'
  if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) { throw 'no installed release record' }
  $previousCommit = [string](Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json).commit
  if ($previousCommit -notmatch '^[a-f0-9]{40}$') { throw 'installed release record names no commit' }
  $previousModule = Invoke-ContainerGit @('show', "$($previousCommit):.orchestrator/controller-install-lock.psm1") -AllowFailure
  if ($previousModule.ExitCode -ne 0) { throw "installed release $previousCommit is unreadable" }
  $scratch = Join-Path ([IO.Path]::GetTempPath()) "controller-previous-inventory-$([guid]::NewGuid().ToString('N'))"
  [void][IO.Directory]::CreateDirectory($scratch)
  $module = $null
  try {
    $modulePath = Join-Path $scratch 'previous-release-install-lock.psm1'
    [IO.File]::WriteAllText($modulePath, ($previousModule.Lines -join [Environment]::NewLine))
    $module = Import-Module $modulePath -Prefix 'PreviousRelease' -PassThru -Force -DisableNameChecking
    $skills = @(& (Get-Command -Module $module.Name -Name 'Get-PreviousReleaseControllerSkillInstallInventory') |
      ForEach-Object { ([string]$_.destination -split '[/\\]')[0] } | Sort-Object -Unique)
    if ($skills.Count -eq 0) { throw 'installed release inventory is empty' }
    $script:previousReleaseSkills = $skills
    return $skills
  } finally {
    if ($module) { Remove-Module -ModuleInfo $module -Force }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# The skill is the human-governing contract and these scripts are the execution
# surface. They ship from one released container commit, but semantic
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
  "harvest-observed-lanes.ps1",
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
    $previousSkills = $null
    try { $previousSkills = Get-PreviousReleaseSkills } catch {
      throw "controller skill install refused: live skill directory missing: $liveSkillRoot (cannot prove the skill is new: $($_.Exception.Message))"
    }
    if ($previousSkills -contains $skillName) {
      throw "controller skill install refused: live skill directory missing: $liveSkillRoot"
    }
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
    $delta = Get-ControllerInstalledHeavyDelta -ContainerRoot $container -DestinationRoot $destinationRoot -CandidateHead $releaseCommit
  } catch {
    Write-Output 'Controller install heavy classification: unknown; retaining product admission and owner refusal'
  }
  $requiresHeavyGuard = $null -eq $delta -or $delta.classification -cne 'non-heavy'
  if ($delta) {
    Write-Output "Controller install heavy classification: $($delta.classification); installed=$($delta.installedHead); candidate=$releaseCommit; heavyPaths=$($delta.heavyPaths -join ',')"
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
    # The helper and its identity live beside the skills. Every reader (the
    # heavy-path classifier, the release battery, the freshness check) reads
    # <skills root>/native-db; installs before tag releases wrote there too.
    $helperDestination = Join-Path $destinationRoot 'native-db/admission.py'
    $identityDestination = Join-Path $destinationRoot 'native-db/identity.json'
    $releaseDestination = Join-Path $destinationRoot 'native-db/release.json'
    if (Test-Path -LiteralPath $helperDestination) {
      if (-not (Test-Path -LiteralPath $identityDestination)) { throw 'controller skill install refused: native helper identity missing' }
      $prior = Get-Content -LiteralPath $identityDestination -Raw | ConvertFrom-Json
      if ((Get-FileHash -LiteralPath $helperDestination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $prior.digest) {
        throw 'controller skill install refused: native helper drift'
      }
    }
    if ($PSCmdlet.ShouldProcess($helperDestination, 'install released native helper')) {
      [void][IO.Directory]::CreateDirectory((Split-Path -Parent $helperDestination))
      [IO.File]::WriteAllBytes($helperDestination, $helperBytes)
      [IO.File]::WriteAllText($identityDestination, (@{head=$releaseCommit;digest=$helperDigest} | ConvertTo-Json -Compress))
      if ((Get-FileHash -LiteralPath $helperDestination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $helperDigest) { throw 'native helper install verification failed' }
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
    if ($PSCmdlet.ShouldProcess($destination, "install released controller skill file")) {
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
  # Codex reads skills from its own root. Link each installed skill there when
  # nothing exists at that path; an existing entry is the user's and is left alone.
  foreach ($skillName in @($installPlan | ForEach-Object { ($_.Destination.Substring($destinationRoot.Length).TrimStart('\', '/') -split '[/\\]')[0] } | Sort-Object -Unique)) {
    $codexEntry = Join-Path $codexSkillRoot $skillName
    if (Get-Item -LiteralPath $codexEntry -Force -ErrorAction SilentlyContinue) { continue }
    if ($PSCmdlet.ShouldProcess($codexEntry, 'link installed skill for Codex')) {
      [void][IO.Directory]::CreateDirectory($codexSkillRoot)
      New-Item -ItemType Junction -Path $codexEntry -Target (Join-Path $destinationRoot $skillName) | Out-Null
    }
  }
  if ($PSCmdlet.ShouldProcess($releaseDestination, 'record installed release')) {
    # Written last: a release record exists only after every file verified.
    $release = [ordered]@{
      schemaVersion = 'controller-release/v1'; tag = $ReleaseTag; tagObject = $localObject
      commit = $releaseCommit; repository = $ReleaseRepository; installedAt = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($releaseDestination, ($release | ConvertTo-Json -Compress) + [Environment]::NewLine)
  }
  } finally {
    if ($admissionHeld) { $admissionMutex.ReleaseMutex() }
    if ($admissionMutex) { $admissionMutex.Dispose() }
  }
}

Write-Output "Installed controller release $ReleaseTag ($releaseCommit)"
