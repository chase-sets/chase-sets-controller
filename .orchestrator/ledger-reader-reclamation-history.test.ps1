$ErrorActionPreference='Stop'
$checks=0
function Check([bool]$Condition,[string]$Message){$script:checks++;if(-not$Condition){throw "ASSERTION FAILED: $Message"}}
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking
$source=Join-Path $PSScriptRoot 'cleanup-orphan-worktree-dirs.ps1'
$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$null,[ref]$e)
Check ($e.Count-eq0) 'actual reclamation source parses'
foreach($name in @('Get-ReclamationPath','Get-ReclamationDispatch')){
  $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq$name},$true))
  Check ($nodes.Count-eq1) "one actual $name function"
  . ([scriptblock]::Create($nodes[0].Extent.Text))
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-reclamation-history-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$path=Join-Path $root 'dispatch-log.jsonl'
$worktree=Join-Path $root 'synthetic-lane';$branch='codex/synthetic-reclamation'
$old=([ordered]@{worktree=$worktree;branch=$branch;attemptId='900001-old'}|ConvertTo-Json -Compress)
$new=([ordered]@{worktree=$worktree;branch=$branch;attemptId='900002-new'}|ConvertTo-Json -Compress)
function Write-History([string]$Text,[bool]$Bom=$false){[IO.File]::WriteAllText($path,$Text,[Text.UTF8Encoding]::new($Bom))}
function Check-PartialRefusal {
  foreach($bom in @($false,$true)){
    foreach($prefix in @('',($old+"`n"))){
      foreach($tail in @($new,'{')){
        Write-History ($prefix+$tail) $bom
        $before=[Convert]::ToHexString([IO.File]::ReadAllBytes($path))
        $r=Get-ReclamationDispatch $root
        Check (-not$r.complete-and$r.paths.Count-eq0-and$r.branches.Count-eq0) 'partial authority refuses without retaining older identity'
        Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($path))-ceq$before) 'partial bytes unchanged'
      }
    }
  }
}
try {
  Check-PartialRefusal
  foreach($bom in @($false,$true)){
    foreach($newline in @("`n","`r`n")){
      Write-History ($old+$newline+$new+$newline) $bom
      $r=Get-ReclamationDispatch $root
      $expectedHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($new)))
      Check ($r.complete-and$r.paths.Count-eq1-and$r.branches.Count-eq1-and
        $r.paths[$worktree].attemptId-ceq'900002-new'-and$r.branches[$branch].fingerprint-ceq$expectedHash) 'committed BOM/LF/CRLF preserve original latest-row identity/hash fold'
    }
    Write-History ($old+"`n{`n") $bom
    $r=Get-ReclamationDispatch $root
    Check (-not$r.complete-and$r.paths.Count-eq0-and$r.branches.Count-eq0) 'committed malformed row still refuses'
  }
  Write-History ($old+"`n"+$new)
  $writer=[IO.File]::Open($path,'Open','Write','ReadWrite')
  try {
    [void]$writer.Seek(0,[IO.SeekOrigin]::End)
    Check (-not(Get-ReclamationDispatch $root).complete) 'real append writer may remain open during partial refusal'
    $writer.WriteByte(10);$writer.Flush($true)
    $r=Get-ReclamationDispatch $root
    Check ($r.complete-and$r.paths[$worktree].attemptId-ceq'900002-new') 'same open writer commits authoritative new row with LF'
  }finally{$writer.Dispose()}
  $original=${function:Get-ReclamationDispatch}
  $removed=$original.ToString().Replace(' -RequireTerminated','')
  Check ($removed-cne$original.ToString()) 'exact strict-termination removal changes actual function'
  try {
    Set-Item Function:Get-ReclamationDispatch ([scriptblock]::Create($removed))
    $failure='';try{Check-PartialRefusal}catch{$failure=$_.Exception.Message}
    Check ($failure-like'*ASSERTION FAILED: partial authority refuses*') 'strict-termination removal killed by actual partial-authority control'
  }finally{Set-Item Function:Get-ReclamationDispatch $original}
  Write-Output "PASS ledger-reader-reclamation-history checks=$checks partialVariants=8 committedVariants=4 realWriter=true strictRemoval=KILLED"
}finally{
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/')-cne([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/')-or
    (Split-Path -Leaf $full)-cnotlike'ledger-reclamation-history-*'){throw 'unsafe reclamation history cleanup'}
  Remove-Item -LiteralPath $full -Recurse -Force
}
