$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-install-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $expected=[ordered]@{
    'install-controller-skills.ps1'=@('$SourcePath','$DestinationPath','$recordPath','$milestoneSkillPath',
      '$source','$helperPath','$identityDestination','$helperDestination','$helperDestination','$destination','$destination')
    'controller-install-lock.psm1'=@('$ownerPath','$ClaimPath')
    'check-controller-skill-freshness.ps1'=@('$Path','$markerPath','$releaseRecord')
  }
  $asts=@{}
  $json='{"synthetic":true,"schemaVersion":1}'
  $positive=Join-Path $root 'metadata.json'
  [IO.File]::WriteAllText($positive,$json)
  $bytes=[Text.Encoding]::UTF8.GetBytes($json)
  $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:synthetic','dispatch-log.jsonl.:synthetic')
  $readCount=0
  foreach($file in $expected.Keys){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
    $asts[$file]=$ast
    Check ($errors.Count -eq 0) "parse $file"
    $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
    Check ($imports.Count -eq 1) "literal unconditional owner import: $file"
    $reads=@($ast.FindAll({param($node)
      ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -cin @('Get-Content','Get-FileHash')) -or
      ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -cin @('ReadAllBytes','Open'))
    },$true))
    Check ($reads.Count -eq $expected[$file].Count) "native path census: $file"
    for($index=0;$index -lt $reads.Count;$index++){
      $read=$reads[$index];$original=$expected[$file][$index];$readCount++
      Check ($read.Extent.Text.Contains("(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $original)",[StringComparison]::Ordinal)) "original path guarded: ${file}:$($read.Extent.StartLineNumber)"
      Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "import before read: $file"
      # Only the exact native expression is executed, never the installer.
      $bindings='$SourcePath=$DestinationPath=$recordPath=$milestoneSkillPath=$source=$helperPath=$identityDestination=$helperDestination=$destination=$ownerPath=$ClaimPath=$Path=$markerPath=$releaseRecord=$ProbePath'
      $probe=Join-Path $root 'probe.ps1'
      [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
      $result=& $probe $positive
      $isStream=$read -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $read.Member.Value -ceq 'Open'
      if($isStream){
        try {
          Check ($result.CanRead -and -not $result.CanWrite) 'owner/claim read-only access unchanged'
          $buffer=[IO.MemoryStream]::new()
          try {$result.CopyTo($buffer);$actual=$buffer.ToArray()}finally{$buffer.Dispose()}
          Check ([Linq.Enumerable]::SequenceEqual([byte[]]$actual,$bytes)) 'actual owner/claim stream bytes'
          $blocked=$false
          try {$other=[IO.File]::Open($positive,'Open','Write','ReadWrite,Delete');$other.Dispose()}catch{$blocked=$true}
          Check ($blocked -eq ($original -ceq '$ClaimPath')) 'owner readwrite/delete sharing versus claim delete-only sharing unchanged'
        } finally {$result.Dispose()}
      } elseif($read -is [Management.Automation.Language.CommandAst]) {
        if($read.GetCommandName() -ceq 'Get-FileHash') {Check ($result.Hash -ceq $hash) 'actual SHA256 expression'}
        else {Check ($result -ceq $json) 'actual text expression'}
      } else {Check ([Linq.Enumerable]::SequenceEqual([byte[]]$result,$bytes)) 'actual byte expression'}
      foreach($alias in $aliases){
        $path=Join-Path $root $alias
        [IO.File]::WriteAllText($path,$json)
        $held=[IO.File]::Open($path,'Open','ReadWrite','None')
        try {
          $failure=''
          try {& $probe $path|Out-Null}catch{$failure=$_.Exception.Message}
          Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') "pre-I/O refusal: $file index=$index alias=$alias failure=$failure"
        } finally {$held.Dispose()}
        Check ([IO.File]::ReadAllText($path) -ceq $json) 'dispatch alias untouched'
      }
    }
  }
  Check ($readCount -eq 16) 'sixteen native path expressions covered'
  $lockText=$asts['controller-install-lock.psm1'].Extent.Text
  Check ($lockText.Contains('([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)')) 'snapshot sharing flags retained'
  Check ($lockText.Contains('$openAttempt -ge 8 -or $openDeadline.ElapsedMilliseconds -ge 1000')) 'snapshot retry/deadline bound retained'
  Check ($lockText.Contains('[IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true), $false, 1024, $true)')) 'claim decoder and handle ownership retained, not blanket-exempted'

  # Extract complete production function definitions without running any
  # installer top-level work, admission, shared locks, or release operations.
  $functionsPath=Join-Path $root 'functions.ps1'
  $definitions=[Collections.Generic.List[string]]::new()
  foreach($pair in @(@('install-controller-skills.ps1','Merge-GeneratedBlocks'),
      @('install-controller-skills.ps1','Get-PreviousReleaseInventory'),
      @('check-controller-skill-freshness.ps1','Get-NormalizedSkillHash'))){
    $name=$pair[1]
    $definition=$asts[$pair[0]].Find({param($node)
      $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
    },$true)
    Check ($null -ne $definition) "real function exists: $name"
    $definitions.Add($definition.Extent.Text)
  }
  [IO.File]::WriteAllText($functionsPath,($definitions -join "`n"))
  . $functionsPath
  $module=Import-Module (Join-Path $PSScriptRoot 'controller-install-lock.psm1') -Force -DisableNameChecking -PassThru
  Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking
  Check ((Get-NormalizedSkillHash $positive $false) -ceq $hash) 'complete freshness hash body'
  $candidate=Join-Path $root 'candidate.json';$live=Join-Path $root 'live.json'
  [IO.File]::WriteAllText($candidate,'{"configs":[{"id":"synthetic","model":"synthetic","effort":"low"}]}')
  [IO.File]::WriteAllText($live,'{"configs":[{"id":"synthetic","model":"synthetic","effort":"low","adjudicated":{"score":7}}]}')
  $merged=Merge-GeneratedBlocks $candidate $live|ConvertFrom-Json
  Check ($merged.configs[0].adjudicated.score -eq 7) 'complete merge body preserves generated authority'
  $lockPath=Join-Path $root 'owner-lock';[void][IO.Directory]::CreateDirectory($lockPath)
  $ownerPath=Join-Path $lockPath 'owner.json';[IO.File]::WriteAllText($ownerPath,$json)
  $snapshot=& $module {param($p) Get-ControllerInstallOwnerSnapshot $p} $lockPath
  Check ($snapshot.Raw -ceq $json -and $snapshot.Record.synthetic) 'complete owner snapshot body'
  $claimPath=Join-Path $lockPath 'owner.reclaim.synthetic.json'
  [IO.File]::Move($ownerPath,$claimPath)
  $removed=& $module {param($l,$c,$raw) Remove-ClaimedOwnerLock $l $c $raw} $lockPath $claimPath $json
  Check ($removed -and -not [IO.Directory]::Exists($lockPath)) 'complete claimed-owner body reads and removes only synthetic lock'
  foreach($alias in $aliases){
    $failure=''
    try {Get-NormalizedSkillHash (Join-Path $root $alias) $false|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') 'complete freshness hash body refuses alias'
    $failure=''
    try {Merge-GeneratedBlocks (Join-Path $root $alias) $live|Out-Null}catch{$failure=$_.Exception.Message}
    Check ($failure -like '*DISPATCH_LEDGER_OWNER_REQUIRED*') 'complete merge body refuses alias'
  }

  # Previous-release inventory is imported in a scratch directory; its new
  # literal owner dependency must travel with it, with no actual install.
  $destinationRoot=Join-Path $root 'skills'
  [void][IO.Directory]::CreateDirectory((Join-Path $destinationRoot 'native-db'))
  [IO.File]::WriteAllText((Join-Path $destinationRoot 'native-db/release.json'),('{"commit":"'+('a'*40)+'"}'))
  $script:previousReleaseInventory=$null
  $previousModuleLines=[IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'controller-install-lock.psm1'))
  function Invoke-ContainerGit {param($Arguments,[switch]$AllowFailure)
    Check ($Arguments[0] -ceq 'show' -and $Arguments[1] -ceq (('a'*40)+':.orchestrator/controller-install-lock.psm1')) 'previous inventory retains commit authority'
    [pscustomobject]@{ExitCode=0;Lines=$previousModuleLines}
  }
  $inventory=@(Get-PreviousReleaseInventory)
  Check ($inventory.Count -eq @(Get-ControllerSkillInstallInventory).Count) 'complete previous-release inventory body imports owner dependency'
  Check ((Get-NormalizedSkillHash $positive $false) -ceq $hash) 'owner import remains callable after scratch module removal'
  Write-Output "PASS ledger-reader-install-paths checks=$script:checks reads=$readCount"
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $resolved) -notlike 'ledger-install-paths-*'){throw 'unsafe install fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
