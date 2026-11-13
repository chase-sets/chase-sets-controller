$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-report-paths-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
function Write-Json([string]$Path,$Value) {
  [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 100),[Text.UTF8Encoding]::new($false))
}
try {
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination $root
  $json='{"synthetic":true}'
  $jsonPath=Join-Path $root 'metadata.json'
  [IO.File]::WriteAllText($jsonPath,$json)
  $import="Import-Module (Join-Path `$PSScriptRoot 'dispatch-ledger-reader.psm1') -Force -DisableNameChecking"
  $expected=[ordered]@{
    'lane-selection.ps1'=@('$ReceiptPath','$InputPath')
    'platform-scorecard.ps1'=@('$Path')
    'waiting-on-todd.ps1'=@('$Path','"$($script:statePathFull).lock"')
  }
  $aliases=@('dispatch-log.jsonl','DISPATCH-LOG.JSONL','./dispatch-log.jsonl',
    'dispatch-log.jsonl.','dispatch-log.jsonl ','dispatch-log.jsonl:synthetic','dispatch-log.jsonl.:synthetic')
  $readCount=0
  foreach($file in $expected.Keys){
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $file),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) "parse $file"
    $imports=@($ast.EndBlock.Statements|Where-Object {$_.Extent.Text -ceq $import})
    Check ($imports.Count -eq 1) "unconditional literal owner import: $file"
    $reads=@($ast.FindAll({param($node)
      ($node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Get-Content') -or
      ($node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        ($node.Member.Value -ceq 'ReadAllText' -or $node.Expression.Extent.Text -ceq '[IO.FileStream]'))
    },$true))
    Check ($reads.Count -eq $expected[$file].Count) "native read census: $file"
    for($index=0;$index -lt $reads.Count;$index++){
      $read=$reads[$index];$original=$expected[$file][$index];$readCount++
      Check ($read.Extent.Text.Contains("(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $original)",[StringComparison]::Ordinal)) "original path guarded: ${file}:$($read.Extent.StartLineNumber)"
      Check ($imports[0].Extent.EndOffset -lt $read.Extent.StartOffset) "owner imported before read: $file"
      $isLock=$original.Contains('statePathFull')
      # Execute the actual native expression, not a reimplementation. This also
      # isolates FileStream from the publisher's GitHub and state-writing work.
      $bindings='$Path=$ReceiptPath=$InputPath=$script:statePathFull=$ProbePath'
      $probe=Join-Path $root 'probe.ps1'
      [IO.File]::WriteAllText($probe,('param([string]$ProbePath)'+"`n"+$import+"`n"+$bindings+"`n"+$read.Extent.Text))
      if($isLock){
        Check ($read.Extent.Text.EndsWith('[IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,'+"`n"+'      [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)') -or
          $read.Extent.Text.Replace("`r`n","`n").EndsWith('[IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite,'+"`n"+'      [IO.FileShare]::None, 1, [IO.FileOptions]::DeleteOnClose)')) 'lock access/share/lifetime unchanged'
        $lockPath=Join-Path $root 'state.json'
        $lock=& $probe -ProbePath $lockPath
        try {
          Check ($lock.CanRead -and $lock.CanWrite -and $lock.Length -eq 0) 'actual sidecar stream is an empty readwrite lock'
          $blocked=$false
          try {$other=[IO.File]::Open("$lockPath.lock",'Open','ReadWrite','None');$other.Dispose()}catch{$blocked=$true}
          Check $blocked 'actual lock remains exclusive'
        } finally {$lock.Dispose()}
        Check (-not [IO.File]::Exists("$lockPath.lock")) 'actual lock deletes on close'
        # A normal state leaf gets .lock, not a dispatch leaf. ADS state aliases
        # retain the dispatch base leaf even after that suffix is appended.
        $cases=@('dispatch-log.jsonl:synthetic','dispatch-log.jsonl.:synthetic')
      } else {
        Check ((& $probe -ProbePath $jsonPath) -ceq $json) "genuine native JSON bytes: $file index=$index"
        $cases=$aliases
      }
      foreach($alias in $cases){
        $path=Join-Path $root $alias
        $target=if($isLock){"$path.lock"}else{$path}
        [IO.File]::WriteAllText($target,$json)
        # A valid readable payload rules out accidental JSON refusal. An
        # exclusive handle makes any native open fail differently from owner refusal.
        Check ([IO.File]::ReadAllText($target) -ceq $json) "valid alias payload: $target"
        $held=[IO.File]::Open($target,'Open','ReadWrite','None')
        try {
          $failure=''
          try {& $probe -ProbePath $path|Out-Null}catch{$failure=$_.Exception.Message}
          Check ($failure -match 'DISPATCH_LEDGER_OWNER_REQUIRED') "owner refused before native I/O: $file index=$index alias=$alias failure=$failure"
        } finally {$held.Dispose()}
        Check ([IO.File]::ReadAllText($target) -ceq $json) "alias untouched: $target"
      }
    }
  }
  Check ($readCount -eq 5) 'five original native expressions covered'

  # Positive coverage also runs complete production bodies, including parsing
  # and schema/reducer behavior, with genuine non-dispatch inputs.
  . (Join-Path $PSScriptRoot 'platform-scorecard.ps1') -FunctionsOnly
  Check ((Read-ScorecardJson $jsonPath).synthetic -eq $true) 'actual scorecard JSON body'
  . (Join-Path $PSScriptRoot 'waiting-on-todd.ps1') -Library
  $statePath=Join-Path $root 'state.json'
  Write-Json $statePath (New-WaitingOnToddState 'synthetic/fixture' 'synthetic-todd')
  $state=Read-WaitingOnToddState $statePath 'synthetic/fixture' 'synthetic-todd'
  Check ($state.schema -ceq 'waiting-on-todd-state/v1' -and $state.owned.Count -eq 0 -and $state.pending.Count -eq 0) 'actual reconciliation state body'
  . (Join-Path $PSScriptRoot 'lane-selection.ps1')
  $receipt=ConvertTo-LaneAdmission (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/lane-admission-collected-input.valid.json') -Raw|ConvertFrom-Json)
  $receiptPath=Join-Path $root 'receipt.json';Write-Json $receiptPath $receipt
  $selectionPath=Join-Path $PSScriptRoot 'fixtures/lane-selection-input.valid.json'
  $selection=& (Join-Path $PSScriptRoot 'lane-selection.ps1') -ReceiptPath $receiptPath -InputPath $selectionPath -Compact|ConvertFrom-Json
  Check ($selection.status -ceq 'selected' -and 101 -in $selection.selectedBatch) 'actual public selection receipt/input bodies'
  Write-Output "PASS ledger-reader-report-paths checks=$script:checks reads=$readCount"
} finally {
  $resolved=[IO.Path]::GetFullPath($root)
  $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
  if((Split-Path -Parent $resolved).TrimEnd('\','/') -cne $temp.TrimEnd('\','/') -or
    (Split-Path -Leaf $resolved) -notlike 'ledger-report-paths-*'){throw 'unsafe report path fixture cleanup'}
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
