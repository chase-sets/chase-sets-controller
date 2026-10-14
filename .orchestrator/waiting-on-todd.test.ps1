<# AC1/AC2 fixtures for waiting-on-todd.ps1 (#9228). Every repo, issue, actionId
   and login below is SYNTHETIC; a fake gh stub stands in for GitHub and no
   live endpoint is ever called. #>
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$script:sut=Join-Path $PSScriptRoot 'waiting-on-todd.ps1';$script:logger=Join-Path $PSScriptRoot 'log-event.ps1'
$root=Join-Path ([IO.Path]::GetTempPath()) ('waiting-on-todd-test-'+[guid]::NewGuid().ToString('N'))
$script:pinned=909229;$script:todd='synthetic-todd'
function Assert-Wot([bool]$c,[string]$m){if(-not$c){throw "ASSERTION FAILED: $m"}}

# Fake GitHub: issue state, call log and one-shot faults persist in one JSON file.
$script:stubSource=@'
$fakePath=$env:WOT_FAKE_GH;$fake=[IO.File]::ReadAllText($fakePath)|ConvertFrom-Json -AsHashtable
$method='GET';$path='';$inputFile='';$field=''
for($i=1;$i -lt $args.Count;$i++){switch -CaseSensitive($args[$i]){'-X'{$i++;$method=$args[$i]}'--input'{$i++;$inputFile=$args[$i]}'-f'{$i++;$field=$args[$i]}default{$path=$args[$i]}}}
$number=[regex]::Match($path,'/issues/(\d+)').Groups[1].Value;$key="$method $number"
$fake.calls=@($fake.calls)+@($key)
function Save{[IO.File]::WriteAllText($fakePath,($fake|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
function Take([string]$List){if(@($fake[$List]) -ccontains $key){$fake[$List]=@(@($fake[$List])|Where-Object{$_ -cne $key});return $true};return $false}
if(Take 'failOnce'){Save;exit 1}
$issue=$fake.issues[$number];if($null -eq $issue){Save;exit 1}
if($method -ceq 'GET'){
  if(@($fake.failGet) -ccontains $number){Save;exit 1}
  $fake.getCounts[$number]=1+[int]$fake.getCounts[$number]
  foreach($change in @($fake.bodyChanges)){if($change.issue -ceq $number -and [int]$change.onGet -eq $fake.getCounts[$number]){
    if($change.ContainsKey('body')){$issue.body=$change.body};if($change.ContainsKey('assignees')){$issue.assignees=@($change.assignees)}}}
  if(@($fake.malformedGet) -ccontains $number){Save;'{"number":'+$number+',"body":"x"}';exit 0}
  Save;[ordered]@{number=[int]$number;body=$issue.body;assignees=@(@($issue.assignees)|ForEach-Object{@{login=$_}})}|ConvertTo-Json -Depth 5 -Compress;exit 0
}
$ignored=Take 'ignoreOnce'
if(-not $ignored){
  $login=$field -replace '^assignees\[\]=',''
  if($method -ceq 'POST'){$issue.assignees=@(@($issue.assignees)+@($login)|Select-Object -Unique)}
  elseif($method -ceq 'DELETE'){$issue.assignees=@(@($issue.assignees)|Where-Object{$_ -cne $login})}
  elseif($method -ceq 'PATCH'){$issue.body=([IO.File]::ReadAllText($inputFile)|ConvertFrom-Json).body}
}
$crash=Take 'crashAfter';Save;if($crash){exit 1};'{}';exit 0
'@

function New-WotCase([string]$Name,[hashtable]$Issues){
  $dir=Join-Path $root $Name;[void](New-Item -ItemType Directory -Path $dir)
  $case=[pscustomobject]@{dir=$dir;ledger=(Join-Path $dir 'dispatch-log.jsonl');state=(Join-Path $dir 'state/waiting-on-todd.json')
    config=(Join-Path $dir 'waiting-on-todd.psd1');fake=(Join-Path $dir 'fake-gh.json');stub=(Join-Path $dir 'fake-gh.ps1');seen=0}
  [IO.File]::WriteAllText($case.config,"@{ Repo = 'synthetic/chase-sets'; PinnedIssue = $script:pinned; Assignee = '$script:todd'; DoneWindowDays = 7 }",[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($case.stub,$script:stubSource,[Text.UTF8Encoding]::new($false))
  $map=@{"$script:pinned"=@{body='synthetic hand-written body';assignees=@()}}
  foreach($k in $Issues.Keys){$map["$k"]=@{body='';assignees=@($Issues[$k])}}
  Set-WotFake $case @{issues=$map;calls=@();getCounts=@{};failGet=@();malformedGet=@();failOnce=@();crashAfter=@();ignoreOnce=@();bodyChanges=@()}
  [IO.File]::WriteAllText($case.ledger,'',[Text.UTF8Encoding]::new($false))
  return $case
}
function Get-WotFake($Case){[IO.File]::ReadAllText($Case.fake)|ConvertFrom-Json -AsHashtable}
function Set-WotFake($Case,$Fake){[IO.File]::WriteAllText($Case.fake,($Fake|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
function Edit-WotFake($Case,[scriptblock]$Edit){$fake=Get-WotFake $Case;& $Edit $fake;Set-WotFake $Case $fake}
function Add-WotAction($Case,[string]$Id,[int]$Issue,[string]$State,[string]$Text="Synthetic step for $Id"){
  & $script:logger -Log dispatch -Kind todd-action -ActionId $Id -Issue $Issue -ActionState $State -Action $Text -ActionTime 'synthetic minutes' -Unblocks "#$($Issue+1000)" -OutFile $Case.ledger -NoBoard|Out-Null
}
function Get-WotStateBytes($Case){if(Test-Path -LiteralPath $Case.state){[Convert]::ToBase64String([IO.File]::ReadAllBytes($Case.state))}else{'<absent>'}}
function Invoke-WotCycle($Case,[string]$Now,[switch]$DryRun,[hashtable]$Extra=@{}){
  $env:WOT_FAKE_GH=$Case.fake
  $arguments=@{Config=$Case.config;DispatchLog=$Case.ledger;StatePath=$Case.state;GhCommand=$Case.stub}
  if($Now){$arguments.NowUtc=$Now};if($DryRun){$arguments.DryRun=$true};foreach($k in $Extra.Keys){$arguments[$k]=$Extra[$k]}
  $out=$null;$err=$null
  try{$out=(& $script:sut @arguments|Out-String).Trim()|ConvertFrom-Json}catch{$err=$_.Exception.Message}
  $calls=@((Get-WotFake $Case).calls);$new=@($calls|Select-Object -Skip $Case.seen);$Case.seen=$calls.Count
  return [pscustomobject]@{out=$out;err=$err;calls=$new;mutations=@($new|Where-Object{$_ -notlike 'GET *'})}
}
function Get-WotIssue($Case,[int]$Number){(Get-WotFake $Case).issues["$Number"]}
function Get-WotOwned($Case){@(([IO.File]::ReadAllText($Case.state)|ConvertFrom-Json).owned)-join','}
function Get-WotPending($Case){@(([IO.File]::ReadAllText($Case.state)|ConvertFrom-Json).pending|ForEach-Object{"$($_.op) $($_.issue)"})-join','}
function Assert-WotRefusal($Case,$Result,[string]$Code,[string]$StateBefore,[string]$Label){
  Assert-Wot ($Result.err -and $Result.err.StartsWith($Code)) "$Label expected $Code, observed '$($Result.err)'"
  Assert-Wot ($Result.mutations.Count -eq 0) "$Label refusal made GitHub writes: $($Result.mutations -join ', ')"
  Assert-Wot ((Get-WotStateBytes $Case) -ceq $StateBefore) "$Label refusal rewrote the state file"
}

try{
  [void](New-Item -ItemType Directory -Path $root)
  Write-Output 'SYNTHETIC identities only: synthetic/chase-sets, issues 909001-909229, login synthetic-todd'
  $t0=[datetimeoffset]::UtcNow

  # --- AC1: two actions on one issue, superseded state, manual assignment, done aging ---
  $a=New-WotCase 'lifecycle' @{909001=@();909002=@();909004=@($script:todd);909005=@($script:todd)}
  foreach($row in @(@('synthetic-a1',909001,'now'),@('synthetic-a2',909001,'now'),@('synthetic-b1',909002,'now'),@('synthetic-m1',909004,'now'))){Add-WotAction $a $row[0] $row[1] $row[2]}
  $dry=Invoke-WotCycle $a -DryRun
  Assert-Wot ($null -eq $dry.err -and $dry.mutations.Count -eq 0 -and (Get-WotStateBytes $a) -ceq '<absent>' -and (@($dry.out.adds)-join',') -ceq '909001,909002') "dry run wrote or planned wrongly: $($dry.err) $($dry.mutations)"
  $r=Invoke-WotCycle $a
  Assert-Wot ($null -eq $r.err) "first cycle refused: $($r.err)"
  Assert-Wot (($r.mutations -join ',') -ceq "POST 909001,POST 909002,PATCH $script:pinned") "first cycle writes: $($r.mutations -join ',')"
  Assert-Wot (@($r.calls|Where-Object{$_ -like '* 909005'}).Count -eq 0) 'an issue with no action and a manual assignment was touched'
  Assert-Wot ((Get-WotOwned $a) -ceq '909001,909002' -and (Get-WotPending $a) -ceq '') "first cycle ownership: $(Get-WotOwned $a)"
  $body=(Get-WotIssue $a $script:pinned).body
  $nowSection=($body -split '## Later')[0]
  foreach($id in @('a1','a2','b1','m1')){Assert-Wot ($nowSection.Contains("Synthetic step for synthetic-$id")) "Now omitted synthetic-$id"}
  Assert-Wot ($body.StartsWith('<!-- waiting-on-todd/v1') -and $body.Contains("| #909001 | Synthetic step for synthetic-a1 | synthetic minutes | #910001 |")) 'body row shape'
  Write-Output 'PASS AC1 first cycle: Now actions rendered, Todd added only where absent, manual assignment not owned, unrelated manual issue untouched'

  # AC2: unchanged input causes no write, not even to the state file.
  $stateBefore=Get-WotStateBytes $a;$stamp=(Get-Item -LiteralPath $a.state).LastWriteTimeUtc
  $r=Invoke-WotCycle $a
  Assert-Wot ($null -eq $r.err -and $r.mutations.Count -eq 0 -and $r.calls.Count -gt 0 -and (Get-WotStateBytes $a) -ceq $stateBefore -and
    (Get-Item -LiteralPath $a.state).LastWriteTimeUtc -eq $stamp -and -not $r.out.bodyWritten) "AC2 unchanged input wrote: $($r.mutations -join ',') $($r.err)"
  Write-Output 'PASS AC2 unchanged input: reads only, no GitHub write, state file untouched'

  # Two actions on one issue resolved separately: the issue stays desired until both are done.
  Add-WotAction $a 'synthetic-a1' 909001 'done'
  $r=Invoke-WotCycle $a
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned") "first resolution writes: $($r.mutations -join ',') $($r.err)"
  $body=(Get-WotIssue $a $script:pinned).body
  Assert-Wot ((($body -split '## Done')[1]).Contains('synthetic-a1') -and (($body -split '## Later')[0]).Contains('synthetic-a2') -and -not (($body -split '## Later')[0]).Contains('synthetic-a1')) 'a1 not moved to Done while a2 stays Now'
  Write-Output 'PASS AC1 two actions on one issue: first resolution keeps Todd assigned and moves only that action to Done'

  # Superseded state: the latest row per actionId wins (now -> later removes the owned assignment).
  Add-WotAction $a 'synthetic-b1' 909002 'later'
  $r=Invoke-WotCycle $a
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "DELETE 909002,PATCH $script:pinned") "superseded writes: $($r.mutations -join ',') $($r.err)"
  Assert-Wot ((Get-WotOwned $a) -ceq '909001' -and @((Get-WotIssue $a 909002).assignees).Count -eq 0) 'superseded issue still owned or assigned'
  $body=(Get-WotIssue $a $script:pinned).body
  Assert-Wot ((($body -split '## Later')[1] -split '## Done')[0].Contains('synthetic-b1') -and -not (($body -split '## Later')[0]).Contains('synthetic-b1')) 'b1 not rendered under Later only'
  Add-WotAction $a 'synthetic-b1' 909002 'now'
  $r=Invoke-WotCycle $a
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "POST 909002,PATCH $script:pinned" -and (Get-WotOwned $a) -ceq '909001,909002') "re-superseded writes: $($r.mutations -join ',')"
  Write-Output 'PASS AC1 superseded state: now->later removes the script-made assignment, later->now restores it'

  # Manual assignment is never removed, even when its only action is done.
  Add-WotAction $a 'synthetic-m1' 909004 'done'
  $r=Invoke-WotCycle $a
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned") "manual done writes: $($r.mutations -join ',')"
  Assert-Wot (@((Get-WotIssue $a 909004).assignees) -ccontains $script:todd -and @((Get-WotIssue $a 909005).assignees) -ccontains $script:todd) 'a manual Todd assignment was removed'
  Add-WotAction $a 'synthetic-a2' 909001 'done';Add-WotAction $a 'synthetic-b1' 909002 'done'
  $r=Invoke-WotCycle $a
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "DELETE 909001,DELETE 909002,PATCH $script:pinned" -and (Get-WotOwned $a) -ceq '') "final resolution writes: $($r.mutations -join ',')"
  Assert-Wot (@((Get-WotIssue $a 909004).assignees) -ccontains $script:todd) 'manual assignment removed after every action resolved'
  Write-Output 'PASS AC1 manual Todd assignment: never owned, never removed; script-made assignments removed when their last Now action resolves'

  # Done ages out after the window: inside the window nothing changes, past it the body drops the rows.
  $r=Invoke-WotCycle $a ($t0.AddDays(6).ToString('o'))
  Assert-Wot ($null -eq $r.err -and $r.mutations.Count -eq 0) "day-6 cycle wrote: $($r.mutations -join ',')"
  $r=Invoke-WotCycle $a ($t0.AddDays(8).ToString('o'))
  $body=(Get-WotIssue $a $script:pinned).body
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned" -and ($body -split '## Done')[1].Contains('None.') -and -not $body.Contains('synthetic-a1')) "done did not age out: $($r.mutations -join ',')"
  Write-Output 'PASS AC1 done aging: Done rows stay for 7 days, then leave the body with one write'

  # --- AC1: failed read writes nothing ---
  $f=New-WotCase 'failed-read' @{909001=@();909002=@()}
  Add-WotAction $f 'synthetic-f1' 909001 'now';Add-WotAction $f 'synthetic-f2' 909002 'now'
  foreach($fault in @(@{name='issue';edit={param($x)$x.failGet=@('909002')}},@{name='pinned';edit={param($x)$x.failGet=@("$script:pinned")}},
      @{name='malformed';edit={param($x)$x.malformedGet=@('909001')}})){
    Edit-WotFake $f $fault.edit;$before=Get-WotStateBytes $f
    Assert-WotRefusal $f (Invoke-WotCycle $f) 'WAITING_ON_TODD_READ_FAILED' $before "failed-read/$($fault.name)"
    Assert-Wot ((Get-WotIssue $f $script:pinned).body -ceq 'synthetic hand-written body') "failed-read/$($fault.name) changed the body"
    Edit-WotFake $f {param($x)$x.failGet=@();$x.malformedGet=@()}
  }
  $r=Invoke-WotCycle $f
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "POST 909001,POST 909002,PATCH $script:pinned") 'recovered cycle after failed reads'
  Write-Output 'PASS AC1 failed read: issue, pinned and malformed reads each write nothing (no GitHub write, no state write)'

  # --- AC1: interrupted cycle after assignment before body write converges ---
  $i=New-WotCase 'interrupted' @{909001=@()}
  Add-WotAction $i 'synthetic-i1' 909001 'now'
  Edit-WotFake $i {param($x)$x.crashAfter=@('POST 909001')}
  $r=Invoke-WotCycle $i
  Assert-Wot ($r.err -like 'WAITING_ON_TODD_WRITE_FAILED*' -and ($r.mutations -join ',') -ceq 'POST 909001' -and (Get-WotPending $i) -ceq 'add 909001' -and
    @((Get-WotIssue $i 909001).assignees) -ccontains $script:todd -and (Get-WotIssue $i $script:pinned).body -ceq 'synthetic hand-written body') "interruption not journaled: $($r.err) $(Get-WotPending $i)"
  $r=Invoke-WotCycle $i
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned" -and (Get-WotOwned $i) -ceq '909001' -and (Get-WotPending $i) -ceq '') "interrupted add did not converge: $($r.mutations -join ',') $($r.err)"
  $r=Invoke-WotCycle $i
  Assert-Wot ($null -eq $r.err -and $r.mutations.Count -eq 0) 'converged cycle wrote again'
  $j=New-WotCase 'interrupted-body' @{909001=@()}
  Add-WotAction $j 'synthetic-j1' 909001 'now'
  Edit-WotFake $j {param($x)$x.failOnce=@("PATCH $script:pinned")}
  $r=Invoke-WotCycle $j
  Assert-Wot ($r.err -like 'WAITING_ON_TODD_WRITE_FAILED*' -and (Get-WotOwned $j) -ceq '909001' -and (Get-WotPending $j) -ceq "body $script:pinned") "body interruption not journaled: $($r.err)"
  $r=Invoke-WotCycle $j
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned" -and (Get-WotPending $j) -ceq '' -and (Get-WotIssue $j $script:pinned).body.Contains('synthetic-j1')) "body interruption did not converge: $($r.mutations -join ',')"
  Write-Output 'PASS AC1 interrupted cycle: lost POST response and failed body write each keep an intent and converge next run without a duplicate assignment'

  # Pending remove is retried; an unconfirmed readback keeps the intent.
  $p=New-WotCase 'pending' @{909001=@()}
  Add-WotAction $p 'synthetic-p1' 909001 'now';[void](Invoke-WotCycle $p);Add-WotAction $p 'synthetic-p1' 909001 'done'
  Edit-WotFake $p {param($x)$x.failOnce=@('DELETE 909001')}
  $r=Invoke-WotCycle $p
  Assert-Wot ($r.err -like 'WAITING_ON_TODD_WRITE_FAILED*' -and (Get-WotPending $p) -ceq 'remove 909001' -and (Get-WotOwned $p) -ceq '909001') "remove failure not journaled: $($r.err)"
  $r=Invoke-WotCycle $p
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "DELETE 909001,PATCH $script:pinned" -and (Get-WotOwned $p) -ceq '' -and @((Get-WotIssue $p 909001).assignees).Count -eq 0) "pending remove not retried: $($r.mutations -join ',')"
  Add-WotAction $p 'synthetic-p2' 909001 'now'
  Edit-WotFake $p {param($x)$x.ignoreOnce=@('POST 909001')}
  $r=Invoke-WotCycle $p
  Assert-Wot ($r.err -like 'WAITING_ON_TODD_READBACK_UNCONFIRMED*' -and (Get-WotPending $p) -ceq 'add 909001' -and (Get-WotOwned $p) -ceq '') "unconfirmed readback became ownership: $($r.err)"
  $r=Invoke-WotCycle $p
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "POST 909001,PATCH $script:pinned" -and (Get-WotOwned $p) -ceq '909001') 'unconfirmed add was not re-planned'
  Write-Output 'PASS pending intents: failed remove retried, unconfirmed readback never becomes ownership and is re-planned'

  # Body compare-and-swap on the body only: one-character mismatch and deletion refuse; assignee churn does not.
  $c=New-WotCase 'cas' @{909001=@()}
  Add-WotAction $c 'synthetic-c1' 909001 'later'
  foreach($change in @(@{name='one-char';body='synthetic hand-written bodY'},@{name='deleted';body=$null})){
    Edit-WotFake $c {param($x)$x.getCounts=@{};$x.issues["$script:pinned"].body='synthetic hand-written body';$x.bodyChanges=@(@{issue="$script:pinned";onGet=2;body=$change.body})}
    $r=Invoke-WotCycle $c
    Assert-Wot ($r.err -like 'WAITING_ON_TODD_BODY_CAS_MISMATCH*' -and @($r.mutations|Where-Object{$_ -like 'PATCH *'}).Count -eq 0) "cas/$($change.name) wrote over a moved body: $($r.err) $($r.mutations -join ',')"
  }
  Edit-WotFake $c {param($x)$x.getCounts=@{};$x.issues["$script:pinned"].body='synthetic hand-written body';$x.bodyChanges=@(@{issue="$script:pinned";onGet=2;assignees=@('synthetic-other')})}
  $r=Invoke-WotCycle $c
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned" -and (Get-WotPending $c) -ceq '') "cas blocked on a non-body field: $($r.err)"
  Write-Output 'PASS body CAS: one-character and deleted-body mismatches refuse the write; a non-body field change does not'

  # Ledger, state, config and lock refusals: each writes nothing.
  $l=New-WotCase 'refusals' @{909001=@()}
  Add-WotAction $l 'synthetic-l1' 909001 'now'
  $good=[IO.File]::ReadAllText($l.ledger).Trim()|ConvertFrom-Json -DateKind String
  $mismatch=[ordered]@{ts='2026-10-09T00:00:00Z';kind='Todd-Action';toddActionSchema='todd-action/v2';actionId='Synthetic-L1';issue='909001';state='Now';action=' padded';time="two`nlines";unblocks=('x'*201)}
  foreach($field in @($good.PSObject.Properties.Name)){
    foreach($variant in @('deleted','mismatch')){
      $row=$good.PSObject.Copy()
      if($variant -ceq 'deleted'){$row.PSObject.Properties.Remove($field)}else{$row.$field=$mismatch[$field]}
      [IO.File]::WriteAllText($l.ledger,($row|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
      $before=Get-WotStateBytes $l;$r=Invoke-WotCycle $l
      if($variant -ceq 'deleted' -and $field -ceq 'kind'){
        # A row without kind is not a todd-action row: it is ignored, never
        # trusted, so the unseeded ledger cannot replace the hand-written body.
        Assert-WotRefusal $l $r 'WAITING_ON_TODD_UNSEEDED' $before 'ledger/deleted/kind';continue
      }
      Assert-WotRefusal $l $r 'TODD_ACTION_LEDGER_INVALID' $before "ledger/$variant/$field"
    }
  }
  $extra=$good.PSObject.Copy();$extra|Add-Member -NotePropertyName note -NotePropertyValue 'synthetic extra'
  [IO.File]::WriteAllText($l.ledger,($extra|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
  $before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'TODD_ACTION_LEDGER_INVALID' $before 'ledger/extra-field'
  $rebound=$good.PSObject.Copy();$rebound.issue=909002
  [IO.File]::WriteAllText($l.ledger,(($good|ConvertTo-Json -Compress),($rebound|ConvertTo-Json -Compress) -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
  $before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'TODD_ACTION_ID_CONFLICT' $before 'ledger/rebound-id'
  [IO.File]::WriteAllText($l.ledger,($good|ConvertTo-Json -Compress)+"`n"+'{"kind":"todd-action","ts":',[Text.UTF8Encoding]::new($false))
  $before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'TODD_ACTION_LEDGER_INVALID' $before 'ledger/torn-line'
  Remove-Item -LiteralPath $l.ledger
  $before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'TODD_ACTION_LEDGER_MISSING' $before 'ledger/missing'
  [IO.File]::WriteAllText($l.ledger,($good|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false))
  [void](New-Item -ItemType Directory -Path (Split-Path -Parent $l.state) -Force)
  foreach($bad in @(@{name='unparsable';text='{'},@{name='extra-field';text='{"schema":"waiting-on-todd-state/v1","repo":"synthetic/chase-sets","assignee":"synthetic-todd","owned":[],"pending":[],"x":1}'},
      @{name='bad-intent';text='{"schema":"waiting-on-todd-state/v1","repo":"synthetic/chase-sets","assignee":"synthetic-todd","owned":[],"pending":[{"op":"assign","issue":909001}]}'})){
    [IO.File]::WriteAllText($l.state,$bad.text,[Text.UTF8Encoding]::new($false))
    $before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'WAITING_ON_TODD_STATE_INVALID' $before "state/$($bad.name)"
  }
  [IO.File]::WriteAllText($l.state,'{"schema":"waiting-on-todd-state/v1","repo":"synthetic/other","assignee":"synthetic-todd","owned":[909001],"pending":[]}',[Text.UTF8Encoding]::new($false))
  $before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'WAITING_ON_TODD_STATE_IDENTITY_MISMATCH' $before 'state/identity'
  Remove-Item -LiteralPath $l.state
  $goodConfig=[IO.File]::ReadAllText($l.config)
  foreach($bad in @($goodConfig.Replace('DoneWindowDays = 7','DoneWindowDays = 0'),$goodConfig.Replace("PinnedIssue = $script:pinned;",''),$goodConfig.Replace(' }','; Extra = 1 }'))){
    [IO.File]::WriteAllText($l.config,$bad,[Text.UTF8Encoding]::new($false))
    $before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'WAITING_ON_TODD_CONFIG_INVALID' $before 'config'
  }
  [IO.File]::WriteAllText($l.config,$goodConfig,[Text.UTF8Encoding]::new($false))
  [void](New-Item -ItemType Directory -Path (Split-Path -Parent $l.state) -Force)
  $held=[IO.FileStream]::new("$($l.state).lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
  try{$before=Get-WotStateBytes $l;Assert-WotRefusal $l (Invoke-WotCycle $l) 'WAITING_ON_TODD_BUSY' $before 'lock/busy'}finally{$held.Dispose()}
  $r=Invoke-WotCycle $l
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "POST 909001,PATCH $script:pinned") "refusal fixture did not recover: $($r.err)"
  Write-Output 'PASS fail-closed refusals: every todd-action field deleted or one-field mismatched, extra field, rebound id, torn line, missing ledger, state, identity, config and busy lock write nothing'

  # Adoption guard: an empty ledger never replaces a hand-maintained pinned
  # body; once the body carries the generated marker, an empty ledger renders.
  $u=New-WotCase 'unseeded' @{909001=@()}
  $before=Get-WotStateBytes $u;Assert-WotRefusal $u (Invoke-WotCycle $u) 'WAITING_ON_TODD_UNSEEDED' $before 'unseeded/hand-written'
  Assert-Wot ((Get-WotIssue $u $script:pinned).body -ceq 'synthetic hand-written body') 'unseeded cycle replaced the hand-written body'
  $dryRefusal=Invoke-WotCycle $u -DryRun
  Assert-Wot ($dryRefusal.err -like 'WAITING_ON_TODD_UNSEEDED*' -and $dryRefusal.mutations.Count -eq 0) 'dry run hid the unseeded refusal'
  Add-WotAction $u 'synthetic-u1' 909001 'done'
  $r=Invoke-WotCycle $u
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned") "seeded ledger did not adopt the body: $($r.err)"
  [IO.File]::WriteAllText($u.ledger,'',[Text.UTF8Encoding]::new($false))
  $r=Invoke-WotCycle $u
  Assert-Wot ($null -eq $r.err -and ($r.mutations -join ',') -ceq "PATCH $script:pinned" -and (Get-WotIssue $u $script:pinned).body.Contains('None.')) "generated body was not re-rendered from an empty ledger: $($r.err)"
  Write-Output 'PASS adoption guard: an unseeded ledger refuses (live and dry run) and writes nothing over a hand-written body; a seeded or generated body renders'

  # Rendering escapes table separators so one action can never forge a row.
  . $script:sut -Library
  $piped=[pscustomobject]@{ts='2026-10-09T00:00:00.000Z';kind='todd-action';toddActionSchema='todd-action/v1';actionId='synthetic-pipe';issue=909001;state='now';action='a | b';time='t';unblocks='u'}
  Assert-Wot ((Get-WaitingOnToddBody @($piped) ([datetimeoffset]'2026-10-09T00:00:00Z') 7).Contains('| #909001 | a \| b | t | u |')) 'pipe in action text was not escaped'
  Write-Output 'PASS rendering escapes table separators'
  # AC3 skill contract: the cycle runs the script, section 11 requires the ledger
  # row and the status link, section 14 names the closed variant. Each rule is
  # removed in isolation to prove the check cannot pass vacuously.
  $skillText=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'controller-skills/milestone-orchestrator/SKILL.md')).Replace("`r`n","`n")
  function Get-WotSection([string]$Text,[int]$Number){$m=[regex]::Match($Text,"(?ms)^## $Number\. .*?(?=^## \d+\. |\z)");if($m.Success){$m.Value}else{''}}
  function Compress-WotText([string]$Text){($Text -replace '\s+',' ').Trim()}
  $skillRules=@(
    @(3,'12. Run `waiting-on-todd.ps1` once, in the foreground.'),
    @(3,'log each packaged Todd action change as `todd-action` (§11).'),
    @(11,'link the pinned Waiting-on-Todd issue for packaged operator actions; they never repeat its list inline.'),
    @(11,'`log-event.ps1 -Log dispatch -Kind todd-action -ActionId <id> -Issue <issue> -ActionState now|later|done -Action <step> -ActionTime <estimate> -Unblocks <issues>`'),
    @(11,'The actionId is stable and unique per action; one issue may carry several.'),
    @(11,'The ledger is the only membership source'),
    @(11,'Ambiguous ownership goes to host triage, never to Todd.'),
    @(11,'removes only assignments it made.'),
    @(11,'It also writes nothing while the pinned body is still hand-written and no `todd-action` row exists, so install seeds the current items first.'),
    @(14,'`todd-action/v1` is closed: actionId, issue, state (`now`, `later` or `done`), action, time and unblocks are all required'),
    @(14,'escaped defect, and Todd action.')
  )
  function Test-WotSkill([string]$Text){foreach($rule in $skillRules){if(-not (Compress-WotText (Get-WotSection $Text $rule[0])).Contains((Compress-WotText $rule[1]),[StringComparison]::Ordinal)){return $false}};return $true}
  Assert-Wot (Test-WotSkill $skillText) 'SKILL sections 3, 11 and 14 do not carry the #9228 contract'
  Assert-Wot (-not $skillText.Contains('Status posts list only open priority or scope questions and packaged')) 'status posts still list operator actions inline'
  foreach($rule in $skillRules){
    $pattern=([regex]::Escape($rule[1])) -replace '\\ ','\s+'
    $mutant=[regex]::Replace($skillText,$pattern,'',1)
    Assert-Wot ($mutant -cne $skillText -and -not (Test-WotSkill $mutant)) "skill rule removal survived: $($rule[1])"
  }
  $loggerKinds=[regex]::Match([IO.File]::ReadAllText($script:logger),'(?s)\$canonicalKinds = @\((.*?)\)').Groups[1].Value
  Assert-Wot ($loggerKinds.Contains('"todd-action"')) 'log-event canonical kinds omit todd-action'
  Write-Output "PASS AC3 skill contract: sections 3, 11 and 14 require todd-action and link the pinned issue; $($skillRules.Count) isolated removals each fail"
  Write-Output 'PASS waiting-on-todd AC1/AC2 fixtures (synthetic identities)'
}finally{
  Remove-Item Env:\WOT_FAKE_GH -ErrorAction SilentlyContinue
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if((Split-Path -Parent $resolved).TrimEnd('\','/')-cne$temp-or(Split-Path -Leaf $resolved)-notlike'waiting-on-todd-test-*'){throw 'unsafe waiting-on-todd cleanup root'}
  if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
