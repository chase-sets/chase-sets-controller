$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-retention-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
  $entry=Join-Path $PSScriptRoot 'runtime-retention.ps1'
  $tokens=$null;$errors=$null
  $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$errors)
  Check ($errors.Count -eq 0) 'retention parses'
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
  Check ($imports.Count -eq 1) 'literal unconditional owner import'
  $reads=@($ast.FindAll({param($node)
    ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-FileHash') -or
    ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
      (($node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -in @('ReadAllText','ReadLines','OpenRead')) -or
       ($node.Expression.Extent.Text -ceq '[IO.Compression.ZipFile]' -and $node.Member.Value -ceq 'OpenRead') -or
       ($node.Expression.Extent.Text -ceq '[IO.File]' -and $node.Member.Value -ceq 'Open' -and $node.Extent.Text.EndsWith(",'Open','Read','Read')"))))
  },$true))
  $paths=@('(Join-Path $Root $p)','$file.FullName','$path','$entry.FullName','$f.fullPath','$Path','$p.FullName','$p')
  Check ($reads.Count -eq $paths.Count) 'eight path-based content reads; write-only opens excluded'
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $positive=Join-Path $root 'reference.txt';[IO.File]::WriteAllText($positive,"synthetic`nreference")
  $zipPath=Join-Path $root 'archive.zip'
  $zip=[IO.Compression.ZipFile]::Open($zipPath,'Create')
  try {
    $writer=[IO.StreamWriter]::new($zip.CreateEntry('synthetic.txt').Open())
    try {$writer.Write('synthetic')} finally {$writer.Dispose()}
  } finally {$zip.Dispose()}
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl','dispatch-log.jsonl.',
    'dispatch-log.jsonl ','dispatch-log.jsonl:retention','dispatch-log.jsonl.:retention')
  for($index=0;$index -lt $reads.Count;$index++) {
    $read=$reads[$index]
    Check ($read.Extent.Text.Contains("(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $($paths[$index]))",[StringComparison]::Ordinal)) "original expression guarded $index"
    Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "import precedes read $index"
    $probe=Join-Path $root 'probe.ps1'
    $bindings='$Root=Split-Path $ProbePath -Parent; $p=Split-Path $ProbePath -Leaf; $path=$ProbePath; $file=$entry=[pscustomobject]@{FullName=$ProbePath}; $f=[pscustomobject]@{fullPath=$ProbePath}'
    if($index -eq 6){$bindings+='; $p=[pscustomobject]@{FullName=$ProbePath}'}
    if($index -eq 7){$bindings+='; $p=$ProbePath'}
    [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
    $inputPath=if($index -eq 5){$zipPath}else{$positive}
    $result=& $probe $inputPath
    try {
      switch($index) {
        2 {Check (($result -join "`n") -ceq "synthetic`nreference") 'native cost-ledger lines'}
        3 {Check ($result.Hash -ceq (Get-FileHash -LiteralPath $positive -Algorithm SHA256).Hash) 'native candidate hash'}
        4 {Check ($result.CanRead -and -not $result.CanWrite -and $result.Length -eq ([IO.FileInfo]$positive).Length) 'native archive source stream'}
        5 {Check ($result.Entries.Count -eq 1 -and $result.Entries[0].FullName -ceq 'synthetic.txt') 'native archive verification ZIP'}
        7 {
          Check ($result.CanRead -and -not $result.CanWrite) 'published archive/manifest lock read-only'
          $blocked=$false
          try {$other=[IO.File]::Open($positive,'Open','Write','ReadWrite');$other.Dispose()}catch{$blocked=$true}
          Check $blocked 'published lock still denies writes'
        }
        default {Check ($result -ceq "synthetic`nreference") "native reference/manifest text $index"}
      }
    } finally {if($result -is [IDisposable]){$result.Dispose()}}
    foreach($alias in $aliases) {
      $target=Join-Path $root $alias
      # Valid, exclusively held bytes distinguish owner refusal from parser or
      # sharing errors, including ZIP verification and ADS/trailing-leaf aliases.
      [IO.File]::WriteAllBytes($target,[IO.File]::ReadAllBytes($inputPath))
      $held=[IO.File]::Open($target,'Open','ReadWrite','None')
      try {
        $failure=''
        try {& $probe $target|Out-Null}catch{$failure=$_.Exception.Message}
        Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refusal before I/O $index/$alias : $failure"
      } finally {$held.Dispose()}
      Check ([Convert]::ToHexString([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($inputPath))) "alias untouched $index/$alias"
    }
  }

  . $entry -Library -Root $root
  $runtime=Join-Path $root '.orchestrator';[void][IO.Directory]::CreateDirectory($runtime)
  $cost=Join-Path $runtime 'cost-ledger.jsonl'
  [IO.File]::WriteAllText($cost,"{`"transcript`":`"old.jsonl`",`"bytes`":3}`n{`"transcript`":`"old.jsonl`",`"bytes`":4}`n")
  Check ((Get-RetentionLedger $root)['old.jsonl'].bytes -eq 4) 'actual cost ledger body keeps newest row'
  $source=Join-Path $runtime 'old.log';[IO.File]::WriteAllText($source,'synthetic')
  $snapshot=Get-RetentionSnapshot $runtime 'old.log'
  Check (-not $snapshot.reason -and $snapshot.files.Count -eq 1 -and $snapshot.files[0].sha256 -ceq (Get-FileHash $source).Hash.ToLowerInvariant()) 'actual candidate snapshot hashes genuine file'
  $files=$snapshot.files; $files[0]|Add-Member fullPath $source
  $archive=Join-Path $root 'body.zip'
  Write-RetentionZip $archive $files
  Check (Test-RetentionZip $archive $files) 'actual writer and verifier bodies preserve source bytes'
  $now=[datetime]::SpecifyKind([datetime]'2030-01-01T12:00:00','Utc')
  $manifest=@{schema='runtime-retention-manifest/v1';verifiedAt=$now.ToString('o');files=$files}
  [IO.File]::WriteAllText((Join-Path $root 'body.manifest.json'),($manifest|ConvertTo-Json -Depth 10))
  Check (-not (Test-RetentionDue $root $now)) 'actual cadence body reads manifest and verifies ZIP'
  Check (Test-RetentionDue $root $now.AddHours(25)) 'actual cadence still expires after 24 hours'
  & {
    Set-Variable -Name HOME -Value (Join-Path $root 'home') -Scope Local -Force
    $skill=Join-Path $HOME '.codex/skills/model-routing';[void][IO.Directory]::CreateDirectory($skill)
    [IO.File]::WriteAllText((Join-Path $skill 'SKILL.md'),'synthetic installed reference')
    [IO.File]::WriteAllText((Join-Path $runtime 'reader.ps1'),'# synthetic tracked reference')
    function git {$global:LASTEXITCODE=0; '.orchestrator/reader.ps1'}
    function Get-CimInstance {param($ClassName,$ErrorAction) @()}
    $context=Get-RetentionContext $root
    Check ($context.complete -and $context.references.Contains('synthetic tracked reference') -and $context.references.Contains('synthetic installed reference')) 'actual context body reads tracked and installed reference text'
  }
  Write-Output "PASS ledger-reader-retention-paths checks=$script:checks reads=$($reads.Count)"
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $resolved) -notlike 'ledger-retention-paths-*'){throw 'unsafe retention fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
