$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'issue-6254-fail-closed-guard-evidence.test.ps1'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$errors)
if($errors.Count){throw 'production discriminator parse failed'}
$calls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'New-ProductionClaim'},$true))
if($calls.Count -ne 2){throw 'ASSERTION FAILED: production claim call inventory changed'}
foreach($call in $calls) {
  if($call.CommandElements.Count -ne 3 -or $call.CommandElements[2].Extent.Text -cne '$candidateBlob') {
    throw 'ASSERTION FAILED: every production claim must receive the measured candidate blob'
  }
}
foreach($name in @('Copy-Value','Insert-ProductionPointer','New-ProductionClaim')) {
  $f=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true)
  if(-not $f){throw "production function missing: $name"}
  Invoke-Expression $f.Extent.Text
}
$root=Split-Path -Parent $PSScriptRoot
$blob=(& git -C $root hash-object -- '.orchestrator/landing-preflight.ps1').Trim()
if($LASTEXITCODE -ne 0 -or $blob -cnotmatch '^[a-f0-9]{40}$'){throw 'measured candidate blob unavailable'}
$mutation=[pscustomobject]@{guardId='LP-B1-B2-EVENT-ORDER';mutantId='B1-B2'}
foreach($expected in @($blob,('b'*40))) {
  $claim=New-ProductionClaim $mutation $expected
  foreach($actual in @($claim.preservedVariables.productionBlob,$claim.candidate.inputs.productionBlob,$claim.bypassMutant.inputs.productionBlob)) {
    if($actual -cne $expected){throw "ASSERTION FAILED: claim productionBlob must bind measured input expected=$expected actual=$actual"}
  }
}
$failed=$false
try{New-ProductionClaim $mutation 'not-a-blob'|Out-Null}catch{$failed=$true}
if(-not $failed){throw 'ASSERTION FAILED: malformed production blob must refuse'}
Write-Output 'PASS production claim provenance measured/sibling blob preserved, invalid blob refused'
