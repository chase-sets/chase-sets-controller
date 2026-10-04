$ErrorActionPreference = "Stop"

$snapshot = Join-Path $PSScriptRoot "frontier-bounded-snapshot.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("frontier-snapshot-test-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null

function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

try {
  # gh stub: label queries drive the frontier, so the fixture is expressed as
  # label -> issue numbers exactly the way the live repo expresses it.
  $stub = Join-Path $testRoot "gh-stub.ps1"
  @'
$ErrorActionPreference = "Stop"
$a = @($args)
$labelIndex = [array]::IndexOf($a, "--label")
$label = if ($labelIndex -ge 0) { $a[$labelIndex + 1] } else { $null }

function Emit($o) { Write-Output (ConvertTo-Json -InputObject $o -Compress -Depth 6) }
# When a label matches nothing, real gh prints "[]"; the empty-set path is the
# healthy steady state and must not throw.
if ($env:FRONTIER_STUB_EMPTY -eq "1" -and $a[0] -eq "issue" -and $a[1] -eq "list" -and -not ($a -contains "--search")) {
  Write-Output ""
  exit 0
}

if ($a[0] -eq "issue" -and $a[1] -eq "list") {
  if ($a -contains "--search") { Emit @(); exit 0 }
  $byLabel = @{
    "status:needs-replan"  = @(5616, 5684, 5748)
    "status:tracking-only" = @(5981)
    "decision"             = @()
    "priority:p0"          = @(5616, 9100)
  }
  $numbers = if ($byLabel.ContainsKey($label)) { $byLabel[$label] } else { @() }
  if ($a -contains "number,title,updatedAt,url") {
    Emit @($numbers | ForEach-Object { @{ number = $_; title = "t$_"; updatedAt = "2026-07-25T00:00:00Z"; url = "u$_" } })
  } else {
    Emit @($numbers | ForEach-Object { @{ number = $_ } })
  }
  exit 0
}
if ($a[0] -eq "issue" -and $a[1] -eq "view") {
  $n = [int]$a[2]
  $labels = switch ($n) {
    5616 { @(@{ name = "status:needs-replan" }, @{ name = "priority:p1" }) }
    5684 { @(@{ name = "status:needs-replan" }) }
    5748 { @(@{ name = "status:needs-replan" }) }
    5981 { @(@{ name = "status:tracking-only" }) }
    default { @() }
  }
  Emit @{
    number = $n; title = "issue $n"; state = "OPEN"; body = "body $n"
    labels = $labels; milestone = @{ title = "Wave 1" }
    comments = @(@{ createdAt = "2026-07-25T00:00:00Z"; body = "c"; url = "cu"; author = @{ login = "todd" } })
    closedAt = $null; updatedAt = "2026-07-25T00:00:00Z"; url = "https://x/$n"
  }
  exit 0
}
if ($a[0] -eq "pr" -and $a[1] -eq "list") { Emit @(@{ number = 6100 }); exit 0 }
if ($a[0] -eq "pr" -and $a[1] -eq "view") {
  $n = [int]$a[2]
  Emit @{
    number = $n; title = "pr $n"; state = "OPEN"; isDraft = $false
    headRefOid = ("b" * 40); baseRefOid = ("c" * 40); mergeStateStatus = "CLEAN"
    body = "pr body"; comments = @(); updatedAt = "2026-07-25T00:00:00Z"; url = "https://p/$n"
  }
  exit 0
}
Write-Error "unexpected gh invocation: $($a -join ' ')"
exit 1
'@ | Set-Content -LiteralPath $stub -Encoding utf8

  $result = & $snapshot -GhCommand $stub | ConvertFrom-Json

  $numbers = @($result.issues | ForEach-Object { $_.number })
  foreach ($expected in @(5616, 5684, 5748)) {
    Assert-True ($numbers -contains $expected) "#$expected reaches the frontier from its label, with no hard-coded list"
  }
  Assert-True ($numbers -contains 5981) "tracking-only originals stay on the frontier until their replacement lands"
  Assert-True ($numbers -contains 9100) "P0s still reach the frontier"

  Assert-True (@($numbers | Where-Object { $_ -eq 5616 }).Count -eq 1) "an issue matching two frontier sources appears exactly once"

  $replan = @($result.issues | Where-Object { $_.number -eq 5684 })[0]
  Assert-True ($replan.lifecycle -eq "needs-replan") "recovery state is a structured field, not prose a consumer must parse"
  $tracking = @($result.issues | Where-Object { $_.number -eq 5981 })[0]
  Assert-True ($tracking.lifecycle -eq "tracking-only") "tracking-only is distinguishable from needs-replan"

  Assert-True ($result.frontierSources.counts.needsReplan -eq 3) "the snapshot reports how much replan debt it found"
  Assert-True (-not $result.frontierSources.issuesTruncated) "an unbounded-enough frontier reports no truncation"

  # Explicit additions are additive, never a replacement for the queries.
  $withExplicit = & $snapshot -GhCommand $stub -Issue 4129 | ConvertFrom-Json
  $explicitNumbers = @($withExplicit.issues | ForEach-Object { $_.number })
  Assert-True ($explicitNumbers -contains 4129) "explicit additions are honored"
  Assert-True ($explicitNumbers -contains 5684) "explicit additions do not displace the derived frontier"

  # Truncation must be loud (SKILL section 15: no silent caps).
  $bounded = & $snapshot -GhCommand $stub -MaxIssues 2 | ConvertFrom-Json
  Assert-True ($bounded.frontierSources.issuesTruncated) "exceeding the bound is reported, never silently dropped"
  Assert-True (@($bounded.frontierSources.droppedIssues).Count -gt 0) "the dropped issue numbers are named"
  Assert-True (@($bounded.issues).Count -eq 2) "the bound is actually enforced"

  # Zero replan debt is the goal state, so it must be the quietest path, not a
  # crash. This caught a real defect: empty gh output parsed as null and threw.
  try {
    $env:FRONTIER_STUB_EMPTY = "1"
    $empty = & $snapshot -GhCommand $stub | ConvertFrom-Json
    Assert-True (@($empty.issues).Count -eq 0) "an empty frontier produces an empty issue set"
    Assert-True ($empty.frontierSources.counts.needsReplan -eq 0) "zero replan debt reports as zero, not as an error"
  } finally {
    Remove-Item Env:FRONTIER_STUB_EMPTY -ErrorAction SilentlyContinue
  }

  # Structural guard for the defect this script had: a hand-maintained frontier.
  $source = [IO.File]::ReadAllText($snapshot)
  $arrayLiteral = [regex]::Match($source, '\$issueNumbers\s*=\s*@\(\s*\d{3,}')
  Assert-True (-not $arrayLiteral.Success) "the frontier is never re-hard-coded: no literal issue-number array may reappear"

  Write-Output "PASS frontier-bounded-snapshot live-derivation coverage"
} finally {
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd("\", "/")
  if ((Split-Path -Parent $resolved).TrimEnd("\", "/") -ne $temp -or
      (Split-Path -Leaf $resolved) -notlike "frontier-snapshot-test-*") {
    throw "refusing unsafe test cleanup target: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
