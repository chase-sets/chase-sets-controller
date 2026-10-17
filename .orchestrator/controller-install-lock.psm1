Set-StrictMode -Version Latest

function Get-ControllerInstallMutexName {
  [CmdletBinding()]
  param()
  "Global\ChaseSetsControllerInstall"
}

function Invoke-WithControllerInstallLock {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][scriptblock]$Body,
    [timespan]$Timeout = ([timespan]::FromSeconds(30))
  )
  if ($Timeout -le [timespan]::Zero -or $Timeout -gt [timespan]::FromMinutes(5)) {
    throw "controller install lock refused: timeout is outside the closed bound"
  }
  $mutex = [Threading.Mutex]::new($false, (Get-ControllerInstallMutexName))
  $owned = $false
  try {
    try { $owned = $mutex.WaitOne($Timeout) }
    catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { throw "controller install lock refused: exclusive writer lock timed out" }
    & $Body
  } finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
  }
}

function Get-ControllerSkillInstallInventory {
  [CmdletBinding()]
  param()
  @(
    [pscustomobject][ordered]@{ source = "model-routing/SKILL.md"; destination = "model-routing/SKILL.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "model-routing/capability-matrix.json"; destination = "model-routing/capability-matrix.json"; preserveGenerated = $true; transportText = $false },
    [pscustomobject][ordered]@{ source = "model-routing/references/capability-recalibration.md"; destination = "model-routing/references/capability-recalibration.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "model-routing/references/experiments.md"; destination = "model-routing/references/experiments.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "model-routing/agents/openai.yaml"; destination = "model-routing/agents/openai.yaml"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/SKILL.md"; destination = "milestone-orchestrator/SKILL.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/rule-provenance-v2.24.md"; destination = "milestone-orchestrator/references/rule-provenance-v2.24.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/references/controller-defect-classes.md"; destination = "milestone-orchestrator/references/controller-defect-classes.md"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/scripts/query-ledgers.ps1"; destination = "milestone-orchestrator/scripts/query-ledgers.ps1"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/scripts/query-ledgers.test.ps1"; destination = "milestone-orchestrator/scripts/query-ledgers.test.ps1"; preserveGenerated = $false; transportText = $true },
    [pscustomobject][ordered]@{ source = "milestone-orchestrator/agents/openai.yaml"; destination = "milestone-orchestrator/agents/openai.yaml"; preserveGenerated = $false; transportText = $true }
  )
}

function Get-ControllerTransportNormalizedBytes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$Bytes,
    [Parameter(Mandatory)][bool]$TransportText
  )
  if (-not $TransportText) { return ,([byte[]]$Bytes.Clone()) }
  $utf8 = [Text.UTF8Encoding]::new($false, $true)
  $text = $utf8.GetString($Bytes)
  # Git-blob LF and a Windows checkout's CRLF are the only equivalent
  # transport forms. A lone CR remains content and therefore stays stale.
  $normalized = $text.Replace("`r`n", "`n")
  return ,([byte[]]$utf8.GetBytes($normalized))
}

function Merge-ControllerGeneratedMatrixBytes {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][byte[]]$CandidateBytes,
    [Parameter(Mandatory)][byte[]]$LiveBytes
  )
  $utf8 = [Text.UTF8Encoding]::new($false, $true)
  $src = ($utf8.GetString($CandidateBytes) | ConvertFrom-Json -DateKind String -ErrorAction Stop)
  $live = ($utf8.GetString($LiveBytes) | ConvertFrom-Json -DateKind String -ErrorAction Stop)

  # A configuration is identified by its exact model and effort; its literal id
  # is a derived key that a release may rename (model-routing v4.13 renamed all
  # twenty). Joining live to candidate by literal id alone made that rename an
  # empty join, so the live generated blocks were silently dropped and live's
  # old-id stamp was installed beside new-id configs. Index live by both.
  function Get-ConfigurationKey($Config) {
    $model = if ($Config.PSObject.Properties["model"]) { ([string]$Config.model).Trim().ToLowerInvariant() } else { "" }
    $effort = if ($Config.PSObject.Properties["effort"]) { ([string]$Config.effort).Trim().ToLowerInvariant() } else { "" }
    if (-not $model -or -not $effort) { return $null }
    return "$model/$effort"
  }
  $liveById = @{}
  $liveByKey = @{}
  foreach ($config in @($live.configs)) {
    if ($config.id) { $liveById[[string]$config.id] = $config }
    $key = Get-ConfigurationKey $config
    # Two live configs with one model+effort can arise only by hand-editing;
    # first wins, never silently last, so the join stays deterministic.
    if ($key -and -not $liveByKey.ContainsKey($key)) { $liveByKey[$key] = $config }
  }

  # Generated content transfers only within one generated schema. Across a
  # schema change (a stamp carrying a different `generatedSchema`, or none) the
  # candidate's freshly regenerated blocks and stamp win, because the live
  # blocks were produced by a script whose keying the candidate no longer
  # shares; the next refresh rebuilds them. The `adjudicated` snapshot is a
  # human baseline keyed to the configuration itself and transfers regardless.
  function Get-GeneratedSchema($Matrix) {
    if ($Matrix.PSObject.Properties["measuredAt"] -and $Matrix.measuredAt -and $Matrix.measuredAt.PSObject.Properties["generatedSchema"]) {
      return [string]$Matrix.measuredAt.generatedSchema
    }
    return ""
  }
  $sameSchema = (Get-GeneratedSchema $src) -ceq (Get-GeneratedSchema $live)

  $mergedIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($config in @($src.configs)) { if ($config.id) { [void]$mergedIds.Add([string]$config.id) } }
  # A live stamp that names configurations absent from the merged matrix (its
  # `configsWithoutEffortEvidence`) would be an orphaned stamp; keep the
  # candidate's instead.
  $liveStampOrphaned = $false
  if ($live.PSObject.Properties["measuredAt"] -and $live.measuredAt -and $live.measuredAt.PSObject.Properties["configsWithoutEffortEvidence"]) {
    foreach ($named in @($live.measuredAt.configsWithoutEffortEvidence)) {
      if ($named -and -not $mergedIds.Contains([string]$named)) { $liveStampOrphaned = $true; break }
    }
  }
  if ($live.PSObject.Properties["measuredAt"] -and $sameSchema -and -not $liveStampOrphaned) {
    if ($src.PSObject.Properties["measuredAt"]) { $src.measuredAt = $live.measuredAt }
    else { $src | Add-Member -NotePropertyName measuredAt -NotePropertyValue $live.measuredAt }
  }

  foreach ($config in @($src.configs)) {
    $liveConfig = $null
    if ($config.id -and $liveById.ContainsKey([string]$config.id)) { $liveConfig = $liveById[[string]$config.id] }
    else {
      $key = Get-ConfigurationKey $config
      if ($key -and $liveByKey.ContainsKey($key)) { $liveConfig = $liveByKey[$key] }
    }
    if ($null -eq $liveConfig) { continue }
    $carried = if ($sameSchema) { @("measured", "adjudicated") } else { @("adjudicated") }
    foreach ($generated in $carried) {
      if (-not $liveConfig.PSObject.Properties[$generated]) { continue }
      if ($config.PSObject.Properties[$generated]) { $config.$generated = $liveConfig.$generated }
      else { $config | Add-Member -NotePropertyName $generated -NotePropertyValue $liveConfig.$generated }
    }
  }
  $json = ($src | ConvertTo-Json -Depth 30) + [Environment]::NewLine
  [Text.UTF8Encoding]::new($false).GetBytes($json)
}

Export-ModuleMember -Function @(
  "Get-ControllerInstallMutexName",
  "Invoke-WithControllerInstallLock",
  "Get-ControllerSkillInstallInventory",
  "Get-ControllerTransportNormalizedBytes",
  "Merge-ControllerGeneratedMatrixBytes"
)
