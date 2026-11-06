$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'ledger-reader-census.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('ledger-inventory-'+[guid]::NewGuid().ToString('N'))
$checks=0
function Check([bool]$Value,[string]$Message){$script:checks++;if(-not $Value){throw "ASSERT: $Message"}}
try {
  [void][IO.Directory]::CreateDirectory($root)
  $sources=[ordered]@{
    'lower.ps1'='throw ''never execute inspected source'';[IO.File]::ReadAllText(''dispatch-log.jsonl'')'
    'UPPER.PS1'='throw ''never execute inspected source'';[IO.File]::ReadAllText(''dispatch-log.jsonl'')'
    'Mixed.Ps1'='[IO.File]::ReadAllText(''dispatch-log.jsonl'')'
    'lower-module.psm1'='[IO.File]::ReadAllText(''dispatch-log.jsonl'')'
    'UPPER-MODULE.PSM1'='[IO.File]::ReadAllText(''dispatch-log.jsonl'')'
    'Mixed-Module.PsM1'='[IO.File]::ReadAllText(''dispatch-log.jsonl'')'
    'lower-native.cs'='class Synthetic { string Read() => System.IO.File.ReadAllText("dispatch-log.jsonl"); }'
    'UPPER-NATIVE.CS'='class Synthetic { string Read() => System.IO.File.ReadAllText("dispatch-log.jsonl"); }'
    'Mixed-Native.Cs'='class Synthetic { string Read() => System.IO.File.ReadAllText("dispatch-log.jsonl"); }'
    'REPORT.TEST.PS1'='[IO.File]::ReadAllText(''dispatch-log.jsonl'')'
    'RECEIPT.PSM1'='[IO.File]::ReadAllText(''receipt.json'')'
  }
  foreach($path in $sources.Keys){[IO.File]::WriteAllText((Join-Path $root $path),$sources[$path])}
  & git -C $root init -q
  if($LASTEXITCODE){throw 'fixture init failed'}
  & git -C $root add -- @($sources.Keys)
  if($LASTEXITCODE){throw 'fixture track failed'}
  & git -C $root -c user.name=Synthetic -c user.email=synthetic@example.invalid commit -qm inventory
  if($LASTEXITCODE){throw 'fixture commit failed'}
  $c=Get-LedgerReaderCensus -Root $root
  Check ($c.scanned -eq $sources.Count -and $c.total -eq $sources.Count) "every tracked extension scanned: got $($c.scanned)/$($sources.Count)"
  foreach($path in $sources.Keys){
    $digest=@($c.sourceDigests|Where-Object path -CEQ $path)
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sources[$path]))).ToLowerInvariant()
    Check ($digest.Count -eq 1 -and $digest[0].sha256 -ceq $hash) "exact source digest $path"
    $rows=@($c.rows|Where-Object path -CEQ $path)
    if($path -ceq 'REPORT.TEST.PS1'){
      Check ($rows.Count -eq 1 -and $rows[0].test -and -not $rows[0].handled -and @($c.violations|Where-Object path -CEQ $path).Count -eq 0) 'mixed-case test remains report-only, not invisible or production'
    } elseif($path -ceq 'RECEIPT.PSM1'){
      Check ($rows.Count -eq 1 -and $rows[0].handled -and $rows[0].authority -ceq 'non-ledger') 'unrelated mixed-case source retains per-use exclusion'
    } else {
      Check ($rows.Count -eq 1 -and -not $rows[0].test -and -not $rows[0].handled -and @($c.violations|Where-Object path -CEQ $path).Count -eq 1) "native production reader refuses $path"
      if($path -match '(?i)\.cs$'){Check ($rows[0].family -ceq 'native-source') "C# is not misparsed as PowerShell: $path"}
    }
  }
  Check ($c.violations.Count -eq 9) 'all nine production readers refuse across case variants'
  "PASS native inventory checks=$checks sources=$($c.scanned) productionRefusals=$($c.violations.Count) reportOnly=1 perUseExclusion=1 noInspectedExecution=true"
} finally {
  $full=[IO.Path]::GetFullPath($root)
  if((Split-Path -Parent $full).TrimEnd('\','/') -cne ([IO.Path]::GetFullPath([IO.Path]::GetTempPath())).TrimEnd('\','/') -or (Split-Path -Leaf $full) -cnotlike 'ledger-inventory-*'){throw 'unsafe fixture cleanup'}
  if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
