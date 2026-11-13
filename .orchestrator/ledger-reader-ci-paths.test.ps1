$ErrorActionPreference='Stop'
function Assert-CiPath([bool]$Condition,[string]$Message) {
  if (-not $Condition) { throw $Message }
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-ci-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $json='{"schemaVersion":"controller-ci-durations/v1","records":[],"shardCount":18}'
  $receipt=Join-Path $root 'plan.json'
  [IO.File]::WriteAllText($receipt,$json)
  [IO.File]::WriteAllText((Join-Path $root 'controller-ci-parts.json'),$json)
  $source=Join-Path $root 'synthetic.test.ps1'
  [IO.File]::WriteAllText($source,"# source fixture`r`nWrite-Output 'fixture'`r`n")
  $expected=[ordered]@{
    'controller-ci-planning.ps1'=@('$Path','$Path')
    'controller-ci-prediction.ps1'=@('$CalibrationPlanPath',"(Join-Path `$PSScriptRoot 'controller-ci-parts.json')")
    'controller-ci-record-durations.ps1'=@('$RecordPlanPath','$ResultPath')
    'controller-ci.ps1'=@('$manifestPath','$PlanPath','$_.FullName')
  }
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $dynamicCount=0
  foreach($file in $expected.Keys) {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
    Assert-CiPath ($errors.Count -eq 0) "parse failed: $file"
    $imports=@($ast.EndBlock.Statements | Where-Object { $_.Extent.Text -ceq $import })
    Assert-CiPath ($imports.Count -eq 1) "missing unconditional exact owner import: $file"
    $reads=@($ast.FindAll({param($node)
      ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Content') -or
      ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $node.Member.Value -ceq 'ReadAllText')
    },$true))
    Assert-CiPath ($reads.Count -eq $expected[$file].Count) "native read census changed: $file"
    for($index=0;$index -lt $reads.Count;$index++) {
      $read=$reads[$index]
      $original=$expected[$file][$index]
      $wrapper="(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $original)"
      Assert-CiPath ($read.Extent.Text.Contains($wrapper,[StringComparison]::Ordinal)) "unfrozen original path: ${file}:$($read.Extent.StartLineNumber)"
      Assert-CiPath ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "late owner import: $file"
      $isSource=$file -ceq 'controller-ci-planning.ps1' -and $index -eq 0
      $positive=if($isSource){$source}else{$receipt}
      # Evaluate only the production native expression and import, never CI's
      # orchestration, Git, shard launch, evidence writer or live commands.
      $probe=Join-Path $root 'probe.ps1'
      $bindings='$Path=$CalibrationPlanPath=$RecordPlanPath=$ResultPath=$manifestPath=$PlanPath=$InputPath; $_=[pscustomobject]@{FullName=$InputPath}'
      [IO.File]::WriteAllText($probe,('param([string]$InputPath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
      $actual=& $probe -InputPath $positive
      $wanted=if($isSource){[IO.File]::ReadAllText($source)}else{$json}
      Assert-CiPath ($actual -ceq $wanted) "positive native bytes changed: ${file}:$($read.Extent.StartLineNumber)"
      if($original.StartsWith('(Join-Path')) { continue } # Fixed literal, not a dynamic census candidate.
      $dynamicCount++
      foreach($alias in @('dispatch-log.jsonl','DISPATCH-LOG.JSONL','dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:receipt','dispatch-log.jsonl.:receipt')) {
        $path=Join-Path $root $alias
        $failure=$null
        try { & $probe -InputPath $path | Out-Null } catch { $failure=$_.Exception.Message }
        Assert-CiPath ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "native read preceded refusal: ${file}:$($read.Extent.StartLineNumber) alias=$alias failure=$failure"
      }
    }
  }
  Assert-CiPath ($dynamicCount -eq 8) 'expected eight dynamic census candidates'
  . (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
  Assert-CiPath ((Read-CiTimingProfile $receipt).shardCount -eq 18) 'profile JSON behavior changed'
  Assert-CiPath ($null -eq (Read-CiTimingProfile (Join-Path $root 'missing.json'))) 'missing profile behavior changed'
  $malformed=Join-Path $root 'malformed.json';[IO.File]::WriteAllText($malformed,'{')
  Assert-CiPath ($null -eq (Read-CiTimingProfile $malformed)) 'malformed profile behavior changed'
  $dispatch=Join-Path $root 'dispatch-log.jsonl';[IO.File]::WriteAllText($dispatch,$json)
  Assert-CiPath ($null -eq (Read-CiTimingProfile $dispatch)) 'profile catch policy changed'
  $normalized=[IO.File]::ReadAllText($source).Replace("`r`n","`n")
  $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($normalized))).ToLowerInvariant()
  Assert-CiPath ((Get-CiSourceDigest $source) -ceq $digest) 'source digest normalization changed'
  Write-Output 'PASS CI paths: eight dynamic reads, fixed manifest read, four imports, six dispatch aliases per dynamic read, native source/JSON and profile error policies'
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'ledger-ci-paths-*') { throw 'unsafe fixture cleanup' }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
