$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$checks=0
function Check([bool]$Condition,[string]$Message) {
  $script:checks++
  if(-not $Condition){throw "ASSERTION FAILED: $Message"}
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-constructor-inventory-'+[guid]::NewGuid().ToString('N'))
try {
  [void][IO.Directory]::CreateDirectory((Join-Path $root '.orchestrator'))
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Destination (Join-Path $root '.orchestrator')
  $path=Join-Path $root 'reader.ps1'
  [IO.File]::WriteAllText($path,'# tracked constructor inventory')
  & git -C $root init -q
  Check ($LASTEXITCODE -eq 0) 'fixture init'
  & git -C $root add reader.ps1 .orchestrator/dispatch-ledger-reader.psm1
  Check ($LASTEXITCODE -eq 0) 'fixture track'
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm constructors
  Check ($LASTEXITCODE -eq 0) 'fixture commit'
  $import='Import-Module (Join-Path $PSScriptRoot ''.orchestrator/dispatch-ledger-reader.psm1'') -Global -DisableNameChecking'
  $guard='(dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $Path)'
  # Each case requires actual inventory, not merely absence of positive proof.
  $cases=[ordered]@{
    fakeStreamReader=@(1,$false,'[Fake.StreamReader]::new($Path)')
    fakeFileStream=@(1,$false,'[Fake.FileStream]::new($Path)')
    fakeReaderGuarded=@(1,$false,('[Fake.StreamReader]::new('+$guard+')'))
    fakeReaderReceipt=@(1,$false,'[Fake.StreamReader]::new(''receipt.json'')')
    fakeReaderCost=@(1,$false,'[Fake.StreamReader]::new(''cost-ledger.jsonl'')')
    genericOuterType=@(1,$false,'[System.IO.StreamReader[int]]::new($Path)')
    genericFakeType=@(1,$false,'[Fake.StreamReader[int]]::new($Path)')
    genericFileStreamType=@(1,$false,'[System.IO.FileStream[int]]::new($Path)')
    unresolvedDecoder=@(1,$false,'$Decoder::new($Path)')
    unresolvedReceipt=@(1,$false,'$Decoder::new(''receipt.json'')')
    unresolvedEmpty=@(1,$false,'$Decoder::new()')
    unresolvedParenthesized=@(1,$false,'($Decoder)::new($Path)')
    dispatchOpaqueConstructor=@(1,$false,'[Unknown.Factory]::new(''dispatch-log.jsonl'')')
    dispatchSplitConstructor=@(1,$false,'$Path=''dispatch-''+''log.jsonl'';[Unknown.Factory]::new($Path)')
    dispatchAliasConstructor=@(1,$false,'$Path=''dispatch-log.jsonl'';$Other=$Path;[Unknown.Factory]::new($Other)')
    dispatchNestedSplit=@(1,$false,'$Path=''dis''+''patch-''+''log.jsonl'';[Unknown.Factory]::new($Path)')
    dispatchEmptySplit=@(1,$false,'$Path=''''+''dispatch-log.jsonl'';[Unknown.Factory]::new($Path)')
    dispatchGroupedLeft=@(1,$false,'$Path=(''dis''+''patch-'')+''log.jsonl'';[Unknown.Factory]::new($Path)')
    dispatchGroupedRight=@(1,$false,'$Path=''dispatch-''+(''log''+''.jsonl'');[Unknown.Factory]::new($Path)')
    dispatchGroupedBoth=@(1,$false,'$Path=(''dis''+''patch-'')+(''log''+''.jsonl'');[Unknown.Factory]::new($Path)')
    dispatchDoubleGrouped=@(1,$false,'$Path=((''dis''+''patch-''))+''log.jsonl'';[Unknown.Factory]::new($Path)')
    nonNativeTypeAlias=@(1,$false,'$Decoder=[Text.UTF8Encoding];$Decoder::new($Path)')
    nonNativeRebound=@(1,$false,'$Decoder=[Text.UTF8Encoding];$Decoder=$Other;$Decoder::new($Path)')
    nativeThenNonNative=@(1,$false,'$Decoder=[IO.StreamReader];$Decoder=[Text.UTF8Encoding];$Decoder::new($Path)')
    nonNativeAfterCall=@(1,$false,'$Decoder::new($Path);$Decoder=[Text.UTF8Encoding]')
    nonNativeConditional=@(1,$false,'if($flag){$Decoder=[Text.UTF8Encoding]};$Decoder::new($Path)')
    nonNativeScoped=@(1,$false,'$script:Decoder=[Text.UTF8Encoding];$script:Decoder=$Other;$script:Decoder::new($Path)')
    nonNativeReadAlias=@(1,$false,('$Decoder=[Text.UTF8Encoding];$Decoder=$Other;$Decoder::ReadAllText('+$guard+')'))
    nonNativeOtherAlias=@(1,$false,'$Decoder=[Text.UTF8Encoding];$Decoder=$Other;$Decoder::Load(''receipt.json'')')
    unresolvedStaticMethod=@(1,$false,'$Decoder::Load(''receipt.json'')')
    unresolvedDynamicMember=@(1,$false,'$Decoder::$Method(''dispatch-log.jsonl'')')
    unresolvedDynamicReceipt=@(1,$false,'$Decoder::$Method(''receipt.json'')')
    unknownComputedMember=@(1,$false,'[Unknown.Factory]::(''n''+''ew'')(''dispatch-log.jsonl'')')
    unknownComputedReceipt=@(1,$false,'[Unknown.Factory]::(''n''+''ew'')(''receipt.json'')')
    unknownDynamicMember=@(1,$false,'[Unknown.Factory]::$Method(''receipt.json'')')
    nativeComputedMember=@(1,$false,('[IO.StreamReader]::(''n''+''ew'')('+$guard+')'))
    groupedMemoryDispatch=@(2,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes((''dis''+''patch-'')+''log.jsonl'');[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    rightGroupedMemoryDispatch=@(2,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes(''dispatch-''+(''log''+''.jsonl''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    groupedMemoryCost=@(1,$true,'$bytes=[Text.Encoding]::UTF8.GetBytes((''cost-''+''ledger'')+''.jsonl'');[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    genericNativeMethod=@(1,$false,('[IO.StreamReader]::new[int]('+$guard+')'))
    genericNativeFileMethod=@(1,$false,('[IO.File]::ReadAllText[int]('+$guard+')'))
    dynamicNativeMember=@(1,$false,('[IO.StreamReader]::$Constructor('+$guard+')'))
    nativeTypeAlias=@(1,$false,('$Decoder=[IO.StreamReader];$Decoder::new('+$guard+')'))
    reboundTypeAlias=@(1,$false,('$Decoder=[IO.StreamReader];$Decoder=$Other;$Decoder::new('+$guard+')'))
    nativeFileAlias=@(1,$false,('$File=[IO.File];$File::ReadAllText('+$guard+')'))
    nativeAliasWriter=@(1,$false,'$File=[IO.File];$File::Open($Path,[IO.FileMode]::Create)')
    nativeAliasAfterCall=@(1,$false,('$Decoder::new('+$guard+');$Decoder=[IO.StreamReader]'))
    nativeAliasConditional=@(1,$false,('if($flag){$Decoder=[IO.StreamReader]};$Decoder::new('+$guard+')'))
    literalReaderGuarded=@(1,$true,('[IO.StreamReader]::new('+$guard+')'))
    literalFileGuarded=@(1,$true,('[System.IO.File]::ReadAllText('+$guard+')'))
    literalMemoryDecoder=@(1,$true,'[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    literalFileWriter=@(1,$true,'[IO.File]::Open($Path,[IO.FileMode]::Create)')
    literalEncoding=@(0,$true,'[Text.UTF8Encoding]::new($false,$true)')
    literalUnknownReceipt=@(0,$true,'[Unknown.Factory]::new(''receipt.json'')')
  }
  $failures=[Collections.Generic.List[string]]::new()
  foreach($name in $cases.Keys) {
    $source='throw ''inspected source must never execute'''+"`n"+$import+"`nfunction Read-Synthetic { param([string]`$Path,`$Other,`$flag) "+$cases[$name][2]+' }'
    [IO.File]::WriteAllText($path,$source)
    $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
    Check ($errors.Count -eq 0) "source parses $name"
    $c=Get-LedgerReaderCensus -Root $root
    Check ($c.scanned -eq 2 -and $c.total -eq 2) "complete tracked inventory $name"
    $rows=@($c.rows|Where-Object path -CEQ 'reader.ps1')
    $violations=@($c.violations|Where-Object path -CEQ 'reader.ps1')
    $valid=$rows.Count -eq $cases[$name][0] -and @($rows|Where-Object owner).Count -eq 0 -and
      @($rows|Where-Object {[bool]$_.handled -ne $cases[$name][1]}).Count -eq 0 -and
      $violations.Count -eq $(if($cases[$name][1]){0}else{$cases[$name][0]})
    if(-not $valid){$failures.Add($name)}
    if($name -ceq 'groupedMemoryCost' -and @($rows|Where-Object authority -EQ 'cost').Count -ne 1){$failures.Add('groupedMemoryCostAuthority')}
    $checks++
    "CONSTRUCTOR case=$name rows=$($rows.Count) handled=$(@($rows|Where-Object handled).Count) violations=$($violations.Count) expectedRows=$($cases[$name][0]) expectedHandled=$($cases[$name][1])"
  }
  Check ($failures.Count -eq 0) "constructor inventory/proof controls: $($failures -join ',')"
  # A test suffix changes enforcement, never discovery.
  $testPath=Join-Path $root 'reader.test.ps1'
  [IO.File]::WriteAllText($testPath,'[Fake.StreamReader]::new(''dispatch-log.jsonl'')')
  & git -C $root add reader.test.ps1
  Check ($LASTEXITCODE -eq 0) 'report-only fixture tracked'
  $c=Get-LedgerReaderCensus -Root $root
  $rows=@($c.rows|Where-Object path -CEQ 'reader.test.ps1')
  Check ($rows.Count -eq 1 -and $rows[0].test -and -not $rows[0].handled -and
    @($c.violations|Where-Object path -CEQ 'reader.test.ps1').Count -eq 0) 'test-only constructor reported without production enforcement'
  "PASS constructor inventory checks=$checks cases=$($cases.Count) reportOnly=1 inspectedExecution=false"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or
    (Split-Path -Leaf $full) -cnotlike 'ledger-constructor-inventory-*'){throw 'unsafe constructor fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
