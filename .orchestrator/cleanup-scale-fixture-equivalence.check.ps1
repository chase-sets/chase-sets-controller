[CmdletBinding()]param(
  [string]$BaselineHead='321915d57da6fbaf647a30080c90601470c2b2cb',
  [string]$RetainedHead='fbe07b88721405081b3409741f4969793b52601e',
  [string]$EvidenceDirectory=(Join-Path ([IO.Path]::GetTempPath()) 'cleanup-scale-proof'),
  [ValidateSet('all','static','teardown','fixture','fixture-baseline','fixture-candidate','fixture-controls','fixture-authority','fixture-teardown')][string]$Phase='all',
  # Resume a fixture run in bounded steps: baseline, candidate, controls, authority, teardown.
  [string]$RunDirectory=''
)
# #9275: independent proof that the cleanup scale fixture construction and
# synchronous teardown mechanics are equivalent to the immutable pre-change
# baseline. It replaces only the "mechanics source equals baseline" premise:
# everything outside the two mechanics regions must still be byte-identical,
# the assertion/PASS/mutant union must be exact, and the mechanics regions are
# judged by what the baseline blob itself builds and removes, never by
# expected values derived from the candidate. Not a battery item.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$TestPath='.orchestrator/cleanup-orphan-worktree-dirs.test.ps1'
$ProductionPath='.orchestrator/cleanup-orphan-worktree-dirs.ps1'
# Recorded immutable objects (#9275 brief; 9272 scope decision B1).
$Pins=@{
  "321915d57da6fbaf647a30080c90601470c2b2cb:$TestPath"='8610bd4d8a27d269b6f0433db12404ae59403b97'
  "321915d57da6fbaf647a30080c90601470c2b2cb:$ProductionPath"='0f5b469b351c11f7f85fb5553b3d9ab79833c0e4'
  "fbe07b88721405081b3409741f4969793b52601e:$TestPath"='7366f75edb39bd2545a955d4e6ce913420b49afa'
}
$ConstructionStart='  Reset-Synthetic;$script:worktrees=@();$script:branches=@();$dispatchRows=[Collections.Generic.List[string]]::new()'
$ConstructionEnd='  $construction.Stop()'
$BoundThrow="throw 'scale fixture construction exceeded 12 minute safety bound'"
# Inert instrumentation the candidate may add outside the mechanics regions.
$Instrumentation=@('$suiteClock=[Diagnostics.Stopwatch]::StartNew()')
$harness=Join-Path $PSScriptRoot 'cleanup-scale-fixture-harness.ps1'
$pwsh=(Get-Process -Id $PID).Path
$run=if($RunDirectory){[IO.Path]::GetFullPath($RunDirectory)}else{Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))}
[void][IO.Directory]::CreateDirectory($run)
$steps=switch($Phase){'all'{'static','teardown','fixture-baseline','fixture-candidate','fixture-controls','fixture-authority','fixture-teardown'}
  'fixture'{'fixture-baseline','fixture-candidate','fixture-controls','fixture-authority','fixture-teardown'};default{$Phase}}
$results=[ordered]@{baselineHead=$BaselineHead;retainedHead=$RetainedHead;phase=$Phase;controls=[ordered]@{}}

function Stop-Check([string]$Message){throw "CHECK $Message"}
function Get-Normalized([string]$Text){$Text.Replace("`r`n","`n")}
function Get-Lines([string]$Text){$lines=@((Get-Normalized $Text)-split"`n");if($lines.Count-and$lines[-1]-ceq''){$lines=$lines[0..($lines.Count-2)]};,$lines}

# Fail closed unless the head exists, is pinned, resolves to the pinned blob
# and the reconstructed text hashes back to that blob.
function Resolve-PinnedSource([string]$Head,[string]$Path,[string]$Expected=$Pins["${Head}:$Path"]){
  $type=(& git -C $repo cat-file -t $Head 2>$null);if($LASTEXITCODE-ne0-or$type-cne'commit'){Stop-Check "provenance object missing: $Head"}
  if(-not$Expected){Stop-Check "provenance unpinned: ${Head}:$Path"}
  $blob=(& git -C $repo rev-parse "${Head}:$Path" 2>$null);if($LASTEXITCODE-ne0-or$blob-cne$Expected){Stop-Check "provenance blob mismatch: ${Head}:$Path=$blob expected $Expected"}
  $text=((& git -C $repo cat-file blob $blob)-join"`n")+"`n"
  $bytes=[Text.Encoding]::UTF8.GetBytes($text);$header=[Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
  $hash=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header+$bytes))).ToLowerInvariant()
  if($hash-cne$Expected){Stop-Check "provenance reconstruction mismatch: ${Head}:$Path"}
  $text
}
function Get-Ast([string]$Text,[string]$Name){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput((Get-Normalized $Text),[ref]$tokens,[ref]$errors)
  if($errors.Count){Stop-Check "$Name does not parse"};$ast
}
function Get-Commands($Ast,[scriptblock]$Where){
  ,@($Ast.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]},$true)|Where-Object $Where|ForEach-Object{$_.Extent.Text}|Sort-Object -CaseSensitive)
}
function Get-Union([string]$Text,[string]$Name){
  $ast=Get-Ast $Text $Name
  [ordered]@{
    assertions=Get-Commands $ast {$_.GetCommandName()-like'Assert-*'}
    receipts=Get-Commands $ast {$_.GetCommandName()-ceq'Write-Output'-and$_.Extent.Text.Contains('PASS')}
    mutants=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.ForEachStatementAst]-and$n.Variable.VariablePath.UserPath-ceq'mutant'},$true)|ForEach-Object{$_.Condition.Extent.Text})
  }
}
function Get-OnlyIndex([string[]]$Lines,[string]$Line,[string]$Name){
  $hits=@(for($i=0;$i-lt$Lines.Count;$i++){if($Lines[$i]-ceq$Line){$i}})
  if($hits.Count-ne1){Stop-Check "$Name anchor occurs $($hits.Count) times"};$hits[0]
}
function Get-Regions([string]$Text,[string]$Name){
  $lines=Get-Lines $Text
  $start=Get-OnlyIndex $lines $ConstructionStart "$Name construction-start";$end=Get-OnlyIndex $lines $ConstructionEnd "$Name construction-end"
  $finally=Get-OnlyIndex $lines '}finally{' "$Name finally"
  if(-not($start-lt$end-and$end-lt$finally)-or$lines[-1]-cne'}'){Stop-Check "$Name region order"}
  [ordered]@{
    construction=@($lines[$start..$end]);teardown=@($lines[($finally+1)..($lines.Count-2)])
    outside=@($lines[0..($start-1)]+$lines[($end+1)..$finally])
  }
}

# Static proof. Order matters only for which named reason a control reports.
function Test-StaticProof([string]$Baseline,[string]$Candidate,[string]$Retained){
  $base=Get-Union $Baseline 'baseline';$cand=Get-Union $Candidate 'candidate';$kept=Get-Union $Retained 'retained'
  if(($base.assertions-join"`n")-cne($cand.assertions-join"`n")){Stop-Check 'assertion union changed'}
  if(($base.receipts-join"`n")-cne($cand.receipts-join"`n")){Stop-Check 'PASS receipt union changed'}
  if(($base.mutants-join"`n")-cne($cand.mutants-join"`n")){Stop-Check 'mutant inventory changed'}
  $b=Get-Regions $Baseline 'baseline';$c=Get-Regions $Candidate 'candidate';$r=Get-Regions $Retained 'retained'
  $outside=[Collections.Generic.List[string]]::new()
  foreach($line in $c.outside){if($line-cin$Instrumentation){continue};$outside.Add($line)}
  foreach($line in $Instrumentation){if(@($c.outside|Where-Object{$_-ceq$line}).Count-ne1){Stop-Check "instrumentation line not exactly once: $line"}}
  if(($outside-join"`n")-cne($b.outside-join"`n")){Stop-Check 'non-mechanics source changed'}
  $constructionText=$c.construction-join"`n"
  if($constructionText.Contains('Assert-')-or$constructionText.Contains('PASS')){Stop-Check 'construction region asserts or reports'}
  $bound=@($c.construction|Where-Object{$_.Contains($BoundThrow)})
  if($bound.Count-ne1-or-not$bound[0].Contains('Elapsed.TotalMinutes-ge12)')){Stop-Check 'construction bound changed'}
  foreach($line in @($b.teardown[0..2])+@('    Remove-Item -LiteralPath $resolved -Recurse -Force')){
    if(@($c.teardown|Where-Object{$_-ceq$line}).Count-ne1){Stop-Check "teardown safety statement changed: $($line.Trim())"}
  }
  if(($c.teardown-join"`n").Contains('Assert-')){Stop-Check 'teardown region asserts'}
  # The retained #9272 head partitions the same baseline: its mechanics and
  # union must equal the baseline, or this proof does not transfer to it.
  if(($r.construction-join"`n")-cne($b.construction-join"`n")-or($r.teardown-join"`n")-cne($b.teardown-join"`n")-or
    ($kept.assertions-join"`n")-cne($base.assertions-join"`n")-or($kept.mutants-join"`n")-cne($base.mutants-join"`n")){Stop-Check 'retained head mechanics differ from baseline'}
  [ordered]@{assertions=$base.assertions.Count;receipts=$base.receipts.Count;mutantLoops=$base.mutants.Count
    mutants=@([regex]::Matches(($base.mutants-join"`n"),"name='([^']+)'")|ForEach-Object{$_.Groups[1].Value})
    outsideLines=$b.outside.Count;baselineConstructionLines=$b.construction.Count;candidateConstructionLines=$c.construction.Count
    baselineTeardownLines=$b.teardown.Count;candidateTeardownLines=$c.teardown.Count}
}
function Edit-Once([string]$Text,[string]$From,[string]$To){
  $n=(Get-Normalized $Text);$count=([regex]::Matches($n,[regex]::Escape($From))).Count
  if($count-ne1){Stop-Check "control seam occurs $count times: $From"};$n.Replace($From,$To)
}
function Get-OnlyLine([string]$Text,[scriptblock]$Match){
  $lines=Get-Lines $Text;$hits=@(for($i=0;$i-lt$lines.Count;$i++){if(&$Match $lines[$i]){$i}})
  if($hits.Count-ne1){Stop-Check "control seam matches $($hits.Count) lines"};[pscustomobject]@{lines=$lines;index=$hits[0];line=$lines[$hits[0]]}
}
function Remove-OnlyLine([string]$Text,[scriptblock]$Match){$hit=Get-OnlyLine $Text $Match;@($hit.lines|Select-Object -Index @(0..($hit.lines.Count-1)|Where-Object{$_-ne$hit.index}))-join"`n"}
function Assert-Red([string]$Name,[string]$Expected,[scriptblock]$Body){
  $message='';try{&$Body}catch{$message=$_.Exception.Message}
  $red=$message.StartsWith("CHECK $Expected")
  $results.controls[$Name]=[ordered]@{expected=$Expected;observed=$message;red=$red}
  if(-not$red){throw "CONTROL $Name not red as '$Expected' (observed '$message')"}
  Write-Output "PASS control $Name RED: $message"
}
function Invoke-Harness([string[]]$Arguments){
  $out=@(& $pwsh -NoProfile -NonInteractive -File $harness @Arguments 2>&1|ForEach-Object{"$_"})
  [pscustomobject]@{exitCode=$LASTEXITCODE;text=($out-join"`n")}
}
function Write-SourceFile([string]$Name,[string]$Text){$p=Join-Path $run "$Name.ps1";[IO.File]::WriteAllText($p,(Get-Normalized $Text));$p}

$baselineText=Resolve-PinnedSource $BaselineHead $TestPath
$retainedText=Resolve-PinnedSource $RetainedHead $TestPath
[void](Resolve-PinnedSource $BaselineHead $ProductionPath)
$productionBlob=(& git -C $repo hash-object -- (Join-Path $repo $ProductionPath)).Trim()
if($productionBlob-cne$Pins["${BaselineHead}:$ProductionPath"]){Stop-Check "production reclamation policy changed: $productionBlob"}
$candidateText=[IO.File]::ReadAllText((Join-Path $repo $TestPath))
$results.provenance=[ordered]@{baselineTest=$Pins["${BaselineHead}:$TestPath"];retainedTest=$Pins["${RetainedHead}:$TestPath"]
  production=$productionBlob;candidateTest=(& git -C $repo hash-object -- (Join-Path $repo $TestPath)).Trim()}
Write-Output "PASS provenance baseline=$BaselineHead test=$($results.provenance.baselineTest) retained=$RetainedHead test=$($results.provenance.retainedTest) production=$productionBlob candidate=$($results.provenance.candidateTest)"
$baselineFile=Write-SourceFile 'baseline' $baselineText;$candidateFile=Write-SourceFile 'candidate' $candidateText
$created=[Collections.Generic.List[string]]::new()
try{

if('static'-cin$steps){
  $results.static=Test-StaticProof $baselineText $candidateText $retainedText
  Write-Output "PASS static union assertions=$($results.static.assertions) receipts=$($results.static.receipts) mutants=$($results.static.mutants-join',') outside-lines=$($results.static.outsideLines) unchanged"
  $scaleAssert="  Assert-Cleanup (@(`$script:scaleResult.rows|Where-Object{`$_.reasonCode-ceq'identity-unrecognized'}).Count-eq150"
  $static=[ordered]@{
    'drop-assertion'=@('assertion union changed',{Test-StaticProof $baselineText (Remove-OnlyLine $candidateText {param($l)$l.StartsWith($scaleAssert)}) $retainedText})
    'duplicate-assertion'=@('assertion union changed',{$line=(Get-OnlyLine $candidateText {param($l)$l.StartsWith($scaleAssert)}).line
      Test-StaticProof $baselineText (Edit-Once $candidateText $ConstructionEnd "$line`n$ConstructionEnd") $retainedText})
    'drop-receipt'=@('PASS receipt union changed',{Test-StaticProof $baselineText (Edit-Once $candidateText "Assert-IdleCallCount;Write-Output 'PASS reclamation-idle-call-count'" 'Assert-IdleCallCount') $retainedText})
    'drop-mutant'=@('mutant inventory changed',{Test-StaticProof $baselineText (Remove-OnlyLine $candidateText {param($l)$l.Contains("@{name='drop-idle'")}) $retainedText})
    'edit-non-mechanics'=@('non-mechanics source changed',{Test-StaticProof $baselineText (Edit-Once $candidateText 'idleHours=5.99}' 'idleHours=6.01}') $retainedText})
    'construction-bound'=@('construction bound changed',{Test-StaticProof $baselineText (Edit-Once $candidateText 'TotalMinutes-ge12)' 'TotalMinutes-ge13)') $retainedText})
    'teardown-containment'=@('teardown safety statement changed',{Test-StaticProof $baselineText (Remove-OnlyLine $candidateText {param($l)$l.Contains("{throw 'unsafe cleanup test root'}")}) $retainedText})
    'retained-drift'=@('retained head mechanics differ from baseline',{Test-StaticProof $baselineText $candidateText (Edit-Once $retainedText "'{0:d4}.txt'" "'{0:d5}.txt'")})
    'provenance-missing'=@('provenance object missing',{Resolve-PinnedSource ('0'*40) $TestPath '8610bd4d8a27d269b6f0433db12404ae59403b97'})
    'provenance-mismatch'=@('provenance blob mismatch',{Resolve-PinnedSource $BaselineHead $TestPath $Pins["${RetainedHead}:$TestPath"]})
  }
  foreach($control in $static.GetEnumerator()){Assert-Red "static/$($control.Key)" $control.Value[0] $control.Value[1]}
}

if('teardown'-cin$steps){
  # Small scenes judge the teardown semantics; the full fixtures below judge
  # complete removal at scale. Every scene runs the baseline finally first.
  function New-Scene([string]$Name){
    $base=[IO.Path]::GetFullPath((Join-Path $run "teardown\$Name"));$evidence=Join-Path $base 'evidence';[void][IO.Directory]::CreateDirectory($evidence);$created.Add($base)
    [pscustomobject]@{base=$base;evidence=$evidence;root=(Join-Path $evidence ('cleanup-orphan-test-'+[guid]::NewGuid().ToString('N')))}
  }
  function New-Keep([string]$Path){[void][IO.Directory]::CreateDirectory($Path);[IO.File]::WriteAllText((Join-Path $Path 'keep.txt'),'outside');Join-Path $Path 'keep.txt'}
  function New-Trees([string]$Root,[int]$Trees,[int]$Files){
    for($t=0;$t-lt$Trees;$t++){$p=Join-Path $Root ('scale/tree-{0:d3}'-f$t);[void][IO.Directory]::CreateDirectory($p);for($f=0;$f-lt$Files;$f++){[IO.File]::WriteAllText((Join-Path $p ('{0:d4}.txt'-f$f)),'synthetic')}}
  }
  $scenes=[ordered]@{
    'complete'={param($s)New-Trees $s.root 4 25;$k=@(New-Keep (Join-Path $s.base 'outside-tree'));$k+=New-Keep (Join-Path $s.base 'outside-nested')
      New-Item -ItemType Junction -Path (Join-Path $s.root 'scale/tree-004') -Target (Split-Path $k[0])|Out-Null
      [void][IO.Directory]::CreateDirectory((Join-Path $s.root 'idle-junction'));New-Item -ItemType Junction -Path (Join-Path $s.root 'idle-junction/redirect') -Target (Split-Path $k[1])|Out-Null
      $ro=Join-Path $s.root 'native/.git/objects/ab';[void][IO.Directory]::CreateDirectory($ro);[IO.File]::WriteAllText((Join-Path $ro 'cdef'),'object');[IO.File]::SetAttributes((Join-Path $ro 'cdef'),'ReadOnly')
      [IO.File]::WriteAllText((Join-Path $s.root 'scale-report.json'),'{}')
      @{args=@();keep=$k;expect=@{exit=$true;root=$false;text=''}}}
    'scale-junction'={param($s)[void][IO.Directory]::CreateDirectory($s.root);$k=@(New-Keep (Join-Path $s.base 'outside-scale/tree-900'));$k+=New-Keep (Join-Path $s.base 'outside-scale/tree-901')
      New-Item -ItemType Junction -Path (Join-Path $s.root 'scale') -Target (Join-Path $s.base 'outside-scale')|Out-Null
      @{args=@();keep=$k;expect=@{exit=$true;root=$false;text=''}}}
    'keep-evidence'={param($s)New-Trees $s.root 1 3;@{args=@('-KeepEvidence');keep=@();expect=@{exit=$true;root=$true;text="EVIDENCE_ROOT $($s.root)"}}}
    'unsafe-parent'={param($s)$s.root=Join-Path $s.base ('elsewhere/cleanup-orphan-test-'+[guid]::NewGuid().ToString('N'));New-Trees $s.root 1 3
      @{args=@();keep=@();expect=@{exit=$false;root=$true;text='unsafe cleanup test root'}}}
    'unsafe-leaf'={param($s)$s.root=Join-Path $s.evidence 'not-a-cleanup-root';New-Trees $s.root 1 3
      @{args=@();keep=@();expect=@{exit=$false;root=$true;text='unsafe cleanup test root'}}}
    'failure-path'={param($s)New-Trees $s.root 2 3;@{args=@('-FailBody');keep=@();expect=@{exit=$false;root=$false;text='synthetic failure'}}}
  }
  function Invoke-Scene([string]$Name,[string]$Label,[string]$SourceFile){
    $scene=New-Scene "$Label-$Name";$spec=& $scenes[$Name] $scene
    $h=Invoke-Harness (@('-Mode','teardown','-Root',$scene.root,'-Source',$SourceFile,'-EvidenceRoot',$scene.evidence)+$spec.args)
    $observed=[ordered]@{exit=($h.exitCode-eq0);root=(Test-Path -LiteralPath $scene.root);keepIntact=(@($spec.keep|Where-Object{-not(Test-Path -LiteralPath $_)}).Count-eq0)
      text=($spec.expect.text-eq''-or$h.text.Contains($spec.expect.text))}
    $ok=$observed.exit-eq$spec.expect.exit-and$observed.root-eq$spec.expect.root-and$observed.keepIntact-and$observed.text
    [pscustomobject]@{ok=$ok;observed=$observed;text=$h.text}
  }
  $results.teardown=[ordered]@{}
  foreach($name in $scenes.Keys){
    $b=Invoke-Scene $name 'baseline' $baselineFile;$c=Invoke-Scene $name 'candidate' $candidateFile
    $results.teardown[$name]=[ordered]@{baseline=$b.observed;candidate=$c.observed}
    if(-not$b.ok){Stop-Check "baseline teardown oracle failed scene $name`: $($b.text)"}
    if(-not$c.ok-or($b.observed|ConvertTo-Json -Compress)-cne($c.observed|ConvertTo-Json -Compress)){Stop-Check "teardown differs from baseline in scene $name`: $($c.text)"}
    Write-Output "PASS teardown scene $name baseline=candidate $($c.observed|ConvertTo-Json -Compress)"
  }
  # One-variable bypass mutants of the candidate finally region.
  $mutants=[ordered]@{
    'scale-reparse-guard'=@('scale-junction','-and-not($scaleTreeRoot.Attributes-band[IO.FileAttributes]::ReparsePoint)','')
    'complete-removal'=@('complete','    Remove-Item -LiteralPath $resolved -Recurse -Force','    $null=$resolved')
    'root-containment'=@('unsafe-parent',"{throw 'unsafe cleanup test root'}",'{}')
    'keep-evidence'=@('keep-evidence','if($KeepEvidence){','if($false){')
  }
  foreach($mutant in $mutants.GetEnumerator()){
    $scene,$from,$to=$mutant.Value
    Assert-Red "teardown/$($mutant.Key)" "teardown differs from baseline in scene $scene" {
      $file=Write-SourceFile "mutant-$($mutant.Key)" (Edit-Once $candidateText $from $to)
      $m=Invoke-Scene $scene "mutant-$($mutant.Key)" $file
      if(-not$m.ok){Stop-Check "teardown differs from baseline in scene $scene`: $($m.observed|ConvertTo-Json -Compress)"}
    }
  }
}

$statePath=Join-Path $run 'fixture-state.json'
$fixtureSteps=@($steps|Where-Object{$_.StartsWith('fixture-')})
if($fixtureSteps.Count){
  $state=if(Test-Path -LiteralPath $statePath){Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json -AsHashtable}else{[ordered]@{}}
  function Save-State{[IO.File]::WriteAllText($statePath,($state|ConvertTo-Json -Depth 5))}
  function Get-Build([string]$Label){
    if(-not$state.Contains($Label)){Stop-Check "fixture step order: $Label has not been built in $run"}
    $b=$state[$Label];[pscustomobject]@{label=$Label;root=$b.root;evidence=$b.evidence;source=$b.source
      manifest=(Get-Content -LiteralPath $b.manifest -Raw|ConvertFrom-Json -Depth 20 -DateKind String)}
  }
  function Build-Fixture([string]$Label,[string]$SourceFile){
    if($state.Contains($Label)){Stop-Check "fixture $Label already built in $run"}
    $evidence=[IO.Path]::GetFullPath((Join-Path $run "fixture\$Label"));[void][IO.Directory]::CreateDirectory($evidence)
    $root=Join-Path $evidence ('cleanup-orphan-test-'+[guid]::NewGuid().ToString('N'));$out=Join-Path $run "manifest-$Label.json"
    $state[$Label]=[ordered]@{root=$root;evidence=$evidence;source=$SourceFile;manifest=$out};Save-State
    $clock=[Diagnostics.Stopwatch]::StartNew();$h=Invoke-Harness @('-Mode','build','-Root',$root,'-Source',$SourceFile,'-OutPath',$out)
    if($h.exitCode-ne0){Stop-Check "fixture build failed for $Label`: $($h.text)"}
    $b=Get-Build $Label;Write-Host "BUILD $Label constructionMs=$($b.manifest.constructionMs) reportMs=$($b.manifest.reportMs) processMs=$($clock.Elapsed.TotalMilliseconds)"
    $results["build-$Label"]=[ordered]@{constructionMs=$b.manifest.constructionMs;reportMs=$b.manifest.reportMs;processMs=$clock.Elapsed.TotalMilliseconds};$b
  }
  function Get-FixtureManifest($Build){
    $out=Join-Path $run "manifest-$($Build.label)-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    $h=Invoke-Harness @('-Mode','manifest','-Root',$Build.root,'-OutPath',$out,'-WindowStartUtc',$Build.manifest.windowStartUtc,'-WindowEndUtc',$Build.manifest.windowEndUtc)
    if($h.exitCode-ne0){Stop-Check "fixture manifest failed for $($Build.label)`: $($h.text)"}
    Get-Content -LiteralPath $out -Raw|ConvertFrom-Json -Depth 20
  }
  # The first differing field names the failure, with enough detail that a
  # control cannot pass on a neighbouring difference; JSON text is the comparison.
  function Get-ReasonCounts($Rows){@($Rows|Group-Object reasonCode|Sort-Object Name|ForEach-Object{"$($_.Name)=$($_.Count)"})-join','}
  function Get-Detail([string]$Field,$Base,$Cand){
    switch($Field){
      'rows'{"$(Get-ReasonCounts $Base) -> $(Get-ReasonCounts $Cand)"}
      'fixture.trees'{$b=@($Base);$c=@($Cand)
        if($b.Count-ne$c.Count){"count $($b.Count) -> $($c.Count)"}
        else{$i=0;while($i-lt$b.Count-and$b[$i].digest-ceq$c[$i].digest-and$b[$i].name-ceq$c[$i].name){$i++}
          if($b[$i].entries-ne$c[$i].entries){"$($c[$i].name) entries $($b[$i].entries) -> $($c[$i].entries)"}else{"$($c[$i].name) digest"}}}
      'fixture.outsideWindow'{"$Base -> $Cand"}
      'fixture.dispatchLog'{"rows $(@($Base.rows).Count) -> $(@($Cand.rows).Count)"}
      default{''}
    }
  }
  function Compare-Fixture($Baseline,$Candidate,$Fixture=$Candidate.fixture){
    $pairs=[ordered]@{worktrees=@($Baseline.worktrees,$Candidate.worktrees);branches=@($Baseline.branches,$Candidate.branches);rows=@($Baseline.rows,$Candidate.rows)}
    foreach($field in 'trees','contents','outsideWindow','rootEntries','dispatchLog','register'){$pairs["fixture.$field"]=@($Baseline.fixture.$field,$Fixture.$field)}
    foreach($pair in $pairs.GetEnumerator()){
      if(($pair.Value[0]|ConvertTo-Json -Depth 8 -Compress)-cne($pair.Value[1]|ConvertTo-Json -Depth 8 -Compress)){
        Stop-Check ("fixture differs: $($pair.Key) "+(Get-Detail $pair.Key $pair.Value[0] $pair.Value[1])).TrimEnd()
      }
    }
  }
  try{
    if('fixture-baseline'-cin$steps){
      $B=Build-Fixture 'baseline' $baselineFile
      # Oracle facts come from the brief and the baseline build, never the candidate.
      $bm=$B.manifest;$rowsByReason=@($bm.rows|Group-Object reasonCode|ForEach-Object{"$($_.Name)=$($_.Count)"})-join','
      if(@($bm.fixture.trees).Count-ne200-or@($bm.fixture.trees|Where-Object{$_.kind-cne'directory'-or$_.entries-ne2000}).Count-or
        @($bm.fixture.contents.PSObject.Properties).Count-ne1-or@($bm.fixture.contents.PSObject.Properties)[0].Value-ne400000-or$bm.fixture.outsideWindow-ne0-or
        @($bm.rows|Where-Object{$_.reasonCode-ceq'identity-unrecognized'}).Count-ne150-or@($bm.rows|Where-Object{$_.reasonCode-ceq'idle-under-six-hours'-and$_.idleState-ceq'recent'}).Count-ne50){
        Stop-Check "baseline oracle is not the 200 x 2000 / 150+50 fixture: $rowsByReason"
      }
      Write-Output "PASS baseline oracle trees=200 filesPerTree=2000 files=400000 contents=1 outsideWindow=0 rows=$rowsByReason"
    }
    if('fixture-candidate'-cin$steps){
      $bm=(Get-Build 'baseline').manifest;$C=Build-Fixture 'candidate' $candidateFile
      Compare-Fixture $bm $C.manifest
      Write-Output 'PASS fixture equivalence candidate=baseline worktrees branches rows trees contents timestamps rootEntries dispatchLog register'
    }
    if('fixture-controls'-cin$steps){
      $bm=(Get-Build 'baseline').manifest;$C=Get-Build 'candidate'
      # One-variable post-construction controls on the candidate fixture; each is
      # restored (bytes and timestamps) before the next except the final tree loss.
      function Get-Leaf([string]$Tree,[string]$File){Join-Path $C.root "scale\$Tree\$File"}
      $leaf=Get-Leaf 'tree-000' '0000.txt';$time=[IO.File]::GetLastWriteTimeUtc($leaf)
      Assert-Red 'fixture/changed-content' 'fixture differs: fixture.trees tree-000 digest' {
        try{[IO.File]::WriteAllText($leaf,'synthetiC');[IO.File]::SetLastWriteTimeUtc($leaf,$time);Compare-Fixture $bm $C.manifest (Get-FixtureManifest $C)}
        finally{[IO.File]::WriteAllText($leaf,'synthetic');[IO.File]::SetLastWriteTimeUtc($leaf,$time)}}
      $leaf=Get-Leaf 'tree-050' '0500.txt';$time=[IO.File]::GetLastWriteTimeUtc($leaf)
      Assert-Red 'fixture/stale-timestamp' 'fixture differs: fixture.outsideWindow 0 -> 1' {
        try{[IO.File]::SetLastWriteTimeUtc($leaf,[datetime]::UtcNow.AddHours(-7));Compare-Fixture $bm $C.manifest (Get-FixtureManifest $C)}
        finally{[IO.File]::SetLastWriteTimeUtc($leaf,$time)}}
      $leaf=Get-Leaf 'tree-137' '1999.txt';$time=[IO.File]::GetLastWriteTimeUtc($leaf);$treeTime=[IO.Directory]::GetLastWriteTimeUtc((Split-Path $leaf))
      Assert-Red 'fixture/missing-file' 'fixture differs: fixture.trees tree-137 entries 2000 -> 1999' {
        try{[IO.File]::Delete($leaf);Compare-Fixture $bm $C.manifest (Get-FixtureManifest $C)}
        finally{[IO.File]::WriteAllText($leaf,'synthetic');[IO.File]::SetLastWriteTimeUtc($leaf,$time);[IO.Directory]::SetLastWriteTimeUtc((Split-Path $leaf),$treeTime)}}
      $log=Join-Path $C.root 'dispatch-log.jsonl';$bytes=[IO.File]::ReadAllBytes($log)
      Assert-Red 'fixture/changed-dispatch-row' 'fixture differs: fixture.dispatchLog rows 50 -> 49' {
        try{[IO.File]::WriteAllText($log,((Get-Lines ([IO.File]::ReadAllText($log)))[1..49]-join"`n")+"`n");Compare-Fixture $bm $C.manifest (Get-FixtureManifest $C)}
        finally{[IO.File]::WriteAllBytes($log,$bytes)}}
      Compare-Fixture $bm $C.manifest (Get-FixtureManifest $C)
      Write-Output 'PASS fixture controls restored candidate=baseline'
      Assert-Red 'fixture/missing-tree' 'fixture differs: fixture.trees count 200 -> 199' {
        [IO.Directory]::Delete((Join-Path $C.root 'scale\tree-199'),$true);Compare-Fixture $bm $C.manifest (Get-FixtureManifest $C)}
    }
    if('fixture-authority'-cin$steps){
      # Source-level one-variable mutant: authority distribution only.
      $bm=(Get-Build 'baseline').manifest
      $A=Build-Fixture 'mutant-authority-distribution' (Write-SourceFile 'mutant-authority-distribution' (Edit-Once $candidateText '$tree%4-eq0' '$tree%5-eq0'))
      Assert-Red 'fixture/changed-authority-distribution' 'fixture differs: rows identity-unrecognized=150,idle-under-six-hours=50 -> identity-unrecognized=160,idle-under-six-hours=40' {Compare-Fixture $bm $A.manifest}
    }
    if('fixture-teardown'-cin$steps){
      # Complete synchronous removal of each full fixture by its own finally region.
      foreach($label in 'baseline','candidate','mutant-authority-distribution'){
        $build=Get-Build $label
        $clock=[Diagnostics.Stopwatch]::StartNew();$h=Invoke-Harness @('-Mode','teardown','-Root',$build.root,'-Source',$build.source,'-EvidenceRoot',$build.evidence)
        $ms=$clock.Elapsed.TotalMilliseconds;$left=Test-Path -LiteralPath $build.root
        $results["teardown-$label"]=[ordered]@{exitCode=$h.exitCode;rootRemains=$left;processMs=$ms}
        if($h.exitCode-ne0-or$left){Stop-Check "full fixture teardown incomplete for $label`: $($h.text)"}
        Write-Output "PASS full fixture teardown $label complete processMs=$ms"
        [IO.Directory]::Delete($build.evidence)
      }
    }
  }catch{
    # A failed step must not leave a 400000-file fixture behind.
    foreach($b in $state.Values){if(Test-Path -LiteralPath $b.evidence){Remove-Item -LiteralPath $b.evidence -Recurse -Force}}
    throw
  }
}
$results.result='PASS'
Write-Output "PASS cleanup-scale-fixture-equivalence phase=$Phase controls=$($results.controls.Count) evidence=$run"
}catch{$results.result="FAIL $($_.Exception.Message)";throw}
finally{
  [IO.File]::WriteAllText((Join-Path $run "result-$Phase.json"),($results|ConvertTo-Json -Depth 10))
  foreach($path in $created){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}}
}
