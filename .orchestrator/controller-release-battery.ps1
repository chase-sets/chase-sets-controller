[CmdletBinding()]
param(
  [string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot),

  [Parameter(Mandatory)]
  [string]$ExpectedControllerHead,

  # Installed baseline commit. When given, the battery runs the impact scope:
  # the smoke set, the changed tests, every test that reaches a changed file,
  # and the guard discriminators. No baseline, -Scope full, a change to this
  # battery, or a changed runtime file that no test reaches selects the full
  # battery.
  [string]$BaselineHead = "",

  [Parameter(DontShow)]
  [string]$SkillsRoot = (Join-Path $HOME '.claude/skills'),

  [ValidateSet("impact", "full")][string]$Scope = "impact",

  # Repair rounds bind their baseline to a governing BLOCK_FIXABLE receipt on
  # that ancestor head. Omit both fields for an initial candidate, whose
  # baseline remains the installed controller head.
  [ValidateRange(0, [int]::MaxValue)][int]$RepairIssue = 0,
  [string]$RepairHistoryPath = "",

  # Optional externally produced guard-evidence record for issue-6254.
  [string]$EvidenceReceiptPath = "",

  # Optional machine-readable battery result output.
  [string]$ResultPath = "",

  # Optional local prior or downloaded controller CI final.json. CI imports
  # authenticate the run, artifact ZIP digest and orphan source trailer against
  # GitHub (gh read access required), then execute only the missing/ineligible
  # and changed items. Import evidence is retained in this seat's artifacts.
  [string]$PriorResultPath = "",

  # stop (default): end at the first failure that is not PREEXISTING; the
  # remaining items are recorded as not run. all: run every item regardless.
  [ValidateSet("stop", "all")][string]$OnFailure = "stop",

  [switch]$ValidatePlanOnly,

  # Exact-owner continuation supplied only by invoke-heavy-verifier.ps1 after
  # it has acquired and published the controller-battery owner record.
  [Parameter(DontShow)]
  [switch]$AdmissionOwned
)

$ErrorActionPreference = "Stop"
# Committed canonical path declaration. Optional batteryHostSha256 literals in
# fixtures are diagnostic only: routine bundle updates never require a repin.
$batteryHostPath = 'C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
$controller = [IO.Path]::GetFullPath($ControllerRoot)
$runtime = Join-Path $controller ".orchestrator"

# Source-mutation seams used only in a copied battery by the omission suite.
# Reconciliation below never consults these switches.
$planInclusion = [ordered]@{
  "direct:fail-closed-guard-evidence" = $true
  "discriminator:issue-6254" = $true
}

function Stop-Battery([string]$Code) {
  throw "FAIL controller-release-battery: $Code"
}

function Test-SameBatteryPath([string]$Left, [string]$Right) {
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

# Fleet-load probe (#8102). Reports whether the platform heavy-verifier slot of
# this container (<container>/.orchestrator/verify-lock.d/owner.json) is held by
# a LIVE owner, using the heavy verifier's own liveness rule: the wrapper pid
# with its process start identity, or (schema 2..5, state started/attached) the
# child pid with its start identity. A stale or unreadable owner.json is never
# load. The battery never takes or waits on that slot.
function Test-BatteryProcessIdentityLive([object]$ProcessId, [object]$ProcessStartUtc) {
  if ($ProcessId -isnot [int] -and $ProcessId -isnot [long]) { return $false }
  if ([long]$ProcessId -lt 1 -or [long]$ProcessId -gt [int]::MaxValue) { return $false }
  if ($ProcessStartUtc -isnot [string] -or [string]::IsNullOrWhiteSpace($ProcessStartUtc)) { return $false }
  try {
    $expected = [DateTimeOffset]::Parse($ProcessStartUtc, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().Ticks
    $process = @(Get-Process -Id ([int]$ProcessId) -ErrorAction SilentlyContinue)
    if ($process.Count -ne 1) { return $false }
    return $process[0].StartTime.ToUniversalTime().Ticks -eq $expected
  } catch {
    return $false
  }
}

function Get-BatteryFleetLoad {
  $ownerPath = Join-Path (Split-Path -Parent $controller) ".orchestrator\verify-lock.d\owner.json"
  if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return "none" }
  try {
    $owner = Get-Content -LiteralPath $ownerPath -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String -ErrorAction Stop
  } catch {
    return "none"
  }
  if ($null -eq $owner) { return "none" }
  $wrapperLive = Test-BatteryProcessIdentityLive $owner.pid $owner.processStartUtc
  $childLive = $false
  if (-not $wrapperLive -and ($owner.schemaVersion -is [int] -or $owner.schemaVersion -is [long]) -and
      [long]$owner.schemaVersion -ge 2 -and [long]$owner.schemaVersion -le 5 -and
      ([string]$owner.state) -cin @("started", "attached")) {
    $childLive = Test-BatteryProcessIdentityLive $owner.childPid $owner.childProcessStartUtc
  }
  if (-not ($wrapperLive -or $childLive)) { return "none" }
  $identity = "lane=$($owner.lane);gate=$($owner.gate);lockId=$($owner.lockId);pid=$($owner.pid);started=$($owner.processStartUtc)"
  return ($identity -replace '\s', '_')
}

function Assert-BatteryAdmission {
  $token = [string]$env:CHASE_SETS_HEAVY_SLOT_ID
  if ($token -cnotmatch "^[a-f0-9]{32}$") { Stop-Battery "BATTERY_ADMISSION_TOKEN_INVALID" }
  $container = Split-Path -Parent $controller
  # The controller slot, never the platform verifier's (Todd ruling 2026-09-10).
  $lockPath = Join-Path $container ".orchestrator\controller-verify-lock.d"
  $ownerPath = Join-Path $lockPath "owner.json"
  if (-not (Test-Path -LiteralPath $lockPath -PathType Container) -or
      -not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
    Stop-Battery "BATTERY_ADMISSION_OWNER_INVALID"
  }
  $deadline = [DateTime]::UtcNow.AddSeconds(10)
  do {
    try {
      $entries = @(Get-ChildItem -LiteralPath $lockPath -Force -ErrorAction Stop)
      if ($entries.Count -eq 1 -and
          (Test-SameBatteryPath $entries[0].FullName $ownerPath) -and
          -not $entries[0].PSIsContainer -and
          (($entries[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne [IO.FileAttributes]::ReparsePoint)) {
        $owner = [IO.File]::ReadAllText($ownerPath, [Text.Encoding]::UTF8) |
          ConvertFrom-Json -DateKind String -ErrorAction Stop
        if ($owner.schemaVersion -eq 4 -and
            $owner.lockId -ceq $token -and
            $owner.gate -ceq "script-battery" -and
            $owner.state -ceq "started" -and
            $owner.identityMode -ceq "branch" -and
            (Test-SameBatteryPath ([string]$owner.worktree) $controller) -and
            $owner.head -ceq $ExpectedControllerHead -and
            $owner.branch -ceq (& git -C $controller branch --show-current 2>$null | Out-String).Trim() -and
            [int]$owner.childPid -eq $PID) {
          $self = Get-Process -Id $PID -ErrorAction Stop
          $wrapper = Get-Process -Id ([int]$owner.pid) -ErrorAction Stop
          $expectedSelf = [DateTimeOffset]::Parse([string]$owner.childProcessStartUtc).ToUniversalTime().Ticks
          $expectedWrapper = [DateTimeOffset]::Parse([string]$owner.processStartUtc).ToUniversalTime().Ticks
          if ($self.StartTime.ToUniversalTime().Ticks -eq $expectedSelf -and
              $wrapper.StartTime.ToUniversalTime().Ticks -eq $expectedWrapper) {
            return
          }
        }
      }
    } catch {}
    Start-Sleep -Milliseconds 25
  } while ([DateTime]::UtcNow -lt $deadline)
  Stop-Battery "BATTERY_ADMISSION_OWNER_INVALID"
}

function Quote-Command([string[]]$Arguments) {
  return @($Arguments | ForEach-Object {
      if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ }
    }) -join " "
}

function Get-BatteryHostIdentity {
  $identity = [ordered]@{
    expectedPath = 'unavailable'; actualPath = 'unavailable'; sha256 = 'unavailable'
    byteLength = 'unavailable'; ProductVersion = 'unavailable'; PSVersion = 'unavailable'
    PSHOME = 'unavailable'; bundleVersion = 'unavailable'
  }
  $diagnostics = [Collections.Generic.List[string]]::new()
  try {
    $source = (& git -C $controller show "${ExpectedControllerHead}:.orchestrator/controller-release-battery.ps1" 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0) { throw 'unreadable candidate blob' }
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw 'malformed candidate blob' }
    $declarations = @($ast.FindAll({ param($node)
      $node -is [Management.Automation.Language.AssignmentStatementAst] -and
      @($node.Left.FindAll({ param($variable)
        $variable -is [Management.Automation.Language.VariableExpressionAst] -and
        ($variable.VariablePath.UserPath -split ':')[-1] -ieq 'batteryHostPath'
      }, $true)).Count -gt 0
    }, $true))
    if ($declarations.Count -ne 1) { throw 'missing or duplicate path declaration' }
    $declaration = $declarations[0]
    if ($declaration.Parent -ne $ast.EndBlock -or
        $declaration.Left -isnot [Management.Automation.Language.VariableExpressionAst] -or
        $declaration.Left.VariablePath.UserPath -ine 'batteryHostPath' -or
        $declaration.Operator -ne 'Equals' -or
        $declaration.Right -isnot [Management.Automation.Language.CommandExpressionAst] -or
        $declaration.Right.Expression -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
        $declaration.Right.Expression.StringConstantType -notin @('SingleQuoted', 'DoubleQuoted')) {
      throw 'path declaration must be a top-level string literal'
    }
    $literal = $declaration.Right.Expression.Value
    if ([string]::IsNullOrWhiteSpace($literal) -or -not [IO.Path]::IsPathFullyQualified($literal) -or
        $literal.IndexOfAny([IO.Path]::GetInvalidPathChars()) -ge 0) { throw 'invalid absolute path' }
    $identity.expectedPath = [IO.Path]::GetFullPath($literal)
  } catch {
    $diagnostics.Add('BATTERY_HOST_PIN_INVALID')
  }

  # Observations are independent, best-effort and never admission predicates.
  try { $identity.actualPath = [IO.Path]::GetFullPath((Get-Process -Id $PID -ErrorAction Stop).Path) } catch {}
  try { $identity.sha256 = (Get-FileHash -LiteralPath $identity.actualPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() } catch {}
  try { $identity.byteLength = (Get-Item -LiteralPath $identity.actualPath -Force -ErrorAction Stop).Length } catch {}
  try {
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($identity.actualPath).ProductVersion
    if (-not [string]::IsNullOrWhiteSpace($version)) { $identity.ProductVersion = $version }
  } catch {}
  try { $identity.PSVersion = $PSVersionTable.PSVersion.ToString() } catch {}
  if (-not [string]::IsNullOrWhiteSpace($PSHOME)) { $identity.PSHOME = $PSHOME }
  try {
    $metadata = [IO.File]::ReadAllText('C:/Users/ToddS/.cache/codex-runtimes/codex-primary-runtime/runtime.json') | ConvertFrom-Json -ErrorAction Stop
    if ($metadata.bundleVersion -is [string] -and -not [string]::IsNullOrWhiteSpace($metadata.bundleVersion)) {
      $identity.bundleVersion = $metadata.bundleVersion
    }
  } catch {}

  if ($diagnostics.Count -eq 0) {
    try {
      $canonical = Get-Item -LiteralPath $identity.expectedPath -Force -ErrorAction Stop
      if ($canonical.PSIsContainer -or $canonical.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
        $diagnostics.Add('BATTERY_HOST_CANONICAL_INVALID')
      }
    } catch [Management.Automation.ItemNotFoundException] {
      $diagnostics.Add('BATTERY_HOST_CANONICAL_MISSING')
    } catch {
      $diagnostics.Add('BATTERY_HOST_CANONICAL_INVALID')
    }
    if (-not (Test-SameBatteryPath $identity.expectedPath $identity.actualPath)) {
      $diagnostics.Add('BATTERY_HOST_PATH_MISMATCH')
    }
  }
  $script:batteryHostLog = 'BATTERY_HOST_IDENTITY ' + (@($identity.Keys | ForEach-Object { "$_=$($identity[$_])" }) -join '; ')
  Write-Host $script:batteryHostLog
  if ($diagnostics.Count -gt 0) {
    Write-Host "BATTERY_HOST_REFUSED primary=$($diagnostics[0]) diagnostics=$($diagnostics -join ',') PIN=committed canonical path declaration"
    Write-Host ("canonicalCommand=& '" + $identity.expectedPath.Replace("'", "''") + "' -NoProfile -NonInteractive -File '" +
      (Join-Path $runtime 'controller-release-battery.ps1').Replace("'", "''") + "' -ControllerRoot '" +
      $controller.Replace("'", "''") + "' -ExpectedControllerHead $ExpectedControllerHead")
    Stop-Battery $diagnostics[0]
  }
  return [pscustomobject]$identity
}

function New-PlanItem(
  [string]$Identity,
  [string]$Path,
  [string[]]$Arguments
) {
  return [pscustomobject][ordered]@{
    identity = $Identity
    path = $Path
    executable = (Get-Process -Id $PID -ErrorAction Stop).Path
    arguments = $Arguments
    command = ((Get-Process -Id $PID -ErrorAction Stop).Path) + " " + (Quote-Command $Arguments)
  }
}

# Impact scope. References are read from code tokens (comments excluded). An
# orchestrator path is referenced by its name stem, plus its directory when the
# stem is shared across orchestrator directories; any other repository path
# only by an explicit leaf or parent/leaf string.
$batteryCodePattern = '\.(ps1|psm1|cjs|js|mjs|cs|py|sh|vbs)$'
$batterySmokeTests = @(
  ".orchestrator/issue-6997-autonomy-policy.test.ps1",
  ".orchestrator/contract-enforcement.test.ps1",
  ".orchestrator/install-controller-skills.test.ps1",
  ".orchestrator/controller-release-battery.test.ps1",
  ".orchestrator/landing-preflight.test.ps1"
)

function Get-BatteryReferenceKey([string]$Path) {
  $leaf = ($Path -split "/")[-1]
  $key = ($leaf.TrimStart(".") -split "\.")[0]
  if ([string]::IsNullOrEmpty($key)) { return $leaf }
  return $key
}

function Get-BatteryReferenceText([string]$RelativePath) {
  $absolute = Join-Path $controller $RelativePath
  if (-not (Test-Path -LiteralPath $absolute -PathType Leaf)) { return "" }
  if ($RelativePath -cmatch '\.(ps1|psm1)$') {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($absolute, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -eq 0) {
      return (@($tokens | Where-Object { $_.Kind -ne [Management.Automation.Language.TokenKind]::Comment } |
          ForEach-Object { $_.Text }) -join "`n")
    }
  }
  return [IO.File]::ReadAllText($absolute)
}

function New-BatteryReferenceIndex([string[]]$TreePaths) {
  $keyDirectories = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::OrdinalIgnoreCase)
  $leafDirectories = [Collections.Generic.Dictionary[string, Collections.Generic.HashSet[string]]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($path in $TreePaths) {
    $directory = if ($path.Contains("/")) { $path.Substring(0, $path.LastIndexOf("/")) } else { "" }
    $leaf = ($path -split "/")[-1]
    if (-not $leafDirectories.ContainsKey($leaf)) { $leafDirectories[$leaf] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
    [void]$leafDirectories[$leaf].Add($directory)
    if ($path -cmatch "^\.orchestrator/") {
      $key = Get-BatteryReferenceKey $path
      if (-not $keyDirectories.ContainsKey($key)) { $keyDirectories[$key] = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
      [void]$keyDirectories[$key].Add($directory)
    }
  }
  $documents = [ordered]@{}
  # The battery names its smoke tests and is never a reader: its own change
  # always runs the battery's full self-test (see the scope selection below).
  foreach ($path in @($TreePaths | Where-Object {
        $_ -cmatch "^\.orchestrator/" -and $_ -cmatch $batteryCodePattern -and
        $_ -cne ".orchestrator/controller-release-battery.ps1"
      })) {
    $text = Get-BatteryReferenceText $path
    $tokenSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($match in [regex]::Matches($text, "[A-Za-z0-9_-]+")) { [void]$tokenSet.Add($match.Value) }
    $documents[$path] = [pscustomobject]@{ text = $text.Replace("\", "/"); tokens = $tokenSet }
  }
  return [pscustomobject]@{ keyDirectories = $keyDirectories; leafDirectories = $leafDirectories; documents = $documents }
}

function Test-BatteryReference($Document, [string]$Path, $Index) {
  $segments = @($Path -split "/")
  $leaf = $segments[-1]
  $parent = if ($segments.Count -gt 1) { $segments[-2].TrimStart(".") } else { "" }
  if ($Path -cmatch "^\.orchestrator/") {
    $key = Get-BatteryReferenceKey $Path
    if (-not $Document.tokens.Contains($key)) { return $false }
    $shared = $Index.keyDirectories.ContainsKey($key) -and $Index.keyDirectories[$key].Count -gt 1
    return (-not $shared -or [string]::IsNullOrEmpty($parent) -or $Document.tokens.Contains($parent))
  }
  $sharedLeaf = $Index.leafDirectories.ContainsKey($leaf) -and $Index.leafDirectories[$leaf].Count -gt 1
  $needle = if ($sharedLeaf -and $segments.Count -gt 1) { $segments[-2] + "/" + $leaf } else { $leaf }
  return $Document.text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-BatteryRuntimePath([string]$Path, [string[]]$TestPaths) {
  if ($Path -cnotmatch "^\.orchestrator/" -or $TestPaths -ccontains $Path) { return $false }
  if ($Path -cmatch "^\.orchestrator/(artifacts|fixtures)/") { return $false }
  return ($Path -cmatch $batteryCodePattern -or $Path -cmatch "^\.orchestrator/[^/]+\.json$")
}

# Per changed path: the orchestrator code files that reference it (transitively
# for a code file; only the direct readers for a skill, contract or data file),
# and the tests or discriminators that reference any of them. A changed test is
# its own impact. A changed runtime path that reaches no test is unreached and
# forces the full battery.
function Get-BatteryImpact([string[]]$Paths, $Index, [string[]]$TestPaths, [string[]]$TreePaths) {
  $tests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $unreached = [Collections.Generic.List[string]]::new()
  $byPath = [ordered]@{}
  foreach ($path in $Paths) {
    $reached = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pathTests = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $queue = [Collections.Generic.Queue[string]]::new()
    $transitive = $path -cmatch $batteryCodePattern
    [void]$reached.Add($path)
    if ($TestPaths -ccontains $path) {
      [void]$pathTests.Add($path)
    } else {
      $queue.Enqueue($path)
    }
    while ($queue.Count -gt 0) {
      $current = $queue.Dequeue()
      foreach ($candidate in @($Index.documents.Keys)) {
        if ($reached.Contains($candidate)) { continue }
        if (-not (Test-BatteryReference $Index.documents[$candidate] $current $Index)) { continue }
        if ($TestPaths -ccontains $candidate) {
          [void]$reached.Add($candidate)
          [void]$pathTests.Add($candidate)
        } elseif ($transitive -or $current -ceq $path) {
          [void]$reached.Add($candidate)
          $queue.Enqueue($candidate)
        }
      }
    }
    if ($pathTests.Count -eq 0 -and ($TreePaths -ccontains $path) -and (Test-BatteryRuntimePath $path $TestPaths)) {
      $unreached.Add($path)
    }
    foreach ($test in $pathTests) { [void]$tests.Add($test) }
    $byPath[$path] = [string[]]@($pathTests)
  }
  return [pscustomobject]@{ tests = $tests; unreached = [string[]]@($unreached); byPath = $byPath }
}

# Normalized failure lines: roots, absolute paths, hex, GUIDs, timestamps and
# long numbers are masked so two runs of one defect compare equal.
function Get-BatteryFailureSignature([string]$Output, [string]$Root) {
  $lines = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
  foreach ($line in @($Output -split "\r?\n")) {
    if ($line -notmatch '(?i)(assert|fail|error|exception|refus)') { continue }
    $normalized = $line.Replace($Root, "<ROOT>").Replace($Root.Replace("\", "/"), "<ROOT>")
    $normalized = $normalized -replace '(?i)[A-Z]:[\\/][^\s''"]*', '<PATH>'
    $normalized = $normalized -replace '(?i)\b[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\b', '<GUID>'
    $normalized = $normalized -replace '\d{4}-\d{2}-\d{2}T[0-9:.]+Z?', '<TIME>'
    $normalized = $normalized -replace '(?i)\b[0-9a-f]{7,}\b', '<HEX>'
    $normalized = $normalized -replace '\d{3,}', '<N>'
    [void]$lines.Add($normalized.Trim())
  }
  return (@($lines) -join "`n")
}

function Get-BatteryCiApi([string]$Endpoint) {
  $json = @(& gh api --method GET "repos/chase-sets/chase-sets-controller/$Endpoint" 2>$null)
  if ($LASTEXITCODE -ne 0) { throw 'CI_API_FAILED' }
  return (($json -join "`n") | ConvertFrom-Json -Depth 40 -DateKind String -ErrorAction Stop)
}

function Save-BatteryCiArtifact([string]$ArtifactId, [string]$Path) {
  # Native stdout redirection preserves the downloaded ZIP bytes (PS 7.4+).
  & gh api --method GET "repos/chase-sets/chase-sets-controller/actions/artifacts/$ArtifactId/zip" > $Path 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'CI_DOWNLOAD_FAILED' }
}

function Import-BatteryCiPrior($Prior, [byte[]]$ReceiptBytes) {
  $runId = [string]$Prior.ci.runId
  if ($runId -cnotmatch '^[1-9][0-9]*$' -or
      [string]$Prior.ci.checkoutHead -cnotmatch '^[a-f0-9]{40}$' -or
      [string]$Prior.ci.runnerHead -cnotmatch '^[a-f0-9]{40}$') { throw 'CI_IDENTITY_INVALID' }
  $run = Get-BatteryCiApi "actions/runs/$runId"
  if ([string]$run.id -cne $runId -or $run.status -cne 'completed' -or
      $run.repository.full_name -cne 'chase-sets/chase-sets-controller' -or
      $run.head_repository.full_name -cne 'chase-sets/chase-sets-controller' -or
      $run.path -cne '.github/workflows/controller-battery.yml' -or
      $run.head_sha -cne $Prior.ci.runnerHead) { throw 'CI_RUN_INVALID' }
  # A failed run is still useful per-item. Neither its conclusion nor the
  # receipt's aggregate outcome can convert FAIL/LOCAL_ONLY into reusable PASS.
  $listing = Get-BatteryCiApi "actions/runs/$runId/artifacts?per_page=100"
  if ($listing.total_count -gt 100) { throw 'CI_ARTIFACT_LIST_INCOMPLETE' }
  $artifacts = @($listing.artifacts | Where-Object { $_.name -ceq 'controller-battery-result' })
  if ($artifacts.Count -ne 1) { throw 'CI_ARTIFACT_INVALID' }
  $artifact = $artifacts[0]
  if ([string]$artifact.id -cnotmatch '^[1-9][0-9]*$' -or $artifact.expired -ne $false -or
      [string]$artifact.workflow_run.id -cne $runId -or $artifact.workflow_run.head_sha -cne $run.head_sha -or
      [string]$artifact.digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'CI_ARTIFACT_INVALID' }
  $importRoot = Join-Path $runtime 'artifacts'
  [void][IO.Directory]::CreateDirectory($importRoot)
  $archivePath = Join-Path $importRoot ("controller-ci-$runId-$($artifact.id)-" + [guid]::NewGuid().ToString('N') + '.zip')
  Save-BatteryCiArtifact ([string]$artifact.id) $archivePath
  $digest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if (('sha256:' + $digest) -cne $artifact.digest) { throw 'CI_DIGEST_MISMATCH' }
  $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
  try {
    # Do not extract untrusted paths. Compare the exact receipt bytes, not a
    # caller-editable imported JSON envelope or just its self-reported hash.
    $entries = @($archive.Entries | Where-Object { $_.FullName -ceq 'final.json' })
    if ($entries.Count -ne 1) { throw 'CI_RECEIPT_MISMATCH' }
    $stream = $entries[0].Open()
    $memory = [IO.MemoryStream]::new()
    try { $stream.CopyTo($memory); $original = $memory.ToArray() } finally { $stream.Dispose(); $memory.Dispose() }
    if ([Convert]::ToBase64String($original) -cne [Convert]::ToBase64String($ReceiptBytes)) { throw 'CI_RECEIPT_MISMATCH' }
    $logs = @($archive.Entries | Where-Object { $_.FullName -ceq 'controller-ci.log' })
    if ($logs.Count -ne 1) { throw 'CI_RAW_LOG_MISMATCH' }
    $stream = $logs[0].Open()
    try { $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
    if ($rawHash -cne [string]$Prior.rawLog.sha256 -or $logs[0].Length -ne $Prior.rawLog.byteLength) { throw 'CI_RAW_LOG_MISMATCH' }
  } finally { $archive.Dispose() }
  $snapshot = Get-BatteryCiApi "git/commits/$($Prior.ci.checkoutHead)"
  if ($snapshot.sha -cne $Prior.ci.checkoutHead -or @($snapshot.parents).Count -ne 0) { throw 'CI_SNAPSHOT_NOT_ORPHAN' }
  $trailers = [regex]::Matches([string]$snapshot.message, '(?m)^Source-Controller-Head: ([a-f0-9]{40})\s*$')
  if ($trailers.Count -ne 1 -or $trailers[0].Groups[1].Value -cne $Prior.controllerHead) { throw 'CI_TRAILER_MISMATCH' }
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($row in @($Prior.results)) {
    if ([string]::IsNullOrWhiteSpace([string]$row.identity) -or -not $seen.Add([string]$row.identity)) { throw 'CI_DUPLICATE_ITEM' }
  }
  $seen.Clear()
  foreach ($item in @($Prior.inventory)) {
    if ([string]::IsNullOrWhiteSpace([string]$item.identity) -or -not $seen.Add([string]$item.identity)) { throw 'CI_DUPLICATE_ITEM' }
  }
  $import = [ordered]@{
    schemaVersion='controller-battery-ci-import/v1'; repository='chase-sets/chase-sets-controller'
    workflow='.github/workflows/controller-battery.yml'; runId=$runId; artifactId=[string]$artifact.id
    artifactPath=$archivePath; artifactSha256=$digest; checkoutHead=[string]$Prior.ci.checkoutHead
    controllerHead=[string]$Prior.controllerHead; importedUtc=[DateTime]::UtcNow.ToString('o')
  }
  $importPath = [IO.Path]::ChangeExtension($archivePath, '.import.json')
  [IO.File]::WriteAllText($importPath, ($import | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  return [pscustomobject]$import
}

if ($ExpectedControllerHead -cnotmatch "^[a-f0-9]{40}$") {
  Stop-Battery "BATTERY_EXPECTED_HEAD_INVALID"
}
$liveHead = (& git -C $controller rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $liveHead -cne $ExpectedControllerHead) {
  Stop-Battery "BATTERY_LIVE_HEAD_MOVED"
}

$hostIdentity = Get-BatteryHostIdentity

if (-not $ValidatePlanOnly) {
  if (-not $AdmissionOwned) {
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CHASE_SETS_HEAVY_SLOT_ID)) {
      Stop-Battery "BATTERY_INHERITED_ADMISSION_FORBIDDEN"
    }
    $verifier = Join-Path $runtime "invoke-heavy-verifier.ps1"
    if (-not (Test-Path -LiteralPath $verifier -PathType Leaf) -or
        (Get-Item -LiteralPath $verifier -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) {
      Stop-Battery "BATTERY_ADMISSION_WRAPPER_UNAVAILABLE"
    }
    $branch = (& git -C $controller branch --show-current 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
      Stop-Battery "BATTERY_BRANCH_IDENTITY_INVALID"
    }
    $lane = Split-Path -Leaf $controller
    & $verifier -ControllerBattery -Worktree $controller -Lane $lane -Branch $branch `
      -ClaimedHead $ExpectedControllerHead -ContainerRoot (Split-Path -Parent $controller) `
      -ControllerBatteryEvidenceReceiptPath $EvidenceReceiptPath `
      -ControllerBatteryResultPath $ResultPath `
      -ControllerBatteryBaselineHead $BaselineHead `
      -ControllerBatteryRepairIssue $RepairIssue `
      -ControllerBatteryRepairHistoryPath $RepairHistoryPath `
      -ControllerBatteryScope $Scope `
      -ControllerBatteryPriorResultPath $PriorResultPath `
      -ControllerBatteryOnFailure $OnFailure
    exit $LASTEXITCODE
  }
  Assert-BatteryAdmission
  # BATTERY_ADMISSION_TEST_HOLD_SEAM
} elseif ($AdmissionOwned) {
  Stop-Battery "BATTERY_PLAN_ONLY_ADMISSION_FORBIDDEN"
}

# Fleet load observed once at admission (#8102); recorded in the plan line, the
# result record, and beside the per-item observation on every RESULT line.
$admissionFleetLoad = Get-BatteryFleetLoad

$treeOutput = & git -C $controller ls-tree -r --name-only $ExpectedControllerHead 2>&1
if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_PLAN_UNREADABLE" }
$tracked = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$treePaths = [string[]]@($treeOutput | ForEach-Object { ([string]$_).Replace("\", "/") })
foreach ($path in @($treeOutput)) {
  $normalized = ([string]$path).Replace("\", "/")
  if ($normalized -cmatch "^\.orchestrator/.+\.test\.ps1$" -or
      $normalized -cmatch "^\.orchestrator/issue-[^/]+-discriminator\.ps1$") {
    [void]$tracked.Add($normalized)
  }
}
$trackedPaths = [string[]]@($tracked)
[Array]::Sort($trackedPaths, [StringComparer]::Ordinal)

$batteryScope = "full"
$scopeReason = "no-baseline"
$batteryChanged = $false
$batteryImpact = $null
$referenceIndex = $null
$changedPaths = @()
if (-not [string]::IsNullOrWhiteSpace($BaselineHead)) {
  if ($BaselineHead -cnotmatch "^[a-f0-9]{40}$") { Stop-Battery "BATTERY_BASELINE_HEAD_INVALID" }
  & git -C $controller merge-base --is-ancestor $BaselineHead $ExpectedControllerHead 2>$null
  if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_BASELINE_NOT_ANCESTOR" }
  $repairContractRequested = $RepairIssue -gt 0 -or -not [string]::IsNullOrWhiteSpace($RepairHistoryPath)
  if ($repairContractRequested) {
    if ($RepairIssue -lt 1 -or [string]::IsNullOrWhiteSpace($RepairHistoryPath)) {
      Stop-Battery "BATTERY_REPAIR_CONTRACT_INCOMPLETE"
    }
    $resolvedRepairHistory = if ([IO.Path]::IsPathRooted($RepairHistoryPath)) {
      [IO.Path]::GetFullPath($RepairHistoryPath)
    } else { [IO.Path]::GetFullPath((Join-Path $controller $RepairHistoryPath)) }
    Import-Module (Join-Path $runtime "review-head-contract.psm1") -Force -DisableNameChecking
    $repairHistory = Read-ExactHeadReviewHistory -Path $resolvedRepairHistory
    if (-not $repairHistory.complete) { Stop-Battery "BATTERY_REPAIR_HISTORY_$($repairHistory.reason)" }
    $repairReceipts = @(Get-ControllerReviewClassifiedHistory -History $repairHistory | Where-Object {
        $_.classification.strict -and $_.classification.valid -and
        [int64]$_.classification.issue -eq $RepairIssue -and
        [string]$_.classification.controllerHead -ceq $BaselineHead -and
        $_.classification.rowKind -ceq "receipt" -and
        [string]$_.classification.reviewAuthority -ceq "governing"
      })
    if ($repairReceipts.Count -ne 1) { Stop-Battery "BATTERY_REPAIR_RECEIPT_AMBIGUOUS" }
    $repairReceipt = $repairReceipts[0].entry.value
    if ([string]$repairReceipt.outcome -cne "BLOCK_FIXABLE") { Stop-Battery "BATTERY_REPAIR_PREDECESSOR_NOT_BLOCK_FIXABLE" }
    if (@($repairReceipt.findingIds).Count -lt 1 -or
        @($repairReceipt.findingIds).Count -ne [int64]$repairReceipt.findings.blocking) {
      Stop-Battery "BATTERY_REPAIR_FINDINGS_MISSING"
    }
    Write-Output "REPAIR_INPUTS -RepairIssue=$RepairIssue -RepairHistoryPath=$RepairHistoryPath"
    Write-Output "REPAIR_RECEIPT issue=$RepairIssue head=$BaselineHead reviewerAttempt=$($repairReceipt.reviewerAttempt) findingIds=$(@($repairReceipt.findingIds) -join ',')"
  } else {
    $installedHead = ''
    try {
      $identityPath = Join-Path $SkillsRoot 'native-db/identity.json'
      $identity = Get-Content -LiteralPath $identityPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      if ($identity -is [pscustomobject] -and @($identity.PSObject.Properties.Name).Count -eq 2 -and
          $identity.head -is [string] -and [string]$identity.head -cmatch '^[a-f0-9]{40}$' -and
          $identity.digest -is [string] -and [string]$identity.digest -cmatch '^[a-f0-9]{64}$') {
        $installedHead = [string]$identity.head
      }
    } catch {}
    if ($BaselineHead -cne $installedHead) { Stop-Battery 'BATTERY_BASELINE_NOT_INSTALLED' }
  }
  $diffOutput = & git -C $controller diff --no-renames --name-only "$BaselineHead..$ExpectedControllerHead" 2>&1
  if ($LASTEXITCODE -ne 0) { Stop-Battery "BATTERY_BASELINE_UNREADABLE" }
  $changedPaths = @($diffOutput | ForEach-Object { ([string]$_).Replace("\", "/").Trim() } | Where-Object { $_ })
  if ($Scope -ceq "full") {
    $scopeReason = "requested"
  } elseif ($changedPaths.Count -eq 0) {
    $scopeReason = "empty-diff"
  } else {
    # A battery change is proven by the battery's full self-test, whose
    # synthetic children drive every loop, reconcile, result and host path,
    # plus the impact of the change and of everything else changed. -Scope
    # full and the weekly host full battery remain the whole-inventory check.
    $batteryChanged = $changedPaths -ccontains ".orchestrator/controller-release-battery.ps1"
    $referenceIndex = New-BatteryReferenceIndex $treePaths
    $batteryImpact = Get-BatteryImpact $changedPaths $referenceIndex $trackedPaths $treePaths
    if ($batteryImpact.unreached.Count -gt 0) {
      $scopeReason = "unreached:" + ($batteryImpact.unreached -join ",")
    } else {
      $batteryScope = "impact"
      $scopeReason = if ($batteryChanged) { "battery-changed" } else { "reached" }
    }
  }
} elseif ($Scope -ceq "full") {
  $scopeReason = "requested"
}
if ($batteryScope -ceq "impact") {
  $impactTests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($smokeTest in $batterySmokeTests) { [void]$impactTests.Add($smokeTest) }
  foreach ($impactTest in $batteryImpact.tests) { [void]$impactTests.Add($impactTest) }
  $trackedPaths = [string[]]@($trackedPaths | Where-Object {
      $_ -cmatch "^\.orchestrator/issue-[^/]+-discriminator\.ps1$" -or $impactTests.Contains($_)
    })
}

$requiredItems = [Collections.Generic.List[object]]::new()
$checkerPath = Join-Path $runtime "fail-closed-guard-evidence.test.ps1"
$resolvedReceipt = if ([string]::IsNullOrWhiteSpace($EvidenceReceiptPath)) {
  ""
} elseif ([IO.Path]::IsPathRooted($EvidenceReceiptPath)) {
  [IO.Path]::GetFullPath($EvidenceReceiptPath)
} else {
  [IO.Path]::GetFullPath((Join-Path $controller $EvidenceReceiptPath))
}
$directArgs = @(
  "-NoProfile", "-NonInteractive", "-File", $checkerPath,
  "-Scenario", "BypassMutants",
  "-ExpectedControllerHead", $ExpectedControllerHead
)
$requiredItems.Add((New-PlanItem "direct:fail-closed-guard-evidence" ".orchestrator/fail-closed-guard-evidence.ps1" $directArgs))

foreach ($path in $trackedPaths) {
  $absolute = Join-Path $controller $path
  if ($path -cmatch "^\.orchestrator/(issue-[^/]+)-discriminator\.ps1$") {
    $slug = $Matches[1]
    $identity = "discriminator:$slug"
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
      $absolute,
      [ref]$tokens,
      [ref]$parseErrors
    )
    if (@($parseErrors).Count -ne 0) {
      Stop-Battery "BATTERY_DISCRIMINATOR_INTERFACE_UNREADABLE:$slug"
    }
    $parameterNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($parameter in @($ast.ParamBlock.Parameters)) {
      [void]$parameterNames.Add($parameter.Name.VariablePath.UserPath)
    }
    if ($slug -ceq "issue-6254") {
      if (-not $parameterNames.Contains("ControllerRoot") -or
          -not $parameterNames.Contains("EvidenceReceiptPath") -or
          -not $parameterNames.Contains("ExpectedControllerHead")) {
        Stop-Battery "BATTERY_DISCRIMINATOR_INTERFACE_UNREADABLE:$slug"
      }
      $arguments = @(
        "-NoProfile", "-NonInteractive", "-File", $absolute,
        "-ControllerRoot", $controller,
        "-EvidenceReceiptPath", $resolvedReceipt,
        "-ExpectedControllerHead", $ExpectedControllerHead
      )
    } else {
      $arguments = @("-NoProfile", "-NonInteractive", "-File", $absolute)
      if ($parameterNames.Contains("ControllerRoot")) {
        $arguments += @("-ControllerRoot", $controller)
      } elseif ($parameterNames.Contains("RepositoryRoot")) {
        $arguments += @("-RepositoryRoot", $controller)
      }
    }
    $requiredItems.Add((New-PlanItem $identity $path $arguments))
    continue
  }

  $identity = "test:" + $path.Substring(".orchestrator/".Length)
  $arguments = @("-NoProfile", "-NonInteractive", "-File", $absolute)
  if ($path -ceq ".orchestrator/controller-release-battery.test.ps1" -and -not $batteryChanged) {
    $arguments += @("-ValidatePlanOnly")
  }
  $requiredItems.Add((New-PlanItem $identity $path $arguments))
}

$identitySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($item in $requiredItems) {
  if (-not $identitySet.Add($item.identity)) { Stop-Battery "BATTERY_PLAN_DUPLICATE:$($item.identity)" }
}
foreach ($requiredDiscriminator in @("discriminator:issue-6254")) {
  if (-not $identitySet.Contains($requiredDiscriminator)) {
    Stop-Battery "BATTERY_DISCRIMINATOR_OMITTED:$($requiredDiscriminator.Substring('discriminator:'.Length))"
  }
}

$selectedItems = [Collections.Generic.List[object]]::new()
foreach ($item in $requiredItems) {
  if ($item.identity -ceq "direct:fail-closed-guard-evidence" -and
      -not $planInclusion["direct:fail-closed-guard-evidence"]) {
    continue
  }
  if ($item.identity -ceq "discriminator:issue-6254" -and
      -not $planInclusion["discriminator:issue-6254"]) {
    continue
  }
  $selectedItems.Add($item)
}

Write-Output "BATTERY_SCOPE scope=$batteryScope baseline=$(if ($BaselineHead) { $BaselineHead } else { 'none' }) changed=$($changedPaths.Count) reason=$scopeReason"
if ($null -ne $batteryImpact) {
  foreach ($path in @($batteryImpact.byPath.Keys | Where-Object { $_ -cmatch "^\.orchestrator/" })) {
    Write-Output "IMPACT path=$path tests=$(@($batteryImpact.byPath[$path] | ForEach-Object { $_.Substring('.orchestrator/'.Length) }) -join ',')"
  }
}
Write-Output "BATTERY_PLAN_BEGIN head=$ExpectedControllerHead required=$($requiredItems.Count) selected=$($selectedItems.Count) fleetLoad=$admissionFleetLoad"
foreach ($item in $requiredItems) {
  Write-Output "REQUIRED identity=$($item.identity) path=$($item.path)"
}
foreach ($item in $selectedItems) {
  Write-Output "PLAN identity=$($item.identity) command=$($item.command)"
}
Write-Output "BATTERY_PLAN_END"

if ($ValidatePlanOnly) {
  Write-Output "PASS controller release battery plan-only head=$ExpectedControllerHead required=$($requiredItems.Count)"
  return
}
$results = [Collections.Generic.List[object]]::new()
$resolvedResult = ""
if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
  try {
    $resolvedResult = if ([IO.Path]::IsPathRooted($ResultPath)) {
      [IO.Path]::GetFullPath($ResultPath)
    } else {
      [IO.Path]::GetFullPath((Join-Path $controller $ResultPath))
    }
    $artifactRoot = [IO.Path]::GetFullPath((Join-Path $runtime "artifacts")).TrimEnd("\", "/")
    $rawPath = [IO.Path]::ChangeExtension($resolvedResult, ".log")
    if ((Split-Path -Parent $resolvedResult).TrimEnd("\", "/") -cne $artifactRoot -or
        (Test-SameBatteryPath $resolvedResult $rawPath) -or
        [IO.Path]::GetFileName($resolvedResult).IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
      Stop-Battery "BATTERY_RESULT_PATH_INVALID"
    }
    foreach ($outputPath in @($resolvedResult, $rawPath)) {
      if ((Test-Path -LiteralPath $outputPath) -and
          ((Get-Item -LiteralPath $outputPath -Force).PSIsContainer -or
           (Get-Item -LiteralPath $outputPath -Force).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint))) {
        Stop-Battery "BATTERY_RESULT_PATH_INVALID"
      }
    }
    New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null
  } catch {
    Stop-Battery "BATTERY_RESULT_PATH_INVALID"
  }
}

# Reuse (#8207). A prior result from this worktree lends its PASS test items to
# this run when the prior head is an ancestor, the host binary and raw log still
# match, the item ran within 24 hours, and the prior..candidate diff reaches
# neither the item nor anything it references. Local-prior guards always execute.
# CI priors replace only that host/path anchor with authenticated GitHub bytes;
# every eligible item (including guards) may be carried across an empty impact.
$reusable = @{}
$priorOrder = @{}
if (-not [string]::IsNullOrWhiteSpace($PriorResultPath)) {
  $priorFailure = $null
  try {
    $resolvedPrior = if ([IO.Path]::IsPathRooted($PriorResultPath)) { [IO.Path]::GetFullPath($PriorResultPath) } else { [IO.Path]::GetFullPath((Join-Path $controller $PriorResultPath)) }
    $priorArtifactRoot = [IO.Path]::GetFullPath((Join-Path $runtime "artifacts")).TrimEnd("\", "/")
    if (-not (Test-Path -LiteralPath $resolvedPrior -PathType Leaf)) { throw "PATH" }
    $priorBytes = [IO.File]::ReadAllBytes($resolvedPrior)
    $prior = [Text.Encoding]::UTF8.GetString($priorBytes) | ConvertFrom-Json -DateKind String -ErrorAction Stop
    if ($prior.schemaVersion -cne "controller-battery-result/v1" -or [string]$prior.controllerHead -cnotmatch "^[a-f0-9]{40}$") { throw "SCHEMA" }
    $isCiPrior = $null -ne $prior.PSObject.Properties['ci']
    if (-not $isCiPrior -and (Split-Path -Parent $resolvedPrior).TrimEnd("\", "/") -cne $priorArtifactRoot) { throw "PATH" }
    & git -C $controller merge-base --is-ancestor $prior.controllerHead $ExpectedControllerHead 2>$null
    if ($LASTEXITCODE -ne 0) { throw "NOT_ANCESTOR" }
    $ciImport = $null
    if ($isCiPrior) {
      $ciImport = Import-BatteryCiPrior $prior $priorBytes
    } else {
      if ([string]$hostIdentity.sha256 -ceq "unavailable" -or [string]$prior.hostIdentity.sha256 -cne [string]$hostIdentity.sha256) { throw "HOST_CHANGED" }
      $priorRawPath = Join-Path $controller ([string]$prior.rawLog.relativePath)
      $priorRawHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($priorRawPath)))).ToLowerInvariant()
      if ($priorRawHash -cne [string]$prior.rawLog.sha256) { throw "RAW_LOG_MISMATCH" }
    }
    $priorResultHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($priorBytes))).ToLowerInvariant()
    $priorDiff = @(& git -C $controller diff --no-renames --name-only "$($prior.controllerHead)..$ExpectedControllerHead" 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "DIFF_UNREADABLE" }
    $priorDiff = @($priorDiff | ForEach-Object { ([string]$_).Replace("\", "/").Trim() } | Where-Object { $_ })
    $priorImpactTests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($priorDiff.Count -gt 0) {
      if (-not $isCiPrior -and $priorDiff -ccontains ".orchestrator/controller-release-battery.ps1") { throw "BATTERY_CHANGED" }
      if ($null -eq $referenceIndex) { $referenceIndex = New-BatteryReferenceIndex $treePaths }
      $priorImpact = Get-BatteryImpact $priorDiff $referenceIndex ([string[]]@($tracked)) $treePaths
      if ($priorImpact.unreached.Count -gt 0) {
        if (-not $isCiPrior) { throw "UNREACHED" }
        # The existing conservative fallback is the whole selected inventory.
        foreach ($item in $selectedItems) { [void]$priorImpactTests.Add($item.path) }
      }
      foreach ($impactTest in $priorImpact.tests) { [void]$priorImpactTests.Add($impactTest) }
      if ($isCiPrior -and $priorDiff -ccontains '.orchestrator/controller-release-battery.ps1') {
        [void]$priorImpactTests.Add('.orchestrator/controller-release-battery.test.ps1')
      }
    }
    $cutoff = [DateTimeOffset]::UtcNow.AddHours(-24)
    foreach ($row in @($prior.results)) {
      $priorOrder[[string]$row.identity] = [long]$row.elapsedMs
      $item = @($selectedItems | Where-Object { $_.identity -ceq [string]$row.identity })
      if ($item.Count -ne 1 -or [string]$row.result -cne "PASS" -or $row.exitCode -ne 0 -or
          $priorImpactTests.Contains($item[0].path)) { continue }
      if ($isCiPrior) {
        $ciItem = @($prior.inventory | Where-Object { $_.identity -ceq $row.identity })
        if ([string]$row.fleetLoad -cne 'none' -or $ciItem.Count -ne 1 -or $ciItem[0].path -cne $item[0].path -or
            $null -ne $ciItem[0].restriction -or [string]$row.provenance.kind -cne 'execution' -or
            $row.identity -cin @($prior.ci.localOnly | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.identity } }) -or
            $row.identity -cin @($prior.ci.notHermetic) -or
            ($item[0].identity -ceq 'discriminator:issue-6254' -and -not [string]::IsNullOrWhiteSpace($EvidenceReceiptPath)) -or
            ($item[0].identity -ceq 'direct:fail-closed-guard-evidence' -and
              $priorImpactTests.Contains('.orchestrator/fail-closed-guard-evidence.test.ps1'))) { continue }
      } else {
        if ($item[0].identity -cnotlike 'test:*' -or $item[0].identity -ceq 'test:controller-release-battery.test.ps1') { continue }
        $ranAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$row.startedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ranAt) -or
            $ranAt -lt $cutoff) { continue }
      }
      $reusable[$item[0].identity] = [pscustomobject]@{
        row = $row; priorHead = [string]$prior.controllerHead; priorResultSha256 = $priorResultHash
        ciImport = $ciImport
      }
    }
  } catch {
    $priorFailure = if ($_.Exception.Message -cmatch "^[A-Z_]+$") { $_.Exception.Message } else { "UNREADABLE" }
  }
  if ($priorFailure) { Stop-Battery "BATTERY_PRIOR_RESULT_INVALID:$priorFailure" }
  Write-Output "REUSE prior=$($prior.controllerHead) reusable=$($reusable.Count) of=$($selectedItems.Count)"
}
# Fast items run first so an early failure is seen early. Timings come from the
# prior result, else from the newest battery result in this worktree's
# artifacts; they order execution only and never affect a verdict.
if ($priorOrder.Count -eq 0) {
  try {
    # Test carriers write thousands of other JSON artifacts here; a 64-byte
    # prefix read finds the newest battery result without parsing them.
    $resultPrefix = '{"schemaVersion":"controller-battery-result/v1"'
    $timingSource = $null
    foreach ($candidateFile in @(Get-ChildItem -LiteralPath (Join-Path $runtime "artifacts") -Filter "*.json" -File -ErrorAction Stop |
        Sort-Object LastWriteTimeUtc -Descending)) {
      $prefix = [byte[]]::new(64)
      $stream = [IO.File]::OpenRead($candidateFile.FullName)
      try { $read = $stream.Read($prefix, 0, 64) } finally { $stream.Dispose() }
      if ([Text.Encoding]::UTF8.GetString($prefix, 0, $read).StartsWith($resultPrefix, [StringComparison]::Ordinal)) {
        $timingSource = Get-Content -LiteralPath $candidateFile.FullName -Raw | ConvertFrom-Json -DateKind String -ErrorAction Stop
        break
      }
    }
    foreach ($row in @($timingSource.results)) { $priorOrder[[string]$row.identity] = [long]$row.elapsedMs }
  } catch {}
}
$executionItems = if ($priorOrder.Count -gt 0) {
  @($selectedItems | Sort-Object -Stable -Property @{ Expression = { if ($priorOrder.ContainsKey($_.identity)) { $priorOrder[$_.identity] } else { 0 } } })
} else { @($selectedItems) }

# Impact runs tell children which orchestrator files changed, so proof arms
# whose guarded file is unchanged may skip (support Test-BatteryProofRelevant).
# A full run clears it and every arm executes.
$env:CHASE_SETS_BATTERY_IMPACT_PATHS = if ($batteryScope -ceq "impact") {
  (@($changedPaths | Where-Object { $_ -cmatch "^\.orchestrator/" }) -join ";")
} else { $null }
if ($batteryScope -ceq "impact" -and [string]::IsNullOrEmpty($env:CHASE_SETS_BATTERY_IMPACT_PATHS)) { $env:CHASE_SETS_BATTERY_IMPACT_PATHS = "none" }

$batteryStartedUtc = [DateTime]::UtcNow.ToString("o")
$batteryClock = [Diagnostics.Stopwatch]::StartNew()
$executionStarted = $false
$batteryFailure = $null
$failureCode = $null
$batteryOutcome = "FAIL"
# Baseline classification (#8207). A failed test item is re-run once on the
# installed baseline in a temporary detached worktree, as soon as it fails. The
# same exit code and the same normalized failure lines make it PREEXISTING and
# the run continues; anything else is a REGRESSION. Repair baselines are
# unreviewed candidates and are never used.
$baselineRoot = $null
$baselineCreated = $false
function Invoke-BatteryBaselineClassification($Failed, $Item) {
  $classification = "REGRESSION"
  $baselineExit = $null
  if (-not $script:baselineRoot) {
    $script:baselineRoot = Join-Path (Split-Path -Parent $controller) ("{0}-battery-baseline-{1}-{2}" -f [DateTime]::UtcNow.ToString("yyyyMMdd"), $BaselineHead.Substring(0, 12), $PID)
    & git -C $controller worktree add --detach --quiet $script:baselineRoot $BaselineHead 2>&1 | Out-Null
    $script:baselineCreated = $LASTEXITCODE -eq 0
  }
  & git -C $controller cat-file -e "$($BaselineHead):$($Item.path)" 2>$null
  if (-not $script:baselineCreated) {
    $classification = "UNCLASSIFIED"
  } elseif ($LASTEXITCODE -eq 0) {
    $baselineArguments = @($Item.arguments | ForEach-Object {
        if (Test-SameBatteryPath $_ $controller) { $script:baselineRoot }
        elseif ($_ -is [string] -and $_.StartsWith($controller, [StringComparison]::OrdinalIgnoreCase)) { $script:baselineRoot + $_.Substring($controller.Length) }
        else { $_ }
      })
    $baselineOutput = & $Item.executable @baselineArguments 2>&1 | Out-String
    $baselineExit = $LASTEXITCODE
    $candidateSignature = Get-BatteryFailureSignature $Failed.output $controller
    $baselineSignature = Get-BatteryFailureSignature $baselineOutput $script:baselineRoot
    if ($baselineExit -eq $Failed.exitCode -and $candidateSignature -and $candidateSignature -ceq $baselineSignature) {
      $classification = "PREEXISTING"
    }
  }
  $Failed | Add-Member -NotePropertyName baseline -NotePropertyValue ([ordered]@{
      head = $BaselineHead; classification = $classification; exitCode = $baselineExit
    })
  Write-Output "BASELINE identity=$($Failed.identity) classification=$classification baseline=$BaselineHead baselineExit=$baselineExit"
}
$timingLines = [Collections.Generic.List[string]]::new()
$stoppedAt = $null
$notRun = [Collections.Generic.List[string]]::new()
try {
  foreach ($item in $executionItems) {
    if ($null -ne $stoppedAt) { $notRun.Add($item.identity); continue }
    if ($reusable.ContainsKey($item.identity)) {
      $reuse = $reusable[$item.identity]
      $result = [pscustomobject][ordered]@{
        identity = $item.identity
        command = $item.command
        exitCode = 0
        result = "PASS"
        fleetLoad = [string]$reuse.row.fleetLoad
        startedUtc = [string]$reuse.row.startedUtc
        finishedUtc = [string]$reuse.row.finishedUtc
        elapsedMs = [long]$reuse.row.elapsedMs
        output = "REUSED from $($reuse.priorHead)"
        provenance = [ordered]@{ kind = 'receipt-reuse'; command = $item.command; attempt = 'local-battery'; priorHead = $reuse.priorHead; priorResultSha256 = $reuse.priorResultSha256
          source = $(if ($null -ne $reuse.ciImport) { 'ci:' + $reuse.ciImport.runId } elseif ($reuse.row.provenance.source -clike 'ci:*') { $reuse.row.provenance.source } else { 'local' }) }
      }
      if ($null -ne $reuse.ciImport) { $result.provenance.ci = $reuse.ciImport }
      elseif ($null -ne $reuse.row.provenance.ci) { $result.provenance.ci = $reuse.row.provenance.ci }
      $results.Add($result)
      Write-Output "RESULT identity=$($result.identity) exitCode=0 result=PASS fleetLoad=$($result.fleetLoad) startedUtc=$($result.startedUtc) finishedUtc=$($result.finishedUtc) elapsedMs=$($result.elapsedMs) provenance=receipt-reuse prior=$($reuse.priorHead)"
      continue
    }
    $itemFleetLoad = Get-BatteryFleetLoad
    $startedUtc = [DateTime]::UtcNow.ToString("o")
    $itemClock = [Diagnostics.Stopwatch]::StartNew()
    $executionStarted = $true
    $childTiming = [Collections.Generic.List[string]]::new()
    try {
      $childOutput = & $item.executable @($item.arguments) 2>&1 | ForEach-Object {
          $first = (($_ | Out-String) -split "\r?\n" | Where-Object { $_ } | Select-Object -First 1)
          $childTiming.Add(("+{0}ms {1}" -f $itemClock.ElapsedMilliseconds, $first))
          $_
        } | Out-String
      $exitCode = $LASTEXITCODE
    } finally {
      $itemClock.Stop()
      $finishedUtc = [DateTime]::UtcNow.ToString("o")
    }
    # MEASURED_LOAD (#8102): a timed fixture that missed its bound while the
    # platform slot was held for its whole window exits 75 and prints a
    # MEASURED_LOAD line. It is never PASS; unlike FAIL it marks the battery
    # INCOMPLETE_MEASURED_LOAD rather than failed.
    $measuredLoad = ($exitCode -eq 75) -and ($childOutput -cmatch '(?m)^MEASURED_LOAD ')
    $provenance = [ordered]@{kind='execution';command=$item.command;attempt='local-battery';source='local'}
    $result = [pscustomobject][ordered]@{
      identity = $item.identity
      command = $item.command
      exitCode = $exitCode
      result = if ($exitCode -eq 0) { "PASS" } elseif ($measuredLoad) { "MEASURED_LOAD" } else { "FAIL" }
      fleetLoad = $itemFleetLoad
      startedUtc = $startedUtc
      finishedUtc = $finishedUtc
      elapsedMs = $itemClock.ElapsedMilliseconds
      output = $childOutput.Trim()
      provenance = $provenance
    }
    $timingLines.Add("ITEM $($item.identity) elapsedMs=$($itemClock.ElapsedMilliseconds)")
    foreach ($timingLine in $childTiming) { $timingLines.Add($timingLine) }
    $results.Add($result)
    Write-Output "RESULT identity=$($result.identity) exitCode=$exitCode result=$($result.result) fleetLoad=$($result.fleetLoad) startedUtc=$startedUtc finishedUtc=$finishedUtc elapsedMs=$($result.elapsedMs)"
    if ($result.output) {
      foreach ($line in @($result.output -split "\r?\n")) {
        Write-Output "CHILD identity=$($result.identity) $line"
      }
    }
    if ($result.result -ceq "FAIL") {
      if ($item.identity -clike "test:*" -and $BaselineHead -and $RepairIssue -eq 0) {
        Invoke-BatteryBaselineClassification $result $item
      }
      $preexisting = $null -ne $result.PSObject.Properties["baseline"] -and $result.baseline.classification -ceq "PREEXISTING"
      if (-not $preexisting -and $OnFailure -ceq "stop") { $stoppedAt = $item.identity }
    }
  }

  if ($null -ne $stoppedAt) {
    Write-Output "NOT_RUN count=$($notRun.Count) after=$stoppedAt identities=$($notRun -join ',')"
    Stop-Battery "BATTERY_CHILD_FAILED:$stoppedAt"
  }

  $executed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($result in $results) {
    if (-not $executed.Add($result.identity)) {
      Stop-Battery "BATTERY_RESULT_DUPLICATE:$($result.identity)"
    }
  }
  foreach ($item in $requiredItems) {
    if (-not $executed.Contains($item.identity)) {
      switch ($item.identity) {
        "direct:fail-closed-guard-evidence" {
          Stop-Battery "BATTERY_DIRECT_CHECKER_VALIDATION_OMITTED"
        }
        "discriminator:issue-6254" {
          Stop-Battery "BATTERY_DISCRIMINATOR_OMITTED:issue-6254"
        }
        default { Stop-Battery "BATTERY_RESULT_MISSING:$($item.identity)" }
      }
    }
  }
  foreach ($result in $results) {
    if (-not $identitySet.Contains($result.identity)) {
      Stop-Battery "BATTERY_RESULT_EXTRA:$($result.identity)"
    }
  }
  $preexistingItems = @()
  foreach ($result in $results) {
    if ($result.exitCode -ne 0 -and $result.result -cne "MEASURED_LOAD") {
      if ($null -ne $result.PSObject.Properties["baseline"] -and $result.baseline.classification -ceq "PREEXISTING") {
        $preexistingItems += $result.identity
        continue
      }
      Stop-Battery "BATTERY_CHILD_FAILED:$($result.identity)"
    }
  }
  if ($results.Count -ne $requiredItems.Count) {
    Stop-Battery "BATTERY_RESULT_COUNT_MISMATCH"
  }
  # Only PREEXISTING failures remain: never PASS and still exit 1, but a
  # distinct outcome the governing review may accept when each item has an
  # open issue (milestone-orchestrator section 7).
  if ($preexistingItems.Count -gt 0) {
    $failureCode = "BATTERY_PREEXISTING_ONLY:" + ($preexistingItems -join ",")
    $batteryFailure = "FAIL controller-release-battery: $failureCode"
    $batteryOutcome = "FAIL_PREEXISTING_ONLY"
    throw $batteryFailure
  }
  # A FAIL above wins over any MEASURED_LOAD item; reaching here means every item
  # is PASS or MEASURED_LOAD. One MEASURED_LOAD item makes the whole run
  # INCOMPLETE_MEASURED_LOAD: not installable, exit 75, never a PASS line.
  $measuredLoadItems = @($results | Where-Object { $_.result -ceq "MEASURED_LOAD" } | ForEach-Object { $_.identity })
  $batteryOutcome = if ($measuredLoadItems.Count -gt 0) { "INCOMPLETE_MEASURED_LOAD" } else { "PASS" }
} catch {
  $batteryFailure = $_
  $failureCode = $_.Exception.Message -creplace '^FAIL controller-release-battery: ', ''
  if ($batteryOutcome -cne "FAIL_PREEXISTING_ONLY") { $batteryOutcome = "FAIL" }
} finally {
  $batteryClock.Stop()
  $batteryFinishedUtc = [DateTime]::UtcNow.ToString("o")
  if ($baselineCreated) { & git -C $controller worktree remove --force $baselineRoot 2>&1 | Out-Null }
}
$measuredLoadItems = @($results | Where-Object { $_.result -ceq "MEASURED_LOAD" } | ForEach-Object { $_.identity })

try {
  if (($executionStarted -or $results.Count -gt 0) -and $resolvedResult) {
    $rawText = @($results | ForEach-Object {
      "RESULT identity=$($_.identity) exitCode=$($_.exitCode) result=$($_.result) fleetLoad=$($_.fleetLoad) startedUtc=$($_.startedUtc) finishedUtc=$($_.finishedUtc) elapsedMs=$($_.elapsedMs)`n$($_.output)"
    }) -join "`n"
    $rawBytes = [Text.UTF8Encoding]::new($false).GetBytes($batteryHostLog + "`n" + $rawText + "`n")
    [IO.File]::WriteAllBytes($rawPath, $rawBytes)
    $rawHash = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rawBytes))).ToLowerInvariant()
    $resultRecord = [ordered]@{
      schemaVersion = "controller-battery-result/v1"
      controllerHead = $ExpectedControllerHead
      hostIdentity = $hostIdentity
      fleetLoad = $admissionFleetLoad
      scope = [ordered]@{ kind = $batteryScope; reason = $scopeReason; baselineHead = $BaselineHead; changedCount = $changedPaths.Count }
      execution = [ordered]@{
        mode = "foreground-file-serial"
        outcome = $batteryOutcome
        startedUtc = $batteryStartedUtc
        finishedUtc = $batteryFinishedUtc
        elapsedMs = $batteryClock.ElapsedMilliseconds
        measuredLoadCount = $measuredLoadItems.Count
        requiredCount = $requiredItems.Count
        executedCount = @($results | Where-Object {$_.provenance.kind -ceq 'execution'}).Count
        reusedCount = @($results | Where-Object {$_.provenance.kind -ceq 'receipt-reuse'}).Count
        satisfiedCount = $results.Count
        onFailure = $OnFailure
        notRun = @($notRun)
      }
      inventory = @($requiredItems | ForEach-Object {
        [ordered]@{ identity = $_.identity; path = $_.path; command = $_.command }
      })
      results = @($results | ForEach-Object {
        $row = [ordered]@{
          identity = $_.identity; exitCode = $_.exitCode; result = $_.result; fleetLoad = $_.fleetLoad
          provenance = $_.provenance; startedUtc = $_.startedUtc; finishedUtc = $_.finishedUtc; elapsedMs = $_.elapsedMs
        }
        if ($null -ne $_.PSObject.Properties["baseline"]) { $row.baseline = $_.baseline }
        $row
      })
      rawLog = [ordered]@{
        kind = "raw-log"
        relativePath = ".orchestrator/artifacts/" + [IO.Path]::GetFileName($rawPath)
        byteLength = $rawBytes.Length
        sha256 = $rawHash
      }
    }
    if ($null -ne $batteryFailure) { $resultRecord.failureCode = $failureCode }
    $resultBytes = [Text.UTF8Encoding]::new($false).GetBytes(($resultRecord | ConvertTo-Json -Compress -Depth 20) + "`n")
    [IO.File]::WriteAllBytes($resolvedResult, $resultBytes)
    # Diagnostic per-line child timing; not bound by the result record.
    try { [IO.File]::WriteAllLines([IO.Path]::ChangeExtension($resolvedResult, ".timing.txt"), [string[]]@($timingLines)) } catch {}
    Write-Output "BATTERY_RESULT path=$resolvedResult raw=$rawPath"
  }
} catch {
  if ($null -eq $batteryFailure) { throw }
  # A secondary output failure must not replace the original terminal signature.
  Write-Warning "Battery result write failed: $($_.Exception.Message)"
}

function Write-BatteryRecap {
  foreach ($result in @($results | Sort-Object -Property elapsedMs -Descending -Stable)) {
    Write-Output "TIMING identity=$($result.identity) startedUtc=$($result.startedUtc) finishedUtc=$($result.finishedUtc) elapsedMs=$($result.elapsedMs)"
  }
}

if ($null -ne $batteryFailure) {
  if ($batteryOutcome -ceq "FAIL_PREEXISTING_ONLY") {
    Write-Output "FAIL_PREEXISTING_ONLY controller release battery head=$ExpectedControllerHead baseline=$BaselineHead preexisting=$($preexistingItems -join ',')"
  }
  Write-BatteryRecap
  throw $batteryFailure
}

if ($batteryOutcome -ceq "INCOMPLETE_MEASURED_LOAD") {
  Write-Output "INCOMPLETE_MEASURED_LOAD controller release battery head=$ExpectedControllerHead measured=$($measuredLoadItems -join ',') fleetLoad=$admissionFleetLoad"
  Write-BatteryRecap
  exit 75
}

$executedCount=@($results|Where-Object{$_.provenance.kind-ceq'execution'}).Count;$reusedCount=@($results|Where-Object{$_.provenance.kind-ceq'receipt-reuse'}).Count
Write-Output "PASS controller release battery head=$ExpectedControllerHead required=$($requiredItems.Count) executed=$executedCount reused=$reusedCount satisfied=$($results.Count) direct=1 tests=$(@($requiredItems | Where-Object identity -like 'test:*').Count) discriminators=$(@($requiredItems | Where-Object identity -like 'discriminator:*').Count) startedUtc=$batteryStartedUtc finishedUtc=$batteryFinishedUtc elapsedMs=$($batteryClock.ElapsedMilliseconds)"
Write-BatteryRecap
