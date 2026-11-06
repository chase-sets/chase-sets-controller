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
    groupedMemoryDispatch=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes((''dis''+''patch-'')+''log.jsonl'');[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    rightGroupedMemoryDispatch=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes(''dispatch-''+(''log''+''.jsonl''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    groupedMemoryCost=@(1,$true,'$bytes=[Text.Encoding]::UTF8.GetBytes((''cost-''+''ledger'')+''.jsonl'');[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    literalUnknownLoad=@(1,$false,'[Unknown.Factory]::Load(''dispatch-log.jsonl'')')
    literalUnknownDecode=@(1,$false,'[Unknown.Factory]::Decode(''dispatch-log.jsonl'')')
    unknownInstance=@(1,$false,'$Decoder.Load(''dispatch-log.jsonl'')')
    unknownInstanceDynamic=@(1,$false,'$Decoder.$Method(''dispatch-log.jsonl'')')
    unknownInstanceComputed=@(1,$false,'$Decoder.(''Lo''+''ad'')(''dispatch-log.jsonl'')')
    literalUnknownGroupedLoad=@(1,$false,'$Path=(''dis''+''patch-'')+''log.jsonl'';[Unknown.Factory]::Load($Path)')
    unresolvedPlus=@(1,$false,'$Path=''rece''+$Other+''ipt.json'';[Unknown.Factory]::new($Path)')
    unresolvedPlusInstance=@(1,$false,'$Path=''rece''+$Other+''ipt.json'';$Decoder.Load($Path)')
    commandPlus=@(1,$false,'$Path=''dis''+(Write-Output ''patch-'')+''log.jsonl'';[Unknown.Factory]::new($Path)')
    pipelinePlus=@(1,$false,'$Path=''dis''+(''patch-''|Write-Output)+''log.jsonl'';[Unknown.Factory]::new($Path)')
    backgroundPlus=@(1,$false,'$Path=''dis''+(''patch-'' &)+''log.jsonl'';[Unknown.Factory]::new($Path)')
    redirectedPlus=@(1,$false,'$Path=''dis''+(''patch-'' > ''unused'')+''log.jsonl'';[Unknown.Factory]::new($Path)')
    scriptBlockPlus=@(2,$false,'$Path=''dis''+(&{throw ''never execute''})+''log.jsonl'';[Unknown.Factory]::new($Path)')
    uncertainMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes(''dis''+(Write-Output ''patch-'')+''log.jsonl'');[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    uncertainAliasMemory=@(3,$false,'$text=''dis''+$Other+''log.jsonl'';$bytes=[Text.Encoding]::UTF8.GetBytes($text);$copy=$bytes;[IO.StreamReader]::new([IO.MemoryStream]::new($copy,$false),[Text.Encoding]::UTF8,$true)')
    uncertainGuardedFile=@(2,$false,('$Path=''rece''+$Other+''ipt.json'';[IO.File]::ReadAllText('+$guard+')'))
    knownReceiptPlus=@(0,$true,'$Path=(''rece''+''ipt'')+''.json'';[Unknown.Factory]::new($Path)')
    knownNumericPlus=@(0,$true,'$count=1+2;[Unknown.Factory]::new($count)')
    knownNumericNestedPlus=@(0,$true,'$count=(1+2)+3;[Unknown.Factory]::new($count)')
    variableOnlyStatic=@(1,$false,'$a=''dis'';$b=''patch-log.jsonl'';$Path=$a+$b;[Unknown.Factory]::Decode($Path)')
    variableOnlyInstance=@(1,$false,'$a=''dis'';$b=''patch-log.jsonl'';$Path=$a+$b;$Decoder.Load($Path)')
    variableOnlyMemory=@(3,$false,'$a=''dis'';$b=''patch-log.jsonl'';$bytes=[Text.Encoding]::UTF8.GetBytes($a+$b);[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    variableAliasMemory=@(3,$false,'$a=''dis'';$b=''patch-log.jsonl'';$text=$a+$b;$other=$text;$bytes=[Text.Encoding]::UTF8.GetBytes($other);[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    expandablePlusStatic=@(1,$false,'$Path="dis${Other}"+"patch-${Other}log.jsonl";[Unknown.Factory]::Decode($Path)')
    expandablePlusMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes("dis${Other}"+"patch-${Other}log.jsonl");[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    interpolationStatic=@(1,$false,'$Path="dis${Other}patch-log.jsonl";[Unknown.Factory]::Decode($Path)')
    interpolationMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes("dis${Other}patch-log.jsonl");[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    formatStatic=@(1,$false,'$Path=''{0}{1}'' -f ''dis'',''patch-log.jsonl'';[Unknown.Factory]::Decode($Path)')
    formatInstance=@(1,$false,'$Path=''{0}{1}'' -f ''dis'',''patch-log.jsonl'';$Decoder.Load($Path)')
    formatMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes((''{0}{1}'' -f ''dis'',''patch-log.jsonl''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    variableFormat=@(1,$false,'$format=''{0}{1}'';$a=''dis'';$b=''patch-log.jsonl'';$Path=$format -f $a,$b;[Unknown.Factory]::Decode($Path)')
    typedVariablePlus=@(1,$false,'[int]$a=1;[int]$b=2;$count=$a+$b;[Unknown.Factory]::new($count)')
    unresolvedVariablePlus=@(1,$false,'$Path=$First+$Second;[Unknown.Factory]::Decode($Path)')
    variableCostMemory=@(3,$false,'$a=''cost-'';$b=''ledger.jsonl'';$bytes=[Text.Encoding]::UTF8.GetBytes($a+$b);[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    unaryJoinStatic=@(1,$false,'$Path=-join (''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    unaryJoinMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes((-join (''dis'',''patch-log.jsonl'')));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    binaryJoinStatic=@(1,$false,'$Path=(''dis'',''patch-log.jsonl'') -join '''';[Unknown.Factory]::Decode($Path)')
    binaryJoinMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes(((''dis'',''patch-log.jsonl'') -join ''''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    variableUnaryJoin=@(1,$false,'$Path=-join $Other;[Unknown.Factory]::Decode($Path)')
    variableBinaryJoin=@(1,$false,'$Path=$Other -join $Path;[Unknown.Factory]::Decode($Path)')
    joinInstance=@(1,$false,'$Path=-join (''dis'',''patch-log.jsonl'');$Decoder.Load($Path)')
    joinCostMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes((-join (''cost-'',''ledger.jsonl'')));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    replaceStatic=@(1,$false,'$Path=''disXpatch-log.jsonl'' -replace ''X'','''';[Unknown.Factory]::Decode($Path)')
    replaceMemory=@(3,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes((''disXpatch-log.jsonl'' -replace ''X'',''''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    caseSensitiveReplace=@(1,$false,'$Path=''disXpatch-log.jsonl'' -creplace ''X'','''';[Unknown.Factory]::Decode($Path)')
    caseInsensitiveReplace=@(1,$false,'$Path=''disXpatch-log.jsonl'' -ireplace ''x'','''';[Unknown.Factory]::Decode($Path)')
    stringConcatStatic=@(2,$false,'$Path=[string]::Concat(''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    stringConcatMemory=@(4,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes([string]::Concat(''dis'',''patch-log.jsonl''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    systemStringConcat=@(2,$false,'$Path=[System.String]::Concat(''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    stringJoinStatic=@(2,$false,'$Path=[string]::Join('''',(''dis'',''patch-log.jsonl''));[Unknown.Factory]::Decode($Path)')
    stringJoinMemory=@(4,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes([string]::Join('''',(''dis'',''patch-log.jsonl'')));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    stringFormatStatic=@(2,$false,'$Path=[string]::Format(''{0}{1}'',''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    stringConstructorStatic=@(2,$false,'$Path=[string]::new([char[]]@(100,105,115,112,97,116,99,104,45,108,111,103,46,106,115,111,110,108));[Unknown.Factory]::Decode($Path)')
    stringDynamicMember=@(2,$false,'$Path=[string]::$Other(''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    stringVariableArguments=@(2,$false,'$Path=[string]::Concat($Other,$Path);[Unknown.Factory]::Decode($Path)')
    literalStringReplace=@(2,$false,'$Path=''disXpatch-log.jsonl''.Replace(''X'','''');[Unknown.Factory]::Decode($Path)')
    literalStringReplaceMemory=@(4,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes(''disXpatch-log.jsonl''.Replace(''X'',''''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    expandableStringReplace=@(2,$false,'$Path="disXpatch-log.jsonl".Replace(''X'','''');[Unknown.Factory]::Decode($Path)')
    stringCostMemory=@(4,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes([string]::Concat(''cost-'',''ledger.jsonl''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    stringCaseInsensitiveType=@(2,$false,'$Path=[sYsTeM.sTrInG]::Concat(''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    wrappedStringLiteral=@(2,$false,'$Path=(''disXpatch-log.jsonl'').Replace(''X'','''');[Unknown.Factory]::Decode($Path)')
    wrappedStringMemory=@(4,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes((''disXpatch-log.jsonl'').Replace(''X'',''''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    wrappedStringType=@(2,$false,'$Path=([string])::Concat(''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    variableStringReceiver=@(2,$false,'$piece=''disXpatch-log.jsonl'';$Path=$piece.Replace(''X'','''');[Unknown.Factory]::Decode($Path)')
    variableStringMemory=@(4,$false,'$piece=''disXpatch-log.jsonl'';$bytes=[Text.Encoding]::UTF8.GetBytes($piece.Replace(''X'',''''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    unresolvedInstanceResult=@(2,$false,'$Path=$Other.Compose();[Unknown.Factory]::Decode($Path)')
    variableStringType=@(2,$false,'$type=[string];$Path=$type::Concat(''dis'',''patch-log.jsonl'');[Unknown.Factory]::Decode($Path)')
    variableStringTypeMemory=@(4,$false,'$type=[string];$bytes=[Text.Encoding]::UTF8.GetBytes($type::Concat(''dis'',''patch-log.jsonl''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    wrappedVariableReceiver=@(2,$false,'$Path=($Other).Replace(''X'','''');[Unknown.Factory]::Decode($Path)')
    castStringReceiver=@(2,$false,'$Path=([string]$Other).Replace(''X'','''');[Unknown.Factory]::Decode($Path)')
    castStringMemory=@(4,$false,'$bytes=[Text.Encoding]::UTF8.GetBytes(([string]$Other).Replace(''X'',''''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)')
    concatStringReceiver=@(2,$false,'$Path=(''disX''+''patch-log.jsonl'').Replace(''X'','''');[Unknown.Factory]::Decode($Path)')
    knownNumericMultiply=@(0,$true,'$count=2*3;[Unknown.Factory]::new($count)')
    knownNumericNegation=@(0,$true,'$count=-2;[Unknown.Factory]::new($count)')
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
  foreach($depth in @(10,12,20)) {
    $expression=('('*$depth)+'''dis''+''patch-'''+(')'*$depth)+'+''log.jsonl'''
    $cases["depthConstructor$depth"]=@(1,$false,('$Path='+$expression+';[Unknown.Factory]::new($Path)'))
    $cases["depthMemory$depth"]=@(3,$false,('$bytes=[Text.Encoding]::UTF8.GetBytes('+$expression+');[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)'))
  }
  foreach($depth in @(12,20)) {
    $receiver=('('*$depth)+'''disXpatch-log.jsonl'''+(')'*$depth)
    $cases["depthMethod$depth"]=@(2,$false,('$Path='+$receiver+'.Replace(''X'','''');[Unknown.Factory]::Decode($Path)'))
    $cases["depthMethodMemory$depth"]=@(4,$false,('$bytes=[Text.Encoding]::UTF8.GetBytes('+$receiver+'.Replace(''X'',''''));[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)'))
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
    $canonicalOwner=@($c.rows|Where-Object {$_.path -ceq '.orchestrator/dispatch-ledger-reader.psm1' -and $_.family -ceq 'IO.File.Open' -and $_.owner})
    Check ($canonicalOwner.Count -eq 1 -and $canonicalOwner[0].handled -and $canonicalOwner[0].authority -eq 'dispatch') "authenticated native owner retained $name"
    $rows=@($c.rows|Where-Object path -CEQ 'reader.ps1')
    $violations=@($c.violations|Where-Object path -CEQ 'reader.ps1')
    $valid=$rows.Count -eq $cases[$name][0] -and @($rows|Where-Object owner).Count -eq 0 -and
      @($rows|Where-Object {[bool]$_.handled -ne $cases[$name][1]}).Count -eq 0 -and
      $violations.Count -eq $(if($cases[$name][1]){0}else{$cases[$name][0]})
    if($name -ceq 'uncertainGuardedFile') {
      # The actual native value guard retains authority; its uncertain input
      # forwarding command is additionally inventoried, not silently discarded.
      $valid=$rows.Count -eq 2 -and @($rows|Where-Object owner).Count -eq 0 -and
        @($rows|Where-Object {$_.family -eq 'IO.File.ReadAllText' -and $_.handled -and $_.authority -eq 'non-ledger'}).Count -eq 1 -and
        $violations.Count -eq 1 -and $violations[0].family -eq 'get-nondispatchledgerpath'
    }
    if($name -ceq 'scriptBlockPlus') {
      # Both the original constructor and the opaque call operator must remain
      # inventoried refusals; added uncertainty must not hide either shape.
      Check (@($rows|Where-Object {$_.family -ceq 'unknown-static-type' -and $_.role -ceq 'unclassified' -and -not $_.handled}).Count -eq 1) 'scriptblock composition retains constructor refusal'
      Check (@($rows|Where-Object {-not $_.family -and $_.role -ceq 'unclassified' -and -not $_.handled}).Count -eq 1) 'scriptblock composition inventories opaque invocation refusal'
    }
    if(-not $valid){$failures.Add($name)}
    if($name -ceq 'groupedMemoryCost' -and @($rows|Where-Object authority -EQ 'cost').Count -ne 1){$failures.Add('groupedMemoryCostAuthority')}
    $checks++
    "CONSTRUCTOR case=$name rows=$($rows.Count) handled=$(@($rows|Where-Object handled).Count) violations=$($violations.Count) expectedRows=$($cases[$name][0]) expectedHandled=$($cases[$name][1])"
  }
  Check ($failures.Count -eq 0) "constructor inventory/proof controls: $($failures -join ',')"
  $ownerCompositions=[ordered]@{
    plus='($Path+$suffix)'
    interpolation='"${Path}${suffix}"'
    format='(''{0}{1}'' -f $Path,$suffix)'
  }
  foreach($composition in $ownerCompositions.Keys) {
    foreach($consumer in @('opaque','memory')) {
      $body='$suffix='''';Read-DispatchLedgerSnapshot -Path '+$ownerCompositions[$composition]+';'
      $body+=if($consumer -eq 'opaque'){'[Unknown.Factory]::Decode($Path)'}else{'$bytes=[Text.Encoding]::UTF8.GetBytes($Path);[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)'}
      $source='throw ''inspected source must never execute'''+"`n"+$import+"`nfunction Read-Synthetic([string]`$Path){"+$body+'}'
      [IO.File]::WriteAllText($path,$source)
      $errors=$null
      [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
      Check ($errors.Count -eq 0) "owner composition parses $composition/$consumer"
      $c=Get-LedgerReaderCensus -Root $root
      Check ($c.scanned -eq 2 -and $c.total -eq 2) "owner composition complete inventory $composition/$consumer"
      $rows=@($c.rows|Where-Object path -CEQ 'reader.ps1')
      $owners=@($rows|Where-Object owner)
      $native=@($rows|Where-Object {-not $_.owner})
      $violations=@($c.violations|Where-Object path -CEQ 'reader.ps1')
      $expected=if($consumer -eq 'opaque'){1}else{3}
      Check ($owners.Count -eq 1 -and $owners[0].handled -and $owners[0].authority -eq 'dispatch') "owner composition owner retained $composition/$consumer"
      Check ($native.Count -eq $expected -and @($native|Where-Object handled).Count -eq 0 -and $violations.Count -eq $expected) "owner composition native enforcement $composition/$consumer"
      if($consumer -eq 'memory') {
        $readers=@($native|Where-Object family -EQ 'StreamReader')
        Check ($readers.Count -eq 1 -and $readers[0].authority -eq 'dispatch' -and -not $readers[0].handled) "owner composition cannot prove nonledger memory $composition"
      }
      "OWNER-COMPOSITION case=$composition/$consumer owner=$($owners.Count) native=$($native.Count) violations=$($violations.Count)"
    }
  }
  foreach($order in @('forward','reverse')) {
    foreach($consumer in @('opaque','memory')) {
      $first='Read-DispatchLedgerSnapshot -Path ($Path+''''+$suffix);'
      $second='Read-DispatchLedgerSnapshot -Path (Join-Path $Path $leaf);'
      $body=if($order -eq 'forward'){$first+$second}else{$second+$first}
      $body+=if($consumer -eq 'opaque'){'[Unknown.Factory]::Decode($leaf)'}else{'$bytes=[Text.Encoding]::UTF8.GetBytes($leaf);[IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)'}
      $source='throw ''inspected source must never execute'''+"`n"+$import+"`nfunction Read-Synthetic([string]`$Path,[string]`$suffix,[string]`$leaf){"+$body+'}'
      [IO.File]::WriteAllText($path,$source)
      $errors=$null
      [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
      Check ($errors.Count -eq 0) "overlapping owner source parses $order/$consumer"
      $c=Get-LedgerReaderCensus -Root $root
      Check ($c.scanned -eq 2 -and $c.total -eq 2) "overlapping owner complete inventory $order/$consumer"
      $rows=@($c.rows|Where-Object path -CEQ 'reader.ps1')
      $owners=@($rows|Where-Object owner)
      $violations=@($c.violations|Where-Object path -CEQ 'reader.ps1')
      $expected=if($consumer -eq 'opaque'){1}else{3}
      Check ($owners.Count -eq 2 -and @($owners|Where-Object {-not $_.handled -or $_.authority -ne 'dispatch'}).Count -eq 0) "overlapping owners retained $order/$consumer"
      Check ($rows.Count -eq ($expected+3) -and $violations.Count -eq $expected -and @($violations|Where-Object handled).Count -eq 0) "overlapping owner consumer enforced $order/$consumer"
      if($consumer -eq 'memory') {
        $readers=@($rows|Where-Object family -EQ 'StreamReader')
        Check ($readers.Count -eq 1 -and $readers[0].authority -eq 'dispatch' -and -not $readers[0].handled) "overlapping owner cannot prove nonledger memory $order"
      }
      "OVERLAPPING-OWNER case=$order/$consumer owners=$($owners.Count) rows=$($rows.Count) violations=$($violations.Count)"
    }
  }
  foreach($consumer in @('writer','forwarder','guardedReader')) {
    $body='$joined=$Path+$suffix;Read-DispatchLedgerSnapshot -Path $Path;'
    $body+=switch($consumer) {
      writer {'[IO.File]::WriteAllText($joined,''x'')'}
      forwarder {'Write-Output $joined'}
      guardedReader {'[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $joined))'}
    }
    $source='throw ''inspected source must never execute'''+"`n"+$import+"`nfunction Read-Synthetic([string]`$Path,[string]`$suffix){"+$body+'}'
    [IO.File]::WriteAllText($path,$source)
    $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
    Check ($errors.Count -eq 0) "mixed-mask source parses $consumer"
    $c=Get-LedgerReaderCensus -Root $root
    Check ($c.scanned -eq 2 -and $c.total -eq 2) "mixed-mask complete inventory $consumer"
    $rows=@($c.rows|Where-Object path -CEQ 'reader.ps1')
    $owners=@($rows|Where-Object owner)
    $violations=@($c.violations|Where-Object path -CEQ 'reader.ps1')
    Check ($owners.Count -eq 1 -and $owners[0].handled) "mixed-mask owner retained $consumer"
    $expected=if($consumer -eq 'guardedReader'){3}else{2}
    Check ($rows.Count -eq $expected -and $violations.Count -eq 1 -and -not $violations[0].handled -and $violations[0].authority -eq 'indeterminate') "uncertainty cannot become positive authority $consumer"
    if($consumer -eq 'guardedReader') {
      $native=@($rows|Where-Object family -EQ 'IO.File.ReadAllText')
      Check ($native.Count -eq 1 -and $native[0].handled -and $native[0].authority -eq 'non-ledger') 'actual value guard retains independent authority'
    }
    "MIXED-MASK case=$consumer rows=$($rows.Count) violations=$($violations.Count)"
  }
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
