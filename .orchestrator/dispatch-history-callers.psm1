# Direct-call coverage, not execution or reader authority. Native/alias provenance
# and actual above-cliff behavior remain separate, mandatory contract gates.
Import-Module (Join-Path $PSScriptRoot 'dispatch-ledger-reader.psm1') -Global -DisableNameChecking -ErrorAction Stop

function Get-DispatchCallerHash([string]$Text) {
  [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-DispatchCallerEnvelope([string]$Path,[string]$Scope,[string]$Api) {
  if($Api -ceq 'read-checkpointeddispatchhistory' -or
      ($Path -ceq '.orchestrator/dispatch-history-checkpoint.psm1' -and $Scope -ceq 'Read-CheckpointedDispatchHistory' -and $Api -ceq 'read-dispatchcounthistory')) {
    return @('checkpoint','dispatch-count/v1','projection+delta')
  }
  if($Api -cin @('read-dispatchcounthistory','read-exactheadreviewhistory')) { return @('one-pass-stream','dispatch-count/v1','parsed-history') }
  $projection=switch -CaseSensitive ($Api) {
    'read-dispatchledgerlines' {'captured-lines'}
    'read-dispatchledgerbytes' {'captured-bytes'}
    'read-dispatchledgersnapshot' {'captured-bytes+lines'}
    default {throw "CALLER_API_UNKNOWN:$Api"}
  }
  return @('one-pass-snapshot',$projection,'captured-history')
}

function Read-DispatchCallerManifest([string]$Path) {
  $text=[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path $Path))
  $options=[System.Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=16
  $doc=[System.Text.Json.JsonDocument]::Parse($text,$options)
  try {
    function Assert-Fields($Node,[string[]]$Fields) {
      if($Node.ValueKind -ne [System.Text.Json.JsonValueKind]::Object){throw 'CALLER_MANIFEST_OBJECT_REQUIRED'}
      $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
      foreach($p in $Node.EnumerateObject()) {
        if($p.Name -cnotin $Fields -or -not $seen.Add($p.Name)){throw 'CALLER_MANIFEST_FIELDS'}
      }
      if($seen.Count -ne $Fields.Count){throw 'CALLER_MANIFEST_FIELDS'}
    }
    Assert-Fields $doc.RootElement @('schemaVersion','rows')
    $version=$doc.RootElement.GetProperty('schemaVersion')
    $items=$doc.RootElement.GetProperty('rows')
    if($version.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or $version.GetString() -cne 'dispatch-history-callers/v1' -or
        $items.ValueKind -ne [System.Text.Json.JsonValueKind]::Array){throw 'CALLER_MANIFEST_SCHEMA'}
    $rows=[Collections.Generic.List[object]]::new()
    foreach($item in $items.EnumerateArray()) {
      Assert-Fields $item @('path','scope','api','ordinal','mode','projection','peakEnvelope','callSha256')
      $row=[ordered]@{}
      foreach($name in @('path','scope','api','mode','projection','peakEnvelope','callSha256')) {
        $value=$item.GetProperty($name)
        if($value.ValueKind -ne [System.Text.Json.JsonValueKind]::String -or -not $value.GetString() -or $value.GetString() -match '[\x00-\x1f]'){throw 'CALLER_MANIFEST_STRING'}
        $row[$name]=$value.GetString()
      }
      $ordinal=$item.GetProperty('ordinal')
      if($ordinal.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or $ordinal.GetRawText() -cnotmatch '^[1-9][0-9]*$'){throw 'CALLER_MANIFEST_ORDINAL'}
      $row.ordinal=$ordinal.GetInt32()
      if($row.path -match '(^|/|\\)\.\.?(/|\\|$)|\\|:' -or [IO.Path]::IsPathRooted($row.path) -or $row.callSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'CALLER_MANIFEST_IDENTITY'}
      $envelope=Get-DispatchCallerEnvelope $row.path $row.scope $row.api
      if($row.mode -cne $envelope[0] -or $row.projection -cne $envelope[1] -or $row.peakEnvelope -cne $envelope[2]){throw 'CALLER_MANIFEST_ENVELOPE'}
      $rows.Add([pscustomobject]$row)
    }
    return [pscustomobject]@{rows=$rows.ToArray();sha256=(Get-DispatchCallerHash $text)}
  } finally {$doc.Dispose()}
}

function Get-DispatchHistoryCallerCensus {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Root,
    [string]$ManifestPath=(Join-Path $PSScriptRoot 'contracts/dispatch-history-callers.json'),[hashtable]$SourceOverride=@{})
  $manifest=Read-DispatchCallerManifest $ManifestPath
  $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  foreach($row in $manifest.rows) {
    $key="$($row.path)`n$($row.scope)`n$($row.api)`n$($row.ordinal)"
    if(-not $expected.TryAdd($key,$row)){throw 'CALLER_MANIFEST_DUPLICATE'}
  }
  $paths=@(& git -C $Root ls-files -- ':(icase)*.ps1' ':(icase)*.psm1')
  if($LASTEXITCODE -ne 0 -or -not $paths.Count){throw 'CALLER_INVENTORY_MISSING'}
  foreach($key in $SourceOverride.Keys){if($key -cnotin $paths){throw "CALLER_OVERRIDE_UNTRACKED:$key"}}
  $apis=@('read-exactheadreviewhistory','read-dispatchledgersnapshot','read-dispatchledgerlines','read-dispatchledgerbytes','read-dispatchcounthistory','read-checkpointeddispatchhistory')
  $rows=[Collections.Generic.List[object]]::new();$tests=[Collections.Generic.List[object]]::new()
  $violations=[Collections.Generic.List[object]]::new();$digests=[Collections.Generic.List[object]]::new()
  $observed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($path in $paths) {
    $text=if($SourceOverride.ContainsKey($path)){$SourceOverride[$path]}else{[IO.File]::ReadAllText((dispatch-ledger-reader\Get-NonDispatchLedgerPath -Path (Join-Path $Root $path)))}
    $digests.Add([pscustomobject]@{path=$path;sha256=(Get-DispatchCallerHash $text)})
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw "CALLER_SOURCE_PARSE:$path"}
    $test=$path -match '(?i)(^|/)(fixtures|diagnostics)/|(?:\.test|\.check|\.test-support|-test-support|-fixture-harness|-test-fixture)\.ps1$|/issue-\d+-(?:discriminator|live-readonly-proof)\.ps1$'
    $ordinals=@{}
    foreach($call in $ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)) {
      $name=$call.GetCommandName()
      if(-not $name){continue}
      $api=($name -split '\\')[-1].ToLowerInvariant()
      if($api -cnotin $apis){continue}
      $scope=$call.Parent
      while($scope -and $scope -isnot [Management.Automation.Language.FunctionDefinitionAst]){$scope=$scope.Parent}
      $scopeName=if($scope){$scope.Name}else{'<script>'}
      $counter="$scopeName`n$api"
      $ordinals[$counter]=1+[int]$ordinals[$counter]
      $ordinal=$ordinals[$counter]
      $callTokens=$null;$callErrors=$null
      [void][Management.Automation.Language.Parser]::ParseInput($call.Extent.Text,[ref]$callTokens,[ref]$callErrors)
      if($callErrors.Count){throw "CALLER_COMMAND_PARSE:$path"}
      $shape=@($callTokens|Where-Object {$_.Kind -notin @('NewLine','LineContinuation','Comment','EndOfInput')}|ForEach-Object {"$($_.Kind):$($_.Text)"}) -join "`n"
      $key="$path`n$scopeName`n$api`n$ordinal"
      $envelope=Get-DispatchCallerEnvelope $path $scopeName $api
      $row=[pscustomobject]@{path=$path;scope=$scopeName;api=$api;ordinal=$ordinal;line=$call.Extent.StartLineNumber
        callSha256=(Get-DispatchCallerHash $shape);mode=$envelope[0];projection=$envelope[1];peakEnvelope=$envelope[2]}
      if($test){$tests.Add($row);continue}
      $rows.Add($row);[void]$observed.Add($key)
      if(-not $expected.ContainsKey($key)){$violations.Add([pscustomobject]@{reason='CALLER_UNCENSUSED';caller=$row})}
      elseif($expected[$key].callSha256 -cne $row.callSha256){$violations.Add([pscustomobject]@{reason='CALLER_CHANGED';caller=$row})}
    }
  }
  foreach($key in $expected.Keys){if(-not $observed.Contains($key)){$violations.Add([pscustomobject]@{reason='CALLER_REMOVED';caller=$expected[$key]})}}
  $head=(& git -C $Root rev-parse HEAD)
  if($LASTEXITCODE -ne 0 -or $head -cnotmatch '^[a-f0-9]{40}$'){throw 'CALLER_HEAD_MISSING'}
  [pscustomobject]@{schemaVersion='dispatch-history-caller-census/v1';sourceHead=$head;manifestSha256=$manifest.sha256;scanned=$paths.Count;total=$paths.Count
    sourceDigests=$digests.ToArray();rows=$rows.ToArray();testRows=$tests.ToArray();violations=$violations.ToArray();complete=($violations.Count -eq 0)
    qualification='static-direct-call-coverage-only'}
}

Export-ModuleMember -Function Get-DispatchHistoryCallerCensus
