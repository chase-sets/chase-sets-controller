# Named -Part partitions of the two dominant hosted controller suites (#9272).
# Each key names one original case, mutant or gated region of the suite, and
# exactly one part owns it. The default -Part all runs every key, so default,
# legacy selector and mutant child self-call behavior is unchanged.
$SuitePartOwners = @{
  'dispatch-routing-data' = [ordered]@{
    'cases-core' = @('case:policy','case:current','case:admission','case:explicit','case:lkg','case:evidence','case:ledger-readers')
    'cases-capacity' = @('case:capacity-shadow','case:capacity-active','case:capacity-validation','case:capacity-history',
      'case:capacity-override','case:capacity-exemptions','case:capacity-logger')
    'capacity-matrix' = @('case:capacity-matrix')
    'routing-mutants' = @('routing-mutants')
    'capacity-mutants-flip' = @('capacity-mutant:override-omission','capacity-mutant:non-prefix-flip','capacity-mutant:shadow-applied',
      'capacity-mutant:own-row-effort','capacity-mutant:nested-validator-omitted')
    'capacity-mutants-history' = @('capacity-mutant:drop-generic-author','capacity-mutant:drop-patched-reviewer',
      'capacity-mutant:partial-history-admitted','capacity-mutant:duplicate-author-erased','capacity-mutant:unknown-history-admitted',
      'capacity-mutant:reviewer-exclusion-omitted')
    'capacity-mutants-validity' = @('capacity-mutant:duration-omitted','capacity-mutant:digest-omitted','capacity-mutant:mode-omitted',
      'capacity-mutant:format-omitted','capacity-mutant:object-omitted','capacity-mutant:provider-state-omitted')
    'capacity-mutants-bounds' = @('capacity-mutant:stale-omitted','capacity-mutant:unknown-omitted','capacity-mutant:steps-integer-omitted',
      'capacity-mutant:toward-presence-omitted','capacity-mutant:steps-upper-omitted','capacity-mutant:steps-lower-omitted',
      'capacity-mutant:instant-syntax-omitted')
  }
  'cleanup-orphan-worktree-dirs' = [ordered]@{
    'synthetic' = @('synthetic')
    'batched-authority' = @('batched-authority')
    'mutants' = @('mutants')
    'baseline-equivalence' = @('baseline-equivalence')
    'scale' = @('scale')
    'native' = @('native')
  }
}

function Get-SuitePartNames([string]$Suite) {
  if (-not $SuitePartOwners.ContainsKey($Suite)) { throw "SUITE_PART: unknown suite $Suite" }
  return @($SuitePartOwners[$Suite].Keys)
}

function Get-SuitePartOwner([string]$Suite, [string]$Key) {
  $owners = @(foreach ($part in Get-SuitePartNames $Suite) { if ($SuitePartOwners[$Suite][$part] -ccontains $Key) { $part } })
  if ($owners.Count -ne 1) { throw "SUITE_PART: $Suite key $Key has $($owners.Count) owners" }
  return $owners[0]
}

function Test-SuitePart([string]$Suite, [string]$Part, [string]$Key) {
  # Resolve the owner even for -Part all, so a broken map can never pass silently.
  $owner = Get-SuitePartOwner $Suite $Key
  return ($Part -ceq 'all' -or $Part -ceq $owner)
}

function Confirm-SuitePartSelection([string]$Suite, [string]$Part, [bool]$LegacySelector) {
  if ($Part -ceq 'all') { return }
  if ($LegacySelector) { throw 'Named parts cannot be combined with legacy selectors' }
  if ($Part -cnotin (Get-SuitePartNames $Suite)) { throw "Unknown $Suite part: $Part" }
}
