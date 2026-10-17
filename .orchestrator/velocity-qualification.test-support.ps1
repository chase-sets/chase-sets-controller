# Frozen synthetic authority only. Never use a real issue/run/reviewer identity.
function New-SyntheticVelocityDispatchIssue($Issue) {
  $m=$Issue.milestone
  if($null -eq $m){return $null}
  $description='<!-- outcome: {"version":1,"track":"'+(Get-VelocityValue $m 'track' '')+'","order":100,"status":"'+$(if($m.committed){'committed'}else{'candidate'})+'"} -->'
  [pscustomobject]@{repository='synthetic/velocity';number=$Issue.number;nodeId="SYNTHETIC_ISSUE_$($Issue.number)";
    updatedAt='2026-09-01T00:00:00Z';state='open';body='Synthetic current brief';issueTypeName='Slice';
    labels=@(@('priority:p1','area:catalog','kind:product') | ForEach-Object {[pscustomobject]@{name=$_}});
    blockedBy=@(if($Issue.openBlockers -gt 0){[pscustomobject]@{state='open'}});
    milestone=[pscustomobject]@{id="SYNTHETIC_MILESTONE_$($m.number)";number=$m.number;title='Synthetic committed outcome';description=$description;state=$m.state.ToLowerInvariant()}}
}
function New-SyntheticVelocityQualification($Issue) {
  $i=$Issue.dispatchIssue
  $revision=[pscustomobject]@{repository=$i.repository;number=$i.number;nodeId=$i.nodeId;updatedAt=$i.updatedAt;milestone=$i.milestone;
    bodySha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($i.body))).ToLowerInvariant()}
  $subject=[pscustomobject]@{repository=$i.repository;number=$i.number;nodeId=$i.nodeId;updatedAt=$i.updatedAt}
  $coverage={param($n) [pscustomobject]@{pages=1;collected=$n;total=$n;complete=$true;reasonCode=$null}}
  $receipt=[pscustomobject]@{schemaVersion='issue-readiness/v1';claim='structural-only';status='ready';subject=$subject;
    facts=[pscustomobject]@{state='open';issueType=[pscustomobject]@{nodeId='SYNTHETIC_SLICE';name='Slice';isEnabled=$true};milestone=$i.milestone;
      labels=@($i.labels.name);hasParent=$false;parentNumber=$null;dependencies=@()};
    checkedRules=@(@('ready-00-placed-classified','ready-00-dependencies-resolved','ready-01-repo-evidence','ready-02-explicit-non-goal',
      'ready-03-acceptance-evidence','ready-04-runnable-verification','ready-05-footprint-operators','ready-06-decisions-resolved',
      'ready-07-terms-declared','ready-08-authority-probe-timed','ready-09-review-packet')|ForEach-Object{[pscustomobject]@{id=$_;status='pass';reasonCodes=@()}});
    reasonCodes=@();coverage=[pscustomobject]@{authorityComplete=$true;issue=[pscustomobject]@{initialRead=$true;finalRead=$true;revisionStable=$true};
      labels=(&$coverage 3);dependencies=(&$coverage 0);comments=(&$coverage 0);form=[pscustomobject]@{parsed=$true;complete=$true}};
    provenance=[pscustomobject]@{checkedAt='2026-09-01T00:01:00Z';checkerSha=('a'*40);apiVersion='2022-11-28';collector='github-rest-plus-graphql'};semanticPressureTest='not-evaluated'}
  [pscustomobject]@{issue=$i.number;readiness=[pscustomobject]@{source='trusted-workflow-artifact';repository=$i.repository;
    workflowPath='.github/workflows/issue-readiness.yml';runId=900000001;artifactName="issue-readiness-$($i.number)-900000001";
    conclusion='success';completedAt='2026-09-01T00:02:00Z';trustedCheckerSha=('a'*40);run=[pscustomobject]@{schemaVersion='issue-readiness-run/v1';receipt=$receipt}};
    semantic=[pscustomobject]@{outcome='PASS';completeSweep=$true;reportIdentity="synthetic-independent-review-$($i.number)";
      authorIdentity='synthetic-author';reviewerIdentity='synthetic-independent-reviewer';subject=$revision;completedAt='2026-09-01T00:03:00Z'};
    prerequisites=[pscustomobject]@{state='resolved';subject=$revision};
    admission=[pscustomobject]@{source='section-4';decision='admitted';mode='window';subject=$revision;
      evidenceIdentity="synthetic-section-4-$($i.number)";evaluatedAt='2026-09-01T00:04:00Z'}}
}
function Set-SyntheticVelocityQualification($Facts) {
  $candidates=@($Facts.productIssues|ForEach-Object{
    if($null -eq $_.PSObject.Properties['dispatchIssue']){$_|Add-Member dispatchIssue (New-SyntheticVelocityDispatchIssue $_)}
    if($null -ne $_.dispatchIssue){New-SyntheticVelocityQualification $_}
  })
  $Facts|Add-Member dispatchQualificationSource ([pscustomobject]@{kind='considered-candidate-dispatch';candidates=$candidates}) -Force
  return $Facts
}
