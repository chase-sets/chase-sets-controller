$ErrorActionPreference = "Stop"

function Get-DispatchCanonicalRoot([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd("\", "/")
}

function Get-DispatchCanonicalExistingPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($PSVersionTable.PSEdition -ceq "Core") {
      # ResolveLinkTarget follows a worktree junction/symlink to its final
      # target. Regular paths use FullName, which expands 8.3 spelling and
      # restores the on-disk casing without paying a redundant link probe.
      $isLink = ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq
        [IO.FileAttributes]::ReparsePoint
      $target = if ($isLink) { $item.ResolveLinkTarget($true) } else { $null }
      $resolved = if ($null -ne $target) { $target.FullName } else { $item.FullName }
    } else {
      # Windows PowerShell 5.1 lacks FileSystemInfo.ResolveLinkTarget.
      $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    }
    return [IO.Path]::GetFullPath($resolved).TrimEnd("\", "/")
  } catch {
    return $null
  }
}

function Test-DispatchSamePath([string]$Left, [string]$Right) {
  try {
    return [string]::Equals(
      [IO.Path]::GetFullPath($Left).TrimEnd("\", "/"),
      [IO.Path]::GetFullPath($Right).TrimEnd("\", "/"),
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function Test-DispatchSameCanonicalPath([string]$Left, [string]$Right) {
  if ([string]::IsNullOrWhiteSpace($Left) -or
      [string]::IsNullOrWhiteSpace($Right)) {
    return $false
  }
  try {
    return [string]::Equals(
      (Get-DispatchCanonicalRoot $Left),
      (Get-DispatchCanonicalRoot $Right),
      [StringComparison]::OrdinalIgnoreCase
    )
  } catch {
    return $false
  }
}

function Get-LaneDiagnosticSeverityTable {
  $table = [Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::Ordinal
  )
  $table.Add("ownership-enumeration-failed", "blocking")
  $table.Add("ownership-record-invalid", "blocking")
  $table.Add("process-identity-probe-failed", "blocking")
  $table.Add("worktree-identity-probe-failed", "blocking")
  $table.Add("worktree-identity-mismatch", "blocking")
  $table.Add("worktree-outside-container", "blocking")
  $table.Add("worktree-outside-product-repository", "advisory")
  $table.Add("legacy-live-ownership", "blocking")
  $table.Add("duplicate-live-ownership", "blocking")
  $table.Add("malformed-live-lane-name", "blocking")
  $table.Add("ownership-record-cap-truncated", "blocking")
  $table.Add("ownership-deadline-truncated", "blocking")
  $table.Add("dispatch-owner-exited", "advisory")
  $table.Add("terminal-transcript-live-process", "blocking")
  $table.Add("transcript-state-unknown", "blocking")
  $table.Add("duplicate-live-transcript", "blocking")
  return $table
}

function Get-LaneDiagnosticSeverity([string]$Code) {
  $table = Get-LaneDiagnosticSeverityTable
  if (-not [string]::IsNullOrWhiteSpace($Code) -and $table.ContainsKey($Code)) {
    return [string]$table[$Code]
  }
  # A new or case-variant code cannot silently authorize capacity.
  return "blocking"
}

function Get-LaneHealthStatus([object[]]$Diagnostics) {
  foreach ($diagnostic in @($Diagnostics)) {
    if ((Get-LaneDiagnosticSeverity ([string]$diagnostic.code)) -ceq "blocking") {
      return "partial"
    }
  }
  return "ok"
}

function Get-DispatchBlockingDiagnostics($Ownership) {
  return (@($Ownership.health.diagnostics | Where-Object {
    (Get-LaneDiagnosticSeverity ([string]$_.code)) -ceq 'blocking'
  } | ForEach-Object { "$($_.code):$($_.lane)" }) -join ',')
}

# The projection proves only membership of the one canonical platform repository,
# never process capabilities, ownership transfer, or vacancy for other consumers.
function Invoke-ProductCensusGit([string]$Checkout, [string[]]$Arguments, $Budget) {
  if ($Budget.watch.ElapsedMilliseconds -ge $Budget.deadline) { throw 'git-deadline' }
  foreach ($name in [Environment]::GetEnvironmentVariables().Keys) {
    if ([string]$name -match '^(GIT_DIR|GIT_COMMON_DIR|GIT_CONFIG_.*)$') { throw 'git-environment' }
  }
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = 'git'; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
  foreach ($arg in @('--no-optional-locks','-C',$Checkout) + $Arguments) { [void]$start.ArgumentList.Add($arg) }
  $process = [Diagnostics.Process]::Start($start)
  try {
    # ReadBlockAsync stops at EOF or the fixed bound. Excess output cannot grow
    # memory or become proof; a blocked pipe is covered by the same deadline.
    $stdout = [char[]]::new(65537); $stderr = [char[]]::new(65537)
    $outRead = $process.StandardOutput.ReadBlockAsync($stdout,0,$stdout.Length)
    $errRead = $process.StandardError.ReadBlockAsync($stderr,0,$stderr.Length)
    $remaining = [Math]::Max(0, $Budget.deadline - $Budget.watch.ElapsedMilliseconds)
    if (-not $process.WaitForExit([int]$remaining)) { throw 'git-deadline' }
    $outCount = $outRead.GetAwaiter().GetResult(); $errCount = $errRead.GetAwaiter().GetResult()
    if ($outCount -eq $stdout.Length -or $errCount -eq $stderr.Length) { throw 'git-output-bound' }
    if ($Budget.watch.ElapsedMilliseconds -ge $Budget.deadline) { throw 'git-deadline' }
    return [pscustomobject]@{ exitCode=$process.ExitCode; text=[string]::new($stdout,0,$outCount).TrimEnd("`r","`n") }
  } finally {
    if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    $process.Dispose()
  }
}

function Resolve-ProductCensusGitPath([string]$Checkout, [string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'git-path' }
  if (-not [IO.Path]::IsPathFullyQualified($Path)) { $Path = Join-Path $Checkout $Path }
  $resolved = Get-DispatchCanonicalExistingPath $Path
  if (-not $resolved) { throw 'git-path' }
  return $resolved
}

function Get-ProductCensusRepository([string]$Checkout, $Budget) {
  $result = Invoke-ProductCensusGit $Checkout @('rev-parse','--show-toplevel','--git-common-dir','HEAD') $Budget
  $lines = @($result.text -split '\r?\n')
  if ($result.exitCode -ne 0 -or $lines.Count -ne 3 -or $lines[2] -cnotmatch '^[a-f0-9]{40}$') { throw 'git-identity' }
  return [pscustomobject]@{
    topLevel=(Resolve-ProductCensusGitPath $Checkout $lines[0])
    commonDir=(Resolve-ProductCensusGitPath $Checkout $lines[1]); head=$lines[2]
  }
}

function Assert-ProductCensusEndpoints([string]$Checkout, $Budget) {
  $result = Invoke-ProductCensusGit $Checkout @('remote') $Budget
  if ($result.exitCode -ne 0 -or -not $result.text) { throw 'remote-enumeration' }
  $remotes = @($result.text -split '\r?\n')
  if ($remotes -cnotcontains 'origin') { throw 'origin-missing' }
  foreach ($remote in $remotes) {
    if ($remote -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') { throw 'remote-name' }
    foreach ($direction in @('fetch','push')) {
      $arguments = @('remote','get-url','--all')
      if ($direction -ceq 'push') { $arguments += '--push' }
      $result = Invoke-ProductCensusGit $Checkout ($arguments + $remote) $Budget
      if ($result.exitCode -ne 0 -or -not $result.text) { throw 'endpoint-unreadable' }
      foreach ($url in @($result.text -split '\r?\n')) {
        if ($url -notmatch '\A(?:https://github\.com/|git@github\.com:)todd-skelton/orchestration-platform(?:\.git)?\z') { throw 'platform-endpoint' }
      }
    }
  }
  $config = Invoke-ProductCensusGit $Checkout @('config','--get-regexp','^(branch\..*\.(remote|pushremote)|remote\.pushdefault)$') $Budget
  if ($config.exitCode -eq 1 -and $config.text -ceq '') { return }
  if ($config.exitCode -ne 0 -or -not $config.text) { throw 'branch-remote-unreadable' }
  foreach ($line in @($config.text -split '\r?\n')) {
    if ($line -notmatch '\A(?:branch\..*\.(?:remote|pushremote)|remote\.pushdefault) ([^\r\n]+)\z' -or
        $remotes -cnotcontains $Matches[1]) { throw 'branch-remote' }
  }
}

function Test-ProductCensusPlatformSeat([string]$Worktree, $Record, [string]$ContainerRoot, $Budget, $Anchors) {
  $clause = 'seat-identity'
  try {
    $seat = Get-ProductCensusRepository $Worktree $Budget
    if (-not (Test-DispatchSameCanonicalPath $seat.topLevel $Worktree)) { throw 'seat-toplevel' }
    $branch = Invoke-ProductCensusGit $Worktree @('branch','--show-current') $Budget
    if ($branch.exitCode -ne 0 -or @($branch.text -split '\r?\n').Count -ne 1) { throw 'seat-branch' }
    if ($Record.identityMode -ceq 'immutable-head' -and ($branch.text -cne '' -or $seat.head -cne $Record.head)) { throw 'record-git-mismatch' }
    if (-not $Anchors.ContainsKey('checked')) {
      $Anchors.checked = $true
      try {
        $anchorPath = Join-Path (Split-Path -Parent $ContainerRoot) 'orchestration-platform'
        $anchor = Get-ProductCensusRepository $anchorPath $Budget
        if (-not (Test-DispatchSameCanonicalPath $anchor.topLevel (Get-DispatchCanonicalExistingPath $anchorPath))) { throw 'anchor-toplevel' }
        $product = if ($Anchors.ContainsKey('product')) { $Anchors.product } else { Get-ProductCensusRepository (Join-Path $ContainerRoot 'main') $Budget }
        $meta = Get-ProductCensusRepository $ContainerRoot $Budget
        $Anchors.anchor = $anchor; $Anchors.product = $product; $Anchors.meta = $meta
        Assert-ProductCensusEndpoints $anchorPath $Budget
      } catch { $Anchors.failure = $_.Exception.Message }
    }
    if ($Anchors.ContainsKey('failure')) { throw $Anchors.failure }
    $clause = 'platform-common-dir'
    if (-not (Test-DispatchSameCanonicalPath $seat.commonDir $Anchors.anchor.commonDir)) { throw 'platform-common-dir' }
    if (Test-DispatchSameCanonicalPath $seat.commonDir $Anchors.product.commonDir) { throw 'product-common-dir' }
    if (Test-DispatchSameCanonicalPath $seat.commonDir $Anchors.meta.commonDir) { throw 'container-meta-common-dir' }
    $clause = 'seat-endpoints'
    Assert-ProductCensusEndpoints $Worktree $Budget
    return [pscustomobject]@{ proven=$true; reason=$null }
  } catch {
    # Only closed clause names leave this boundary, never native error text,
    # endpoints, environment values, or credentials.
    $reason = $_.Exception.Message
    if ($reason -cnotin @('git-deadline','git-environment','git-output-bound','git-path','git-identity',
      'seat-toplevel','seat-branch','record-git-mismatch','anchor-toplevel','platform-common-dir',
      'product-common-dir','container-meta-common-dir','remote-enumeration','origin-missing','remote-name',
      'endpoint-unreadable','platform-endpoint','branch-remote-unreadable','branch-remote')) { $reason = $clause }
    return [pscustomobject]@{ proven=$false; reason=$reason }
  }
}

function Test-DispatchUtcIdentity([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}

function Test-DispatchUtcRoundTripIdentity([object]$Value) {
  if ($Value -isnot [string] -or
      [string]::IsNullOrWhiteSpace([string]$Value) -or
      [string]$Value -cnotmatch "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}Z$") {
    return $false
  }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParseExact(
    [string]$Value,
    "o",
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::RoundtripKind,
    [ref]$parsed
  )
}

function Test-DispatchJsonInteger([object]$Value, [int]$Minimum = [int]::MinValue) {
  if ($Value -isnot [int] -and $Value -isnot [long]) { return $false }
  try {
    $converted = [long]$Value
    return $converted -ge $Minimum -and $converted -le [int]::MaxValue
  } catch {
    return $false
  }
}

function Get-DispatchProcessStartIdentity([int]$ProcessId) {
  try {
    return (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString("o")
  } catch {
    return $null
  }
}

function Get-DispatchProcessIdentityState([int]$ProcessId, [string]$StartIdentity) {
  if ($ProcessId -le 0 -or -not (Test-DispatchUtcIdentity $StartIdentity)) { return "ambiguous" }
  $process = @(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
  if ($process.Count -eq 0) { return "dead" }
  if ($process.Count -ne 1) { return "ambiguous" }
  try {
    $expected = [DateTimeOffset]::Parse($StartIdentity).ToUniversalTime().Ticks
    $actual = $process[0].StartTime.ToUniversalTime().Ticks
    return $(if ($actual -eq $expected) { "live" } else { "dead" })
  } catch {
    return "ambiguous"
  }
}

function Test-DispatchFullyQualifiedPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  try {
    return [IO.Path]::IsPathFullyQualified($Path)
  } catch {
    # Windows PowerShell 5.1 runs on .NET Framework, which predates
    # IsPathFullyQualified. Reject drive-relative paths such as C:lane.
    return [IO.Path]::IsPathRooted($Path) -and
      ($Path -match "^[A-Za-z]:[\\/]" -or $Path -match "^[\\/]{2}")
  }
}

function ConvertFrom-DispatchOwnershipJson(
  [string]$Json,
  [bool]$DateKindSupported = (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")
) {
  if ($DateKindSupported) {
    return $Json | ConvertFrom-Json -DateKind String -ErrorAction Stop
  }
  if ($PSVersionTable.PSEdition -ceq "Desktop") {
    # Windows PowerShell 5.1's JavaScriptSerializer leaves ISO identity values
    # as strings. PowerShell Core before -DateKind does not: it coerces them to
    # DateTime and destroys the exact process-start identity. Fail closed there.
    return $Json | ConvertFrom-Json -ErrorAction Stop
  }
  throw "dispatch ownership JSON parsing requires ConvertFrom-Json -DateKind String on PowerShell Core"
}

function Get-DispatchOwnershipPropertyNames([int]$SchemaVersion) {
  if ($SchemaVersion -eq 5) { return @(Get-DispatchOwnershipPropertyNames 4) + @('interruptedIntegration') }
  $base = @(
    "schemaVersion",
    "launchId",
    "laneRole",
    "promptPath",
    "reviewIsolationRoot",
    "launcherPid",
    "launcherStartIdentity",
    "recordedAt",
    "state",
    "childPid",
    "childStartIdentity"
  )
  if ($SchemaVersion -eq 2) { return $base }
  if ($SchemaVersion -eq 3) {
    return @($base) + @(
      "worktree",
      "lane",
      "identityMode",
      "branch",
      "head"
    )
  }
  if ($SchemaVersion -eq 4) {
    return @($base) + @(
      "worktree",
      "lane",
      "identityMode",
      "branch",
      "head",
      "label",
      "transcriptPath"
    )
  }
  return @()
}

function Test-DispatchRoutingProvenance($Record) {
  $names = @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
  $actual = @($Record.PSObject.Properties.Name)
  $present = @($names | Where-Object { $_ -in $actual })
  if ($present.Count -eq 0) { return $true }
  if ($present.Count -ne $names.Count) { return $false }
  return (Test-DispatchJsonInteger $Record.policyGeneration 1) -and
    $Record.registryAuthorityDigest -is [string] -and
    $Record.registryAuthorityDigest -cmatch '^[a-zA-Z0-9._:-]{1,128}$' -and
    $Record.family -is [string] -and $Record.family -cmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -and
    $Record.slot -is [string] -and $Record.slot -cmatch '^(explicit|(codex|claude)\.(primary|fallback))$' -and
    $Record.usedLastKnownGood -is [bool]
}

function Get-DispatchRoutingLedgerKeys([string]$Schema) {
  $keys = @('ts','kind','dispatchRoutingSchema','attemptId','label','lane','laneRole','transcript','harness','model','effort','row','placement','worktree','branch','head')
  if ($Schema -ceq 'watchdog-dispatch-routing/v1') { return $keys }
  if ($Schema -cin @('watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3')) {
    $keys += @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
    if ($Schema -ceq 'watchdog-dispatch-routing/v3') {
      $keys += @('capacityForecastStatus','capacityDecisionDigest','capacityFlip','capacityShadowFlip','capacityFlipSkip')
    }
    return $keys
  }
  throw 'ROUTING_EVIDENCE_INVALID: unknown ledger schema'
}

function Test-DispatchRoutingLedgerEvidence($Row) {
  if ($Row.dispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v1') { return $true }
  if ($Row.dispatchRoutingSchema -ceq 'watchdog-dispatch-routing/v3') {
    $keys=@(Get-DispatchRoutingLedgerKeys $Row.dispatchRoutingSchema)
    if (@($Row.PSObject.Properties).Count -ne $keys.Count -or
        @($keys|Where-Object{$_ -cnotin $Row.PSObject.Properties.Name}).Count -or
        -not (Test-DispatchCapacityEvidence $Row)) { return $false }
  }
  return $Row.dispatchRoutingSchema -cin @('watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3') -and
    (Test-DispatchJsonInteger $Row.policyGeneration 1) -and
    $Row.registryAuthorityDigest -is [string] -and $Row.registryAuthorityDigest -cmatch '^[a-zA-Z0-9._:-]{1,128}$' -and
    $Row.family -is [string] -and $Row.family -cmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -and
    $Row.slot -is [string] -and $Row.slot -cmatch '^(explicit|(codex|claude)\.(primary|fallback))$' -and
    $Row.usedLastKnownGood -is [bool]
}

function Test-DispatchCapacityEvidence($Record) {
  $fields=@('capacityForecastStatus','capacityDecisionDigest','capacityFlip','capacityShadowFlip','capacityFlipSkip')
  if (@($fields | Where-Object {$_ -cnotin $Record.PSObject.Properties.Name}).Count) { return $false }
  $status=$Record.capacityForecastStatus
  if ($status -isnot [string] -or $status -cnotin @('not-evaluated','absent','malformed','stale','unknown','shadow','in-force')) { return $false }
  if ($status -cnotin @('shadow','in-force')) {
    return $null -eq $Record.capacityDecisionDigest -and $null -eq $Record.capacityFlip -and
      $null -eq $Record.capacityShadowFlip -and $null -eq $Record.capacityFlipSkip
  }
  if ($Record.capacityDecisionDigest -isnot [string] -or $Record.capacityDecisionDigest -cnotmatch '^[a-f0-9]{16}$') { return $false }
  if ($null -ne $Record.capacityFlipSkip) {
    if ($Record.capacityFlipSkip -isnot [string] -or $Record.capacityFlipSkip -cnotin @('SLOT_NOT_ADMITTED','REVIEWER_HISTORY_UNKNOWN','REVIEWER_INDEPENDENCE') -or
        $null -ne $Record.capacityFlip -or $null -ne $Record.capacityShadowFlip) { return $false }
  }
  if (($status -ceq 'shadow' -and $null -ne $Record.capacityFlip) -or
      ($status -ceq 'in-force' -and $null -ne $Record.capacityShadowFlip)) { return $false }
  $flip=if($status -ceq 'shadow'){$Record.capacityShadowFlip}else{$Record.capacityFlip}
  if ($null -eq $flip) { return $true }
  $keys=@('row','toward','steps','from','to')
  if ($flip -isnot [pscustomobject] -or @($flip.PSObject.Properties).Count -ne $keys.Count -or
      @($keys | Where-Object {$_ -cnotin $flip.PSObject.Properties.Name}).Count -or
      -not (Test-DispatchJsonInteger $flip.row 1) -or $flip.row -gt 15 -or
      -not (Test-DispatchJsonInteger $flip.steps 1) -or $flip.steps -gt 4 -or
      $flip.toward -isnot [string] -or $flip.toward -cnotin @('codex','claude') -or [string]$flip.row -cne [string]$Record.row) { return $false }
  foreach($side in @('from','to')) {
    $route=$flip.$side;$keys=@('harness','family','effort','slot')
    if($side -ceq 'to'){$keys+= 'placement'}
    if($route -isnot [pscustomobject] -or @($route.PSObject.Properties).Count -ne $keys.Count -or
        @($keys | Where-Object {$_ -cnotin $route.PSObject.Properties.Name}).Count){return $false}
    foreach($key in $keys){if($route.$key -isnot [string]){return $false}}
    if($route.harness -cnotin @('codex','claude') -or $route.family -cnotmatch '^[a-z0-9][a-z0-9._-]{0,63}$' -or
        $route.effort -cnotin @('low','medium','high','xhigh','max') -or
        $route.slot -cnotmatch '^(explicit|(codex|claude)\.(primary|fallback))$' -or
        ($route.slot -cne 'explicit' -and -not $route.slot.StartsWith("$($route.harness).",[StringComparison]::Ordinal))){return $false}
  }
  if($flip.to.placement -cnotmatch '^(measured|provisional|override-[A-Za-z0-9._-]+)$' -or
      $flip.to.slot -ceq 'explicit' -or $flip.to.harness -cne $flip.toward -or $flip.from.harness -ceq $flip.toward){return $false}
  $order=if($flip.toward -ceq 'claude'){@(13,10,4,5)}else{@(3,13,10,4)}
  if($flip.row -notin @($order | Select-Object -First $flip.steps)){return $false}
  $effective=if($status -ceq 'shadow'){$flip.from}else{$flip.to}
  foreach($key in @('harness','family','effort','slot')){if($effective.$key -cne $Record.$key){return $false}}
  if($status -ceq 'in-force' -and $flip.to.placement -cne $Record.placement){return $false}
  return $true
}

function ConvertFrom-DispatchClosedJson([string]$Json) {
  try {
    $document = [Text.Json.JsonDocument]::Parse($Json)
    function UniqueMembers($Element) {
      if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
          if (-not $seen.Add($property.Name)) { throw 'duplicate closed JSON member' }
          UniqueMembers $property.Value
        }
      } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($value in $Element.EnumerateArray()) { UniqueMembers $value }
      }
    }
    try { UniqueMembers $document.RootElement } finally { $document.Dispose() }
    return ConvertFrom-DispatchOwnershipJson $Json
  } catch { return $null }
}

function Write-DispatchOwnershipRecord([string]$RecordPath, $Record, [switch]$CreateNew) {
  $temporaryPath = "$RecordPath.$([guid]::NewGuid().ToString('N')).tmp"
  $backupPath = $null
  try {
    [IO.File]::WriteAllText(
      $temporaryPath,
      ($Record | ConvertTo-Json -Depth 4 -Compress),
      [Text.UTF8Encoding]::new($false)
    )
    if ($CreateNew) {
      [IO.File]::Move($temporaryPath, $RecordPath)
    } else {
      if ($PSVersionTable.PSEdition -eq "Desktop") {
        # .NET Framework lacks File.Move(source, destination, overwrite).
        # Replace is atomic and the ownership destination already exists.
        $backupPath = "$RecordPath.$([guid]::NewGuid().ToString('N')).bak"
        [IO.File]::Replace($temporaryPath, $RecordPath, $backupPath)
      } else {
        [IO.File]::Move($temporaryPath, $RecordPath, $true)
      }
    }
  } finally {
    Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    if ($backupPath) {
      Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Get-ValidatedDispatchOwnershipRecord(
  [string]$RecordPath,
  [string]$RuntimeRoot,
  [string]$TempRoot,
  [int]$MaxRecordBytes = 65536,
  [Nullable[bool]]$DateKindSupported = $null
) {
  try {
    $recordFile = Get-Item -LiteralPath $RecordPath -Force -ErrorAction Stop
    if ($MaxRecordBytes -le 0 -or $recordFile.Length -le 0 -or $recordFile.Length -gt $MaxRecordBytes) {
      return $null
    }
    $json = [IO.File]::ReadAllText($RecordPath, [Text.Encoding]::UTF8)
    $record = if ($null -eq $DateKindSupported) {
      ConvertFrom-DispatchOwnershipJson $json
    } else {
      ConvertFrom-DispatchOwnershipJson $json -DateKindSupported ([bool]$DateKindSupported)
    }
    if ($null -eq $record) { return $null }

    $schemaVersion = 0
    if (-not [int]::TryParse([string]$record.schemaVersion, [ref]$schemaVersion)) { return $null }
    if ($schemaVersion -eq 5) { $record = ConvertFrom-DispatchClosedJson $json; if ($null -eq $record) { return $null } }
    $requiredProperties = @(Get-DispatchOwnershipPropertyNames $schemaVersion)
    if ($requiredProperties.Count -eq 0) { return $null }
    $actualProperties = @($record.PSObject.Properties.Name)
    $provenanceNames = @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
    $hasProvenance = @($provenanceNames | Where-Object { $_ -in $actualProperties }).Count -gt 0
    if ($hasProvenance) { $requiredProperties += $provenanceNames }
    if ($actualProperties.Count -ne $requiredProperties.Count) { return $null }
    foreach ($name in $requiredProperties) {
      if ($actualProperties -cnotcontains $name) { return $null }
    }
    if (-not (Test-DispatchRoutingProvenance $record)) { return $null }

    $launchId = [string]$record.launchId
    if ($launchId -cnotmatch "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$") { return $null }

    $runtimeResolved = Get-DispatchCanonicalRoot $RuntimeRoot
    $tempResolved = Get-DispatchCanonicalRoot $TempRoot
    $expectedRecordPath = Join-Path $runtimeResolved "dispatch-launch-$launchId.json"
    $expectedPromptPath = Join-Path $runtimeResolved "dispatch-heavy-verifier-$launchId.prompt.txt"
    if (-not (Test-DispatchSamePath $RecordPath $expectedRecordPath)) { return $null }
    if (-not (Test-DispatchFullyQualifiedPath ([string]$record.promptPath)) -or
        -not (Test-DispatchSamePath ([string]$record.promptPath) $expectedPromptPath)) { return $null }

    # review and planning are both provider-credential-isolated and own an
    # isolation root named for their role; implementation owns none.
    if ($record.laneRole -ceq "review" -or $record.laneRole -ceq "planning") {
      $expectedIsolationRoot = Join-Path $tempResolved "chase-sets-$([string]$record.laneRole)-$launchId"
      if (-not (Test-DispatchFullyQualifiedPath ([string]$record.reviewIsolationRoot)) -or
          -not (Test-DispatchSamePath ([string]$record.reviewIsolationRoot) $expectedIsolationRoot)) { return $null }
    } elseif ($record.laneRole -ceq "implementation") {
      if ($null -ne $record.reviewIsolationRoot) { return $null }
    } else {
      return $null
    }

    $launcherPid = 0
    if (-not [int]::TryParse([string]$record.launcherPid, [ref]$launcherPid) -or $launcherPid -le 0) { return $null }
    if (-not (Test-DispatchUtcIdentity ([string]$record.launcherStartIdentity)) -or
        -not (Test-DispatchUtcIdentity ([string]$record.recordedAt))) { return $null }

    if ($record.state -ceq "launching") {
      if ($null -ne $record.childPid -or -not [string]::IsNullOrWhiteSpace([string]$record.childStartIdentity)) { return $null }
    } elseif ($record.state -ceq "started") {
      $childPid = 0
      if (-not [int]::TryParse([string]$record.childPid, [ref]$childPid) -or $childPid -le 0 -or
          -not (Test-DispatchUtcIdentity ([string]$record.childStartIdentity))) { return $null }
    } else {
      return $null
    }

    if ($schemaVersion -in @(4, 5)) {
      # Schema v4 is a closed launch contract. Values that merely parse as the
      # required type are rejected, and the exact property-set check above
      # rejects all unknown fields.
      if (-not (Test-DispatchJsonInteger $record.schemaVersion 4) -or
          [long]$record.schemaVersion -notin @(4, 5) -or
          $record.launchId -isnot [string] -or
          $record.laneRole -isnot [string] -or
          $record.promptPath -isnot [string] -or
          ($null -ne $record.reviewIsolationRoot -and
            $record.reviewIsolationRoot -isnot [string]) -or
          -not (Test-DispatchJsonInteger $record.launcherPid 1) -or
          -not (Test-DispatchUtcRoundTripIdentity $record.launcherStartIdentity) -or
          -not (Test-DispatchUtcRoundTripIdentity $record.recordedAt) -or
          $record.state -isnot [string] -or
          ($null -ne $record.childPid -and
            -not (Test-DispatchJsonInteger $record.childPid 1)) -or
          ($null -ne $record.childStartIdentity -and
            -not (Test-DispatchUtcRoundTripIdentity $record.childStartIdentity)) -or
          $record.worktree -isnot [string] -or
          $record.lane -isnot [string] -or
          $record.identityMode -isnot [string] -or
          ($null -ne $record.branch -and $record.branch -isnot [string]) -or
          $record.head -isnot [string] -or
          $record.label -isnot [string] -or
          $record.transcriptPath -isnot [string]) {
        return $null
      }
    }

    if ($schemaVersion -eq 5) {
      if ($record.laneRole -cne 'implementation' -or $record.identityMode -cne 'branch' -or $record.interruptedIntegration -isnot [string]) { return $null }
      $binding = ConvertFrom-DispatchClosedJson $record.interruptedIntegration
      if (-not (Test-DispatchInterruptedBindingShape $binding) -or $record.branch -cne $binding.obligation.branch -or
          -not (Test-DispatchSamePath $record.worktree $binding.obligation.worktree) -or $record.head -cne $binding.state.stoppedHead) { return $null }
    }
    if ($schemaVersion -in @(3, 4, 5)) {
      $worktree = [string]$record.worktree
      $lane = [string]$record.lane
      if (-not (Test-DispatchFullyQualifiedPath $worktree) -or
          $lane -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$") {
        return $null
      }
      $canonicalWorktree = Get-DispatchCanonicalRoot $worktree
      if (-not [string]::Equals(
          (Split-Path -Leaf $canonicalWorktree),
          $lane,
          [StringComparison]::Ordinal
        )) {
        return $null
      }

      $head = [string]$record.head
      if ($head -cnotmatch "^[a-f0-9]{40}$") { return $null }
      if ($record.identityMode -ceq "branch") {
        $branch = [string]$record.branch
        if ([string]::IsNullOrWhiteSpace($branch) -or
            $branch.Length -gt 512 -or
            $branch.Trim() -cne $branch) {
          return $null
        }
      } elseif ($record.identityMode -ceq "immutable-head") {
        if ($null -ne $record.branch) { return $null }
      } else {
        return $null
      }

      if ($schemaVersion -in @(4, 5)) {
        $label = [string]$record.label
        $transcriptPath = [string]$record.transcriptPath
        if ($label -cnotmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$" -or
            -not (Test-DispatchFullyQualifiedPath $transcriptPath) -or
            -not (Test-DispatchSamePath (Split-Path -Parent $transcriptPath) $runtimeResolved) -or
            -not [string]::Equals(
              (Split-Path -Leaf $transcriptPath),
              "$label.jsonl",
              [StringComparison]::Ordinal
            )) {
          return $null
        }
      }
    }

    return $record
  } catch {
    return $null
  }
}

function Test-DispatchOwnershipRecordExact($Left, $Right) {
  if ($null -eq $Left -or $null -eq $Right) { return $false }
  try {
    $leftRecord = ConvertFrom-DispatchOwnershipJson (
      $Left | ConvertTo-Json -Depth 4 -Compress
    )
    $rightRecord = ConvertFrom-DispatchOwnershipJson (
      $Right | ConvertTo-Json -Depth 4 -Compress
    )
  } catch {
    return $false
  }
  $leftSchema = 0
  $rightSchema = 0
  if (-not [int]::TryParse([string]$leftRecord.schemaVersion, [ref]$leftSchema) -or
      -not [int]::TryParse([string]$rightRecord.schemaVersion, [ref]$rightSchema) -or
      $leftSchema -ne $rightSchema) {
    return $false
  }
  $names = @(Get-DispatchOwnershipPropertyNames $leftSchema)
  if ($names.Count -eq 0) {
    return $false
  }
  $routingNames=@('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
  $leftRouting=@($routingNames|Where-Object{$_ -in @($leftRecord.PSObject.Properties.Name)})
  $rightRouting=@($routingNames|Where-Object{$_ -in @($rightRecord.PSObject.Properties.Name)})
  if ($leftRouting.Count -ne $rightRouting.Count -or ($leftRouting.Count -gt 0 -and $leftRouting.Count -ne $routingNames.Count)) { return $false }
  if ($leftRouting.Count -eq $routingNames.Count) { $names += $routingNames }
  if (@($leftRecord.PSObject.Properties.Name).Count -ne $names.Count -or @($rightRecord.PSObject.Properties.Name).Count -ne $names.Count) { return $false }
  foreach ($name in $names) {
    $leftProperty = $leftRecord.PSObject.Properties[$name]
    $rightProperty = $rightRecord.PSObject.Properties[$name]
    if ($null -eq $leftProperty -or $null -eq $rightProperty) { return $false }
    if ($null -eq $leftProperty.Value -or $null -eq $rightProperty.Value) {
      if ($null -ne $leftProperty.Value -or $null -ne $rightProperty.Value) { return $false }
    } elseif (-not [string]::Equals(
        [string]$leftProperty.Value,
        [string]$rightProperty.Value,
        [StringComparison]::Ordinal
      )) {
      return $false
    }
  }
  return $true
}

function Get-DispatchGitIdentity([string]$Worktree) {
  if (-not (Test-Path -LiteralPath $Worktree -PathType Container)) {
    return [pscustomobject]@{ status = "mismatch"; worktree = $null; branch = $null; head = $null }
  }
  try {
    $topLevel = @(& git -C $Worktree rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $topLevel.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace([string]$topLevel[0])) {
      return [pscustomobject]@{ status = "mismatch"; worktree = $null; branch = $null; head = $null }
    }
    $branchOutput = @(& git -C $Worktree branch --show-current 2>$null)
    if ($LASTEXITCODE -ne 0 -or $branchOutput.Count -gt 1) {
      return [pscustomobject]@{ status = "mismatch"; worktree = $null; branch = $null; head = $null }
    }
    $headOutput = @(& git -C $Worktree rev-parse --verify HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $headOutput.Count -ne 1) {
      return [pscustomobject]@{ status = "mismatch"; worktree = $null; branch = $null; head = $null }
    }
    $head = ([string]$headOutput[0]).Trim().ToLowerInvariant()
    if ($head -cnotmatch "^[a-f0-9]{40}$") {
      return [pscustomobject]@{ status = "mismatch"; worktree = $null; branch = $null; head = $null }
    }
    return [pscustomobject]@{
      status = "ok"
      worktree = Get-DispatchCanonicalRoot ([string]$topLevel[0])
      branch = $(if ($branchOutput.Count -eq 1) { ([string]$branchOutput[0]).Trim() } else { "" })
      head = $head
    }
  } catch {
    return [pscustomobject]@{ status = "failed"; worktree = $null; branch = $null; head = $null }
  }
}

# An attached branch and a branch undergoing native rebase are different Git
# states. This projection preserves the logical branch without claiming HEAD is
# attached. It is useful to *exclude* competing claimants, never to admit a
# dirty worktree. Admission separately authenticates the interrupted operation.
function Get-DispatchRebaseBranch([string]$Worktree, [string]$RequestedBranch) {
  $directory = @(& git --no-optional-locks -C $Worktree rev-parse --git-path rebase-merge 2>$null)
  if ($LASTEXITCODE -ne 0 -or $directory.Count -ne 1) { throw 'dispatch-ownership: native operation unknown' }
  $path = [string]$directory[0]
  if (-not [IO.Path]::IsPathFullyQualified($path)) { $path = Join-Path $Worktree $path }
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw 'dispatch-ownership: native operation unknown' }
  $headNamePath = Join-Path $path 'head-name'
  if (-not (Test-Path -LiteralPath $headNamePath -PathType Leaf)) { throw 'dispatch-ownership: native operation incomplete' }
  $headName = [IO.File]::ReadAllText($headNamePath).Trim()
  if ($headName -cnotmatch '^refs/heads/(.+)$') { throw 'dispatch-ownership: native operation malformed' }
  & git --no-optional-locks -C $Worktree check-ref-format $headName 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'dispatch-ownership: native operation malformed' }
  $logicalBranch = $headName.Substring('refs/heads/'.Length)
  # A known other branch cannot occupy the requested branch. This is only a
  # scope projection: matching and unscoped ownership callers keep strict proof.
  if ($RequestedBranch -and $logicalBranch -cne $RequestedBranch) { return $logicalBranch }
  $values = @{}
  foreach ($name in @('orig-head','onto')) {
    $file = Join-Path $path $name
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'dispatch-ownership: native operation incomplete' }
    $values[$name] = [IO.File]::ReadAllText($file).Trim()
  }
  if ($values['orig-head'] -cnotmatch '^[a-f0-9]{40}$' -or $values.onto -cnotmatch '^[a-f0-9]{40}$') {
    throw 'dispatch-ownership: native operation malformed'
  }
  $tip = @(& git --no-optional-locks -C $Worktree rev-parse --verify $headName 2>$null)
  if ($LASTEXITCODE -ne 0 -or $tip.Count -ne 1 -or [string]$tip[0] -cne $values['orig-head']) {
    throw 'dispatch-ownership: native original branch moved'
  }
  return $logicalBranch
}

function Test-DispatchInterruptedBindingShape($Binding) {
  function HasKeys($Value,[string[]]$Keys) {
    if ($null -eq $Value -or $Value -isnot [pscustomobject]) { return $false }
    $actual = @($Value.PSObject.Properties.Name)
    return $actual.Count -eq $Keys.Count -and @($Keys | Where-Object { $_ -cnotin $actual }).Count -eq 0
  }
  if (-not (HasKeys $Binding @('schemaVersion','obligation','sources','state')) -or $Binding.schemaVersion -cne 'interrupted-canonical-integration/v1') { return $false }
  $o=$Binding.obligation;$s=$Binding.sources;$n=$Binding.state
  if (-not (HasKeys $o @('schemaVersion','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane')) -or
      -not (HasKeys $s @('requestIdentity','priorLabel','priorLaunchId','ackSha256','watchdogSha256','promptSha256','transcriptSha256','routingIdentity','checkpointSha256')) -or
      -not (HasKeys $n @('branch','originalHead','onto','stoppedHead','stoppedCommit','oldBase','metadataSha256','indexSha256','stagesSha256','dirtySha256','stagedSha256','unstagedSha256'))) { return $false }
  foreach ($key in @('requestIdentity','ackSha256','watchdogSha256','promptSha256','transcriptSha256','routingIdentity')) {
    if ($s.$key -isnot [string] -or $s.$key -cnotmatch '^[a-f0-9]{64}$') { return $false }
  }
  if ($null -ne $s.checkpointSha256 -and ($s.checkpointSha256 -isnot [string] -or $s.checkpointSha256 -cnotmatch '^[a-f0-9]{64}$')) { return $false }
  foreach ($key in @('metadataSha256','indexSha256','stagesSha256','dirtySha256','stagedSha256','unstagedSha256')) {
    if ($n.$key -isnot [string] -or $n.$key -cnotmatch '^[a-f0-9]{64}$') { return $false }
  }
  foreach ($key in @('originalHead','onto','stoppedHead','stoppedCommit','oldBase')) {
    if ($n.$key -isnot [string] -or $n.$key -cnotmatch '^[a-f0-9]{40}$') { return $false }
  }
  foreach ($key in @('landedHead','targetHead','newBase')) {
    if ($o.$key -isnot [string] -or $o.$key -cnotmatch '^[a-f0-9]{40}$') { return $false }
  }
  return $o.schemaVersion -ceq 'landed-integration-owed/v1' -and (Test-DispatchJsonInteger $o.pr 1) -and (Test-DispatchJsonInteger $o.landedPr 1) -and
    $o.branch -is [string] -and $o.branch -cmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -and $o.worktree -is [string] -and (Test-DispatchFullyQualifiedPath $o.worktree) -and
    $o.integrationLane -is [string] -and $o.integrationLane -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -and
    $s.priorLabel -is [string] -and $s.priorLabel -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -and $s.priorLaunchId -is [string] -and $s.priorLaunchId -cmatch '^[a-f0-9-]{36}$' -and
    $n.branch -ceq $o.branch -and $n.originalHead -ceq $o.targetHead -and $n.onto -ceq $o.newBase
}

function New-DispatchAttemptState(
  [ValidateSet("active", "terminal", "unknown")][string]$State,
  [string]$Reason,
  [int]$CompleteRows,
  [int]$MalformedRows,
  [long]$WindowStartByte
) {
  return [pscustomobject][ordered]@{
    state = $State
    reason = $Reason
    completeRows = $CompleteRows
    malformedRows = $MalformedRows
    windowStartByte = $WindowStartByte
  }
}

function Get-DispatchAttemptState(
  [string]$TranscriptPath,
  [int]$MaxTailBytes = 1048576,
  [int]$MaxCanonicalRowBytes = 2103802,
  [Parameter(DontShow)][scriptblock]$StreamOpenedObserver
) {
  $maxMalformedSampleRows = 64
  if ($MaxTailBytes -le 0 -or $MaxCanonicalRowBytes -le 0) {
    return New-DispatchAttemptState "unknown" "transcript-unreadable" 0 0 0
  }
  if ([string]::IsNullOrWhiteSpace($TranscriptPath)) {
    return New-DispatchAttemptState "unknown" "transcript-missing" 0 0 0
  }

  $stream = $null
  try {
    $stream = [IO.File]::Open(
      $TranscriptPath,
      [IO.FileMode]::Open,
      [IO.FileAccess]::Read,
      [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    )
    # Sample length exactly once. Bytes appended afterward belong to the next
    # snapshot, so growth cannot change this snapshot halfway through its read.
    $length = [long]$stream.Length
    if ($StreamOpenedObserver) {
      & $StreamOpenedObserver $stream $length
    }
    if ($length -eq 0) {
      return New-DispatchAttemptState "active" "transcript-empty" 0 0 0
    }

    $readLength = [int][Math]::Min($length, [long]$MaxTailBytes)
    $windowStart = $length - $readLength
    [void]$stream.Seek($windowStart, [IO.SeekOrigin]::Begin)
    $bytes = [byte[]]::new($readLength)
    $offset = 0
    while ($offset -lt $readLength) {
      $read = $stream.Read($bytes, $offset, $readLength - $offset)
      if ($read -le 0) { break }
      $offset += $read
    }
    if ($offset -ne $readLength) {
      return New-DispatchAttemptState "unknown" "transcript-unreadable" 0 0 $windowStart
    }

    # A tail seek can land inside one UTF-8 scalar. Advance over at most three
    # continuation bytes, then decode non-throwing and let JSON validity decide.
    $alignment = 0
    if ($windowStart -gt 0) {
      while ($alignment -lt [Math]::Min(3, $bytes.Length) -and
          (($bytes[$alignment] -band 0xC0) -eq 0x80)) {
        $alignment += 1
      }
    }
    $alignedStart = $windowStart + $alignment
    $text = [Text.UTF8Encoding]::new($false, $false).GetString(
      $bytes,
      $alignment,
      $bytes.Length - $alignment
    )

    if ($windowStart -gt 0) {
      $firstNewline = $text.IndexOf("`n", [StringComparison]::Ordinal)
      if ($firstNewline -lt 0) {
        return New-DispatchAttemptState "unknown" `
          "window-holds-no-complete-row" 0 0 $alignedStart
      }
      $text = $text.Substring($firstNewline + 1)
    }

    # Walk complete rows from the end without materializing or parsing every
    # JSON row in the one-MiB tail. The final complete nonblank row is always
    # authoritative; malformed-density is computed over a fixed suffix sample.
    # MaxCanonicalRowBytes remains an independent per-row bound and is reachable
    # when a caller intentionally supplies a MaxTailBytes value large enough to
    # hold a larger complete row.
    $completeEnd = $text.LastIndexOf([char]10)
    if ($completeEnd -lt 0) {
      return New-DispatchAttemptState "active" "transcript-no-complete-row" `
        0 0 $alignedStart
    }
    $rows = [Collections.Generic.List[object]]::new()
    $malformedRows = 0
    $cursor = $completeEnd - 1
    while ($cursor -ge 0 -and $rows.Count -lt $MaxMalformedSampleRows) {
      $previousNewline = $text.LastIndexOf([char]10, $cursor)
      $segmentStart = $previousNewline + 1
      $segmentLength = ($cursor + 1) - $segmentStart
      if ($segmentLength -gt 0 -and
          $text[$segmentStart + $segmentLength - 1] -eq [char]13) {
        $segmentLength -= 1
      }
      $segment = $text.Substring($segmentStart, $segmentLength)
      $cursor = $previousNewline - 1
      if ([string]::IsNullOrWhiteSpace($segment)) { continue }
      if ([Text.Encoding]::UTF8.GetByteCount($segment) -gt $MaxCanonicalRowBytes) {
        $rows.Add([pscustomobject]@{ valid = $false; value = $null })
        $malformedRows += 1
        continue
      }
      try {
        $parsed = $segment | ConvertFrom-Json -ErrorAction Stop
        $rows.Add([pscustomobject]@{ valid = $true; value = $parsed })
      } catch {
        $rows.Add([pscustomobject]@{ valid = $false; value = $null })
        $malformedRows += 1
      }
    }

    $completeRows = $rows.Count
    if ($completeRows -eq 0) {
      return New-DispatchAttemptState "active" "transcript-no-complete-row" `
        0 0 $alignedStart
    }
    # Rows were sampled in reverse order, so index zero is the final complete
    # nonblank row even when an incomplete row follows the last newline.
    $last = $rows[0]
    if (-not $last.valid) {
      return New-DispatchAttemptState "unknown" "final-row-malformed" `
        $completeRows $malformedRows $alignedStart
    }
    if ($malformedRows -gt 3 -and
        $malformedRows -gt (0.25 * $completeRows)) {
      return New-DispatchAttemptState "unknown" "malformed-density" `
        $completeRows $malformedRows $alignedStart
    }

    # Attempt identity is the schema-v4 launchId + label + transcriptPath
    # binding. Within that one attempt, only the last complete row is selected;
    # earlier resume/retry terminal-shaped rows collapse as non-authority.
    $typeProperties = @($last.value.PSObject.Properties | Where-Object {
        $_.Name -ceq "type"
      })
    $terminal = $typeProperties.Count -eq 1 -and
      $typeProperties[0].Value -is [string] -and
      ([string]$typeProperties[0].Value -ceq "result" -or
        [string]$typeProperties[0].Value -ceq "turn.completed")
    if ($terminal) {
      return New-DispatchAttemptState "terminal" "final-row-terminal" `
        $completeRows $malformedRows $alignedStart
    }
    return New-DispatchAttemptState "active" "final-row-active" `
      $completeRows $malformedRows $alignedStart
  } catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] {
    return New-DispatchAttemptState "unknown" "transcript-missing" 0 0 0
  } catch {
    return New-DispatchAttemptState "unknown" "transcript-unreadable" 0 0 0
  } finally {
    if ($null -ne $stream) { $stream.Dispose() }
  }
}

function Initialize-DispatchOwnershipRecordProbe(
  [string]$TempRoot,
  [bool]$DateKindSupported,
  [Parameter(DontShow)][scriptblock]$TranscriptProbeObserver
) {
  $tempResolved = Get-DispatchCanonicalRoot $TempRoot
  $warmRoot = Join-Path $tempResolved (
    "dispatch-ownership-warmup-" + [guid]::NewGuid().ToString("N")
  )
  $launchId = "00000000-0000-0000-0000-000000000000"
  $recordPath = Join-Path $warmRoot "dispatch-launch-$launchId.json"
  try {
    [void][IO.Directory]::CreateDirectory($warmRoot)
    $record = [ordered]@{
      schemaVersion = 4
      launchId = $launchId
      laneRole = "implementation"
      promptPath = Join-Path $warmRoot "dispatch-heavy-verifier-$launchId.prompt.txt"
      reviewIsolationRoot = $null
      launcherPid = 1
      launcherStartIdentity = "2000-01-01T00:00:00.0000000Z"
      recordedAt = "2000-01-01T00:00:00.0000000Z"
      state = "launching"
      childPid = $null
      childStartIdentity = $null
      worktree = Join-Path $tempResolved "lane-00"
      lane = "lane-00"
      identityMode = "branch"
      branch = "warmup/record-probe"
      head = "0" * 40
      label = "dispatch-ownership-warmup"
      transcriptPath = Join-Path $warmRoot "dispatch-ownership-warmup.jsonl"
    }
    [IO.File]::WriteAllText(
      $recordPath,
      ($record | ConvertTo-Json -Depth 4 -Compress),
      [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
      [string]$record.transcriptPath,
      "{`"type`":`"item.completed`"}`n",
      [Text.UTF8Encoding]::new($false)
    )
    $warmed = Get-ValidatedDispatchOwnershipRecord $recordPath $warmRoot $tempResolved `
      -DateKindSupported $DateKindSupported
    if ($null -eq $warmed) {
      throw "dispatch ownership record-probe warm-up failed validation"
    }
    $warmedAttempt = Get-DispatchAttemptState ([string]$record.transcriptPath)
    if ($warmedAttempt.state -cne "active" -or
        $warmedAttempt.reason -cne "final-row-active" -or
        $warmedAttempt.completeRows -ne 1 -or
        $warmedAttempt.malformedRows -ne 0) {
      throw "dispatch ownership transcript-probe warm-up failed validation"
    }
    if ($TranscriptProbeObserver) {
      & $TranscriptProbeObserver ([string]$record.transcriptPath) $warmedAttempt
    }
    # Sort-Object is part of the record path in the reducer and has a material
    # cold first-use cost on Windows PowerShell.
    [void]@($recordPath | Sort-Object)
  } finally {
    $warmResolved = Get-DispatchCanonicalRoot $warmRoot
    if ((Split-Path -Parent $warmResolved).TrimEnd("\", "/") -ne
        $tempResolved.TrimEnd("\", "/") -or
        (Split-Path -Leaf $warmResolved) -notlike "dispatch-ownership-warmup-*") {
      throw "refusing unsafe ownership warm-up cleanup target: $warmResolved"
    }
    if ([IO.Directory]::Exists($warmResolved)) {
      [IO.Directory]::Delete($warmResolved, $true)
    }
  }
}

function Get-LiveDispatchOwnership(
  [string]$RuntimeRoot,
  [string]$TempRoot,
  [string]$ContainerRoot,
  [int]$MaxRecords = 64,
  [int]$DeadlineMs = 5000,
  [switch]$ProductCensus,
  [scriptblock]$ProcessStateResolver = {
    param($ProcessId, $StartIdentity)
    Get-DispatchProcessIdentityState ([int]$ProcessId) ([string]$StartIdentity)
  },
  [scriptblock]$GitIdentityResolver = {
    param($Worktree)
    Get-DispatchGitIdentity ([string]$Worktree)
  },
  [scriptblock]$AttemptStateResolver = {
    param($TranscriptPath)
    Get-DispatchAttemptState ([string]$TranscriptPath)
  },
  [scriptblock]$CanonicalPathObserver,
  [scriptblock]$DateKindSupportResolver = {
    (Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")
  }
) {
  $counts = [ordered]@{
    candidates = 0
    examined = 0
    active = 0
    legacyLiveOwners = 0
    lingeringAttempts = 0
    inactive = 0
    rejected = 0
    probeFailures = 0
    truncated = 0
  }
  $diagnostics = @()
  $active = @()
  # Hoist every one-time initialization class before the deadline meter:
  # final-path support, container/runtime roots, DateKind feature detection,
  # and one throwaway read/parse validation of the cold record path.
  $containerResolved = Get-DispatchCanonicalExistingPath $ContainerRoot
  if ($CanonicalPathObserver) {
    & $CanonicalPathObserver $ContainerRoot $containerResolved
  }
  if ($null -eq $containerResolved) {
    throw "container root cannot be resolved to an existing canonical path"
  }
  $runtimeResolved = Get-DispatchCanonicalExistingPath $RuntimeRoot
  if ($CanonicalPathObserver) {
    & $CanonicalPathObserver $RuntimeRoot $runtimeResolved
  }
  if ($null -eq $runtimeResolved) {
    # Preserve the inherited enumeration-failure producer for a missing root.
    $runtimeResolved = Get-DispatchCanonicalRoot $RuntimeRoot
  }
  $dateKindSupported = [bool](& $DateKindSupportResolver)
  Initialize-DispatchOwnershipRecordProbe $TempRoot $dateKindSupported
  $candidatePaths = [Collections.Generic.List[string]]::new()

  try {
    $recordCapUnexamined = 0
    foreach ($path in [IO.Directory]::EnumerateFiles(
        $runtimeResolved,
        "dispatch-launch-*.json",
        [IO.SearchOption]::TopDirectoryOnly
      )) {
      if ($candidatePaths.Count -ge [Math]::Max(0, $MaxRecords)) {
        # The first excluded row proves at least one record was not examined;
        # do not turn an unbounded enumeration into a supposedly exact count.
        $recordCapUnexamined = 1
        break
      }
      $candidatePaths.Add($path)
    }
    $counts.candidates = $candidatePaths.Count
    if ($recordCapUnexamined -gt 0) {
      $counts.truncated += $recordCapUnexamined
      $diagnostics += [ordered]@{
        code = "ownership-record-cap-truncated"
        unexamined = $recordCapUnexamined
        unexaminedIsLowerBound = $true
      }
    }
  } catch {
    $counts.probeFailures += 1
    $diagnostics += [ordered]@{ code = "ownership-enumeration-failed" }
  }

  $orderedCandidatePaths = @($candidatePaths | Sort-Object)
  $seenWorktrees = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $seenTranscripts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $productAnchors = @{}
  $productBudget = @{ watch=$watch; deadline=$DeadlineMs }
  foreach ($recordPath in $orderedCandidatePaths) {
    if ($watch.ElapsedMilliseconds -ge $DeadlineMs) {
      $deadlineUnexamined = $orderedCandidatePaths.Count - $counts.examined
      $counts.truncated += $deadlineUnexamined
      $diagnostics += [ordered]@{
        code = "ownership-deadline-truncated"
        unexamined = $deadlineUnexamined
      }
      break
    }
    $counts.examined += 1
    $record = Get-ValidatedDispatchOwnershipRecord $recordPath $runtimeResolved $TempRoot `
      -DateKindSupported $dateKindSupported
    if ($null -eq $record) {
      $counts.rejected += 1
      $diagnostics += [ordered]@{ code = "ownership-record-invalid" }
      continue
    }

    $ownerProcessId = if ($record.state -ceq "started") { $record.childPid } else { $record.launcherPid }
    $startIdentity = if ($record.state -ceq "started") { $record.childStartIdentity } else { $record.launcherStartIdentity }
    try {
      $processState = & $ProcessStateResolver $ownerProcessId $startIdentity
    } catch {
      $processState = "failed"
    }
    if ($processState -eq "dead") {
      $counts.inactive += 1
      $diagnostics += [ordered]@{
        code = "dispatch-owner-exited"
        lane = $(if ($null -eq $record.lane) { $null } else { [string]$record.lane })
      }
      continue
    }
    if ($processState -ne "live") {
      $counts.probeFailures += 1
      $diagnostics += [ordered]@{ code = "process-identity-probe-failed"; lane = [string]$record.lane }
      continue
    }
    if ($record.schemaVersion -notin @(4, 5)) {
      $counts.legacyLiveOwners += 1
      $diagnostics += [ordered]@{
        code = "legacy-live-ownership"
        lane = $(if ($null -eq $record.lane) { $null } else { [string]$record.lane })
        schemaVersion = [int]$record.schemaVersion
      }
      continue
    }

    $worktree = Get-DispatchCanonicalRoot ([string]$record.worktree)
    $canonicalWorktree = Get-DispatchCanonicalExistingPath $worktree
    if ($CanonicalPathObserver) {
      & $CanonicalPathObserver $worktree $canonicalWorktree
    }
    if ($null -eq $canonicalWorktree) {
      if (Test-Path -LiteralPath $worktree) {
        $counts.probeFailures += 1
        $diagnostics += [ordered]@{ code = "worktree-identity-probe-failed"; lane = [string]$record.lane }
      } else {
        $counts.inactive += 1
        $diagnostics += [ordered]@{ code = "worktree-identity-mismatch"; lane = [string]$record.lane }
      }
      continue
    }
    $canonicalLane = Split-Path -Leaf $canonicalWorktree
    $recordLaneIsMalformed = [string]$record.lane -like "lane-*" -and
      [string]$record.lane -cnotmatch "^lane-[0-9]{2}$"
    $canonicalLaneIsMalformed = $canonicalLane -like "lane-*" -and
      $canonicalLane -cnotmatch "^lane-[0-9]{2}$"
    if ($recordLaneIsMalformed -or $canonicalLaneIsMalformed) {
      $counts.rejected += 1
      $diagnostics += [ordered]@{
        code = "malformed-live-lane-name"
        lane = $(if ($canonicalLaneIsMalformed) { $canonicalLane } else { [string]$record.lane })
      }
      continue
    }
    if (-not [string]::Equals(
        $canonicalLane,
        [string]$record.lane,
        [StringComparison]::Ordinal
      )) {
      $counts.rejected += 1
      $diagnostics += [ordered]@{ code = "ownership-record-invalid"; lane = [string]$record.lane }
      continue
    }
    $platformSeat = $false
    if (-not [string]::Equals(
        (Split-Path -Parent $canonicalWorktree),
        $containerResolved,
        [StringComparison]::OrdinalIgnoreCase
      )) {
      $proof = if ($ProductCensus) { Test-ProductCensusPlatformSeat $canonicalWorktree $record $containerResolved $productBudget $productAnchors } else { $null }
      if ($null -eq $proof -or -not $proof.proven) {
        $counts.inactive += 1
        $diagnostic = [ordered]@{ code = "worktree-outside-container"; lane = [string]$record.lane }
        if ($ProductCensus) { $diagnostic.reason = $proof.reason }
        $diagnostics += $diagnostic
        continue
      }
      $platformSeat = $true
    }
    if (-not $platformSeat) {
    try {
      $gitIdentity = & $GitIdentityResolver $canonicalWorktree
    } catch {
      $gitIdentity = [pscustomobject]@{ status = "failed" }
    }
    if ($null -eq $gitIdentity -or $gitIdentity.status -eq "failed") {
      $counts.probeFailures += 1
      $diagnostics += [ordered]@{ code = "worktree-identity-probe-failed"; lane = [string]$record.lane }
      continue
    }
    $gitHead = [string]$gitIdentity.head
    $gitMatches = $gitIdentity.status -eq "ok" -and
      $gitHead -cmatch "^[a-f0-9]{40}$" -and
      (Test-DispatchSameCanonicalPath ([string]$gitIdentity.worktree) $canonicalWorktree)
    if ($gitMatches -and $record.identityMode -ceq "branch") {
      # Launch branch/head are telemetry from before the child advances. Exact
      # process identity plus canonical worktree confinement remain identity
      # across branch creation, advancement, and transient detached HEAD.
      $gitMatches = $true
    } elseif ($gitMatches -and $record.identityMode -ceq "immutable-head") {
      $gitMatches = [string]::IsNullOrWhiteSpace([string]$gitIdentity.branch) -and
        ($gitHead -ceq [string]$record.head)
    }
    if (-not $gitMatches) {
      $counts.inactive += 1
      $diagnostics += [ordered]@{ code = "worktree-identity-mismatch"; lane = [string]$record.lane }
      continue
    }
    }
    if (-not $seenWorktrees.Add($canonicalWorktree)) {
      $counts.rejected += 1
      $diagnostics += [ordered]@{ code = "duplicate-live-ownership"; lane = [string]$record.lane }
      continue
    }

    $transcriptPath = Get-DispatchCanonicalRoot ([string]$record.transcriptPath)
    if (-not $seenTranscripts.Add($transcriptPath)) {
      $counts.rejected += 1
      $diagnostics += [ordered]@{
        code = "duplicate-live-transcript"
        lane = [string]$record.lane
      }
      continue
    }

    if ($platformSeat) {
      $counts.inactive += 1
      $diagnostics += [ordered]@{ code = "worktree-outside-product-repository"; lane = [string]$record.lane }
      continue
    }

    try {
      $attemptState = & $AttemptStateResolver ([string]$record.transcriptPath)
    } catch {
      $attemptState = $null
    }
    if ($null -eq $attemptState -or
        [string]$attemptState.state -notin @("active", "terminal", "unknown")) {
      $attemptState = New-DispatchAttemptState "unknown" `
        "transcript-unreadable" 0 0 0
    }
    if ([string]$attemptState.state -ceq "terminal") {
      $counts.lingeringAttempts += 1
      $diagnostics += [ordered]@{
        code = "terminal-transcript-live-process"
        lane = [string]$record.lane
      }
    } elseif ([string]$attemptState.state -ceq "unknown") {
      $counts.probeFailures += 1
      $diagnostics += [ordered]@{
        code = "transcript-state-unknown"
        lane = [string]$record.lane
        reason = [string]$attemptState.reason
      }
    }

    $logicalBranch = [string]$gitIdentity.branch
    if ($record.identityMode -ceq 'branch' -and [string]::IsNullOrWhiteSpace($logicalBranch)) {
      try { $logicalBranch = Get-DispatchRebaseBranch $canonicalWorktree }
      catch {
        $counts.probeFailures += 1
        $diagnostics += [ordered]@{ code = 'worktree-identity-probe-failed'; lane = [string]$record.lane }
      }
    }
    if ($record.schemaVersion -eq 5 -and $logicalBranch -cne $record.branch) {
      # Even an invalid/moving native state must exclude a second claimant for
      # the immutable resume branch. Blocking health prevents using this as
      # affirmative Git authority or claiming that HEAD is attached.
      $counts.probeFailures += 1
      $diagnostics += [ordered]@{ code = 'worktree-identity-probe-failed'; lane = [string]$record.lane }
      $logicalBranch = [string]$record.branch
    }
    $active += [ordered]@{
      launchId = [string]$record.launchId
      ownershipRecordPath = [IO.Path]::GetFullPath($recordPath)
      launcherPid = [long]$record.launcherPid
      launcherStartIdentity = [string]$record.launcherStartIdentity
      lane = [string]$record.lane
      laneRole = [string]$record.laneRole
      worktree = $canonicalWorktree
      branch = $(if ($record.identityMode -ceq "branch" -and
          -not [string]::IsNullOrWhiteSpace($logicalBranch)) {
        $logicalBranch
      } else { $null })
      head = $gitHead
      identityMode = [string]$record.identityMode
      policyGeneration = if($record.PSObject.Properties['policyGeneration']){[long]$record.policyGeneration}else{$null}
      registryAuthorityDigest = if($record.PSObject.Properties['registryAuthorityDigest']){[string]$record.registryAuthorityDigest}else{$null}
      family = if($record.PSObject.Properties['family']){[string]$record.family}else{$null}
      slot = if($record.PSObject.Properties['slot']){[string]$record.slot}else{$null}
      usedLastKnownGood = if($record.PSObject.Properties['usedLastKnownGood']){[bool]$record.usedLastKnownGood}else{$null}
    }
  }
  $counts.active = $active.Count
  return [pscustomobject][ordered]@{
    activeLanes = @($active | Sort-Object lane, head)
    health = [ordered]@{
      status = Get-LaneHealthStatus @($diagnostics)
      counts = $counts
      diagnostics = @($diagnostics)
    }
  }
}

function Test-DispatchResourceIsSafe([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $true }
  try {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return -not (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
  } catch {
    return $false
  }
}

function Remove-DispatchLaunchResources(
  [string]$RecordPath,
  $ExpectedRecord,
  [string]$RuntimeRoot,
  [string]$TempRoot
) {
  $current = Get-ValidatedDispatchOwnershipRecord $RecordPath $RuntimeRoot $TempRoot
  if (-not (Test-DispatchOwnershipRecordExact $current $ExpectedRecord)) { return $false }

  $promptPath = Join-Path (Get-DispatchCanonicalRoot $RuntimeRoot) "dispatch-heavy-verifier-$($current.launchId).prompt.txt"
  $isolationRoot = if ($current.laneRole -ceq "review") {
    Join-Path (Get-DispatchCanonicalRoot $TempRoot) "chase-sets-review-$($current.launchId)"
  } else {
    $null
  }
  if (-not (Test-DispatchResourceIsSafe $promptPath) -or
      ($isolationRoot -and -not (Test-DispatchResourceIsSafe $isolationRoot))) { return $false }

  Remove-Item -LiteralPath $promptPath -Force -ErrorAction SilentlyContinue
  if ($isolationRoot) {
    Remove-Item -LiteralPath $isolationRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ((Test-Path -LiteralPath $promptPath) -or ($isolationRoot -and (Test-Path -LiteralPath $isolationRoot))) {
    return $false
  }

  $afterCleanup = Get-ValidatedDispatchOwnershipRecord $RecordPath $RuntimeRoot $TempRoot
  if (-not (Test-DispatchOwnershipRecordExact $afterCleanup $ExpectedRecord)) { return $false }
  Remove-Item -LiteralPath $RecordPath -Force -ErrorAction SilentlyContinue
  return -not (Test-Path -LiteralPath $RecordPath)
}

function Test-DispatchPossiblePendingChild($Record) {
  try {
    $recordedAt = [DateTimeOffset]::Parse([string]$Record.recordedAt).ToUniversalTime()
    $candidates = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($Record.launcherPid)" -ErrorAction Stop)
    foreach ($candidate in $candidates) {
      try {
        $createdAt = if ($candidate.CreationDate -is [DateTime]) {
          ([DateTime]$candidate.CreationDate).ToUniversalTime()
        } else {
          [Management.ManagementDateTimeConverter]::ToDateTime([string]$candidate.CreationDate).ToUniversalTime()
        }
        if ($createdAt.Ticks -ge $recordedAt.Ticks) { return $true }
      } catch {
        return $null
      }
    }
    return $false
  } catch {
    return $null
  }
}

function Invoke-DispatchOwnershipScavenge(
  [string]$RuntimeRoot,
  [string]$TempRoot,
  [scriptblock]$ProcessStateResolver = {
    param($ProcessId, $StartIdentity)
    Get-DispatchProcessIdentityState ([int]$ProcessId) ([string]$StartIdentity)
  },
  [scriptblock]$PendingChildResolver = {
    param($Record)
    Test-DispatchPossiblePendingChild $Record
  },
  [Nullable[bool]]$DateKindSupported = $null
) {
  $result = [ordered]@{ scanned = 0; removed = 0; preserved = 0; rejected = 0 }
  foreach ($candidate in @(Get-ChildItem -LiteralPath $RuntimeRoot -File -Filter "dispatch-launch-*.json" -ErrorAction SilentlyContinue)) {
    $result.scanned++
    $record = if ($null -eq $DateKindSupported) {
      Get-ValidatedDispatchOwnershipRecord $candidate.FullName $RuntimeRoot $TempRoot
    } else {
      Get-ValidatedDispatchOwnershipRecord $candidate.FullName $RuntimeRoot $TempRoot `
        -DateKindSupported ([bool]$DateKindSupported)
    }
    if ($null -eq $record) {
      $result.rejected++
      # Rejection is a validation diagnostic, while preservation reports the
      # resource action. An unreadable record must never become a deletion key.
      $result.preserved++
      continue
    }

    $launcherState = & $ProcessStateResolver $record.launcherPid $record.launcherStartIdentity
    if ($launcherState -notin @("live", "dead", "ambiguous") -or $launcherState -ne "dead") {
      $result.preserved++
      continue
    }

    if ($record.state -ceq "launching") {
      $pendingChild = & $PendingChildResolver $record
      if ($pendingChild -ne $false) {
        $result.preserved++
        continue
      }
    } else {
      $childState = & $ProcessStateResolver $record.childPid $record.childStartIdentity
      if ($childState -notin @("live", "dead", "ambiguous") -or $childState -ne "dead") {
        $result.preserved++
        continue
      }
    }

    if (Remove-DispatchLaunchResources $candidate.FullName $record $RuntimeRoot $TempRoot) {
      $result.removed++
    } else {
      $result.preserved++
    }
  }
  return [pscustomobject]$result
}
