$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'controller-ci-record-durations.ps1') -Library
function Refuses-Record([scriptblock]$Body){$refused=$false;try{&$Body|Out-Null}catch{$refused=$true};Assert-Ci $refused 'recorder bypass survived'}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ci-record-check-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try{
  & git -C $temp init -q
  & git -C $temp config user.name Synthetic
  & git -C $temp config user.email synthetic@example.invalid
  & git -C $temp config core.autocrlf false
  $unicode='caf'+[char]0xe9+' '+[char]0x96ea
  foreach($ending in @('lf','crlf')){foreach($final in @($false,$true)){
    $text=$unicode+"`n"+'last'+$(if($final){"`n"}else{''})
    if($ending-ceq'crlf'){$text=$text.Replace("`n","`r`n")}
    $name="$ending-$final.ps1"
    [IO.File]::WriteAllText((Join-Path $temp $name),$text,[Text.UTF8Encoding]::new($false))
  }}
  & git -C $temp add .
  & git -C $temp commit -qm synthetic
  Assert-Ci ($LASTEXITCODE-eq0) 'recorder fixture commit failed'
  $head=(Get-CiHead $temp)
  $oldEncoding=$OutputEncoding;$oldConsole=[Console]::OutputEncoding
  try{
    $observed=@(foreach($encoding in @([Text.UTF8Encoding]::new($false),[Text.Encoding]::GetEncoding(437))){
      $OutputEncoding=$encoding;[Console]::OutputEncoding=$encoding
      foreach($name in @('lf-False.ps1','crlf-False.ps1','lf-True.ps1','crlf-True.ps1')){Get-CiBlobDigest $temp $head $name}
    })
  }finally{$OutputEncoding=$oldEncoding;[Console]::OutputEncoding=$oldConsole}
  Assert-Ci ($observed[0]-ceq$observed[1]-and$observed[2]-ceq$observed[3]-and$observed[0]-cne$observed[2]) 'line endings or final newline corrupted'
  Assert-Ci (($observed[0..3]-join',')-ceq($observed[4..7]-join',')) 'console encoding changed blob digest'
  Assert-Ci ($observed[0]-ceq(Get-CiTextDigest ([Text.Encoding]::UTF8.GetBytes($unicode+"`n"+'last')))) 'non-ASCII source digest corrupted'
  Refuses-Record {Get-CiBlobDigest $temp $head 'missing.ps1'}
  Refuses-Record {Get-CiBlobDigest $temp ('f'*40) 'lf-False.ps1'}
  $plan=@{checkoutHead=$head;controllerHead=$head;runnerHead=('b'*40);productSha=('c'*40)
    executionItems=@(@{identity='test:encoding';path='lf-False.ps1';restriction=$null})}
  $result=@{controllerHead=$head;ci=@{checkoutHead=$head;runnerHead=$plan.runnerHead;productSha=$plan.productSha
    planSha256=('d'*64);runId='123';executionResults=@(@{identity='test:encoding';result='PASS';exitCode=0;elapsedMs=1234;finishedUtc='2026-10-23T00:00:00Z'})}}
  $record=@(New-CiDurationRecords $plan $result ('d'*64) $temp)[0]
  Assert-Ci ($record.elapsedMs-eq1234-and$record.recordedAtUtc-ceq'2026-10-23T00:00:00Z'-and$record.runId-ceq'123'-and
    $record.checkoutHead-ceq$head-and$record.runnerHead-ceq$plan.runnerHead-and$record.productSha-ceq$plan.productSha-and
    $record.planSha256-ceq('d'*64)-and$record.sourceSha256-ceq$observed[0]) 'measured provenance changed'
  $result.ci.planSha256='wrong';Refuses-Record {New-CiDurationRecords $plan $result ('d'*64) $temp}
  Write-Output 'PASS recorder exact blob bytes, UTF-8/non-UTF-8 consoles, non-ASCII, CRLF/LF, final-newline distinction, unchanged provenance and unreadable-blob refusals'
}finally{
  $resolved=[IO.Path]::GetFullPath($temp)
  Assert-Ci ((Split-Path -Parent $resolved)-ceq[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')) 'unsafe recorder fixture cleanup'
  Remove-Item -LiteralPath $resolved -Recurse -Force
}
