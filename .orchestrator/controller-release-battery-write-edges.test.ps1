[CmdletBinding()]
param([string]$BatterySourcePath = (Join-Path $PSScriptRoot 'controller-release-battery.ps1'))
$ErrorActionPreference = 'Stop'
# Definitions and the actual preflight/publication blocks only: no admission,
# live locks, census or child battery. The alternate source runs identical
# controls against a saved base, without changing the worktree under test.
$source = [IO.File]::ReadAllText($BatterySourcePath)
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'battery parse failed' }
foreach ($definition in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
$publication = @($ast.EndBlock.Statements | Where-Object {
  $_ -is [Management.Automation.Language.TryStatementAst] -and $_.Extent.Text.Contains('$rawText =')
})
if ($publication.Count -ne 1) { throw 'missing publication block' }
$publish = [scriptblock]::Create($publication[0].Extent.Text)
$preStart = $source.IndexOf('$resolvedResult = ""', [StringComparison]::Ordinal)
$preEnd = $source.IndexOf('# Reuse (#8207).', [StringComparison]::Ordinal)
if ($preStart -lt 0 -or $preEnd -le $preStart) { throw 'missing output preflight' }
$preflight = [scriptblock]::Create($source.Substring($preStart, $preEnd - $preStart))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('battery-write-edges-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$failures = [Collections.Generic.List[string]]::new()
function Assert-Test([bool]$Value, [string]$Message) { if (-not $Value) { throw "ASSERTION FAILED: $Message" } }
function Test-Control([string]$Name, [scriptblock]$Body) {
  try { & $Body; Write-Output "PASS 215 $Name" }
  catch { $script:failures.Add($Name); Write-Output "FAIL 215 ${Name}: $($_.Exception.Message)" }
}
function Get-Refusal([scriptblock]$Action) {
  try { $null = & $Action; return '' } catch { return $_.Exception.Message }
}
try {
  $root = Join-Path $testRoot 'artifacts'
  [void][IO.Directory]::CreateDirectory($root)
  $bytes = [Text.Encoding]::UTF8.GetBytes('replacement')
  Test-Control 'share-reader' {
    $path = Join-Path $root 'reader.log'
    [IO.File]::WriteAllText($path, 'old')
    $reader = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      Write-BatteryArtifact $root $path 'EDGE_REFUSED' $bytes
      Assert-Test ([IO.File]::ReadAllText($path) -ceq 'replacement') 'concurrent reader allows overwrite'
      Assert-Test ((Get-Refusal { Write-BatteryArtifact $root $path 'EDGE_REFUSED' $bytes -CreateNew }) -ceq 'FAIL controller-release-battery: EDGE_REFUSED') 'CreateNew still refuses an existing name'
    } finally { $reader.Dispose() }
  }
  Test-Control 'warning-before-refusal' {
    $path = Join-Path $root 'diagnostic.txt'
    [IO.File]::WriteAllText($path, 'sentinel')
    $events = @(& {
      try { Write-BatteryArtifact $root $path 'EDGE_REFUSED' $bytes -CreateNew }
      catch { Write-Output $_.Exception.Message }
    } 3>&1)
    Assert-Test ($events.Count -eq 2 -and $events[0] -is [Management.Automation.WarningRecord] -and
      $events[0].Message.StartsWith("artifact write refused (${path}): ") -and
      $events[0].Message.Contains('Exception calling "Write"') -and
      $events[1] -ceq 'FAIL controller-release-battery: EDGE_REFUSED') 'exception message warning precedes unchanged refusal'
    Assert-Test ([IO.File]::ReadAllText($path) -ceq 'sentinel') 'diagnostic failure does not truncate'
  }
  Test-Control 'hardlink-output' {
    $outside = Join-Path $testRoot 'victim.txt'
    $path = Join-Path $root 'hardlink.log'
    [IO.File]::WriteAllText($outside, 'outside-sentinel')
    [void](New-Item -ItemType HardLink -Path $path -Target $outside)
    $refusal = Get-Refusal { Write-BatteryArtifact $root $path 'EDGE_REFUSED' $bytes }
    Assert-Test ($refusal -ceq 'FAIL controller-release-battery: EDGE_REFUSED' -and
      [IO.File]::ReadAllText($outside) -ceq 'outside-sentinel') 'hard-linked output refused before truncation'
  }
  foreach ($kind in @('directory', 'symlink')) {
    Test-Control "timing-preflight-$kind" {
      $controller = Join-Path $testRoot "preflight-$kind"
      $runtime = Join-Path $controller '.orchestrator'
      $artifactRoot = Join-Path $runtime 'artifacts'
      [void][IO.Directory]::CreateDirectory($artifactRoot)
      $ResultPath = Join-Path $artifactRoot 'result.json'
      $timing = [IO.Path]::ChangeExtension($ResultPath, '.timing.txt')
      if ($kind -ceq 'directory') { [void][IO.Directory]::CreateDirectory($timing) }
      else { [void](New-Item -ItemType SymbolicLink -Path $timing -Target (Join-Path $testRoot 'victim.txt')) }
      $refusal = Get-Refusal { . $preflight; throw 'CHILD_WOULD_START' }
      Assert-Test ($refusal -ceq 'FAIL controller-release-battery: BATTERY_RESULT_PATH_INVALID') 'bad timing name refused before any child'
    }
  }
  foreach ($failTiming in @($false, $true)) {
    Test-Control "timing-publication-failure=$failTiming" {
      $artifactRoot = $root
      $resolvedResult = Join-Path $root "publication-$failTiming.json"
      $rawPath = [IO.Path]::ChangeExtension($resolvedResult, '.log')
      $executionStarted = $true; $batteryFailure = $null; $batteryOutcome = 'PASS'
      $ExpectedControllerHead = 'a' * 40; $hostIdentity = @{}; $admissionFleetLoad = 'none'
      $batteryScope = 'full'; $scopeReason = 'fixture'; $BaselineHead = ''; $changedPaths = @()
      $batteryStartedUtc = $batteryFinishedUtc = [DateTime]::UtcNow.ToString('o')
      $batteryClock = [Diagnostics.Stopwatch]::StartNew(); $measuredLoadItems = @(); $notRun = @()
      $OnFailure = 'all'; $concurrentMode = $false; $batteryHostLog = 'fixture'
      $results = @([pscustomobject]@{identity='test:fixture';exitCode=0;result='PASS';fleetLoad='none';
        provenance=@{kind='execution'};startedUtc=$batteryStartedUtc;finishedUtc=$batteryFinishedUtc;elapsedMs=1;output='PASS'})
      $requiredItems = @([pscustomobject]@{identity='test:fixture';path='fixture';command='fixture'})
      $timingLines = @('ITEM fixture')
      $writes = [Collections.Generic.List[string]]::new()
      function Invoke-BatteryArtifactWriteSeam([string]$Path) {
        $writes.Add($Path)
        if ($failTiming -and $Path.EndsWith('.timing.txt')) { throw 'TIMING_FAILURE' }
      }
      $refusal = Get-Refusal { . $publish }
      if ($failTiming) {
        Assert-Test ($refusal -ceq 'TIMING_FAILURE' -and -not [IO.File]::Exists($resolvedResult)) 'timing failure cannot leave a new PASS record'
      } else {
        Assert-Test ($refusal -ceq '' -and $writes.Count -eq 3 -and $writes[2] -ceq $resolvedResult -and
          (Get-Content $resolvedResult -Raw | ConvertFrom-Json).execution.outcome -ceq 'PASS') 'PASS result is the final artifact write'
      }
    }
  }

  # Authenticated, synthetic CI fixture. Only the local fixture git object is
  # consulted; the API and download stubs cannot access the network.
  $controller = Join-Path $testRoot 'controller'
  $runtime = Join-Path $controller '.orchestrator'
  [void][IO.Directory]::CreateDirectory($runtime)
  & git -C $controller init --quiet
  & git -C $controller -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m fixture
  if ($LASTEXITCODE -ne 0) { throw 'fixture git commit failed' }
  $head = (& git -C $controller rev-parse HEAD).Trim()
  $tree = (& git -C $controller rev-parse 'HEAD^{tree}').Trim()
  $raw = [Text.Encoding]::UTF8.GetBytes('CI log')
  $prior = @{controllerHead=$head;inventory=@();results=@();
    ci=@{runId='12345';runnerHead=('b'*40);checkoutHead=('a'*40);productSha=('c'*40)};
    rawLog=@{sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant();byteLength=$raw.Length}}
  $receipt = [Text.Encoding]::UTF8.GetBytes(($prior | ConvertTo-Json -Depth 10 -Compress))
  $zipPath = Join-Path $testRoot 'source.zip'
  $zip = [IO.Compression.ZipArchive]::new([IO.File]::Create($zipPath), [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($entry in @(@{name='final.json';bytes=$receipt}, @{name='controller-ci.log';bytes=$raw})) {
      $stream = $zip.CreateEntry($entry.name).Open()
      try { $stream.Write($entry.bytes) } finally { $stream.Dispose() }
    }
  } finally { $zip.Dispose() }
  $digest = 'sha256:' + (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
  function Swap-CiRoot {
    [IO.Directory]::Move($ciRoot, ($ciRoot + '-saved'))
    [void](New-Item -ItemType Junction -Path $ciRoot -Target $ciOutside)
    $script:swapped = $true
  }
  function Get-BatteryCiApi([string]$Endpoint) {
    switch -CaseSensitive ($Endpoint) {
      'actions/runs/12345' { return @{id=12345;status='completed';repository=@{full_name='chase-sets/chase-sets-controller'};
        head_repository=@{full_name='chase-sets/chase-sets-controller'};path='.github/workflows/controller-battery.yml';
        head_branch='main';event='push';head_sha=('b'*40)} }
      ('compare/' + ('b'*40) + '...main') { return @{status='identical'} }
      'actions/runs/12345/artifacts?per_page=100' { return @{total_count=1;artifacts=@(@{id=67890;name='controller-battery-result';expired=$false;
        workflow_run=@{id=12345;head_sha=('b'*40)};digest=$digest})} }
      ('git/commits/' + ('a'*40)) {
        if ($mode -ceq 'snapshot-swap') { Swap-CiRoot }
        return @{sha=('a'*40);parents=@();tree=@{sha=$tree};message="Source-Controller-Head: $head"}
      }
      default { throw "unexpected API: $Endpoint" }
    }
  }
  function Save-BatteryCiArtifact([string]$ArtifactId, [string]$Path) {
    $script:downloadPath = $Path
    if ($mode -ceq 'download-swap') { Swap-CiRoot }
    [IO.File]::Copy($zipPath, $Path, $true)
  }
  function Invoke-BatteryArtifactWriteSeam([string]$Path) {
    if ($Path.EndsWith('.zip')) { $script:archiveSeam = $true }
    if ($Path.EndsWith('.import.json')) { $script:importSeam = $true }
    if ($mode -ceq 'import-swap' -and $Path.EndsWith('.import.json')) { Swap-CiRoot }
    if (($mode -ceq 'archive-collision' -and $Path.EndsWith('.zip')) -or
        ($mode -ceq 'import-collision' -and $Path.EndsWith('.import.json'))) {
      $script:collisionPath = $Path
      [IO.File]::WriteAllText($Path, 'collision-sentinel')
    }
  }
  $physicalRuntime = $runtime
  $runtimeLink = Join-Path $testRoot 'runtime-link'
  [void](New-Item -ItemType Junction -Path $runtimeLink -Target $physicalRuntime)
  foreach ($mode in @('valid', 'physical-root', 'download-swap', 'snapshot-swap', 'import-swap', 'archive-collision', 'import-collision', 'bad-digest')) {
    Test-Control "ci-$mode" {
      $runtime = if ($mode -ceq 'physical-root') { $runtimeLink } else { $physicalRuntime }
      $ciRoot = Join-Path $physicalRuntime 'artifacts'
      $ciOutside = Join-Path $testRoot "outside-$mode"
      [void][IO.Directory]::CreateDirectory($ciOutside)
      [void][IO.Directory]::CreateDirectory($ciRoot)
      $script:swapped = $script:archiveSeam = $script:importSeam = $false
      $script:downloadPath = $script:collisionPath = ''
      $goodDigest = $digest
      if ($mode -ceq 'bad-digest') { $digest = 'sha256:' + ('0'*64) }
      try {
        $import = $null; $message = ''
        try { $import = Import-BatteryCiPrior $prior $receipt } catch { $message = $_.Exception.Message }
        if ($mode -cin @('valid', 'physical-root')) {
          Assert-Test ($message -ceq '' -and $archiveSeam -and $importSeam) 'both retained artifacts use anchored write seams'
          Assert-Test ((Split-Path -Parent $import.artifactPath) -ceq $ciRoot -and
            (Get-FileHash $import.artifactPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $goodDigest.Substring(7) -and
            [IO.File]::Exists([IO.Path]::ChangeExtension($import.artifactPath, '.import.json'))) 'verified archive and import JSON retained under physical root'
        } elseif ($mode -clike '*swap') {
          $escaped = @(Get-ChildItem -LiteralPath $ciOutside -Force)
          Write-Output "CONTROL 215 ci-$mode swapped=$swapped refusal=$message escaped=$($escaped.Count) names=$($escaped.Name -join ',')"
          Assert-Test ($swapped -and $message -ceq 'FAIL controller-release-battery: CI_ARTIFACT_PATH_INVALID' -and
            $escaped.Count -eq 0) 'swap refused without even one escaped file'
        } elseif ($mode -clike '*collision') {
          Assert-Test ($collisionPath -ne '' -and $message -ceq 'FAIL controller-release-battery: CI_ARTIFACT_PATH_INVALID' -and
            [IO.File]::ReadAllText($collisionPath) -ceq 'collision-sentinel') 'CreateNew refuses existing archive/import without truncation or deletion'
        } else {
          Assert-Test ($message -ceq 'CI_DIGEST_MISMATCH' -and @(Get-ChildItem $ciRoot -Force).Count -eq 0) 'digest verified before artifact writes'
        }
        Assert-Test ($downloadPath -ne '' -and -not $downloadPath.StartsWith($ciRoot, [StringComparison]::OrdinalIgnoreCase) -and
          -not [IO.File]::Exists($downloadPath)) 'download is outside artifact root and cleaned on every exit'
      } finally {
        $digest = $goodDigest
        if ($swapped) {
          [IO.Directory]::Delete($ciRoot, $false)
          [IO.Directory]::Move(($ciRoot + '-saved'), $ciRoot)
        }
        # Only fixture-owned children, after restoring any swapped junction.
        Get-ChildItem -LiteralPath $ciRoot -Force | Remove-Item -Force
      }
    }
  }
  [IO.Directory]::Delete($runtimeLink, $false)
  if ($failures.Count) { throw "write-edge controls failed: $($failures -join ',')" }
  Write-Output 'PASS battery write-edge controls'
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') -or
      (Split-Path -Leaf $resolved) -notlike 'battery-write-edges-*') { throw 'unsafe write-edge cleanup' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
