param([string]$ControllerRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
. (Join-Path $ControllerRoot '.orchestrator/routing-data-test-support.ps1')
$routingTestScope=Enter-RoutingDataTestScope
. (Join-Path $ControllerRoot '.orchestrator/integration-dispatch-contract.ps1')
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('integration-author-test-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory $root | Out-Null
  $future = [datetimeoffset]::UtcNow.AddDays(1).ToString('o')
  $accounts = @(
    [ordered]@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='blocked';next_retry_after=$future}}},
    [ordered]@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='blocked';next_retry_after=$future}}},
    [ordered]@{provider='claude';disabled=$false;routingModels=@{}}
  )
  function Select-Fixture($Name, $Payload) {
    $path = Join-Path $root "$Name.json"
    [IO.File]::WriteAllText($path, ($Payload | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    Get-LandedIntegrationAuthor $path
  }
  $blocked = Select-Fixture 'blocked' @{accounts=$accounts;error=$null}
  Assert-True ($blocked.harness -ceq 'claude' -and $blocked.model -ceq 'claude-fable-5-1') 'all blocked with future resets must select Fable on Claude'
  $accounts[1].routingModels.'gpt-6-astra'.status = 'ready'
  Assert-True ((Select-Fixture 'one-ready' @{accounts=$accounts}).model -ceq 'gpt-6-astra') 'one ready account must retain Astra'
  $accounts[1].disabled = $true
  Assert-True ((Select-Fixture 'disabled-ready' @{accounts=$accounts}).model -ceq 'claude-fable-5-1') 'disabled accounts must not defeat an all-enabled block'
  $accounts[1].disabled = $false; $accounts[1].routingModels.'gpt-6-astra'.status = 'blocked'
  foreach ($variant in @('missing-reset','past-reset','missing-model','bad-account','bad-shape','error','unparsable')) {
    $payload = @{accounts=($accounts | ConvertTo-Json -Depth 8 | ConvertFrom-Json -DateKind String);error=$null}
    switch ($variant) {
      'missing-reset' { $payload.accounts[0].routingModels.'gpt-6-astra'.PSObject.Properties.Remove('next_retry_after') }
      'past-reset' { $payload.accounts[0].routingModels.'gpt-6-astra'.next_retry_after = '2020-01-01T00:00:00Z' }
      'missing-model' { $payload.accounts[0].routingModels.PSObject.Properties.Remove('gpt-6-astra') }
      'bad-account' { $payload.accounts[1].disabled = 'unknown' }
      'bad-shape' { $payload.accounts = 'blocked' }
      'error' { $payload.error = 'status unavailable' }
    }
    if ($variant -eq 'unparsable') {
      $path=Join-Path $root 'unparsable.json';[IO.File]::WriteAllText($path, '{invalid')
      $selected=Get-LandedIntegrationAuthor $path
    } else { $selected=Select-Fixture $variant $payload }
    Assert-True ($selected.model -ceq 'gpt-6-astra') "$variant must fail closed"
  }
  $missing = Get-LandedIntegrationAuthor (Join-Path $root 'unreachable.json')
  Assert-True ($missing.model -ceq 'gpt-6-astra') 'unreachable status must fail closed'
  Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading.Tasks;
public sealed class IntegrationStatusServer : IDisposable {
  private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
  private Task serving;
  public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
  public IntegrationStatusServer(string body) {
    listener.Start();
    serving = Task.Run(async () => {
      using (var client = await listener.AcceptTcpClientAsync()) {
        var stream = client.GetStream();
        var buffer = new byte[4096];
        await stream.ReadAsync(buffer, 0, buffer.Length);
        var bytes = Encoding.UTF8.GetBytes(body);
        var header = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + bytes.Length + "\r\nConnection: close\r\n\r\n");
        await stream.WriteAsync(header, 0, header.Length);
        await stream.WriteAsync(bytes, 0, bytes.Length);
      }
    });
  }
  public void Dispose() { listener.Stop(); if (serving.IsCompleted) serving.GetAwaiter().GetResult(); }
}
'@
  $previousPoolUrl=$env:CODEX_POOL_STATUS_URL
  try {
    foreach ($case in @(@('http-blocked',@{accounts=$accounts;error=$null},'claude-fable-5-1'),@('http-ready',@{accounts=@(@{provider='codex';disabled=$false;routingModels=@{'gpt-6-astra'=@{status='ready'}}})},'gpt-6-astra'))) {
      $server=[IntegrationStatusServer]::new(($case[1] | ConvertTo-Json -Depth 8))
      try {
        $env:CODEX_POOL_STATUS_URL="http://127.0.0.1:$($server.Port)/api/status"
        Assert-True ((Get-LandedIntegrationAuthor).model -ceq $case[2]) "$($case[0]) selection through HTTP parser"
      } finally { $server.Dispose() }
    }
  } finally {
    if($null-eq$previousPoolUrl){Remove-Item Env:CODEX_POOL_STATUS_URL -ErrorAction SilentlyContinue}else{$env:CODEX_POOL_STATUS_URL=$previousPoolUrl}
  }
  foreach ($tuple in @(@('codex','gpt-6-astra'),@('claude','claude-fable-5-1'))) {
    Assert-IntegrationAuthor $tuple[0] $tuple[1] high 7 override-Todd
  }
  foreach ($tuple in @(@('codex','claude-fable-5-1','high',7,'override-Todd'),@('claude','gpt-6-astra','high',7,'override-Todd'),@('claude','claude-fable-5','high',7,'override-Todd'),@('claude','claude-fable-5-1','medium',7,'override-Todd'),@('claude','claude-fable-5-1','high',4,'override-Todd'),@('claude','claude-fable-5-1','high',7,'provisional'))) {
    $rejected=$false;try { Assert-IntegrationAuthor @tuple } catch { $rejected=$_.Exception.Message -like 'INTEGRATION_AUTHOR_UNAVAILABLE*' }
    Assert-True $rejected "out-of-set author $($tuple -join '/') admitted"
  }
  Write-Output 'PASS integration author pool admission, fail-closed status, and closed route set'
} finally {
  Exit-RoutingDataTestScope $routingTestScope
  $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')
  if ((Split-Path -Parent $resolved).TrimEnd('\','/') -ne $temp -or (Split-Path -Leaf $resolved) -notlike 'integration-author-test-*') { throw "unsafe cleanup $resolved" }
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
