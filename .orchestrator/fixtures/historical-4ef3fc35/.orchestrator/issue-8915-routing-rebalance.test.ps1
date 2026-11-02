$ErrorActionPreference = 'Stop'
$routingPath = Join-Path $PSScriptRoot 'controller-skills/model-routing/SKILL.md'
$matrixPath = Join-Path $PSScriptRoot 'controller-skills/model-routing/capability-matrix.json'
$referencePath = Join-Path $PSScriptRoot 'controller-skills/model-routing/references/benchmark-rebalance-20261006.md'

function Assert-8915([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL issue-8915: $Message" }
}

function Assert-CurrentRowSelections([string]$Skill, $Matrix) {
  $rows = @([regex]::Matches($Skill, '(?m)^\| (\d+) \|([^\r\n]+)'))
  Assert-8915 ($rows.Count -eq 15) 'expected exactly 15 routing rows'
  $seen = @{}
  foreach ($row in $rows) {
    $number = [int]$row.Groups[1].Value
    Assert-8915 ($number -ge 1 -and $number -le 15 -and -not $seen.ContainsKey($number)) 'duplicate or invalid row'
    $seen[$number] = $true
    $cells = $row.Value.Split('|')
    Assert-8915 ($cells.Count -eq 7) "row $number needs task, default, fallback and governing benchmark"
    foreach ($column in @(3, 4)) {
      $ids = @([regex]::Matches($cells[$column], '(?<![a-z0-9.-])((?:gpt|claude)-[a-z0-9.-]+/[a-z]+)(?![a-z0-9.-])'))
      Assert-8915 ($ids.Count -gt 0) "row $number column $column lacks an exact configuration"
      foreach ($id in $ids) {
        $config = @($Matrix.configs | Where-Object id -CEQ $id.Groups[1].Value)
        Assert-8915 ($config.Count -eq 1) "unknown configuration $($id.Groups[1].Value)"
        Assert-8915 (-not $config[0].historicalOnly -and $config[0].selectable -cne $false -and
          $config[0].model -cnotin @($Matrix.retiredModels)) "historicalOnly selection $($id.Groups[1].Value)"
      }
    }
    Assert-8915 ($cells[5].Trim().Length -gt 12) "row $number lacks governing benchmark"
  }
}

$skill = [IO.File]::ReadAllText($routingPath)
$matrix = Get-Content $matrixPath -Raw | ConvertFrom-Json
Assert-CurrentRowSelections $skill $matrix
Write-Output 'GREEN issue-8915: every default/fallback resolves to a current exact configuration'

# Exercise both selection columns, not merely the retired roster's flags.
foreach ($column in @(3, 4)) {
  $lines = $skill -split "`n"
  $index = [Array]::FindIndex($lines, [Predicate[string]]{ param($line) $line.StartsWith('| 1 |') })
  $cells = $lines[$index].Split('|')
  # Unquoted exact IDs must be caught too; formatting cannot hide a retired route.
  $cells[$column] = ' gpt-5.6-luna/low '
  $lines[$index] = $cells -join '|'
  $failure = $null
  try { Assert-CurrentRowSelections ($lines -join "`n") $matrix } catch { $failure = $_.Exception.Message }
  Assert-8915 ($failure -like '*historicalOnly selection gpt-5.6-luna/low*') "negative control column $column failed to reject retired config: $failure"
  Write-Output "RED negative control: historicalOnly column $column rejected"
}
$mutant = $matrix | ConvertTo-Json -Depth 100 | ConvertFrom-Json
($mutant.configs | Where-Object id -CEQ 'gpt-6-luna/low') | Add-Member -NotePropertyName historicalOnly -NotePropertyValue $true -Force
$failure = $null
try { Assert-CurrentRowSelections $skill $mutant } catch { $failure = $_.Exception.Message }
Assert-8915 ($failure -like '*historicalOnly selection gpt-6-luna/low*') 'negative control must reject a current ID newly marked historicalOnly'

$snapshot = $matrix.benchmarkRebalance20261006
Assert-8915 ($snapshot.fetchedAt -ceq '2026-10-06' -and $snapshot.basis -match 'v4.3.2') 'dated current benchmark snapshot missing'
Assert-8915 ($snapshot.sources.Count -eq 12 -and @($snapshot.sources | Where-Object { $_.fetchedAt -cne '2026-10-06' -or $_.httpStatus -ne 200 -or $_.sha256 -cnotmatch '^[a-f0-9]{64}$' }).Count -eq 0) 'source fetch identity missing'
$ids = @($snapshot.configurations.id)
Assert-8915 ($ids.Count -eq 29 -and @($ids | Sort-Object -Unique).Count -eq 29) 'exact-effort snapshot roster drift'
foreach ($config in @($matrix.configs | Where-Object { -not $_.historicalOnly })) {
  Assert-8915 ($config.id -cin $ids) "selectable configuration lacks coverage: $($config.id)"
}
foreach ($row in $snapshot.configurations) {
  Assert-8915 ($row.source -cin $snapshot.sources.url -and $row.indexIsEstimated -ceq $false) "source or measured public index flag missing: $($row.id)"
  foreach ($metric in @('index','terminalBench4Percent','gdpval','aaLcr','omniscience','weightedApiUsdPerTaskEstimate','weightedOutputTokensPerTask','timePerTaskSeconds','firstAnswerTokenSeconds')) {
    Assert-8915 (($null -eq $row.$metric) -eq ($metric -cin $row.notPublished)) "missing metric must explicitly say not published: $($row.id)/$metric"
  }
  Assert-8915 (($row.id.StartsWith('claude-')) -eq $row.defaultProviderFallback) 'provider-fallback limitation lost'
}
Assert-8915 ($snapshot.officialModels.Count -eq 6 -and @($snapshot.officialModels | Where-Object { $_.exactEffortBenchmark -notlike 'not published*' }).Count -eq 0) 'official overview limitations missing'
$reference = [IO.File]::ReadAllText($referencePath)
Assert-8915 ($reference.Contains('USD/run is unknown') -and $reference.Contains('override-Todd')) 'proxy/run distinction or placement label lost'
Write-Output 'PASS issue-8915 snapshot coverage, source identities, missing metrics and non-measured placement'

function Get-8915Hash([string]$Text) {
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

# Pins captured from installed baseline 7b897d16, not regenerated from the candidate.
# Normalize only checkout newline representation; every rule character is pinned.
$normalized = $skill.Replace("`r`n", "`n")
foreach ($pin in @(
  @('upper-tier', '### Upper-tier authorship requirements', 'Keep row 1 on Luna 6', '28cebadca5e6d3a73ba4d87c3bcbae48222380c7f485a8356fa87b346a3515e5'),
  @('review-history', 'Prefer a fully independent reviewer:', 'Review each new configuration at 20', 'd1383e333a888615c0d3cdbbc2c526049d8ebb0a12a88e96048a1d7245995db3'),
  @('spend', '## Spend telemetry', '## Fable availability reserve', '342098efc94d8a9444b61be1c03948a098513de5e94832d5691a2e0852bcdd55'),
  @('reserve and concurrency', '## Fable availability reserve', '## Challenger quotas and rebalance', '9d16e8350d7fe42fbe485db8ce624bdc33a9371df77c2382fb5ced8356c3b460'),
  @('closed watchdog', 'The watchdog stays closed-table', '### September 23 benchmark rebalance', 'ca1b74eae7e7ebd6988de3c30b75a604ec63b35b5460bdb698c186dfa3cd65d7'),
  @('vendor recovery', 'An Opus low/medium placement requires admission', 'Prefer a fully independent reviewer:', 'ff6f36efa09a9f5a82ab75f6a5dbbb2a168efc15eba316117ca56ecf8c1a6755')
)) {
  $start = $normalized.IndexOf($pin[1], [StringComparison]::Ordinal)
  $end = $normalized.IndexOf($pin[2], $start, [StringComparison]::Ordinal)
  Assert-8915 ($start -ge 0 -and $end -gt $start) "missing protected section $($pin[0])"
  $section = $normalized.Substring($start, $end - $start)
  Assert-8915 ((Get-8915Hash $section) -ceq $pin[3]) "protected baseline rule changed: $($pin[0])"
  Assert-8915 ((Get-8915Hash ($section + ' weakened')) -cne $pin[3]) "protected-rule negative control $($pin[0])"
}
foreach ($pin in @(
  @('benchmarkRebalance20260929', '05462b33b072179d92d41d03c086849f25288f80fbf35d424aec2e70b385c25b'),
  @('configs', 'f8e3dc5b9a0dc06f4084ae9f939ce52eec08c76911660badd5a1dc76612a074d'),
  @('dimensions', 'c6e5280555c0e380bd36fbb0bf1465c0be78f919fdab62dff527e4e7fd8ef8fd'),
  @('measuredAt', '2293049f7af9862019682772bf8f9908967c32a27a3f70d0dde36390fa58d511')
)) {
  Assert-8915 ((Get-8915Hash ($matrix.($pin[0]) | ConvertTo-Json -Depth 100 -Compress)) -ceq $pin[1]) "historical/generated evidence changed: $($pin[0])"
}
Write-Output 'PASS issue-8915 protected baseline rules, historical snapshot and generated evidence unchanged'
