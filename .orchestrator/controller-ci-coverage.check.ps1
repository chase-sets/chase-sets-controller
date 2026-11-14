[CmdletBinding()]
param([string]$BaselineHead='e671d823b96d45a3b71d7b81cf05a24d173df73a',[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
. (Join-Path $PSScriptRoot 'controller-ci-record-durations.ps1') -Library
. (Join-Path $PSScriptRoot 'suite-parts.ps1')
$root=Split-Path -Parent $PSScriptRoot
$manifest=Get-Content (Join-Path $PSScriptRoot 'controller-ci-parts.json') -Raw|ConvertFrom-Json -Depth 50
Assert-Ci ($manifest.baselineHead-ceq$BaselineHead) 'coverage baseline mismatch'
$pins=@{
  'dispatch-routing-data.test.ps1'='a3a957cc8e271d06e0a6b28b52d078ebc7b43a54'
  'cleanup-orphan-worktree-dirs.test.ps1'='52d4aa1c082db8efcb3169b2bfa326b6ab1e38b6'
  'board-hourly-scale.test.ps1'='4eedaa85619279fa8b30595045acf95a6137e802'
  'board-scale-test-support.ps1'='3bf88f145428c9950ee02019efca407802dea094'
  'landed-integration-dispatch.test.ps1'='d19467b682d79bb64a6ec58aef76f2da43c7cf59'
  'invoke-heavy-verifier.test.ps1'='4abac745923af272440e35f9c04fb05448681d08'
}
$newTestPins=@{
  'heavy-verifier-priority.test.ps1'='b5354627d03b595b7295e7e573641f55189b86676682b9b34bc8f61340fd0d80'
}
# Baseline nodes retired by an intentional behavior change, keyed by exact node text.
# Each entry must be consumed by a node that is absent from the candidate, or the check refuses.
$conservationRetirements=@{
  # #239: dispatch-lane refuses row 6 before routing; capacity-continuation now asserts that refusal for these row-6 plans.
  'dispatch-routing-data.test.ps1'=@(
    'CommandAst:Assert-True ($null -ne (Plan ($astra+@{Row=6})).capacityFlip) ''valid attributed history does not exclude the row policy slot''',
    'BinaryExpressionAst:$null -ne (Plan ($astra+@{Row=6})).capacityFlip',
    'CommandAst:Plan ($astra+@{Row=6})',
    'CommandAst:Assert-True ($null -ne (Plan @{Model=''gpt-6.1-sol'';Effort=''high'';Placement=''provisional'';Row=6}).capacityFlip) ''row 6 from Sol flips to its own Claude slot''',
    'BinaryExpressionAst:$null -ne (Plan @{Model=''gpt-6.1-sol'';Effort=''high'';Placement=''provisional'';Row=6}).capacityFlip',
    'CommandAst:Plan @{Model=''gpt-6.1-sol'';Effort=''high'';Placement=''provisional'';Row=6}',
    # #244: two capacity mutant seams retarget the decision-aware review line in routing-data.ps1 (d0c63bb).
    'HashtableAst:@{name=''code-exclusion-dropped'';file=''routing-data.ps1'';case=''capacity-roles'';old="    if (`$role -ceq ''implementation'') { return ''code'' }`n    if (`$role -ceq ''planning'') { return ''brief'' }`n    if (`$role -ceq ''review'') { return `$null }";new="    if (`$role -ceq ''implementation'') { return `$null }`n    if (`$role -ceq ''planning'') { return ''brief'' }`n    if (`$role -ceq ''review'') { return `$null }"}',
    'HashtableAst:@{name=''brief-authors-merged'';file=''routing-data.ps1'';case=''capacity-roles'';old="    if (`$role -ceq ''planning'') { return ''brief'' }`n    if (`$role -ceq ''review'') { return `$null }";new="    if (`$role -ceq ''planning'') { return ''code'' }`n    if (`$role -ceq ''review'') { return `$null }"}'
  )
  # Replay moved scalar validation into its early closed-value guard and added a rejection-only command seam.
  # Retire only these exact obsolete diagnostics; full reconstruction binds their replacements.
  'invoke-heavy-verifier.test.ps1'=@(
    ('CommandAst:Assert-True ($Source -match ''(?s)Parameter\(ParameterSetName\s*=\s*"Gate",\s*DontShow\)\]\s*\[Parameter\(ParameterSetName\s*=\s*"ControllerBattery",\s*DontShow\)\]\s*\[Parameter\(ParameterSetName\s*=\s*"Attach",\s*DontShow\)\]\s*\[string\]\$CommandPath'') `' + "`n" + '    "CommandPath is not confined to the Gate parameter set"'),
    ('BinaryExpressionAst:$Source -match ''(?s)Parameter\(ParameterSetName\s*=\s*"Gate",\s*DontShow\)\]\s*\[Parameter\(ParameterSetName\s*=\s*"ControllerBattery",\s*DontShow\)\]\s*\[Parameter\(ParameterSetName\s*=\s*"Attach",\s*DontShow\)\]\s*\[string\]\$CommandPath'''),
    ('CommandAst:Assert-True ($unknownProducer.exitCode -ne 0 -and $unknownProducer.output -match "ValidateSet" -and' + "`n" + '    -not (Test-Path -LiteralPath (Join-Path $worktree $unknownOut))) "unknown precursor producer is rejected by the closed allowlist"'),
    ('BinaryExpressionAst:$unknownProducer.exitCode -ne 0 -and $unknownProducer.output -match "ValidateSet" -and' + "`n" + '    -not (Test-Path -LiteralPath (Join-Path $worktree $unknownOut))'),
    ('BinaryExpressionAst:$unknownProducer.exitCode -ne 0 -and $unknownProducer.output -match "ValidateSet"'),
    ('BinaryExpressionAst:$unknownProducer.output -match "ValidateSet"'),
    ('CommandAst:Assert-True ($bypassFailed -and "$bypassOutput" -match "ValidateSet") "unsupported gate bypass is refused"'),
    ('BinaryExpressionAst:$bypassFailed -and "$bypassOutput" -match "ValidateSet"'),
    ('BinaryExpressionAst:"$bypassOutput" -match "ValidateSet"')
  )
}
function Assert-Conservation($Manifest,$Overrides=@{}) {
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($entry in $Manifest.sourceConservation){
    $leaf=Split-Path -Leaf $entry.path
    Assert-Ci ($seen.Add($leaf)-and$pins.ContainsKey($leaf)-and$entry.baselineBlob-ceq$pins[$leaf]) 'unknown/duplicate/misbound conservation source'
    $blob=(ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('rev-parse',"${BaselineHead}:$($entry.path)"))).Trim()
    Assert-Ci ($blob-ceq$entry.baselineBlob) 'baseline full blob mismatch'
    $source=(ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',"${BaselineHead}:$($entry.path)"))).Replace("`r`n","`n")
    $baselineSource=$source
    $lines=[Collections.Generic.List[string]]::new([string[]]$source.Split("`n"))
    $last=$lines.Count+1
    foreach($edit in @($entry.edits|Sort-Object offset -Descending)){
      Assert-Ci ($edit.offset-ge0-and$edit.offset+$edit.remove-lt$last) 'overlapping conservation edits'
      $last=$edit.offset
      $original=@(for($i=0;$i-lt$edit.remove;$i++){$lines[$edit.offset+$i]})
      Assert-Ci (($original-join"`n")-ceq(@($edit.original)-join"`n")) 'conservation anchor mismatch'
      $lines.RemoveRange($edit.offset,$edit.remove)
      $lines.InsertRange($edit.offset,[string[]]@($edit.replacement))
    }
    $actual=if($Overrides.ContainsKey($leaf)){$Overrides[$leaf]}else{[IO.File]::ReadAllText((Join-Path $root $entry.path)).Replace("`r`n","`n")}
    $joined=$lines -join "`n"
    Assert-Ci ($joined-ceq$actual) "changed/dropped/duplicate/misowned source predicate: $leaf"
    $t=$null;$e=$null
    $before=[Management.Automation.Language.Parser]::ParseInput($baselineSource,[ref]$t,[ref]$e)
    Assert-Ci ($e.Count-eq0) 'baseline parse failed'
    $after=[Management.Automation.Language.Parser]::ParseInput($actual,[ref]$t,[ref]$e)
    Assert-Ci ($e.Count-eq0) 'candidate parse failed'
    $predicate={param($n) $n-is[Management.Automation.Language.CommandAst]-or
      $n-is[Management.Automation.Language.BinaryExpressionAst]-or$n-is[Management.Automation.Language.UnaryExpressionAst]-or
      $n-is[Management.Automation.Language.HashtableAst]}
    $available=@{};$retired=@{}
    if($conservationRetirements.ContainsKey($leaf)){foreach($retiredKey in $conservationRetirements[$leaf]){$retired[$retiredKey]++}}
    foreach($node in $after.FindAll($predicate,$true)){$key=$node.GetType().Name+':'+$node.Extent.Text;$available[$key]++}
    foreach($node in $before.FindAll($predicate,$true)){
      $key=$node.GetType().Name+':'+$node.Extent.Text
      if($available[$key]-le0-and$retired[$key]-gt0){$retired[$key]--;continue}
      Assert-Ci ($available[$key]-gt0) "baseline command/predicate/mutant table lost: $leaf $key"
      $available[$key]--
    }
    Assert-Ci (@($retired.Values|Where-Object{$_-gt0}).Count-eq0) "unused conservation retirement: $leaf"
    if($before.ParamBlock){
      if($leaf-ceq'cleanup-orphan-worktree-dirs.test.ps1'){
        foreach($beforeParameter in $before.ParamBlock.Parameters){
          $afterParameter=@($after.ParamBlock.Parameters|Where-Object {$_.Name.Extent.Text-ceq$beforeParameter.Name.Extent.Text})
          Assert-Ci ($afterParameter.Count-eq1-and$beforeParameter.Extent.Text-ceq$afterParameter[0].Extent.Text) 'legacy parameter/default/order changed'
        }
      }else{
        for($i=0;$i-lt$before.ParamBlock.Parameters.Count;$i++){
          $afterParameter=$after.ParamBlock.Parameters[$i].Extent.Text
          if($leaf-ceq'board-hourly-scale.test.ps1'-and$i-eq0){$afterParameter=$afterParameter.Replace(",'ten-item-scan'",'')}
          Assert-Ci ($before.ParamBlock.Parameters[$i].Extent.Text-ceq$afterParameter) 'legacy parameter/default/order changed'
        }
      }
    }
  }
  Assert-Ci ($seen.Count-eq$pins.Count) 'missing conservation source'
  foreach($name in $newTestPins.Keys){
    $identity='test:'+$name
    $mapping=@($Manifest.items|Where-Object identity -CEQ $identity)
    Assert-Ci ($mapping.Count-eq1-and$mapping[0].identity.Substring(5)-ceq$name) 'new proof test mapping missing/drifted'
    Assert-Ci ((Get-CiSourceDigest (Join-Path $root ('.orchestrator/'+$name)))-ceq$newTestPins[$name]) 'new proof test source drifted'
  }
  $expectedMappings=@('test:dispatch-lane.test.ps1','test:dispatch-routing-data.test.ps1','test:board-hourly-scale.test.ps1','test:landed-integration-dispatch.test.ps1','test:invoke-heavy-verifier.test.ps1','test:heavy-verifier-priority.test.ps1','test:cleanup-orphan-worktree-dirs.test.ps1','test:long-product-gate.test.ps1','test:landed-integration-r3.test.ps1')
  $expectedMappings=@('test:dispatch-lane.test.ps1','test:dispatch-routing-data.test.ps1','test:board-hourly-scale.test.ps1','test:landed-integration-dispatch.test.ps1','test:invoke-heavy-verifier.test.ps1','test:heavy-verifier-priority.test.ps1','test:cleanup-orphan-worktree-dirs.test.ps1','test:long-product-gate.test.ps1','test:landed-integration-r3.test.ps1','test:codex-launch-boundary.test.ps1','test:dispatch-lane-installed-claude.test.ps1','test:dispatch-ownership.test.ps1')
  Assert-Ci (@($Manifest.items).Count-eq14-and@($expectedMappings|Where-Object{$_-cnotin@($Manifest.items.identity)}).Count-eq0) 'missing/extra proof ownership'
  $inventory=@($Manifest.items|ForEach-Object{[pscustomobject]@{identity=$_.identity;path=('.orchestrator/'+$_.identity.Substring(5));restriction=$null}})
  Assert-CiManifest $inventory $Manifest $root
}
Assert-Conservation $manifest
function Refuses-Coverage([scriptblock]$Body){$refused=$false;try{&$Body}catch{$refused=$true};Assert-Ci $refused 'coverage bypass survived'}

$codexPath=Join-Path $PSScriptRoot 'codex-launch-boundary.test.ps1'
$codexItem=$manifest.items|Where-Object identity -eq 'test:codex-launch-boundary.test.ps1'
Assert-Ci ($null -ne $codexItem) 'codex launch boundary split mapping missing'
Assert-Ci ((@($codexItem.parts.name|Sort-Object)-join',') -ceq 'local-smoke,portable') 'codex launch boundary part census changed'
Assert-Ci ((Get-SuiteExpectedParts $codexPath|Sort-Object)-join',' -ceq 'local-smoke,portable') 'codex launch boundary selector census changed'
foreach($name in @($codexItem.parts.name)){
  Refuses-Coverage { Assert-Ci ((@($codexItem.parts.name|Where-Object{$_-cne$name}|Sort-Object)-join',') -ceq ((Get-SuiteExpectedParts $codexPath|Sort-Object)-join',')) "codex launch boundary dropped part survived: $name" }
}
Write-Output 'PASS codex launch boundary part ownership: portable and local-smoke selectors are complete and dropped-part mutants refuse'

$claudePath=Join-Path $PSScriptRoot 'dispatch-lane-installed-claude.test.ps1'
$claudeItem=$manifest.items|Where-Object identity -eq 'test:dispatch-lane-installed-claude.test.ps1'
Assert-Ci ($null -ne $claudeItem) 'installed Claude split mapping missing'
Assert-Ci ((@($claudeItem.parts.name|Sort-Object)-join',') -ceq 'local-smoke,portable') 'installed Claude part census changed'
Assert-Ci ((Get-SuiteExpectedParts $claudePath|Sort-Object)-join',' -ceq 'local-smoke,portable') 'installed Claude selector census changed'
$claudeLocal=$claudeItem.parts|Where-Object name -ceq 'local-smoke'
Assert-Ci ($claudeLocal.restriction.classification -ceq 'LOCAL_ONLY') 'installed Claude local-smoke restriction missing'
foreach($name in @($claudeItem.parts.name)){
  Refuses-Coverage { Assert-Ci ((@($claudeItem.parts.name|Where-Object{$_-cne$name}|Sort-Object)-join',') -ceq ((Get-SuiteExpectedParts $claudePath|Sort-Object)-join',')) "installed Claude dropped part survived: $name" }
}
$claudeSource=[IO.File]::ReadAllText($claudePath)
$claudePathAnchor='$env:PATH = "$(Split-Path -Parent $gitExe);$PSHOME;$testRoot"'
Assert-Ci ($claudeSource.Contains("[ValidateSet('portable','local-smoke')][string]`$Part")) 'installed Claude selector source missing'
Assert-Ci ($claudeSource.Contains("if (-not `$Part -or `$Part -ceq 'portable')") -and $claudeSource.Contains("if (-not `$Part -or `$Part -ceq 'local-smoke')")) 'installed Claude part guards missing'
Assert-Ci ($claudeSource.Contains("Get-Command claude -CommandType Application") -and $claudeSource.Contains($claudePathAnchor)) 'installed Claude native lookup guard drifted'
Assert-Ci ($claudeSource.Contains("if (`$ValidatorOnly)")) 'installed Claude ValidatorOnly mode missing'
Write-Output 'PASS installed Claude part ownership: portable fixture/argv proof and explicit local-smoke selector are complete and hosted native lookup is poisoned'

$ownershipPath=Join-Path $PSScriptRoot 'dispatch-ownership.test.ps1'
$ownershipItem=$manifest.items|Where-Object identity -eq 'test:dispatch-ownership.test.ps1'
Assert-Ci ($null -ne $ownershipItem) 'dispatch ownership split mapping missing'
Assert-Ci ((@($ownershipItem.parts.name|Sort-Object)-join',') -ceq 'local-smoke,portable-carrier,portable-census,portable-reducer') 'dispatch ownership part census changed'
Assert-Ci ((Get-SuiteExpectedParts $ownershipPath|Sort-Object)-join',' -ceq 'local-smoke,portable-carrier,portable-census,portable-reducer') 'dispatch ownership selector census changed'
$ownershipLocal=$ownershipItem.parts|Where-Object name -ceq 'local-smoke'
Assert-Ci ($ownershipLocal.restriction.classification -ceq 'LOCAL_ONLY' -and $ownershipLocal.restriction.notHermetic) 'dispatch ownership local-smoke restriction missing'
$ownershipSource=[IO.File]::ReadAllText($ownershipPath).Replace("`r`n","`n")
Assert-Ci ($ownershipSource.Contains("[ValidateSet('portable-census','portable-reducer','portable-carrier','local-smoke')][string]`$Part = ''")) 'dispatch ownership selector source missing'
Assert-Ci ($ownershipSource.Contains('$runSection = { param([string]$Name) -not $Part -or $Part -ceq $Name }')) 'dispatch ownership section gate missing'
foreach($section in @('portable-census','portable-reducer','portable-carrier')){
  Assert-Ci (([regex]::Matches($ownershipSource,[regex]::Escape("if (& `$runSection '$section') {"))).Count -eq 1) "dispatch ownership hosted section is not gated exactly once: $section"
}
Assert-Ci ($ownershipSource.Contains("if (`$Part -ceq 'local-smoke')") -and $ownershipSource.Contains('Invoke-DispatchOwnershipLocalSmoke')) 'dispatch ownership local-smoke guard missing'
Assert-Ci ($ownershipSource.Contains("if (`$ProductCensusOnly -or `$Part -ceq 'portable-census') { return }") -and $ownershipSource.Contains('if ($Part -ceq ''portable-carrier'') {'+"`n"+'    $carrierRootResolved = [IO.Path]::GetFullPath($root)')) 'dispatch ownership hosted part root cleanup missing'
Assert-Ci ($ownershipSource.Contains('poisoned-default-runtime') -and $ownershipSource.Contains('hosted ownership census reads only the synthetic runtime')) 'dispatch ownership hosted source guard missing'
function Get-OwnershipConservation([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'dispatch ownership conservation source parse failed'
  $keys=@{}
  foreach($node in $ast.FindAll({param($n)
    $n-is[Management.Automation.Language.CommandAst]-or
    $n-is[Management.Automation.Language.BinaryExpressionAst]-or
    $n-is[Management.Automation.Language.UnaryExpressionAst]-or
    $n-is[Management.Automation.Language.HashtableAst]-or
    $n-is[Management.Automation.Language.ThrowStatementAst]
  },$true)){$key=$node.GetType().Name+':'+$node.Extent.Text;$keys[$key]++}
  return $keys
}
$ownershipBaseline=(ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',"${BaselineHead}:.orchestrator/dispatch-ownership.test.ps1"))).Replace("`r`n","`n")
$ownershipBefore=Get-OwnershipConservation $ownershipBaseline
$ownershipAfter=Get-OwnershipConservation $ownershipSource
# The pinned controller-ci baseline predates the already-landed decision-lane
# isolation extension. Retire only those two exact pre-split fixture literals;
# every other baseline command, predicate, throw and mutant remains required.
$ownershipRetirements=@($ownershipBefore.Keys|Where-Object {
  $_ -match '\$LaneRole -in @\("review", "planning"\)'
})
foreach($key in $ownershipBefore.Keys){
  if($ownershipRetirements -contains $key){continue}
  Assert-Ci ([int]$ownershipAfter[$key] -ge [int]$ownershipBefore[$key]) "dispatch ownership baseline proof lost: $key"
}
Assert-Ci ($ownershipRetirements.Count -eq 2) 'dispatch ownership conservation retirement census changed'
Assert-Ci ($ownershipSource.Contains('$guardOwners = Get-LiveDispatchOwnership $guardRuntime $providerTemp $container') -and
  $ownershipSource.Contains('$poisonedDefaultRuntime')) 'dispatch ownership synthetic source invocation drifted'
foreach($name in @($ownershipItem.parts.name)){
  Refuses-Coverage { Assert-Ci ((@($ownershipItem.parts.name|Where-Object{$_-cne$name}|Sort-Object)-join',') -ceq ((Get-SuiteExpectedParts $ownershipPath|Sort-Object)-join',')) "dispatch ownership dropped part survived: $name" }
}
Write-Output 'PASS dispatch ownership part ownership: synthetic portable census, poisoned-source guard, exact baseline proof census, and local-smoke restriction are complete'

function Get-DispatchCoverageKeys([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'dispatch-lane source parse failed'
  $keys=[Collections.Generic.List[string]]::new()
  foreach($fn in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){$keys.Add("function:$($fn.Name)")}
  foreach($call in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))){
    $name=$call.GetCommandName()
    if($name -and ($name -match '^(Test|Invoke|Assert)-' -or $name -ceq 'Start-Process')){$keys.Add("call:$name")}
  }
  return @($keys)
}
function Get-DispatchCaseOwners([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'dispatch-lane case ownership source parse failed'
  $owners=[Collections.Generic.List[object]]::new()
  foreach($call in @($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Invoke-DispatchMeasuredCase','Start-DispatchCase')},$true))){
    if($call.CommandElements.Count -lt 3 -or
       $call.CommandElements[1] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
       $call.CommandElements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst]){continue}
    $owners.Add([pscustomobject]@{name=[string]$call.CommandElements[1].Value;part=[string]$call.CommandElements[2].Value})
  }
  return @($owners)
}
$dispatchPath=Join-Path $PSScriptRoot 'dispatch-lane.test.ps1'
$dispatchSource=[IO.File]::ReadAllText($dispatchPath).Replace("`r`n","`n")
$dispatchExpected=@((Get-DispatchLanePartMap).Keys)
$dispatchItem=$manifest.items|Where-Object identity -eq 'test:dispatch-lane.test.ps1'
Assert-Ci ($null -ne $dispatchItem) 'dispatch-lane split mapping missing'
function Assert-DispatchPartNames($Names){
  $expected=@((Get-DispatchLanePartMap).Keys)
  Assert-Ci ((@($Names|Sort-Object)-join',')-ceq(@($expected|Sort-Object)-join',')) 'dispatch-lane part census changed'
}
Assert-DispatchPartNames @($dispatchItem.parts.name)
$dispatchBaseline=(ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',"${BaselineHead}:.orchestrator/dispatch-lane.test.ps1"))).Replace("`r`n","`n")
# The five-concept receipt policy retired the strict prelog/void/recovery
# ceremony, not ordinary launch admission. Bind that exact baseline block to
# its exact direct-review replacement: head/issue/source guards, inert launch,
# no-write preparation, v3 capacity evidence and consumed forecast bytes.
$dispatchReviewRetirement=@{
  baselineSha256='011bfa85488aaefa4c4c8b3f852fbf60490cdc15c063b71dfb194cb9bedd2a31'
  replacementSha256='1444f91940fac5d74099016f54521888c045a1556bea8665d060b089546ce70a'
  helpers=@('function:Set-StrictForecast','function:Get-StrictInventory','function:New-StrictPrelog','function:Complete-StrictRecovery')
}
function Get-DispatchReviewBlock([string]$Source,[string]$Start,[string]$End) {
  Assert-Ci ([regex]::Matches($Source,[regex]::Escape($Start)).Count -eq 1) 'review retirement start is missing/duplicate'
  $offset=$Source.IndexOf($Start,[StringComparison]::Ordinal)
  $limit=$Source.IndexOf($End,$offset,[StringComparison]::Ordinal)
  Assert-Ci ($limit -gt $offset) 'review retirement end missing'
  return $Source.Substring($offset,$limit-$offset).TrimEnd("`n")
}
function Get-DispatchReviewRetirement([string]$Source,[string]$Baseline,$Binding=$dispatchReviewRetirement) {
  Assert-Ci ($null -ne $Binding -and @($Binding.helpers).Count -eq 4) 'missing/unused review retirement binding'
  $old=Get-DispatchReviewBlock $Baseline '  # Controller prelaunch uses the public producer and the real inert launcher.' '  Invoke-FleetLauncherOrderingControls'
  $replacement=Get-DispatchReviewBlock $Source '  # Controller reviews use ordinary launch admission, not receipt prelogging.' '  if($Part -ceq ''controller-review''){return}'
  foreach($pair in @(@($old,$Binding.baselineSha256),@($replacement,$Binding.replacementSha256))) {
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($pair[0]))).ToLowerInvariant()
    Assert-Ci ($digest -ceq $pair[1]) 'review retirement/replacement source binding changed'
  }
  $retired=Get-DispatchAssertionCensus $old
  $bound=Get-DispatchAssertionCensus $replacement
  Assert-Ci ($retired.all.Count -eq 47 -and $bound.all.Count -eq 15) 'review retirement/replacement assertion census changed'
  $oldKeys=Get-DispatchCoverageKeys $old
  $newKeys=Get-DispatchCoverageKeys $Source
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($key in $Binding.helpers) {
    Assert-Ci ($seen.Add($key) -and $key -cin $oldKeys -and $key -cnotin $newKeys) "missing/duplicate/unused retired review helper: $key"
  }
  $after=Get-DispatchAssertionCensus $Source
  foreach($key in $retired.all.Keys) {
    Assert-Ci ($retired.all[$key] -eq 1 -and -not $after.all.ContainsKey($key)) "unused review assertion retirement: $key"
  }
  return $retired.all
}
function Assert-DispatchCoverageKeys([string]$Source,[string]$Baseline,$Binding=$dispatchReviewRetirement) {
  $null=Get-DispatchReviewRetirement $Source $Baseline $Binding
  $keys=Get-DispatchCoverageKeys $Source
  foreach($key in (Get-DispatchCoverageKeys $Baseline)) {
    Assert-Ci ($key -cin $keys -or $key -cin $Binding.helpers) "dispatch-lane baseline proof key lost: $key"
  }
}
# Outside the bound review retirement, every base Assert-* and throw keeps its text and
# multiplicity, so deleting an Assert-only block is red even though its command
# name survives elsewhere. The listed base assertions moved with the installed
# Claude probe or were replaced by the pinned historical fixture refusal; each
# move is bound to its replacement. Per-part counts are lexical (the enclosing
# & $runPart guard; code outside a guard, including helper functions, is
# 'unscoped') and pinned, so moving assertions across parts is also red.
function Get-DispatchAssertionCensus([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'dispatch assertion census parse failed'
  $all=@{};$parts=@{}
  foreach($node in @($ast.FindAll({param($n) ($n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -clike 'Assert-*') -or $n -is [Management.Automation.Language.ThrowStatementAst]},$true))){
    $key=$node.GetType().Name+':'+$node.Extent.Text;$all[$key]=1+[int]$all[$key]
    $part='unscoped';$p=$node.Parent
    while($p){
      if($p -is [Management.Automation.Language.IfStatementAst] -and $p.Clauses.Count -ge 1 -and $p.Clauses[0].Item1.Extent.Text -cmatch '^& \$runPart ''([a-z-]+)''$' -and
        $p.Clauses[0].Item2.Extent.StartOffset -le $node.Extent.StartOffset -and $node.Extent.EndOffset -le $p.Clauses[0].Item2.Extent.EndOffset){$part=$Matches[1];break}
      $p=$p.Parent
    }
    $parts[$part]=1+[int]$parts[$part]
  }
  return [pscustomobject]@{all=$all;parts=$parts}
}
$dispatchAssertionMoves=[ordered]@{
  'ThrowStatementAst:throw "unable to materialize exact base launcher $baseObject"'=@('interrupted-integration-test-support.ps1','HISTORICAL_FIXTURE: blob mismatch')
  'CommandAst:Assert-True ($claudeHelpExited) "installed Claude argument fixture exits without launching a model"'=@('dispatch-lane-installed-claude.test.ps1','$p.WaitForExit()')
  'CommandAst:Assert-True ($claudeHelpProcess.ExitCode -eq 0) "installed Claude CLI accepts the exact disallowed-tool argument shape"'=@('dispatch-lane-installed-claude.test.ps1','CLAUDE_HELP_FIXTURE: installed Claude --help exit')
  'CommandAst:Assert-True ((Get-Content -Raw -LiteralPath $claudeHelpOutput) -match "--disallowedTools") "installed Claude help confirms the supported disallowed-tools option"'=@('dispatch-lane-installed-claude.test.ps1','CLAUDE_HELP_FIXTURE: hosted option check missing --disallowedTools')
}
# Only the unscoped review block changes: 152 - 47 retired + 15 replacements = 120.
$dispatchAssertionParts=@{'unscoped'=120;'dispatch-foundation'=7;'refusal-foundation'=60;'refusal-harness'=149}
function Assert-DispatchAssertionCensus([string]$Source,[string]$Baseline) {
  $before=Get-DispatchAssertionCensus $Baseline;$after=Get-DispatchAssertionCensus $Source
  $retired=Get-DispatchReviewRetirement $Source $Baseline
  foreach($key in $before.all.Keys){
    if($retired.ContainsKey($key)){continue}
    if($dispatchAssertionMoves.Contains($key)){
      $move=$dispatchAssertionMoves[$key]
      Assert-Ci ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $move[0])).Contains($move[1])) "dispatch moved assertion lost its replacement: $key"
      continue
    }
    Assert-Ci ([int]$after.all[$key] -ge $before.all[$key]) "dispatch-lane base assertion lost: $key"
  }
  $actualParts=(@($after.parts.Keys|Sort-Object|ForEach-Object{"$_=$($after.parts[$_])"})-join',')
  $expectedParts=(@($dispatchAssertionParts.Keys|Sort-Object|ForEach-Object{"$_=$($dispatchAssertionParts[$_])"})-join',')
  Assert-Ci ($actualParts -ceq $expectedParts) "dispatch per-part assertion census changed: $actualParts"
}
Assert-DispatchCoverageKeys $dispatchSource $dispatchBaseline
Assert-DispatchAssertionCensus $dispatchSource $dispatchBaseline
$savedReviewRetirement=$dispatchReviewRetirement
Refuses-Coverage { Assert-DispatchCoverageKeys $dispatchSource $dispatchBaseline $null }
$unusedReviewRetirement=$dispatchReviewRetirement.Clone();$unusedReviewRetirement.helpers+=@('function:NotARetiredReviewHelper')
Refuses-Coverage { Assert-DispatchCoverageKeys $dispatchSource $dispatchBaseline $unusedReviewRetirement }
$duplicateReviewRetirement=$dispatchReviewRetirement.Clone();$duplicateReviewRetirement.helpers=@($dispatchReviewRetirement.helpers)
$duplicateReviewRetirement.helpers[0]=$duplicateReviewRetirement.helpers[1]
Refuses-Coverage { Assert-DispatchCoverageKeys $dispatchSource $dispatchBaseline $duplicateReviewRetirement }
$dispatchReviewRetirement=$savedReviewRetirement
$reviewReplacement=Get-DispatchReviewBlock $dispatchSource '  # Controller reviews use ordinary launch admission, not receipt prelogging.' '  if($Part -ceq ''controller-review''){return}'
foreach($replacementMutant in @(
  $dispatchSource.Replace($reviewReplacement,''),
  $dispatchSource.Replace($reviewReplacement,"$reviewReplacement`n$reviewReplacement"),
  $dispatchSource.Replace('$preparedFlip.harness -ceq ''claude''','$preparedFlip.harness -cne ''claude'''),
  $dispatchSource.Replace($reviewReplacement,"if (& `$runPart 'refusal-foundation') {`n$reviewReplacement`n}")
)) {
  Refuses-Coverage { Assert-DispatchCoverageKeys $replacementMutant $dispatchBaseline }
}
Write-Output 'PASS review proof retirement: 47 exact strict assertions and four helpers bound to 15 direct-review assertions; missing/unused/duplicate bindings and omitted/duplicate/changed-predicate/misowned replacements refused'
$assertOnly="`n  Assert-True (`$codex.laneRole -eq `"review`") `"omitted lane role defaults to review without prompting`"`n"
Assert-Ci ($dispatchSource.Contains($assertOnly)) 'dispatch Assert-only mutant anchor missing'
Assert-Ci (@(Get-DispatchCoverageKeys $dispatchSource.Replace($assertOnly,"`n")) -contains 'call:Assert-True') 'Assert-only mutant control: command-name keys alone stay green'
Refuses-Coverage { Assert-DispatchAssertionCensus $dispatchSource.Replace($assertOnly,"`n") $dispatchBaseline }
$hoisted=$dispatchSource.Replace($assertOnly,"`n").Replace("`n`$launcher = Join-Path","`n$($assertOnly.Trim())`n`$launcher = Join-Path")
Refuses-Coverage { Assert-DispatchAssertionCensus $hoisted $dispatchBaseline }
Write-Output "PASS dispatch assertion census: base Assert-*/throw multiset kept ($($dispatchAssertionMoves.Count) bound moves); per-part counts pinned; Assert-only deletion and cross-part move mutants refused"
foreach($partName in $dispatchExpected){
  Assert-Ci ($dispatchSource.Contains("'$partName'")) "dispatch source selector missing: $partName"
  Refuses-Coverage { Assert-DispatchPartNames @($dispatchItem.parts.name|Where-Object{$_ -cne $partName}) }
}
Refuses-Coverage { Assert-DispatchPartNames (@($dispatchItem.parts.name)+@('dispatch-incident-b-route-baseline')) }
Refuses-Coverage { Assert-DispatchPartNames (@($dispatchItem.parts.name|Where-Object{$_ -cnotin @('dispatch-incident-b-route-baseline','dispatch-incident-b-route-matrix')})+@('dispatch-incident-b-route')) }
$dispatchCaseExpected=[ordered]@{
  'dispatch-foundation-verification-policy'='dispatch-foundation'
  'dispatch-foundation-routing'='dispatch-foundation'
  'dispatch-foundation-publication'='dispatch-foundation'
  'refusal-foundation'='refusal-foundation'
  'refusal-harness'='refusal-harness'
  'dispatch-guard-pid'='dispatch-guard-pid'
  'dispatch-guard-omission'='dispatch-guard-omission'
  'dispatch-guard-reuse'='dispatch-guard-reuse'
  'dispatch-guard-arm'='dispatch-guard-arm'
  'dispatch-guard-timed'='dispatch-guard-timed'
  'dispatch-guard-regression'='dispatch-guard-regression'
  'dispatch-incident-a-route'='dispatch-incident-a-route'
  'dispatch-incident-a-binding'='dispatch-incident-a-binding'
  'dispatch-incident-a-source-native'='dispatch-incident-a-source-native'
  'dispatch-incident-b-route-baseline'='dispatch-incident-b-route-baseline'
  'dispatch-incident-b-route-matrix'='dispatch-incident-b-route-matrix'
  'dispatch-incident-b-binding-structure'='dispatch-incident-b-binding-structure'
  'dispatch-incident-b-binding-mutants'='dispatch-incident-b-binding-mutants'
  'dispatch-incident-b-source-binding'='dispatch-incident-b-source-binding'
  'dispatch-incident-b-source-remote'='dispatch-incident-b-source-remote'
  'dispatch-incident-b-native'='dispatch-incident-b-native'
  'native-branch-scope'='native-branch-scope'
  'native-branch-resume'='native-branch-resume'
}
$dispatchCaseOwners=Get-DispatchCaseOwners $dispatchSource
Assert-Ci (@($dispatchCaseOwners).Count -eq $dispatchCaseExpected.Count) 'dispatch asserting block was dropped, duplicated or merged'
foreach($caseName in $dispatchCaseExpected.Keys){
  $matches=@($dispatchCaseOwners|Where-Object name -ceq $caseName)
  Assert-Ci ($matches.Count -eq 1 -and $matches[0].part -ceq $dispatchCaseExpected[$caseName]) "dispatch case ownership is missing, duplicated or misbound: $caseName"
}
Refuses-Coverage {
  $needle="Invoke-DispatchMeasuredCase 'dispatch-guard-pid' 'dispatch-guard-pid'"
  Assert-Ci ($dispatchSource.Contains($needle)) 'dispatch duplicate-execution mutant anchor missing'
  $mutant=$dispatchSource.Replace($needle,"$needle`n$needle")
  $mutantOwners=Get-DispatchCaseOwners $mutant
  Assert-Ci (@($mutantOwners|Where-Object name -ceq 'dispatch-guard-pid').Count -eq 1) 'dispatch duplicate-execution mutant survived'
}
function Test-DispatchAstWithin($Node,$Container){ $Container.Extent.StartOffset -le $Node.Extent.StartOffset -and $Node.Extent.EndOffset -le $Container.Extent.EndOffset }
# The real part gate is the enclosing `if (& $runPart '<part>')`; the case
# helpers ignore their part argument. Each case's nearest enclosing if must be
# exactly its own part guard, and no other part guard may enclose it.
function Assert-DispatchCaseGuards([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'dispatch case guard source parse failed'
  $guardPattern='^& \$runPart ''([a-z-]+)''$'
  $isGuard={param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -ge 1 -and $n.Clauses[0].Item1.Extent.Text -cmatch $guardPattern}
  $cases=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Invoke-DispatchMeasuredCase','Start-DispatchCase')},$true))
  Assert-Ci ($cases.Count -eq $dispatchCaseExpected.Count) 'dispatch case census changed'
  foreach($case in $cases){
    Assert-Ci ($case.CommandElements.Count -ge 3 -and $case.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst] -and $case.CommandElements[2] -is [Management.Automation.Language.StringConstantExpressionAst]) 'dispatch case label is not a literal'
    $name=[string]$case.CommandElements[1].Value;$part=[string]$case.CommandElements[2].Value
    $nearest=$case.Parent; while($nearest -and $nearest -isnot [Management.Automation.Language.IfStatementAst]){$nearest=$nearest.Parent}
    Assert-Ci ($null -ne $nearest -and $nearest.Clauses.Count -eq 1 -and $null -eq $nearest.ElseClause -and
      $nearest.Clauses[0].Item1.Extent.Text -ceq "& `$runPart '$part'" -and (Test-DispatchAstWithin $case $nearest.Clauses[0].Item2)) "dispatch case is not gated by its own part guard: $name"
    $outer=0; $p=$nearest.Parent; while($p){ if(& $isGuard $p){$outer++}; $p=$p.Parent }
    Assert-Ci ($outer -eq 0) "dispatch case is enclosed by a second part guard: $name"
  }
  $guards=@($ast.FindAll($isGuard,$true))
  Assert-Ci ($guards.Count -eq $cases.Count) 'dispatch part guard without exactly one gated case'
}
Assert-DispatchCaseGuards $dispatchSource
$guardOmission="if (& `$runPart 'dispatch-guard-omission') {`n  Invoke-DispatchMeasuredCase 'dispatch-guard-omission' 'dispatch-guard-omission' { Test-TreeDeathOmissionStillRefuses }`n}"
foreach($guardMutant in @(
  @{name='swapped';edits=@(@("if (& `$runPart 'dispatch-guard-pid')","if (& `$runPart 'SWAP')"),@("if (& `$runPart 'dispatch-guard-omission')","if (& `$runPart 'dispatch-guard-pid')"),@("if (& `$runPart 'SWAP')","if (& `$runPart 'dispatch-guard-omission')"))},
  @{name='duplicated';edits=@(,@($guardOmission,"if (& `$runPart 'dispatch-guard-pid') {`n$guardOmission`n}"))},
  @{name='ungated';edits=@(,@("  if (& `$runPart 'dispatch-foundation') {`n    Invoke-DispatchMeasuredCase 'dispatch-foundation-publication'","  if (`$true) {`n    Invoke-DispatchMeasuredCase 'dispatch-foundation-publication'"))}
)){
  $mutantSource=$dispatchSource
  foreach($edit in $guardMutant.edits){
    Assert-Ci ($mutantSource.Contains($edit[0])) "dispatch $($guardMutant.name) guard mutant anchor missing"
    $mutantSource=([regex]::new([regex]::Escape($edit[0]))).Replace($mutantSource,$edit[1].Replace('$','$$'),1)
  }
  Refuses-Coverage { Assert-DispatchCaseGuards $mutantSource }
}
Write-Output 'PASS dispatch case guards: every case sits directly under its own & $runPart guard; swapped, duplicated and ungated guard mutants refused'
# Legacy switch paths keep base semantics: every base if-condition that reads a
# legacy switch keeps its exact text and multiplicity, and the verification
# policy and publication cases sit under the base outer condition with only the
# part guard added inside it.
function Assert-DispatchSwitchConditions([string]$Source,[string]$Baseline) {
  $switchPattern='\$(ValidatorOnly|FleetPreClosureOnly|NativeBranchOnly|OrdinaryOnly|ProductCensusOnly|CapacityOnly|RoutingIssueOnly|VerificationPolicyOnly)\b'
  $parse={param([string]$Text) $tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors);Assert-Ci ($errors.Count -eq 0) 'dispatch switch source parse failed';$tree}
  $before=& $parse $Baseline;$after=& $parse $Source
  $census={param($Tree) $h=@{};foreach($if in @($Tree.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst]},$true))){foreach($clause in $if.Clauses){$text=$clause.Item1.Extent.Text;if($text -cmatch $switchPattern){$h[$text]=1+[int]$h[$text]}}};$h}
  $baseConditions=& $census $before;$candidateConditions=& $census $after
  $baseText=(@($baseConditions.Keys|Sort-Object|ForEach-Object{"$_ x$($baseConditions[$_])"})-join"`n");$candidateText=(@($candidateConditions.Keys|Sort-Object|ForEach-Object{"$_ x$($candidateConditions[$_])"})-join"`n")
  Assert-Ci ($baseText -ceq $candidateText) "dispatch legacy switch conditions differ from base: $candidateText"
  foreach($pin in @(@('& $PSCommandPath -VerificationPolicyOnly','dispatch-foundation-verification-policy'),@('Test-PlatformSeatNativePublication','dispatch-foundation-publication'))){
    $baseCall=@($before.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -ceq $pin[0]},$true))
    Assert-Ci ($baseCall.Count -eq 1) "dispatch base switch anchor missing: $($pin[0])"
    $baseIf=$baseCall[0].Parent;while($baseIf -isnot [Management.Automation.Language.IfStatementAst]){$baseIf=$baseIf.Parent}
    $case=@($after.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-DispatchMeasuredCase' -and $n.CommandElements.Count -ge 2 -and $n.CommandElements[1].Extent.Text -ceq "'$($pin[1])'"},$true))
    Assert-Ci ($case.Count -eq 1) "dispatch switch case missing: $($pin[1])"
    $guard=$case[0].Parent;while($guard -isnot [Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent}
    $outer=$guard.Parent;while($outer -and $outer -isnot [Management.Automation.Language.IfStatementAst]){$outer=$outer.Parent}
    Assert-Ci ($null -ne $outer -and $outer.Clauses.Count -eq 1 -and $outer.Clauses[0].Item1.Extent.Text -ceq $baseIf.Clauses[0].Item1.Extent.Text -and (Test-DispatchAstWithin $guard $outer.Clauses[0].Item2)) "dispatch $($pin[1]) outer switch condition differs from base"
  }
}
Assert-DispatchSwitchConditions $dispatchSource $dispatchBaseline
foreach($switchMutant in @(
  @('if ($ProductCensusOnly -or (-not $ValidatorOnly -and -not $FleetPreClosureOnly -and -not $NativeBranchOnly)) {','if ($ProductCensusOnly -or (& $runPart ''dispatch-foundation'')) {'),
  @('if ($ProductCensusOnly -or (-not $ValidatorOnly -and -not $FleetPreClosureOnly -and -not $NativeBranchOnly)) {','if ($ProductCensusOnly -or (-not $ValidatorOnly -and -not $FleetPreClosureOnly)) {'),
  @('if(-not ($ValidatorOnly -or $FleetPreClosureOnly -or $NativeBranchOnly -or $OrdinaryOnly -or $ProductCensusOnly)){','if(-not ($ValidatorOnly -or $FleetPreClosureOnly -or $NativeBranchOnly -or $ProductCensusOnly)){'),
  @('if($RoutingIssueOnly){return}','if($RoutingIssueOnly -and $false){return}'),
  # Hoists keep every condition text (census unchanged); only the outer pin sees them.
  @("if(-not (`$ValidatorOnly -or `$FleetPreClosureOnly -or `$NativeBranchOnly -or `$OrdinaryOnly -or `$ProductCensusOnly)){`n  if (& `$runPart 'dispatch-foundation') {`n    Invoke-DispatchMeasuredCase 'dispatch-foundation-verification-policy' 'dispatch-foundation' { & `$PSCommandPath -VerificationPolicyOnly }`n  }`n}","if (& `$runPart 'dispatch-foundation') {`n  Invoke-DispatchMeasuredCase 'dispatch-foundation-verification-policy' 'dispatch-foundation' { & `$PSCommandPath -VerificationPolicyOnly }`n}`nif(-not (`$ValidatorOnly -or `$FleetPreClosureOnly -or `$NativeBranchOnly -or `$OrdinaryOnly -or `$ProductCensusOnly)){`n}"),
  @("  if (& `$runPart 'dispatch-foundation') {`n    Invoke-DispatchMeasuredCase 'dispatch-foundation-publication' 'dispatch-foundation' { Test-PlatformSeatNativePublication }`n  }`n  if (`$ProductCensusOnly) { return }`n}","  if (`$ProductCensusOnly) { return }`n}`nif (& `$runPart 'dispatch-foundation') {`n  Invoke-DispatchMeasuredCase 'dispatch-foundation-publication' 'dispatch-foundation' { Test-PlatformSeatNativePublication }`n}")
)){
  Assert-Ci ($dispatchSource.Contains($switchMutant[0])) "dispatch switch mutant anchor missing: $($switchMutant[0])"
  Refuses-Coverage { Assert-DispatchSwitchConditions $dispatchSource.Replace($switchMutant[0],$switchMutant[1]) $dispatchBaseline }
}
Write-Output 'PASS dispatch legacy switch conditions: base if-conditions kept exactly; verification-policy and publication under the base outer condition; 4 condition and 2 hoist mutants refused'
# Whole-run (no -Part / -Part all) dispatch-lane keeps the base carrier shape:
# the test of [chase-sets#8102 Classify a fleet-load miss of the controller battery's timed fixtures as MEASURED_LOAD, never FAIL or PASS](https://github.com/chase-sets/chase-sets/issues/8102)
# owns both literal dispatch carrier calls, guarded by the
# whole-run selector with a DEFERRED single-part branch, and the base top-level
# sequence. Single parts call carriers only through Invoke-7963ResumeCarriers
# (MEASURED_LOAD -> exit 75), never Test-7963ResumeCarrier directly.
function Assert-DispatchCarrierShape([string]$Source,[string]$Baseline) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'dispatch carrier shape parse failed'
  Assert-Ci (@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Test-7963ResumeCarrier'},$true)).Count -eq 0) 'dispatch carrier bypasses the Invoke-7963ResumeCarriers MEASURED_LOAD wrapper'
  $timed=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-TimedFixtureUnderFleetLoadMeasuresLoad'},$true))
  Assert-Ci ($timed.Count -eq 1) 'dispatch 8102 timed fixture function missing'
  $literal="Invoke-7963ResumeCarriers @('dispatch')"
  $calls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -ceq $literal},$true))
  Assert-Ci ($calls.Count -eq 2) 'dispatch whole-run carrier call count changed'
  foreach($call in $calls){
    Assert-Ci (Test-DispatchAstWithin $call $timed[0]) 'dispatch whole-run carrier call left the 8102 test'
    $guard=$call.Parent; while($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent}
    Assert-Ci ($null -ne $guard -and $guard.Clauses.Count -eq 1 -and $guard.Clauses[0].Item1.Extent.Text -ceq '$dispatchWholeRun' -and
      (Test-DispatchAstWithin $call $guard.Clauses[0].Item2) -and $null -ne $guard.ElseClause -and
      $guard.ElseClause.Extent.Text.Contains('DEFERRED 8102') -and -not $guard.ElseClause.Extent.Text.Contains('vacant=PASS')) 'dispatch whole-run carrier is not guarded by the whole-run selector with a DEFERRED single-part branch'
  }
  Assert-Ci ([regex]::Matches($timed[0].Extent.Text,'vacant=PASS').Count -eq 1) 'dispatch 8102 vacant=PASS claim duplicated or dropped'
  $whole=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses.Count -eq 1 -and $n.Clauses[0].Item1.Extent.Text -ceq '$dispatchWholeRun' -and -not (Test-DispatchAstWithin $n $timed[0])},$true))
  Assert-Ci ($whole.Count -eq 1 -and $null -ne $whole[0].ElseClause) 'dispatch whole-run top-level selector missing'
  $expected=@('Test-ReusedPidRootIsDeadByIdentity','Test-TreeDeathOmissionStillRefuses','Test-8076MeasuredReuseIsLauncherOnly','Test-ArmAfterOmissionSurvivesPreArmDelay','Test-TimedFixtureUnderFleetLoadMeasuresLoad','Test-RegressionUnderLoadIsNotMasked',"Invoke-7963ResumeCarriers @('native-branch')")
  $at=0
  foreach($statement in $expected){$at=$Baseline.IndexOf("`n$statement`n",$at,[StringComparison]::Ordinal);Assert-Ci ($at -ge 0) "dispatch base top-level sequence anchor missing: $statement";$at++}
  $actual=@($whole[0].Clauses[0].Item2.Statements|ForEach-Object{$_.Extent.Text})
  Assert-Ci (($actual -join "`n") -ceq ($expected -join "`n")) 'dispatch whole-run top-level sequence differs from base'
  $parts=[ordered]@{}
  foreach($name in @('dispatch-incident-a-route','dispatch-incident-a-binding','dispatch-incident-a-source-native','dispatch-incident-b-route-baseline','dispatch-incident-b-route-matrix','dispatch-incident-b-binding-structure','dispatch-incident-b-binding-mutants','dispatch-incident-b-source-binding','dispatch-incident-b-source-remote','dispatch-incident-b-native')){$parts[$name]='dispatch'}
  $parts['native-branch-scope']='native-branch';$parts['native-branch-resume']='native-branch'
  $measured=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Invoke-DispatchMeasuredCase' -and $n.CommandElements.Count -ge 4 -and $n.CommandElements[1] -is [Management.Automation.Language.StringConstantExpressionAst]},$true))
  foreach($case in @($measured|Where-Object{$_.CommandElements[1].Value -like 'dispatch-guard-*'})){Assert-Ci (Test-DispatchAstWithin $case $whole[0].ElseClause) "dispatch single-part guard escaped into the whole run: $($case.CommandElements[1].Value)"}
  foreach($name in $parts.Keys){
    $case=@($measured|Where-Object{$_.CommandElements[1].Value -ceq $name})
    Assert-Ci ($case.Count -eq 1 -and (Test-DispatchAstWithin $case[0] $whole[0].ElseClause)) "dispatch carrier part is missing or runs in the whole run: $name"
    $inner=@($case[0].CommandElements[3].FindAll({param($n) $n -is [Management.Automation.Language.CommandAst]},$true))
    Assert-Ci ($inner.Count -eq 1 -and $inner[0].Extent.Text -ceq "Invoke-7963ResumeCarriers -Carriers @('$($parts[$name])') -Part '$name'") "dispatch carrier part does not run through Invoke-7963ResumeCarriers with its own -Part: $name"
  }
}
$dispatchBaseHead=(ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob','62a4a6c1469beb46be27b3805a3a398fc5b598d0:.orchestrator/dispatch-lane.test.ps1'))).Replace("`r`n","`n")
Assert-DispatchCarrierShape $dispatchSource $dispatchBaseHead
foreach($carrierMutant in @(
  @("Invoke-7963ResumeCarriers -Carriers @('dispatch') -Part 'dispatch-incident-b-native'","Test-7963ResumeCarrier 'dispatch' -Part 'dispatch-incident-b-native'"),
  @("-Part 'dispatch-incident-a-route' }","-Part 'dispatch-incident-a-binding' }"),
  @("`n    Invoke-7963ResumeCarriers @('dispatch')`n","`n    Write-Output 'carrier omitted'`n"),
  @("`n    Write-Output `"PASS 8102 `$test held-miss=MEASURED_LOAD vacant-miss=FAIL vacant-mutant=CAUGHT`"`n","`n    Write-Output `"PASS 8102 `$test held-miss=MEASURED_LOAD vacant-miss=FAIL vacant-mutant=CAUGHT vacant=PASS`"`n"),
  @("`nTest-TimedFixtureUnderFleetLoadMeasuresLoad`n","`n"),
  @('if ($dispatchWholeRun) {','if ($true) {')
)){
  Assert-Ci ($dispatchSource.Contains($carrierMutant[0])) "dispatch carrier mutant anchor missing: $($carrierMutant[0])"
  $mutantSource=([regex]::new([regex]::Escape($carrierMutant[0]))).Replace($dispatchSource,$carrierMutant[1].Replace('$','$$'),1)
  Refuses-Coverage { Assert-DispatchCarrierShape $mutantSource $dispatchBaseHead }
}
Write-Output 'PASS dispatch carrier shape: whole-run base sequence and two guarded 8102 carrier calls; single parts through Invoke-7963ResumeCarriers -Part; 6 carrier mutants refused'
# Historical fixtures are verified by their raw Git blob ids computed in process.
# The tracked * -text policy keeps the public fixture bytes stable. A tampered
# copy and a line-ending-mutated copy are refused.
& {
  . (Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')
  $fixtureControlRoot=Join-Path ([IO.Path]::GetTempPath()) ('historical-fixture-control-'+[guid]::NewGuid().ToString('N'))
  try {
    $controlFixtures=Join-Path $fixtureControlRoot 'fixtures'
    [void][IO.Directory]::CreateDirectory($controlFixtures)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/historical-b3b4ac2') -Destination (Join-Path $controlFixtures 'historical-b3b4ac2') -Recurse
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/historical-aa62899') -Destination (Join-Path $controlFixtures 'historical-aa62899') -Recurse
    $successorModuleRoot=New-HistoricalDispatchFixture 'aa62899' (Join-Path $fixtureControlRoot 'out-successor') $controlFixtures
    $successorLauncher=Join-Path $successorModuleRoot 'dispatch-lane.ps1'
    Assert-Ci (Test-Path -LiteralPath $successorLauncher -PathType Leaf) 'successor baseline launcher read set missing'
    [IO.File]::Delete((Join-Path $controlFixtures 'historical-aa62899/.orchestrator/dispatch-lane.ps1'))
    $successorLauncherRefused=$false
    try { [void](New-HistoricalDispatchFixture 'aa62899' (Join-Path $fixtureControlRoot 'out-successor-missing-launcher') $controlFixtures) } catch { $successorLauncherRefused=$_.Exception.Message.Contains('HISTORICAL_FIXTURE: read set changed for aa62899') }
    Assert-Ci $successorLauncherRefused 'missing successor baseline launcher must refuse before fixture use'
    $successorModule=Import-Module (Join-Path $successorModuleRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking -PassThru
    Remove-Module $successorModule -Force
    $target=Join-Path $controlFixtures 'historical-b3b4ac2/.orchestrator/dispatch-lane.ps1'
    $lf=[IO.File]::ReadAllBytes($target)
    Assert-Ci (-not [Text.Encoding]::Latin1.GetString($lf).Contains("`r`n")) 'historical fixture control expects LF working bytes'
    [void](New-HistoricalDispatchFixture 'b3b4ac2' (Join-Path $fixtureControlRoot 'out-lf') $controlFixtures)
    $crlf=[Text.Encoding]::Latin1.GetBytes([Text.Encoding]::Latin1.GetString($lf).Replace("`n","`r`n"))
    [IO.File]::WriteAllBytes($target,$crlf)
    $lineEndingRefused=$false
    try { [void](New-HistoricalDispatchFixture 'b3b4ac2' (Join-Path $fixtureControlRoot 'out-crlf') $controlFixtures) } catch { $lineEndingRefused=$_.Exception.Message.Contains('HISTORICAL_FIXTURE: blob mismatch b3b4ac2/.orchestrator/dispatch-lane.ps1') }
    Assert-Ci $lineEndingRefused 'line-ending-mutated historical fixture was accepted'
    $tampered=[byte[]]$lf.Clone();$tampered[$tampered.Length-3]=$tampered[$tampered.Length-3] -bxor 0x20
    [IO.File]::WriteAllBytes($target,$tampered)
    $refused=$false
    try { [void](New-HistoricalDispatchFixture 'b3b4ac2' (Join-Path $fixtureControlRoot 'out-tampered') $controlFixtures) } catch { $refused=$_.Exception.Message.Contains('HISTORICAL_FIXTURE: blob mismatch b3b4ac2/.orchestrator/dispatch-lane.ps1') }
    Assert-Ci $refused 'tampered historical fixture control is RED'
    Assert-Ci (-not (Test-Path -LiteralPath (Join-Path $fixtureControlRoot 'out-tampered/.orchestrator/dispatch-lane.ps1'))) 'tampered historical fixture was copied'
    [IO.File]::Delete($target)
    $missingRefused=$false
    try { [void](New-HistoricalDispatchFixture 'b3b4ac2' (Join-Path $fixtureControlRoot 'out-missing') $controlFixtures) } catch { $missingRefused=$_.Exception.Message.Contains('HISTORICAL_FIXTURE: read set changed for b3b4ac2') }
    Assert-Ci $missingRefused 'one-file-removed historical fixture was accepted'
  } finally {
    $resolved=[IO.Path]::GetFullPath($fixtureControlRoot)
    Assert-Ci ((Split-Path -Parent $resolved) -ceq [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')) 'unsafe historical fixture control cleanup'
    if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
  }
}
Write-Output 'PASS historical fixture pins: raw Git blob ids accept pinned LF bytes; missing-file, line-ending and one-byte mutations refused'
Write-Output 'PASS successor fixture pins: nine aa62899 raw Git blobs materialize and import without the private object database'
function Assert-CarrierPartContract([string]$Path,$Item,[string[]]$CarrierCalls) {
  $source=[IO.File]::ReadAllText($Path).Replace("`r`n","`n")
  $expected=@($Item.parts.name)
  Assert-Ci ((@($expected|Sort-Object)-join',')-ceq(@((Get-SuiteExpectedParts $Path)|Sort-Object)-join',')) "carrier part census changed: $($Item.identity)"
  foreach($name in $expected){
    $selectorPresent=$source.Contains("'$name'")
    if(-not $selectorPresent -and $Item.identity -ceq 'test:lane-stall-watchdog.test.ps1' -and $name -like 'watchdog-policy-*'){
      $selectorPresent=$source.Contains("`$Part -like 'watchdog-policy-*'")
    }
    Assert-Ci $selectorPresent "carrier part selector missing: $($Item.identity) $name"
    Refuses-Coverage { Assert-Ci ((@($expected|Where-Object{$_-cne$name}|Sort-Object)-join',')-ceq(@((Get-SuiteExpectedParts $Path)|Sort-Object)-join',')) "carrier dropped part survived: $name" }
  }
  foreach($call in $CarrierCalls){ Assert-Ci (([regex]::Matches($source,[regex]::Escape($call))).Count -eq 1) "carrier arm missing or duplicated: $call" }
}
$rebasePath=Join-Path $PSScriptRoot 'rebase-integration.test.ps1'
$watchdogPath=Join-Path $PSScriptRoot 'lane-stall-watchdog.test.ps1'
$rebaseItem=$manifest.items|Where-Object identity -eq 'test:rebase-integration.test.ps1'
$watchdogItem=$manifest.items|Where-Object identity -eq 'test:lane-stall-watchdog.test.ps1'
Assert-Ci ($null -ne $rebaseItem -and $null -ne $watchdogItem) 'historical carrier split mappings missing'
Assert-CarrierPartContract $rebasePath $rebaseItem @(
  "Test-7963ResumeCarrier 'rebase'",
  "Test-9334OrdinaryCarrier 'ordinary-rebase' -Part 'ordinary-rebase-live'",
  "Test-9334OrdinaryCarrier 'ordinary-rebase' -Part 'ordinary-rebase-retry'",
  "Test-9334OrdinaryCarrier 'successor-rebase'",
  "Test-9334OrdinaryCarrier 'successor-publication'",
  "Test-9334OrdinaryCarrier 'successor-amend'")
Assert-CarrierPartContract $watchdogPath $watchdogItem @()
Assert-Ci (([regex]::Matches([IO.File]::ReadAllText($watchdogPath),[regex]::Escape("Test-7963ResumeCarrier 'watchdog'")).Count -eq 2) -and
  ([regex]::Matches([IO.File]::ReadAllText($watchdogPath),[regex]::Escape("Test-9334OrdinaryCarrier 'ordinary-watchdog'")).Count -eq 2)) 'watchdog historical/ordinary carrier arms missing or duplicated'
Assert-Ci (([regex]::Matches([IO.File]::ReadAllText($watchdogPath),[regex]::Escape("Test-9334OrdinaryCarrier 'successor-watchdog'")).Count -eq 2)) 'watchdog successor carrier arms missing or duplicated'
$rebaseText=[IO.File]::ReadAllText($rebasePath)
foreach($name in @($rebaseItem.parts.name)){ Assert-Ci ($rebaseText.Contains("& `$runPart '$name'") -or $rebaseText.Contains("`$Part -ceq '$name'")) "rebase carrier guard dropped: $name" }
Assert-Ci (([IO.File]::ReadAllText($watchdogPath).Contains("if(-not `$Part){"))) 'watchdog legacy carrier whole-run guard dropped'
Refuses-Coverage { Assert-CarrierPartContract $rebasePath ([pscustomobject]@{parts=@($rebaseItem.parts|Where-Object name -cne 'rebase-amend');identity=$rebaseItem.identity}) @() }
Refuses-Coverage { Assert-CarrierPartContract $watchdogPath ([pscustomobject]@{parts=@($watchdogItem.parts|Where-Object name -cne 'watchdog-historical');identity=$watchdogItem.identity}) @() }
Write-Output 'PASS historical carrier part ownership: rebase and watchdog selectors, carrier arms, legacy whole-run guard, and dropped-part mutants refused'
$r3Path=Join-Path $PSScriptRoot 'landed-integration-r3.test.ps1'
$r3Item=$manifest.items|Where-Object identity -eq 'test:landed-integration-r3.test.ps1'
Assert-Ci ($null -ne $r3Item) 'r3 split mapping missing'
Assert-CarrierPartContract $r3Path $r3Item @()
$r3Source=[IO.File]::ReadAllText($r3Path)
function Assert-R3WitnessOwner([string]$Source) {
  Assert-Ci ($Source.Contains("if (& `$runPart 'three-native-source') { Assert-SyntheticIntegrationWitnesses `$fixtureRoot }")) 'synthetic source scan and real-repository negative must have one owner'
  Assert-Ci ($Source.Contains("if(`$Part -cin @('three-native-boundaries','three-native-retained','three-native-watchdog')) { Assert-SyntheticIntegrationWitnessFiles `$fixtureRoot }")) 'each disjoint native fixture must validate its own witnesses'
}
Assert-R3WitnessOwner $r3Source
Assert-Ci ($r3Source.Contains("`$nativePart=if(`$Part -cin `$nativeParts){`$Part}else{''}") -and
  $r3Source.Contains('Test-7962NativeControls -RepositoryRoot (Split-Path -Parent $PSScriptRoot) -Part $nativePart')) 'r3 native part selection must reach its controls'
Assert-Ci ($r3Source.Contains("if (& `$runPart `$ordinaryPart) { Invoke-9334OrdinaryCarriers @('ordinary-dispatch') -Part `$ordinaryPart }")) 'r3 ordinary part selection must reach its carrier'
Refuses-Coverage { Assert-Ci (($r3Source.Replace('-Part $nativePart','')).Contains('Test-7962NativeControls -RepositoryRoot (Split-Path -Parent $PSScriptRoot) -Part $nativePart')) 'native part forwarding removed' }
Refuses-Coverage { Assert-Ci (($r3Source.Replace('-Part $ordinaryPart','')).Contains("Invoke-9334OrdinaryCarriers @('ordinary-dispatch') -Part `$ordinaryPart")) 'ordinary part forwarding removed' }
Refuses-Coverage { Assert-R3WitnessOwner ($r3Source.Replace("if (& `$runPart 'three-native-source') { Assert-SyntheticIntegrationWitnesses", "if (& `$runPart 'three-completed-rebase') { Assert-SyntheticIntegrationWitnesses")) }
Refuses-Coverage { Assert-R3WitnessOwner ($r3Source.Replace("'three-native-boundaries','three-native-retained','three-native-watchdog'","'three-native-boundaries','three-native-watchdog'")) }
Assert-Ci ('ordinary-dispatch' -cnotin @($r3Item.parts.name) -and 'three-native-controls' -cnotin @($r3Item.parts.name) -and 'three-completed-rebase' -cnotin @($r3Item.parts.name)) 'oversized r3 part identities still registered'
function Assert-R3LoadArmOwnership([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count-eq0) 'r3 classifier selector source parse failed'
  $functions=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Test-TimedFixtureUnderFleetLoadMeasuresLoad'},$true))
  Assert-Ci ($functions.Count-eq1) 'r3 classifier function missing or duplicated'
  $statements=@($functions[0].Body.EndBlock.Statements)
  $flags=@('$runHeld','$runVacant','$runMutant')
  for($i=0;$i-lt$flags.Count;$i++){
    Assert-Ci ($statements[$i+1]-is[Management.Automation.Language.AssignmentStatementAst]-and$statements[$i+1].Left.Extent.Text-ceq$flags[$i]) 'r3 classifier selector prefix changed'
    $arms=@($functions[0].Body.FindAll({param($n) $n-is[Management.Automation.Language.IfStatementAst]-and$n.Clauses[0].Item1.Extent.Text-ceq$flags[$i]},$true))
    Assert-Ci ($arms.Count-eq1-and$arms[0].Extent.Text.Contains('Invoke-8102RetainedLeg')) 'r3 classifier flag must gate exactly one real leg'
  }
  Assert-Ci ($statements[4]-is[Management.Automation.Language.IfStatementAst]-and$statements[4].Extent.Text.Contains('R3_LOAD_PART_NO_ARM')) 'r3 classifier no-arm guard must precede fixtures and impact returns'
  # Execute only the real selector assignments and guard, never the test body.
  $select=[scriptblock]::Create('param([string]$Part)'+"`n"+(($statements[1..4]|ForEach-Object {$_.Extent.Text})-join"`n")+"`n"+'@($runHeld,$runVacant,$runMutant)')
  $parts=@('three-load-held','three-load-vacant','three-load-mutant')
  Assert-Ci ((@($r3Item.parts.name|Where-Object {$_-clike'three-load-*'}|Sort-Object)-join',')-ceq(@($parts|Sort-Object)-join',')) 'r3 classifier manifest arms changed'
  for($i=0;$i-lt$parts.Count;$i++){
    $selected=@(& $select $parts[$i])
    Assert-Ci ($selected.Count-eq3-and@($selected|Where-Object {$_}).Count-eq1-and$selected[$i]) "r3 classifier part selects no arm or the wrong arm: $($parts[$i])"
  }
  Assert-Ci ((@(& $select ''|Where-Object {$_})).Count-eq3) 'r3 omitted selector must retain all classifier arms'
  foreach($invalid in @('8102-held','8102-vacant','8102-mutant','three-load-unknown')){
    $failure=$null;try{& $select $invalid|Out-Null}catch{$failure=$_.Exception.Message}
    Assert-Ci ($failure-ceq'R3_LOAD_PART_NO_ARM: selected part owns no classifier arm') 'r3 unknown/stale selector must trip the executable no-arm guard'
  }
}
Assert-R3LoadArmOwnership $r3Source
foreach($arm in @('held','vacant','mutant')){
  Refuses-Coverage { Assert-R3LoadArmOwnership ($r3Source.Replace("`$Part -ceq 'three-load-$arm'","`$Part -ceq '8102-$arm'")) }
}
Refuses-Coverage { Assert-R3LoadArmOwnership ($r3Source.Replace("if(`$Part -and -not(`$runHeld -or `$runVacant -or `$runMutant)){throw 'R3_LOAD_PART_NO_ARM: selected part owns no classifier arm'}",'')) }
Refuses-Coverage { Assert-R3LoadArmOwnership ($r3Source.Replace('if($runHeld){','if($runVacant){')) }
Write-Output 'PASS r3 classifier arm ownership: each manifest part selects one real leg, omitted selector selects all; stale names trip no-arm guard; stale-selector, removed-guard and misgated-arm negatives refused'
function Assert-R3HeldCarrierDiagnostics([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count-eq0) 'r3 held-carrier diagnostics source parse failed'
  $names=@('Get-8102HeldCarrierFacts','Get-8102HeldPairFacts','Format-8102HeldCarrierDiagnostic','Write-8102HeldCarrierDiagnostic','Assert-8102')
  foreach($name in $names){
    $functions=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true))
    Assert-Ci ($functions.Count-eq1) "r3 held-carrier diagnostics helper missing or duplicated: $name"
    . ([scriptblock]::Create($functions[0].Extent.Text))
  }
  Assert-Ci ($Source.Contains("if(`$null -ne `$Leg-and`$Leg.label-ceq'phantom-root-held'){Write-8102HeldCarrierDiagnostic `$Leg}")) 'held-carrier diagnostics call was removed or widened'
  Assert-Ci ($Source.Contains('[Console]::Error.WriteLine($line)')-and$Source.Contains("[Console]::Error.WriteLine('8102_HELD_CARRIER_UNAVAILABLE')")) 'held-carrier diagnostics must publish only to stderr and fail closed'
  Assert-Ci ($Source.Contains('[Text.Encoding]::UTF8.GetByteCount($text)')-and$Source.Contains('if($lineBytes-gt2048){throw')) 'held-carrier diagnostics lost UTF-8 byte bounds'
  Assert-Ci ($Source.Contains("facts=(Get-8102HeldCarrierFacts `$text)")-and$Source.Contains('$pair=Get-8102HeldPairFacts $Leg.pair')) 'held-carrier diagnostics copied unallowlisted stream text or dropped pair projection'
  Assert-Ci ($Source.Contains('EXCEPTION 7963 retained 7963 retained ASSERTION FAILED:')-and$Source.Contains('$pair=''unavailable''')) 'held-carrier diagnostics lost real exception prefix or unavailable pair marker'
  $secret='synthetic-bearer-never-valid';$path='C:\Users\Todd\synthetic\held-secret.txt';$unicode=([string][char]0x754C)*2000
  $stdout="PROOF 7963 retained earlier discriminator candidate exit=99 independent omitted guard actual exit=88`nEXCEPTION 7963 retained 7963 retained ASSERTION FAILED: retained retry binds its current full index independent omitted guard actual exit=1 expected=0 plan=RAN harness=NOTRUN all target/runtime bytes=UNCHANGED raw=$path STACK ...`nRETAINED 7963 retained native objects, stage bodies, entry snapshots and source evidence: $path; finished=False`n$unicode"
  $stderr="R3_PRIOR_TEARDOWN: ambiguous root`nAuthorization: Bearer $secret`n$unicode"
  $pair=[pscustomobject]@{name='retained retry binds its current full index';mutantExit=1;fleetLoad=[pscustomobject]@{held=$true}}
  $leg=[pscustomobject]@{label='phantom-root-held';exit=1;pair=$pair;run=[pscustomobject]@{stdout=$stdout;stderr=$stderr;stdoutPath=$path;stderrPath=(Join-Path $path 'stderr')}}
  $previousError=[Console]::Error;$errorCapture=[IO.StringWriter]::new()
  try {
    [Console]::SetError($errorCapture)
    $LASTEXITCODE=19
    $failure=$null;try{Assert-8102 $false 'synthetic-held' 'original failure' $leg}catch{$failure=$_.Exception.Message}
    $expected="8102 synthetic-held ASSERTION FAILED: original failure; leg=phantom-root-held exit=1 stdout=$path stderr=$(Join-Path $path 'stderr')"
    Assert-Ci ($failure-ceq$expected-and$LASTEXITCODE-eq19) 'held diagnostic changed the original assertion failure or exit code'
    $line=$errorCapture.ToString().TrimEnd("`r","`n");$prefix='8102_HELD_CARRIER '
    Assert-Ci ($line.StartsWith($prefix,[StringComparison]::Ordinal)-and[Text.Encoding]::UTF8.GetByteCount($line)-le2048) 'held diagnostic missing prefix or exceeding UTF-8 byte bound'
    Assert-Ci (-not$line.Contains($secret)-and-not$line.Contains($path)-and-not$line.Contains('root=')-and-not$line.Contains('raw=')) 'held diagnostic leaked secret/path/free-form payload'
    $payload=$line.Substring($prefix.Length)|ConvertFrom-Json
    $expectedStdoutBytes=[Text.Encoding]::UTF8.GetByteCount($stdout);$expectedStderrBytes=[Text.Encoding]::UTF8.GetByteCount($stderr)
    Assert-Ci ($payload.exit-eq1-and$payload.stdout.bytes-eq$expectedStdoutBytes-and$payload.stderr.bytes-eq$expectedStderrBytes-and
      $payload.stdout.overLimit-and$payload.stderr.overLimit-and
      $payload.stdout.facts.exception-and$payload.stdout.facts.proofName-ceq'retained retry binds its current full index'-and
      $null-eq$payload.stdout.facts.candidateExit-and$payload.stdout.facts.omittedGuardExit-eq1-and$payload.stdout.facts.finished-eq$false-and
      $payload.stderr.facts.teardownReason-ceq'R3_PRIOR_TEARDOWN: ambiguous root' -and
      $payload.pair.mutantExit-eq1-and$payload.pair.fleetLoadHeld) 'held diagnostic lost bounded carrier families, pair evidence or UTF-8 byte counts'
    $facts=Get-8102HeldCarrierFacts "PROOF 7963 retained earlier candidate exit=99 independent omitted guard actual exit=88`nEXCEPTION 7963 retained 7963 retained ASSERTION FAILED: retained retry binds its current full index candidate exit=7 expected=0 plan=RAN harness=NOTRUN`nMEASURED_LOAD 7963 retained fleetHolder=synthetic elapsedSeconds=30 discriminator=retained retry binds its current full index mutantExit=1 raw=$path`nRETAINED 7963 retained native objects, stage bodies, entry snapshots and source evidence: $path; finished=True`nINTEGRATION_RESUME_PRIOR_OWNER: live root"
    Assert-Ci ($facts.candidateExit-eq7-and$null-eq$facts.omittedGuardExit-and$facts.measuredLoad-and$facts.finished-and$facts.resumeReason-ceq'INTEGRATION_RESUME_PRIOR_OWNER: live root') 'carrier reason/exit families were not projected from the failing exception line'
    $notHeldPair=[pscustomobject]@{name='retained retry binds its current full index';mutantExit=1;fleetLoad=[pscustomobject]@{held=$false}}
    $notHeld=$leg|Select-Object *;$notHeld.pair=$notHeldPair
    $notHeldPayload=(Format-8102HeldCarrierDiagnostic $notHeld).Substring($prefix.Length)|ConvertFrom-Json
    Assert-Ci ($notHeldPayload.stdout.facts.proofName-ceq'retained retry binds its current full index'-and$notHeldPayload.stdout.facts.omittedGuardExit-eq1-and$notHeldPayload.pair.fleetLoadHeld-eq$false) 'realistic not-held refusal pair was not attributed'
    $unrelated=[pscustomobject]@{label='phantom-root-held';exit=1;pair='unavailable';run=[pscustomobject]@{stdout='EXCEPTION 7963 retained R3_PRIOR_TEARDOWN: native inventory unavailable STACK controller stack';stderr='R3_PRIOR_TEARDOWN: native inventory unavailable';stdoutPath=$path;stderrPath=(Join-Path $path 'stderr')}}
    $unrelatedPayload=(Format-8102HeldCarrierDiagnostic $unrelated).Substring($prefix.Length)|ConvertFrom-Json
    Assert-Ci ($unrelatedPayload.stdout.facts.teardownReason-ceq'R3_PRIOR_TEARDOWN: native inventory unavailable'-and$unrelatedPayload.pair-ceq'unavailable'-and$unrelatedPayload.stderr.facts.teardownReason-ceq'R3_PRIOR_TEARDOWN: native inventory unavailable') 'pair-unavailable marker collapsed or lost stream facts'
    function Get-8102HeldCarrierFacts { return [ordered]@{exception=$true;proofName=('x'*3000);candidateExit=$null;omittedGuardExit=$null;teardownReason=$null;resumeReason=$null;measuredLoad=$false;finished=$null} }
    $overflowFailure=$null;try{Format-8102HeldCarrierDiagnostic $leg|Out-Null}catch{$overflowFailure=$_.Exception.Message}
    Assert-Ci ($overflowFailure-ceq'held carrier diagnostic exceeds UTF-8 byte bound') 'oversized projected carrier facts did not fail closed at the UTF-8 line bound'
    [void]$errorCapture.GetStringBuilder().Clear()
    $vacant=$leg|Select-Object *;$vacant.label='phantom-root-vacant'
    $vacantFailure=$null;try{Assert-8102 $false 'synthetic-vacant' 'vacant failure' $vacant}catch{$vacantFailure=$_.Exception.Message}
    Assert-Ci ($vacantFailure-clike'8102 synthetic-vacant ASSERTION FAILED:*'-and$errorCapture.ToString()-ceq'') 'non-held failure unexpectedly published held diagnostics'
    [void]$errorCapture.GetStringBuilder().Clear()
    $LASTEXITCODE=19
    $formatterFailure=$null;try{& { function Format-8102HeldCarrierDiagnostic { throw 'synthetic formatter failure' };Assert-8102 $false 'synthetic-held' 'original failure' $leg }}catch{$formatterFailure=$_.Exception.Message}
    Assert-Ci ($formatterFailure-ceq$expected-and$LASTEXITCODE-eq19-and$errorCapture.ToString().Trim()-ceq'8102_HELD_CARRIER_UNAVAILABLE') 'formatter failure did not preserve the original assertion/exit or fail closed'
    [void]$errorCapture.GetStringBuilder().Clear();[void](Assert-8102 $true 'synthetic-held' 'no failure' $leg)
    Assert-Ci ($errorCapture.ToString()-ceq'') 'successful held assertion published diagnostics'
  } finally { [Console]::SetError($previousError);$errorCapture.Dispose() }
}
Assert-R3HeldCarrierDiagnostics $r3Source
$heldDiagnosticMutants=@(
  @('if($null -ne $Leg-and$Leg.label-ceq''phantom-root-held''){Write-8102HeldCarrierDiagnostic $Leg}','if($false){Write-8102HeldCarrierDiagnostic $Leg}'),
  @('if($lineBytes-gt2048){throw ''held carrier diagnostic exceeds UTF-8 byte bound''}','if($false){throw ''held carrier diagnostic exceeds UTF-8 byte bound''}'),
  @('[Console]::Error.WriteLine($line)','[Console]::Out.WriteLine($line)'),
  @('facts=(Get-8102HeldCarrierFacts $text)','facts=$text'),
  @('overLimit=($bytes-gt$maxStreamBytes)','overLimit=$false'),
  @('throw "8102 $Test ASSERTION FAILED: $Name; leg=$($Leg.label) exit=$($Leg.exit) stdout=$($Leg.run.stdoutPath) stderr=$($Leg.run.stderrPath)"','return')
)
foreach($mutant in $heldDiagnosticMutants){
  Assert-Ci (([regex]::Matches($r3Source,[regex]::Escape($mutant[0]))).Count-eq1) "r3 held-carrier diagnostic mutant anchor missing or duplicated: $($mutant[0])"
  Refuses-Coverage { Assert-R3HeldCarrierDiagnostics $r3Source.Replace($mutant[0],$mutant[1]) }
}
Write-Output 'PASS r3 held-carrier diagnostics: failure-only stderr publication, closed carrier/pair projections, secret/path suppression, UTF-8 bounds and original failure preservation; removal, unbounded, stdout, unredacted, over-limit and swallowed-throw mutants refused'
# Keep the full proof/helper source immutable: only entrypoint routing changes.
$completedBaseline=ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob','1238d8ae56ba7142013a2c0076a7349b1d569266'))
$completedSupport=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'landed-integration-evidence-test-support.ps1'))
$completedOwners=[ordered]@{
  'three-completed-rebase-prospective'='prospective'
  'three-completed-rebase-platform'='platform'
  'three-completed-rebase-platform-complete'='platform-complete'
  'three-completed-rebase-platform-complete-recheck'='platform-complete-recheck'
  'three-completed-rebase-late-owed'='late-owed'
  'three-completed-rebase-legacy'='legacy'
  'three-completed-rebase-skip-release'='skip-release'
  'three-completed-rebase-review'='review'
  'three-completed-rebase-planning'='planning'
  'three-completed-rebase-foreign-release'='foreign-release'
}
function Assert-R3CompletedRebaseOwnership([string]$Source,[string]$Support) {
  Assert-Ci ($Support.Replace("`r`n","`n") -ceq $completedBaseline.Replace("`r`n","`n")) 'completed-rebase assertion/control/mutant/fixture source changed'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'completed-rebase entrypoint parse failed'
  $maps=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$completedRebaseModes'},$true))
  Assert-Ci ($maps.Count -eq 1) 'completed-rebase mode map missing or duplicated'
  $tables=@($maps[0].Right.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true))
  Assert-Ci ($tables.Count -eq 1) 'completed-rebase literal mode ownership missing'
  $entries=@($tables[0].KeyValuePairs | ForEach-Object { [pscustomobject]@{Key=$_.Item1.SafeGetValue();Value=$_.Item2.SafeGetValue()} })
  Assert-Ci ($entries.Count -eq $completedOwners.Count) 'completed-rebase mode ownership cardinality changed'
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($entry in $entries){
    Assert-Ci ($completedOwners.Contains($entry.Key) -and $completedOwners[$entry.Key] -ceq $entry.Value -and $seen.Add([string]$entry.Value)) 'completed-rebase mode missing/duplicated/misowned'
  }
  $defaults=@(($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ceq 'Modes'}).DefaultValue.SafeGetValue())
  Assert-Ci (($defaults -join ',') -ceq (@($completedOwners.Values) -join ',')) 'completed-rebase default modes changed'
  Assert-Ci ((@($r3Item.parts.name | Where-Object {$_ -clike 'three-completed-rebase*'} | Sort-Object) -join ',') -ceq (@($completedOwners.Keys | Sort-Object) -join ',')) 'completed-rebase manifest ownership changed'
  foreach($wire in @(
    "`$completedRebasePart=if(`$Part -cin @(`$completedRebaseModes.Keys)){`$Part}else{'three-completed-rebase-prospective'}"
    "`$completedModes=if(`$Part -cin @(`$completedRebaseModes.Keys)){@(`$completedRebaseModes[`$Part])}else{`$Modes}"
    "'7926' {`$completedRebasePart;break}"
    "name='7926';body={Test-7926CompletedRebase -Modes `$completedModes -CensusLatencyMs `$CensusLatencyMs}"
    'if(-not (& $runPart $partName)){continue}'
  )){
    Assert-Ci (([regex]::Matches($Source,[regex]::Escape($wire))).Count -eq 1) 'completed-rebase selected modes/part guard must reach exactly one control'
  }
}
Assert-R3CompletedRebaseOwnership $r3Source $completedSupport
$modeEntry="    'three-completed-rebase-platform'='platform'"
Assert-Ci ($r3Source.Contains($modeEntry)) 'completed-rebase negative seam missing'
Refuses-Coverage { Assert-R3CompletedRebaseOwnership ($r3Source.Replace($modeEntry,'')) $completedSupport }
Refuses-Coverage { Assert-R3CompletedRebaseOwnership ($r3Source.Replace($modeEntry,$modeEntry+"`n"+$modeEntry)) $completedSupport }
Refuses-Coverage { Assert-R3CompletedRebaseOwnership ($r3Source.Replace($modeEntry,"    'three-completed-rebase-platform'='prospective'")) $completedSupport }
Refuses-Coverage { Assert-R3CompletedRebaseOwnership ($r3Source.Replace('-Modes $completedModes','-Modes $Modes')) $completedSupport }
Refuses-Coverage { Assert-R3CompletedRebaseOwnership ($r3Source.Replace('if(-not (& $runPart $partName)){continue}','')) $completedSupport }
Refuses-Coverage { Assert-R3CompletedRebaseOwnership $r3Source ($completedSupport.Replace('Proof ($consumerReplay.exit -eq 0','Proof ($true -or $consumerReplay.exit -eq 0')) }
Refuses-Coverage { Assert-R3CompletedRebaseOwnership $r3Source ($completedSupport+"`n"+$completedSupport) }
Write-Output 'PASS r3 completed-rebase exact mode ownership: ten independent modes; immutable proofs, controls, mutants and fixtures; dropped/duplicate/misowned/forwarding/guard/weakened-proof negatives refused'
foreach($part in @($r3Item.parts.name)){
  Assert-Ci ($r3Source.Contains("'$part'")) "r3 selector missing: $part"
  Refuses-Coverage { Assert-Ci ((@($r3Item.parts.name|Where-Object{$_-cne$part}|Sort-Object)-join',')-ceq(@((Get-SuiteExpectedParts $r3Path)|Sort-Object)-join',')) "r3 dropped part survived: $part" }
}
Refuses-Coverage { Assert-Ci ((@($r3Item.parts.name|Select-Object -Skip 1|Sort-Object)-join',')-ceq(@((Get-SuiteExpectedParts $r3Path)|Sort-Object)-join',')) 'r3 first-part omission survived' }
Refuses-Coverage { Assert-Ci ((@($r3Item.parts.name)+@('r3-duplicate')|Sort-Object)-join',' -eq (@((Get-SuiteExpectedParts $r3Path)|Sort-Object)-join',')) 'r3 duplicate part survived' }
Write-Output 'PASS r3 named part ownership: selector map is complete and dropped/duplicate part mutants refuse'

# Compare ordered assertion/control traces, not multisets. Only selector-only
# conditions are evaluated; no fixture, test body, native child or fleet read runs.
function Get-R3AggregateOrder([string]$Source,[string]$FunctionName) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source.Replace("`r`n","`n"),[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count-eq0) 'aggregate-order source parse failed'
  $functions=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$FunctionName},$true))
  Assert-Ci ($functions.Count-eq1) "aggregate-order function missing/duplicated: $FunctionName"
  foreach($node in $functions[0].Body.FindAll({param($n)
    $n-is[Management.Automation.Language.CommandAst]-and($n.GetCommandName()-clike'Assert-*'-or$n.GetCommandName()-clike'Proof*'-or
      $n.GetCommandName()-cin @('Check','Control','ValidPlan9334','Refusal9334','Discriminator9334','Mutant9334','New-Subject','Invoke-8102RetainedLeg','Test-9334OrdinaryCarrier'))
  },$true)){
    $included=$true
    for($parent=$node.Parent;$parent-and$parent-ne$functions[0];$parent=$parent.Parent){
      if($parent-isnot[Management.Automation.Language.IfStatementAst]){continue}
      $conditions=@($parent.Clauses|ForEach-Object{$_.Item1})
      $variables=@($conditions|ForEach-Object{$_.FindAll({param($n) $n-is[Management.Automation.Language.VariableExpressionAst]},$true)})
      if($variables.Count-eq0-or@($variables|Where-Object{$_.VariablePath.UserPath-cne'Part'}).Count){continue}
      Assert-Ci (@($conditions|ForEach-Object{$_.FindAll({param($n) $n-is[Management.Automation.Language.CommandAst]-or$n-is[Management.Automation.Language.InvokeMemberExpressionAst]},$true)}).Count-eq0) 'aggregate selector condition must be expression-only'
      $selected=$parent.ElseClause
      foreach($clause in $parent.Clauses){
        if(& ([scriptblock]::Create('param($Part) '+$clause.Item1.Extent.Text)) ''){$selected=$clause.Item2;break}
      }
      if($null-eq$selected-or$node.Extent.StartOffset-lt$selected.Extent.StartOffset-or$node.Extent.EndOffset-gt$selected.Extent.EndOffset){$included=$false;break}
    }
    if($included){$node.GetCommandName()+':'+$node.Extent.Text}
  }
}
function Assert-R3AggregateTrace([string[]]$Actual,[string[]]$Expected,[string]$FunctionName) {
  Assert-Ci ($Expected.Count-gt0-and$Actual.Count-eq$Expected.Count) "aggregate assertion/control count changed: $FunctionName"
  for($i=0;$i-lt$Expected.Count;$i++){
    Assert-Ci ($Actual[$i]-ceq$Expected[$i]) "aggregate assertion/control order changed: $FunctionName index=$i"
  }
}
function Assert-R3AggregateOrder([string]$Source,[string]$Baseline,[string]$FunctionName) {
  $expected=@(Get-R3AggregateOrder $Baseline $FunctionName)
  $actual=@(Get-R3AggregateOrder $Source $FunctionName)
  Assert-R3AggregateTrace $actual $expected $FunctionName
  return $actual.Count
}
$aggregateBase='67ecf1ff740ad8a65aa27689eb49e345854e2e68'
$aggregateSources=@{
  'interrupted-integration-test-support.ps1'=@{blob='d727ffd657698017569d7ae4dcf3d9823238f368';functions=@('Test-9334OrdinaryCarrier','Test-7963ResumeCarrier','Invoke-9334OrdinaryCarriers')}
  'integration-dispatch-test-support.ps1'=@{blob='1d7a8fa8695478f02896f171bb74037d4a2e00af';functions=@('Test-7962NativeControls')}
  'landed-integration-evidence-test-support.ps1'=@{blob='8e36cbefe749fbdd4eaa034d46cb773833bf51d1';functions=@('Test-7926CompletedRebase')}
  'landed-integration-r3.test.ps1'=@{blob='a90ea0223b1e984134555c0107e410a321f341c1';functions=@('Test-TimedFixtureUnderFleetLoadMeasuresLoad')}
}
function Assert-RetainedFleetObservation([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count-eq0) 'retained observation source parse failed'
  $helpers=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Write-7963FleetLoadObservation'},$true))
  Assert-Ci ($helpers.Count-eq1) 'retained observation helper missing/duplicated'
  . ([scriptblock]::Create($helpers[0].Extent.Text))
  $hook="if(`$LoadBound-and`$Carrier-ceq'retained'){Write-7963FleetLoadObservation (`$bypass.resultPath.Replace('.result.json','.pair.json')) `$fleetContainer}"
  Assert-Ci ($Source.Contains("Save (`$bypass.resultPath.Replace('.result.json','.pair.json')) `$pair"+"`n    "+$hook)) 'retained observation must read the actual just-saved pair only in its load-bound arm'
  $path=Join-Path ([IO.Path]::GetTempPath()) ('r3-fleet-observation-'+[guid]::NewGuid().ToString('N')+'.pair.json')
  $container=Join-Path ([IO.Path]::GetTempPath()) 'synthetic-runner-workspace'
  $ownerPath=Join-Path $container '.orchestrator/verify-lock.d/owner.json'
  $previous=[Console]::Out;$capture=[IO.StringWriter]::new()
  try {
    [Console]::SetOut($capture)
    foreach($reason in @('absent','live')){
      $pair=@{fleetLoad=@{start=@{reason=$reason;ownerPath=$ownerPath};end=@{reason=$reason;ownerPath=$ownerPath}};unexpectedSecret='synthetic-token-never-valid'}
      [IO.File]::WriteAllText($path,($pair|ConvertTo-Json -Depth 5 -Compress))
      $hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
      [void]$capture.GetStringBuilder().Clear()
      Write-7963FleetLoadObservation $path $container
      $line=$capture.ToString().TrimEnd("`r","`n")
      Assert-Ci ($line-ceq"OBSERVATION 7963 retained fleetLoad reason=$reason endReason=$reason ownerPath=$($ownerPath|ConvertTo-Json -Compress) pair=$hash") 'retained observation lost actual pair values or SHA256 binding'
      Assert-Ci ($line.Length-le2048-and$line-cnotmatch'[\r\n]'-and-not$line.Contains('synthetic-token-never-valid')) 'retained observation leaked unowned content or exceeded single-line bound'
    }
    foreach($invalid in @('reason','ownerPath','oversize')){
      if($invalid-ceq'reason'){$pair.fleetLoad.start.reason='synthetic-token-never-valid'}
      if($invalid-ceq'ownerPath'){$pair.fleetLoad.start.reason='absent';$pair.fleetLoad.start.ownerPath='synthetic-token-never-valid'}
      if($invalid-ceq'oversize'){$container='x'*2100;$pair.fleetLoad.start.ownerPath=Join-Path $container '.orchestrator/verify-lock.d/owner.json';$pair.fleetLoad.end.ownerPath=$pair.fleetLoad.start.ownerPath}
      [IO.File]::WriteAllText($path,($pair|ConvertTo-Json -Depth 5 -Compress))
      [void]$capture.GetStringBuilder().Clear()
      Write-7963FleetLoadObservation $path $container
      Assert-Ci ($capture.ToString().Trim()-ceq'OBSERVATION 7963 retained fleetLoad unavailable') 'retained observation validation must be closed and outcome-neutral'
    }
    [IO.File]::Delete($path);[void]$capture.GetStringBuilder().Clear()
    Write-7963FleetLoadObservation $path $container
    Assert-Ci ($capture.ToString().Trim()-ceq'OBSERVATION 7963 retained fleetLoad unavailable') 'retained observation read failure must not change pass/fail semantics'
  } finally { [Console]::SetOut($previous);$capture.Dispose();[IO.File]::Delete($path) }
}
$retainedSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'interrupted-integration-test-support.ps1')).Replace("`r`n","`n")
Assert-RetainedFleetObservation $retainedSource
Refuses-Coverage { Assert-RetainedFleetObservation ($retainedSource.Replace('reason=$($start.reason)','reason=absent')) }
Refuses-Coverage { Assert-RetainedFleetObservation ($retainedSource.Replace('pair=$hash','pair=unbound')) }
Refuses-Coverage { Assert-RetainedFleetObservation ($retainedSource.Replace('if($LoadBound-and$Carrier-ceq''retained'')','if($LoadBound)')) }
Write-Output 'PASS retained fleet observation: actual pair reason/runner ownerPath/SHA256; bounded closed fields and read failures outcome-neutral; constant-reason, unbound-hash and wrong-arm negatives refused'
foreach($leaf in $aggregateSources.Keys){
  $entry=$aggregateSources[$leaf]
  Assert-Ci ((ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('rev-parse',"${aggregateBase}:.orchestrator/$leaf"))).Trim()-ceq$entry.blob) "aggregate baseline blob mismatch: $leaf"
  $before=ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',$entry.blob))
  $after=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $leaf)).Replace("`r`n","`n")
  foreach($name in $entry.functions){
    $count=Assert-R3AggregateOrder $after $before $name
    # Swap each distinct adjacent pair in the projected trace to exercise every
    # assertion position, without running the underlying heavy function.
    $trace=@(Get-R3AggregateOrder $after $name)
    $baselineTrace=@(Get-R3AggregateOrder $before $name)
    for($i=1;$i-lt$trace.Count;$i++){
      if($trace[$i]-ceq$trace[$i-1]){continue}
      $mutant=@($trace);$mutant[$i-1]=$trace[$i];$mutant[$i]=$trace[$i-1]
      Refuses-Coverage { Assert-R3AggregateTrace $mutant $baselineTrace $name }
    }
    if($name-ceq'Test-9334OrdinaryCarrier'){
      $anchor="      ValidPlan9334 `$f 'original ordinary fixture after independent destructive controls'"
      $historical="      if (-not `$Part -or `$Part -ceq 'ordinary-historical') {"
      Assert-Ci ($after.Contains($anchor)-and$after.Contains($historical)) 'aggregate early-assertion negative anchor missing'
      $mutant=$after.Replace($anchor,'').Replace($historical,$anchor+"`n"+$historical)
      Refuses-Coverage { Assert-R3AggregateOrder $mutant $before $name }
    }
    Write-Output "PASS r3 omitted-selector aggregate order: $name keys=$count baseline=$aggregateBase; order negatives refused"
  }
}

# Exact pre-split blobs, including the previously repaired hosted controls.
# A proof key includes the assertion text or the complete control/mutant body;
# foreach inventories retain every dynamic case as well as the assertions.
function Get-R3SplitProofs([string]$Source,[ValidateSet('ordinary','native')][string]$Kind,[switch]$Baseline) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source.Replace("`r`n","`n"),[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'r3 split proof source parse failed'
  $scope=if($Kind -ceq 'ordinary'){
    @($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "`$Carrier -ceq 'ordinary-dispatch'"},$true))[0].Clauses[0].Item2
  }else{
    @($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-7962NativeControls'},$true))[0].Body.EndBlock
  }
  Assert-Ci ($null -ne $scope) 'r3 split proof scope missing'
  $entries=[Collections.Generic.List[object]]::new()
  $owner=''
  foreach($statement in $scope.Statements){
    if($statement -is [Management.Automation.Language.FunctionDefinitionAst]){continue}
    $text=$statement.Extent.Text
    if($Baseline){
      if($Kind -ceq 'ordinary'){
        if($text.StartsWith("`$f=Fixture9334 'dispatch'")){$owner='ordinary-admission'}
        if($text.StartsWith("`$stateMutant=Mutant9334")){$owner='ordinary-state'}
        if($text.StartsWith("`$sourceMutant=Mutant9334")){$owner='ordinary-sources'}
        if($text.StartsWith("`$replayMutant=Mutant9334")){$owner='ordinary-historical'}
        if($text.StartsWith('ValidPlan9334 $f ''original ordinary')){
          $owner='ordinary-sources'
        }
        if($text.StartsWith('$entryState=Get-InterruptedIntegrationState')){$owner='ordinary-publication'}
        if($text.StartsWith("foreach(`$violation in")){$owner='ordinary-scope'}
        if($text.StartsWith("`$unpublished=Fixture9334")){$owner='ordinary-publication-refusals'}
      }else{
        if($text.StartsWith("Control 'baseline-late-head-and-Terra'")){$owner='three-native-source'}
        if($text.StartsWith("foreach(`$field in")){$owner='three-native-boundaries'}
        if($text.StartsWith("Control 'retained-exited0-parameter-stop-double-replay'")){$owner='three-native-retained'}
        if($text.StartsWith("Control 'native-probe-exit-candidate-and-bypass'")){$owner='three-native-boundaries'}
        if($text.StartsWith("Control 'fresh-v3-request-reader-and-unavailable-executable'")){$owner='three-native-watchdog'}
      }
    }else{
      $owner=''
      if($statement -is [Management.Automation.Language.IfStatementAst] -and
        $statement.Clauses[0].Item1.Extent.Text -cmatch '^\-not \$Part -or \$Part -ceq ''([^'']+)''$'){
        $owner=$Matches[1]
      }
    }
    foreach($node in $statement.FindAll({param($n)
      ($n -is [Management.Automation.Language.CommandAst] -and
        ($n.GetCommandName() -cin @('Proof9334','Check','Control','ValidPlan9334','Refusal9334','Discriminator9334','Mutant9334','New-Subject'))) -or
      $n -is [Management.Automation.Language.ForEachStatementAst]
    },$true)){
      $key=if($node -is [Management.Automation.Language.ForEachStatementAst]){'cases:'+$node.Condition.Extent.Text}else{$node.GetCommandName()+':'+$node.Extent.Text}
      $entries.Add([pscustomobject]@{key=$key;owner=$owner})
    }
  }
  return $entries.ToArray()
}
function Assert-R3SplitProofs([string]$Source,[string]$Baseline,[string]$Kind,[string[]]$Parts) {
  $expected=@(Get-R3SplitProofs $Baseline $Kind -Baseline)
  $actual=@(Get-R3SplitProofs $Source $Kind)
  Assert-Ci ($expected.Count -gt 0 -and $actual.Count -eq $expected.Count) "r3 $Kind assertion/control/mutant/case cardinality changed"
  $counts=@{}
  foreach($entry in $expected){
    Assert-Ci ($entry.owner -cin $Parts) "r3 $Kind baseline proof unowned: $($entry.key)"
    $key=$entry.owner+':'+$entry.key;$counts[$key]++
  }
  foreach($entry in $actual){
    $key=$entry.owner+':'+$entry.key
    Assert-Ci ($entry.owner -cin $Parts -and $counts[$key] -gt 0) "r3 $Kind assertion/control/mutant/case unowned, duplicated or misowned: $($entry.key)"
    $counts[$key]--
  }
  Assert-Ci (@($counts.Values|Where-Object{$_ -ne 0}).Count -eq 0) "r3 $Kind proof lost"
  foreach($part in $Parts){Assert-Ci (@($actual|Where-Object owner -ceq $part).Count -gt 0) "r3 empty part: $part"}
  return $actual.Count
}
$r3SplitBlobs=@{ordinary='20019bb182df52486ec46f0aa364f7ca895a57cf';native='bf82671ac0325f81047ef6575b946a87512ca11e'}
foreach($kind in @('ordinary','native')){
  $leaf=if($kind -ceq 'ordinary'){'interrupted-integration-test-support.ps1'}else{'integration-dispatch-test-support.ps1'}
  $before=ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',$r3SplitBlobs[$kind]))
  $after=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $leaf)).Replace("`r`n","`n")
  $parts=@($r3Item.parts.name|Where-Object{if($kind -ceq 'ordinary'){$_ -clike 'ordinary-*'}else{$_ -clike 'three-native-*'}})
  $count=Assert-R3SplitProofs $after $before $kind $parts
  $commandName=if($kind -ceq 'ordinary'){'Proof9334'}else{'Control'}
  $proof=@(Get-R3SplitProofs $after $kind|Where-Object key -clike ($commandName+':*'))[0].key.Substring($commandName.Length+1)
  Refuses-Coverage { Assert-R3SplitProofs ($after.Replace($proof,'Write-Output ''removed proof''')) $before $kind $parts }
  Refuses-Coverage { Assert-R3SplitProofs ($after.Replace($proof,$proof+"`n"+$proof)) $before $kind $parts }
  $guard="-not `$Part -or `$Part -ceq '$($parts[0])'"
  Assert-Ci ($after.Contains($guard)) 'r3 unowned mutant guard missing'
  Refuses-Coverage { Assert-R3SplitProofs ($after.Replace($guard,'$true')) $before $kind $parts }
  Refuses-Coverage { Assert-R3SplitProofs ($after.Replace($guard,"-not `$Part -or `$Part -ceq '$($parts[1])'")) $before $kind $parts }
  Write-Output "PASS r3 $kind exact proof ownership: $count assertion/control/mutant/case keys; dropped, duplicated, unowned and misowned negatives refused"
}
# The fixture manifest check runs inside this existing timed identity rather than
# as a new required hosted identity: a new identity has no duration record, and
# enforced candidate plans refuse fallback estimates.
$fixtureCheck=Join-Path $PSScriptRoot 'historical-fixture-manifest.check.ps1'
Assert-Ci (Test-Path -LiteralPath $fixtureCheck -PathType Leaf) 'historical fixture manifest check missing'
$fixtureOutput=@(& (Get-Process -Id $PID).Path -NoProfile -File $fixtureCheck 2>&1)
Assert-Ci ($LASTEXITCODE -eq 0 -and (@($fixtureOutput | Where-Object { "$_" -clike 'PASS historical fixture manifest validation:*' }).Count -eq 1)) "historical fixture manifest check failed: $(($fixtureOutput | Select-Object -Last 3) -join ' | ')"
Write-Output 'PASS historical fixture manifests: delegated check passed inside check:controller-ci-coverage'
function Get-CarrierProofCensus([string]$Source){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source.Replace("`r`n","`n"),[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count -eq 0) 'historical carrier proof source parse failed'
  # AC2 replaces the wall-clock carrier timeout with a terminal process wait
  # followed by both redirected-stream EOF waits. Keep these member calls in
  # the baseline census even though they are not predicates themselves.
  $terminalBoundCalls=@('$p.WaitForExit()','$out.GetAwaiter().GetResult()','$err.GetAwaiter().GetResult()','$Holder.child.WaitForExit()')
  $keys=@{}
  foreach($node in $ast.FindAll({param($n)
    ($n -is [Management.Automation.Language.CommandAst] -and ($n.GetCommandName() -clike 'Assert-*' -or $n.GetCommandName() -clike 'Proof*')) -or
    $n -is [Management.Automation.Language.ThrowStatementAst] -or $n -is [Management.Automation.Language.HashtableAst] -or
    $n -is [Management.Automation.Language.BinaryExpressionAst] -or $n -is [Management.Automation.Language.UnaryExpressionAst] -or
    ($n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $terminalBoundCalls -contains $n.Extent.Text)
  },$true)){
    $key=$node.GetType().Name+':'+$node.Extent.Text
    if($node -is [Management.Automation.Language.InvokeMemberExpressionAst]){
      $owner=$node.Parent
      while($owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
      Assert-Ci ($null -ne $owner) 'historical carrier terminal wait has no function owner'
      $key=$owner.Name+'/'+$key
    }
    $keys[$key]=1+[int]$keys[$key]
  }
  return $keys
}
$carrierPredicateReplacements=@{
  # AC2 intentionally removes the bounded WaitForExit($TimeoutSeconds*1000)
  # predicate. Its replacement is the exact producer terminal state: process
  # exit plus both redirected streams reaching EOF.
  'BinaryExpressionAst:$TimeoutSeconds*1000'=@(
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$p.WaitForExit()'
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$out.GetAwaiter().GetResult()'
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$err.GetAwaiter().GetResult()'
  )
  'UnaryExpressionAst:-not$p.WaitForExit($TimeoutSeconds*1000)'=@(
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$p.WaitForExit()'
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$out.GetAwaiter().GetResult()'
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$err.GetAwaiter().GetResult()'
  )
  'ThrowStatementAst:throw "8102 carrier copy $($Copy.label)/$Carrier exceeded $TimeoutSeconds s"'=@(
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$p.WaitForExit()'
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$out.GetAwaiter().GetResult()'
    'Invoke-8102CarrierCopy/InvokeMemberExpressionAst:$err.GetAwaiter().GetResult()'
  )
  # AC2 also removes the five-second owned-holder bound. Cleanup now waits for
  # the owned child and only uses HasExited to decide whether an owned kill is
  # still required after a signal/cleanup failure.
  'UnaryExpressionAst:-not$Holder.child.WaitForExit(5000)'=@(
    'UnaryExpressionAst:-not$Holder.child.HasExited'
    'Stop-SyntheticFleetHolder/InvokeMemberExpressionAst:$Holder.child.WaitForExit()'
    'BinaryExpressionAst:$Holder.child.StartTime.ToUniversalTime().ToString(''o'')-cne$Holder.owner.childProcessStartUtc'
  )
}
function Assert-CarrierProofCensus([string]$Source,[string]$Baseline){
  $before=Get-CarrierProofCensus $Baseline;$after=Get-CarrierProofCensus $Source
  foreach($key in $before.Keys){
    if([int]$after[$key] -ge $before[$key]){continue}
    if($carrierPredicateReplacements.ContainsKey($key)){
      foreach($replacement in $carrierPredicateReplacements[$key]){
        Assert-Ci ([int]$after[$replacement] -ge 1) "historical carrier AC2 replacement predicate/mutant lost: $key -> $replacement"
      }
      continue
    }
    Assert-Ci $false "historical carrier baseline predicate/assertion/mutant lost: $key"
  }
  $tokens=$null;$errors=$null
  $beforeAst=[Management.Automation.Language.Parser]::ParseInput($Baseline,[ref]$tokens,[ref]$errors)
  $afterAst=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  if($beforeAst.ParamBlock){
    for($i=0;$i-lt$beforeAst.ParamBlock.Parameters.Count;$i++){
      Assert-Ci ($beforeAst.ParamBlock.Parameters[$i].Extent.Text -ceq $afterAst.ParamBlock.Parameters[$i].Extent.Text) 'historical carrier legacy parameter/default/order changed'
    }
  }
}
function Assert-CarrierOwnerMap([object[]]$Entries,$Expected,[string[]]$Parts){
  Assert-Ci ($Entries.Count -eq $Expected.Count) 'historical suite owner map cardinality changed'
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($entry in $Entries){
    Assert-Ci ($seen.Add([string]$entry.Key) -and $Expected.Contains($entry.Key) -and
      $entry.Value -ceq $Expected[$entry.Key] -and $entry.Value -cin $Parts) "historical suite proof key missing/duplicated/misowned: $($entry.Key)"
  }
}
$nativeSplitBaseline=ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',$r3SplitBlobs.native))
$nativeSplitSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'integration-dispatch-test-support.ps1'))
Assert-CarrierProofCensus $nativeSplitSource $nativeSplitBaseline
Refuses-Coverage { Assert-CarrierProofCensus ($nativeSplitSource.Replace("throw 'synthetic authority/request/call witnesses missing'",'Write-Output ''removed witness guard''')) $nativeSplitBaseline }
Write-Output 'PASS r3 native full-source conservation: shared fixture/helper/witness assertions, predicates and mutant tables retained; removed witness guard refused'
# These blobs are the issue's dispatch baseline, not private product history.
# Keep the older six-suite conservation base above unchanged.
# The watchdog baseline includes the reviewed AC5 host-hold cases from facc7e7.
# #237 moves it to the no-escalation baseline: quota/session raises removed and
# the watchdog-no-escalation part added. Its repair adds the bound-launch
# replay regressions (acknowledged and reserved relaunches across pool changes).
$carrierBaselineBlobs=@{
  'rebase-integration.test.ps1'='0a3350f8a51a32c1b9ee16447c1e6829f10a41c1'
  'lane-stall-watchdog.test.ps1'='fd0d28b18f1d5af3d17d6ee34442744696cb59e3'
  'interrupted-integration-test-support.ps1'='371e2aa2dcbdeb34b5568878c96811eea4ba99b1'
}
$carrierOwnerCounts=@{
  rebase=@{'rebase-foundation'=23;'rebase-historical'=1;'rebase-ordinary-live'=1;'rebase-ordinary-retry'=1;'rebase-successor'=1;'rebase-publication'=1;'rebase-amend'=1}
  watchdog=@{'watchdog-foundation'=166;'watchdog-capacity'=5;'watchdog-historical'=1;'watchdog-ordinary'=1;'watchdog-successor'=1;'watchdog-no-escalation'=25
    'watchdog-host-hold-cases'=52;'watchdog-host-hold-mutants'=12
    'watchdog-policy-ac'=12;'watchdog-policy-protected'=1;'watchdog-policy-consumed'=2;'watchdog-policy-unlinked'=6
    'watchdog-policy-authentication'=32;'watchdog-policy-scalars'=13;'watchdog-policy-joins'=7;'watchdog-policy-legacy'=1
    'watchdog-policy-pos'=12;'watchdog-policy-mutants-admission'=8;'watchdog-policy-mutants-lineage'=4
    'watchdog-policy-mutants-envelope'=4;'watchdog-policy-mutants-history'=4;'watchdog-policy-mutants-binding'=9;'watchdog-policy-mutants-joins'=6}
}
function Assert-NativeFailureDiagnostics([string]$Source) {
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseInput($Source,[ref]$tokens,[ref]$errors)
  Assert-Ci ($errors.Count-eq0) 'native failure diagnostics source parse failed'
  $diagnostic=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.IfStatementAst]-and$n.Extent.Text.Contains('NATIVE_FAILURE_CONTEXT')},$true))
  Assert-Ci ($diagnostic.Count-eq1) 'native failure diagnostics missing or duplicated'
  $helpers=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Protect-NativeFailureContext'},$true))
  Assert-Ci ($helpers.Count-eq1) 'native failure context redaction helper missing or duplicated'
  . ([scriptblock]::Create($helpers[0].Extent.Text))
  $catch=$diagnostic[0].Parent
  while($catch-and$catch-isnot[Management.Automation.Language.CatchClauseAst]){$catch=$catch.Parent}
  Assert-Ci ($null-ne$catch) 'native failure diagnostics must be failure-only'
  $propagate=[scriptblock]::Create("try { throw 'synthetic original native failure' } catch { "+$catch.Body.Extent.Text.TrimStart('{').TrimEnd('}')+' }')
  $previous=$script:ordinary9334LastResult;$previousError=[Console]::Error;$previousExit=$LASTEXITCODE
  $capture=[IO.StringWriter]::new()
  $childErrorPath=Join-Path ([IO.Path]::GetTempPath()) ('r3-native-diagnostic-'+[guid]::NewGuid().ToString('N')+'.err.log')
  try {
    $Carrier='synthetic-diagnostic'
    $markers=@('synthetic-bearer-never-valid','synthetic-password-never-valid','synthetic-token-never-valid')
    $credentials="Authorization: Bearer $($markers[0])`npassword=$($markers[1])`n{`"token`":`"$($markers[2])`"}"
    $childError=$credentials+('x'*16384)
    [IO.File]::WriteAllText($childErrorPath,$childError)
    $script:ordinary9334LastResult=[pscustomobject]@{exit=19;stdout=$childError;stderr=$credentials;resultPath=$credentials;childStderrPath=$childErrorPath;unexpectedSecret=$credentials}
    $LASTEXITCODE=19
    [Console]::SetError($capture)
    $failure=$null;try{& $propagate|Out-Null}catch{$failure=$_.Exception.Message}
    Assert-Ci ($failure-ceq'synthetic original native failure'-and$LASTEXITCODE-eq19) 'native diagnostic changed original throw or exit code'
    $prefix='NATIVE_FAILURE_CONTEXT '
    $line=$capture.ToString().TrimEnd("`r","`n")
    Assert-Ci ($line.StartsWith($prefix,[StringComparison]::Ordinal)) 'native failure context prefix missing'
    Assert-Ci ($line.Length-le($prefix.Length+2048)) 'native failure context exceeds emitted size bound'
    foreach($marker in $markers){Assert-Ci (-not$line.Contains($marker)) 'native failure context leaked synthetic credential'}
    $retained=$line.Substring($prefix.Length)|ConvertFrom-Json
    Assert-Ci ($retained.exit-eq19-and$retained.stdout-ceq'[redacted]'-and$retained.stderr-ceq'[redacted]'-and$retained.resultPath-ceq'[redacted]') 'native failure context lost exit or redaction boundary'
    Assert-Ci ($retained.stdoutChars-eq$childError.Length-and$retained.stderrChars-eq$credentials.Length-and$retained.childStderr-ceq'[redacted]'-and$retained.childStderrBytes-eq([IO.FileInfo]$childErrorPath).Length-and$null-eq$retained.childStdout) 'native failure context lost stream lengths or invented absent output'
    Assert-Ci ($null-eq$retained.PSObject.Properties['unexpectedSecret']) 'native failure context copied unowned native fields'
    [void]$capture.GetStringBuilder().Clear()
    & {
      function Protect-NativeFailureContext { throw 'synthetic redaction failure' }
      $failure=$null;try{& $propagate|Out-Null}catch{$failure=$_.Exception.Message}
      Assert-Ci ($failure-ceq'synthetic original native failure'-and$LASTEXITCODE-eq19) 'redaction failure replaced original throw or exit code'
    }
    Assert-Ci ($capture.ToString().Trim()-ceq'NATIVE_FAILURE_CONTEXT_UNAVAILABLE') 'redaction failure did not fail closed'
    [void]$capture.GetStringBuilder().Clear();$script:ordinary9334LastResult=$null
    & ([scriptblock]::Create($diagnostic[0].Extent.Text))
    Assert-Ci ($capture.ToString()-ceq'') 'native failure context must stay silent without a native result'
  } finally {
    [Console]::SetError($previousError);$capture.Dispose();$script:ordinary9334LastResult=$previous;$LASTEXITCODE=$previousExit
    [IO.File]::Delete($childErrorPath)
  }
}
foreach($leaf in $carrierBaselineBlobs.Keys){
  $baseline=ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',$carrierBaselineBlobs[$leaf]))
  $candidate=[IO.File]::ReadAllText((Join-Path $PSScriptRoot $leaf))
  if($leaf-ceq'interrupted-integration-test-support.ps1'){
    Assert-NativeFailureDiagnostics $candidate
    Refuses-Coverage { Assert-NativeFailureDiagnostics ($candidate.Replace('NATIVE_FAILURE_CONTEXT','REMOVED_NATIVE_CONTEXT')) }
    Refuses-Coverage { Assert-NativeFailureDiagnostics ($candidate.Replace("`$safe[`$stream]='[redacted]'",' $safe[$stream]=$Result.$stream')) }
    Refuses-Coverage { Assert-NativeFailureDiagnostics ($candidate.Replace('    throw'+"`r`n"+'  } finally {','    return'+"`r`n"+'  } finally {').Replace('    throw'+"`n"+'  } finally {','    return'+"`n"+'  } finally {')) }
    Write-Output 'PASS native failure diagnostics: bounded closed fields redact bearer/password/token content and unknown fields; original exit/throw retained even if redaction fails; unredacted-stream and swallowed-throw negatives refused'
  }
  Assert-CarrierProofCensus $candidate $baseline
  if($leaf -cne 'interrupted-integration-test-support.ps1'){
    $suite=if($leaf -ceq 'rebase-integration.test.ps1'){'rebase'}else{'watchdog'}
    $expectedOwners=Get-HistoricalSuitePartOwners $suite $baseline
    $owners=Get-HistoricalSuitePartOwners $suite $candidate
    $entries=@($owners.GetEnumerator())
    $parts=Get-SuiteExpectedParts (Join-Path $PSScriptRoot $leaf)
    Assert-CarrierOwnerMap $entries $expectedOwners $parts
    Assert-Ci ($carrierOwnerCounts[$suite].Count -eq $parts.Count) 'historical suite has an unowned part'
    foreach($part in $parts){Assert-Ci (@($entries|Where-Object Value -ceq $part).Count -eq $carrierOwnerCounts[$suite][$part]) "historical suite owner census changed: $part"}
    Refuses-Coverage { Assert-CarrierOwnerMap $entries[1..($entries.Count-1)] $expectedOwners $parts }
    Refuses-Coverage { Assert-CarrierOwnerMap (@($entries[0])+@($entries[0])+@($entries[2..($entries.Count-1)])) $expectedOwners $parts }
    if($suite -ceq 'watchdog'){Assert-Ci (@($entries|Where-Object Key -clike 'mutant:*').Count -eq 42) 'watchdog policy and host-hold mutant ownership census changed'}
    Write-Output "PASS $suite SuitePartOwners: keys=$($owners.Count); baseline ownership retained; dropped-key and duplicated-key mutants refused"
  }
  $needle=if($leaf -ceq 'interrupted-integration-test-support.ps1'){"Proof9334 (`$live.seed.exit-eq0-and(Test-Path -LiteralPath `$live.capturePath))"}else{'Assert-True '}
  Assert-Ci ($candidate.Contains($needle)) "carrier dropped-proof mutant anchor missing: $leaf"
  Refuses-Coverage { Assert-CarrierProofCensus ($candidate.Replace($needle,'REMOVED-PROOF ')) $baseline }
  if($leaf -ceq 'interrupted-integration-test-support.ps1'){
    foreach($key in @($carrierPredicateReplacements.Values|ForEach-Object{$_}|Sort-Object -Unique)){
      $extent=$key.Substring($key.IndexOf(':')+1)
      Assert-Ci ($candidate.Contains($extent)) "carrier AC2 replacement predicate anchor missing: $extent"
      Refuses-Coverage { Assert-CarrierProofCensus ($candidate.Replace($extent,'$null')) $baseline }
    }
    Write-Output 'PASS AC2 historical bound replacements: exact function-owned process/EOF waits and owned-holder terminal cleanup retained; dropped replacement-key mutants refused'
  }
}
Write-Output 'PASS historical carrier baseline blobs: assertion/throw, predicate and mutant-table multisets retained in both suites and support; dropped-proof mutants refused'
function Assert-BoardSplitContract([string]$Source){
  Assert-Ci ($Source.Contains("param([ValidateSet('all','candidate','baseline','issue-scan','no-linkage','ten-item','ten-item-scan')][string]`$Arm = 'all')")) 'board selector census changed'
  Assert-Ci ($Source.Contains("`$arms = if (`$Arm -eq 'all') { @('candidate','baseline','issue-scan','no-linkage','ten-item') } else { @(`$Arm) }")) 'legacy board all-arm order changed'
  Assert-Ci ($Source.Contains("Invoke-BoardScaleArm `$f `$(if (`$name -eq 'ten-item') { 'candidate' } else { `$name })")) 'ten-item candidate verdict dropped'
  Assert-Ci ($Source.Contains("if (`$name -eq 'ten-item' -and `$Arm -eq 'all')")) 'ten-item scan was merged into explicit candidate part'
  Assert-Ci ($Source.Contains("if (`$name -eq 'ten-item-scan')")) 'ten-item-scan part dropped'
  Assert-Ci ($Source.Contains("`$scan = New-BoardScaleFixture (Join-Path `$root 'ten-item-scan') 10")) 'ten-item-scan fixture dropped'
  Assert-Ci ($Source.Contains("Invoke-BoardScaleArm `$scan 'ten-item-scan'")) 'ten-item-scan verdict dropped'
  Assert-Ci ($Source.Contains("Write-Output 'CONTROL ten-item issue scan is non-discriminating'")) 'ten-item scan control dropped'
}
function Assert-BoardPartNames($Names){
  $expected=@('candidate','baseline','issue-scan','no-linkage','ten-item','ten-item-scan')
  $actualText=(@($Names|Sort-Object)-join',')
  $expectedText=(@($expected|Sort-Object)-join',')
  Assert-Ci ($actualText-ceq$expectedText) 'board part census changed'
}
function Assert-CleanupPartNames($Names){
  $expected=@('proof','scale')
  Assert-Ci ((@($Names|Sort-Object)-join',')-ceq(@($expected|Sort-Object)-join',')) 'cleanup part census changed'
}
function Assert-CleanupSplitContract([string]$Source){
  Assert-Ci ($Source.Contains("[ValidateSet('proof','scale')][string]`$Part=''")) 'cleanup selector census changed'
  Assert-Ci ($Source.Contains("if(-not`$Part -or `$Part -eq 'proof')")) 'cleanup proof part dropped'
  Assert-Ci ($Source.Contains("if(-not`$Part -or `$Part -eq 'scale')")) 'cleanup scale part dropped'
  Assert-Ci ($Source.Contains('for($tree=0;$tree-lt200;$tree++)')) 'cleanup fixture tree count changed'
  Assert-Ci ($Source.Contains('for($file=0;$file-lt2000;$file++)')) 'cleanup fixture file count changed'
  Assert-Ci ($Source.Contains('Elapsed.TotalMinutes-ge12')) 'cleanup construction bound changed'
  Assert-Ci ($Source.Contains('wall.TotalSeconds-lt60')) 'cleanup report bound changed'
  Assert-Ci ($Source.Contains('phaseTimings.total-lt300000')) 'cleanup total bound changed'
  Assert-Ci ($Source.Contains('}finally{')) 'cleanup synchronous teardown dropped'
}
$boardPath=Join-Path $PSScriptRoot 'board-hourly-scale.test.ps1'
$boardText=[IO.File]::ReadAllText($boardPath).Replace("`r`n","`n")
$boardItem=$manifest.items|Where-Object identity -eq 'test:board-hourly-scale.test.ps1'
Assert-BoardPartNames @($boardItem.parts.name)
Assert-BoardSplitContract $boardText
Refuses-Coverage { Assert-BoardPartNames @($boardItem.parts.name|Where-Object{$_-ne'ten-item-scan'}) }
Refuses-Coverage { Assert-BoardPartNames @($boardItem.parts.name|Where-Object{$_-ne'ten-item'}) }
Refuses-Coverage { Assert-BoardSplitContract ($boardText.Replace("if (`$name -eq 'ten-item' -and `$Arm -eq 'all')","if (`$name -eq 'ten-item')")) }
Refuses-Coverage { Assert-BoardSplitContract ($boardText.Replace("Invoke-BoardScaleArm `$f `$(if (`$name -eq 'ten-item') { 'candidate' } else { `$name })",'')) }
$cleanupPath=Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.test.ps1'
$cleanupText=[IO.File]::ReadAllText($cleanupPath).Replace("`r`n","`n")
$cleanupItem=$manifest.items|Where-Object identity -eq 'test:cleanup-orphan-worktree-dirs.test.ps1'
Assert-CleanupPartNames @($cleanupItem.parts.name)
Assert-CleanupSplitContract $cleanupText
Refuses-Coverage { Assert-CleanupPartNames @($cleanupItem.parts.name|Where-Object{$_-ne'proof'}) }
Refuses-Coverage { Assert-CleanupPartNames @($cleanupItem.parts.name|Where-Object{$_-ne'scale'}) }
Refuses-Coverage { Assert-CleanupSplitContract ($cleanupText.Replace("if(-not`$Part -or `$Part -eq 'scale')",'')) }
$routing=Get-SuiteRoutingNames (ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',"${BaselineHead}:.orchestrator/dispatch-routing-data.test.ps1")))
Assert-Ci ($routing.cases.Count-eq18-and$routing.mutants.Count-eq8-and$routing.capacityMutants.Count-eq36) 'baseline routing census drift'
$path=Join-Path $PSScriptRoot 'dispatch-routing-data.test.ps1'
$text=[IO.File]::ReadAllText($path).Replace("`r`n","`n")
Refuses-Coverage {Assert-Conservation $manifest @{'dispatch-routing-data.test.ps1'=$text.Replace('Invoke-Case $name','') }}
Refuses-Coverage {Assert-Conservation $manifest @{'dispatch-routing-data.test.ps1'=$text.Replace('Invoke-Case $name','Invoke-Case $name;Invoke-Case $name') }}
Refuses-Coverage {Assert-Conservation $manifest @{'dispatch-routing-data.test.ps1'=$text.Replace('"case-$name"','"routing-mutant-$name"') }}
Refuses-Coverage {Assert-Conservation $manifest @{'dispatch-routing-data.test.ps1'=$text.Replace('$exit-eq1-and','$exit-ne1-and') }}
$savedRetirements=$conservationRetirements
$conservationRetirements=@{}; Refuses-Coverage {Assert-Conservation $manifest}
$conservationRetirements=@{'dispatch-routing-data.test.ps1'=@($savedRetirements['dispatch-routing-data.test.ps1'])+@('CommandAst:Plan ($astra+@{Row=8})')}; Refuses-Coverage {Assert-Conservation $manifest}
$conservationRetirements=$savedRetirements
if($EvidenceDirectory){Write-CiJson @{baselineHead=$BaselineHead;baselineBlobs=$pins;routing=$routing;parts=@($manifest.items|Select-Object identity,ownership)
  repeatedWitnesses='Mutant children run their original -Case without -Part. Landed per-part synthetic-witness checks cover each disjoint retained fixture set; setup and unchanged summary lines may repeat.'} (Join-Path $EvidenceDirectory 'source-coverage.json')}
Write-Output 'PASS source conservation: pinned full blobs, 18 routing cases, 8 routing mutants, 36 capacity mutants, six board parts with required ten-item split, unchanged board/cleanup proof; dropped/duplicate/misowned/changed-predicate and missing/unused-retirement controls refused'

$splitInventory=@($manifest.items|ForEach-Object{[pscustomobject]@{
  identity=$_.identity;path=('.orchestrator/'+$_.identity.Substring(5));command='synthetic';arguments=@();restriction=$null}})
$expectedIdentities=@($manifest.items|ForEach-Object{
  $requiredIdentity=$_.identity;foreach($part in $_.parts){"$requiredIdentity#$($part.name)"}
}|Sort-Object)
foreach($count in 16..48){
  Assert-Ci ((Get-CiShardCount @{shardCount=$count})-eq$count) 'supported coverage shard count refused'
  $splitTasks=New-CiAssignments $splitInventory '' $manifest -ShardCount $count
  Assert-Ci ((@($splitTasks.identity|Sort-Object)-join',')-ceq($expectedIdentities-join',')) 'shard count changed execution identity coverage'
  Assert-Ci (@($splitTasks|Where-Object{$_.shard-lt0-or$_.shard-ge$count}).Count-eq0) 'part assigned outside supported shard range'
}
foreach($badCount in @(15,49)){
  Refuses-Coverage {Get-CiShardCount @{shardCount=$badCount}}
  Refuses-Coverage {New-CiAssignments $splitInventory '' $manifest -ShardCount $badCount}
}
Write-Output 'PASS full manifest execution coverage preserved at every shard count 16..48; 15/49 refused'
