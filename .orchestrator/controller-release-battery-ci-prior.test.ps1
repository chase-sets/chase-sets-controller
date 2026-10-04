[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# Load definitions and the real reuse/merge blocks, never the battery entry,
# admission, host discovery, census or live runtime. All inputs are private.
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-release-battery.ps1'))
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'battery parse failed' }
foreach ($definition in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
  . ([scriptblock]::Create($definition.Extent.Text))
}
$reuseStart = $source.IndexOf('# Reuse (#8207).', [StringComparison]::Ordinal)
$reuseEnd = $source.IndexOf('# Fast items run first', [StringComparison]::Ordinal)
$reuseBlock = [scriptblock]::Create($source.Substring($reuseStart, $reuseEnd - $reuseStart))
$mergeStart = $source.IndexOf('$timingLines =', [StringComparison]::Ordinal)
$mergeEnd = $source.IndexOf('function Write-BatteryRecap', [StringComparison]::Ordinal)
$mergeBlock = [scriptblock]::Create($source.Substring($mergeStart, $mergeEnd - $mergeStart))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('battery-ci-prior-' + [guid]::NewGuid().ToString('N'))
$controller = Join-Path $testRoot 'controller'
$runtime = Join-Path $controller '.orchestrator'
$artifacts = Join-Path $runtime 'artifacts'
[void][IO.Directory]::CreateDirectory($artifacts)
$assertions = 0
function Assert-Test([bool]$Value, [string]$Message) {
  $script:assertions++
  if (-not $Value) { throw "ASSERTION FAILED: $Message" }
}
function Write-Json($Value, [string]$Path) {
  [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 40 -Compress), [Text.UTF8Encoding]::new($false))
}
function Git-Fixture([string[]]$Arguments) {
  $output = @(& git -C $controller @Arguments 2>&1)
  if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
  return ($output -join "`n").Trim()
}
function Get-BatteryCiApi([string]$Endpoint) {
  # Exact synthetic endpoints: an unexpected call cannot reach the network.
  switch -CaseSensitive ($Endpoint) {
    'actions/runs/12345' { return $script:run }
    'actions/runs/12345/artifacts?per_page=100' { return $script:artifactList }
    ('git/commits/' + ('a' * 40)) { return $script:snapshot }
    default { throw 'CI_API_UNEXPECTED' }
  }
}
function Save-BatteryCiArtifact([string]$ArtifactId, [string]$Path) {
  Assert-Test ($ArtifactId -ceq '67890') 'download exact artifact id'
  [IO.File]::Copy($script:zipPath, $Path, $true)
}
function Get-BatteryFleetLoad { return 'none' }
function Invoke-FixtureItem {
  param([string]$Identity)
  $script:executions.Add($Identity)
  if ($Identity -ceq $script:failIdentity) {
    $global:LASTEXITCODE = 1
    'fixture FAIL'
    return
  }
  $global:LASTEXITCODE = 0
  'fixture PASS'
}
function Reset-Ci {
  $script:prior = [ordered]@{
    schemaVersion='controller-battery-result/v1';controllerHead=$script:baseHead
    hostIdentity=@{sha256=('9' * 64)};fleetLoad='none'
    scope=@{kind='full'};execution=@{outcome='FAIL';notRun=@()}
    inventory=@($script:selectedItems | ForEach-Object { @{identity=$_.identity;path=$_.path;restriction=$null} })
    results=@($script:selectedItems | Where-Object identity -CNE 'test:missing.test.ps1' | ForEach-Object {
      @{identity=$_.identity;exitCode=0;result='PASS';fleetLoad='none';elapsedMs=10
        startedUtc=[DateTime]::UtcNow.ToString('o');finishedUtc=[DateTime]::UtcNow.ToString('o')
        provenance=@{kind='execution';attempt='github-12345-1-shard-0'}}
    })
    ci=@{runId='12345';checkoutHead=('a' * 40);runnerHead=('b' * 40);productSha=('c' * 40)
      localOnly=@(@{identity='test:local.test.ps1';reason='host resource'})
      notHermetic=@('test:nonhermetic.test.ps1')}
  }
  ($script:prior.results | Where-Object identity -CEQ 'test:fail.test.ps1').result='FAIL'
  ($script:prior.results | Where-Object identity -CEQ 'test:fail.test.ps1').exitCode=1
  ($script:prior.results | Where-Object identity -CEQ 'test:local.test.ps1').result='LOCAL_ONLY'
  ($script:prior.results | Where-Object identity -CEQ 'test:local.test.ps1').exitCode=125
  $script:run = @{id=12345;status='completed';path='.github/workflows/controller-battery.yml';head_sha=('b' * 40)
    repository=@{full_name='chase-sets/chase-sets-controller'};head_repository=@{full_name='chase-sets/chase-sets-controller'}}
  $script:snapshot = @{sha=('a' * 40);parents=@();message="Snapshot`n`nSource-Controller-Head: $script:baseHead"}
}
function Publish-Ci {
  $raw = [Text.UTF8Encoding]::new($false).GetBytes('fixture CI log')
  $script:prior.rawLog=@{kind='raw-log';relativePath='.orchestrator/artifacts/controller-ci.log';byteLength=$raw.Length
    sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()}
  Write-Json $script:prior $script:PriorResultPath
  $bytes = [IO.File]::ReadAllBytes($script:PriorResultPath)
  $stream = [IO.File]::Create($script:zipPath)
  $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($file in @(@{name='final.json';bytes=$bytes}, @{name='controller-ci.log';bytes=$raw})) {
      $entry = $zip.CreateEntry($file.name).Open()
      try { $entry.Write($file.bytes) } finally { $entry.Dispose() }
    }
  } finally { $zip.Dispose(); $stream.Dispose() }
  $script:artifactList = @{total_count=1;artifacts=@(@{id=67890;name='controller-battery-result';expired=$false
    digest=('sha256:' + (Get-FileHash $script:zipPath -Algorithm SHA256).Hash.ToLowerInvariant())
    workflow_run=@{id=12345;head_sha=('b' * 40)}})}
}
function Invoke-Reuse {
  $referenceIndex = $null
  $messages = @(. $script:reuseBlock)
  return @{reusable=$reusable;order=$priorOrder;messages=$messages}
}
function Assert-Refused([string]$Reason) {
  $message = ''
  try { $null = Invoke-Reuse } catch { $message = $_.Exception.Message }
  Assert-Test ($message -clike "*BATTERY_PRIOR_RESULT_INVALID:$Reason*") "refuse $Reason, got $message"
}
try {
  $null = Git-Fixture @('init','--quiet')
  $null = Git-Fixture @('config','user.name','Fixture')
  $null = Git-Fixture @('config','user.email','fixture@example.invalid')
  [IO.File]::WriteAllText((Join-Path $controller '.gitignore'), "/.orchestrator/artifacts/`n")
  $selectedItems = @(
    @{identity='direct:fail-closed-guard-evidence';path='.orchestrator/fail-closed-guard-evidence.ps1'},
    @{identity='discriminator:issue-6254';path='.orchestrator/issue-6254-discriminator.ps1'}
  ) + @('pass','fail','local','nonhermetic','missing','changed','controller-release-battery' | ForEach-Object {
    @{identity="test:$_.test.ps1";path=".orchestrator/$_.test.ps1"}
  })
  $selectedItems = @($selectedItems | ForEach-Object {
    [IO.File]::WriteAllText((Join-Path $controller $_.path), "# fixture`n")
    [pscustomobject]@{identity=$_.identity;path=$_.path;command=('fixture ' + $_.identity)
      executable='Invoke-FixtureItem';arguments=@($_.identity)}
  })
  [IO.File]::WriteAllText((Join-Path $runtime 'controller-release-battery.ps1'), "# fixture battery`n")
  [IO.File]::WriteAllText((Join-Path $runtime 'controller-release-battery.test.ps1'), "'controller-release-battery.ps1'`n")
  $null = Git-Fixture @('add','.')
  $null = Git-Fixture @('commit','--quiet','-m','fixture baseline')
  $baseHead = Git-Fixture @('rev-parse','HEAD')
  $ExpectedControllerHead = $baseHead
  $treePaths = [string[]]@($selectedItems.path) + '.orchestrator/controller-release-battery.ps1'
  $tracked = [string[]]@($selectedItems.path | Where-Object { $_ -cne '.orchestrator/fail-closed-guard-evidence.ps1' })
  $batteryCodePattern = '\.(ps1|psm1|cjs|js|mjs|cs|py|sh|vbs)$'
  $hostIdentity = @{sha256=('1' * 64)}
  $PriorResultPath = Join-Path $testRoot 'final.json'
  $zipPath = Join-Path $testRoot 'download.zip'
  Reset-Ci; Publish-Ci
  $selection = Invoke-Reuse
  Assert-Test (($selection.reusable.Keys | Sort-Object) -join ',' -ceq
    'direct:fail-closed-guard-evidence,discriminator:issue-6254,test:changed.test.ps1,test:controller-release-battery.test.ps1,test:pass.test.ps1') 'exact CI subset, including guards and battery self-test'
  Write-Output 'PASS valid CI prior and exact subset'

  Reset-Ci; $prior.ci.runId='99999'; Publish-Ci; Assert-Refused 'CI_API_UNEXPECTED'
  Reset-Ci; Publish-Ci; $artifactList.artifacts[0].digest='sha256:' + ('0' * 64); Assert-Refused 'CI_DIGEST_MISMATCH'
  Reset-Ci; Publish-Ci; $snapshot.message='Source-Controller-Head: ' + ('d' * 40); Assert-Refused 'CI_TRAILER_MISMATCH'
  Reset-Ci; Publish-Ci; $snapshot.parents=@(@{sha=('d' * 40)}); Assert-Refused 'CI_SNAPSHOT_NOT_ORPHAN'
  Reset-Ci; Publish-Ci; $snapshot.message += "`nSource-Controller-Head: $baseHead"; Assert-Refused 'CI_TRAILER_MISMATCH'
  Reset-Ci; Publish-Ci; $run.path='.github/workflows/forged.yml'; Assert-Refused 'CI_RUN_INVALID'
  Reset-Ci; Publish-Ci; $run.head_repository.full_name='fork/controller'; Assert-Refused 'CI_RUN_INVALID'
  Reset-Ci; Publish-Ci; $run.id=99999; Assert-Refused 'CI_RUN_INVALID'
  Reset-Ci; Publish-Ci; $run.status='in_progress'; Assert-Refused 'CI_RUN_INVALID'
  Reset-Ci; Publish-Ci; $artifactList.artifacts[0].workflow_run.id=99999; Assert-Refused 'CI_ARTIFACT_INVALID'
  Reset-Ci; Publish-Ci; $prior.results[0].elapsedMs=42; Write-Json $prior $PriorResultPath; Assert-Refused 'CI_RECEIPT_MISMATCH'
  Reset-Ci; $prior.controllerHead='d' * 40; Publish-Ci; Assert-Refused 'NOT_ANCESTOR'
  Reset-Ci; $prior.results += $prior.results[0]; Publish-Ci; Assert-Refused 'CI_DUPLICATE_ITEM'
  Reset-Ci; ($prior.results | Where-Object identity -CEQ 'test:pass.test.ps1').fleetLoad='busy'; Publish-Ci
  Assert-Test (-not (Invoke-Reuse).reusable.ContainsKey('test:pass.test.ps1')) 'CI loaded PASS never reused'
  Reset-Ci; ($prior.results | Where-Object identity -CEQ 'test:pass.test.ps1').exitCode=1; Publish-Ci
  Assert-Test (-not (Invoke-Reuse).reusable.ContainsKey('test:pass.test.ps1')) 'nonzero exit cannot claim reusable PASS'
  Reset-Ci; ($prior.results | Where-Object identity -CEQ 'test:local.test.ps1').result='PASS'
  ($prior.results | Where-Object identity -CEQ 'test:local.test.ps1').exitCode=0; Publish-Ci
  Assert-Test (-not (Invoke-Reuse).reusable.ContainsKey('test:local.test.ps1')) 'LOCAL_ONLY classification cannot be laundered as PASS'
  Reset-Ci; ($prior.inventory | Where-Object identity -CEQ 'test:pass.test.ps1').restriction=@{classification='NOT_HERMETIC'}; Publish-Ci
  Assert-Test (-not (Invoke-Reuse).reusable.ContainsKey('test:pass.test.ps1')) 'inventory restriction never reused'
  Reset-Ci; ($prior.results | Where-Object identity -CEQ 'test:pass.test.ps1').result='NOT_HERMETIC'; Publish-Ci
  Assert-Test (-not (Invoke-Reuse).reusable.ContainsKey('test:pass.test.ps1')) 'NOT_HERMETIC result never reused'
  Reset-Ci; Publish-Ci; $EvidenceReceiptPath='fixture-external-evidence.json'
  Assert-Test (-not (Invoke-Reuse).reusable.ContainsKey('discriminator:issue-6254')) 'external evidence must be revalidated locally'
  $EvidenceReceiptPath=''

  # Ancestor impact must select precisely the changed item, not all CI work.
  [IO.File]::AppendAllText((Join-Path $runtime 'changed.test.ps1'), "'changed'`n")
  $null = Git-Fixture @('add','.'); $null = Git-Fixture @('commit','--quiet','-m','changed test')
  $ExpectedControllerHead = Git-Fixture @('rev-parse','HEAD')
  Reset-Ci; Publish-Ci; $selection = Invoke-Reuse
  Assert-Test ($selection.reusable.Count -eq 4 -and -not $selection.reusable.ContainsKey('test:changed.test.ps1')) 'ancestor exact impact'
  $beforeBatteryChange=$ExpectedControllerHead
  [IO.File]::AppendAllText((Join-Path $runtime 'controller-release-battery.ps1'), "'battery change'`n")
  $null=Git-Fixture @('add','.'); $null=Git-Fixture @('commit','--quiet','-m','battery change')
  $ExpectedControllerHead=Git-Fixture @('rev-parse','HEAD')
  $batterySelection=Invoke-Reuse
  Assert-Test ($batterySelection.reusable.Count -eq 3 -and -not $batterySelection.reusable.ContainsKey('test:controller-release-battery.test.ps1')) 'battery change reruns self-test, carries unrelated CI PASS'
  $ExpectedControllerHead=$beforeBatteryChange

  # Drive the unchanged production execution/reconciliation/serialization block
  # with synthetic item bodies, not controller-release-battery.ps1 end to end.
  $reusable=$selection.reusable; $executionItems=$selectedItems; $requiredItems=$selectedItems
  $identitySet=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($item in $selectedItems) { [void]$identitySet.Add($item.identity) }
  $results=[Collections.Generic.List[object]]::new(); $executions=[Collections.Generic.List[string]]::new()
  $resolvedResult=Join-Path $artifacts 'merged.json'; $rawPath=Join-Path $artifacts 'merged.log'
  $executionStarted=$false; $batteryClock=[Diagnostics.Stopwatch]::StartNew(); $batteryStartedUtc=[DateTime]::UtcNow.ToString('o')
  $batteryFailure=$null; $batteryOutcome='FAIL'; $baselineCreated=$false; $BaselineHead=''; $RepairIssue=0
  $OnFailure='all'; $batteryHostLog='fixture host'; $admissionFleetLoad='none'; $batteryScope='full'; $scopeReason='fixture'; $changedPaths=@()
  $null = . $mergeBlock
  $merged = Get-Content $resolvedResult -Raw | ConvertFrom-Json -DateKind String
  Assert-Test ($batteryOutcome -ceq 'PASS') 'merged outcome PASS'
  Assert-Test (($executions | Sort-Object) -join ',' -ceq
    'test:changed.test.ps1,test:fail.test.ps1,test:local.test.ps1,test:missing.test.ps1,test:nonhermetic.test.ps1') 'execute exact complement of CI plus impact'
  Assert-Test ($merged.schemaVersion -ceq 'controller-battery-result/v1' -and $merged.controllerHead -ceq $ExpectedControllerHead) 'same merged schema and head'
  Assert-Test ($merged.execution.executedCount -eq 5 -and $merged.execution.reusedCount -eq 4 -and $merged.execution.satisfiedCount -eq 9) 'merged exact counts'
  Assert-Test (@($merged.results | Where-Object { $_.exitCode -ne 0 -or $_.result -cne 'PASS' }).Count -eq 0) 'same item result/exit fields'
  Assert-Test (@($merged.results | Where-Object { $_.provenance.source -ceq 'ci:12345' }).Count -eq 4) 'CI item provenance'
  Assert-Test (@($merged.results | Where-Object { $_.provenance.source -ceq 'local' }).Count -eq 5) 'local item provenance'
  Assert-Test ($merged.rawLog.sha256 -ceq (Get-FileHash $rawPath -Algorithm SHA256).Hash.ToLowerInvariant()) 'merged raw log binding'
  Assert-Test (($merged.PSObject.Properties.Name | Sort-Object) -join ',' -ceq
    'controllerHead,execution,fleetLoad,hostIdentity,inventory,rawLog,results,schemaVersion,scope') 'unchanged top-level result schema'
  Assert-Test (($merged.results[0].PSObject.Properties.Name | Sort-Object) -join ',' -ceq
    'elapsedMs,exitCode,finishedUtc,fleetLoad,identity,provenance,result,startedUtc') 'unchanged per-item result schema'

  # A complete same-head CI result executes only LOCAL_ONLY, then zero items
  # when no host-only item exists. Even zero execution must write a receipt.
  $ancestorHead=$baseHead; $baseHead=$ExpectedControllerHead
  foreach ($onlyLocal in @($true,$false)) {
    Reset-Ci
    $prior.ci.notHermetic=@()
    $prior.results=@($selectedItems | ForEach-Object {
      @{identity=$_.identity;exitCode=0;result='PASS';fleetLoad='none';elapsedMs=10
        startedUtc=[DateTime]::UtcNow.ToString('o');finishedUtc=[DateTime]::UtcNow.ToString('o');provenance=@{kind='execution'}}
    })
    if (-not $onlyLocal) { $prior.ci.localOnly=@() }
    Publish-Ci; $reusable=(Invoke-Reuse).reusable
    $results=[Collections.Generic.List[object]]::new(); $executions=[Collections.Generic.List[string]]::new()
    $executionStarted=$false; $batteryClock=[Diagnostics.Stopwatch]::StartNew(); $batteryFailure=$null
    $null = . $mergeBlock
    $merged=Get-Content $resolvedResult -Raw | ConvertFrom-Json -DateKind String
    $expectedLocal=if($onlyLocal){1}else{0}
    Assert-Test ($executions.Count -eq $expectedLocal -and $merged.execution.executedCount -eq $expectedLocal -and
      $merged.execution.reusedCount -eq (9-$expectedLocal) -and $merged.execution.outcome -ceq 'PASS') "empty-impact local count=$expectedLocal"
    if ($onlyLocal) { Assert-Test ($executions[0] -ceq 'test:local.test.ps1') 'only LOCAL_ONLY executed' }
  }
  $baseHead=$ancestorHead

  # A valid but divergent local commit is not an ancestor, not merely an
  # unknown object. No branch or object outside this fixture is consulted.
  $null=Git-Fixture @('checkout','--quiet','-b','sibling',$baseHead)
  [IO.File]::WriteAllText((Join-Path $controller 'sibling.txt'),'sibling')
  $null=Git-Fixture @('add','.'); $null=Git-Fixture @('commit','--quiet','-m','sibling')
  $sibling=Git-Fixture @('rev-parse','HEAD')
  $null=Git-Fixture @('checkout','--quiet','--detach',$ExpectedControllerHead)
  Reset-Ci; $prior.controllerHead=$sibling; Publish-Ci; Assert-Refused 'NOT_ANCESTOR'

  # Unreached new runtime code forces the selected inventory to execute.
  [IO.File]::WriteAllText((Join-Path $runtime 'unreached.ps1'),"'new'`n")
  $null=Git-Fixture @('add','.'); $null=Git-Fixture @('commit','--quiet','-m','unreached runtime')
  $ExpectedControllerHead=Git-Fixture @('rev-parse','HEAD'); $treePaths += '.orchestrator/unreached.ps1'
  Reset-Ci; Publish-Ci
  Assert-Test ((Invoke-Reuse).reusable.Count -eq 0) 'unreached change runs whole selected inventory'
  $ExpectedControllerHead=$merged.controllerHead; $treePaths=@($treePaths | Where-Object { $_ -cne '.orchestrator/unreached.ps1' })

  # Local prior guard is unchanged, including placement and host binary hash.
  $PriorResultPath=$resolvedResult
  $hostIdentity=@{sha256=('2' * 64)}
  Assert-Refused 'HOST_CHANGED'
  $hostIdentity=@{sha256=('1' * 64)}
  Assert-Test ((Invoke-Reuse).reusable.ContainsKey('test:pass.test.ps1')) 'valid local prior still reusable'
  $external=Join-Path $testRoot 'local.json'; [IO.File]::Copy($resolvedResult,$external); $PriorResultPath=$external
  Assert-Refused 'PATH'

  # CI reuse cannot hide a local failure or weaken the stop/not-run contract.
  $failIdentity='test:local.test.ps1'; $OnFailure='stop'
  $reusable.Remove($failIdentity)
  $results=[Collections.Generic.List[object]]::new(); $executions=[Collections.Generic.List[string]]::new()
  $executionStarted=$false; $batteryClock=[Diagnostics.Stopwatch]::StartNew(); $batteryFailure=$null
  $null = . $mergeBlock
  $failed=Get-Content $resolvedResult -Raw | ConvertFrom-Json -DateKind String
  Assert-Test ($failed.execution.outcome -ceq 'FAIL' -and $failed.failureCode -ceq 'BATTERY_CHILD_FAILED:test:local.test.ps1') 'local failure stays FAIL'
  Assert-Test ($failed.execution.notRun.Count -gt 0 -and @($failed.results | Where-Object { $_.identity -ceq $failIdentity -and $_.exitCode -eq 1 }).Count -eq 1) 'local failure preserves stop/not-run'
  Write-Output "PASS controller CI prior focused suite assertions=$assertions"
} finally {
  $fullRoot=[IO.Path]::GetFullPath($testRoot)
  if (-not $fullRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe fixture cleanup' }
  Remove-Item -LiteralPath $fullRoot -Recurse -Force
}
