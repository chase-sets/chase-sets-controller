$ErrorActionPreference = 'Stop'
$clock = [Diagnostics.Stopwatch]::StartNew()
$kind = 'config'
$list = @($args)
function Arg([string]$Name) {
  foreach ($a in $list) { if ($a.StartsWith($Name + '=')) { return $a.Substring($Name.Length + 1) } }
}
function Save($Path, $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 25 -Compress)) }
try {
  if ($args[0] -eq 'variable') {
    if ($args[2] -eq 'DELIVERY_STATUS_OPTION_IDS') { '{"In lane":"lane","In review":"review","Landed":"landed"}' }
    else { 'PVT_SYNTHETIC' }
  } elseif ($args[0] -eq 'workflow') { $kind = 'sync'; '{"ok":true}' }
  else {
    $query = Arg 'query'
    if ($query -match 'mutation') {
      $kind = 'mutation'
      $number = [int]((Arg 'i') -replace '^PVTI_SYNTHETIC_', '')
      $path = Join-Path $PSScriptRoot "item-$number.json"
      $item = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
      $item.status.name = if ($query -match 'clearProject') { '' } else { switch (Arg 'o') { 'lane' { 'In lane' }; 'review' { 'In review' }; 'landed' { 'Landed' } } }
      Save $path $item
      $offset = [int]([Math]::Floor(($number - 8548) / 100) * 100)
      $pagePath = Join-Path $PSScriptRoot "page-$offset.json"
      $page = Get-Content $pagePath -Raw | ConvertFrom-Json -AsHashtable
      $page.data.node.items.nodes[$number - 8548 - $offset] = $item
      Save $pagePath $page
      '{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"synthetic"}},"clearProjectV2ItemFieldValue":{"projectV2Item":{"id":"synthetic"}}}}'
    } elseif ($query -match 'issue\(number:') {
      $kind = 'issue'
      $item = Get-Content (Join-Path $PSScriptRoot "item-$(Arg 'number').json") -Raw | ConvertFrom-Json -AsHashtable
      $issue = $item.content
      $issue.projectItems = @{ nodes = @(@{ id = $item.id; project = @{ id = 'PVT_SYNTHETIC' }; status = $item.status }); pageInfo = @{ hasNextPage = $false } }
      @{ data = @{ repository = @{ issue = $issue } } } | ConvertTo-Json -Depth 25 -Compress
    } else {
      $kind = 'page'
      $offset = if (Arg 'after') { [int](Arg 'after') } else { 0 }
      [IO.File]::ReadAllText((Join-Path $PSScriptRoot "page-$offset.json"))
    }
  }
} finally {
  [IO.File]::AppendAllText((Join-Path $PSScriptRoot 'stub-trace'), (@{ kind = $kind; seconds = $clock.Elapsed.TotalSeconds } | ConvertTo-Json -Compress) + "`n")
}
exit 0
