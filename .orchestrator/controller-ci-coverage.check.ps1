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
    $available=@{}
    foreach($node in $after.FindAll($predicate,$true)){$key=$node.GetType().Name+':'+$node.Extent.Text;$available[$key]++}
    foreach($node in $before.FindAll($predicate,$true)){
      $key=$node.GetType().Name+':'+$node.Extent.Text
      Assert-Ci ($available[$key]-gt0) "baseline command/predicate/mutant table lost: $leaf $key"
      $available[$key]--
    }
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
  $expectedMappings=@('test:dispatch-lane.test.ps1','test:dispatch-routing-data.test.ps1','test:board-hourly-scale.test.ps1','test:landed-integration-dispatch.test.ps1','test:invoke-heavy-verifier.test.ps1','test:cleanup-orphan-worktree-dirs.test.ps1')
  Assert-Ci (@($Manifest.items).Count-eq6-and@($expectedMappings|Where-Object{$_-cnotin@($Manifest.items.identity)}).Count-eq0) 'missing/extra proof ownership'
  $inventory=@($Manifest.items|ForEach-Object{[pscustomobject]@{identity=$_.identity;path=('.orchestrator/'+$_.identity.Substring(5));restriction=$null}})
  Assert-CiManifest $inventory $Manifest $root
}
Assert-Conservation $manifest
function Refuses-Coverage([scriptblock]$Body){$refused=$false;try{&$Body}catch{$refused=$true};Assert-Ci $refused 'coverage bypass survived'}

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
Assert-Ci ((@($dispatchItem.parts.name|Sort-Object)-join ',') -ceq (@($dispatchExpected|Sort-Object)-join ',')) 'dispatch-lane part census changed'
$dispatchBaseline=(ConvertFrom-CiUtf8 (Read-CiGitBytes $root @('cat-file','blob',"${BaselineHead}:.orchestrator/dispatch-lane.test.ps1"))).Replace("`r`n","`n")
$baselineKeys=Get-DispatchCoverageKeys $dispatchBaseline
$candidateKeys=Get-DispatchCoverageKeys $dispatchSource
foreach($key in $baselineKeys){Assert-Ci ($candidateKeys -contains $key) "dispatch-lane baseline proof key lost: $key"}
foreach($partName in $dispatchExpected){
  Assert-Ci ($dispatchSource.Contains("'$partName'")) "dispatch source selector missing: $partName"
  Refuses-Coverage {
    $remaining=@($dispatchItem.parts.name|Where-Object{$_ -ne $partName})
    Assert-Ci ((@($remaining|Sort-Object)-join ',') -eq (@($dispatchExpected|Sort-Object)-join ',')) "dispatch part dropped: $partName"
  }
}
Refuses-Coverage { Assert-Ci ((@($dispatchItem.parts.name)+@('dispatch-incident-b-route-baseline')).Count -eq @($dispatchExpected).Count) 'dispatch part merged/duplicated' }
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
# Whole-run (no -Part / -Part all) dispatch-lane keeps the base carrier shape:
# the 8102 test owns both literal dispatch carrier calls, guarded by the
# whole-run selector with a DEFERRED single-part branch, and the base top-level
# sequence. Single parts call carriers only through Invoke-7963ResumeCarriers
# (MEASURED_LOAD -> exit 75), never Test-7963ResumeCarrier directly.
function Test-DispatchAstWithin($Node,$Container){ $Container.Extent.StartOffset -le $Node.Extent.StartOffset -and $Node.Extent.EndOffset -le $Container.Extent.EndOffset }
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
if($EvidenceDirectory){Write-CiJson @{baselineHead=$BaselineHead;baselineBlobs=$pins;routing=$routing;parts=@($manifest.items|Select-Object identity,ownership)
  repeatedWitnesses='Mutant children run their original -Case without -Part. Landed per-part synthetic-witness checks cover each disjoint retained fixture set; setup and unchanged summary lines may repeat.'} (Join-Path $EvidenceDirectory 'source-coverage.json')}
Write-Output 'PASS source conservation: pinned full blobs, 18 routing cases, 8 routing mutants, 36 capacity mutants, six board parts with required ten-item split, unchanged board/cleanup proof; dropped/duplicate/misowned/changed-predicate controls refused'
