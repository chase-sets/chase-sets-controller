$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'controller-heavy-paths.psm1') -Force -DisableNameChecking
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}
function Assert-HeavyFiles {
  foreach ($file in @(
    'invoke-heavy-verifier.ps1', 'native-db-admission.py', 'heavy-slot.cjs',
    'heavy-nested-client.cjs', 'heavy-nested-owner.cs', 'heavy-admission-preload.cjs',
    'heavy-admission-holder-launcher.cjs', 'dispatch-ownership.ps1', 'fleet-exclusive-admission.psm1', 'invoke-fleet-exclusive-gate.ps1',
    'lane-admission.ps1', 'lane-admission-v1.schema.json', 'lane-admission-collected-input-v1.schema.json',
    'install-controller-skills.ps1', 'controller-install-lock.psm1', 'controller-heavy-paths.psm1',
    'dispatch-lane.ps1', 'lane-stall-watchdog.ps1', 'lane-stall-watchdog-batch.ps1',
    'lease.ps1', 'lease-contract.psm1', 'integration-dispatch-contract.ps1',
    'controller-release-battery.ps1', 'verify-lock.d/owner.json', 'controller-verify-lock.d/owner.json',
    'contracts/heavy-lane-admission.md'
  )) {
    Assert-True (Test-ControllerHeavyPath ".orchestrator/$file") "heavy classifier must include $file"
    Assert-True (Test-ControllerHeavyPath ".orchestrator\$file") "heavy classifier normalizes backslashes for $file"
  }
}
Assert-HeavyFiles
foreach ($file in @('.orchestrator/velocity-metrics.ps1', '.orchestrator/controller-skills/milestone-orchestrator/SKILL.md', 'README.md')) {
  Assert-True (-not (Test-ControllerHeavyPath $file)) "non-heavy classifier excludes $file"
}
$sandbox = Join-Path ([IO.Path]::GetTempPath()) "controller-heavy-paths-$([guid]::NewGuid().ToString('N'))"
try {
  [void][IO.Directory]::CreateDirectory($sandbox)
  & git -C $sandbox init -q -b main
  & git -C $sandbox config user.email 'heavy-path-test@example.invalid'
  & git -C $sandbox config user.name 'Synthetic heavy classifier test'
  [IO.File]::WriteAllText((Join-Path $sandbox 'heavy-slot.cjs'), 'synthetic heavy')
  [void][IO.Directory]::CreateDirectory((Join-Path $sandbox '.orchestrator'))
  $fleetGate = Join-Path $sandbox '.orchestrator/invoke-fleet-exclusive-gate.ps1'
  [IO.File]::WriteAllText($fleetGate, '# synthetic fleet gate baseline')
  & git -C $sandbox add heavy-slot.cjs .orchestrator/invoke-fleet-exclusive-gate.ps1
  & git -C $sandbox commit -q -m 'baseline'
  $baseline = (& git -C $sandbox rev-parse HEAD).Trim()
  [IO.File]::WriteAllText((Join-Path $sandbox 'README.md'), 'non-heavy')
  & git -C $sandbox add README.md
  & git -C $sandbox commit -q -m 'non-heavy'
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  $delta = Get-ControllerHeavyInstallDelta -ContainerRoot $sandbox -InstalledHead $baseline -CandidateHead $head
  Assert-True ($delta.classification -ceq 'non-heavy') 'installed-to-candidate non-heavy diff'
  $fleetBaseline = $head
  Add-Content -LiteralPath $fleetGate -Value '# synthetic fleet gate revision'
  & git -C $sandbox add .orchestrator/invoke-fleet-exclusive-gate.ps1
  & git -C $sandbox commit -q -m 'modify only synthetic fleet gate'
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  $delta = Get-ControllerHeavyInstallDelta -ContainerRoot $sandbox -InstalledHead $fleetBaseline -CandidateHead $head
  Assert-True ($delta.classification -ceq 'heavy' -and $delta.heavyPaths.Count -eq 1 -and $delta.heavyPaths -ccontains '.orchestrator/invoke-fleet-exclusive-gate.ps1') 'fleet-gate-only modification is heavy and lists its path'
  & git -C $sandbox mv heavy-slot.cjs renamed.cjs
  & git -C $sandbox commit -q -m 'rename heavy file'
  $head = (& git -C $sandbox rev-parse HEAD).Trim()
  $delta = Get-ControllerHeavyInstallDelta -ContainerRoot $sandbox -InstalledHead $baseline -CandidateHead $head
  Assert-True ($delta.classification -ceq 'heavy' -and $delta.heavyPaths -ccontains 'heavy-slot.cjs') 'rename cannot hide the removed heavy path'
  $unreadableRejected = $false
  try { Get-ControllerHeavyInstallDelta -ContainerRoot $sandbox -InstalledHead ('0' * 40) -CandidateHead $head | Out-Null } catch {
    $unreadableRejected = $_.Exception.Message -match 'diff unreadable'
  }
  Assert-True $unreadableRejected 'unreadable baseline cannot become non-heavy'
  $modulePath = Join-Path $PSScriptRoot 'controller-heavy-paths.psm1'
  $text = [IO.File]::ReadAllText($modulePath)
  $mutant = $text.Replace("  `$normalized -imatch", "  if (`$normalized -ieq '.orchestrator/heavy-slot.cjs') { return `$false }`n  `$normalized -imatch")
  Assert-True ($mutant -cne $text) 'classifier omission mutant changes its exact target'
  $mutantPath = Join-Path $sandbox 'mutant.psm1'
  [IO.File]::WriteAllText($mutantPath, $mutant)
  Import-Module $mutantPath -Force -DisableNameChecking
  $mutantRejected = $false
  try { Assert-HeavyFiles } catch { $mutantRejected = $_.Exception.Message -match '^FAIL: heavy classifier must include heavy-slot.cjs' }
  Assert-True $mutantRejected 'heavy path coverage kills omitted-heavy-file mutant'
  Write-Output 'PASS controller heavy paths: protected inventory, non-heavy exclusion, rename/delete classification, unreadable history fail closed, omission mutant killed'
} finally {
  # This unique root was created by this test; never sweep unrelated temp files.
  if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}
