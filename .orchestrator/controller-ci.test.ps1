$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'controller-ci.ps1') -Mode Library
function Refuses([scriptblock]$Body) {
  $refused=$false
  try { & $Body | Out-Null } catch { $refused=$true }
  Assert-Ci $refused 'negative control accepted'
}
$inventory = @(0..22 | ForEach-Object { [pscustomobject]@{identity="test:fixture-$_.ps1";restriction=$null} })
$selected = New-CiAssignments $inventory ''
Assert-Ci ($selected.Count -eq 23 -and @($selected | Group-Object shard).Count -eq 10) 'ten-way assignment'
Refuses { New-CiAssignments $inventory 'missing' }
Refuses { New-CiAssignments $inventory 'test:fixture-1.ps1,test:fixture-1.ps1' }
$plan = @{controllerHead=('a'*40);checkoutHead=('b'*40);productSha=('c'*40);planSha256=('d'*64);selected=$selected}
$parts = @(0..9 | ForEach-Object {
  $number=$_
  @{schemaVersion='controller-ci-shard/v1';shard=$number;controllerHead=$plan.controllerHead;checkoutHead=$plan.checkoutHead
    productSha=$plan.productSha;planSha256=$plan.planSha256
    results=@($selected | Where-Object shard -EQ $number | ForEach-Object { @{identity=$_.identity;result='PASS';exitCode=0} })}
})
$merged = Merge-CiResults $plan $parts
Assert-Ci ($merged.Count -eq 23) 'complete merge'
Refuses { Merge-CiResults $plan $parts[0..8] }
$parts[0].planSha256='wrong'
Refuses { Merge-CiResults $plan $parts }
$parts[0].planSha256=$plan.planSha256
$parts[0].results[0].exitCode=1
Refuses { Merge-CiResults $plan $parts }
$parts[0].results[0].exitCode=0
$parts[0].results[0].result='LOCAL_ONLY';$parts[0].results[0].exitCode=125
Refuses { Merge-CiResults $plan $parts }
$selected[0].restriction=@{classification='LOCAL_ONLY';reason='synthetic host-only fixture'}
$merged = Merge-CiResults $plan $parts
Assert-Ci ($merged.Count -eq 23 -and @($merged | Where-Object result -CEQ 'LOCAL_ONLY').Count -eq 1) 'explicit local-only merge'
$parts[0].results[0].identity='test:extra.ps1'
Refuses { Merge-CiResults $plan $parts }
Write-Output 'PASS controller CI assignment, missing/duplicate/extra identities, digest, exit/result and exclusion controls'
