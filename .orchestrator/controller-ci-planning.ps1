function Get-CiSourceDigest([string]$Path) {
  $text = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
  return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}

function Read-CiTimingProfile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $profile = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 40 -DateKind String
    if ($profile.schemaVersion -cne 'controller-ci-durations/v1') { return $null }
    return $profile
  } catch { return $null }
}

function Get-CiEstimatedDuration($Item, $Profile, [string]$Root, [datetimeoffset]$Now) {
  if ($null -ne $Item.restriction) { return @{elapsedMs=0L;source='local-only'} }
  $fallback = @{elapsedMs=30000L;source='fallback'}
  if ($null -eq $Profile) { return $fallback }
  $records = @($Profile.records | Where-Object identity -CEQ $Item.identity)
  if ($records.Count -ne 1) { return $fallback }
  $record = $records[0]
  try {
    $age = $Now - [datetimeoffset]::Parse($record.recordedAtUtc, [Globalization.CultureInfo]::InvariantCulture)
    if ($age.TotalDays -lt 0 -or $age.TotalDays -gt 30 -or
        ($record.elapsedMs -isnot [long] -and $record.elapsedMs -isnot [int]) -or $record.elapsedMs -le 0 -or
        $record.sourceSha256 -cnotmatch '^[a-f0-9]{64}$') { return $fallback }
    $source = Join-Path $Root $Item.path
    if ((Get-CiSourceDigest $source) -cne $record.sourceSha256) { return @{elapsedMs=[long]$record.elapsedMs;source='stale-recorded'} }
    return @{elapsedMs=[long]$record.elapsedMs;source='recorded'}
  } catch { return $fallback }
}

function New-CiExecutionItems([object[]]$Inventory, $Manifest, $Profile, [string]$Root, [datetimeoffset]$Now) {
  Assert-Ci ($null -eq $Manifest -or $Manifest.schemaVersion -ceq 'controller-ci-parts/v1') 'parts manifest schema mismatch'
  $tasks = [Collections.Generic.List[object]]::new()
  $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($item in $Inventory) {
    $timing = Get-CiEstimatedDuration $item $Profile $Root $Now
    $mapping = @($Manifest.items | Where-Object identity -CEQ $item.identity)
    Assert-Ci ($mapping.Count -le 1) 'duplicate split mapping'
    if ($mapping.Count -eq 0 -or $null -ne $item.restriction) {
      $task = $item | Select-Object *
      $task | Add-Member requiredIdentity $item.identity -Force
      $task | Add-Member estimatedMs $timing.elapsedMs -Force
      $task | Add-Member timingSource $timing.source -Force
      $tasks.Add($task)
      Assert-Ci ($seen.Add($task.identity)) 'duplicate execution identity'
      continue
    }
    $split = $mapping[0]
    Assert-Ci ($split.selector -cin @('-Arm','-Part') -and @($split.parts).Count -gt 1) 'invalid split selector/parts'
    $weight = 0L
    foreach ($part in $split.parts) {
      Assert-Ci ($part.name -cmatch '^[a-z][a-z-]*$' -and
        ($part.weight -is [long] -or $part.weight -is [int]) -and $part.weight -gt 0) 'invalid split name/weight'
      $weight += $part.weight
    }
    foreach ($part in $split.parts) {
      $id = "$($item.identity)#$($part.name)"
      Assert-Ci ($seen.Add($id)) 'duplicate execution identity'
      $partTiming = Get-CiEstimatedDuration ([pscustomobject]@{identity=$id;path=$item.path;restriction=$null}) $Profile $Root $Now
      $estimate = [long][Math]::Ceiling($timing.elapsedMs * ([double]$part.weight / $weight))
      $timingSource = $timing.source + '-split-estimate'
      if ($partTiming.source -ceq 'recorded') { $estimate=$partTiming.elapsedMs; $timingSource='recorded-part' }
      $tasks.Add([pscustomobject]@{identity=$id;requiredIdentity=$item.identity;path=$item.path;command=$item.command
        arguments=@($item.arguments) + @($split.selector,$part.name);restriction=$item.restriction
        estimatedMs=$estimate;timingSource=$timingSource})
    }
  }
  return ,@($tasks)
}

function Set-CiBalancedShards([object[]]$Tasks) {
  # Ordinal identity breaks equal-duration ties independently of locale and input order.
  $order = [Collections.Generic.List[object]]::new()
  foreach ($task in $Tasks) { $order.Add($task) }
  $order.Sort([Comparison[object]]{
    param($a,$b)
    $duration = ([long]$b.estimatedMs).CompareTo([long]$a.estimatedMs)
    if ($duration -ne 0) { return $duration }
    return [StringComparer]::Ordinal.Compare([string]$a.identity,[string]$b.identity)
  })
  $loads = [long[]]::new(10)
  foreach ($task in $order) {
    $shard = 0
    for ($i=1; $i -lt 10; $i++) { if ($loads[$i] -lt $loads[$shard]) { $shard=$i } }
    $task | Add-Member shard $shard -Force
    $loads[$shard] += $task.estimatedMs
  }
  return ,@($order)
}

function ConvertTo-CiRequiredResults($Plan, [object[]]$Results) {
  if ($null -eq $Plan.executionItems) { return ,$Results }
  $merged = [Collections.Generic.List[object]]::new()
  foreach ($required in $Plan.selected) {
    $tasks = @($Plan.executionItems | Where-Object requiredIdentity -CEQ $required.identity)
    Assert-Ci ($tasks.Count -gt 0) 'required item has no execution mapping'
    $rows = @($Results | Where-Object { $_.identity -cin @($tasks.identity) })
    Assert-Ci ($rows.Count -eq $tasks.Count) 'required item has missing parts'
    if ($tasks.Count -eq 1 -and $tasks[0].identity -ceq $required.identity) { $merged.Add($rows[0]); continue }
    Assert-Ci (@($rows | Where-Object result -CEQ 'LOCAL_ONLY').Count -eq 0) 'split exclusion forbidden'
    $failed = @($rows | Where-Object result -CEQ 'FAIL')
    $merged.Add([pscustomobject]@{identity=$required.identity;exitCode=$(if($failed.Count){$failed[0].exitCode}else{0})
      result=$(if($failed.Count){'FAIL'}else{'PASS'});fleetLoad='none';elapsedMs=[long](($rows | Measure-Object elapsedMs -Sum).Sum)
      startedUtc=($rows.startedUtc | Sort-Object | Select-Object -First 1)
      finishedUtc=($rows.finishedUtc | Sort-Object | Select-Object -Last 1)
      provenance=@{kind='execution';command=$required.command;attempt="github-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT-split"
        parts=@($rows | Select-Object identity,provenance)}})
  }
  Assert-Ci (@($Results | Where-Object { $_.identity -cnotin @($Plan.executionItems.identity) }).Count -eq 0) 'unmapped execution result'
  return ,@($merged | Sort-Object identity)
}
