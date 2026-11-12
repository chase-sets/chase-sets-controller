$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'controller-install-lock.psm1') -Force -DisableNameChecking
$sandbox = Join-Path $PSScriptRoot ('artifacts/skill-reference-archive-test-' + [guid]::NewGuid().ToString('N'))
$names = @('defect-classes.md', 'stall-gotchas.md',
  'defect-classes.md.bak-20261015T0925', 'defect-classes.md.bak-20261102T1400')
$script:checks = 0
function Assert-Archive([bool]$Condition, [string]$Message) {
  $script:checks++
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function New-Fixture {
  $root = Join-Path $sandbox ([guid]::NewGuid().ToString('N'))
  $f = @{ContainerRoot=Join-Path $root 'container'; DestinationRoot=Join-Path $root 'live'; CodexSkillRoot=Join-Path $root 'codex'}
  [void][IO.Directory]::CreateDirectory((Join-Path $f.ContainerRoot '.orchestrator'))
  [void][IO.Directory]::CreateDirectory($f.CodexSkillRoot)
  $references = Join-Path $f.DestinationRoot 'milestone-orchestrator/references'
  [void][IO.Directory]::CreateDirectory($references)
  for ($i=0; $i -lt $names.Count; $i++) {
    [IO.File]::WriteAllBytes((Join-Path $references $names[$i]), [byte[]]@(0,255,$i,13,10,65))
  }
  [IO.File]::WriteAllText((Join-Path $references 'user-notes.md'), 'unknown user bytes')
  [IO.File]::WriteAllText((Join-Path $references 'defect-classes.md.bak-unknown'), 'unknown backup bytes')
  return $f
}
function Assert-Sources($Plan) {
  foreach ($entry in $Plan.Entries) {
    Assert-Archive ([Convert]::ToBase64String([IO.File]::ReadAllBytes($entry.Source)) -ceq
      [Convert]::ToBase64String($entry.Bytes)) "exact source bytes preserved: $($entry.Source)"
  }
}
function Assert-Refused([scriptblock]$Body, [string]$Reason) {
  $failure = ''
  try { & $Body | Out-Null } catch { $failure = $_.Exception.Message }
  Assert-Archive ($failure.Contains($Reason)) "expected refusal '$Reason', got '$failure'"
}
try {
  $f = New-Fixture
  $plan = Get-ControllerLegacyReferenceArchivePlan @f
  Assert-Archive ($plan.Entries.Count -eq 4) 'exactly four known legacy names are selected'
  Assert-Archive ($plan.ArchiveRoot -ceq (Join-Path $f.ContainerRoot '.orchestrator/archived-skill-references')) 'archive is canonical runtime state outside skills'
  Invoke-WithControllerLegacyReferenceArchive @f -Preview -Body { $script:previewRan = $true }
  Assert-Archive $script:previewRan 'preview retains ordinary installer body semantics'
  Assert-Archive (-not (Test-Path -LiteralPath $plan.ArchiveRoot)) 'preview never creates archive'
  Assert-Sources $plan
  Invoke-WithControllerInstallLock -Body {
    Invoke-WithControllerLegacyReferenceArchive @f -Body {
      foreach ($entry in $plan.Entries) { Assert-Archive (-not (Test-Path -LiteralPath $entry.Source)) 'legacy leaves discovery before release recording' }
      $script:installed = $true
    }
  }
  Assert-Archive $script:installed 'guarded migration reaches installer tail'
  $archiveSnapshot = @{}
  foreach ($entry in $plan.Entries) {
    $bytes = [IO.File]::ReadAllBytes($entry.Archive)
    Assert-Archive ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($entry.Bytes)) 'archive retains binary bytes, not decoded text'
    Assert-Archive ((Get-FileHash -LiteralPath $entry.Archive -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $entry.Hash) 'archive SHA256 matches source snapshot'
    $archiveSnapshot[$entry.Archive] = (Get-Item -LiteralPath $entry.Archive).LastWriteTimeUtc
  }
  Invoke-WithControllerLegacyReferenceArchive @f -Body {}
  foreach ($entry in $plan.Entries) {
    Assert-Archive ((Get-Item -LiteralPath $entry.Archive).LastWriteTimeUtc -eq $archiveSnapshot[$entry.Archive]) 'repeat install does not rewrite archives'
  }
  # Reintroduced identical legacy bytes reuse, rather than overwrite, archives.
  foreach ($entry in $plan.Entries) { [IO.File]::WriteAllBytes($entry.Source, $entry.Bytes) }
  Invoke-WithControllerLegacyReferenceArchive @f -Body {}
  foreach ($entry in $plan.Entries) {
    Assert-Archive ((Get-Item -LiteralPath $entry.Archive).LastWriteTimeUtc -eq $archiveSnapshot[$entry.Archive]) 'identical archive is verified and reused'
  }
  $references = Join-Path $f.DestinationRoot 'milestone-orchestrator/references'
  Assert-Archive ([IO.File]::ReadAllText((Join-Path $references 'user-notes.md')) -ceq 'unknown user bytes') 'unknown user file survives'
  Assert-Archive ([IO.File]::ReadAllText((Join-Path $references 'defect-classes.md.bak-unknown')) -ceq 'unknown backup bytes') 'no backup glob or history sweep'

  # Default host roots can have .claude/.codex junction ancestors. Trust the
  # configured roots, not arbitrary descendants below them.
  $f = New-Fixture
  $hostRoot = Join-Path (Split-Path $f.ContainerRoot -Parent) 'host'
  [void][IO.Directory]::CreateDirectory($hostRoot)
  $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
  $links = @()
  try {
    foreach ($pair in @(@('.claude', $f.DestinationRoot), @('.codex', $f.CodexSkillRoot))) {
      $targetParent = Split-Path $pair[1] -Parent
      $targetName = Split-Path $pair[1] -Leaf
      $link = Join-Path $hostRoot $pair[0]
      [void](New-Item -ItemType $linkType -Path $link -Target $targetParent)
      $links += $link
      if ($pair[0] -eq '.claude') { $f.DestinationRoot = Join-Path $link $targetName }
      else { $f.CodexSkillRoot = Join-Path $link $targetName }
    }
    $plan = Get-ControllerLegacyReferenceArchivePlan @f
    Assert-Archive ($plan.Entries.Count -eq 4) 'both configured roots accept trusted junction ancestors'
    Invoke-WithControllerLegacyReferenceArchive @f -Body {}
    foreach ($entry in $plan.Entries) {
      Assert-Archive (-not (Test-Path -LiteralPath $entry.Source) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($entry.Archive)) -ceq [Convert]::ToBase64String($entry.Bytes)) 'junction-ancestor migration retains exact bytes outside discovery'
    }
  } finally { foreach ($link in $links) { [IO.Directory]::Delete($link) } }

  $f = New-Fixture; $plan = Get-ControllerLegacyReferenceArchivePlan @f
  [void][IO.Directory]::CreateDirectory($plan.ArchiveRoot)
  [IO.File]::WriteAllText($plan.Entries[0].Archive, 'collision')
  Assert-Refused { Invoke-WithControllerLegacyReferenceArchive @f -Body { throw 'must not run' } } 'archive collision, no overwrite'
  Assert-Sources $plan
  Assert-Archive ([IO.File]::ReadAllText($plan.Entries[0].Archive) -ceq 'collision') 'collision bytes are never overwritten'

  $f = New-Fixture; $plan = Get-ControllerLegacyReferenceArchivePlan @f
  [IO.File]::Delete($plan.Entries[0].Source)
  [void][IO.Directory]::CreateDirectory($plan.Entries[0].Source)
  Assert-Refused { Get-ControllerLegacyReferenceArchivePlan @f } 'not an ordinary file'
  Assert-Archive (-not (Test-Path -LiteralPath $plan.ArchiveRoot)) 'malformed source refuses before archive writes'

  $f = New-Fixture; $plan = Get-ControllerLegacyReferenceArchivePlan @f
  [IO.File]::WriteAllText($plan.ArchiveRoot, 'not a directory')
  Assert-Refused { Get-ControllerLegacyReferenceArchivePlan @f } 'archive is not an ordinary directory'
  Assert-Sources $plan

  $f = New-Fixture; $plan = Get-ControllerLegacyReferenceArchivePlan @f
  Assert-Refused { Invoke-WithControllerLegacyReferenceArchive @f -Body { throw 'synthetic installer tail failure' } } 'synthetic installer tail failure'
  Assert-Sources $plan
  Assert-Archive (-not (Test-Path -LiteralPath $plan.ArchiveRoot)) 'tail failure rolls back new archives after exact source restoration'
  # Existing archive bytes belong to their earlier successful migration.
  [void][IO.Directory]::CreateDirectory($plan.ArchiveRoot)
  [IO.File]::WriteAllBytes($plan.Entries[0].Archive, $plan.Entries[0].Bytes)
  Assert-Refused { Invoke-WithControllerLegacyReferenceArchive @f -Body { throw 'second tail failure' } } 'second tail failure'
  Assert-Sources $plan
  Assert-Archive (Test-Path -LiteralPath $plan.Entries[0].Archive) 'rollback never removes a preexisting verified archive'

  $unknownArchive = Join-Path $plan.ArchiveRoot 'user-owned.txt'
  [IO.File]::WriteAllText($unknownArchive, 'unknown archive bytes')
  Assert-Refused { Invoke-WithControllerLegacyReferenceArchive @f -Body { throw 'third tail failure' } } 'third tail failure'
  Assert-Sources $plan
  Assert-Archive ([IO.File]::ReadAllText($unknownArchive) -ceq 'unknown archive bytes') 'rollback never removes unknown archive files'

  if ($IsWindows) {
    $f = New-Fixture; $plan = Get-ControllerLegacyReferenceArchivePlan @f
    $handle = [IO.File]::Open($plan.Entries[1].Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
      $refused = $false
      try { Invoke-WithControllerLegacyReferenceArchive @f -Body { throw 'tail must not run' } } catch { $refused = $true }
      Assert-Archive $refused 'locked second legacy file refuses partial deletion'
      Assert-Sources $plan
      Assert-Archive (-not (Test-Path -LiteralPath $plan.ArchiveRoot)) 'partial removal failure restores earlier sources and rolls back new archives'
    } finally { $handle.Dispose() }
  }

  $f = New-Fixture; $plan = Get-ControllerLegacyReferenceArchivePlan @f
  Assert-Refused {
    Invoke-WithControllerLegacyReferenceArchive @f -Body {
      [IO.File]::WriteAllText($plan.Entries[0].Source, 'concurrent user bytes')
      throw 'tail failure after source changed'
    }
  } 'rollback refused to overwrite changed source'
  Assert-Archive ([IO.File]::ReadAllText($plan.Entries[0].Source) -ceq 'concurrent user bytes') 'rollback refuses source overwrite'
  foreach ($entry in $plan.Entries) {
    Assert-Archive ([Convert]::ToBase64String([IO.File]::ReadAllBytes($entry.Archive)) -ceq [Convert]::ToBase64String($entry.Bytes)) 'conflicted rollback preserves every original in verified archive'
  }

  $f = New-Fixture
  $unsafe = $f.Clone(); $unsafe.ContainerRoot = 'relative-container'
  Assert-Refused { Get-ControllerLegacyReferenceArchivePlan @unsafe } 'path must be absolute and local'
  $unsafe = $f.Clone(); $unsafe.DestinationRoot = Join-Path $f.ContainerRoot '.orchestrator'
  Assert-Refused { Get-ControllerLegacyReferenceArchivePlan @unsafe } 'overlaps a skill-discovery root'
  $unsafe = $f.Clone(); $unsafe.ContainerRoot = Join-Path (Split-Path $f.ContainerRoot -Parent) 'skills/container'
  [void][IO.Directory]::CreateDirectory((Join-Path $unsafe.ContainerRoot '.orchestrator'))
  Assert-Refused { Get-ControllerLegacyReferenceArchivePlan @unsafe } 'skill-discovery ancestor'

  foreach ($surface in @('source-parent','archive-root','archive-parent','source-file')) {
    $f = New-Fixture; $plan = Get-ControllerLegacyReferenceArchivePlan @f
    $target = Join-Path (Split-Path $f.ContainerRoot -Parent) 'outside-link-target'
    [void][IO.Directory]::CreateDirectory($target)
    [IO.File]::WriteAllText((Join-Path $target 'sentinel'), 'outside bytes')
    if ($surface -eq 'source-parent') {
      $path = Join-Path $f.DestinationRoot 'milestone-orchestrator/references'
      # The fixture-owned ordinary directory is empty before replacement.
      foreach ($file in Get-ChildItem -LiteralPath $path -File) { [IO.File]::Delete($file.FullName) }
      [IO.Directory]::Delete($path)
    } elseif ($surface -eq 'archive-parent') {
      $path = Join-Path $f.ContainerRoot '.orchestrator'
      [IO.Directory]::Delete($path)
    } elseif ($surface -eq 'source-file') {
      $path = $plan.Entries[0].Source
      [IO.File]::Delete($path)
    } else { $path = $plan.ArchiveRoot }
    $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    [void](New-Item -ItemType $linkType -Path $path -Target $target)
    Assert-Refused { Get-ControllerLegacyReferenceArchivePlan @f } 'reparse point'
    Assert-Archive ([IO.File]::ReadAllText((Join-Path $target 'sentinel')) -ceq 'outside bytes') 'reparse refusal does not touch target'
    [IO.Directory]::Delete($path)
  }
  # The hook is inside the existing install lock, after copy verification and
  # before the release record. Tests never invoke a live installer or skill root.
  $installer = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-controller-skills.ps1'))
  $hook = $installer.IndexOf('  Invoke-WithControllerLegacyReferenceArchive -ContainerRoot')
  Assert-Archive ($hook -gt $installer.IndexOf('foreach ($file in $installPlan) {') -and
    $hook -lt $installer.IndexOf("'record installed release'")) 'tag installer commits migration between copy verification and release recording'
  Assert-Archive ($installer.Contains('$legacyReferences = Get-ControllerLegacyReferenceArchivePlan')) 'tag installer preflights legacy paths before any writes'
  Write-Output "PASS exact legacy reference archive checks=$script:checks; binary/hash preservation, idempotence, unknown files, path/reparse refusal and rollback; isolated fixtures only"
} finally {
  $resolved = [IO.Path]::GetFullPath($sandbox)
  $prefix = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'artifacts')).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
  if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe archive test cleanup' }
  if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
