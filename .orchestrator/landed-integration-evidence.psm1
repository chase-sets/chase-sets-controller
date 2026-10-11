# Completion is execution evidence, never review or landing authority. The
# runtime directory is the existing trusted controller store. Hashes bind bytes;
# they do not authenticate an administrator who can rewrite that store.
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')

function Get-RebaseHash([byte[]]$Bytes) {
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function ConvertTo-RebaseCanonical($Value) {
  if ($null -eq $Value) { return 'null' }
  if ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) {
    $names = if ($Value -is [Collections.IDictionary]) { [string[]]@($Value.Keys) } else { [string[]]@($Value.PSObject.Properties.Name) }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return '{' + (@($names | ForEach-Object { ($_ | ConvertTo-Json -Compress) + ':' + (ConvertTo-RebaseCanonical $Value.$_) }) -join ',') + '}'
  }
  if ($Value -is [array]) { return '[' + (@($Value | ForEach-Object { ConvertTo-RebaseCanonical $_ }) -join ',') + ']' }
  return ConvertTo-Json -InputObject $Value -Compress -Depth 30
}
function Get-RebaseRecordIdentity($Value) { Get-RebaseHash ([Text.Encoding]::UTF8.GetBytes((ConvertTo-RebaseCanonical $Value))) }
function Get-RebaseObligationIdentity($Value) {
  # owed/v1's original property order and spelling are part of its identity.
  Get-RebaseHash ([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Compress)))
}
function Assert-RebaseKeys($Value, [string[]]$Keys) {
  $names = if ($Value -is [Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
  if ($null -eq $Value -or $names.Count -ne $Keys.Count -or @($Keys | Where-Object { $_ -cnotin $names }).Count) { throw 'OWED_REBASE_PROOF_INVALID: closed object' }
}
function Read-RebaseJson([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'OWED_REBASE_PROOF_MISSING: JSON record' }
  ConvertFrom-RebaseJson ([IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false,$true)))
}
function ConvertFrom-RebaseJson([string]$raw) {
  try {
    $doc = [Text.Json.JsonDocument]::Parse($raw)
    function Assert-UniqueJson($Element) {
      if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $Element.EnumerateObject()) {
          if (-not $seen.Add($p.Name)) { throw 'duplicate key' }
          Assert-UniqueJson $p.Value
        }
      } elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) { foreach ($e in $Element.EnumerateArray()) { Assert-UniqueJson $e } }
    }
    try { Assert-UniqueJson $doc.RootElement } finally { $doc.Dispose() }
    return $raw | ConvertFrom-Json -DateKind String -Depth 30 -ErrorAction Stop
  } catch { throw "OWED_REBASE_PROOF_INVALID: JSON ($($_.Exception.Message))" }
}
function Assert-RebaseInstant($Value) {
  if ($Value -isnot [string] -or $Value -cnotmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$' -or -not (Test-DispatchUtcIdentity $Value)) { throw 'OWED_REBASE_PROOF_INVALID: instant' }
}
function Assert-RebaseSha($Value, [int]$Length=40) {
  if ($Value -isnot [string] -or $Value -cnotmatch "^[a-f0-9]{$Length}$") { throw 'OWED_REBASE_PROOF_INVALID: hash' }
}
function Assert-RebaseObligation($Value) {
  Assert-RebaseKeys $Value @('schemaVersion','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane')
  if ($Value.schemaVersion -cne 'landed-integration-owed/v1' -or -not (Test-DispatchJsonInteger $Value.landedPr 1) -or -not (Test-DispatchJsonInteger $Value.pr 1) -or
    $Value.branch -isnot [string] -or $Value.integrationLane -isnot [string] -or $Value.worktree -isnot [string] -or
    $Value.branch -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,255}$' -or $Value.integrationLane -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or -not (Test-DispatchFullyQualifiedPath $Value.worktree)) { throw 'OWED_REBASE_PROOF_INVALID: obligation' }
  foreach ($key in @('landedHead','targetHead','newBase')) { Assert-RebaseSha $Value.$key }
}
function Assert-RebaseOwner($Owner, $Obligation, [string]$Runtime, [switch]$Prelaunch) {
  Assert-RebaseKeys $Owner @('launchId','recordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','laneRole','identityMode','branch','worktree','head')
  if ($Owner.launchId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or
    -not (Test-DispatchSamePath $Owner.recordPath (Join-Path $Runtime "dispatch-launch-$($Owner.launchId).json")) -or
    -not (Test-DispatchJsonInteger $Owner.launcherPid 1) -or $Owner.laneRole -cne 'implementation' -or $Owner.identityMode -cne 'branch' -or
    $Owner.branch -cne $Obligation.branch -or -not (Test-DispatchSamePath $Owner.worktree $Obligation.worktree)) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED' }
  Assert-RebaseSha $Owner.head
  Assert-RebaseInstant $Owner.launcherStartIdentity
  if ($Prelaunch -and $null -eq $Owner.childPid -and $null -eq $Owner.childStartIdentity) { return }
  if (-not (Test-DispatchJsonInteger $Owner.childPid 1) -or $Owner.childPid -eq $Owner.launcherPid) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: child' }
  Assert-RebaseInstant $Owner.childStartIdentity
  if ([datetimeoffset]$Owner.childStartIdentity -lt [datetimeoffset]$Owner.launcherStartIdentity) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: causal start' }
}
function ConvertTo-RebaseOwner($Record, [string]$Path) {
  [ordered]@{launchId=$Record.launchId;recordPath=[IO.Path]::GetFullPath($Path);launcherPid=[long]$Record.launcherPid;launcherStartIdentity=$Record.launcherStartIdentity;childPid=$Record.childPid;childStartIdentity=$Record.childStartIdentity;laneRole=$Record.laneRole;identityMode=$Record.identityMode;branch=$Record.branch;worktree=$Record.worktree;head=$Record.head}
}
function Get-RebaseProcessChain {
  $chain = [Collections.Generic.List[object]]::new(); $id = $PID
  $seen = [Collections.Generic.HashSet[int]]::new()
  while ($id -gt 0) {
    if (-not $seen.Add($id)) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: process cycle' }
    $rows = @(Get-CimInstance Win32_Process -Filter "ProcessId = $id" -ErrorAction Stop)
    if ($rows.Count -ne 1) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: process unknown' }
    $start = Get-DispatchProcessStartIdentity $id
    if (-not $start) {
      if ($chain.Count -eq 0) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: start unknown' }
      break
    }
    if ($chain.Count -and [datetimeoffset]$start -gt [datetimeoffset]$chain[$chain.Count-1].start) { break } # A reused parent PID is an exited parent (#8103): the chain ends here.
    $chain.Add([pscustomobject]@{id=$id;start=$start})
    $id = [int]$rows[0].ParentProcessId
    # A parent may have exited. It cannot be used as authority beyond this point.
    if ($id -gt 0 -and -not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { break }
  }
  return @($chain)
}
function Assert-RebaseProducerProcess([string]$Runtime) {
  $chain = @(Get-RebaseProcessChain)
  foreach ($file in @(Get-ChildItem -LiteralPath $Runtime -Filter 'dispatch-launch-*.json' -File)) {
    $record = Get-ValidatedDispatchOwnershipRecord $file.FullName $Runtime ([IO.Path]::GetTempPath())
    if ($null -eq $record) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: unknown ownership' }
    if (@($chain | Where-Object { ($_.id -eq $record.childPid -and $_.start -ceq $record.childStartIdentity) -or ($_.id -eq $record.launcherPid -and $_.start -ceq $record.launcherStartIdentity) }).Count -and $record.laneRole -cne 'implementation') { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: observer' }
  }
}
function Get-RebaseAuthenticatedOwner($Obligation, [string]$Runtime, [string]$RecordPath, [ValidateSet('Child','Launcher','Prelaunch')][string]$Phase, [switch]$ProductCensus) {
  $evaluate = {
  param($budget)
  Assert-RebaseProducerProcess $Runtime
  $productObligation = $false
  $budget.watch.Restart()
  $anchors = @{}
  if ($ProductCensus) {
    try {
      $container = Get-DispatchCanonicalExistingPath (Split-Path -Parent $Runtime)
      $worktree = Get-DispatchCanonicalExistingPath $Obligation.worktree
      $product = Get-ProductCensusRepository (Join-Path $container 'main') $budget
      $anchors.product = $product
      $target = Get-ProductCensusRepository $worktree $budget
      $productObligation = (Test-DispatchSameCanonicalPath $target.topLevel $worktree) -and
        (Test-DispatchSameCanonicalPath $target.commonDir $product.commonDir)
    } catch {
      if ($_.Exception.Message -ceq 'git-deadline') { throw }
      $productObligation = $false
    }
  }
  $records = @()
  $examined = 0
  foreach ($file in @(Get-ChildItem -LiteralPath $Runtime -Filter 'dispatch-launch-*.json' -File)) {
    $examined++
    $record = Get-ValidatedDispatchOwnershipRecord $file.FullName $Runtime ([IO.Path]::GetTempPath())
    if ($null -eq $record) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: unknown ownership' }
    if ($record.branch -ceq $Obligation.branch -and (Get-DispatchProcessIdentityState $record.launcherPid $record.launcherStartIdentity) -ceq 'live') {
      if ($productObligation -and $examined -le 64 -and $record.schemaVersion -in @(4,5)) {
        $seat = Get-DispatchCanonicalExistingPath $record.worktree
        if ($seat -and (Split-Path -Leaf $seat) -ceq $record.lane -and
            -not (Test-DispatchSameCanonicalPath (Split-Path -Parent $seat) $container)) {
          $proof = Test-ProductCensusPlatformSeat $seat $record $container $budget $anchors
          if ($proof.reason -ceq 'git-deadline') { throw 'git-deadline' }
          if ($proof.proven) { continue }
        }
      }
      $records += [pscustomobject]@{record=$record;path=$file.FullName}
    }
  }
  if ($records.Count -ne 1 -or ($RecordPath -and -not (Test-DispatchSamePath $RecordPath $records[0].path))) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: unique owner' }
  $owner = ConvertTo-RebaseOwner $records[0].record $records[0].path
  Assert-RebaseOwner $owner $Obligation $Runtime -Prelaunch:($Phase -eq 'Prelaunch')
  if ($Phase -eq 'Child') {
    $chain = @(Get-RebaseProcessChain)
    if ((Get-DispatchProcessIdentityState $owner.childPid $owner.childStartIdentity) -cne 'live' -or
      @($chain | Where-Object { $_.id -eq $owner.childPid -and $_.start -ceq $owner.childStartIdentity }).Count -ne 1 -or
      @($chain | Where-Object { $_.id -eq $owner.launcherPid -and $_.start -ceq $owner.launcherStartIdentity }).Count -ne 1) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: actual child tree' }
  } else {
    if ($PID -ne $owner.launcherPid -or (Get-DispatchProcessStartIdentity $PID) -cne $owner.launcherStartIdentity) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: actual launcher' }
    if ($Phase -eq 'Launcher' -and (Get-DispatchProcessIdentityState $owner.childPid $owner.childStartIdentity) -cne 'dead') { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: child still owns work' }
    if ($Phase -eq 'Launcher') {
      if (Get-Process -Id $owner.childPid -ErrorAction SilentlyContinue) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: reused child PID' }
      $possibleChildren=@(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($owner.childPid)" -ErrorAction Stop)
      foreach ($child in $possibleChildren) {
        $childStart=Get-DispatchProcessStartIdentity ([int]$child.ProcessId)
        if (-not $childStart -or [datetimeoffset]$childStart -ge [datetimeoffset]$owner.childStartIdentity) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: possible live child' }
      }
    }
  }
  return $owner
  }
  # Same 5000 ms/evaluation, one deadline-only retry as the ownership census.
  # Re-read producer/owner/process/phase/Git proof and fresh anchors on retry.
  # Strict interrupted/unscoped callers do not receive this allowance.
  try {
    if ($ProductCensus) { return Invoke-ProductCensusEvaluation $evaluate }
    return & $evaluate @{watch=[Diagnostics.Stopwatch]::new();deadline=5000}
  } catch {
    if ($_.Exception.Message -ceq 'git-deadline') { throw 'OWED_REBASE_PRODUCT_CENSUS_GIT_DEADLINE' }
    throw
  }
}
function Write-RebaseBytes([string]$Path, [byte[]]$Bytes) {
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    if ((Get-RebaseHash ([IO.File]::ReadAllBytes($Path))) -cne (Get-RebaseHash $Bytes)) { throw 'OWED_REBASE_PROOF_AMBIGUOUS: immutable record' }
    return
  }
  $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
  try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Write-RebaseRecord([string]$Path, $Value) { Write-RebaseBytes $Path ([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Compress -Depth 30))) }
function Save-RebaseBytes([string]$Runtime, [byte[]]$Bytes) {
  $hash = Get-RebaseHash $Bytes
  Write-RebaseBytes (Join-Path $Runtime "integration-rebase-bytes-$hash.bin") $Bytes
  return $hash
}
function Read-RebaseBytes([string]$Runtime, [string]$Hash) {
  Assert-RebaseSha $Hash 64
  $path = Join-Path $Runtime "integration-rebase-bytes-$Hash.bin"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'OWED_REBASE_PROOF_MISSING: retained bytes' }
  $bytes = [IO.File]::ReadAllBytes($path)
  if ((Get-RebaseHash $bytes) -cne $Hash) { throw 'OWED_REBASE_PROOF_INVALID: retained bytes' }
  return ,$bytes
}
function Invoke-RebaseEvidenceGit([string]$Worktree,[string[]]$Arguments,[string]$GitExecutable='git',[switch]$Empty) {
  $output = @(& $GitExecutable -C $Worktree @Arguments 2>&1); $code = $LASTEXITCODE
  $text = ($output -join "`n").Trim()
  if ($code -ne 0 -or ($Empty -and $text)) { throw "OWED_REBASE_PROOF_INVALID: git $($Arguments[0]) exit=$code output=$text" }
  return $text
}
function Get-RebaseLogBytes([string]$Worktree,[string]$Ref) {
  $path = Get-RebaseGitPath $Worktree "logs/$Ref"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'OWED_REBASE_PROOF_MISSING: native reflog' }
  return ,[IO.File]::ReadAllBytes($path)
}
function Get-RebaseGitPath([string]$Worktree,[string]$Name,[string]$GitExecutable='git') {
  $path=Invoke-RebaseEvidenceGit $Worktree @('rev-parse','--git-path',$Name) $GitExecutable
  if ([string]::IsNullOrWhiteSpace($path) -or $path.Contains("`n")) { throw 'OWED_REBASE_PROOF_INVALID: git path' }
  if (-not [IO.Path]::IsPathFullyQualified($path)) { $path=Join-Path $Worktree $path }
  return [IO.Path]::GetFullPath($path)
}
function ConvertFrom-RebaseLog([byte[]]$Bytes) {
  $raw = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
  $rows = @()
  foreach ($line in @($raw -split "`n" | Where-Object { $_ })) {
    $m = [regex]::Match($line,'^(?<old>[a-f0-9]{40}) (?<new>[a-f0-9]{40}) .+ <[^>]*> (?<seconds>[0-9]+) [+-][0-9]{4}\t(?<message>[^\r\n]+)$')
    if (-not $m.Success) { throw 'OWED_REBASE_PROOF_INVALID: native reflog shape' }
    $rows += [pscustomobject]@{old=$m.Groups['old'].Value;new=$m.Groups['new'].Value;seconds=[long]$m.Groups['seconds'].Value;message=$m.Groups['message'].Value}
  }
  return $rows
}
function Get-RebaseOwed([string]$Runtime,[string]$Branch,[string]$Worktree) {
  foreach ($file in @(Get-ChildItem -LiteralPath $Runtime -Filter 'integration-owed-*.json' -File | Where-Object { $_.Name -notlike 'integration-owed-ack-*' -and $_.Name -notlike 'integration-owed-accept-*' })) {
    $o = Read-RebaseJson $file.FullName; Assert-RebaseObligation $o
    if ($o.branch -cne $Branch) { continue }
    if (-not (Test-DispatchSamePath $o.worktree $Worktree)) { throw 'OWED_REBASE_PROOF_INVALID: worktree' }
    $o
  }
}
function Get-RebaseCurrentOwedHash($Obligation,[string]$Runtime) {
  $path=Join-Path $Runtime "integration-owed-$($Obligation.pr)-$($Obligation.landedHead.Substring(0,12)).json"
  $current=Read-RebaseJson $path; Assert-RebaseObligation $current
  if ((Get-RebaseObligationIdentity $current) -cne (Get-RebaseObligationIdentity $Obligation)) { throw 'OWED_REBASE_PROOF_INVALID: current owed changed' }
  return Get-RebaseHash ([IO.File]::ReadAllBytes($path))
}
function New-RebaseStart($Obligation,[string]$Runtime,[string]$RecordPath,[switch]$Prelaunch) {
  Assert-RebaseObligation $Obligation
  $owedHash=Get-RebaseCurrentOwedHash $Obligation $Runtime
  $owner = Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath $(if($Prelaunch){'Prelaunch'}else{'Child'}) -ProductCensus
  $identity = Get-RebaseObligationIdentity $Obligation
  $phase = if ($Prelaunch) { 'prelaunch' } else { 'start' }
  $path = Join-Path $Runtime "integration-rebase-$phase-$identity-$($owner.launchId).json"
  $head = Invoke-RebaseEvidenceGit $Obligation.worktree @('rev-parse','HEAD'); Assert-RebaseSha $head
  [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base','--is-ancestor',$Obligation.targetHead,$head) -Empty)
  if ((Invoke-RebaseEvidenceGit $Obligation.worktree @('branch','--show-current')) -cne $Obligation.branch) { throw 'OWED_REBASE_RESULT_MISMATCH: attached branch' }
  $oldBase = Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base',$head,$Obligation.newBase); Assert-RebaseSha $oldBase
  $bytes = Get-RebaseLogBytes $Obligation.worktree "refs/heads/$($Obligation.branch)"
  $hash = Save-RebaseBytes $Runtime $bytes
  if (Test-Path -LiteralPath $path -PathType Leaf) {
    $existing = Read-RebaseJson $path
    if ($existing.predecessorHead -cne $head -or $existing.obligationIdentity -cne $identity -or (Get-RebaseRecordIdentity $existing.executionOwner) -cne (Get-RebaseRecordIdentity $owner) -or $existing.branchReflogBefore.sha256 -cne $hash) { throw 'OWED_REBASE_PROOF_AMBIGUOUS: start already moved' }
    return $existing
  }
  $start = [ordered]@{schemaVersion='landed-integration-rebase-start/v1';obligation=$Obligation;obligationIdentity=$identity;executionOwner=$owner;predecessorHead=$head;oldBase=$oldBase;startedAt=[datetimeoffset]::UtcNow.ToString('o');branchReflogBefore=[ordered]@{sha256=$hash;recordCount=@(ConvertFrom-RebaseLog $bytes).Count}}
  if ((Get-RebaseCurrentOwedHash $Obligation $Runtime) -cne $owedHash) { throw 'OWED_REBASE_PROOF_INVALID: owed bytes changed' }
  Write-RebaseRecord $path $start
  return $start
}
function Save-RebaseConflict($Start,[string]$Runtime) {
  $o = $Start.obligation
  $dir = Get-RebaseGitPath $o.worktree 'rebase-merge'
  $values = @{}
  foreach ($key in @('orig-head','onto','head-name')) {
    $p = Join-Path $dir $key
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw 'OWED_REBASE_PROOF_MISSING: native conflict' }
    $values[$key] = [IO.File]::ReadAllText($p).Trim()
  }
  if ($values['orig-head'] -cne $Start.predecessorHead -or $values.onto -cne $o.newBase -or $values['head-name'] -cne "refs/heads/$($o.branch)") { throw 'OWED_REBASE_PROOF_INVALID: native conflict' }
  $value = [ordered]@{schemaVersion='landed-integration-rebase-conflict/v1';startIdentity=(Get-RebaseRecordIdentity $Start);origHead=$values['orig-head'];onto=$values.onto;headName=$values['head-name'];capturedAt=[datetimeoffset]::UtcNow.ToString('o')}
  Write-RebaseRecord (Join-Path $Runtime "integration-rebase-conflict-$($Start.obligationIdentity)-$($Start.executionOwner.launchId).json") $value
}
function Assert-RebaseStart($Start,$Obligation,[string]$Runtime) {
  Assert-RebaseKeys $Start @('schemaVersion','obligation','obligationIdentity','executionOwner','predecessorHead','oldBase','startedAt','branchReflogBefore')
  Assert-RebaseObligation $Start.obligation
  if ($Start.schemaVersion -cne 'landed-integration-rebase-start/v1' -or $Start.obligationIdentity -cne (Get-RebaseObligationIdentity $Obligation) -or (Get-RebaseObligationIdentity $Start.obligation) -cne $Start.obligationIdentity) { throw 'OWED_REBASE_PROOF_INVALID: start binding' }
  Assert-RebaseOwner $Start.executionOwner $Obligation $Runtime
  Assert-RebaseSha $Start.predecessorHead; Assert-RebaseSha $Start.oldBase; Assert-RebaseInstant $Start.startedAt
  Assert-RebaseKeys $Start.branchReflogBefore @('sha256','recordCount')
  $before = Read-RebaseBytes $Runtime $Start.branchReflogBefore.sha256
  if (-not (Test-DispatchJsonInteger $Start.branchReflogBefore.recordCount 1) -or @(ConvertFrom-RebaseLog $before).Count -ne $Start.branchReflogBefore.recordCount -or [datetimeoffset]$Start.startedAt -lt [datetimeoffset]$Start.executionOwner.childStartIdentity) { throw 'OWED_REBASE_PROOF_INVALID: before movement' }
}
function Get-RebaseNativeProof($Obligation,[string]$Predecessor,[string]$Result,[string]$OldBase,[datetimeoffset]$Earliest,[datetimeoffset]$Latest,[byte[]]$BranchBytes,[byte[]]$HeadBytes) {
  $branchRows = @(ConvertFrom-RebaseLog $BranchBytes); $headRows = @(ConvertFrom-RebaseLog $HeadBytes)
  $finishMessage = '^rebase(?: \(continue\))? \(finish\): refs/heads/' + [regex]::Escape($Obligation.branch) + ' onto ' + $Obligation.newBase + '$'
  $finish = @($branchRows | Where-Object { $_.old -ceq $Predecessor -and $_.new -ceq $Result -and $_.message -cmatch $finishMessage -and $_.seconds -ge $Earliest.ToUnixTimeSeconds() -and $_.seconds -le $Latest.ToUnixTimeSeconds() })
  if ($finish.Count -eq 0) { throw 'OWED_REBASE_PROOF_MISSING: native predecessor to result' }
  if ($finish.Count -ne 1) { throw 'OWED_REBASE_PROOF_AMBIGUOUS: native finish' }
  if ($branchRows[-1].old -cne $Predecessor -or $branchRows[-1].new -cne $Result -or $branchRows[-1].message -cnotmatch $finishMessage) { throw 'OWED_REBASE_PROOF_INVALID: movement after completion' }
  $starts = @(); $ends = @()
  for ($i=0; $i -lt $headRows.Count; $i++) {
    $r = $headRows[$i]
    if ($r.old -ceq $Predecessor -and $r.new -ceq $Obligation.newBase -and $r.message -ceq "rebase (start): checkout $($Obligation.newBase)" -and $r.seconds -ge $Earliest.ToUnixTimeSeconds() -and $r.seconds -le $finish[0].seconds) { $starts += $i }
    if ($r.new -ceq $Result -and $r.message -cmatch ('^rebase(?: \(continue\))? \(finish\): returning to refs/heads/' + [regex]::Escape($Obligation.branch) + '$') -and $r.seconds -eq $finish[0].seconds) { $ends += $i }
  }
  if ($starts.Count -ne 1 -or $ends.Count -ne 1 -or $starts[0] -ge $ends[0]) { throw 'OWED_REBASE_PROOF_AMBIGUOUS: native start/finish' }
  for ($i=$starts[0]+1; $i -le $ends[0]; $i++) {
    if ($headRows[$i].old -cne $headRows[$i-1].new -or $headRows[$i].message -cnotmatch '^rebase(?: \(continue\))? \((pick|continue|finish)\):') { throw 'OWED_REBASE_PROOF_INVALID: unrelated movement' }
  }
  [ordered]@{oldBase=$OldBase;branchOldHead=$Predecessor;branchNewHead=$Result;onto=$Obligation.newBase;branchReflogHash=(Get-RebaseHash $BranchBytes);headReflogHash=(Get-RebaseHash $HeadBytes);startedAt=[datetimeoffset]::FromUnixTimeSeconds($headRows[$starts[0]].seconds).ToString('o');finishedAt=[datetimeoffset]::FromUnixTimeSeconds($finish[0].seconds).ToString('o')}
}
function Assert-RebaseResult($Obligation,[string]$Result,[string]$Tree,[string]$GitExecutable='git',[switch]$Replay) {
  foreach ($sha in @($Obligation.landedHead,$Obligation.targetHead,$Obligation.newBase,$Result)) { [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('cat-file','-e',"$sha^{commit}") $GitExecutable -Empty) }
  $head = Invoke-RebaseEvidenceGit $Obligation.worktree @('rev-parse','HEAD') $GitExecutable; Assert-RebaseSha $head
  if ($Replay) { [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base','--is-ancestor',$Result,$head) $GitExecutable -Empty) }
  elseif ($head -cne $Result) { throw 'OWED_REBASE_RESULT_MISMATCH: current result' }
  if ((Invoke-RebaseEvidenceGit $Obligation.worktree @('rev-parse',"$Result^{tree}") $GitExecutable) -cne $Tree -or (Invoke-RebaseEvidenceGit $Obligation.worktree @('branch','--show-current') $GitExecutable) -cne $Obligation.branch) { throw 'OWED_REBASE_RESULT_MISMATCH: tree/branch' }
  [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base','--is-ancestor',$Obligation.newBase,$Result) $GitExecutable -Empty)
  if (-not $Replay) {
    [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('status','--porcelain=v1','--untracked-files=normal') $GitExecutable -Empty)
    [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('ls-files','-u') $GitExecutable -Empty)
    foreach ($name in @('rebase-merge','rebase-apply','MERGE_HEAD')) {
      $p = Get-RebaseGitPath $Obligation.worktree $name $GitExecutable
      if (Test-Path -LiteralPath $p) { throw 'OWED_REBASE_RESULT_MISMATCH: unfinished integration' }
    }
  }
}
function Get-RebasePublication($Obligation,[string]$Result) {
  try {
    $repository = Invoke-RebaseEvidenceGit $Obligation.worktree @('remote','get-url','origin')
    $remote = Invoke-RebaseEvidenceGit $Obligation.worktree @('ls-remote','--exit-code','--heads','origin',"refs/heads/$($Obligation.branch)")
    if ($remote -cne "$Result`trefs/heads/$($Obligation.branch)") { throw 'remote mismatch' }
    return [ordered]@{repository=$repository;branch=$Obligation.branch;observedHead=$Result;observedAt=[datetimeoffset]::UtcNow.ToString('o')}
  } catch { throw "OWED_REBASE_PUBLICATION_UNKNOWN: $($_.Exception.Message)" }
}
function Complete-RebaseOwner($Obligation,[string]$Runtime,[string]$RecordPath) {
  $resumeRecord = Get-ValidatedDispatchOwnershipRecord $RecordPath $Runtime ([IO.Path]::GetTempPath())
  if ($resumeRecord -and $resumeRecord.schemaVersion -eq 5) { return Complete-InterruptedIntegration $Obligation $Runtime $RecordPath }
  $identity = Get-RebaseObligationIdentity $Obligation
  $paths = @(Get-ChildItem -LiteralPath $Runtime -Filter "integration-rebase-start-$identity-*.json" -File)
  if ($paths.Count -eq 0) { return $null }
  if ($paths.Count -ne 1) { throw 'OWED_REBASE_PROOF_AMBIGUOUS: starts' }
  $owedHash=Get-RebaseCurrentOwedHash $Obligation $Runtime
  $start = Read-RebaseJson $paths[0].FullName; Assert-RebaseStart $start $Obligation $Runtime
  $owner = Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher -ProductCensus
  if ((Get-RebaseRecordIdentity $owner) -cne (Get-RebaseRecordIdentity $start.executionOwner)) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: release owner' }
  $result = Invoke-RebaseEvidenceGit $Obligation.worktree @('rev-parse','HEAD'); Assert-RebaseSha $result
  if ($result -ceq $start.predecessorHead) { return $null }
  $tree = Invoke-RebaseEvidenceGit $Obligation.worktree @('rev-parse',"$result^{tree}"); Assert-RebaseSha $tree
  Assert-RebaseResult $Obligation $result $tree
  $branchBytes = Get-RebaseLogBytes $Obligation.worktree "refs/heads/$($Obligation.branch)"; $headBytes = Get-RebaseLogBytes $Obligation.worktree 'HEAD'
  $before = Read-RebaseBytes $Runtime $start.branchReflogBefore.sha256
  if ($branchBytes.Length -le $before.Length -or (Get-RebaseHash ([byte[]]$branchBytes[0..($before.Length-1)])) -cne $start.branchReflogBefore.sha256) { throw 'OWED_REBASE_PROOF_INVALID: changed before log' }
  $proof = Get-RebaseNativeProof $Obligation $start.predecessorHead $result $start.oldBase ([datetimeoffset]$start.startedAt) ([datetimeoffset]::UtcNow) $branchBytes $headBytes
  [void](Save-RebaseBytes $Runtime $branchBytes); [void](Save-RebaseBytes $Runtime $headBytes)
  $publication = Get-RebasePublication $Obligation $result
  $completion = [ordered]@{schemaVersion='landed-integration-rebase-complete/v1';obligation=$Obligation;obligationIdentity=$identity;mode='OWNER_RELEASE';executionOwner=$owner;acknowledgingOwner=$owner;startIdentity=(Get-RebaseRecordIdentity $start);recoveryEvidence=$null;predecessorHead=$start.predecessorHead;resultHead=$result;resultTree=$tree;completedAt=[datetimeoffset]::UtcNow.ToString('o');rebaseProof=$proof;publication=$publication}
  [void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher -ProductCensus)
  Assert-RebaseResult $Obligation $result $tree
  if ((Get-RebaseCurrentOwedHash $Obligation $Runtime) -cne $owedHash) { throw 'OWED_REBASE_PROOF_INVALID: owed bytes changed' }
  Write-RebaseRecord (Join-Path $Runtime "integration-rebase-complete-$identity.json") $completion
  return $completion
}

function Get-RebaseRecoveryEvidence($References,$Obligation,[string]$Runtime,[string]$Launch,[string]$Result,[string]$Tree,[switch]$Retained) {
  if ($References -isnot [array] -or $References.Count -ne 5) { throw 'OWED_REBASE_PROOF_MISSING: five causal sources required' }
  $sources = @{}; $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($reference in $References) {
    Assert-RebaseKeys $reference @('path','sha256','recordIdentity')
    Assert-RebaseSha $reference.sha256 64; Assert-RebaseSha $reference.recordIdentity 64
    if (-not (Test-DispatchFullyQualifiedPath $reference.path) -or -not (Test-DispatchSamePath (Split-Path -Parent $reference.path) $Runtime) -or -not $seen.Add($reference.path)) { throw 'OWED_REBASE_PROOF_INVALID: recovery path' }
    if (-not $Retained -and -not (Test-Path -LiteralPath $reference.path -PathType Leaf)) { throw 'OWED_REBASE_PROOF_MISSING: recovery source' }
    $bytes = if ($Retained) { Read-RebaseBytes $Runtime $reference.sha256 } else { [IO.File]::ReadAllBytes($reference.path) }
    if ((Get-RebaseHash $bytes) -cne $reference.sha256) { throw 'OWED_REBASE_PROOF_INVALID: recovery bytes' }
    $text = [Text.UTF8Encoding]::new($false,$true).GetString($bytes)
    $sources[[IO.Path]::GetFullPath($reference.path)] = [pscustomobject]@{reference=$reference;bytes=$bytes;text=$text}
  }
  $watchdogs = @($sources.Values | Where-Object { (Split-Path -Leaf $_.reference.path) -clike 'watchdog-lane-*.json' })
  if ($watchdogs.Count -ne 1) { throw 'OWED_REBASE_PROOF_AMBIGUOUS: watchdog' }
  $wSource=$watchdogs[0]
  # Parse retained documents with the same recursive duplicate-key check.
  if (-not $Retained) { [void](Save-RebaseBytes $Runtime $wSource.bytes) }
  $w=Read-RebaseJson (Join-Path $Runtime "integration-rebase-bytes-$($wSource.reference.sha256).bin")
  $watchdogIdentity=Get-RebaseRecordIdentity $w
  if ($w.schemaVersion -ceq 'watchdog-lane/v3') {
    . (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1')
    Assert-IntegrationRequest $w.integrationRequest
    Assert-IntegrationAuthor $w.harness $w.model $w.effort $w.row $w.placement -HistoricalRead
    if ($w.integrationRequest.label -cne $w.label -or $w.integrationRequest.head -cne $w.head -or
        $w.integrationRequest.branch -cne $w.branch -or -not (Test-DispatchSamePath $w.integrationRequest.worktree $w.worktree)) { throw 'OWED_REBASE_PROOF_INVALID: integration request' }
    $w.PSObject.Properties.Remove('integrationRequest'); $w.schemaVersion='watchdog-lane/v2'
  }
  Assert-RebaseKeys $w @('schemaVersion','label','attemptId','relaunchCount','resumeOfLaunchId','harness','model','effort','row','placement','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','state','exitCode','updatedAt')
  if ($w.schemaVersion -cne 'watchdog-lane/v2' -or $w.launchId -cne $Launch -or $w.head -cne $Obligation.targetHead -or $w.laneRole -cne 'implementation' -or $w.state -cne 'exited' -or $w.exitCode -isnot [long] -or $w.exitCode -ne 0 -or
    $watchdogIdentity -cne $wSource.reference.recordIdentity -or (Split-Path -Leaf $wSource.reference.path) -cne "watchdog-lane-$($w.label).json") { throw 'OWED_REBASE_PROOF_INVALID: executor provenance' }
  $owner=[ordered]@{launchId=$w.launchId;recordPath=$w.ownershipRecordPath;launcherPid=$w.launcherPid;launcherStartIdentity=$w.launcherStartIdentity;childPid=$w.childPid;childStartIdentity=$w.childStartIdentity;laneRole=$w.laneRole;identityMode='branch';branch=$w.branch;worktree=$w.worktree;head=$w.head}
  Assert-RebaseOwner $owner $Obligation $Runtime
  Assert-RebaseInstant $w.updatedAt
  $identity=Get-RebaseObligationIdentity $Obligation
  $acceptPath=[IO.Path]::GetFullPath((Join-Path $Runtime "integration-owed-accept-$identity-$Launch.json"))
  $routingPath=[IO.Path]::GetFullPath((Join-Path $Runtime 'dispatch-log.jsonl'))
  foreach ($path in @($acceptPath,$routingPath,$w.originalPromptPath,$w.partialReportPath)) {
    if (-not $sources.ContainsKey([IO.Path]::GetFullPath($path))) { throw 'OWED_REBASE_PROOF_MISSING: causal source' }
  }
  $acceptSource=$sources[$acceptPath]
  if (-not $Retained) { [void](Save-RebaseBytes $Runtime $acceptSource.bytes) }
  $a=Read-RebaseJson (Join-Path $Runtime "integration-rebase-bytes-$($acceptSource.reference.sha256).bin")
  Assert-RebaseKeys $a @('schemaVersion','obligationIdentity','ownerLaunchId','ownerRecordPath','branch','worktree','ownerPid','ownerStartIdentity','acceptedAt')
  if ($a.schemaVersion -cne 'landed-integration-owed-accept/v1' -or $a.obligationIdentity -cne $identity -or $a.ownerLaunchId -cne $Launch -or -not (Test-DispatchSamePath $a.ownerRecordPath $owner.recordPath) -or $a.branch -cne $Obligation.branch -or -not (Test-DispatchSamePath $a.worktree $Obligation.worktree) -or $a.ownerPid -ne $owner.launcherPid -or $a.ownerStartIdentity -cne $owner.launcherStartIdentity -or (Get-RebaseRecordIdentity $a) -cne $acceptSource.reference.recordIdentity) { throw 'OWED_REBASE_PROOF_INVALID: executor acceptance' }
  Assert-RebaseInstant $a.acceptedAt
  if ([datetimeoffset]$a.acceptedAt -lt [datetimeoffset]$owner.childStartIdentity) { throw 'OWED_REBASE_PROOF_INVALID: acceptance time' }
  $routingSource=$sources[$routingPath]
  $rows=@($routingSource.text -split "\r?\n" | Where-Object { $_ } | ForEach-Object { ConvertFrom-RebaseJson $_ })
  $routes=@($rows | Where-Object { $_.dispatchRoutingSchema -cin @('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3') -and $_.label -ceq $w.label -and $_.attemptId -ceq $w.attemptId })
  if ($routes.Count -ne 1) { throw 'OWED_REBASE_PROOF_AMBIGUOUS: routing' }
  $r=$routes[0]
  Assert-RebaseKeys $r @(Get-DispatchRoutingLedgerKeys $r.dispatchRoutingSchema $r)
  if (-not (Test-DispatchRoutingLedgerEvidence $r)) { throw 'OWED_REBASE_PROOF_INVALID: routing evidence' }
  if ($r.lane -cne (Split-Path -Leaf $owner.worktree)) { throw 'OWED_REBASE_PROOF_INVALID: routing lane' }
  if ($r.kind -cne 'dispatch' -or $r.laneRole -cne 'implementation' -or $r.transcript -cne (Split-Path -Leaf $w.partialReportPath) -or $r.branch -cne $owner.branch -or $r.head -cne $owner.head -or -not (Test-DispatchSamePath $r.worktree $owner.worktree) -or $r.harness -cne $w.harness -or $r.model -cne $w.model -or $r.effort -cne $w.effort -or [string]$r.row -cne [string]$w.row -or $r.placement -cne $w.placement -or (Get-RebaseRecordIdentity $r) -cne $routingSource.reference.recordIdentity) { throw 'OWED_REBASE_PROOF_INVALID: routing join' }
  Assert-RebaseInstant $r.ts
  if ([datetimeoffset]$r.ts -lt [datetimeoffset]$owner.launcherStartIdentity -or [datetimeoffset]$r.ts -gt [datetimeoffset]$owner.childStartIdentity) { throw 'OWED_REBASE_PROOF_INVALID: routing causality' }
  $promptSource=$sources[[IO.Path]::GetFullPath($w.originalPromptPath)]
  if ($promptSource.reference.recordIdentity -cne $promptSource.reference.sha256) { throw 'OWED_REBASE_PROOF_INVALID: prompt identity' }
  foreach ($token in @([string]$Obligation.pr,$Obligation.targetHead,$Obligation.newBase,$Obligation.branch)) {
    if (-not $promptSource.text.Contains($token,[StringComparison]::Ordinal)) { throw 'OWED_REBASE_PROOF_INVALID: prompt binding' }
  }
  $transcriptSource=$sources[[IO.Path]::GetFullPath($w.partialReportPath)]
  if ($transcriptSource.reference.recordIdentity -cne $transcriptSource.reference.sha256) { throw 'OWED_REBASE_PROOF_INVALID: transcript identity' }
  $events=@($transcriptSource.text -split "\r?\n" | Where-Object { $_ } | ForEach-Object { ConvertFrom-RebaseJson $_ })
  $items=@($events | Where-Object { $_.type -ceq 'item.completed' -and $_.item.type -ceq 'command_execution' } | ForEach-Object { $_.item })
  $conflicts=@();$finishes=@();$pushes=@();$probes=@()
  for ($i=0;$i -lt $items.Count;$i++) {
    $item=$items[$i];$output=[string]$item.aggregated_output;$command=[string]$item.command
    if ($item.exit_code -eq 2 -and $command.Contains('rebase-integration.ps1')) {
      foreach ($line in @($output -split "\r?\n" | Where-Object { $_.StartsWith('{') })) {
        try { $v=$line|ConvertFrom-Json -DateKind String -ErrorAction Stop } catch { continue }
        if ($v.schemaVersion -ceq 'rebase-integration-result/v1' -and $v.status -ceq 'DELTA_REQUIRED' -and $v.reason -ceq 'REBASE_CONFLICT' -and $v.pr -eq $Obligation.pr -and $v.reviewedHead -ceq $Obligation.targetHead -and $v.newBase -ceq $Obligation.newBase -and @($v.conflictPaths).Count -gt 0 -and $command.Contains($Obligation.targetHead) -and $command.Contains($Obligation.newBase)) { $conflicts+=$i }
      }
    }
    if ($item.exit_code -eq 0 -and $command.Contains('rebase --continue') -and $output.Contains('RAW_REBASE_CONTINUE_EXIT=0') -and $output.Contains("Successfully rebased and updated refs/heads/$($Obligation.branch).")) { $finishes+=$i }
    if ($item.exit_code -eq 0 -and $command.Contains('git push') -and $command.Contains('--force-with-lease') -and $command.Contains($Obligation.targetHead) -and $command.Contains($Result) -and $command.Contains($Obligation.branch) -and $output.Contains("PREPUSH_HEAD=$Result") -and $output.Contains("PREPUSH_TREE=$Tree") -and $output.Contains("OBSERVED_LS_REMOTE=$($Obligation.targetHead)") -and $output.Contains('RAW_PUSH_EXIT=0')) { $pushes+=$i }
    if ($item.exit_code -eq 0 -and $command.Contains('ls-remote') -and $command.Contains($Obligation.newBase) -and $output.Contains("HEAD=$Result") -and $output.Contains("TREE=$Tree") -and $output.Contains("BRANCH=$($Obligation.branch)") -and $output.Contains("REMOTE_HEAD=$Result") -and $output.Contains('BASE_ANCESTOR_EXIT=0')) { $probes+=$i }
  }
  if ($conflicts.Count -ne 1 -or $finishes.Count -ne 1 -or $pushes.Count -ne 1 -or $probes.Count -ne 1 -or $conflicts[0] -ge $finishes[0] -or $finishes[0] -ge $pushes[0] -or $pushes[0] -ge $probes[0]) { throw 'OWED_REBASE_PROOF_INVALID: transcript causal transition' }
  if (-not $Retained) { foreach ($source in $sources.Values) { [void](Save-RebaseBytes $Runtime $source.bytes) } }
  return [pscustomobject]@{owner=$owner;finishedBy=$w.updatedAt}
}
function Adopt-RebaseCompletion($Obligation,[string]$Runtime,[string]$RecordPath,[string]$RecoveryPath) {
  $owedHash=Get-RebaseCurrentOwedHash $Obligation $Runtime
  $inputValue=Read-RebaseJson $RecoveryPath
  Assert-RebaseKeys $inputValue @('obligationIdentity','executionLaunchId','resultHead','resultTree','evidence')
  if ($inputValue.obligationIdentity -cne (Get-RebaseObligationIdentity $Obligation)) { throw 'OWED_REBASE_PROOF_INVALID: recovery obligation' }
  Assert-RebaseSha $inputValue.resultHead; Assert-RebaseSha $inputValue.resultTree
  $owner=Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Prelaunch -ProductCensus
  if ($null -ne $owner.childPid -or $owner.launchId -ceq $inputValue.executionLaunchId) { throw 'OWED_REBASE_OWNER_UNAUTHORIZED: distinct producer claim' }
  $historical=Get-RebaseRecoveryEvidence $inputValue.evidence $Obligation $Runtime $inputValue.executionLaunchId $inputValue.resultHead $inputValue.resultTree
  if ($owner.head -cne $inputValue.resultHead) { throw 'OWED_REBASE_RESULT_MISMATCH: adoption claim head' }
  Assert-RebaseResult $Obligation $inputValue.resultHead $inputValue.resultTree
  $oldBase=Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base',$Obligation.targetHead,$Obligation.newBase); Assert-RebaseSha $oldBase
  $branchBytes=Get-RebaseLogBytes $Obligation.worktree "refs/heads/$($Obligation.branch)"; $headBytes=Get-RebaseLogBytes $Obligation.worktree 'HEAD'
  $proof=Get-RebaseNativeProof $Obligation $Obligation.targetHead $inputValue.resultHead $oldBase ([datetimeoffset]$historical.owner.childStartIdentity) ([datetimeoffset]$historical.finishedBy) $branchBytes $headBytes
  [void](Save-RebaseBytes $Runtime $branchBytes);[void](Save-RebaseBytes $Runtime $headBytes)
  $publication=Get-RebasePublication $Obligation $inputValue.resultHead
  $completion=[ordered]@{schemaVersion='landed-integration-rebase-complete/v1';obligation=$Obligation;obligationIdentity=$inputValue.obligationIdentity;mode='PRODUCER_ADOPTION';executionOwner=$historical.owner;acknowledgingOwner=$owner;startIdentity=$null;recoveryEvidence=$inputValue.evidence;predecessorHead=$Obligation.targetHead;resultHead=$inputValue.resultHead;resultTree=$inputValue.resultTree;completedAt=[datetimeoffset]::UtcNow.ToString('o');rebaseProof=$proof;publication=$publication}
  [void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Prelaunch -ProductCensus)
  Assert-RebaseResult $Obligation $completion.resultHead $completion.resultTree
  if ((Get-RebaseCurrentOwedHash $Obligation $Runtime) -cne $owedHash) { throw 'OWED_REBASE_PROOF_INVALID: owed bytes changed' }
  Write-RebaseRecord (Join-Path $Runtime "integration-rebase-complete-$($completion.obligationIdentity).json") $completion
  return $completion
}
function Read-RebaseCompletion($Obligation,[string]$Runtime,[string]$GitExecutable='git',[switch]$Replay) {
  $identity=Get-RebaseObligationIdentity $Obligation
  $path=Join-Path $Runtime "integration-rebase-complete-$identity.json"
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $c=Read-RebaseJson $path
  if ($c.schemaVersion -ceq 'landed-integration-rebase-complete/v2') { return Read-InterruptedIntegrationCompletion $c $Obligation $Runtime $GitExecutable -Replay:$Replay }
  Assert-RebaseKeys $c @('schemaVersion','obligation','obligationIdentity','mode','executionOwner','acknowledgingOwner','startIdentity','recoveryEvidence','predecessorHead','resultHead','resultTree','completedAt','rebaseProof','publication')
  Assert-RebaseObligation $c.obligation
  if ($c.schemaVersion -cne 'landed-integration-rebase-complete/v1' -or $c.obligationIdentity -cne $identity -or (Get-RebaseObligationIdentity $c.obligation) -cne $identity -or $c.mode -cnotin @('OWNER_RELEASE','PRODUCER_ADOPTION')) { throw 'OWED_REBASE_PROOF_INVALID: completion binding' }
  Assert-RebaseOwner $c.executionOwner $Obligation $Runtime
  Assert-RebaseOwner $c.acknowledgingOwner $Obligation $Runtime -Prelaunch:($c.mode -ceq 'PRODUCER_ADOPTION')
  foreach ($key in @('predecessorHead','resultHead','resultTree')) { Assert-RebaseSha $c.$key }
  Assert-RebaseInstant $c.completedAt
  Assert-RebaseKeys $c.rebaseProof @('oldBase','branchOldHead','branchNewHead','onto','branchReflogHash','headReflogHash','startedAt','finishedAt')
  foreach ($key in @('oldBase','branchOldHead','branchNewHead','onto')) { Assert-RebaseSha $c.rebaseProof.$key }
  Assert-RebaseInstant $c.rebaseProof.startedAt; Assert-RebaseInstant $c.rebaseProof.finishedAt
  Assert-RebaseKeys $c.publication @('repository','branch','observedHead','observedAt')
  Assert-RebaseInstant $c.publication.observedAt
  if ([string]::IsNullOrWhiteSpace($c.publication.repository) -or $c.publication.branch -cne $Obligation.branch -or $c.publication.observedHead -cne $c.resultHead -or [datetimeoffset]$c.publication.observedAt -gt [datetimeoffset]$c.completedAt -or [datetimeoffset]$c.rebaseProof.finishedAt -gt [datetimeoffset]$c.publication.observedAt -or [datetimeoffset]$c.completedAt -gt [datetimeoffset]::UtcNow -or [datetimeoffset]$c.acknowledgingOwner.launcherStartIdentity -gt [datetimeoffset]$c.completedAt) { throw 'OWED_REBASE_PROOF_INVALID: publication/time binding' }
  $branchBytes=Read-RebaseBytes $Runtime $c.rebaseProof.branchReflogHash; $headBytes=Read-RebaseBytes $Runtime $c.rebaseProof.headReflogHash
  if ($c.mode -ceq 'OWNER_RELEASE') {
    if ($null -ne $c.recoveryEvidence -or (Get-RebaseRecordIdentity $c.executionOwner) -cne (Get-RebaseRecordIdentity $c.acknowledgingOwner)) { throw 'OWED_REBASE_PROOF_INVALID: release authority' }
    $startPath=Join-Path $Runtime "integration-rebase-start-$identity-$($c.executionOwner.launchId).json"
    if (-not (Test-Path -LiteralPath $startPath -PathType Leaf)) { throw 'OWED_REBASE_PROOF_MISSING: start' }
    $s=Read-RebaseJson $startPath; Assert-RebaseStart $s $Obligation $Runtime
    if ((Get-RebaseRecordIdentity $s) -cne $c.startIdentity -or (Get-RebaseRecordIdentity $s.executionOwner) -cne (Get-RebaseRecordIdentity $c.executionOwner) -or $s.predecessorHead -cne $c.predecessorHead -or $s.oldBase -cne $c.rebaseProof.oldBase) { throw 'OWED_REBASE_PROOF_INVALID: start completion join' }
    $before=Read-RebaseBytes $Runtime $s.branchReflogBefore.sha256
    if ($branchBytes.Length -le $before.Length -or (Get-RebaseHash ([byte[]]$branchBytes[0..($before.Length-1)])) -cne $s.branchReflogBefore.sha256) { throw 'OWED_REBASE_PROOF_INVALID: retained prefix' }
    $conflictPath=Join-Path $Runtime "integration-rebase-conflict-$identity-$($c.executionOwner.launchId).json"
    $nativeConflict=@(ConvertFrom-RebaseLog $branchBytes)[-1].message.Contains('(continue)')
    if ($nativeConflict -and -not (Test-Path -LiteralPath $conflictPath -PathType Leaf)) { throw 'OWED_REBASE_PROOF_MISSING: native conflict capture' }
    if (Test-Path -LiteralPath $conflictPath -PathType Leaf) {
      $conflict=Read-RebaseJson $conflictPath
      Assert-RebaseKeys $conflict @('schemaVersion','startIdentity','origHead','onto','headName','capturedAt')
      Assert-RebaseInstant $conflict.capturedAt
      if ($conflict.schemaVersion -cne 'landed-integration-rebase-conflict/v1' -or $conflict.startIdentity -cne $c.startIdentity -or $conflict.origHead -cne $c.predecessorHead -or $conflict.onto -cne $Obligation.newBase -or $conflict.headName -cne "refs/heads/$($Obligation.branch)" -or [datetimeoffset]$conflict.capturedAt -lt [datetimeoffset]$s.startedAt -or ([datetimeoffset]$conflict.capturedAt).ToUnixTimeSeconds() -gt ([datetimeoffset]$c.rebaseProof.finishedAt).ToUnixTimeSeconds()) { throw 'OWED_REBASE_PROOF_INVALID: conflict capture binding' }
    }
    $earliest=[datetimeoffset]$s.startedAt; $latest=[datetimeoffset]$c.completedAt
  } else {
    if ($null -ne $c.startIdentity -or $c.executionOwner.launchId -ceq $c.acknowledgingOwner.launchId -or $null -ne $c.acknowledgingOwner.childPid -or $c.predecessorHead -cne $Obligation.targetHead -or $c.acknowledgingOwner.head -cne $c.resultHead) { throw 'OWED_REBASE_PROOF_INVALID: adoption authority' }
    $historical=Get-RebaseRecoveryEvidence $c.recoveryEvidence $Obligation $Runtime $c.executionOwner.launchId $c.resultHead $c.resultTree -Retained
    if ((Get-RebaseRecordIdentity $historical.owner) -cne (Get-RebaseRecordIdentity $c.executionOwner) -or [datetimeoffset]$historical.finishedBy -ge [datetimeoffset]$c.completedAt) { throw 'OWED_REBASE_PROOF_INVALID: adoption causality' }
    $earliest=[datetimeoffset]$historical.owner.childStartIdentity; $latest=[datetimeoffset]$historical.finishedBy
  }
  $proof=Get-RebaseNativeProof $Obligation $c.predecessorHead $c.resultHead $c.rebaseProof.oldBase $earliest $latest $branchBytes $headBytes
  if ((Get-RebaseRecordIdentity $proof) -cne (Get-RebaseRecordIdentity $c.rebaseProof)) { throw 'OWED_REBASE_PROOF_INVALID: native proof binding' }
  [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base','--is-ancestor',$Obligation.targetHead,$c.predecessorHead) $GitExecutable -Empty)
  [void](Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base','--is-ancestor',$c.executionOwner.head,$c.predecessorHead) $GitExecutable -Empty)
  if ((Invoke-RebaseEvidenceGit $Obligation.worktree @('merge-base',$c.predecessorHead,$Obligation.newBase) $GitExecutable) -cne $c.rebaseProof.oldBase) { throw 'OWED_REBASE_PROOF_INVALID: old base' }
  Assert-RebaseResult $Obligation $c.resultHead $c.resultTree $GitExecutable -Replay:$Replay
  return $c
}
function Assert-RebaseAcknowledgement($Ack,$Obligation,[string]$Runtime,[string]$GitExecutable='git') {
  Assert-RebaseKeys $Ack @('schemaVersion','obligationIdentity','landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane','predecessorHead','resultHead','resultStatus','acknowledgedAt','completionIdentity')
  if (-not(Test-DispatchJsonInteger $Ack.landedPr 1) -or -not(Test-DispatchJsonInteger $Ack.pr 1)) { throw 'OWED_INTEGRATION_ACK_UNKNOWN: numeric identity' }
  if ($Ack.schemaVersion -cne 'landed-integration-owed-ack/v3' -or $Ack.obligationIdentity -cne (Get-RebaseObligationIdentity $Obligation) -or $Ack.resultStatus -cne 'REVIEW_REQUIRED') { throw 'OWED_INTEGRATION_ACK_UNKNOWN' }
  foreach ($key in @('landedPr','landedHead','pr','targetHead','newBase','branch','worktree','integrationLane')) { if ($Ack.$key -cne $Obligation.$key) { throw 'OWED_INTEGRATION_ACK_UNKNOWN' } }
  Assert-RebaseInstant $Ack.acknowledgedAt
  $c=Read-RebaseCompletion $Obligation $Runtime $GitExecutable -Replay
  if ($null -eq $c -or $Ack.completionIdentity -cne (Get-RebaseRecordIdentity $c) -or $Ack.predecessorHead -cne $c.predecessorHead -or $Ack.resultHead -cne $c.resultHead -or [datetimeoffset]$Ack.acknowledgedAt -lt [datetimeoffset]$c.completedAt) { throw 'OWED_INTEGRATION_ACK_UNKNOWN: completion' }
}

function Get-InterruptedIntegrationGitBytes([string]$Worktree,[string[]]$Arguments) {
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = 'git'; $psi.WorkingDirectory = $Worktree
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  foreach ($argument in @('--no-optional-locks') + $Arguments) { [void]$psi.ArgumentList.Add($argument) }
  $process = [Diagnostics.Process]::Start($psi)
  $bytes = [IO.MemoryStream]::new()
  try {
    $errorTask = $process.StandardError.ReadToEndAsync()
    $process.StandardOutput.BaseStream.CopyTo($bytes)
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "INTEGRATION_RESUME_GIT_UNKNOWN: $($errorTask.GetAwaiter().GetResult())" }
    return ,$bytes.ToArray()
  } finally { $bytes.Dispose(); $process.Dispose() }
}

function Get-InterruptedIntegrationState([string]$Worktree) {
  $identity = Get-DispatchGitIdentity $Worktree
  if ($identity.status -cne 'ok' -or $identity.branch -or -not (Test-DispatchSameCanonicalPath $identity.worktree $Worktree)) {
    throw 'INTEGRATION_RESUME_OPERATION: detached canonical root required'
  }
  $branch = Get-DispatchRebaseBranch $Worktree
  if (-not $branch) { throw 'INTEGRATION_RESUME_OPERATION: native rebase required' }
  foreach ($other in @('rebase-apply','MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','sequencer')) {
    if (Test-Path -LiteralPath (Get-RebaseGitPath $Worktree $other)) { throw 'INTEGRATION_RESUME_OPERATION: conflicting operation' }
  }
  $directory = Get-RebaseGitPath $Worktree 'rebase-merge'
  $metadata = [ordered]@{}
  foreach ($file in @(Get-ChildItem -LiteralPath $directory -Force -Recurse -File | Sort-Object FullName)) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'INTEGRATION_RESUME_OPERATION: linked metadata' }
    $metadata[[IO.Path]::GetRelativePath($directory,$file.FullName)] = Get-RebaseHash ([IO.File]::ReadAllBytes($file.FullName))
  }
  $native = @{}
  foreach ($name in @('orig-head','onto','stopped-sha','git-rebase-todo','done')) {
    $path = Join-Path $directory $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "INTEGRATION_RESUME_OPERATION: missing $name" }
    $native[$name] = [IO.File]::ReadAllText($path).Trim()
  }
  foreach ($name in @('orig-head','onto','stopped-sha')) { Assert-RebaseSha $native[$name] }
  $rebaseHead = Invoke-RebaseEvidenceGit $Worktree @('rev-parse','--verify','REBASE_HEAD')
  if ($rebaseHead -cne $native['stopped-sha']) { throw 'INTEGRATION_RESUME_OPERATION: stopped commit mismatch' }
  $oldBase = Invoke-RebaseEvidenceGit $Worktree @('merge-base',$native['orig-head'],$native.onto)
  $commits = @( (Invoke-RebaseEvidenceGit $Worktree @('rev-list','--reverse',"$oldBase..$($native['orig-head'])")) -split "`n" )
  $done = @($native.done -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
  $todo = @($native['git-rebase-todo'] -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
  $sequence = @()
  foreach ($line in @($done) + @($todo)) {
    if ($line -cnotmatch '^pick ([a-f0-9]{7,40}) .+$') { throw 'INTEGRATION_RESUME_OPERATION: noncanonical todo' }
    $sequence += Invoke-RebaseEvidenceGit $Worktree @('rev-parse',"$($Matches[1])^{commit}")
  }
  if ($done.Count -lt 1 -or ($sequence -join ',') -cne ($commits -join ',') -or $sequence[$done.Count-1] -cne $rebaseHead) {
    throw 'INTEGRATION_RESUME_OPERATION: todo/done history mismatch'
  }
  $stages = Get-InterruptedIntegrationGitBytes $Worktree @('ls-files','--stage','-z')
  $unmerged = Get-InterruptedIntegrationGitBytes $Worktree @('ls-files','--unmerged','-z')
  if ($unmerged.Length -eq 0) { throw 'INTEGRATION_RESUME_OPERATION: no unresolved native conflict' }
  $dirty = [ordered]@{}
  $paths = [Text.UTF8Encoding]::new($false,$true).GetString((Get-InterruptedIntegrationGitBytes $Worktree @('ls-files','--modified','--others','--exclude-standard','-z'))).Split([char]0)
  $paths += [Text.UTF8Encoding]::new($false,$true).GetString((Get-InterruptedIntegrationGitBytes $Worktree @('diff','HEAD','--name-only','-z','--no-ext-diff'))).Split([char]0)
  foreach ($relative in @($paths | Where-Object { $_ } | Sort-Object -Unique)) {
    $path = [IO.Path]::GetFullPath((Join-Path $Worktree $relative))
    if (-not $path.StartsWith([IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'INTEGRATION_RESUME_BYTES: escaped path' }
    if (Test-Path -LiteralPath $path) {
      $item = Get-Item -LiteralPath $path -Force
      if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'INTEGRATION_RESUME_BYTES: unsupported dirty entry' }
      $dirty[$relative] = Get-RebaseHash ([IO.File]::ReadAllBytes($path))
    } else { $dirty[$relative] = 'deleted' }
  }
  # Full index stages cover staged nonconflict hunks as well as stage 1/2/3.
  # The binary diffs additionally bind modes, deletions and staged-only paths.
  [ordered]@{
    branch=$branch; originalHead=$native['orig-head']; onto=$native.onto
    stoppedHead=$identity.head; stoppedCommit=$rebaseHead; oldBase=$oldBase
    metadataSha256=(Get-RebaseRecordIdentity $metadata)
    indexSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes((Get-RebaseGitPath $Worktree 'index'))))
    stagesSha256=(Get-RebaseHash $stages); dirtySha256=(Get-RebaseRecordIdentity $dirty)
    stagedSha256=(Get-RebaseHash (Get-InterruptedIntegrationGitBytes $Worktree @('diff','--cached','--binary','--full-index','--no-ext-diff','HEAD')))
    unstagedSha256=(Get-RebaseHash (Get-InterruptedIntegrationGitBytes $Worktree @('diff','--binary','--full-index','--no-ext-diff')))
  }
}

function Assert-InterruptedIntegrationTreeDead($Owner) {
  # Each root is decided by process identity from one inventory (#8103): no row
  # is dead; a row whose creation identity matches the recorded start is live;
  # a readable, different identity is a reused PID and is dead; an unreadable
  # identity or more than one row is ambiguous. A second exact read follows for
  # each possible descendant; no process observation is synthesized from
  # retained metadata.
  $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  $observer = @($all | Where-Object { $_.ProcessId -eq $PID })
  if ($observer.Count -ne 1 -or $null -eq $observer[0].CreationDate -or
      [Math]::Abs((([datetimeoffset]$observer[0].CreationDate).ToUniversalTime().Ticks) - (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks) -ge 10) {
    throw 'INTEGRATION_RESUME_PRIOR_OWNER: incomplete native process inventory'
  }
  $seen = [Collections.Generic.HashSet[int]]::new()
  $reused = @{}
  foreach ($role in @('launcher','child')) {
    $id = $Owner."${role}Pid"
    if (-not (Test-DispatchJsonInteger $id 1) -or -not $seen.Add([int]$id)) { throw 'INTEGRATION_RESUME_PRIOR_OWNER: ambiguous root' }
    $rows = @($all | Where-Object { $_.ProcessId -eq $id })
    if (-not $rows.Count) { continue }
    if ($rows.Count -ne 1 -or $null -eq $rows[0].CreationDate) { throw 'INTEGRATION_RESUME_PRIOR_OWNER: ambiguous root' }
    if ([Math]::Abs((([datetimeoffset]$rows[0].CreationDate).ToUniversalTime().Ticks) - ([datetimeoffset]$Owner."${role}StartIdentity").ToUniversalTime().Ticks) -lt 10) {
      throw 'INTEGRATION_RESUME_PRIOR_OWNER: live root'
    }
    $reused[[int]$id] = [datetimeoffset]$rows[0].CreationDate
  }
  $queue = [Collections.Generic.Queue[int]]::new()
  foreach ($id in $seen) { $queue.Enqueue($id) }
  while ($queue.Count) {
    $parent = $queue.Dequeue()
    foreach ($child in @($all | Where-Object { $_.ParentProcessId -eq $parent })) {
      # A reused root's own children were born after it; only earlier births can descend from the prior owner.
      if ($reused.ContainsKey($parent) -and $null -ne $child.CreationDate -and [datetimeoffset]$child.CreationDate -ge $reused[$parent]) { continue }
      $exact = @(Get-CimInstance Win32_Process -Filter "ProcessId = $($child.ProcessId)" -ErrorAction Stop)
      if ($exact.Count -ne 1 -or $null -eq $child.CreationDate -or $child.CreationDate -ne $exact[0].CreationDate) { throw 'INTEGRATION_RESUME_PRIOR_OWNER: ambiguous descendant' }
      if ([datetimeoffset]$child.CreationDate -ge [datetimeoffset]$Owner.launcherStartIdentity) { throw 'INTEGRATION_RESUME_PRIOR_OWNER: possible descendant' }
      if ($seen.Add([int]$child.ProcessId)) { $queue.Enqueue([int]$child.ProcessId) }
    }
  }
}

function Test-InterruptedIntegrationCommand([string]$Command,[string]$Prompt,$Obligation,[string]$Runtime,[string]$CanonicalHelper) {
  if ($CanonicalHelper) { $expectedHelper = $CanonicalHelper }
  else {
    if ($Prompt -cnotmatch "Use only '([^']+rebase-integration\.ps1)'" ) { return $null }
    $expectedHelper = $Matches[1]
  }
  if (-not (Test-DispatchSamePath $expectedHelper (Join-Path $Runtime 'rebase-integration.ps1'))) { return $null }
  $text = $Command.Replace('\\','\')
  $style = 'file'
  if ($text -match '^"[^"]+pwsh\.exe"(?: -NoProfile)?(?: -NonInteractive)? -Command "(.+)"$') { $text=$Matches[1];$style='command' }
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
  $commands=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true))
  if ($errors.Count -or $commands.Count -ne 1 -or $commands[0].Redirections.Count) { return $null }
  $elements=@($commands[0].CommandElements)
  $fileIndex=0
  if ($style -ceq 'file') {
    if ([IO.Path]::GetFileNameWithoutExtension($commands[0].GetCommandName()) -cne 'pwsh') { return $null }
    $fileParameters=@(0..($elements.Count-1)|Where-Object {$elements[$_] -is [Management.Automation.Language.CommandParameterAst] -and $elements[$_].ParameterName -ceq 'File'})
    if ($fileParameters.Count -ne 1) { return $null };$fileIndex=$fileParameters[0]+1
    for($i=1;$i-lt$fileIndex-1;$i++){if($elements[$i] -isnot [Management.Automation.Language.CommandParameterAst] -or $elements[$i].ParameterName -cnotin @('NoProfile','NonInteractive')){return $null}}
  } elseif ($commands[0].InvocationOperator -ne [Management.Automation.Language.TokenKind]::Ampersand) { return $null }
  if ($elements[$fileIndex] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or -not (Test-DispatchSamePath $elements[$fileIndex].Value $expectedHelper)) { return $null }
  $arguments=@{}
  for($i=$fileIndex+1;$i-lt$elements.Count;$i++){
    $parameter=$elements[$i]
    if($parameter -isnot [Management.Automation.Language.CommandParameterAst] -or $parameter.Argument -or $arguments.ContainsKey($parameter.ParameterName)){return $null}
    $name=$parameter.ParameterName
    if($name -ceq 'ContinueInterruptedIntegration'){$arguments[$name]=$true;continue}
    if($name -cnotin @('Pr','ReviewedHead','NewBase','SourcePassReceiptIdentity','SourcePassReviewedHead','IntegrationLane','Worktree','RuntimeRoot','HistoryPath')){return $null}
    $i++;if($i-ge$elements.Count-or($elements[$i] -isnot [Management.Automation.Language.StringConstantExpressionAst] -and $elements[$i] -isnot [Management.Automation.Language.ConstantExpressionAst])){return $null}
    $arguments[$name]=[string]$elements[$i].Value
  }
  if($arguments.Pr -cne [string]$Obligation.pr -or $arguments.ReviewedHead -cne $Obligation.targetHead -or $arguments.NewBase -cne $Obligation.newBase -or
      -not(Test-DispatchSamePath $arguments.Worktree $Obligation.worktree)-or $arguments.IntegrationLane -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or
      ($arguments.SourcePassReceiptIdentity -cne 'ABSENT_REVIEW_REQUIRED' -and $arguments.SourcePassReceiptIdentity -cnotmatch '^[a-f0-9]{64}$')){return $null}
  return $style
}

function Get-InterruptedIntegrationSources($Obligation,[string]$Runtime,[string]$PriorLabel,[string]$PriorLaunchId,[int]$Depth=0) {
  if ($Depth -gt 3) { throw 'INTEGRATION_RESUME_SOURCE: bounded retained chain exhausted' }
  Assert-RebaseObligation $Obligation
  if ($PriorLabel -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$' -or $PriorLaunchId -cnotmatch '^[a-f0-9-]{36}$') { throw 'INTEGRATION_RESUME_SOURCE: identity' }
  $o = $Obligation
  $requestText = "landed-integration-start/v1`n$($o.landedPr)`n$($o.landedHead)`n$($o.pr)`n$($o.targetHead)`n$($o.branch)`n$($o.worktree)`n$($o.integrationLane)"
  $request = Get-RebaseHash ([Text.Encoding]::UTF8.GetBytes($requestText))
  $watchdogPath = Join-Path $Runtime "watchdog-lane-$PriorLabel.json"
  $w = Read-RebaseJson $watchdogPath
  $ackKeys = @('schemaVersion','requestIdentity','label','launchId','ownershipRecordPath','worktree','branch','head','harness','model','effort','row','placement','state','childPid','childStartIdentity')
  $watchdogKeys = @('schemaVersion','label','attemptId','relaunchCount','resumeOfLaunchId','harness','model','effort','row','placement','laneRole','originalPromptPath','partialReportPath','errorPath','worktree','branch','head','launchId','ownershipRecordPath','launcherPid','launcherStartIdentity','childPid','childStartIdentity','state','exitCode','updatedAt')
  $routingKeys = @('policyGeneration','registryAuthorityDigest','family','slot','usedLastKnownGood')
  function Add-OptionalRoutingKeys($Value,[ref]$Keys) {
    $present=@($routingKeys|Where-Object{$_-in @($Value.PSObject.Properties.Name)})
    if($present.Count-eq0){return $false}
    if($present.Count-ne$routingKeys.Count-or
      -not(Test-DispatchJsonInteger $Value.policyGeneration 1)-or
      $Value.registryAuthorityDigest-isnot[string]-or$Value.registryAuthorityDigest-cnotmatch'^[a-zA-Z0-9._:-]{1,128}$'-or
      $Value.family-isnot[string]-or$Value.family-cnotmatch'^[a-z0-9][a-z0-9._-]{0,63}$'-or
      $Value.slot-isnot[string]-or$Value.slot-cnotmatch'^(explicit|(codex|claude)\.(primary|fallback))$'-or
      $Value.usedLastKnownGood-isnot[bool]){throw 'OWED_REBASE_PROOF_INVALID: routing provenance'}
    $Keys.Value += $routingKeys
    return $true
  }
  $watchdogHasRouting=Add-OptionalRoutingKeys $w ([ref]$watchdogKeys)
  $priorBinding = $null; $checkpoint = $null; $checkpointHash = $null
  $expectedHead = $o.targetHead; $ackVersion = 'dispatch-start-ack/v1'
  $canonicalHelper = $null
  if($w.schemaVersion -cin @('watchdog-lane/v3','watchdog-lane/v4')) { . (Join-Path $PSScriptRoot 'integration-dispatch-contract.ps1') }
  if ($w.schemaVersion -ceq 'watchdog-lane/v3') {
    $watchdogKeys += 'integrationRequest'
    $target = $w.integrationRequest
    Assert-IntegrationRequest $target
    Assert-IntegrationAuthor $w.harness $w.model $w.effort $w.row $w.placement -HistoricalRead
    if ($target.label -cne $PriorLabel -or $target.pr -ne $o.pr -or $target.landedPr -ne $o.landedPr -or
        $target.landedHead -cne $o.landedHead -or $target.head -cne $o.targetHead -or $target.newBase -cne $o.newBase -or
        $target.branch -cne $o.branch -or -not (Test-DispatchSameCanonicalPath $target.worktree $o.worktree) -or
        -not (Test-DispatchSamePath $target.runtimeRoot $Runtime) -or
        (Get-RebaseRecordIdentity (Read-RebaseJson (Join-Path $Runtime "integration-request-$PriorLabel.json"))) -cne (Get-RebaseRecordIdentity $target)) { throw 'INTEGRATION_RESUME_SOURCE: canonical request mismatch' }
    $request = $target.requestIdentity
    $canonicalHelper = Join-Path $Runtime 'rebase-integration.ps1'
  }
  if ($w.schemaVersion -ceq 'watchdog-lane/v4') {
    $watchdogKeys += 'interruptedIntegration'; $ackKeys += 'interruptedIntegration'; $ackVersion = 'dispatch-start-ack/v2'
    $priorBinding = ConvertFrom-RebaseJson $w.interruptedIntegration
    if (-not (Test-DispatchInterruptedBindingShape $priorBinding) -or (Get-RebaseObligationIdentity $priorBinding.obligation) -cne (Get-RebaseObligationIdentity $o)) { throw 'INTEGRATION_RESUME_SOURCE: retained binding' }
    $priorSource = Get-InterruptedIntegrationSources $o $Runtime $priorBinding.sources.priorLabel $priorBinding.sources.priorLaunchId ($Depth+1)
    $canonicalHelper = $priorSource.canonicalHelper
    if ((Get-RebaseRecordIdentity $priorSource.binding) -cne (Get-RebaseRecordIdentity $priorBinding.sources)) { throw 'INTEGRATION_RESUME_SOURCE: retained source changed' }
    $request = Get-RebaseRecordIdentity $priorBinding
    $expectedHead = $priorBinding.state.stoppedHead
    $checkpointPath = Join-Path $Runtime "integration-resume-stop-$PriorLaunchId.json"
    if (Test-Path -LiteralPath $checkpointPath) {
      $checkpoint = Read-RebaseJson $checkpointPath
      Assert-RebaseKeys $checkpoint @('schemaVersion','launchId','bindingIdentity','state','capturedAt')
      # Reuse the recursively validated parsed obligation. Callers may supply an
      # ordered owed/v1 dictionary; its exact identity was checked above. Do not
      # widen the persisted shape validator or manufacture missing members.
      $checkpointShape = [pscustomobject]@{schemaVersion='interrupted-canonical-integration/v1';obligation=$priorBinding.obligation;sources=$priorBinding.sources;state=$checkpoint.state}
      if (-not (Test-DispatchInterruptedBindingShape $checkpointShape)) { throw 'INTEGRATION_RESUME_SOURCE: closed checkpoint state' }
      Assert-RebaseInstant $checkpoint.capturedAt
      if ($checkpoint.schemaVersion -cne 'integration-resume-stop/v1' -or $checkpoint.launchId -cne $PriorLaunchId -or $checkpoint.bindingIdentity -cne $request -or
          [datetimeoffset]$checkpoint.capturedAt -lt [datetimeoffset]$w.childStartIdentity -or ($w.state -ceq 'exited' -and [datetimeoffset]$checkpoint.capturedAt -gt [datetimeoffset]$w.updatedAt) -or [datetimeoffset]$checkpoint.capturedAt -gt [datetimeoffset]::UtcNow) { throw 'INTEGRATION_RESUME_SOURCE: retained stop causality' }
      $checkpointHash = Get-RebaseHash ([IO.File]::ReadAllBytes($checkpointPath))
    }
  }
  $ackPath = Join-Path $Runtime "dispatch-start-$request.json"
  $ack = Read-RebaseJson $ackPath
  $ackHasRouting=Add-OptionalRoutingKeys $ack ([ref]$ackKeys)
  if($watchdogHasRouting -ne $ackHasRouting){throw 'INTEGRATION_RESUME_SOURCE: routing provenance presence'}
  if($watchdogHasRouting){foreach($key in $routingKeys){if([string]$ack.$key -cne [string]$w.$key){throw "INTEGRATION_RESUME_SOURCE: routing join $key"}}}
  Assert-RebaseKeys $ack $ackKeys; Assert-RebaseKeys $w $watchdogKeys
  if (-not (Test-DispatchJsonInteger $w.launcherPid 1) -or -not (Test-DispatchJsonInteger $w.childPid 1) -or -not (Test-DispatchJsonInteger $ack.childPid 1) -or $w.launcherPid -eq $w.childPid -or
      -not (Test-DispatchJsonInteger $w.relaunchCount 0) -or $w.relaunchCount -gt 3 -or
      -not (Test-DispatchJsonInteger $w.row 1) -or $w.row -gt 15 -or -not (Test-DispatchJsonInteger $ack.row 1) -or
      ($w.state -ceq 'exited' -and -not (Test-DispatchJsonInteger $w.exitCode)) -or ($w.state -ceq 'running' -and $null -ne $w.exitCode) -or
      ($priorBinding -and -not (Test-IntegrationAuthorRoute $w.harness $w.model $w.effort $w.row $w.placement -HistoricalRead))) { throw 'INTEGRATION_RESUME_SOURCE: native launch types/route' }
  if ($priorBinding -and $ack.interruptedIntegration -cne $w.interruptedIntegration) { throw 'INTEGRATION_RESUME_SOURCE: retained start binding' }
  if ($ack.schemaVersion -cne $ackVersion -or $ack.requestIdentity -cne $request -or $ack.state -cne 'started' -or
      $w.schemaVersion -cnotin @('watchdog-lane/v2','watchdog-lane/v3','watchdog-lane/v4') -or $w.laneRole -cne 'implementation' -or $w.state -cnotin @('running','exited') -or
      $w.launchId -cne $PriorLaunchId -or $w.label -cne $PriorLabel -or $w.head -cne $expectedHead -or $w.branch -cne $o.branch -or
      -not (Test-DispatchSameCanonicalPath $w.worktree $o.worktree)) { throw 'INTEGRATION_RESUME_SOURCE: prior launch/request' }
  foreach ($key in @('label','launchId','ownershipRecordPath','worktree','branch','head','harness','model','effort','row','placement','childPid','childStartIdentity')) {
    if ([string]$ack.$key -cne [string]$w.$key) { throw "INTEGRATION_RESUME_SOURCE: start join $key" }
  }
  foreach ($key in @('launcherStartIdentity','childStartIdentity','updatedAt')) { Assert-RebaseInstant $w.$key }
  if ([datetimeoffset]$w.childStartIdentity -lt [datetimeoffset]$w.launcherStartIdentity -or [datetimeoffset]$w.updatedAt -lt [datetimeoffset]$w.childStartIdentity -or
      -not (Test-DispatchSamePath $w.ownershipRecordPath (Join-Path $Runtime "dispatch-launch-$PriorLaunchId.json")) -or
      -not (Test-DispatchSamePath $w.originalPromptPath (Join-Path $Runtime "$PriorLabel.prompt.txt")) -or
      -not (Test-DispatchSamePath $w.partialReportPath (Join-Path $Runtime "$PriorLabel.jsonl"))) { throw 'INTEGRATION_RESUME_SOURCE: causal paths' }
  $history = Read-RebaseJsonLines (Join-Path $Runtime 'dispatch-log.jsonl')
  $routes = @($history | Where-Object { $_.dispatchRoutingSchema -cin @('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3') -and $_.label -ceq $PriorLabel })
  if ($routes.Count -ne 1) { throw 'INTEGRATION_RESUME_SOURCE: ambiguous routing' }
  $route = $routes[0]
  Assert-RebaseKeys $route @(Get-DispatchRoutingLedgerKeys $route.dispatchRoutingSchema $route)
  if (-not (Test-DispatchRoutingLedgerEvidence $route)) { throw 'INTEGRATION_RESUME_SOURCE: routing evidence' }
  foreach ($key in @('attemptId','label','laneRole','harness','model','effort','row','placement','worktree','branch','head')) {
    if ([string]$route.$key -cne [string]$w.$key) { throw "INTEGRATION_RESUME_SOURCE: route join $key" }
  }
  Assert-RebaseInstant $route.ts
  if ($route.kind -cne 'dispatch' -or $route.lane -cne (Split-Path -Leaf $o.worktree) -or $route.transcript -cne "$PriorLabel.jsonl" -or
      [datetimeoffset]$route.ts -lt [datetimeoffset]$w.launcherStartIdentity -or [datetimeoffset]$route.ts -gt [datetimeoffset]$w.childStartIdentity) { throw 'INTEGRATION_RESUME_SOURCE: routing causality' }
  $prompt = [IO.File]::ReadAllText($w.originalPromptPath)
  $commandPrompt = if ($priorBinding) { $priorSource.commandPrompt } else { $prompt }
  if (-not $priorBinding) {
    foreach ($token in @("PR #$($o.pr)","PR #$($o.landedPr)",$o.targetHead,$o.newBase,'rebase-integration.ps1')) {
      if (-not $prompt.Contains($token,[StringComparison]::Ordinal)) { throw 'INTEGRATION_RESUME_SOURCE: original request' }
    }
  }
  $events = @(Read-RebaseJsonLines $w.partialReportPath)
  $conflicts = @()
  foreach ($event in $events) {
    if ($event.type -cne 'item.completed' -or $event.item.type -cne 'command_execution') { continue }
    $command = [string]$event.item.command
    $commandStyle = Test-InterruptedIntegrationCommand $command $commandPrompt $o $Runtime $canonicalHelper
    $nativeFailure = ($event.item.exit_code -eq 2 -and $commandStyle -ceq 'file') -or ($event.item.exit_code -eq 1 -and $commandStyle -ceq 'command')
    if (-not $nativeFailure) { continue }
    if (-not $command.Contains('rebase-integration.ps1',[StringComparison]::Ordinal) -or -not $command.Contains($o.targetHead) -or -not $command.Contains($o.newBase)) { continue }
    foreach ($line in @([string]$event.item.aggregated_output -split "`r?`n" | Where-Object { $_.StartsWith('{') })) {
      $result = ConvertFrom-RebaseJson $line
      Assert-RebaseKeys $result @('schemaVersion','status','pr','reviewedHead','newBase','conflictPaths','reason')
      if ($result.schemaVersion -ceq 'rebase-integration-result/v1' -and $result.status -ceq 'DELTA_REQUIRED' -and $result.reason -ceq 'REBASE_CONFLICT' -and
          $result.pr -eq $o.pr -and $result.reviewedHead -ceq $o.targetHead -and $result.newBase -ceq $o.newBase -and @($result.conflictPaths).Count -gt 0) { $conflicts += $result }
    }
  }
  if (-not $priorBinding -and $conflicts.Count -ne 1) { throw 'INTEGRATION_RESUME_SOURCE: canonical helper conflict absent or ambiguous' }
  if ($priorBinding -and $checkpoint -and $conflicts.Count -ne 1) { throw 'INTEGRATION_RESUME_SOURCE: continued helper conflict absent or ambiguous' }
  [pscustomobject]@{
    owner=$w; rootOwner=$(if ($priorBinding) { $priorSource.rootOwner } else { $w }); commandPrompt=$commandPrompt; canonicalHelper=$canonicalHelper; conflict=$(if ($conflicts.Count) { $conflicts[0] } else { $null }); priorBinding=$priorBinding; checkpoint=$checkpoint
    binding=[ordered]@{
      requestIdentity=$request; priorLabel=$PriorLabel; priorLaunchId=$PriorLaunchId
      ackSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($ackPath)))
      watchdogSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($watchdogPath)))
      promptSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($w.originalPromptPath)))
      transcriptSha256=(Get-RebaseHash ([IO.File]::ReadAllBytes($w.partialReportPath)))
      routingIdentity=(Get-RebaseRecordIdentity $route)
      checkpointSha256=$checkpointHash
    }
  }
}

function Read-RebaseJsonLines([string]$Path) {
  foreach ($line in [IO.File]::ReadAllLines($Path,[Text.UTF8Encoding]::new($false,$true))) {
    if ($line.Trim()) { ConvertFrom-RebaseJson $line }
  }
}

function Assert-InterruptedIntegrationReplay($Obligation,$State) {
  # Historic helpers did not capture dirty bytes. Reproduce their *native*
  # first stop from immutable objects in an owned scratch repository. A hash of
  # today's caller-supplied dirty state alone would authorize unrelated edits.
  $temporary = Join-Path ([IO.Path]::GetTempPath()) ('integration-resume-proof-'+[guid]::NewGuid().ToString('N'))
  $source = $Obligation.worktree
  try {
    [void](Get-InterruptedIntegrationGitBytes $source @('clone','--shared','--no-checkout','--',$source,$temporary))
    [void](Get-InterruptedIntegrationGitBytes $temporary @('config','user.name','Interrupted integration scratch proof'))
    [void](Get-InterruptedIntegrationGitBytes $temporary @('config','user.email','integration-proof@example.invalid'))
    [void](Get-InterruptedIntegrationGitBytes $temporary @('checkout','-B',$Obligation.branch,$Obligation.targetHead))
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName='git';$psi.WorkingDirectory=$temporary;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    foreach ($arg in @('-c','core.hooksPath=NUL','-c','rerere.enabled=false','rebase','--onto',$Obligation.newBase,$State.oldBase)) { [void]$psi.ArgumentList.Add($arg) }
    $p = [Diagnostics.Process]::Start($psi)
    try {
      $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();$p.WaitForExit()
      [void]$stdout.GetAwaiter().GetResult();[void]$stderr.GetAwaiter().GetResult()
      if ($p.ExitCode -eq 0) { throw 'INTEGRATION_RESUME_NATIVE_PROOF: no canonical conflict' }
    } finally { $p.Dispose() }
    $replayed = Get-InterruptedIntegrationState $temporary
    foreach ($key in @('branch','originalHead','onto','stoppedHead','stoppedCommit','oldBase','metadataSha256','stagesSha256','dirtySha256','stagedSha256','unstagedSha256')) {
      if ($replayed.$key -cne $State.$key) { throw "INTEGRATION_RESUME_NATIVE_PROOF: $key differs from native first stop" }
    }
  } finally {
    $resolved=[IO.Path]::GetFullPath($temporary)
    if ((Split-Path -Parent $resolved).TrimEnd('\','/') -cne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') -or (Split-Path -Leaf $resolved) -cnotmatch '^integration-resume-proof-[a-f0-9]{32}$') { throw 'INTEGRATION_RESUME_NATIVE_PROOF: unsafe scratch cleanup' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
  }
}

function New-InterruptedIntegrationResume($Obligation,[string]$Runtime,[string]$PriorLabel,[string]$PriorLaunchId) {
  $sources = Get-InterruptedIntegrationSources $Obligation $Runtime $PriorLabel $PriorLaunchId
  $state = Get-InterruptedIntegrationState $Obligation.worktree
  $binding = [ordered]@{schemaVersion='interrupted-canonical-integration/v1';obligation=$Obligation;sources=$sources.binding;state=$state}
  [void](Assert-InterruptedIntegrationResume $binding $Runtime)
  return $binding
}

function Assert-InterruptedIntegrationResume($Binding,[string]$Runtime) {
  Assert-RebaseKeys $Binding @('schemaVersion','obligation','sources','state')
  if ($Binding.schemaVersion -cne 'interrupted-canonical-integration/v1') { throw 'INTEGRATION_RESUME_BINDING: version' }
  Assert-RebaseObligation $Binding.obligation
  Assert-RebaseKeys $Binding.sources @('requestIdentity','priorLabel','priorLaunchId','ackSha256','watchdogSha256','promptSha256','transcriptSha256','routingIdentity','checkpointSha256')
  Assert-RebaseKeys $Binding.state @('branch','originalHead','onto','stoppedHead','stoppedCommit','oldBase','metadataSha256','indexSha256','stagesSha256','dirtySha256','stagedSha256','unstagedSha256')
  foreach ($key in @('requestIdentity','ackSha256','watchdogSha256','promptSha256','transcriptSha256','routingIdentity')) { Assert-RebaseSha $Binding.sources.$key 64 }
  foreach ($key in @('metadataSha256','indexSha256','stagesSha256','dirtySha256','stagedSha256','unstagedSha256')) { Assert-RebaseSha $Binding.state.$key 64 }
  foreach ($key in @('originalHead','onto','stoppedHead','stoppedCommit','oldBase')) { Assert-RebaseSha $Binding.state.$key }
  $o = $Binding.obligation
  $sources = Get-InterruptedIntegrationSources $o $Runtime $Binding.sources.priorLabel $Binding.sources.priorLaunchId
  if ((Get-RebaseRecordIdentity $sources.binding) -cne (Get-RebaseRecordIdentity $Binding.sources)) { throw 'INTEGRATION_RESUME_SOURCE: changed binding' }
  $state = Get-InterruptedIntegrationState $o.worktree
  if ((Get-RebaseRecordIdentity $state) -cne (Get-RebaseRecordIdentity $Binding.state) -or $state.branch -cne $o.branch -or $state.originalHead -cne $o.targetHead -or $state.onto -cne $o.newBase) { throw 'INTEGRATION_RESUME_STATE: stale or unrelated bytes' }
  foreach ($ref in @("refs/heads/$($o.branch)","refs/pull/$($o.pr)/head")) {
    $remote = Invoke-RebaseEvidenceGit $o.worktree @('ls-remote','--exit-code','origin',$ref)
    if ($remote -cne "$($o.targetHead)`t$ref") { throw 'INTEGRATION_RESUME_REMOTE: original branch/PR changed' }
  }
  if ($sources.priorBinding) {
    $expectedState = if ($sources.checkpoint) { $sources.checkpoint.state } else { $sources.priorBinding.state }
    if ((Get-RebaseRecordIdentity $expectedState) -cne (Get-RebaseRecordIdentity $state)) { throw 'INTEGRATION_RESUME_STATE: no authentic current stop' }
  } else {
    Assert-InterruptedIntegrationReplay $o $state # RESUME_GUARD_NATIVE_REPLAY
  }
  Assert-InterruptedIntegrationTreeDead $sources.owner # RESUME_GUARD_PRIOR_DEATH
  return $sources.owner
}

function Get-InterruptedIntegrationChild([string]$Runtime,[string]$RecordPath) {
  $record = Get-ValidatedDispatchOwnershipRecord $RecordPath $Runtime ([IO.Path]::GetTempPath())
  if (-not $record -or $record.schemaVersion -ne 5) { throw 'INTEGRATION_RESUME_CHILD: bound owner required' }
  $binding = ConvertFrom-RebaseJson $record.interruptedIntegration
  $owner = Get-RebaseAuthenticatedOwner $binding.obligation $Runtime $RecordPath Child
  if ($owner.launchId -cne $record.launchId) { throw 'INTEGRATION_RESUME_CHILD: exact actual child required' }
  [pscustomobject]@{record=$record;binding=$binding;owner=$owner}
}

function Save-InterruptedIntegrationStop([string]$Runtime,[string]$RecordPath) {
  $child = Get-InterruptedIntegrationChild $Runtime $RecordPath
  $state = Get-InterruptedIntegrationState $child.binding.obligation.worktree
  if ($state.originalHead -cne $child.binding.obligation.targetHead -or $state.branch -cne $child.binding.obligation.branch -or $state.onto -cne $child.binding.obligation.newBase) { throw 'INTEGRATION_RESUME_CHILD: operation changed' }
  $value = [ordered]@{schemaVersion='integration-resume-stop/v1';launchId=$child.record.launchId;bindingIdentity=(Get-RebaseRecordIdentity $child.binding);state=$state;capturedAt=[datetimeoffset]::UtcNow.ToString('o')}
  $path = Join-Path $Runtime "integration-resume-stop-$($child.record.launchId).json"
  $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllText($temporary,($value | ConvertTo-Json -Depth 12 -Compress),[Text.UTF8Encoding]::new($false))
    [void](Get-InterruptedIntegrationChild $Runtime $RecordPath)
    [IO.File]::Move($temporary,$path,$true)
  } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Complete-InterruptedIntegration($Obligation,[string]$Runtime,[string]$RecordPath) {
  $record = Get-ValidatedDispatchOwnershipRecord $RecordPath $Runtime ([IO.Path]::GetTempPath())
  if (-not $record -or $record.schemaVersion -ne 5) { return $null }
  $binding = ConvertFrom-RebaseJson $record.interruptedIntegration
  if ((Get-RebaseObligationIdentity $binding.obligation) -cne (Get-RebaseObligationIdentity $Obligation)) { return $null }
  $owner = Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher
  $sources = Get-InterruptedIntegrationSources $Obligation $Runtime $binding.sources.priorLabel $binding.sources.priorLaunchId
  if ((Get-RebaseRecordIdentity $sources.binding) -cne (Get-RebaseRecordIdentity $binding.sources)) { throw 'INTEGRATION_RESUME_COMPLETION: source changed' }
  $result = Invoke-RebaseEvidenceGit $Obligation.worktree @('rev-parse','HEAD')
  $tree = Invoke-RebaseEvidenceGit $Obligation.worktree @('rev-parse','HEAD^{tree}')
  Assert-RebaseResult $Obligation $result $tree
  $branchBytes = Get-RebaseLogBytes $Obligation.worktree "refs/heads/$($Obligation.branch)"
  $headBytes = Get-RebaseLogBytes $Obligation.worktree 'HEAD'
  $proof = Get-RebaseNativeProof $Obligation $Obligation.targetHead $result $binding.state.oldBase ([datetimeoffset]$sources.rootOwner.childStartIdentity) ([datetimeoffset]::UtcNow) $branchBytes $headBytes
  [void](Save-RebaseBytes $Runtime $branchBytes); [void](Save-RebaseBytes $Runtime $headBytes)
  $publication = Get-RebasePublication $Obligation $result
  $value = [ordered]@{schemaVersion='landed-integration-rebase-complete/v2';obligation=$Obligation;obligationIdentity=(Get-RebaseObligationIdentity $Obligation);mode='INTERRUPTED_OWNER_RELEASE';interruptedIntegration=$record.interruptedIntegration;executionOwner=$owner;predecessorHead=$Obligation.targetHead;resultHead=$result;resultTree=$tree;completedAt=[datetimeoffset]::UtcNow.ToString('o');rebaseProof=$proof;publication=$publication}
  [void](Get-RebaseAuthenticatedOwner $Obligation $Runtime $RecordPath Launcher)
  Assert-RebaseResult $Obligation $result $tree
  Write-RebaseRecord (Join-Path $Runtime "integration-rebase-complete-$($value.obligationIdentity).json") $value
  return $value
}

function Read-InterruptedIntegrationCompletion($Completion,$Obligation,[string]$Runtime,[string]$GitExecutable,[switch]$Replay) {
  $c = $Completion
  Assert-RebaseKeys $c @('schemaVersion','obligation','obligationIdentity','mode','interruptedIntegration','executionOwner','predecessorHead','resultHead','resultTree','completedAt','rebaseProof','publication')
  Assert-RebaseObligation $c.obligation
  if ($c.mode -cne 'INTERRUPTED_OWNER_RELEASE' -or $c.obligationIdentity -cne (Get-RebaseObligationIdentity $Obligation) -or
      (Get-RebaseObligationIdentity $c.obligation) -cne $c.obligationIdentity -or $c.interruptedIntegration -isnot [string]) { throw 'INTEGRATION_RESUME_COMPLETION: binding' }
  $binding = ConvertFrom-RebaseJson $c.interruptedIntegration
  if (-not (Test-DispatchInterruptedBindingShape $binding) -or (Get-RebaseObligationIdentity $binding.obligation) -cne $c.obligationIdentity) { throw 'INTEGRATION_RESUME_COMPLETION: retained binding' }
  Assert-RebaseOwner $c.executionOwner $Obligation $Runtime
  Assert-RebaseInstant $c.completedAt
  foreach ($key in @('predecessorHead','resultHead','resultTree')) { Assert-RebaseSha $c.$key }
  if ($c.predecessorHead -cne $Obligation.targetHead -or $c.executionOwner.head -cne $binding.state.stoppedHead -or [datetimeoffset]$c.completedAt -gt [datetimeoffset]::UtcNow) { throw 'INTEGRATION_RESUME_COMPLETION: original/executor/time' }
  $sources = Get-InterruptedIntegrationSources $Obligation $Runtime $binding.sources.priorLabel $binding.sources.priorLaunchId
  if ((Get-RebaseRecordIdentity $sources.binding) -cne (Get-RebaseRecordIdentity $binding.sources) -or [datetimeoffset]$sources.owner.updatedAt -gt [datetimeoffset]$c.executionOwner.launcherStartIdentity) { throw 'INTEGRATION_RESUME_COMPLETION: source causality' }
  Assert-RebaseKeys $c.rebaseProof @('oldBase','branchOldHead','branchNewHead','onto','branchReflogHash','headReflogHash','startedAt','finishedAt')
  Assert-RebaseKeys $c.publication @('repository','branch','observedHead','observedAt')
  Assert-RebaseInstant $c.publication.observedAt
  $proof = Get-RebaseNativeProof $Obligation $Obligation.targetHead $c.resultHead $binding.state.oldBase ([datetimeoffset]$sources.rootOwner.childStartIdentity) ([datetimeoffset]$c.completedAt) (Read-RebaseBytes $Runtime $c.rebaseProof.branchReflogHash) (Read-RebaseBytes $Runtime $c.rebaseProof.headReflogHash)
  if ((Get-RebaseRecordIdentity $proof) -cne (Get-RebaseRecordIdentity $c.rebaseProof) -or $c.publication.branch -cne $Obligation.branch -or $c.publication.observedHead -cne $c.resultHead -or
      [datetimeoffset]$c.publication.observedAt -gt [datetimeoffset]$c.completedAt -or [datetimeoffset]$c.publication.observedAt -lt [datetimeoffset]$proof.finishedAt) { throw 'INTEGRATION_RESUME_COMPLETION: native publication proof' }
  Assert-RebaseResult $Obligation $c.resultHead $c.resultTree $GitExecutable -Replay:$Replay
  return $c
}

# Fleet-load observation (#8102). Reports whether the platform heavy-verifier
# slot of a container (<container>/.orchestrator/verify-lock.d/owner.json) is
# held by a LIVE owner under the heavy verifier's own rule: the wrapper pid with
# its process start identity, or (schema 2..5 in state started/attached) the
# child pid with its start identity. A stale or unreadable owner.json is never
# load. This only observes; nothing here takes or waits on the slot. Appended
# after the guards above so their recorded line numbers stay exact.
function Get-FleetLoadObservation([string]$Container) {
  $ownerPath = Join-Path $Container '.orchestrator/verify-lock.d/owner.json'
  $observation = [ordered]@{observedAt=[datetimeoffset]::UtcNow.ToString('o');ownerPath=$ownerPath;held=$false;holder='none';reason='absent'}
  if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { return [pscustomobject]$observation }
  try { $owner = ConvertFrom-RebaseJson ([IO.File]::ReadAllText($ownerPath)) } catch { $owner = $null }
  if ($null -eq $owner -or $owner -isnot [pscustomobject]) { $observation.reason = 'unparseable'; return [pscustomobject]$observation }
  $wrapperLive = (Test-DispatchJsonInteger $owner.pid 1) -and (Get-DispatchProcessIdentityState ([int]$owner.pid) ([string]$owner.processStartUtc)) -ceq 'live'
  $childLive = $false
  if (-not $wrapperLive -and (Test-DispatchJsonInteger $owner.schemaVersion 2) -and [long]$owner.schemaVersion -le 5 -and ([string]$owner.state) -cin @('started','attached')) {
    $childLive = (Test-DispatchJsonInteger $owner.childPid 1) -and (Get-DispatchProcessIdentityState ([int]$owner.childPid) ([string]$owner.childProcessStartUtc)) -ceq 'live'
  }
  if (-not ($wrapperLive -or $childLive)) { $observation.reason = 'stale'; return [pscustomobject]$observation }
  $observation.held = $true; $observation.reason = 'live'
  $observation.holder = ("lane=$($owner.lane);gate=$($owner.gate);lockId=$($owner.lockId);pid=$($owner.pid);started=$($owner.processStartUtc)" -replace '\s', '_')
  return [pscustomobject]$observation
}
# A window counts as held only when both ends saw the same live acquisition
# (identical holder string, which carries the lockId).
function Get-FleetLoadWindow($Start, $End) {
  $held = $null -ne $Start -and $null -ne $End -and [bool]$Start.held -and [bool]$End.held -and ([string]$Start.holder) -ceq ([string]$End.holder)
  return [pscustomobject][ordered]@{held=$held;holder=$(if ($held) { [string]$Start.holder } else { 'none' });start=$Start;end=$End}
}

Export-ModuleMember -Function Get-RebaseHash,Get-RebaseRecordIdentity,Get-RebaseObligationIdentity,Read-RebaseJson,Assert-RebaseKeys,Assert-RebaseObligation,Get-RebaseOwed,New-RebaseStart,Save-RebaseConflict,Complete-RebaseOwner,Adopt-RebaseCompletion,Read-RebaseCompletion,Assert-RebaseAcknowledgement,Write-RebaseRecord,Assert-RebaseProducerProcess,Get-RebaseAuthenticatedOwner,Get-InterruptedIntegrationState,Assert-InterruptedIntegrationTreeDead,New-InterruptedIntegrationResume,Assert-InterruptedIntegrationResume,Get-InterruptedIntegrationChild,Save-InterruptedIntegrationStop,Complete-InterruptedIntegration,Get-FleetLoadObservation,Get-FleetLoadWindow
