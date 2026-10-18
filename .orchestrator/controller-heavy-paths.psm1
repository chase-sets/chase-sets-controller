Set-StrictMode -Version Latest

function Test-ControllerHeavyPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)
  $normalized = $Path.Replace('\', '/')
  # Include the classifier and installer themselves: changing the guard must
  # never qualify for its own non-heavy exemption. Ownership/admission callers
  # without those words in their names are explicit below.
  $normalized -imatch 'heavy|verify|admission|ownership|(^|/)(install-controller-skills\.ps1|controller-install-lock\.psm1|dispatch-lane\.ps1|lane-stall-watchdog[^/]*|lease[^/]*|integration-dispatch-contract\.ps1|controller-release-battery\.ps1|invoke-fleet-exclusive-gate\.ps1)$'
}

function Get-ControllerHeavyInstallDelta {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ContainerRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$InstalledHead,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$CandidateHead
  )
  $start = [Diagnostics.ProcessStartInfo]::new('git')
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($argument in @('-C', $ContainerRoot, 'diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', $InstalledHead, $CandidateHead, '--')) {
    $start.ArgumentList.Add($argument)
  }
  $process = [Diagnostics.Process]::Start($start)
  try {
    $output = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
      $process.Kill()
      $process.WaitForExit()
      throw 'controller heavy classification refused: git diff expired'
    }
    if ($process.ExitCode -ne 0) { throw 'controller heavy classification refused: installed-to-candidate diff unreadable' }
    $paths = @($output.GetAwaiter().GetResult().Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
    $heavyPaths = @($paths | Where-Object { Test-ControllerHeavyPath -Path $_ })
    [pscustomobject]@{
      installedHead = $InstalledHead
      candidateHead = $CandidateHead
      classification = if ($heavyPaths.Count) { 'heavy' } else { 'non-heavy' }
      heavyPaths = $heavyPaths
    }
  } finally {
    $process.Dispose()
  }
}

function Get-ControllerInstalledHeavyDelta {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$ContainerRoot,
    [Parameter(Mandatory)][string]$DestinationRoot,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$CandidateHead
  )
  $identity = Get-Content -LiteralPath (Join-Path $DestinationRoot 'native-db/identity.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  if (@($identity.PSObject.Properties.Name).Count -ne 2 -or
      $identity.head -isnot [string] -or $identity.head -cnotmatch '^[a-f0-9]{40}$' -or
      $identity.digest -isnot [string] -or $identity.digest -cnotmatch '^[a-f0-9]{64}$' -or
      (Get-FileHash -LiteralPath (Join-Path $DestinationRoot 'native-db/admission.py') -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $identity.digest) {
    throw 'controller heavy classification refused: installed helper identity invalid'
  }
  Get-ControllerHeavyInstallDelta -ContainerRoot $ContainerRoot -InstalledHead $identity.head -CandidateHead $CandidateHead
}

Export-ModuleMember -Function Test-ControllerHeavyPath, Get-ControllerHeavyInstallDelta, Get-ControllerInstalledHeavyDelta
