[CmdletBinding()]param(
  [string]$BaselineHead='321915d57da6fbaf647a30080c90601470c2b2cb',
  [string]$EvidenceDirectory=(Join-Path ([IO.Path]::GetTempPath()) 'cleanup-scale-proof'),
  [ValidateSet('all','static','teardown','fixture','fixture-baseline','fixture-candidate','fixture-controls','fixture-authority','fixture-teardown')][string]$Phase='all',
  # Resumes a fixture run in bounded steps: baseline, candidate, controls, authority, teardown.
  [string]$RunDirectory=''
)
# #9275: independent proof that the cleanup scale fixture keeps its proof after
# its construction mechanics changed. It replaces only the "mechanics source
# equals the baseline" premise. Outside the construction region the candidate
# must equal the immutable baseline blob except a closed list of inert phase
# instrumentation lines; the finally region, whose synchronous Remove-Item is
# the sole deletion authority, is held to the same rule; the assertion, PASS
# receipt and mutant unions must be exact; and the construction region is
# judged by what the baseline blob itself builds and removes, never by expected
# values derived from the candidate. static and teardown are cheap direct
# phases; fixture builds three full fixtures and belongs to host-attributed
# heavy verification. Not a battery item.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$TestPath='.orchestrator/cleanup-orphan-worktree-dirs.test.ps1'
$ProductionPath='.orchestrator/cleanup-orphan-worktree-dirs.ps1'
# Recorded immutable objects (#9275 brief AC5; B is an ancestor of the installed base).
$Pins=@{
  "321915d57da6fbaf647a30080c90601470c2b2cb:$TestPath"='8610bd4d8a27d269b6f0433db12404ae59403b97'
  "321915d57da6fbaf647a30080c90601470c2b2cb:$ProductionPath"='0f5b469b351c11f7f85fb5553b3d9ab79833c0e4'
}
$ConstructionStart='  Reset-Synthetic;$script:worktrees=@();$script:branches=@();$dispatchRows=[Collections.Generic.List[string]]::new()'
$ConstructionEnd='  $construction.Stop()'
$ConstructionClock='  $construction=[Diagnostics.Stopwatch]::StartNew()'
$BoundLine='^\s*if\(\(?\$(?:using:)?construction\)?\.Elapsed\.TotalMinutes-ge12\)\{throw ''scale fixture construction exceeded 12 minute safety bound''\}$'
# The only lines the candidate may add outside the construction region, each
# at a fixed place so no clock can exclude part of its phase: the item clock
# right after the error preference, the teardown clock around the whole finally.
$ItemClockAfter='$ErrorActionPreference=''Stop'''
$ItemClock='$suiteClock=[Diagnostics.Stopwatch]::StartNew()'
$TeardownClock='  $teardown=[Diagnostics.Stopwatch]::StartNew()'
$PhaseReceipt='  $teardown.Stop();Write-Output "PHASE reclamation-scale constructionMs=$($construction.Elapsed.TotalMilliseconds) reportMs=$($wall.TotalMilliseconds) teardownMs=$($teardown.Elapsed.TotalMilliseconds) fullItemMs=$($suiteClock.Elapsed.TotalMilliseconds)"'
$Removal='  elseif(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}'
# controller-9275-review-r1 F1: the parallel pre-delete from salvage 795a37c3,
# verbatim. Bypass mutants reintroduce it; it must never pass.
$SalvagePrePass=@'
  elseif(Test-Path -LiteralPath $resolved){
    # Delete the contained scale trees four at a time, never enumerating through
    # a reparse point. Remove-Item stays the complete removal of whatever remains.
    $scaleTreeRoot=[IO.DirectoryInfo]::new((Join-Path $resolved 'scale'))
    if($scaleTreeRoot.Exists-and-not($scaleTreeRoot.Attributes-band[IO.FileAttributes]::ReparsePoint)){
      $scaleTreeRoot.GetDirectories()|ForEach-Object -ThrottleLimit 4 -Parallel {try{$_.Delete($true)}catch{}}
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
'@
$SalvagePrePass=$SalvagePrePass.Replace("`r`n","`n").TrimEnd("`n")
$PrePassGuard='-and-not($scaleTreeRoot.Attributes-band[IO.FileAttributes]::ReparsePoint)'
$harness=Join-Path $PSScriptRoot 'cleanup-scale-fixture-harness.ps1'
$pwsh=(Get-Process -Id $PID).Path
$run=if($RunDirectory){[IO.Path]::GetFullPath($RunDirectory)}else{Join-Path ([IO.Path]::GetFullPath($EvidenceDirectory)) ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))}
[void][IO.Directory]::CreateDirectory($run)
$steps=switch($Phase){'all'{'static','teardown','fixture-baseline','fixture-candidate','fixture-controls','fixture-authority','fixture-teardown'}
  'fixture'{'fixture-baseline','fixture-candidate','fixture-controls','fixture-authority','fixture-teardown'};default{$Phase}}
$results=[ordered]@{baselineHead=$BaselineHead;phase=$Phase;controls=[ordered]@{}}

function Stop-Check([string]$Message){throw "CHECK $Message"}
function Get-Normalized([string]$Text){$Text.Replace("`r`n","`n")}
function Get-Lines([string]$Text){$lines=@((Get-Normalized $Text)-split"`n");if($lines.Count-and$lines[-1]-ceq''){$lines=$lines[0..($lines.Count-2)]};,$lines}
function Get-BlobId([byte[]]$Bytes){
  $header=[Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
  [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header+$Bytes))).ToLowerInvariant()
}
function Test-BlobBytes([byte[]]$Bytes,[string]$Expected,[string]$Name){
  $id=Get-BlobId $Bytes;if($id-cne$Expected){Stop-Check "provenance content mismatch: $Name=$id expected $Expected"}
  [Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
}
function Get-GitBytes([string[]]$Arguments){
  $info=[Diagnostics.ProcessStartInfo]::new('git');foreach($argument in @('-C',$repo)+$Arguments){$info.ArgumentList.Add($argument)}
  $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
  $process=[Diagnostics.Process]::Start($info);$buffer=[IO.MemoryStream]::new();$errorText=$process.StandardError.ReadToEndAsync()
  $process.StandardOutput.BaseStream.CopyTo($buffer);$process.WaitForExit();$null=$errorText.Result
  if($process.ExitCode-ne0){return $null};,$buffer.ToArray()
}
# Fail closed unless the head is a commit, its path resolves to the pinned blob
# and the exact bytes read hash back to that blob.
function Get-PinnedSource([string]$Head,[string]$Path,[string]$Expected=$Pins["${Head}:$Path"]){
  $type=Get-GitBytes @('cat-file','-t',$Head)
  if($null-eq$type-or[Text.Encoding]::ASCII.GetString($type).Trim()-cne'commit'){Stop-Check "provenance object missing: $Head"}
  if(-not$Expected){Stop-Check "provenance unpinned: ${Head}:$Path"}
  $blob=Get-GitBytes @('rev-parse',"${Head}:$Path");$blob=if($null-eq$blob){''}else{[Text.Encoding]::ASCII.GetString($blob).Trim()}
  if($blob-cne$Expected){Stop-Check "provenance blob mismatch: ${Head}:$Path=$blob expected $Expected"}
  Test-BlobBytes (Get-GitBytes @('cat-file','blob',$blob)) $Expected "${Head}:$Path"
}
# Working-tree files are compared as the LF blob Git stores for them.
function Get-WorktreeBlobId([string]$Path){Get-BlobId ([Text.Encoding]::UTF8.GetBytes((Get-Normalized ([IO.File]::ReadAllText($Path)))))}
function Test-Production([string]$Path){
  $id=Get-WorktreeBlobId $Path;$expected=$Pins["321915d57da6fbaf647a30080c90601470c2b2cb:$ProductionPath"]
  if($id-cne$expected){Stop-Check "production reclamation policy changed: $id expected $expected"};$id
}
function Get-Ast([string]$Text,[string]$Name){
  $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput((Get-Normalized $Text),[ref]$tokens,[ref]$errors)
  if($errors.Count){Stop-Check "$Name does not parse"};$ast
}
function Get-Commands($Ast,[scriptblock]$Where){
  ,@($Ast.FindAll({param($n)$n-is[Management.Automation.Language.CommandAst]},$true)|Where-Object $Where|ForEach-Object{$_.Extent.Text}|Sort-Object -CaseSensitive)
}
function Get-Union($Ast){
  [ordered]@{
    assertions=Get-Commands $Ast {$_.GetCommandName()-like'Assert-*'}
    receipts=Get-Commands $Ast {$_.GetCommandName()-ceq'Write-Output'-and$_.Extent.Text.Contains('PASS')}
    mutants=@($Ast.FindAll({param($n)$n-is[Management.Automation.Language.ForEachStatementAst]-and$n.Variable.VariablePath.UserPath-ceq'mutant'},$true)|ForEach-Object{$_.Condition.Extent.Text})
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
function Test-StaticProof([string]$Baseline,[string]$Candidate){
  $base=Get-Union (Get-Ast $Baseline 'baseline');$cand=Get-Union (Get-Ast $Candidate 'candidate')
  if(($base.assertions-join"`n")-cne($cand.assertions-join"`n")){Stop-Check 'assertion union changed'}
  if(($base.receipts-join"`n")-cne($cand.receipts-join"`n")){Stop-Check 'PASS receipt union changed'}
  if(($base.mutants-join"`n")-cne($cand.mutants-join"`n")){Stop-Check 'mutant inventory changed'}
  $b=Get-Regions $Baseline 'baseline';$c=Get-Regions $Candidate 'candidate'
  # With the unions and every line outside the construction region fixed, the
  # construction region cannot gain or lose an assertion or PASS receipt.
  $at=(Get-OnlyIndex $b.outside $ItemClockAfter 'baseline item-clock')+1
  if(((@($b.outside[0..($at-1)])+$ItemClock+@($b.outside[$at..($b.outside.Count-1)]))-join"`n")-cne($c.outside-join"`n")){Stop-Check 'non-mechanics source changed'}
  if(((@($TeardownClock)+$b.teardown+$PhaseReceipt)-join"`n")-cne($c.teardown-join"`n")){Stop-Check 'teardown region changed'}
  # Every changed construction line runs inside the construction clock: the
  # baseline prefix through its start is kept, only the final anchor stops it,
  # and nothing started inside outlives it. Lines after the anchor are outside.
  $bClock=Get-OnlyIndex $b.construction $ConstructionClock 'baseline construction-clock';$cClock=Get-OnlyIndex $c.construction $ConstructionClock 'candidate construction-clock'
  if(($c.construction[0..$cClock]-join"`n")-cne($b.construction[0..$bClock]-join"`n")){Stop-Check 'construction work outside its clock'}
  $construction=Get-Ast ($c.construction[0..($c.construction.Count-2)]-join"`n") 'candidate construction'
  $detached=@($construction.FindAll({param($n)
    ($n-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$n.Expression.Extent.Text-cmatch'^\(?\$(?:using:)?construction\)?$')-or
    ($n-is[Management.Automation.Language.CommandAst]-and($n.GetCommandName()-cin@('Start-Job','Start-ThreadJob','Start-Process')-or
      @($n.CommandElements|Where-Object{$_-is[Management.Automation.Language.CommandParameterAst]-and$_.ParameterName-eq'AsJob'}).Count))},$true))
  if($detached.Count){Stop-Check "construction work outside its clock: $($detached[0].Extent.Text.Split("`n")[0])"}
  $bound=@($c.construction|Where-Object{$_-cmatch$BoundLine})
  if($bound.Count-ne1-or@($c.construction|Where-Object{$_.Contains('construction exceeded')}).Count-ne1){Stop-Check 'construction bound changed'}
  $deletes=@($construction.FindAll({param($n)
    ($n-is[Management.Automation.Language.CommandAst]-and$n.GetCommandName()-cin@('Remove-Item','ri','rm','rmdir','rd','del','erase'))-or
    ($n-is[Management.Automation.Language.InvokeMemberExpressionAst]-and$n.Member.Extent.Text-ceq'Delete')},$true))
  if($deletes.Count){Stop-Check "construction deletes: $($deletes[0].Extent.Text)"}
  [ordered]@{assertions=$base.assertions.Count;receipts=$base.receipts.Count;mutantLoops=$base.mutants.Count
    mutants=@([regex]::Matches(($base.mutants-join"`n"),"name='([^']+)'")|ForEach-Object{$_.Groups[1].Value})
    outsideLines=$b.outside.Count;teardownLines=$b.teardown.Count
    baselineConstructionLines=$b.construction.Count;candidateConstructionLines=$c.construction.Count}
}
function Edit-Once([string]$Text,[string]$From,[string]$To){
  $n=Get-Normalized $Text;$count=([regex]::Matches($n,[regex]::Escape($From))).Count
  if($count-ne1){throw "control seam occurs $count times: $From"};$n.Replace($From,$To)
}
function Remove-OnlyLine([string]$Text,[string]$Prefix){
  $lines=Get-Lines $Text;$hits=@(for($i=0;$i-lt$lines.Count;$i++){if($lines[$i].StartsWith($Prefix)){$i}})
  if($hits.Count-ne1){throw "control seam matches $($hits.Count) lines: $Prefix"}
  @($lines|Select-Object -Index @(0..($lines.Count-1)|Where-Object{$_-ne$hits[0]}))-join"`n"
}
function Assert-Red([string]$Name,[string]$Expected,[scriptblock]$Body){
  $message='';try{$null=&$Body}catch{$message=$_.Exception.Message}
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

$baselineText=Get-PinnedSource $BaselineHead $TestPath
[void](Get-PinnedSource $BaselineHead $ProductionPath)
$productionBlob=Test-Production (Join-Path $repo $ProductionPath)
$candidatePath=Join-Path $repo $TestPath;$candidateText=Get-Normalized ([IO.File]::ReadAllText($candidatePath))
$results.provenance=[ordered]@{baselineTest=$Pins["${BaselineHead}:$TestPath"];production=$productionBlob
  candidateTest=(Get-WorktreeBlobId $candidatePath);candidateHead=[Text.Encoding]::ASCII.GetString((Get-GitBytes @('rev-parse','HEAD'))).Trim()}
Write-Output "PASS provenance baseline=$BaselineHead test=$($results.provenance.baselineTest) production=$productionBlob candidate=$($results.provenance.candidateTest) head=$($results.provenance.candidateHead)"
$baselineFile=Write-SourceFile 'baseline' $baselineText;$candidateFile=Write-SourceFile 'candidate' $candidateText
$created=[Collections.Generic.List[string]]::new()
try{

if('static'-cin$steps){
  $results.static=Test-StaticProof $baselineText $candidateText
  $s=$results.static
  Write-Output "PASS static union assertions=$($s.assertions) receipts=$($s.receipts) mutants=$($s.mutants-join',') outside-lines=$($s.outsideLines) teardown-lines=$($s.teardownLines) unchanged"
  $scaleAssert='  Assert-Cleanup (@($script:scaleResult.rows|Where-Object{$_.reasonCode-ceq''identity-unrecognized''}).Count-eq150'
  $scaleAssertLine=@((Get-Lines $candidateText)|Where-Object{$_.StartsWith($scaleAssert)})[0]
  $static=[ordered]@{
    'provenance-missing'=@('provenance object missing',{Get-PinnedSource ('0'*40) $TestPath $Pins["${BaselineHead}:$TestPath"]})
    'provenance-unpinned'=@('provenance unpinned',{Get-PinnedSource $BaselineHead '.orchestrator/cleanup-orphan-worktree-dirs.test.ps1.unpinned'})
    'provenance-mismatch'=@('provenance blob mismatch',{Get-PinnedSource $BaselineHead $TestPath $Pins["${BaselineHead}:$ProductionPath"]})
    'provenance-content'=@('provenance content mismatch',{Test-BlobBytes ([Text.Encoding]::UTF8.GetBytes($baselineText.Replace("`n","`r`n"))) $Pins["${BaselineHead}:$TestPath"] 'baseline'})
    'production-policy'=@('production reclamation policy changed',{Test-Production (Write-SourceFile 'control-production' ([IO.File]::ReadAllText((Join-Path $repo $ProductionPath))+"# control`n"))})
    'unparseable'=@('candidate does not parse',{Test-StaticProof $baselineText ($candidateText+"{`n")})
    'drop-assertion'=@('assertion union changed',{Test-StaticProof $baselineText (Remove-OnlyLine $candidateText $scaleAssert)})
    'duplicate-assertion'=@('assertion union changed',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$ConstructionEnd`n" "`n$scaleAssertLine`n$ConstructionEnd`n")})
    'drop-receipt'=@('PASS receipt union changed',{Test-StaticProof $baselineText (Edit-Once $candidateText "Assert-IdleCallCount;Write-Output 'PASS reclamation-idle-call-count'" 'Assert-IdleCallCount')})
    'drop-mutant'=@('mutant inventory changed',{Test-StaticProof $baselineText (Remove-OnlyLine $candidateText "    @{name='drop-idle'")})
    'duplicate-anchor'=@('candidate construction-end anchor occurs 2 times',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$ConstructionEnd`n" "`n$ConstructionEnd`n$ConstructionEnd`n")})
    'region-order'=@('candidate region order',{Test-StaticProof $baselineText ($candidateText+"`$null`n")})
    'edit-non-mechanics'=@('non-mechanics source changed',{Test-StaticProof $baselineText (Edit-Once $candidateText 'idleHours=5.99}' 'idleHours=6.01}')})
    'duplicate-item-clock'=@('non-mechanics source changed',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$ItemClock`n" "`n$ItemClock`n$ItemClock`n")})
    'phase-before-removal'=@('teardown region changed',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$Removal`n$PhaseReceipt`n" "`n$PhaseReceipt`n$Removal`n")})
    'teardown-prepass'=@('teardown region changed',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$Removal`n" "`n$SalvagePrePass`n")})
    'teardown-containment'=@('teardown region changed',{Test-StaticProof $baselineText (Remove-OnlyLine $candidateText '  if((Split-Path -Parent $resolved)')})
    'teardown-removal'=@('teardown region changed',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$Removal`n" "`n$($Removal.Replace(' -Force}','}'))`n")})
    'construction-bound'=@('construction bound changed',{Test-StaticProof $baselineText (Edit-Once $candidateText 'TotalMinutes-ge12)' 'TotalMinutes-ge13)')})
    'work-before-clock'=@('construction work outside its clock',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$ConstructionClock`n" "`n  [void][IO.Directory]::CreateDirectory((Join-Path `$scaleRoot 'tree-000'))`n$ConstructionClock`n")})
    'clock-stopped-early'=@('construction work outside its clock',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n  `$scaleTrees|ForEach-Object" "`n  [void]`$construction.Stop()`n  `$scaleTrees|ForEach-Object")})
    'work-as-job'=@('construction work outside its clock',{Test-StaticProof $baselineText (Edit-Once $candidateText '-ThrottleLimit 4 -Parallel {' '-ThrottleLimit 4 -AsJob -Parallel {')})
    'construction-deletes'=@('construction deletes',{Test-StaticProof $baselineText (Edit-Once $candidateText "`n$ConstructionEnd`n" "`n  [IO.Directory]::Delete((Join-Path `$scaleRoot 'tree-199'),`$true)`n$ConstructionEnd`n")})
  }
  foreach($control in $static.GetEnumerator()){Assert-Red "static/$($control.Key)" $control.Value[0] $control.Value[1]}
}

if('teardown'-cin$steps){
  # Small scenes judge teardown semantics; the full fixtures below judge
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
    # The test root itself is a junction to outside data (F1, physical identity).
    'root-junction'={param($s)$k=@(New-Keep (Join-Path $s.base 'outside-root/scale/tree-000'));$k+=New-Keep (Join-Path $s.base 'outside-root/scale/tree-001')
      New-Item -ItemType Junction -Path $s.root -Target (Join-Path $s.base 'outside-root')|Out-Null
      @{args=@();keep=$k;expect=@{exit=$true;root=$false;text=''}}}
    # scale is swapped for an outside junction after the containment check (F1, check/use).
    'scale-replacement'={param($s)New-Trees $s.root 2 3;$k=@(New-Keep (Join-Path $s.base 'outside-replacement/tree-900'));$k+=New-Keep (Join-Path $s.base 'outside-replacement/tree-901')
      @{args=@('-ReplaceScaleWith',(Join-Path $s.base 'outside-replacement'));keep=$k;expect=@{exit=$true;root=$false;text='HARNESS scale replaced by an outside junction after the containment check'}}}
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
    [pscustomobject]@{ok=$ok;observed=$observed;json=($observed|ConvertTo-Json -Compress);text=$h.text}
  }
  function Test-Scene([string]$Name,[string]$Label,[string]$SourceFile,[string]$BaselineFile){
    $b=Invoke-Scene $Name "$Label-baseline" $BaselineFile
    if(-not$b.ok){Stop-Check "baseline teardown oracle failed scene $Name`: $($b.json) $($b.text)"}
    $c=Invoke-Scene $Name $Label $SourceFile
    if(-not$c.ok-or$b.json-cne$c.json){Stop-Check "teardown differs from baseline in scene $Name`: $($c.json) $($c.text)"}
    [ordered]@{baseline=$b.observed;candidate=$c.observed}
  }
  $results.teardown=[ordered]@{}
  foreach($name in $scenes.Keys){
    $results.teardown[$name]=Test-Scene $name 'candidate' $candidateFile $baselineFile
    Write-Output "PASS teardown scene $name baseline=candidate $($results.teardown[$name].candidate|ConvertTo-Json -Compress)"
  }
  # One-variable bypass mutants of the candidate finally region, each run
  # against the scene that kills it; the oracle control feeds a broken baseline.
  $mutants=[ordered]@{
    'prepass-guarded'=@('root-junction',$Removal,$SalvagePrePass)
    'prepass-unguarded'=@('scale-replacement',$Removal,$SalvagePrePass.Replace($PrePassGuard,''))
    'complete-removal'=@('complete',$Removal,'  elseif(Test-Path -LiteralPath $resolved){$null=$resolved}')
    'root-containment'=@('unsafe-parent',"{throw 'unsafe cleanup test root'}",'{}')
    'keep-evidence'=@('keep-evidence','if($KeepEvidence){','if($false){')
  }
  foreach($mutant in $mutants.GetEnumerator()){
    $scene,$from,$to=$mutant.Value
    $file=Write-SourceFile "mutant-$($mutant.Key)" (Edit-Once $candidateText $from $to)
    Assert-Red "teardown/$($mutant.Key)" "teardown differs from baseline in scene $scene" {Test-Scene $scene "mutant-$($mutant.Key)" $file $baselineFile}
  }
  $broken=Write-SourceFile 'control-broken-baseline' (Edit-Once $baselineText $Removal '  elseif(Test-Path -LiteralPath $resolved){$null=$resolved}')
  Assert-Red 'teardown/baseline-oracle' 'baseline teardown oracle failed scene complete' {Test-Scene 'complete' 'control-oracle' $candidateFile $broken}
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
  function Remove-Build([string]$Label){
    $b=$state[$Label];if(Test-Path -LiteralPath $b.evidence){Remove-Item -LiteralPath $b.evidence -Recurse -Force};$state.Remove($Label);Save-State
  }
  function Build-Fixture([string]$Label,[string]$SourceFile){
    if($state.Contains($Label)){Stop-Check "fixture step order: $Label already built in $run"}
    $evidence=[IO.Path]::GetFullPath((Join-Path $run "fixture\$Label"));[void][IO.Directory]::CreateDirectory($evidence)
    $root=Join-Path $evidence ('cleanup-orphan-test-'+[guid]::NewGuid().ToString('N'));$out=Join-Path $run "manifest-$Label.json"
    $state[$Label]=[ordered]@{root=$root;evidence=$evidence;source=$SourceFile;manifest=$out};Save-State
    $clock=[Diagnostics.Stopwatch]::StartNew();$h=Invoke-Harness @('-Mode','build','-Root',$root,'-Source',$SourceFile,'-OutPath',$out)
    if($h.exitCode-ne0){Remove-Build $Label;Stop-Check "fixture build failed for $Label`: $($h.text)"}
    $b=Get-Build $Label
    $results["build-$Label"]=[ordered]@{constructionMs=$b.manifest.constructionMs;reportMs=$b.manifest.reportMs;processMs=$clock.Elapsed.TotalMilliseconds};$b
  }
  function Get-BuildLine([string]$Label){$t=$results["build-$Label"];"BUILD $Label constructionMs=$($t.constructionMs) reportMs=$($t.reportMs) processMs=$($t.processMs)"}
  function Get-FixtureManifest($Build){
    $out=Join-Path $run "manifest-$($Build.label)-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
    $h=Invoke-Harness @('-Mode','manifest','-Root',$Build.root,'-OutPath',$out,'-WindowStartUtc',$Build.manifest.windowStartUtc,'-WindowEndUtc',$Build.manifest.windowEndUtc)
    if($h.exitCode-ne0){Stop-Check "fixture manifest failed for $($Build.label)`: $($h.text)"}
    Get-Content -LiteralPath $out -Raw|ConvertFrom-Json -Depth 20
  }
  # Oracle facts come from the brief and the baseline build, never the candidate.
  function Get-ReasonCounts($Rows){@($Rows|Group-Object reasonCode|Sort-Object Name|ForEach-Object{"$($_.Name)=$($_.Count)"})-join','}
  function Test-Oracle($Manifest){
    $f=$Manifest.fixture
    if(@($f.trees).Count-ne200-or@($f.trees|Where-Object{$_.kind-cne'directory'-or$_.entries-ne2000}).Count-or
      @($f.contents.PSObject.Properties).Count-ne1-or@($f.contents.PSObject.Properties)[0].Value-ne400000-or$f.outsideWindow-ne0-or
      @($Manifest.rows|Where-Object{$_.reasonCode-ceq'identity-unrecognized'}).Count-ne150-or
      @($Manifest.rows|Where-Object{$_.reasonCode-ceq'idle-under-six-hours'-and$_.idleState-ceq'recent'}).Count-ne50){
      Stop-Check "baseline oracle is not the 200 x 2000 / 150+50 fixture: $(Get-ReasonCounts $Manifest.rows)"
    }
  }
  # The first differing field names the failure with enough detail that a
  # control cannot pass on a neighbouring difference; JSON text is the comparison.
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
  function Invoke-Teardown($Build,[string]$SourceFile){
    $clock=[Diagnostics.Stopwatch]::StartNew();$h=Invoke-Harness @('-Mode','teardown','-Root',$Build.root,'-Source',$SourceFile,'-EvidenceRoot',$Build.evidence)
    [pscustomobject]@{exitCode=$h.exitCode;rootRemains=(Test-Path -LiteralPath $Build.root);processMs=$clock.Elapsed.TotalMilliseconds;text=$h.text}
  }
  try{
    if('fixture-baseline'-cin$steps){
      $B=Build-Fixture 'baseline' $baselineFile;Get-BuildLine 'baseline';Test-Oracle $B.manifest
      Write-Output "PASS baseline oracle trees=200 filesPerTree=2000 files=400000 contents=1 outsideWindow=0 rows=$(Get-ReasonCounts $B.manifest.rows)"
    }
    if('fixture-candidate'-cin$steps){
      $bm=(Get-Build 'baseline').manifest;$C=Build-Fixture 'candidate' $candidateFile;Get-BuildLine 'candidate'
      Compare-Fixture $bm $C.manifest
      Write-Output 'PASS fixture equivalence candidate=baseline worktrees branches rows trees contents timestamps rootEntries dispatchLog register'
    }
    if('fixture-controls'-cin$steps){
      $bm=(Get-Build 'baseline').manifest;$C=Get-Build 'candidate'
      Assert-Red 'fixture/step-not-built' 'fixture step order: control-absent has not been built' {Get-Build 'control-absent'}
      Assert-Red 'fixture/step-rebuilt' 'fixture step order: candidate already built' {Build-Fixture 'candidate' $candidateFile}
      Assert-Red 'fixture/build-failed' 'fixture build failed for control-unparseable' {Build-Fixture 'control-unparseable' (Write-SourceFile 'control-unparseable' ($candidateText+"{`n"))}
      Assert-Red 'fixture/manifest-failed' 'fixture manifest failed for candidate' {Get-FixtureManifest ([pscustomobject]@{label='candidate';root=(Join-Path $run 'control-missing-root');manifest=$C.manifest})}
      # One-variable post-construction controls on the candidate fixture; each is
      # restored (bytes and timestamps) before the next, except the final tree loss.
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
      $A=Build-Fixture 'mutant-authority-distribution' (Write-SourceFile 'mutant-authority-distribution' (Edit-Once $candidateText '$tree%4-eq0' '$tree%5-eq0'));Get-BuildLine 'mutant-authority-distribution'
      Assert-Red 'fixture/changed-authority-distribution' 'fixture differs: rows identity-unrecognized=150,idle-under-six-hours=50 -> identity-unrecognized=160,idle-under-six-hours=40' {Compare-Fixture $bm $A.manifest}
      Assert-Red 'fixture/baseline-oracle' 'baseline oracle is not the 200 x 2000 / 150+50 fixture' {Test-Oracle $A.manifest}
    }
    if('fixture-teardown'-cin$steps){
      # A finally region that removes nothing must be refused on a full fixture.
      $A=Get-Build 'mutant-authority-distribution'
      $none=Write-SourceFile 'control-no-removal' (Edit-Once $candidateText $Removal '  elseif(Test-Path -LiteralPath $resolved){$null=$resolved}')
      Assert-Red 'fixture/incomplete-teardown' 'full fixture teardown incomplete for mutant-authority-distribution' {
        $t=Invoke-Teardown $A $none;if($t.exitCode-ne0-or$t.rootRemains){Stop-Check "full fixture teardown incomplete for $($A.label)`: exit=$($t.exitCode) rootRemains=$($t.rootRemains)"}}
      # Complete synchronous removal of each full fixture by its own finally region.
      foreach($label in 'baseline','candidate','mutant-authority-distribution'){
        $build=Get-Build $label;$t=Invoke-Teardown $build $build.source
        $results["teardown-$label"]=[ordered]@{exitCode=$t.exitCode;rootRemains=$t.rootRemains;processMs=$t.processMs}
        if($t.exitCode-ne0-or$t.rootRemains){Stop-Check "full fixture teardown incomplete for $label`: $($t.text)"}
        Write-Output "PASS full fixture teardown $label complete processMs=$($t.processMs)"
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
