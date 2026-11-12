param([string]$LiveLedgerPath)
$ErrorActionPreference = "Stop"
$readerCompatibilityRuntime=([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..')))
. (Join-Path $readerCompatibilityRuntime 'ledger-reader-compatibility.test-support.ps1')
Test-DispatchLedgerConsumerCompatibility -Consumer 'query' -RuntimeRoot $readerCompatibilityRuntime

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "FAIL: $Message" }
}

$sandbox = Join-Path ([IO.Path]::GetTempPath()) "ledger-query-$([guid]::NewGuid().ToString('N'))"
try {
  New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
  @"
# Stall-gotcha ledger

## codex-stdin (first seen 2026-07-01)
Symptom: Codex waits for stdin.
Root cause: inherited stdin stays open.
Detection: output stops at the stdin banner.
Remedy: close stdin before launching Codex.
Standing rule: launcher.

## deploy-mask (first seen 2026-07-01)
Symptom: staging is stale.
Root cause: resolver job is mistaken for deploy.
Detection: inspect the executed deploy job.
Remedy: select the actual deploy job.
Standing rule: landing.
"@ | Set-Content -LiteralPath (Join-Path $sandbox "stall-gotchas.md") -Encoding utf8

  @"
# Defect-class ledger

## schema-without-migration (first bitten 2026-07-01)
Defect: runtime SQL references a column no migration creates.
Territory: Postgres schema and migration files.
Territory globs: bounded-contexts/*/support/migrations/**
Occurrences: one.
Guard issue: #1.
Constraint for dispatch prompts: Ship the migration with the schema consumer.
Structural guard: migration checker.

## css-only-regression (first bitten 2026-07-01)
Defect: responsive geometry is not exercised.
Territory: CSS and visual evidence.
Occurrences: one.
Constraint for dispatch prompts: Capture responsive evidence.
Structural guard: visual test.
"@ | Set-Content -LiteralPath (Join-Path $sandbox "defect-classes.md") -Encoding utf8

  $script = Join-Path $PSScriptRoot "query-ledgers.ps1"
  $historical=Join-Path $sandbox 'historical-dispatch.jsonl'
  Copy-Item (Join-Path $PSScriptRoot '../../../fixtures/controller-review-7978-originals.jsonl') $historical
  $before=(Get-FileHash $historical).Hash
  $read=& $script -HistoricalDispatchLog $historical|ConvertFrom-Json
  Assert-True ($read.complete -and $read.rows-eq2 -and $read.retiredRows-eq2 -and(Get-FileHash $historical).Hash-ceq$before) 'historical dispatch fixture read changed bytes or refused retired selectors'
  if($LiveLedgerPath){
    $before=(Get-FileHash -LiteralPath $LiveLedgerPath).Hash
    $read=& $script -HistoricalDispatchLog $LiveLedgerPath|ConvertFrom-Json
    Assert-True ($read.complete -and $read.rows-gt2 -and $read.retiredRows-gt0 -and(Get-FileHash -LiteralPath $LiveLedgerPath).Hash-ceq$before) 'live historical ledger did not parse read-only'
    Write-Output "PASS live historical dispatch ledger rows=$($read.rows) retiredRows=$($read.retiredRows) unchanged=$before"
  }
  $query = @(
    & pwsh -NoProfile -NonInteractive -File $script `
      -ReferenceRoot $sandbox `
      -Mode implementation `
      -Text "Postgres schema change" `
      -Footprint "bounded-contexts/catalog/support/migrations/001.sql" `
      -Json
  ) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "query should succeed"
  $result = $query | ConvertFrom-Json
  Assert-True ($result.resultCount -ge 1) "schema query should return a match"
  Assert-True ($result.entries[0].slug -eq "schema-without-migration") "schema entry should rank first"
  Assert-True ($result.entries[0].instruction -match "migration") "query should return the compact constraint"

  $auditText = @(
    & pwsh -NoProfile -NonInteractive -File $script `
      -ReferenceRoot $sandbox `
      -Audit `
      -Json
  ) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "audit should succeed"
  $audit = $auditText | ConvertFrom-Json
  Assert-True ($audit.stallEntries -eq 2) "audit counts stall entries"
  Assert-True ($audit.defectEntries -eq 2) "audit counts defect entries"
  Assert-True ($audit.defectWithTerritoryGlobs -eq 1) "audit reports glob coverage"

  $fallbackText = @(
    & pwsh -NoProfile -NonInteractive -File $script `
      -InstalledReferenceRoot $sandbox `
      -Audit `
      -Json
  ) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) "source skill without mutable ledgers should use the installed reference root"
  $fallback = $fallbackText | ConvertFrom-Json
  Assert-True ($fallback.stallEntries -eq 2) "installed fallback counts stall entries"
  Assert-True ($fallback.defectEntries -eq 2) "installed fallback does not automatically load archived controller history"
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../../docs/archive/milestone-orchestrator/controller-defect-classes.md') -Destination $sandbox
  $planningText=@(& pwsh -NoProfile -NonInteractive -File $script -InstalledReferenceRoot $sandbox `
    -ReferenceRoot $sandbox -Mode dispatch -Text 'planning-repair unsupported_encrypted_delegation' -Footprint '.orchestrator/contracts/planning-repair-v1.md' -Json) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) 'planning dispatch query succeeds with reviewed supplement'
  $planning=$planningText|ConvertFrom-Json
  Assert-True (@($planning.entries|Where-Object slug -eq 'unattributed-nested-model-dispatch').Count -eq 1) 'planning dispatch retrieves host-review constraint'
  $entry = @($planning.entries | Where-Object slug -eq 'unattributed-nested-model-dispatch')
  Assert-True ($entry[0].instruction.Contains('review-probe-live-provider-credential-inheritance') -and
    $entry[0].instruction.Contains('review-isolation-opt-in-by-default') -and
    $entry[0].guard.Contains('CONTRACT_AND_REGRESSION')) 'explicit archive query retains both cross-references and guard status'
  $foregroundText=@(& pwsh -NoProfile -NonInteractive -File $script -InstalledReferenceRoot $sandbox `
    -ReferenceRoot $sandbox -Mode dispatch -Text 'Claude lane gate exceeds tool timeout auto-background' -Footprint '.orchestrator/dispatch-lane.ps1' -Json) -join "`n"
  Assert-True ($LASTEXITCODE -eq 0) 'Claude foreground dispatch query succeeds with reviewed supplement'
  $foreground=$foregroundText|ConvertFrom-Json
  Assert-True ($foreground.entries[0].slug -eq 'claude-foreground-gate-exceeds-tool-limit' -and $foreground.entries[0].instruction -match 'No auto-backgrounding' -and $foreground.entries[0].instruction -match 'claude-background-task-dies-on-session-exit') 'Claude lane dispatch ranks the foreground-gate constraint first with its overlapping constraints'

  # Physical cliffs only: whitespace LF padding is inert, not 50000 events.
  function Invoke-HistoricalCli([string]$Path) {
    $identity=@((Get-FileHash $Path).Hash,(Get-Item $Path).Length,(Get-Item $Path).LastWriteTimeUtc.Ticks)
    $output=@(& pwsh -NoProfile -NonInteractive -File $script -HistoricalDispatchLog $Path 2>&1) -join "`n"
    $exit=$LASTEXITCODE
    Write-Host "CLI historical nativeExit=$exit inputSha256=$($identity[0]) bytes=$($identity[1]) lastwriteTicks=$($identity[2]) output=$output"
    Assert-True ($exit -eq 0) "historical actual CLI native exit=$exit output=$output"
    Assert-True (($identity|ConvertTo-Json -Compress) -ceq (@((Get-FileHash $Path).Hash,(Get-Item $Path).Length,(Get-Item $Path).LastWriteTimeUtc.Ticks)|ConvertTo-Json -Compress)) 'historical actual CLI must preserve hash/length/lastwrite'
    $output|ConvertFrom-Json -DateKind String|ConvertTo-Json -Compress -Depth 100
  }
  $cliffPath=Join-Path $sandbox 'historical-physical-cliff.jsonl'
  $cliffBackup=Join-Path $sandbox 'historical-physical-original.jsonl'
  $smallPath=Join-Path $sandbox 'historical-small-oracle.jsonl'
  $early=@('{"kind":"dispatch","model":"gpt-5.6-sol"}', '{"kind":"review-complete","reviewerModel":"claude-opus-5","authorModel":"gpt-5.6-terra"}')
  $late='{"kind":"dispatch","model":"gpt-6.1-sol"}'
  $append='{"kind":"review-complete","model":"claude-opus-5"}'
  $padding=' '*700
  $writer=[IO.StreamWriter]::new($cliffPath,$false,[Text.UTF8Encoding]::new($false));$writer.NewLine="`n"
  try {
    foreach($line in $early){$writer.WriteLine($line)}
    for($i=0;$i -lt 51000;$i++){$writer.WriteLine($padding)}
    $writer.WriteLine($late)
  } finally {$writer.Dispose()}
  $physicalRows=0;foreach($line in [IO.File]::ReadLines($cliffPath)){$physicalRows++}
  $original=Get-Item $cliffPath;$originalLength=$original.Length;$originalTime=$original.LastWriteTimeUtc
  $originalHash=(Get-FileHash $cliffPath).Hash
  Assert-True ($physicalRows -eq 51003 -and $originalLength -gt 33554432) 'historical fixture must exceed both physical cliffs'
  Copy-Item -LiteralPath $cliffPath -Destination $cliffBackup
  [IO.File]::WriteAllText($smallPath,($early+@($late) -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  $small=Invoke-HistoricalCli $smallPath
  $expected=[ordered]@{schemaVersion='historical-dispatch-ledger-read/v1';complete=$true;rows=3;retiredRows=2}|ConvertTo-Json -Compress
  $whole=Invoke-HistoricalCli $cliffPath
  Assert-True ($small -ceq $expected -and $whole -ceq $small -and (Invoke-HistoricalCli $cliffPath) -ceq $whole) 'historical full/default and deterministic small oracle whole results'
  foreach($control in @('last50000','prefix32MiB')){
    $writer=[IO.StreamWriter]::new($cliffPath,$false,[Text.UTF8Encoding]::new($false));$writer.NewLine="`n"
    $reader=[IO.StreamReader]::new($cliffBackup,[Text.UTF8Encoding]::new($false,$true))
    $lineNumber=0;$writtenBytes=0L;$writtenRows=0;$nextBytes=0
    try {
      while($null -ne ($line=$reader.ReadLine())){
        $lineNumber++;$nextBytes=[Text.Encoding]::UTF8.GetByteCount($line)+1
        if($control -ceq 'last50000' -and $lineNumber -le ($physicalRows-50000)){continue}
        if($control -ceq 'prefix32MiB' -and $writtenBytes+$nextBytes -gt 33554432){break}
        $writer.WriteLine($line);$writtenBytes+=$nextBytes;$writtenRows++
      }
    } finally {$reader.Dispose();$writer.Dispose()}
    Assert-True ($(if($control -ceq 'last50000'){$writtenRows -eq 50000}else{$writtenBytes -le 33554432 -and $writtenBytes+$nextBytes -gt 33554432})) "historical actual $control geometry"
    $cut=Invoke-HistoricalCli $cliffPath
    $cutExpected=[ordered]@{schemaVersion='historical-dispatch-ledger-read/v1';complete=$true;rows=$(if($control -ceq 'last50000'){1}else{2});retiredRows=$(if($control -ceq 'last50000'){0}else{2})}|ConvertTo-Json -Compress
    Assert-True ($cut -ceq $cutExpected -and $cut -cne $whole) "historical $control must discriminate complete rows and retiredRows"
    Copy-Item -LiteralPath $cliffBackup -Destination $cliffPath -Force
    [IO.File]::SetLastWriteTimeUtc($cliffPath,$originalTime)
    Assert-True ((Get-FileHash $cliffPath).Hash -ceq $originalHash -and (Get-Item $cliffPath).Length -eq $originalLength -and (Get-Item $cliffPath).LastWriteTimeUtc -eq $originalTime -and (Invoke-HistoricalCli $cliffPath) -ceq $whole) "historical $control restores original identity and whole result"
    Write-Output "PASS historical actual CLI $control rows=$writtenRows bytes=$writtenBytes result=$cut restoration=hash,length,lastwrite,whole-result"
  }
  foreach($path in @($cliffPath,$smallPath)){[IO.File]::AppendAllText($path,$append+"`n",[Text.UTF8Encoding]::new($false))}
  $appended=Invoke-HistoricalCli $cliffPath
  $appendExpected=[ordered]@{schemaVersion='historical-dispatch-ledger-read/v1';complete=$true;rows=4;retiredRows=3}|ConvertTo-Json -Compress
  Assert-True ($appended -ceq $appendExpected -and $appended -ceq (Invoke-HistoricalCli $smallPath) -and $appended -ceq (Invoke-HistoricalCli $cliffPath)) 'historical late valid append whole small equality and deterministic read-only replay'
  Write-Output "PASS historical actual CLI default bounds physicalLF=$physicalRows bytes=$originalLength parsedEvents=3 whole=$whole append=$appended; no model admission or memory qualification"

  Write-Output "PASS query-ledgers relevance and audit coverage"
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
  }
}
