Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# #8580: the tracked history fixtures are the only source of retired controller
# sources for every battery item. This guard proves each fixture is exact and
# closed, that its consumers name it, that no orchestrator script still reads a
# fixture commit from Git history, and that the reader fails closed.
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
. (Join-Path $PSScriptRoot 'history-fixture.ps1')

$fixtureDirectory = Join-Path $PSScriptRoot 'fixtures/history'
$fixtures = @(Get-ChildItem -LiteralPath $fixtureDirectory -Filter '*.json' -File | Sort-Object Name)
Assert-True ($fixtures.Count -ge 9) "history fixtures present (found $($fixtures.Count))"
$scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse | Where-Object { $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar)fixtures$([IO.Path]::DirectorySeparatorChar)*" -and $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar)artifacts$([IO.Path]::DirectorySeparatorChar)*" })
$scriptText = @{}
foreach ($script in $scripts) { $scriptText[$script.FullName] = [IO.File]::ReadAllText($script.FullName) }
$historyRead = [regex]::new('\bgit(?:\.exe)?\b[^\r\n]*\b(?:show|archive|cat-file|fetch)\b', [Text.RegularExpressions.RegexOptions]::CultureInvariant)

$temp = Join-Path ([IO.Path]::GetTempPath()) ("history-fixture-test-" + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
  $totalRead = 0; $totalExistence = 0
  foreach ($file in $fixtures) {
    $commit = $file.BaseName
    Assert-True ($commit -cmatch '^[a-f0-9]{40}$') "fixture file is named by its full commit: $($file.Name)"
    $fixture = Read-HistoryFixture $commit
    Assert-True (@($fixture.consumers).Count -ge 1) "$commit names at least one consumer"
    Assert-True (@($fixture.files).Count -ge 1) "$commit holds at least one file"
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($fixture.files)) {
      Assert-True ($paths.Add([string]$entry.path)) "$commit lists $($entry.path) once"
      Assert-True ([string]$entry.path -cmatch '^\.orchestrator/[A-Za-z0-9._/-]+$' -and -not ([string]$entry.path).Contains('..')) "$commit path is a plain .orchestrator-relative path: $($entry.path)"
      Assert-True ([string]$entry.blob -cmatch '^[a-f0-9]{40}$' -and [string]$entry.sha256 -cmatch '^[a-f0-9]{64}$') "$commit $($entry.path) carries blob and sha256 provenance"
      $properties = @($entry.PSObject.Properties.Name)
      if ([string]$entry.mode -ceq 'read') {
        Assert-True ($properties -ccontains 'content') "$commit $($entry.path) read entry holds content"
        $bytes = Get-HistoryFixtureBytes $commit ([string]$entry.path)
        Assert-True ($bytes.Length -eq [int64]$entry.bytes -and $bytes.Length -gt 0) "$commit $($entry.path) exact byte count"
        $totalRead++
      } elseif ([string]$entry.mode -ceq 'existence-only') {
        Assert-True ($properties -cnotcontains 'content') "$commit $($entry.path) existence-only entry holds no bytes"
        $thrown = $null; try { [void](Get-HistoryFixtureBytes $commit ([string]$entry.path)) } catch { $thrown = $_.Exception.Message }
        Assert-True ($thrown -like '*holds no bytes*') "$commit $($entry.path) existence-only entry refuses byte reads"
        $totalExistence++
      } else { throw "ASSERTION FAILED: $commit $($entry.path) unknown mode $($entry.mode)" }
    }
    # Expansion materializes exactly the manifest, byte for byte.
    $destination = Join-Path $temp $commit.Substring(0, 8)
    $manifest = Expand-HistoryFixture $commit $destination
    Assert-True ($manifest.commit -ceq $commit -and @($manifest.files).Count -eq @($fixture.files).Count) "$commit expansion manifest is complete"
    $materialized = @(Get-ChildItem -LiteralPath $destination -Recurse -File)
    Assert-True ($materialized.Count -eq @($fixture.files).Count) "$commit expansion writes only manifest files"
    foreach ($entry in @($fixture.files)) {
      $target = Join-Path $destination (([string]$entry.path) -replace '/', [IO.Path]::DirectorySeparatorChar)
      Assert-True (Test-Path -LiteralPath $target -PathType Leaf) "$commit expanded $($entry.path)"
      if ([string]$entry.mode -ceq 'read') {
        Assert-True ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ceq [string]$entry.sha256) "$commit expanded $($entry.path) sha256"
      } else {
        Assert-True ((Get-Item -LiteralPath $target).Length -eq 0) "$commit expanded $($entry.path) is an empty placeholder"
      }
    }
    # Every consumer names the commit literally (so the battery impact index
    # reaches it) and no script reads that commit from Git history any more.
    $referencing = @($scripts | Where-Object { $scriptText[$_.FullName].Contains($commit) })
    Assert-True ($referencing.Count -ge 1) "$commit is referenced by a consumer script"
    foreach ($script in $referencing) {
      foreach ($line in @($scriptText[$script.FullName] -split "\r?\n" | Where-Object { $_.Contains($commit) })) {
        Assert-True (-not $historyRead.IsMatch($line)) "$($script.Name) no longer reads $commit from history: $($line.Trim())"
      }
    }
    Write-Output "FIXTURE $commit files=$(@($fixture.files).Count) read=$(@($fixture.files | Where-Object mode -ceq 'read').Count) existence-only=$(@($fixture.files | Where-Object mode -ceq 'existence-only').Count) consumers=$(@($fixture.consumers).Count)"
  }
  Write-Output "PASS history fixtures exact and closed fixtures=$($fixtures.Count) read=$totalRead existence-only=$totalExistence"

  # Fail-closed reader controls on a private copy of the helper and one fixture.
  $copyRoot = Join-Path $temp 'copy'
  [void][IO.Directory]::CreateDirectory((Join-Path $copyRoot 'fixtures/history'))
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'history-fixture.ps1') -Destination (Join-Path $copyRoot 'history-fixture.ps1')
  $subject = $fixtures | Where-Object { $_.BaseName -ceq '50e3695074960ed988996860ff9bf8a45d6b8bea' } | Select-Object -First 1
  Assert-True ($null -ne $subject) 'control fixture available'
  $copyFixture = Join-Path $copyRoot "fixtures/history/$($subject.Name)"
  $document = Get-Content -LiteralPath $subject.FullName -Raw | ConvertFrom-Json -DateKind String
  $runner = Join-Path $copyRoot 'read.ps1'
  [IO.File]::WriteAllText($runner, ". (Join-Path `$PSScriptRoot 'history-fixture.ps1')`nparam()`n", [Text.UTF8Encoding]::new($false))
  function Invoke-CopyReader([string]$Commit, [string]$Path) {
    $script = ". '$($copyRoot.Replace("'", "''"))\history-fixture.ps1'; try { [void](Get-HistoryFixtureText '$Commit' '$Path'); 'ACCEPTED' } catch { 'REFUSED: ' + `$_.Exception.Message }"
    return (& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -NonInteractive -Command $script | Select-Object -Last 1)
  }
  $missing = Invoke-CopyReader $subject.BaseName '.orchestrator/dispatch-ownership.ps1'
  Assert-True ($missing -like 'REFUSED: history fixture missing*') "absent fixture refuses: $missing"
  Copy-Item -LiteralPath $subject.FullName -Destination $copyFixture
  $accepted = Invoke-CopyReader $subject.BaseName '.orchestrator/dispatch-ownership.ps1'
  Assert-True ($accepted -ceq 'ACCEPTED') "intact copied fixture is accepted: $accepted"
  $document.files[0].content = ([string]$document.files[0].content).Replace('function', 'functiom')
  [IO.File]::WriteAllText($copyFixture, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
  $mutated = Invoke-CopyReader $subject.BaseName '.orchestrator/dispatch-ownership.ps1'
  Assert-True ($mutated -like 'REFUSED: history fixture bytes differ*') "altered fixture bytes refuse: $mutated"
  $document = Get-Content -LiteralPath $subject.FullName -Raw | ConvertFrom-Json -DateKind String
  $document.commit = 'e396120d26a766e467e0d01052939d6abf945e21'
  [IO.File]::WriteAllText($copyFixture, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
  $renamed = Invoke-CopyReader $subject.BaseName '.orchestrator/dispatch-ownership.ps1'
  Assert-True ($renamed -like 'REFUSED: history fixture identity differs*') "fixture naming a different commit refuses: $renamed"
  $document = Get-Content -LiteralPath $subject.FullName -Raw | ConvertFrom-Json -DateKind String
  $document.files[0].path = '.orchestrator/../escape.ps1'
  [IO.File]::WriteAllText($copyFixture, ($document | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
  $escaped = $null
  try { . (Join-Path $copyRoot 'history-fixture.ps1'); [void](Expand-HistoryFixture $subject.BaseName (Join-Path $temp 'escape')) } catch { $escaped = $_.Exception.Message }
  Assert-True ($escaped -like '*history fixture path refused*') "traversal path refuses expansion: $escaped"
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $temp 'escape.ps1'))) 'traversal wrote nothing outside the destination'
  Write-Output 'PASS history fixture reader fails closed on absent, altered, misnamed and escaping fixtures'
} finally {
  $resolved = [IO.Path]::GetFullPath($temp)
  if ((Split-Path -Leaf $resolved) -like 'history-fixture-test-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
