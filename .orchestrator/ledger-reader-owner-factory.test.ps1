$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$checks=0
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not $Value){throw "ASSERT: $Message"}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-owner-factory-'+[guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  $actual=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1'),[ref]$null,[ref]$null)
  $factory=@($actual.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Open-DispatchLedgerReadStream'},$true))
  Check ($factory.Count -eq 1) 'one actual native owner factory'
  $source=$factory[0].Extent.Text
  $path='.orchestrator/dispatch-ledger-reader.psm1'
  [IO.File]::WriteAllText((Join-Path $root $path),$source)
  [IO.File]::WriteAllText((Join-Path $root 'driver.ps1'),"Open-DispatchLedgerReadStream -Path 'dispatch-log.jsonl'")
  [IO.File]::WriteAllText((Join-Path $root 'other.psm1'),'# tracked sibling')
  & git -C $root init -q
  if($LASTEXITCODE){throw 'fixture init failed'}
  & git -C $root add .orchestrator/dispatch-ledger-reader.psm1 driver.ps1 other.psm1
  if($LASTEXITCODE){throw 'fixture track failed'}
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm factory
  if($LASTEXITCODE){throw 'fixture commit failed'}
  $baseline=Get-LedgerReaderCensus -Root $root
  $owned=@($baseline.rows|Where-Object owner)
  Check ($owned.Count -eq 1 -and $owned[0].handled -and $owned[0].family -ceq 'IO.File.Open' -and $owned[0].authority -ceq 'dispatch') 'actual factory native expression recognized as sole owner'
  $cases=[ordered]@{
    trivia=@(1,$source.Replace('return [IO.File]',"return <# same native operation #> [IO.File]"))
    readWrite=@(0,$source.Replace('[IO.FileAccess]::Read,','[IO.FileAccess]::ReadWrite,'))
    write=@(0,$source.Replace('[IO.FileAccess]::Read,','[IO.FileAccess]::Write,'))
    shareRead=@(0,$source.Replace('[IO.FileShare]::ReadWrite','[IO.FileShare]::Read'))
    shareComment=@(0,$source.Replace('[IO.FileShare]::ReadWrite','[IO.FileShare]::Read <# FileShare]::ReadWrite #>'))
    create=@(0,$source.Replace('[IO.FileMode]::Open','[IO.FileMode]::Create'))
    wrongPath=@(0,$source.Replace('::Open($Path,','::Open($Other,'))
    literalPath=@(0,$source.Replace('::Open($Path,',"::Open('dispatch-log.jsonl',"))
    untyped=@(0,$source.Replace('[string]$Path','$Path'))
    extraParameter=@(0,$source.Replace('[string]$Path)','[string]$Path,$Other)'))
    defaultValue=@(0,$source.Replace('[string]$Path)',"[string]`$Path='dispatch-log.jsonl')"))
    extraStatement=@(0,$source.Replace('return [IO.File]','[IO.File]::ReadAllText($Path);return [IO.File]'))
    nested=@(0,('function Wrapper {'+$source+'}'))
    duplicate=@(0,($source+"`n"+$source))
    legacyLookalike=@(0,$source.Replace('Open-DispatchLedgerReadStream','Read-DispatchLedgerSnapshot').Replace('[IO.FileAccess]::Read,','[IO.FileAccess]::ReadWrite,'))
  }
  foreach($name in $cases.Keys){
    $c=Get-LedgerReaderCensus -Root $root -SourceOverride @{$path=$cases[$name][1]}
    $owners=@($c.rows|Where-Object owner)
    Check ($owners.Count -eq $cases[$name][0]) "owner proof $name owners=$($owners.Count)"
    "OWNER-PROOF case=$name owners=$($owners.Count) expected=$($cases[$name][0])"
  }
  $c=Get-LedgerReaderCensus -Root $root -SourceOverride @{$path=($source+"`n"+'[IO.File]::Open(''dispatch-log.jsonl'',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)')}
  Check (@($c.rows|Where-Object owner).Count -eq 1 -and @($c.violations|Where-Object family -CEQ 'IO.File.Open').Count -eq 1) 'sibling native read never inherits factory authority'
  $c=Get-LedgerReaderCensus -Root $root -SourceOverride @{$path=($source+"`n"+'$io=[IO.File];$io::ReadAllText(''dispatch-log.jsonl'')')}
  Check (@($c.rows|Where-Object owner).Count -eq 1 -and @($c.violations|Where-Object family -CEQ 'IO.File.ReadAllText').Count -eq 1) 'native type-alias sibling remains independently unowned'
  $c=Get-LedgerReaderCensus -Root $root -SourceOverride @{$path='# moved';'other.psm1'=$source}
  Check (@($c.rows|Where-Object owner).Count -eq 0 -and @($c.violations|Where-Object family -CEQ 'IO.File.Open').Count -eq 1) 'same factory text outside actual module has no authority'
  # Execute only the extracted real factory against a private synthetic ledger.
  $ledger=Join-Path $root 'dispatch-log.jsonl'
  [IO.File]::WriteAllText($ledger,"one`n")
  $streams=& ([scriptblock]::Create($source+"`n"+'@(Open-DispatchLedgerReadStream -Path $args[0];Open-DispatchLedgerReadStream -Path $args[0])')) $ledger
  try {
    Check ($streams.Count -eq 2 -and @($streams|Where-Object {$_.CanRead -and -not $_.CanWrite}).Count -eq 2) 'two actual read-only native owners retained'
    [IO.File]::AppendAllText($ledger,"two`n")
    [IO.File]::AppendAllText($ledger,"three`n")
    Check ([IO.File]::ReadAllText($ledger) -ceq "one`ntwo`nthree`n") 'two appends succeed while actual owner streams held'
  } finally {foreach($stream in $streams){$stream.Dispose()}}
  "PASS owner factory checks=$checks mutants=$($cases.Count) sibling=REFUSED moved=REFUSED nativeReaders=2 appends=2; not global census qualification"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-owner-factory-*'){throw 'unsafe fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
