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
  $expectedMappings=@('test:dispatch-routing-data.test.ps1','test:board-hourly-scale.test.ps1','test:landed-integration-dispatch.test.ps1','test:invoke-heavy-verifier.test.ps1','test:cleanup-orphan-worktree-dirs.test.ps1')
  Assert-Ci (@($Manifest.items).Count-eq5-and@($expectedMappings|Where-Object{$_-cnotin@($Manifest.items.identity)}).Count-eq0) 'missing/extra proof ownership'
  $inventory=@($Manifest.items|ForEach-Object{[pscustomobject]@{identity=$_.identity;path=('.orchestrator/'+$_.identity.Substring(5));restriction=$null}})
  Assert-CiManifest $inventory $Manifest $root
}
Assert-Conservation $manifest
function Refuses-Coverage([scriptblock]$Body){$refused=$false;try{&$Body}catch{$refused=$true};Assert-Ci $refused 'coverage bypass survived'}
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
