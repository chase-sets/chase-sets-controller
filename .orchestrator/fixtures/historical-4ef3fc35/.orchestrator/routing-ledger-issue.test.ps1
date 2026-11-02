$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'dispatch-ownership.ps1')
Import-Module (Join-Path $PSScriptRoot 'landed-integration-evidence.psm1') -Force -DisableNameChecking
$module=Get-Module landed-integration-evidence
$assertions=0
# Exercise the actual key-selection statements at every closed routing reader.
# All rows are synthetic; no ownership, process, history or fleet read occurs.
foreach($file in @('integration-dispatch-contract.ps1','landed-integration-evidence.psm1','lane-stall-watchdog.ps1')){
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw "parse failed: $file"}
  $calls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-DispatchRoutingLedgerKeys'},$true))
  $expected=if($file -ceq 'lane-stall-watchdog.ps1'){1}else{2}
  if($calls.Count -ne $expected){throw "reader inventory changed: $file"}
  foreach($call in $calls){
    foreach($schema in @('watchdog-dispatch-routing/v1','watchdog-dispatch-routing/v2','watchdog-dispatch-routing/v3')){
      foreach($case in @('absent','positive','zero','negative','overflow','boolean','string','fraction','null','extra-key')){
        $row=[ordered]@{ts='2026-10-03T00:00:00Z';kind='dispatch';dispatchRoutingSchema=$schema;attemptId='synthetic-attempt';label='synthetic-label';lane='synthetic-lane';laneRole='implementation';transcript='synthetic.jsonl';harness='codex';model='gpt-6-astra';effort='high';row=7;placement='override-Todd';worktree='D:\synthetic';branch='synthetic/branch';head=('a'*40)}
        if(-not $schema.EndsWith('/v1')){foreach($entry in @{policyGeneration=1L;registryAuthorityDigest='synthetic';family='astra';slot='explicit';usedLastKnownGood=$false}.GetEnumerator()){$row[$entry.Key]=$entry.Value}}
        if($schema.EndsWith('/v3')){foreach($entry in @{capacityForecastStatus='not-evaluated';capacityDecisionDigest=$null;capacityFlip=$null;capacityShadowFlip=$null;capacityFlipSkip=$null}.GetEnumerator()){$row[$entry.Key]=$entry.Value}}
        switch($case){
          positive {$row.issue=908526L}
          zero {$row.issue=0L}
          negative {$row.issue=-1L}
          overflow {$row.issue=[long][int]::MaxValue+1L}
          boolean {$row.issue=$true}
          string {$row.issue='908526'}
          fraction {$row.issue=1.5}
          null {$row.issue=$null}
          'extra-key' {$row.issue=908526L;$row.unrecognized=$true}
        }
        $route=$r=$value=[pscustomobject]$row
        $accepted=$false
        try {
          $keys=@(& ([scriptblock]::Create($call.Extent.Text)))
          & $module {param($Record,$Keys) Assert-RebaseKeys $Record $Keys} $route $keys
          $accepted=Test-DispatchRoutingLedgerEvidence $route
        } catch { $accepted=$false }
        $wanted=$case -in @('absent','positive')
        if($accepted -ne $wanted){throw "FAIL routing issue $file line=$($call.Extent.StartLineNumber) $schema/$case accepted=$accepted expected=$wanted"}
        $assertions++
      }
    }
    Write-Output "PASS routing issue reader $file line=$($call.Extent.StartLineNumber): absent/present and malformed closed-row controls"
  }
}
Write-Output "PASS routing-ledger-issue assertions=$assertions"
