[CmdletBinding()]
param([string]$ControllerRoot=(Split-Path -Parent $PSScriptRoot),[string]$CensusPath='')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
function Assert-Reader($Condition,[string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
& (Join-Path $PSScriptRoot 'ledger-reader-ast-selection.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-provenance.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-exclusion.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-path-value.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-traps.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-embedded-writer.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-ci-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-json-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-metrics-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-report-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-evidence-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-install-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-retention-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-heavy-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-integration-contract-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-battery-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-watchdog-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-dispatch-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-cost-owner-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-unterminated-lines.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-routing-history.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-routing-boundary-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-board-preflight-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-reclamation-matrix-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-reclamation-history.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-guard-receipt-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-direct-native-paths.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-direct-tail.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-board-history.test.ps1')
& (Join-Path $PSScriptRoot 'ledger-reader-query-paths.test.ps1')
$census=Get-LedgerReaderCensus -Root $ControllerRoot
foreach ($row in $census.rows) { Write-Output ("CENSUS {0}:{1} role={2} family={3} authority={4} owner={5} test={6} handled={7}" -f $row.path,$row.line,$row.role,$row.family,$row.authority,$row.owner,$row.test,$row.handled) }
if ($CensusPath) { $census | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $CensusPath -Encoding utf8 }
Assert-Reader ($census.scanned -eq $census.total -and $census.total -gt 0) 'incomplete tracked source scan'
Assert-Reader (-not $census.violations.Count) ("uncensused or bypass reader: "+($census.violations | ConvertTo-Json -Depth 8 -Compress))
Assert-Reader (@($census.rows | Where-Object test).Count -gt 0) 'test/fixture readers must be reported, not guarded'
Assert-Reader (@($census.rows | Where-Object { $_.role -eq 'retention-pattern' }).Count -gt 0) 'retention role lost'
Assert-Reader (@($census.rows | Where-Object { $_.authority -eq 'cost' }).Count -gt 0) 'cost exclusions lost'

$queryPath='.orchestrator/controller-skills/milestone-orchestrator/scripts/query-ledgers.ps1'
$query=[IO.File]::ReadAllText((Join-Path $ControllerRoot $queryPath))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($query,[ref]$tokens,[ref]$errors)
$redirect=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-DispatchCountHistory'},$true)
Assert-Reader ($null -ne $redirect) 'installed compatibility entrypoint removed'
$calls=@($redirect.Body.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'dispatch-ledger-reader\Read-DispatchCountHistory'},$true))
Assert-Reader ($calls.Count -eq 1 -and $redirect.Extent.Text -notmatch 'IO\.File|GetTempFileName|ReadExactly|snapshotHash|ConvertFrom-Json') 'old fold not removed or redirect no longer delegates'
$owner=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1'))
Assert-Reader ($owner -notmatch 'Import-Module|review-head-contract|query-ledgers\.ps1') 'owner/parser import recursion'
Assert-Reader ($owner -match '\[IO.File\]::Open\(\$Path,\[IO.FileMode\]::Open,\[IO.FileAccess\]::Read,\[IO.FileShare\]::ReadWrite\)') 'canonical read-only shared owner open changed'
Assert-Reader (@($census.rows | Where-Object { $_.role -eq 'reader' -and -not $_.test -and $_.family -ne 'owner-api' -and $_.authority -eq 'dispatch' }).Count -eq 1) 'sole native owner violated'
$review=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'review-head-contract.psm1'))
$reviewAst=[Management.Automation.Language.Parser]::ParseInput($review,[ref]$tokens,[ref]$errors)
$adapter=$reviewAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-ExactHeadReviewHistory'},$true)
Assert-Reader ($adapter -and $adapter.Extent.Text -match 'dispatch-ledger-reader\\Read-DispatchCountHistory' -and $adapter.Extent.Text -notmatch 'OpenText|ReadLine|ConvertFrom-Json') 'strict parser ownership/removal drift'

# Contract API families are explicit; paths/roles come only from the census.
# Every pair exercises ordinary and sibling syntax against the same guard.
$families=[ordered]@{
  'IO.File.Open'=@('[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)', '[System.IO.File]::Open( $p, [System.IO.FileMode]::Open )')
  'IO.File.OpenRead'=@('[IO.File]::OpenRead($p)', '[System.IO.File]::OpenRead( $p )')
  'IO.File.OpenText'=@('[IO.File]::OpenText($p)', '[System.IO.File]::OpenText( $p )')
  'IO.File.ReadLines'=@('[IO.File]::ReadLines($p)', '[System.IO.File]::ReadLines( $p )')
  'IO.File.ReadAllLines'=@('[IO.File]::ReadAllLines($p)', '[System.IO.File]::ReadAllLines( $p )')
  'IO.File.ReadAllText'=@('[IO.File]::ReadAllText($p)', '[System.IO.File]::ReadAllText( $p )')
  'IO.File.ReadAllBytes'=@('[IO.File]::ReadAllBytes($p)', '$io=[System.IO.File];$io::ReadAllBytes($p)')
  'Get-Content'=@('Get-Content -LiteralPath $p', '& ''Microsoft.PowerShell.Management\Get-Content'' -Path $p', 'Set-Alias ledgerRead Get-Content; ledgerRead -LiteralPath $p')
  'StreamReader'=@('[IO.StreamReader]::new($p)', 'New-Object -TypeName System.IO.StreamReader -ArgumentList $p')
  'FileStream'=@('[IO.FileStream]::new($p,[IO.FileMode]::Open)', 'New-Object System.IO.FileStream -ArgumentList $p,([IO.FileMode]::Open)')
  'embedded-C#.File.ReadLines'=@('Add-Type ''class Mutant { void Read() { foreach(var x in System.IO.File.ReadLines("dispatch-log.jsonl")) {} } }''', 'Add-Type ''class Sibling { void Read() { foreach(var x in File . ReadLines ("dispatch-log.jsonl")) {} } }''')
}
$readerFiles=@($census.rows | Where-Object { -not $_.test -and $_.role -eq 'reader' -and $_.authority -eq 'dispatch' } | Select-Object -ExpandProperty path -Unique)
Assert-Reader ($readerFiles.Count -gt 1) 'derived reader-role file set empty'
function Mutate([string]$Path,[string]$Expression) {
  $text=[IO.File]::ReadAllText((Join-Path $ControllerRoot $Path))
  $text+="`nfunction Invoke-UnownedLedgerProbe { `$origin=Join-Path `$HOME 'dispatch-log.jsonl'; `$p=`$origin; $Expression }`n"
  return Get-LedgerReaderCensus -Root $ControllerRoot -SourceOverride @{$Path=$text}
}
foreach ($family in $families.Keys) {
  foreach ($syntax in $families[$family]) {
    $mutant=Mutate $readerFiles[0] $syntax
    Assert-Reader (@($mutant.violations | Where-Object path -CEQ $readerFiles[0]).Count -gt 0) "SURVIVED API family $family / $syntax"
    Write-Output "KILLED family=$family syntax=$syntax"
  }
}
foreach ($path in $readerFiles) {
  $mutant=Mutate $path '[IO.File]::ReadAllBytes($p)'
  Assert-Reader (@($mutant.violations | Where-Object path -CEQ $path).Count -gt 0) "SURVIVED reader-role file $path"
  $canonical=Mutate $path 'Read-DispatchLedgerSnapshot -Path $p'
  Assert-Reader (-not $canonical.violations.Count) "canonical-entrypoint rejected for $path"
  Write-Output "KILLED reader-role=$path canonical-entrypoint=accepted removal=owned"
}
foreach ($syntax in @('[IO.File]::UnknownReadFamily($p)','[Unclassified.IO]::ReadAllText($p)','& $unclassifiedReader $p','Invoke-UnknownLedgerReader $p','$unknownType::ReadAllText($p)','New-Object $unknownType -ArgumentList $p')) {
  Assert-Reader ((Mutate $readerFiles[0] $syntax).violations.Count -gt 0) "unknown/unclassified must fail closed: $syntax"
}
# The exclusion is per use, never per file: a direct dispatch read in a
# file also consuming cost history must still be killed by the same guard.
$costFiles=@($census.rows | Where-Object { -not $_.test -and $_.authority -eq 'cost' } | Select-Object -ExpandProperty path -Unique)
foreach ($path in $costFiles) { Assert-Reader ((Mutate $path '[IO.File]::ReadLines($p)').violations.Count -gt 0) "cost file exemption leaked: $path" }
$testOnly=Mutate '.orchestrator/ledger-reader-contract.test.ps1' '[IO.File]::ReadAllBytes($p)'
Assert-Reader (-not $testOnly.violations.Count -and @($testOnly.rows | Where-Object { $_.test -and $_.family -eq 'IO.File.ReadAllBytes' }).Count) 'fixture/test reporting became a production exemption or a guard target'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('ledger-census-'+[guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory($temporary)
  & git -C $temporary init -q
  Assert-Reader ($LASTEXITCODE -eq 0) 'missing-path fixture init'
  $file=Join-Path $temporary 'reader.ps1';[IO.File]::WriteAllText($file,'# tracked')
  & git -C $temporary add reader.ps1
  Assert-Reader ($LASTEXITCODE -eq 0) 'missing-path fixture track'
  [IO.File]::WriteAllText($file,'[IO.File]::ReadAllText((Join-Path $HOME ''dispatch-log.jsonl''))')
  & git -C $temporary add reader.ps1
  & git -C $temporary -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm census
  Assert-Reader ($LASTEXITCODE -eq 0) 'unfamiliar-path fixture commit'
  $unknownPath=Get-LedgerReaderCensus -Root $temporary
  Assert-Reader ($unknownPath.violations.Count -eq 1 -and $unknownPath.rows[0].path -ceq 'reader.ps1') 'path-vocabulary scoped guard missed new reader role'
  Remove-Item -LiteralPath $file
  $refused=$false
  try { Get-LedgerReaderCensus -Root $temporary | Out-Null } catch { $refused=$_.Exception.Message -like 'LEDGER_CENSUS_PATH_MISSING:*' }
  Assert-Reader $refused 'missing tracked path silently skipped'
} finally {
  $full=[IO.Path]::GetFullPath($temporary)
  if ((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-census-*') { throw 'unsafe census fixture cleanup' }
  Remove-Item -LiteralPath $full -Recurse -Force
}
Write-Output "PASS ledger sole-reader contract scanned=$($census.scanned)/$($census.total) readerFiles=$($readerFiles.Count)"
