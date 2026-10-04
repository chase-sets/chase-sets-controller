[CmdletBinding()]
param([string]$SourcePath = (Join-Path $PSScriptRoot 'runtime-retention.ps1'), [string]$Case = '*', [switch]$RunMutants, [switch]$DispositionFailureControl)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
if (-not (Test-Path -LiteralPath $SourcePath)) { throw 'RED runtime-retention: implementation missing' }
. $SourcePath -Library
$script:passed = 0
$script:root = Join-Path ([IO.Path]::GetTempPath()) ('runtime-retention-synthetic-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($script:root) | Out-Null
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw "ASSERT: $Message" } }
function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Name -notlike $Case) { return }
    & $Body
    $script:passed++
    "PASS $Name"
}
function New-Fixture {
    $r = Join-Path $script:root ([guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory((Join-Path $r '.orchestrator')) | Out-Null
    Set-Variable -Name HOME -Value $r -Scope Script -Force
    $script:now = [datetime]::SpecifyKind([datetime]'2035-01-20T12:00:00', 'Utc')
    $script:ctx = @{ tracked=@(); references=''; commands=@(); complete=$true }
    $script:authority = New-Authority
    $script:ledger = @{}
    $script:harvestOK = $true
    $script:harvestCalls = 0
    $script:phase = {}
    $script:writer = { param($p,$f) Write-RetentionZip $p $f }
    return $r
}
function New-Authority {
    $a = @{ openIssues=@(); openPrs=@() }
    foreach ($repo in @('chase-sets/chase-sets','todd-skelton/orchestration-platform')) {
        $n=if($repo -eq 'chase-sets/chase-sets'){987654}else{987664}
        $a.openIssues += @{repository=$repo; collection='issues(states:OPEN)'; complete=$true; pages=1; nodes=1; totalCount=1; numbers=@($n)}
        $a.openPrs += @{repository=$repo; collection='pullRequests(states:OPEN)'; complete=$true; pages=1; nodes=1; totalCount=1; nodesData=@(@{number=($n+1); headRefName='synthetic/head'; headRefOid=('a'*40); baseRefName='synthetic/base'})}
    }
    return $a
}
function Put([string]$Root,[string]$Relative='old.log',[string]$Text='archived') {
    $p = Join-Path $Root ".orchestrator/$Relative"
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)) | Out-Null
    [IO.File]::WriteAllText($p,$Text)
    [IO.File]::SetLastWriteTimeUtc($p,$script:now.AddDays(-8))
    $parent = [IO.Path]::GetDirectoryName($p)
    while ($parent.StartsWith((Join-Path $Root '.orchestrator'))) {
        [IO.Directory]::SetLastWriteTimeUtc($parent,$script:now.AddDays(-8))
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    return $p
}
function Run([string]$Root,[switch]$Apply) {
    Invoke-RuntimeRetention -Root $Root -Now $script:now -Apply:$Apply -Dependencies @{
        Context={ param($r) $script:ctx }; Authority={ $script:authority }
        ProtectionSnapshot={ param($r) $script:ctx }
        Harvest={ param($r) $script:harvestCalls++; @{ok=$script:harvestOK; ledger=$script:ledger} }
        Phase={ param($stage,$r) & $script:phase $stage $r }
        ZipWriter={ param($p,$f) & $script:writer $p $f }
    }
}
function Row($Report,[string]$Path='old.log') { @($Report.items | Where-Object path -eq $Path)[0] }
function Tree([string]$Root) {
    @(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $hash = if (-not $_.PSIsContainer) { (Get-FileHash -LiteralPath $_.FullName).Hash } else { '' }
        "$($_.FullName)|$($_.Attributes)|$($_.LastWriteTimeUtc.Ticks)|$hash"
    }) -join "`n"
}
if($DispositionFailureControl){
    $r=New-Fixture; $p=Put $r; $v=Run $r -Apply
    Assert ($v.published -and (Test-Path $p)) 'failed native disposition lost data'
    Assert ((Row $v).action -eq 'retain' -and (Row $v).reason -eq 'changed-during-apply') 'failed disposition falsely reported success'
    'PASS runtime-retention-disposition-refused'; return
}
Test-Case 'runtime-retention-report-only' {
    $r=New-Fixture; $null=Put $r; $before=Tree $r; $v=Run $r
    Assert ((Row $v).action -eq 'archive') 'eligible report'; Assert ((Tree $r) -ceq $before) 'report changed tree'
    Assert ($script:harvestCalls -eq 0) 'report harvested'
}
Test-Case 'runtime-retention-apply-verified' {
    $r=New-Fixture; $p=Put $r; $v=Run $r -Apply
    Assert ($v.published -and (Test-Path $v.archive)) 'archive missing'
    Assert (-not (Test-Path $p)) 'eligible file survived'; Assert ((Row $v).action -eq 'deleted') 'deletion not reported'
    $m=Get-Content -LiteralPath $v.manifest -Raw | ConvertFrom-Json
    Assert ($m.files.Count -eq 1 -and $m.files[0].sha256.Length -eq 64) 'manifest content'
    Assert (Test-RetentionZip $v.archive $m.files) 'archive failed reverify'
}
Test-Case 'runtime-retention-retained-protection-authority-unknown' {
    $r=New-Fixture; $p=Put $r; $script:ctx.complete=$false
    $v=Run $r -Apply
    Assert ((Row $v).reason -eq 'protection-authority-unknown') 'unknown protection authority accepted'
    Assert (Test-Path -LiteralPath $p) 'unknown protection authority deleted file'
    $m=Get-Content -LiteralPath $v.manifest -Raw | ConvertFrom-Json
    Assert (@($m.files | Where-Object source -eq 'old.log').Count -eq 0) 'unknown protection authority archived file'
}
Test-Case 'runtime-retention-context-production' {
    $r=New-Fixture; $id=[guid]::NewGuid().ToString('N')
    # Only the external process adapter is synthetic; context and Git are real.
    Set-Variable -Name HOME -Value $r -Scope Local -Force
    function Get-CimInstance { param($ClassName,$ErrorAction) @() }
    $tracked="$id-tracked.log"; $named="$id-named.log"; $reader="$id-reader.ps1"
    $p=Put $r $tracked; $q=Put $r $named; $null=Put $r $reader "# reads $named"
    & git -C $r init --quiet; Assert ($LASTEXITCODE -eq 0) 'fixture git init'
    & git -C $r add -- ".orchestrator/$tracked" ".orchestrator/$reader"; Assert ($LASTEXITCODE -eq 0) 'fixture git add'
    & git -C $r -c user.name=Synthetic -c user.email=synthetic@example.invalid -c commit.gpgsign=false commit --quiet -m 'synthetic retention fixture'
    Assert ($LASTEXITCODE -eq 0) 'fixture git commit'
    $ctx=Get-RetentionContext $r
    Assert $ctx.complete 'production context incomplete'
    Assert ($ctx.tracked -contains ".orchestrator/$tracked") 'production context lost tracked path'
    Assert ($ctx.references.Contains($named)) 'production context lost reference text'
    $deps=@{Authority={$script:authority};Harvest={@{ok=$true;ledger=@{}}}}
    $v=Invoke-RuntimeRetention -Root $r -Now $script:now -Apply -Dependencies $deps
    Assert ((Row $v $tracked).reason -eq 'tracked' -and (Test-Path -LiteralPath $p)) 'production tracked protection lost'
    Assert ((Row $v $named).reason -eq 'referenced' -and (Test-Path -LiteralPath $q)) 'production reference protection lost'
    $r=New-Fixture; $p=Put $r "$id-orphan.log"
    $ctx=Get-RetentionContext $r
    Assert (-not $ctx.complete) 'non-repository context reports complete'
    $v=Invoke-RuntimeRetention -Root $r -Now $script:now -Apply -Dependencies @{Authority={$script:authority};Harvest={@{ok=$true;ledger=@{}}}}
    Assert ((Row $v "$id-orphan.log").reason -eq 'protection-authority-unknown') 'non-repository protection authority accepted'
    Assert (Test-Path -LiteralPath $p) 'non-repository file lost'
}
Test-Case 'runtime-retention-harvest-production' {
    $r=New-Fixture
    $stub=@'
param([switch]$Backfill,[string]$TranscriptDir,[string]$Ledger)
@{backfill=[bool]$Backfill;transcriptDir=$TranscriptDir;ledger=$Ledger} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'synthetic-arguments.json')
exit ([int][IO.File]::ReadAllText((Join-Path $PSScriptRoot 'synthetic-exit.txt')))
'@
    $null=Put $r 'cost-harvest.ps1' $stub
    foreach($code in @(0,1)) {
        $null=Put $r 'synthetic-exit.txt' ([string]$code)
        $v=Invoke-RetentionHarvest $r
        $argsRead=Get-Content -LiteralPath (Join-Path $r '.orchestrator/synthetic-arguments.json') -Raw | ConvertFrom-Json
        Assert $argsRead.backfill 'production harvest missing -Backfill'
        Assert ($argsRead.transcriptDir -eq (Join-Path $r '.orchestrator')) 'production harvest transcript directory'
        Assert ($argsRead.ledger -eq (Join-Path $r '.orchestrator/cost-ledger.jsonl')) 'production harvest ledger path'
        Assert ($v.ok -eq ($code -eq 0)) "production harvest exit code $code ignored"
    }
}
Test-Case 'runtime-retention-directory-nonempty' {
    Initialize-RetentionNative
    $r=New-Fixture; $p=Put $r 'nonempty/child.log'; $refused=$false
    try {[RuntimeRetention.Handle]::RemoveEmptyDirectory((Split-Path $p -Parent))} catch {$refused=$true}
    Assert $refused 'nonempty directory removal did not throw'
    Assert (Test-Path -LiteralPath $p) 'nonempty directory child lost'
}
Test-Case 'runtime-retention-context-once-and-batch-recheck' {
    $r=New-Fixture; $id=[guid]::NewGuid().ToString('N')
    Set-Variable -Name HOME -Value $r -Scope Local -Force
    function Get-CimInstance { param($ClassName,$ErrorAction) @() }
    & git -C $r init --quiet; Assert ($LASTEXITCODE -eq 0) 'batch fixture git init'
    $reader="$id-reader.ps1"
    $readerPath=Put $r $reader ('# synthetic reference padding ' + ('x' * 6500000))
    $referenceBytes=(Get-Item -LiteralPath $readerPath).Length
    & git -C $r add -- ".orchestrator/$reader"; Assert ($LASTEXITCODE -eq 0) 'batch fixture reader add'
    foreach($n in 1..130){$null=Put $r ("$id-{0:d3}.log" -f $n)}
    $counts=@{context=0;snapshot=0;contextMs=0;snapshotMs=0}
    $deps=@{
        Authority={$script:authority};Harvest={@{ok=$true;ledger=@{}}}
        Context={param($root)
            $counts.context++;$timer=[Diagnostics.Stopwatch]::StartNew();$result=Get-RetentionContext $root
            $counts.contextMs+=$timer.Elapsed.TotalMilliseconds;return $result
        }
        ProtectionSnapshot={param($root)
            $counts.snapshot++
            if($counts.snapshot -eq 2){
                & git -C $root add -- .orchestrator
                Assert ($LASTEXITCODE -eq 0) 'new protection git add'
            }
            $timer=[Diagnostics.Stopwatch]::StartNew();$result=Get-RetentionProtectionSnapshot $root
            $counts.snapshotMs+=$timer.Elapsed.TotalMilliseconds;return $result
        }
    }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $v=Invoke-RuntimeRetention -Root $r -Now $script:now -Apply -Dependencies $deps
    $elapsed=$timer.Elapsed.TotalMilliseconds
    Assert ($null -eq $v.error) 'batch fixture apply failed'
    $deleted=@($v.items | Where-Object action -eq 'deleted')
    $retained=@($v.items | Where-Object { $_.path -like '*.log' -and $_.reason -eq 'tracked' })
    Assert ($deleted.Count -eq 128 -and $retained.Count -eq 2) 'batch reused stale snapshot for newly tracked items'
    foreach($item in $retained){Assert (Test-Path -LiteralPath (Join-Path $r ".orchestrator/$($item.path)")) 'newly tracked item deleted'}
    Assert ($counts.context -eq 1) 'context not built exactly once per run'
    Assert ($counts.snapshot -eq 2) 'delete batches did not refresh protection snapshot'
    'TIMING synthetic items=130 referenceBytes={0} contextBuilds={1} batchSnapshots={2} contextMs={3:F3} snapshotTotalMs={4:F3} runMs={5:F3} perItemMs={6:F3}' -f $referenceBytes,$counts.context,$counts.snapshot,$counts.contextMs,$counts.snapshotMs,$elapsed,($elapsed/130)
}
Test-Case 'runtime-retention-batch-process-and-unknown' {
    foreach($kind in @('live-process','protection-authority-unknown')) {
        $r=New-Fixture; $p=Put $r
        $v=Invoke-RuntimeRetention -Root $r -Now $script:now -Apply -Dependencies @{
            Context={$script:ctx};Authority={$script:authority};Harvest={@{ok=$true;ledger=@{}}}
            ProtectionSnapshot={param($root)
                if($kind -eq 'live-process'){@{complete=$true;tracked=@();commands=@('synthetic.exe old.log')}}
                else{@{complete=$false;tracked=@();commands=@()}}
            }
        }
        Assert ((Row $v).reason -eq $kind -and (Test-Path -LiteralPath $p)) "batch protection $kind lost"
    }
}
Test-Case 'runtime-retention-recent-never-hashed' {
    $r=New-Fixture; $p=Put $r; $q=Put $r 'package/recent.log'
    [IO.File]::SetLastWriteTimeUtc($p,$script:now);[IO.File]::SetLastWriteTimeUtc($q,$script:now)
    $hashes=@{count=0}
    function Get-FileHash { param($LiteralPath,$Algorithm,$ErrorAction) $hashes.count++; Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm }
    $v=Run $r -Apply
    Assert ($hashes.count -eq 0) 'recent item hashed before age rejection'
    Assert ((Row $v).reason -eq 'recent' -and (Row $v 'package').reason -eq 'recent') 'recent metadata classification lost'
    Assert ((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath $q)) 'recent fixture deleted'
}
foreach($fault in @('wrong-content','wrong-path','dropped-entry','corrupt-entry')) {
    Test-Case "runtime-retention-verify-mismatch-deletes-nothing-$fault" {
        $r=New-Fixture; $p=Put $r
        $script:writer={ param($p,$f)
            if($fault -eq 'corrupt-entry'){ [IO.File]::WriteAllText($p,'not a zip'); return }
            $s=[IO.File]::Open($p,'CreateNew','Write','None'); $z=[IO.Compression.ZipArchive]::new($s,'Create')
            try { if($fault -ne 'dropped-entry') {
                $name=if($fault -eq 'wrong-path'){'wrong.log'}else{$f[0].path}
                $e=$z.CreateEntry($name); $w=[IO.StreamWriter]::new($e.Open())
                try{$w.Write($(if($fault -eq 'wrong-content'){'NEW-DATA'}else{'archived'}))}finally{$w.Dispose()}
            }}finally{$z.Dispose();$s.Dispose()}
        }
        $v=Run $r -Apply; Assert (-not $v.published) 'bad zip published'; Assert (Test-Path $p) 'bad zip authorized deletion'
    }
}
foreach($reason in @('tracked','protected-name','live-process','recent','referenced','open-number-receipt','open-number-authority-unknown','read-only','reparse-descendant','enumeration-failed','nested-transcript-unsupported','transcript-not-covered')) {
    Test-Case "runtime-retention-retained-$reason" {
        $r=New-Fixture; $name='old.log'
        switch($reason){
            'protected-name'{$name='cost-ledger.jsonl'}
            'open-number-receipt'{$name='987654.report.md'}
            'open-number-authority-unknown'{$name='987656.report.json';$script:authority.openIssues[0].complete=$false}
            'nested-transcript-unsupported'{$name='logs/old.jsonl'}
            'transcript-not-covered'{$name='old.jsonl'}
            'reparse-descendant'{$name='package/old.log'}
            'enumeration-failed'{$name='package/old.log'}
        }
        $p=Put $r $name
        switch($reason){
            'tracked'{$script:ctx.tracked=@('.orchestrator/old.log')}
            'live-process'{$script:ctx.commands=@("synthetic.exe `"$p`"")}
            'recent'{[IO.File]::SetLastWriteTimeUtc($p,$script:now)}
            'referenced'{$script:ctx.references='Read old.log here'}
            'read-only'{[IO.File]::SetAttributes($p,'ReadOnly')}
            'reparse-descendant'{ $outside=Join-Path $r 'outside'; [IO.Directory]::CreateDirectory($outside)|Out-Null; New-Item -ItemType Junction -Path (Join-Path $r '.orchestrator/package/link') -Target $outside | Out-Null }
            'enumeration-failed'{
                $directory=Split-Path $p -Parent; $savedAcl=Get-Acl -LiteralPath $directory
                $acl=Get-Acl -LiteralPath $directory
                $deny=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.WindowsIdentity]::GetCurrent().User,'ListDirectory','Deny')
                $acl.AddAccessRule($deny);Set-Acl -LiteralPath $directory -AclObject $acl
            }
        }
        try {
            $v=Run $r -Apply; $item=if($reason -in @('reparse-descendant','enumeration-failed')){'package'}else{$name}
            Assert ((Row $v $item).reason -eq $reason) "expected $reason got $((Row $v $item).reason)"
            Assert (Test-Path $p) "$reason file lost"
        } finally { if($reason -eq 'enumeration-failed'){Set-Acl -LiteralPath $directory -AclObject $savedAcl} }
    }
}
foreach($stage in @('after-gather','after-harvest','after-verify')) {
    foreach($change in @('append','new-child')) {
        Test-Case "runtime-retention-changed-during-apply-$stage-$change" {
            $r=New-Fixture; $p=Put $r 'package/old.log'
            $script:phase={ param($s,$root) if($s -eq $stage){ if($change -eq 'append'){[IO.File]::AppendAllText($p,'NEW')}else{$null=Put $root 'package/new.log' 'NEW'} } }.GetNewClosure()
            $v=Run $r -Apply
            Assert ((Row $v 'package').reason -eq 'changed-during-apply') 'changed item not retained'
            Assert (Test-Path $p) 'original of changed item lost'
            if($change -eq 'new-child'){Assert (Test-Path (Join-Path $r '.orchestrator/package/new.log')) 'new child lost'}
        }
    }
}
Test-Case 'runtime-retention-changed-during-apply-restamped' {
    $r=New-Fixture; $p=Put $r
    $script:phase={param($s,$root) if($s -eq 'before-delete'){ $null=Put $root 'old.log' 'NEW-DATA' }}
    $v=Run $r -Apply
    Assert ((Row $v).reason -eq 'changed-during-apply') 'equal metadata accepted'
    Assert ([IO.File]::ReadAllText($p) -ceq 'NEW-DATA') 'replacement deleted'
}
Test-Case 'runtime-retention-in-use' {
    $r=New-Fixture; $p=Put $r
    $holder=@{}
    $script:phase={param($s,$root) if($s -eq 'before-delete'){$holder.held=[IO.File]::Open($p,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))}}.GetNewClosure()
    try { $v=Run $r -Apply; Assert ((Row $v).reason -eq 'in-use') 'sharing refusal absent'; Assert (Test-Path $p) 'held file lost' }
    finally {if($holder.held){$holder.held.Dispose()}}
}
Test-Case 'runtime-retention-reparse-swap' {
    $r=New-Fixture; $p=Put $r 'package/old.log'; $outside=Join-Path $r 'outside'
    [IO.Directory]::CreateDirectory($outside)|Out-Null; [IO.File]::WriteAllText((Join-Path $outside 'old.log'),'archived')
    $before=Tree $outside
    $script:phase={param($s,$root) if($s -eq 'before-delete'){
        [IO.Directory]::Move((Join-Path $root '.orchestrator/package'),(Join-Path $root 'saved-package'))
        New-Item -ItemType Junction -Path (Join-Path $root '.orchestrator/package') -Target $outside | Out-Null
    }}.GetNewClosure()
    $v=Run $r -Apply; Assert ((Row $v 'package').reason -eq 'changed-during-apply') 'swap accepted'; Assert ((Tree $outside) -ceq $before) 'outside sentinel changed'
}
Test-Case 'runtime-retention-sealed-package' {
    $r=New-Fixture; $null=Put $r 'sealed/checksums.txt'; $p=Put $r 'sealed/deep/read-only.log'
    [IO.File]::SetAttributes($p,'ReadOnly'); $before=Tree (Join-Path $r '.orchestrator/sealed')
    $v=Run $r -Apply; Assert ((Row $v 'sealed').reason -eq 'read-only') 'sealed not retained'; Assert ((Tree (Join-Path $r '.orchestrator/sealed')) -ceq $before) 'sealed bytes changed'
}
Test-Case 'runtime-retention-native-final-path' {
    Initialize-RetentionNative
    $r=New-Fixture;$null=Put $r 'original/old.log';$p=Put $r 'outside/old.log'
    $expected=Get-RetentionSnapshot (Join-Path $r '.orchestrator') 'outside/old.log'
    $f=$expected.files[0];$before=Tree (Join-Path $r '.orchestrator/outside')
    $positive=[RuntimeRetention.Handle]::Verified($p,$f.length,([datetime]::Parse($f.lastWriteUtc).ToUniversalTime().Ticks),$f.sha256,$false);$positive.Dispose()
    $link=Join-Path $r '.orchestrator/alias';New-Item -ItemType Junction -Path $link -Target (Join-Path $r '.orchestrator/outside')|Out-Null
    $refused=$false;$h=$null
    try{$h=[RuntimeRetention.Handle]::Verified((Join-Path $link 'old.log'),$f.length,([datetime]::Parse($f.lastWriteUtc).ToUniversalTime().Ticks),$f.sha256,$false)}catch{$refused=$true}finally{if($h){$h.Dispose()}}
    Assert $refused 'native handle accepted a redirected parent'
    Assert ((Tree (Join-Path $r '.orchestrator/outside')) -ceq $before) 'native final-path sentinel changed'
}
Test-Case 'runtime-retention-harvest-coverage' {
    foreach($mode in @('covered','appended','skipped','failed','newest-row')) {
        $r=New-Fixture; $p=Put $r 'old.jsonl'; $ordinary=Put $r 'ordinary.log'; $script:ledger['old.jsonl']=@{bytes=8;usd=$null}
        if($mode -eq 'skipped'){$script:ledger=@{}}
        if($mode -eq 'failed'){$script:harvestOK=$false}
        if($mode -eq 'newest-row'){$script:ledger['old.jsonl']=@{bytes=7;usd=$null}}
        if($mode -eq 'appended'){$script:phase={param($s,$root) if($s -eq 'after-harvest'){[IO.File]::AppendAllText($p,'NEW')}}.GetNewClosure()}
        $v=Run $r -Apply
        Assert ($script:harvestCalls -eq 1) 'harvest missing'
        Assert ((Test-Path $p) -eq ($mode -ne 'covered')) "coverage $mode"
        Assert (-not (Test-Path $ordinary)) "unrelated raw file stopped by harvest $mode"
        if($mode -eq 'covered'){Assert ($null -eq $script:ledger['old.jsonl'].usd) 'null cost coerced'}
    }
}
Test-Case 'runtime-retention-authority-shape' {
    foreach($fault in @('none','duplicate','missing-page','count','missing-number','missing-repo','failed')){
        $a=New-Authority
        switch($fault){
            'duplicate'{$a.openIssues[0].numbers=@(987654,987654);$a.openIssues[0].nodes=2;$a.openIssues[0].totalCount=2}
            'missing-page'{$a.openIssues[0].numbers=@();$a.openIssues[0].complete=$false}
            'count'{$a.openPrs[0].totalCount=2}
            'missing-number'{$a.openPrs[0].nodesData[0].Remove('number')}
            'missing-repo'{$a.openIssues=@($a.openIssues[0])}
            'failed'{$a=$null}
        }
        $v=ConvertTo-RetentionAuthority ($a | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        Assert ($v.known -eq ($fault -eq 'none')) "authority $fault"
        if($fault -eq 'none'){Assert ($v.numbers.Contains(987654) -and $v.numbers.Contains(987655) -and $v.numbers.Contains(987664) -and $v.numbers.Contains(987665)) 'union missing'}
    }
}
Test-Case 'runtime-retention-authority-paging' {
    foreach($fault in @('none','missing-page','moving-total','duplicate','null-number','errors','failed','missing-total','bad-cursor')){
        $calls=@{count=0}
        $read={param($query,$owner,$name)
            $calls.count++
            Assert ($query.Contains('first:100,after:$endCursor') -and $query.Contains('states:OPEN')) 'query contract'
            if($fault -eq 'failed'){throw 'synthetic network failure'}
            $kind=if($query.Contains('pullRequests(')){'pullRequests'}else{'issues'}
            $first=@(1..100|ForEach-Object{@{number=$_}});$last=@(@{number=987654})
            $p1=@{totalCount=101;nodes=$first;pageInfo=@{hasNextPage=$true;endCursor='synthetic-cursor'}}
            $p2=@{totalCount=101;nodes=$last;pageInfo=@{hasNextPage=$false;endCursor='synthetic-end'}}
            switch($fault){
                'moving-total'{$p2.totalCount=102}
                'duplicate'{$p2.nodes=@(@{number=1})}
                'null-number'{$p2.nodes=@(@{number=$null})}
                'missing-total'{$p2.Remove('totalCount')}
                'bad-cursor'{$p1.pageInfo.endCursor=$null}
            }
            $out=@(@{data=@{repository=@{$kind=$p1}}},@{data=@{repository=@{$kind=$p2}}})
            if($fault -eq 'errors'){$out[1].errors=@(@{message='synthetic error'})}
            if($fault -eq 'missing-page'){$out=@($out[0])}
            return ($out | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        }.GetNewClosure()
        $a=ConvertTo-RetentionAuthority (Get-RetentionAuthority -ReadPages $read)
        Assert ($a.known -eq ($fault -eq 'none')) "paging $fault"
        if($fault -eq 'none'){Assert ($a.numbers.Contains(987654) -and $calls.count -eq 4) 'page beyond cap or repository read missing'}
    }
}
Test-Case 'runtime-retention-ledger-newest-row' {
    $r=New-Fixture; $path=Join-Path $r '.orchestrator/cost-ledger.jsonl'
    [IO.File]::WriteAllLines($path,@('{"transcript":"synthetic.jsonl","bytes":8,"usd":1}','{"transcript":"synthetic.jsonl","bytes":7,"usd":null}'))
    $l=Get-RetentionLedger $r; Assert ($l['synthetic.jsonl'].bytes -eq 7 -and $null -eq $l['synthetic.jsonl'].usd) 'not last row'
    [IO.File]::AppendAllText($path,"`n{broken")
    Assert ((Get-RetentionLedger $r).Count -eq 0) 'malformed ledger granted coverage'
}
Test-Case 'runtime-retention-protection-recheck' {
    foreach($kind in @('tracked','live-process','referenced','read-only','recent')){
        $r=New-Fixture; $p=Put $r
        $script:phase={param($s,$root)if($s -eq 'after-verify'){
            switch($kind){
                'tracked'{$script:ctx.tracked=@('.orchestrator/old.log')}
                'live-process'{$script:ctx.commands=@('synthetic.exe old.log')}
                'referenced'{$script:ctx.references='synthetic old.log reader'}
                'read-only'{[IO.File]::SetAttributes((Join-Path $root '.orchestrator/old.log'),'ReadOnly')}
                'recent'{[IO.File]::SetLastWriteTimeUtc((Join-Path $root '.orchestrator/old.log'),$script:now)}
            }
        }}
        $v=Run $r -Apply; Assert ((Row $v).action -eq 'retain' -and (Test-Path $p)) "protection $kind not rechecked"
    }
}
Test-Case 'runtime-retention-item-all-handles-before-delete' {
    $r=New-Fixture; $p=Put $r 'package/a.log'; $q=Put $r 'package/z.log'
    $script:phase={param($s,$root)if($s -eq 'before-delete'){$null=Put $root 'package/z.log' 'NEW-DATA'}}
    $v=Run $r -Apply; Assert ((Row $v 'package').action -eq 'retain') 'changed last file accepted'
    Assert ((Test-Path $p) -and (Test-Path $q)) 'partial item deleted before full handle validation'
}
Test-Case 'runtime-retention-protected-trees-not-walked' {
    $r=New-Fixture; $null=Put $r 'platform-runs/old.log';$null=Put $r 'salvage/old.log';$null=Put $r 'locks.d/old.log'
    $before=Tree (Join-Path $r '.orchestrator');$v=Run $r -Apply
    Assert ((Tree (Join-Path $r '.orchestrator')) -ceq $before) 'protected tree mutated'
    Assert (@($v.items|Where-Object reason -ne 'protected-name').Count -eq 0) 'protected tree not classified'
    Assert (@($v.items|ForEach-Object {$_.snapshot.files}).Count -eq 0) 'protected tree walked'
}
Test-Case 'runtime-retention-multiple-files-and-empty-directories' {
    $r=New-Fixture;$null=Put $r 'package/deep/a.log';$null=Put $r 'package/b.log'
    $v=Run $r -Apply
    Assert ((Row $v 'package').action -eq 'deleted') 'package deletion failed'
    Assert (-not (Test-Path (Join-Path $r '.orchestrator/package'))) 'empty directories not removed'
    $m=Get-Content $v.manifest -Raw|ConvertFrom-Json;Assert ($m.files.Count -eq 2) 'package manifest incomplete'
}
Test-Case 'runtime-retention-cadence' {
    $r=New-Fixture; $null=Put $r; $v=Run $r -Apply
    $script:now=$script:now.AddHours(23); Assert (-not (Run $r).due) 'early due'
    $before=Tree $r; $calls=$script:harvestCalls
    Assert (-not (Run $r -Apply).due -and $script:harvestCalls -eq $calls -and (Tree $r) -ceq $before) 'early apply changed state'
    $script:now=$script:now.AddHours(2); Assert ((Run $r).due) 'late not due'
    $r=New-Fixture; $null=Put $r
    $script:phase={param($s,$root)if($s -eq 'before-publish'){throw 'synthetic crash'}}
    $v=Run $r -Apply; Assert (-not $v.published) 'crash published'; Assert ((Run $r).due) 'crash not due'
}
Test-Case 'runtime-retention-no-clobber' {
    $r=New-Fixture; $p=Put $r; $dir=Join-Path $r '.archive/runtime'; [IO.Directory]::CreateDirectory($dir)|Out-Null
    $z=Join-Path $dir ($script:now.ToString('yyyyMMddTHHmmssZ')+'.zip'); [IO.File]::WriteAllText($z,'sentinel')
    $v=Run $r -Apply; Assert ([IO.File]::ReadAllText($z) -ceq 'sentinel') 'archive clobbered'; Assert (Test-Path $p) 'collision deleted source'
}
Test-Case 'runtime-retention-top-level-link' {
    $r=New-Fixture; $outside=Join-Path $r 'outside'; [IO.Directory]::CreateDirectory($outside)|Out-Null
    [IO.File]::WriteAllText((Join-Path $outside 'sentinel'),'safe'); $before=Tree $outside
    $p=Join-Path $r '.orchestrator/old-link'; New-Item -ItemType Junction -Path $p -Target $outside|Out-Null
    # DirectoryInfo timestamp setters follow links on some runtimes; use an old controlled clock instead.
    $script:now=[datetime]::UtcNow.AddDays(9)
    $v=Run $r -Apply; Assert ((Row $v 'old-link').action -eq 'deleted') 'link retained'
    Assert (-not (Test-Path $p)) 'link survived'; Assert ((Tree $outside) -ceq $before) 'link target changed'
    $m=Get-Content $v.manifest -Raw|ConvertFrom-Json; Assert ($m.files[0].path -eq 'old-link.link.txt') 'link receipt missing'
}
Test-Case 'runtime-retention-integration-wiring' {
    $controller=Split-Path $PSScriptRoot -Parent
    $skill=[IO.File]::ReadAllText((Join-Path $controller '.orchestrator/controller-skills/milestone-orchestrator/SKILL.md'))
    $cycle=[regex]::Match($skill,'(?s)## 3\. Cycle.*?(?=## 4\.)').Value
    Assert ($cycle.Contains('runtime-retention.ps1 -Apply') -and $cycle.Contains('24 hours')) 'cycle wiring missing'
    Assert ([IO.File]::ReadAllText((Join-Path $controller 'README.md')).Contains('.orchestrator/runtime-retention.ps1')) 'README wiring missing'
}
Assert ($script:passed -gt 0) 'no cases selected'
"PASS runtime-retention cases=$script:passed fixtures=$script:root (retained; no shared TEMP cleanup)"
if($RunMutants){
    $source=[IO.File]::ReadAllText($SourcePath)
    $mutants=@(
        @{name='same-count-only-zip';old='if($hash -cne $f.sha256){return $false}';new='if($false){return $false}';case='runtime-retention-verify-mismatch-deletes-nothing-wrong-content'},
        @{name='metadata-only-delete';old='if(size!=length || !String.Equals(actual,hash,StringComparison.OrdinalIgnoreCase))';new='if(size!=length)';case='runtime-retention-changed-during-apply-restamped'},
        @{name='missing-transcript-coverage';old="return 'transcript-not-covered'";new="return 'eligible'";case='runtime-retention-retained-transcript-not-covered'},
        @{name='unknown-is-closed';old='if($matches.Count -and -not $Authority.known)';new='if($false)';case='runtime-retention-retained-open-number-authority-unknown'},
        @{name='read-only-classification-omitted';old='if($entry.Attributes -band [IO.FileAttributes]::ReadOnly)';new='if($false)';case='runtime-retention-retained-read-only'},
        @{name='disposition-omitted';old='foreach($h in $handles){$h.MarkDelete()}';new='foreach($h in $handles){$null=$h}';case='runtime-retention-apply-verified'},
        @{name='cadence-ignored';old='if(Test-RetentionZip $zip $m.files){return $false}';new='if($false){return $false}';case='runtime-retention-cadence'},
        @{name='total-count-ignored';old='$c.totalCount -ne $values.Count';new='$false';case='runtime-retention-authority-shape'},
        @{name='exclusive-share-omitted';old='directory && !link ? 3u : 0u';new='7u';case='runtime-retention-in-use'},
        @{name='final-path-omitted';old="!String.Equals(Canonical(final.ToString()).TrimEnd('\\'),Path.GetFullPath(path).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)";new='false';case='runtime-retention-native-final-path'},
        @{name='protection-unknown-ignored';old="if(-not `$Context.complete){return 'protection-authority-unknown'}";new='';case='runtime-retention-retained-protection-authority-unknown'},
        @{name='context-failure-reports-complete';old="return @{complete=`$false;tracked=@();references='';commands=@()}";new="return @{complete=`$true;tracked=@();references='';commands=@()}";case='runtime-retention-context-production'},
        @{name='context-tracked-empty';old='complete=$true;tracked=$tracked;references=$refs.ToString()';new='complete=$true;tracked=@();references=$refs.ToString()';case='runtime-retention-context-production'},
        @{name='harvest-backfill-dropped';old=' -Backfill -TranscriptDir ';new=' -TranscriptDir ';case='runtime-retention-harvest-production'},
        @{name='harvest-exitcode-ignored';old='ok=($LASTEXITCODE -eq 0);ledger=';new='ok=$true;ledger=';case='runtime-retention-harvest-production'},
        @{name='directory-delete-recursive';old='using(var h=new Handle(p,true,false,true)) h.MarkDelete(); // Kernel refuses a nonempty directory.';new='Directory.Delete(p,true);';case='runtime-retention-directory-nonempty'},
        @{name='batch-stale-snapshot';old='$snapshot=& $Dependencies.ProtectionSnapshot $Root';new='$snapshot=$context';case='runtime-retention-context-once-and-batch-recheck'},
        @{name='recent-hashed';old='$item.snapshot=Get-RetentionSnapshot $runtime $item.path -MetadataOnly';new='$item.snapshot=Get-RetentionSnapshot $runtime $item.path';case='runtime-retention-recent-never-hashed'}
    )
    $logs=Join-Path $PSScriptRoot 'artifacts';[IO.Directory]::CreateDirectory($logs)|Out-Null
    foreach($m in $mutants){
        Assert ($source.Contains($m.old)) "mutant $($m.name) not applied"
        $copy=Join-Path $script:root ($m.name+'.ps1');[IO.File]::WriteAllText($copy,$source.Replace($m.old,$m.new))
        $log=Join-Path $logs ('runtime-retention-mutant-'+$m.name+'.log')
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $PSCommandPath -SourcePath $copy -Case $m.case *> $log
        Assert ($LASTEXITCODE -ne 0 -and [IO.File]::ReadAllText($log).Contains('ASSERT:')) "mutant survived or invalid: $($m.name)"
        "KILLED $($m.name) case=$($m.case) log=$log"
    }
    $copy=Join-Path $script:root 'native-disposition-failure.ps1'
    Assert ($source.Contains('SetFileInformationByHandle(handle,4,ref disposition,1)')) 'disposition fault not applied'
    [IO.File]::WriteAllText($copy,$source.Replace('SetFileInformationByHandle(handle,4,ref disposition,1)','SetFileInformationByHandle(handle,999,ref disposition,1)'))
    $log=Join-Path $logs 'runtime-retention-disposition-refused.log'
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File $PSCommandPath -SourcePath $copy -DispositionFailureControl *> $log
    Assert ($LASTEXITCODE -eq 0) 'native disposition refusal control failed'
    "PASS runtime-retention-disposition-refused log=$log"
}
