[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'dispatch-history-checkpoint.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('checkpoint-lifecycle-private-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Assert([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function New-Case {
  $directory=Join-Path $root ([guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($directory)
  $path=Join-Path $directory 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($path,'{"kind":"dispatch","issue":1}'+"`n",[Text.UTF8Encoding]::new($false))
  return $path
}
function Read-Case([string]$Path,[long]$Bytes=[long]::MaxValue,[int]$Rows=[int]::MaxValue){
  $script:metrics=$null
  return Read-CheckpointedDispatchHistory -Path $Path -MaxDeltaBytes $Bytes -MaxDeltaRows $Rows -ReadMetrics ([ref]$script:metrics)
}
function Assert-FullEquivalent($Actual,[string]$Path){
  $full=dispatch-ledger-reader\Read-DispatchCountHistory $Path
  Assert ($Actual.complete -and $full.complete) 'differential input refused'
  foreach($field in @('rows','audit','snapshotLength','snapshotLines','snapshotHash','cursor','partialTrailingRow')){
    Assert ((ConvertTo-Json -InputObject $Actual.$field -Depth 50 -Compress) -ceq (ConvertTo-Json -InputObject $full.$field -Depth 50 -Compress)) "differential field changed: $field"
  }
}
function Check([string]$Name,[scriptblock]$Body){& $Body;$script:checks++;"PASS lifecycle $Name"}
try {
  Check 'bootstrap-steady-delta' {
    $path=New-Case
    $first=Read-Case $path 1 0
    Assert-FullEquivalent $first $path
    Assert ($metrics.rebuilds -eq 1 -and $metrics.readPasses -eq 1 -and $metrics.tailParsedRows -eq 1 -and $metrics.publications -eq 1) 'bootstrap was capped or counted incorrectly'
    $steady=Read-Case $path
    Assert-FullEquivalent $steady $path
    Assert ($metrics.rebuilds -eq 0 -and $metrics.readPasses -eq 1 -and $metrics.tailParsedRows -eq 0 -and $metrics.publications -eq 0) 'steady reparsed prefix or rewrote unchanged checkpoint'
    [IO.File]::AppendAllText($path,'{"kind":"dispatch","issue":2}'+"`n",[Text.UTF8Encoding]::new($false))
    $delta=Read-Case $path 100 1
    Assert-FullEquivalent $delta $path
    Assert ($metrics.readPasses -eq 1 -and $metrics.tailParsedRows -eq 1 -and $metrics.publications -eq 1) 'delta reread or reparsed prefix'
    Assert ($first.rows[0].rawSha256 -ceq $delta.rows[0].rawSha256 -and $delta.rows[1].line -eq 2) 'cross-checkpoint identity changed'
  }
  Check 'version-invalid-rebuild' {
    foreach($kind in @('version','invalid')){
      $path=New-Case;[void](Read-Case $path)
      $checkpoint=Get-DispatchHistoryCheckpointPath $path
      if($kind -ceq 'invalid'){[IO.File]::WriteAllText($checkpoint,'{broken')}
      else {$e=Get-Content $checkpoint -Raw|ConvertFrom-Json -AsHashtable;$e.reducerVersion='old/v0';[IO.File]::WriteAllText($checkpoint,($e|ConvertTo-Json -Depth 50 -Compress))}
      $result=Read-Case $path 1 0
      Assert-FullEquivalent $result $path
      Assert ($metrics.rebuilds -eq 1 -and $metrics.tailParsedRows -eq 1 -and $metrics.publications -eq 1) "$kind did not discard/count rebuild"
      [void](Read-Case $path)
      Assert ($metrics.rebuilds -eq 0 -and $metrics.tailParsedRows -eq 0) "$kind did not return to steady"
    }
  }
  Check 'invalid-utf8-checkpoint-rebuild' {
    foreach($badBytes in @([byte[]]@(255),[byte[]]@(192,175))){
      $path=New-Case;[void](Read-Case $path)
      [IO.File]::WriteAllBytes((Get-DispatchHistoryCheckpointPath $path),$badBytes)
      $result=Read-Case $path
      Assert-FullEquivalent $result $path
      Assert ($metrics.rebuilds -eq 1 -and $metrics.quarantines -eq 1 -and $metrics.readPasses -eq 1 -and $metrics.publications -eq 1) 'invalid UTF8 checkpoint permanently blocked recovery'
    }
  }
  Check 'rewind-refuse-quarantine-next-read-rebuild' {
    $path=New-Case;[void](Read-Case $path)
    [IO.File]::WriteAllText($path,"{}`n",[Text.UTF8Encoding]::new($false))
    $refused=Read-Case $path
    Assert (-not $refused.complete -and $refused.reason -ceq 'CHECKPOINT_REWOUND' -and $refused.rows.Count -eq 0 -and $metrics.quarantines -eq 1 -and $metrics.rebuilds -eq 0) 'rewind silently rebuilt or trusted stale projection'
    Assert (-not [IO.File]::Exists((Get-DispatchHistoryCheckpointPath $path))) 'rewound checkpoint not quarantined'
    $rebuilt=Read-Case $path
    Assert-FullEquivalent $rebuilt $path
    Assert ($metrics.rebuilds -eq 1) 'next read did not rebuild rewind'
  }
  Check 'digest-and-coherent-projection-refusal' {
    foreach($mutation in @('canonical','cache')){
      $path=New-Case;[void](Read-Case $path)
      if($mutation -ceq 'canonical'){
        [IO.File]::WriteAllText($path,([IO.File]::ReadAllText($path).Replace('"issue":1','"issue":9')),[Text.UTF8Encoding]::new($false))
      } else {
        $checkpoint=Get-DispatchHistoryCheckpointPath $path
        $e=Get-Content $checkpoint -Raw|ConvertFrom-Json -AsHashtable
        $e.rows[0].raw=$e.rows[0].raw.Replace('"issue":1','"issue":9');$e.rows[0].value.issue=9
        $e.rows[0].rawSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($e.rows[0].raw))).ToLowerInvariant()
        [IO.File]::WriteAllText($checkpoint,($e|ConvertTo-Json -Depth 50 -Compress))
        Assert ((Read-DispatchHistoryCheckpoint $path).state -ceq 'valid') 'coherent cache control was not structurally valid'
      }
      $refused=Read-Case $path
      Assert (-not $refused.complete -and $refused.reason -ceq 'CHECKPOINT_DIGEST_MISMATCH' -and $refused.rows.Count -eq 0 -and $metrics.quarantines -eq 1 -and $metrics.rebuilds -eq 0) "$mutation not bound to canonical prefix"
      $rebuilt=Read-Case $path;Assert-FullEquivalent $rebuilt $path
      Assert ($metrics.rebuilds -eq 1) 'digest next-read rebuild absent'
    }
  }
  Check 'partial-tail-and-boundary' {
    $path=New-Case;$first=Read-Case $path
    [IO.File]::AppendAllText($path,'{"kind":"dispatch","issue":2}',[Text.UTF8Encoding]::new($false))
    $partial=Read-Case $path
    Assert-FullEquivalent $partial $path
    Assert ($partial.partialTrailingRow -and $partial.cursor -eq $first.cursor -and $metrics.tailParsedRows -eq 0 -and $metrics.publications -eq 0) 'partial advanced cursor, reparsed prefix or conflicted at equal cursor'
    $strict=Read-CheckpointedDispatchHistory $path -RequireTerminated
    Assert (-not $strict.complete -and $strict.reason -ceq 'HISTORY_UNTERMINATED_OR_MOVED') 'strict partial accepted'
    [IO.File]::AppendAllText($path,"`n",[Text.UTF8Encoding]::new($false))
    $completed=Read-Case $path;Assert-FullEquivalent $completed $path
    Assert ($completed.rows[1].line -eq 2 -and $metrics.tailParsedRows -eq 1) 'completed LF lost identity or parsed twice'
    $bytes=[IO.File]::ReadAllBytes($path);$bytes[$bytes.Length-1]=32;[IO.File]::WriteAllBytes($path,$bytes)
    $boundary=Read-Case $path
    Assert (-not $boundary.complete -and $boundary.rows.Count -eq 0 -and $metrics.quarantines -eq 1) 'non-LF prior boundary trusted'
  }
  Check 'changed-prefix-strict-partial-still-quarantines' {
    $path=New-Case;[void](Read-Case $path)
    $changed=[IO.File]::ReadAllText($path).Replace('"issue":1','"issue":9')+'{"partial":'
    [IO.File]::WriteAllText($path,$changed,[Text.UTF8Encoding]::new($false))
    $script:metrics=$null
    $result=Read-CheckpointedDispatchHistory $path -RequireTerminated -ReadMetrics ([ref]$script:metrics)
    Assert (-not $result.complete -and $result.reason -ceq 'CHECKPOINT_DIGEST_MISMATCH' -and $result.rows.Count -eq 0 -and $metrics.quarantines -eq 1) 'strict partial suppressed checkpoint invalidation'
    $next=Read-Case $path;Assert-FullEquivalent $next $path
    Assert ($metrics.rebuilds -eq 1 -and $next.partialTrailingRow) 'next observation did not rebuild only LF-complete changed prefix'
  }
  Check 'decode-failure-does-not-prove-prefix-change' {
    foreach($changed in @($false,$true)){
      foreach($strict in @($false,$true)){
        $path=New-Case;[IO.File]::WriteAllText($path,"{}`n");[void](Read-Case $path)
        $checkpoint=Get-DispatchHistoryCheckpointPath $path
        $before=[IO.File]::ReadAllBytes($checkpoint)
        $prefix=if($changed){"[]`n"}else{"{}`n"}
        $bytes=[byte[]]([Text.Encoding]::UTF8.GetBytes($prefix)+[byte[]]@(255,10)+[Text.Encoding]::UTF8.GetBytes('{"partial":'))
        [IO.File]::WriteAllBytes($path,$bytes);$script:metrics=$null
        $result=Read-CheckpointedDispatchHistory $path -RequireTerminated:$strict -ReadMetrics ([ref]$script:metrics)
        $reason=if($changed){'CHECKPOINT_DIGEST_MISMATCH'}elseif($strict){'HISTORY_UNTERMINATED_OR_MOVED'}else{'HISTORY_UNREADABLE'}
        Assert (-not $result.complete -and $result.reason -ceq $reason -and $result.rows.Count -eq 0) 'decode failure changed refusal precedence or invented prefix mismatch'
        Assert ($metrics.quarantines -eq [int]$changed -and $metrics.rebuilds -eq 0 -and $metrics.publications -eq 0 -and $metrics.readPasses -eq 1) 'decode failure caused false invalidation or extra canonical pass'
        if(-not $changed){
          Assert ([IO.File]::Exists($checkpoint) -and [Convert]::ToHexString([IO.File]::ReadAllBytes($checkpoint)) -ceq [Convert]::ToHexString($before)) 'unchanged prefix lost its valid checkpoint'
        }
      }
    }
  }
  Check 'delta-ceilings-not-whole-artifact' {
    foreach($limit in @('bytes','rows')){
      $path=New-Case;[void](Read-Case $path 1 0)
      [IO.File]::AppendAllText($path,"{}`n{}`n",[Text.UTF8Encoding]::new($false))
      $before=[IO.File]::ReadAllText((Get-DispatchHistoryCheckpointPath $path))
      $result=if($limit -ceq 'bytes'){Read-Case $path 1 100}else{Read-Case $path 100 1}
      Assert (-not $result.complete -and $result.reason -ceq 'HISTORY_TRUNCATED' -and $result.audit.truncated -and $metrics.publications -eq 0) "$limit delta ceiling absent"
      Assert ([IO.File]::ReadAllText((Get-DispatchHistoryCheckpointPath $path)) -ceq $before) 'ceiling refusal advanced checkpoint'
      $result=Read-Case $path;Assert-FullEquivalent $result $path
    }
  }
  Check 'missing-malformed-and-unreadable-refuse' {
    $path=New-Case;[IO.File]::Delete($path)
    $missing=Read-Case $path
    Assert (-not $missing.complete -and $missing.reason -ceq 'HISTORY_MISSING') 'missing invented authority'
    [IO.File]::WriteAllText($path,"bad`n")
    $malformed=Read-Case $path
    Assert (-not $malformed.complete -and $malformed.reason -ceq 'HISTORY_MALFORMED') 'malformed invented authority'
    [IO.File]::WriteAllText($path,"{}`n");[void](Read-Case $path)
    $checkpoint=Get-DispatchHistoryCheckpointPath $path;$before=[IO.File]::ReadAllText($checkpoint)
    $held=[IO.File]::Open($checkpoint,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try {$unreadable=Read-Case $path;Assert (-not $unreadable.complete -and $unreadable.reason -ceq 'CHECKPOINT_UNREADABLE' -and $unreadable.rows.Count -eq 0) 'unreadable cache rebuilt through monotonic guard'} finally {$held.Dispose()}
    Assert ([IO.File]::ReadAllText($checkpoint) -ceq $before) 'unreadable refusal overwrote checkpoint'
  }
  Check 'root-recreation-bootstrap-once' {
    $path=New-Case;[void](Read-Case $path)
    $directory=[IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($path))
    Assert ($directory.StartsWith([IO.Path]::GetFullPath($root)+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) 'root recreation escaped private case'
    Remove-Item -LiteralPath $directory -Recurse -Force
    [void][IO.Directory]::CreateDirectory($directory);[IO.File]::WriteAllText($path,"{}`n")
    $rebuilt=Read-Case $path;Assert-FullEquivalent $rebuilt $path
    Assert ($metrics.rebuilds -eq 1 -and $metrics.publications -eq 1) 'recreated root did not bootstrap'
    [void](Read-Case $path);Assert ($metrics.rebuilds -eq 0 -and $metrics.tailParsedRows -eq 0) 'root recreation repeatedly bootstrapped'
  }
  Check 'all-four-watchdog-consumers-use-checkpoints' {
    $file=Join-Path $PSScriptRoot 'lane-stall-watchdog.ps1'
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) 'watchdog parse failed'
    $calls=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
    Assert (@($calls|Where-Object {$_ -ceq 'dispatch-history-checkpoint\Read-CheckpointedDispatchHistory'}).Count -eq 4) 'watchdog checkpoint consumer census changed'
    Assert (@($calls|Where-Object {$_ -match '(^|\\)Read-(ExactHeadReviewHistory|DispatchCountHistory)$'}).Count -eq 0) 'watchdog bypasses persisted checkpoint owner'
  }
  "PASS checkpoint lifecycle cases=$script:checks canonicalBinding=true parseDeltaOnly=true"
} finally {
  $full=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
  if(-not $full.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notlike 'checkpoint-lifecycle-private-*'){throw 'cleanup escaped private fixture'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
