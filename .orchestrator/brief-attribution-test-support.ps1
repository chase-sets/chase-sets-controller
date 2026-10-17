# Isolated, unmistakably SYNTHETIC replays of #9339's captured defect shapes.
# Every positive lifecycle/attribution row is emitted by the production logger.
function Test-BriefAttribution([string]$Mode) {
  . (Join-Path (Split-Path -Parent $LauncherPath) 'routing-data.ps1') -Library
  $logger=Join-Path (Split-Path -Parent $LauncherPath) 'log-event.ps1'
  $ledger=Join-Path $runtime 'dispatch-log.jsonl'
  Write-History @()
  function Emit-Dispatch([int]$Issue,[string]$Attempt,[string]$Model,[string]$Role='planning',[string]$Effort='high') {
    $harness=if($Model.StartsWith('claude')){'claude'}else{'codex'}
    & $logger -Log dispatch -Kind dispatch -Issue $Issue -LaneRole $Role -Model $Model -Effort $Effort -Harness $harness -Row 7 -Placement override-Todd `
      -DispatchRoutingSchema watchdog-dispatch-routing/v1 -DispatchAttemptId $Attempt -DispatchLabel $Attempt -Lane $Attempt -Transcript "$Attempt.jsonl" `
      -DispatchWorktree $repo -DispatchBranch 'synthetic-brief' -DispatchHead ('a'*40) -OutFile $ledger -NoBoard | Out-Null
    return Get-BriefRawSha256 (Get-Content $ledger -Tail 1)
  }
  function Target([int]$Issue,[string]$Revision,[string]$Hash=('b'*64),[string]$Artifact='body') {
    return [ordered]@{issue=$Issue;artifact=$Artifact;revision=$Revision;bodySha256=$Hash;observedAt=[DateTimeOffset]::UtcNow.AddMilliseconds(-1).ToString('o')}
  }
  function Declaration([string]$Operation='publication',[bool]$Writing=$true) {
    return [ordered]@{operation=$Operation;originalRowSha256=$null;authors=@();host=@{model='gpt-6.1-sol';effort='high';writing=$Writing};consumed=@();byteProof=$null}
  }
  function Emit($Target,$Attribution,[string]$Report='') {
    $args=@{Log='dispatch';Kind='decision-resolved';Issue=$Target.issue;BriefRevision=($Target|ConvertTo-Json -Depth 20 -Compress);BriefAttribution=($Attribution|ConvertTo-Json -Depth 20 -Compress);OutFile=$ledger;NoBoard=$true}
    if($Report){$args.BriefEvidencePath=$Report}
    & $logger @args | Out-Null
    return Get-BriefRawSha256 (Get-Content $ledger -Tail 1)
  }
  function Author([int]$Issue,[string]$Attempt,[string]$Model,[string]$Dispatch,[string]$Evidence=$Dispatch,$Effort='high') {
    return [ordered]@{issue=$Issue;attemptId=$Attempt;dispatchRawSha256=$Dispatch;evidenceRawSha256=$Evidence;model=$Model;effort=$Effort}
  }
  function Read-BriefFixture([int]$Issue,[string]$Artifact='brief') { return Get-CapacityAuthorHistory -Path $ledger -Issue $Issue -Artifact $Artifact -Registry (Get-RoutingData -ReadOnly).registry }
  function Reject($Target,$Attribution,[string]$Code='BRIEF_ATTRIBUTION_INVALID') {
    $before=[IO.File]::ReadAllBytes($ledger);$message=''
    try { Emit $Target $Attribution | Out-Null } catch { $message=$_.Exception.Message }
    Assert-True ($message.Contains($Code)) "brief refusal $Code observed=$message"
    Assert-True ([Linq.Enumerable]::SequenceEqual($before,[IO.File]::ReadAllBytes($ledger))) 'brief refusal is nonwriting'
  }
  # 30320 shape: an eligible host-written intake cannot be masked by a later
  # read-only dispatch of the same exact model at another effort.
  $t=Target 990339 'SYNTHETIC-intake';$a=Declaration
  $hostFact=Emit $t $a
  $null=Emit-Dispatch 990339 'SYNTHETIC-readonly' 'gpt-6.1-sol' 'review' 'medium'
  $h=Read-BriefFixture 990339
  Assert-True ($h.complete -and $h.models -ccontains 'gpt-6.1-sol') 'eligible host writer survives same-model other-effort masking'
  $bad=Declaration publication $false
  Reject (Target 990339 'SYNTHETIC-false-nonwriting') $bad 'BRIEF_ATTRIBUTION_WRITER_CONFLICT'
  # Omission is a producer refusal, not an implicit empty ancestry declaration.
  $before=[IO.File]::ReadAllBytes($ledger);$message=''
  try { & $logger -Log dispatch -Kind decision-resolved -Issue 990339 -BriefRevision ($t|ConvertTo-Json -Compress) -OutFile $ledger -NoBoard | Out-Null } catch {$message=$_.Exception.Message}
  Assert-True ($message.Contains('BRIEF_ATTRIBUTION_REQUIRED') -and [Linq.Enumerable]::SequenceEqual($before,[IO.File]::ReadAllBytes($ledger))) 'omission refuses without append'
  # An eligible row with neither target identity cannot be isolated to another
  # issue. The producer must share the reader's global incomplete result.
  $identityLines=[IO.File]::ReadAllLines($ledger)
  $unidentified=$identityLines[0]|ConvertFrom-Json -AsHashtable
  $unidentified.Remove('issue');$unidentified.briefRevision.Remove('issue')
  $identityLines[0]=$unidentified|ConvertTo-Json -Depth 20 -Compress
  [IO.File]::WriteAllLines($ledger,$identityLines,[Text.UTF8Encoding]::new($false))
  Assert-True (-not (Read-BriefFixture 990339).complete) 'unidentified eligible row makes reader incomplete'
  Reject (Target 990339 'SYNTHETIC-after-unidentified-row') (Declaration)
  [IO.File]::WriteAllBytes($ledger,$before)
  if ($Mode -ceq 'capacity-logger') { Write-Output 'PASS brief producer required/writer-conflict/nonwriting refusals';return }
  if ($Mode -ceq 'capacity-history') {
    $null=Emit-Dispatch 990338 'SYNTHETIC-legacy-planner' 'gpt-6-astra'
    Assert-True ((Read-BriefFixture 990338).complete -and (Read-BriefFixture 990338).models -ccontains 'gpt-6-astra') 'mixed ledger retains unrelated legacy projection'
    $lines=[IO.File]::ReadAllLines($ledger);$valid=[string[]]$lines.Clone()
    $malformed=$lines[0]|ConvertFrom-Json -AsHashtable;$malformed.Remove('briefAttribution')
    $lines[0]=$malformed|ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllLines($ledger,$lines,[Text.UTF8Encoding]::new($false))
    Assert-True (-not (Read-BriefFixture 990339).complete -and (Read-BriefFixture 990338).complete) 'eligible omission is incomplete without poisoning unrelated legacy'
    [IO.File]::WriteAllLines($ledger,$valid,[Text.UTF8Encoding]::new($false))
    Assert-True ((Read-BriefFixture 990339).complete) 'explicit empty consumed declaration restores the unchanged positive control'
    Write-Output 'PASS brief mixed eligible/legacy/omission history controls';return
  }

  # F1: an eligible intake cannot itself become an overridden original,
  # including when the attempted override names a different artifact key.
  $d=Emit-Dispatch 990339 'SYNTHETIC-override-writer' 'gpt-6-astra'
  $writer=Author 990339 'SYNTHETIC-override-writer' 'gpt-6-astra' $d
  $bodyHash=Get-BriefRawSha256 'SYNTHETIC override body'
  $report=Join-Path $root 'SYNTHETIC-override-writer.report.md'
  [IO.File]::WriteAllText($report,"SYNTHETIC-override-writer gpt-6-astra`nBODY_SHA256: $bodyHash`n")
  $attest=Declaration attestation;$attest.host=$null;$attest.authors=@($writer)
  $attest.byteProof=@{reportSha256=(Get-FileHash $report).Hash.ToLowerInvariant();bodySha256=$bodyHash;attestorDispatchRawSha256=$d}
  $proof=Emit (Target 990339 'SYNTHETIC-override-attested' $bodyHash 'override-probe') $attest $report
  $override=Declaration publication $false;$override.authors=@($writer);$override.byteProof=@{attestationRawSha256=$proof}
  $overrideTarget=Target 990339 'SYNTHETIC-override' $bodyHash 'override-probe'
  $prefix=[IO.File]::ReadAllBytes($ledger)
  $null=Emit $overrideTarget $override
  $overrideRow=Get-Content $ledger -Tail 1|ConvertFrom-Json -AsHashtable
  Assert-True ((Read-BriefFixture 990339).complete) 'F1 unchanged emitted transport control is complete'
  [IO.File]::WriteAllBytes($ledger,$prefix)
  $override.originalRowSha256=$hostFact
  foreach($operation in @('publication','retrospective')) {
    $override.operation=$operation
    Reject $overrideTarget $override 'BRIEF_ATTRIBUTION_INVALID: original is an attribution'
    $h=Read-BriefFixture 990339
    Assert-True ($h.complete -and $h.models -ccontains 'gpt-6.1-sol') "F1 $operation refusal retains eligible Sol intake writer"
    $overrideRow.briefAttribution.originalRowSha256=$hostFact
    $overrideRow.briefAttribution.operation=$operation
    [IO.File]::AppendAllText($ledger,($overrideRow|ConvertTo-Json -Depth 20 -Compress)+"`n")
    Assert-True (-not (Read-BriefFixture 990339).complete) "F1 hand-spliced $operation override is incomplete"
    [IO.File]::WriteAllBytes($ledger,$prefix)
  }
  Write-Output 'PASS F1 attribution originals refuse nonwriting, retain Sol, and hand-spliced rows are incomplete'

  # F2: consuming the latest repaired source inherits its earlier writer,
  # without permitting an extra edge to the now-stale first revision.
  $revisions=@()
  foreach($pair in @(@('claude-opus-5-5','1'),@('gpt-6-astra','2'))) {
    $model=$pair[0];$revision=$pair[1];$attempt="SYNTHETIC-source-r$revision"
    $d=Emit-Dispatch 990911 $attempt $model
    if($revision -ceq '2') {
      & $logger -Log dispatch -Kind lane-complete -Issue 990911 -LaneRole planning -Model gpt-6-astra -Outcome REPAIRED -OutFile $ledger -NoBoard | Out-Null
    }
    $writer=Author 990911 $attempt $model $d
    $bodyHash=$revision*64
    $report=Join-Path $root "$attempt.report.md"
    [IO.File]::WriteAllText($report,"$attempt $model`nBODY_SHA256: $bodyHash`n")
    $attest=Declaration attestation;$attest.host=$null;$attest.authors=@($writer)
    $attest.byteProof=@{reportSha256=(Get-FileHash $report).Hash.ToLowerInvariant();bodySha256=$bodyHash;attestorDispatchRawSha256=$d}
    $proof=Emit (Target 990911 "$attempt-attested" $bodyHash) $attest $report
    $transport=Declaration publication $false;$transport.authors=@($writer);$transport.byteProof=@{attestationRawSha256=$proof}
    $source=Target 990911 $attempt $bodyHash
    $fact=Emit $source $transport
    $revisions+=@{issue=$source.issue;artifact=$source.artifact;revision=$source.revision;bodySha256=$source.bodySha256;attributionRawSha256=$fact}
  }
  $h=Read-BriefFixture 990911
  Assert-True ($h.complete -and $h.models -ccontains 'claude-opus-5-5' -and $h.models -ccontains 'gpt-6-astra' -and $h.models -cnotcontains 'gpt-6.1-sol') 'F2 source retains original and repair writers, not transport host'
  $consumed=Declaration;$consumed.host.model='gpt-6-astra';$consumed.consumed=@($revisions[1])
  $null=Emit (Target 990912 'SYNTHETIC-consumed-latest' ('3'*64)) $consumed
  $h=Read-BriefFixture 990912
  Assert-True ($h.complete -and $h.models -ccontains 'claude-opus-5-5' -and $h.models -ccontains 'gpt-6-astra' -and $h.models -cnotcontains 'gpt-6.1-sol') 'F2 latest consumed revision retains both Opus and Astra writers'
  $consumed.consumed=@($revisions[0])
  Reject (Target 990912 'SYNTHETIC-consumed-stale' ('4'*64)) $consumed 'BRIEF_ATTRIBUTION_INVALID: stale or conflicting edge'
  Write-Output 'PASS F2 latest consumed revision retains Opus and Astra; stale source edge refuses nonwriting'

  # 28189/28202/28218 shape: the Packet was written in implementation lanes.
  # Explicit brief attribution preserves those code roles, all repairs and efforts.
  $authors=@()
  foreach($n in 1..3) {
    $d=Emit-Dispatch 990351 "SYNTHETIC-packet-$n" 'claude-opus-5-5' 'implementation' $(if($n -eq 2){'medium'}else{'high'})
    $authors+=Author 990351 "SYNTHETIC-packet-$n" 'claude-opus-5-5' $d $d $(if($n -eq 2){'medium'}else{'high'})
  }
  $packet=Target 990351 'SYNTHETIC-packet-final' ('c'*64) 'packet'
  $a=Declaration retrospective $false;$a.originalRowSha256=$d;$a.authors=$authors
  $packetFact=Emit $packet $a
  Reject (Target 990351 'SYNTHETIC-packet-duplicate-original' ('c'*64) 'packet') $a 'BRIEF_ATTRIBUTION_INVALID: original already attributed'
  $d=Emit-Dispatch 990359 'SYNTHETIC-ac4-review' 'claude-opus-5-5' 'review'
  & $logger -Log dispatch -Kind lane-complete -Issue 990359 -Lane SYNTHETIC-ac4-review -Model claude-opus-5-5 -Outcome BLOCK_FIXABLE_REPAIRED_IN_BODY -OutFile $ledger -NoBoard | Out-Null
  $repair=Get-BriefRawSha256 (Get-Content $ledger -Tail 1)
  $ac4=Target 990359 'SYNTHETIC-ac4-final' ('d'*64)
  $a=Declaration retrospective $false;$a.originalRowSha256=$repair;$a.authors=@((Author 990359 'SYNTHETIC-ac4-review' 'claude-opus-5-5' $d $repair $null))
  $ac4Fact=Emit $ac4 $a
  $consumer=Target 990337 'SYNTHETIC-consumer'
  $a=Declaration;$a.host.model='gpt-6-astra'
  foreach($pair in @(@($packet,$packetFact),@($ac4,$ac4Fact))) {
    $source=$pair[0];$a.consumed+=@{issue=$source.issue;artifact=$source.artifact;revision=$source.revision;bodySha256=$source.bodySha256;attributionRawSha256=$pair[1]}
  }
  $consumerFact=Emit $consumer $a
  $h=Read-BriefFixture 990337
  Assert-True ($h.complete -and $h.models -ccontains 'claude-opus-5-5' -and $h.models -ccontains 'gpt-6-astra' -and $h.models -cnotcontains 'gpt-6.1-sol') 'explicit Packet/AC4 ancestry adds Opus only'
  $review=@{LaneRole='review';Row=11;Model='gpt-6.1-sol';Effort='high';Placement='provisional';Issue=990337;ReviewArtifact='brief'}
  if ($Mode -ceq 'capacity-roles') { $review.Remove('Model');$review.Remove('Effort');$review.Harness='codex' }
  $p=Plan $review
  Assert-True ($p.capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE' -and $p.routing.model -ceq 'gpt-6.1-sol') 'producer reader resolver retains admitted Sol instead of Opus'
  # 30294 shape is explicit nonwriting participation, not publication.
  & $logger -Log dispatch -Kind decision-resolved -Issue 990337 -Model gpt-6.1-sol -Effort high -Outcome CONTINUE -OutFile $ledger -NoBoard | Out-Null
  $decision=Get-BriefRawSha256 (Get-Content $ledger -Tail 1)
  Assert-True (-not (Read-BriefFixture 990337).complete) 'unattributed legacy host decision remains unknown'
  $nonwriting=Declaration participation $false;$nonwriting.originalRowSha256=$decision
  $null=Emit (Target 990337 'SYNTHETIC-consumer') $nonwriting
  Assert-True ((Read-BriefFixture 990337).complete -and (Read-BriefFixture 990337).models -cnotcontains 'gpt-6.1-sol') '30294 nonwriting is neither author nor unknown without a Sol dispatch'

  # 29838 shape: only the author's report captured before publication binds
  # exact bytes. N18 directly checks classification, not merely model absence.
  $d=Emit-Dispatch 990358 'SYNTHETIC-astra-body' 'gpt-6-astra'
  $writer=Author 990358 'SYNTHETIC-astra-body' 'gpt-6-astra' $d
  $bodyHash=Get-BriefRawSha256 'SYNTHETIC reviewed body'
  $report=Join-Path $root 'SYNTHETIC-astra-body.report.md'
  [IO.File]::WriteAllText($report,"SYNTHETIC-astra-body gpt-6-astra`nBODY_SHA256: $bodyHash`n")
  $attest=Declaration attestation;$attest.host=$null;$attest.authors=@($writer)
  $attest.byteProof=@{reportSha256=(Get-FileHash $report).Hash.ToLowerInvariant();bodySha256=$bodyHash;attestorDispatchRawSha256=$d}
  $attestation=Emit (Target 990358 'SYNTHETIC-reviewed' $bodyHash) $attest $report
  $attestedPrefix=[IO.File]::ReadAllBytes($ledger)
  $bad=$attest|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable;$bad.byteProof.reportSha256='f'*64
  $message='';try { Emit (Target 990358 'SYNTHETIC-unattested' $bodyHash) $bad $report | Out-Null } catch {$message=$_.Exception.Message}
  Assert-True ($message.Contains('BRIEF_ATTRIBUTION_INVALID') -and [Linq.Enumerable]::SequenceEqual($attestedPrefix,[IO.File]::ReadAllBytes($ledger))) 'N19 report bytes must match the attestation before append'
  $publication=Declaration publication $false;$publication.authors=@($writer);$publication.byteProof=@{attestationRawSha256=$attestation}
  # Closed objects are unordered: field order is not writer identity.
  $publication.authors=@([ordered]@{effort=$writer.effort;model=$writer.model;evidenceRawSha256=$writer.evidenceRawSha256;dispatchRawSha256=$writer.dispatchRawSha256;attemptId=$writer.attemptId;issue=$writer.issue})
  $null=Emit (Target 990358 'SYNTHETIC-published' $bodyHash) $publication
  $published=Get-Content $ledger -Tail 1|ConvertFrom-Json -DateKind String
  Assert-True ($published.briefAttribution.host.writing -ceq $false) 'N18 emitted host is explicitly nonwriting'
  Assert-True ((Read-BriefFixture 990358).complete -and (Read-BriefFixture 990358).models -cnotcontains 'gpt-6.1-sol') '29838 exact transport excludes unanchored host from authors'
  Reject (Target 990358 'SYNTHETIC-host-edited' ('e'*64)) $publication 'BRIEF_ATTRIBUTION_WRITER_CONFLICT'
  $bad=$publication|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable;$bad.host.writing=$true
  Reject (Target 990358 'SYNTHETIC-wrong-writer' $bodyHash) $bad 'BRIEF_ATTRIBUTION_WRITER_CONFLICT'
  Reject (Target 990358 'SYNTHETIC-omitted-match' $bodyHash) (Declaration) 'BRIEF_ATTRIBUTION_WRITER_CONFLICT'
  $code=Read-BriefFixture 990337 code
  Assert-True ($code.complete -and $code.models -cnotcontains 'claude-opus-5-5') 'brief edges do not recast consumed authors as code authors'
  $sibling=Target 990338 'SYNTHETIC-sibling';$null=Emit $sibling (Declaration)
  Assert-True ((Read-BriefFixture 990338).models -cnotcontains 'claude-opus-5-5') 'unrelated sibling gets no edge traversal'

  $valid=[IO.File]::ReadAllBytes($ledger)
  $validLines=[IO.File]::ReadAllLines($ledger)
  $publicationLine=-1
  for($i=0;$i -lt $validLines.Count;$i++) {
    $r=$validLines[$i]|ConvertFrom-Json -DateKind String
    if($r.issue -eq 990358 -and $r.briefAttribution.operation -ceq 'publication'){$publicationLine=$i}
  }
  Assert-True ($publicationLine -ge 0 -and (Read-BriefFixture 990358).complete) 'reader-negative unchanged control is complete'
  foreach($mutation in @('source','hash','revision','nested','type','cycle','future','past','original')) {
    $bad=$a|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
    $t=Target 990337 "SYNTHETIC-negative-$mutation"
    switch($mutation) {
      source {$bad.consumed[0].attributionRawSha256='f'*64}
      hash {$bad.consumed[0].bodySha256='f'*64}
      revision {$bad.consumed[0].revision='SYNTHETIC-wrong'}
      nested {$bad.consumed[0].extra='SYNTHETIC-extra'}
      type {$bad.consumed[0].issue=[string]$bad.consumed[0].issue}
      cycle {$bad.consumed[0]=@{issue=990337;artifact='body';revision=$consumer.revision;bodySha256=$consumer.bodySha256;attributionRawSha256=$consumerFact}}
      future {$t.observedAt=[DateTimeOffset]::UtcNow.AddDays(1).ToString('o')}
      past {$t.observedAt='2000-01-01T00:00:00Z'}
      original {$bad.originalRowSha256=$repair}
    }
    Reject $t $bad
  }
  $authorControl=Declaration retrospective $false
  $authorControl.originalRowSha256=$authors[0].dispatchRawSha256
  $authorControl.authors=@($authors[0])
  $authorTarget=Target 990351 'SYNTHETIC-author-control'
  $null=Emit $authorTarget $authorControl
  [IO.File]::WriteAllBytes($ledger,$valid)
  foreach($field in @('model','effort','dispatchRawSha256','evidenceRawSha256')) {
    $bad=$authorControl|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
    $bad.authors[0][$field]=switch($field){model {'gpt-6.1-sol'} effort {'medium'} default {'f'*64}}
    Reject $authorTarget $bad
  }
  # A cycle across revisions is still a cycle despite causal append order.
  $cycle=Declaration;$cycle.consumed=@(@{issue=990337;artifact='body';revision=$consumer.revision;bodySha256=$consumer.bodySha256;attributionRawSha256=$consumerFact})
  Reject (Target 990351 'SYNTHETIC-packet-cycle' ('c'*64) 'packet') $cycle
  # Corrupt emitted bytes only for negative reader controls. No positive row
  # is hand-authored, and the valid emitted prefix is restored for each case.
  foreach($mutation in @('missing','empty-target','extra','partial','truncated','duplicate','date-only','missing-issue','wrong-issue','missing-marker','unknown-schema','array-schema','array-kind','array-operation','array-hash')) {
    $negative=$published|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable
    switch($mutation) {
      missing {$negative.Remove('briefAttribution')}
      empty-target {$negative.briefRevision=$null}
      extra {$negative.briefAttribution.host.extra=$true}
      partial {$negative.partial=$true}
      truncated {$negative.truncated=$true}
      date-only {$negative.briefRevision.observedAt='2026-10-11'}
      missing-issue {$negative.Remove('issue')}
      wrong-issue {$negative.issue=990359}
      missing-marker {$negative.Remove('briefSchema')}
      unknown-schema {$negative.briefSchema='brief-attribution/v999'}
      array-schema {$negative.briefSchema=@('brief-attribution/v1')}
      array-kind {$negative.kind=@('decision-resolved')}
      array-operation {$negative.briefAttribution.operation=@('publication')}
      array-hash {$negative.briefRevision.bodySha256=@($bodyHash)}
    }
    $line=$negative|ConvertTo-Json -Compress -Depth 20
    if($mutation -eq 'duplicate'){$line=$line.Replace('"writing":false','"writing":false,"writing":true')}
    $negativeLines=[string[]]$validLines.Clone();$negativeLines[$publicationLine]=$line
    [IO.File]::WriteAllLines($ledger,$negativeLines,[Text.UTF8Encoding]::new($false))
    Assert-True (-not (Read-BriefFixture 990358).complete) "reader fails closed for $mutation eligible bytes"
  }
  [IO.File]::WriteAllBytes($ledger,$valid)
  [IO.File]::AppendAllText($ledger,'{"briefSchema":')
  Assert-True (-not (Read-BriefFixture 990337).complete) 'unterminated ledger cannot prove absent authors'
  [IO.File]::WriteAllBytes($ledger,$valid)
  $mover=[PowerShell]::Create()
  $moving=[Threading.ManualResetEventSlim]::new($false)
  $stopMoving=[Threading.ManualResetEventSlim]::new($false)
  try {
    # A same-process runspace changes the file during a sufficiently long read;
    # it is awaited here and never launches a worker, verifier or model.
    $padding=@(1..500|ForEach-Object{'{"kind":"decision-resolved","issue":999999}'})
    [IO.File]::AppendAllLines($ledger,[string[]]$padding)
    [void]$mover.AddScript('param($p,$started,$stop) $n=0; $started.Set(); while(-not $stop.IsSet){ [IO.File]::SetLastWriteTimeUtc($p,[datetime]::UtcNow.AddSeconds(++$n)); [Threading.Thread]::Sleep(1) }').AddArgument($ledger).AddArgument($moving).AddArgument($stopMoving)
    $pending=$mover.BeginInvoke()
    $moving.Wait()
    Assert-True (-not (Read-BriefFixture 990337).complete) 'moving complete ledger fails closed'
    $stopMoving.Set()
    [void]$mover.EndInvoke($pending)
    Assert-True (-not $mover.HadErrors) 'moving-ledger probe completed without a tooling error'
  } finally { $stopMoving.Set();if($pending -and -not $pending.IsCompleted){[void]$mover.EndInvoke($pending)};$mover.Dispose();$moving.Dispose();$stopMoving.Dispose() }
  [IO.File]::WriteAllBytes($ledger,$valid)
  & $logger -Log dispatch -Kind lane-complete -Issue 990337 -LaneRole planning -Model gpt-6-astra -Outcome REPAIRED -OutFile $ledger -NoBoard | Out-Null
  Assert-True (-not (Read-BriefFixture 990337).complete) 'later repair invalidates stale latest declaration'
  $fresh=Declaration;$fresh.host.model='gpt-6-astra';$fresh.consumed=$a.consumed
  $null=Emit (Target 990337 'SYNTHETIC-after-repair') $fresh
  Assert-True ((Read-BriefFixture 990337).complete -and (Read-BriefFixture 990337).models -ccontains 'claude-opus-5-5') 'fresh repair revision restores completeness without erasing authors'
  if ($Mode -ceq 'capacity-roles') {
    $capture=Get-Content (Join-Path $PSScriptRoot 'fixtures/brief-attribution-9339.json') -Raw | ConvertFrom-Json -DateKind String
    $raw=@{};$captured=@{}
    foreach($item in $capture.rows) {$raw[[int]$item.line]=$item.raw;$captured[[int]$item.line]=$item.raw|ConvertFrom-Json -DateKind String}
    function Captured-Author([int]$Dispatch,[int]$Evidence=$Dispatch) {
      $d=$captured[$Dispatch];$e=$captured[$Evidence]
      return Author $d.issue $d.attemptId $d.model (Get-BriefRawSha256 $raw[$Dispatch]) (Get-BriefRawSha256 $raw[$Evidence]) (Get-BriefEffort $e)
    }
    function Captured-Target([int]$Line,[string]$Revision,[string]$Hash,[string]$Artifact='body') {
      $t=Target $captured[$Line].issue $Revision $Hash $Artifact;$t.observedAt=$captured[$Line].ts;return $t
    }
    # Retained original bytes, not fabricated historical facts. The fixtures
    # are a named issue/source slice, not a replacement canonical ledger.
    [IO.File]::WriteAllLines($ledger,@($capture.rows|Where-Object{$_.line -lt 30294}|ForEach-Object raw),[Text.UTF8Encoding]::new($false))
    $baseline=Read-BriefFixture 9337
    Assert-True ($baseline.complete -and $baseline.models.Count -eq 1 -and $baseline.models[0] -ceq 'gpt-6-astra') 'captured pre-30294 legacy projection is unchanged'
    $review.Issue=9337
    Assert-True ((Plan $review).routing.model -ceq 'claude-opus-5-5') 'captured baseline discriminates actual erroneous Opus flip'
    $packet=Captured-Target 28218 'comment-6031379240' '5f04881559abba510866a6eccc1de05df2f00a98b4647dd346a5686b5d215eaf' 'packet'
    $packet.observedAt='2026-10-07T05:10:25Z'
    $a=Declaration retrospective $false;$a.originalRowSha256=Get-BriefRawSha256 $raw[28218]
    $a.authors=@((Captured-Author 28189),(Captured-Author 28202 28209),(Captured-Author 28218))
    $packetFact=Emit $packet $a
    $ac4=Captured-Target 29718 'publication-25731216' '2573121668888d0ed7f7646b97b1d85fc44bd1108125bc9d87823bcecb3916af'
    $a=Declaration retrospective $false;$a.originalRowSha256=Get-BriefRawSha256 $raw[29718];$a.authors=@((Captured-Author 29711 29718))
    $ac4Fact=Emit $ac4 $a
    # Prospective capture binding: observed now; not a backdated publication.
    $t=Target 9337 'captured-bfc1cec6' 'bfc1cec6ca8d20696beca911061fc862d0f051ff76732617acdd8bb33b4d6c6c'
    $a=Declaration retrospective $false;$a.originalRowSha256=Get-BriefRawSha256 $raw[30285];$a.authors=@((Captured-Author 30285))
    foreach($pair in @(@($packet,$packetFact),@($ac4,$ac4Fact))) {
      $s=$pair[0];$a.consumed+=@{issue=$s.issue;artifact=$s.artifact;revision=$s.revision;bodySha256=$s.bodySha256;attributionRawSha256=$pair[1]}
    }
    $null=Emit $t $a
    $p=Plan $review
    Assert-True ($p.capacityFlipSkip -ceq 'REVIEWER_INDEPENDENCE' -and $p.routing.model -ceq 'gpt-6.1-sol') 'captured Packet plus AC4 excludes Opus and retains Sol'
    $h=Read-BriefFixture 9337
    Assert-True ($h.models -ccontains 'claude-opus-5-5' -and $h.models -cnotcontains 'gpt-6.1-sol') 'verbatim 29750 anomaly does not add Sol to consumed 9259 brief'
    $bad=Declaration retrospective $false;$bad.originalRowSha256=Get-BriefRawSha256 $raw[29750]
    $bad.authors=@((Captured-Author 29722 29750))
    Reject (Target 9259 'conflicting-9259-impl-g1') $bad
    [IO.File]::AppendAllText($ledger,$raw[30294]+"`n")
    Assert-True (-not (Read-BriefFixture 9337).complete) 'captured 30294 before Sol dispatch is legacy unknown'
    $a=Declaration participation $false;$a.originalRowSha256=Get-BriefRawSha256 $raw[30294]
    $null=Emit (Target 9337 $t.revision $t.bodySha256) $a
    Assert-True ((Read-BriefFixture 9337).complete -and (Read-BriefFixture 9337).models -cnotcontains 'gpt-6.1-sol') 'captured 30294 is explicitly nonwriting'
    [IO.File]::AppendAllText($ledger,$raw[30317]+"`n"+$raw[30320]+"`n")
    $t=Captured-Target 30320 'intake-c6758c28' 'c6758c2883556775665e2bf147d22829c5138655eafab30a6e33078df3f377f0'
    $a=Declaration retrospective;$a.originalRowSha256=Get-BriefRawSha256 $raw[30320]
    $null=Emit $t $a
    $null=Emit-Dispatch 9339 'SYNTHETIC-after-captured-intake' 'gpt-6.1-sol' 'review' 'medium'
    Assert-True ((Read-BriefFixture 9339).models -ccontains 'gpt-6.1-sol') 'captured 30320 intake writer cannot be masked'
    # The original dispatch AND report name Opus, not Astra as the brief says.
    # Preserve this discovered historical fact; Astra transport is tested above
    # using synthetic identities. Do not relabel real row 29824.
    $bodyHash='8c3e26aa9cbbf59e0dff529ad60c52047cf1d67378fc75460344aac5a21e6967'
    $report=Join-Path $PSScriptRoot 'fixtures/brief-attribution-9258-report.txt'
    Assert-True ((Get-FileHash $report).Hash.ToLowerInvariant() -ceq 'a2b1848ef6e1e9d0dd064c150fce0fe96e3c7095757136625f8c50fe7fb873b3') 'captured author report bytes are immutable across checkout'
    $a=Declaration attestation;$a.host=$null;$a.authors=@((Captured-Author 29824 29832))
    $a.byteProof=@{reportSha256=(Get-FileHash $report).Hash.ToLowerInvariant();bodySha256=$bodyHash;attestorDispatchRawSha256=Get-BriefRawSha256 $raw[29824]}
    $proof=Emit (Captured-Target 29832 'report-8c3e26aa' $bodyHash) $a $report
    $a.operation='retrospective';$a.host=@{model='gpt-6.1-sol';effort='high';writing=$false}
    $a.originalRowSha256=Get-BriefRawSha256 $raw[29838];$a.byteProof=@{attestationRawSha256=$proof}
    $null=Emit (Captured-Target 29838 'publication-8c3e26aa' $bodyHash) $a
    Assert-True ((Read-BriefFixture 9258).complete -and (Read-BriefFixture 9258).models -cnotcontains 'gpt-6.1-sol') 'captured 29838 byte transport retains actual Opus author and Sol nonwriting'
    Assert-True ((Get-Content $ledger -Tail 1|ConvertFrom-Json).briefAttribution.host.writing -ceq $false) 'captured transport directly asserts nonwriting'
    Write-Output 'PASS captured 9337/30294/30320/29838 and immutable 29750 controls'
  }
  Write-Output "PASS brief attribution producer-to-reader-to-resolver $Mode"
}
