[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Load only artifact functions, never admission or live battery state.
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-release-battery.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'battery parse failed' }
foreach ($name in @('Stop-Battery', 'Assert-BatteryArtifactPath', 'Initialize-BatteryArtifactNative', 'Write-BatteryArtifact', 'Confirm-BatteryArtifactWrite')) {
  $definition = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq $name })
  if ($definition.Count -ne 1) { throw "missing artifact function: $name" }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('battery-artifact-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$assertions = 0
function Assert-Test([bool]$Value, [string]$Message) {
  $script:assertions++
  if (-not $Value) { throw "ASSERTION FAILED: $Message" }
}
function Assert-Refusal([scriptblock]$Action, [string]$Message) {
  $refused = $false
  try { & $Action } catch { $refused = $_.Exception.Message -ceq 'FAIL controller-release-battery: ARTIFACT_TEST_REFUSED' }
  Assert-Test $refused $Message
}
try {
  $root = Join-Path $testRoot 'artifacts'
  $outside = Join-Path $testRoot 'outside'
  [void][IO.Directory]::CreateDirectory($outside)
  $bytes = [Text.Encoding]::UTF8.GetBytes('retained')
  $file = Join-Path $root 'nested/evidence.txt'
  Write-BatteryArtifact $root $root 'ARTIFACT_TEST_REFUSED' -Directory
  Write-BatteryArtifact $root $file 'ARTIFACT_TEST_REFUSED' $bytes -CreateNew
  Confirm-BatteryArtifactWrite $root $file 'ARTIFACT_TEST_REFUSED'
  Assert-Test ([IO.File]::ReadAllText($file) -ceq 'retained') 'nested CreateNew bytes'
  Assert-Refusal { Write-BatteryArtifact $root $file 'ARTIFACT_TEST_REFUSED' @() -CreateNew } 'CreateNew refuses existing evidence'
  Assert-Test ([IO.File]::ReadAllText($file) -ceq 'retained') 'CreateNew never truncates'
  Write-BatteryArtifact $root $file 'ARTIFACT_TEST_REFUSED' ([Text.Encoding]::UTF8.GetBytes('x'))
  Assert-Test ([IO.File]::ReadAllText($file) -ceq 'x') 'output overwrite truncates only the checked handle'
  Assert-Refusal { Write-BatteryArtifact $root ($file + ':stream') 'ARTIFACT_TEST_REFUSED' $bytes } 'ADS refused'
  Assert-Refusal { Write-BatteryArtifact $root (Join-Path $outside 'escape.txt') 'ARTIFACT_TEST_REFUSED' $bytes } 'outside path refused'

  # Deterministic check -> swap -> open, with no post-write check to rescue it.
  foreach ($directory in @($false, $true)) {
    $path = Join-Path $root $(if ($directory) { 'nested/created/child' } else { 'nested/escaped.txt' })
    [void](Assert-BatteryArtifactPath $root $path 'ARTIFACT_TEST_REFUSED')
    [IO.Directory]::Move((Join-Path $root 'nested'), (Join-Path $root 'saved'))
    [void](New-Item -ItemType Junction -Path (Join-Path $root 'nested') -Target $outside)
    try {
      Assert-Refusal { Write-BatteryArtifact $root $path 'ARTIFACT_TEST_REFUSED' $bytes -Directory:$directory } "descendant junction swap directory=$directory"
      Assert-Test (@(Get-ChildItem -LiteralPath $outside -Force).Count -eq 0) "no escaped entries directory=$directory"
    } finally {
      [IO.Directory]::Delete((Join-Path $root 'nested'), $false)
      [IO.Directory]::Move((Join-Path $root 'saved'), (Join-Path $root 'nested'))
    }
  }
  $victim = Join-Path $outside 'victim.txt'
  [IO.File]::WriteAllText($victim, 'outside-sentinel')
  $leaf = Join-Path $root 'leaf.txt'
  [void](Assert-BatteryArtifactPath $root $leaf 'ARTIFACT_TEST_REFUSED')
  [void](New-Item -ItemType SymbolicLink -Path $leaf -Target $victim)
  try {
    Assert-Refusal { Write-BatteryArtifact $root $leaf 'ARTIFACT_TEST_REFUSED' $bytes } 'leaf symlink is checked before truncation'
    Assert-Test ([IO.File]::ReadAllText($victim) -ceq 'outside-sentinel') 'outside symlink target unchanged'
  } finally { [IO.File]::Delete($leaf) }

  # A swap after the protected handle closes is still a loud refusal. Keep the
  # original detect-after-write line independently tested as a second defense.
  [IO.Directory]::Move($root, ($root + '-saved'))
  [void](New-Item -ItemType Junction -Path $root -Target $outside)
  try {
    Assert-Refusal { Confirm-BatteryArtifactWrite $root $file 'ARTIFACT_TEST_REFUSED' } 'post-write path recheck retained'
    $confirm = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Confirm-BatteryArtifactWrite' })[0].Extent.Text
    . ([scriptblock]::Create($confirm.Replace('  [void](Assert-BatteryArtifactPath $Root $Path $Code)', '  # recheck removed')))
    $red = $false
    try { Assert-Refusal { Confirm-BatteryArtifactWrite $root $file 'ARTIFACT_TEST_REFUSED' } 'removed recheck must fail' } catch { $red = $_.Exception.Message.Contains('ASSERTION FAILED: removed recheck') }
    Assert-Test $red 'post-write recheck removal is RED'
    Write-Output 'MUTANT 211 post-write-recheck-removed RED: completed-write root swap was not refused'
  } finally {
    [IO.Directory]::Delete($root, $false)
    [IO.Directory]::Move(($root + '-saved'), $root)
  }

  # Inject a synchronous callback at the native boundary after root was opened.
  # The callback tries to rename that already checked root. A handle without
  # delete protection lets it succeed, so the same verdict kills that mutant.
  $initializer = @($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -ceq 'Initialize-BatteryArtifactNative' })[0].Extent.Text
  foreach ($mutant in @($false, $true)) {
    $variant = if ($mutant) { 'ArtifactUnpinned' } else { 'ArtifactPinned' }
    $native = $initializer.Replace('BatteryArtifactWriter', $variant)
    $native = $native.Replace('        handles.Add(parent);' + "`r`n" + '        for (int i=0;', '        handles.Add(parent);' + "`r`n" + '        try { Directory.Move(root, root + "-moved"); throw new Exception("PIN_REMOVED"); } catch (IOException) {}' + "`r`n" + '        for (int i=0;')
    if ($mutant) {
      $native = $native.Replace('directory ? 1u : 0u', 'directory ? 7u : 0u').Replace('CreateFileW(nativeParent, 0x100081, 1,', 'CreateFileW(nativeParent, 0x100081, 7,')
    }
    . ([scriptblock]::Create($native))
    Initialize-BatteryArtifactNative
    $type = "ChaseSets.$variant" -as [type]
    $variantRoot = Join-Path $testRoot $variant
    $red = $false
    try { $type::Write($variantRoot, (Join-Path $variantRoot 'value.txt'), $bytes, $false, $false) }
    catch { $red = $_.Exception.ToString().Contains('PIN_REMOVED'); if (-not $red) { throw } }
    Assert-Test ($red -eq $mutant) "opened directory rename protection mutant=$mutant"
    if ($mutant) { Write-Output 'MUTANT 211 directory-delete-sharing RED: checked root renamed while descendant open was pending' }
  }
  Write-Output "PASS battery artifact native no-follow controls assertions=$assertions"
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  if ((Split-Path -Parent $resolved).TrimEnd('\', '/') -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') -or (Split-Path -Leaf $resolved) -notlike 'battery-artifact-*') { throw 'unsafe artifact test cleanup' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
