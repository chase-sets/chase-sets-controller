[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'platform-scorecard.ps1'),
    [ValidateSet('all','attribution','cohort','interventions')][string]$Suite = 'all',
    [ValidateSet('none','branch-prefix','participant-dedup','ledger-final','local-date','omit-manifests','api-cap')]
    [string]$Mutant = 'none',
    [string]$EvidenceRoot = ''
)
$ErrorActionPreference = 'Stop'
[Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
. $ScriptPath -FunctionsOnly
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
$fixtureParent=if($EvidenceRoot){$EvidenceRoot}else{[IO.Path]::GetTempPath()}
$root = Join-Path $fixtureParent ("$Suite-$Mutant-fixtures-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

function Assert-Scorecard($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Check([string]$Name, [scriptblock]$Body) {
    $script:checks++
    try { & $Body; Write-Output "PASS $Name" }
    catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function Write-Json([string]$Path, $Value) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 40))
}
function Connection($Nodes) {
    return @{totalCount=@($Nodes).Count;nodes=@($Nodes);pageInfo=@{hasNextPage=$false;endCursor=$null}}
}
function Pr([int]$Number, [int[]]$Issues, [string]$MergedAt = '2026-09-30T12:00:00Z', [string]$Branch = 'codex/native') {
    return @{number=$Number;repository=@{nameWithOwner='chase-sets/chase-sets'};mergedAt=$MergedAt;
        mergeCommit=@{oid=('a' * 32 + $Number.ToString('x8'))};headRefOid=('b' * 40);headRefName=$Branch;
        closingIssuesReferences=(Connection @($Issues | ForEach-Object { @{number=$_;repository=@{nameWithOwner='chase-sets/chase-sets'}} }))}
}
function Fixture([string]$Name) {
    $f = Join-Path $root $Name
    foreach ($p in @('.orchestrator/logs','.orchestrator/platform-runs','.archive/runtime','m1/runtime','m2/runtime')) {
        New-Item -ItemType Directory -Path (Join-Path $f $p) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $f '.orchestrator/dispatch-log.jsonl'), '')
    [IO.File]::WriteAllText((Join-Path $f '.orchestrator/cost-ledger.jsonl'), '')
    $global:ScorecardTestApi = @{prs=@();plans=@();histories=@{};closures=@{};fault='';calls=0;queries=[Collections.Generic.List[string]]::new()}
    return $f
}
function Add-Witness($F, $Pr, [string]$Stage = 'source', [string]$Run = 'run', [string]$RootName = 'm2') {
    $dir = Join-Path $F "$RootName/runtime/$Run/cs-$($Pr.number)-attempt-1/$Stage"
    Write-Json (Join-Path $dir 'merge.json') @{number=$Pr.number;head=$Pr.headRefOid;mergeCommit=$Pr.mergeCommit.oid}
    Write-Json (Join-Path $dir 'publication.json') @{number=$Pr.number;head=$Pr.headRefOid;repository='chase-sets/chase-sets'}
    return $dir
}
function Add-Participant($F, [int]$Issue, [string]$Id, [string]$Item, [int]$Index = 1, $InputValue = 10) {
    $key=if($Item -cmatch "^cs-$Issue-replan-\d+:"){$Item.Split(':')[0]}else{"cs-$Issue"}
    $dir = Join-Path $F "m2/runtime/run/$key-attempt-1"
    Write-Json (Join-Path $dir "participant-$Index-terminal.json") @{id=$Id;item=$Item;role='author';outcome='passed';usage=@{
        inputTokens=@{status=$(if($null -eq $InputValue){'unavailable'}else{'known'});value=$InputValue};outputTokens=@{status='known';value=3}}}
}
function Add-Install($F, [string]$Name, [string]$At, [string]$Text = 'upgrade') {
    $p = Join-Path $F ".orchestrator/logs/$Name"
    [IO.File]::WriteAllText($p, $Text)
    [IO.File]::SetLastWriteTimeUtc($p, [datetime]::Parse($At).ToUniversalTime())
    [IO.File]::SetCreationTimeUtc($p, [datetime]'2026-10-08T00:00:00Z')
    return @{source="logs/$Name";path="logs/$Name";length=(Get-Item -LiteralPath $p).Length;
        lastWriteUtc=$At;sha256=(Get-FileHash -LiteralPath $p).Hash;link=$false}
}
function Add-Manifest($F, $Entries, [string]$Name = 'one') {
    Write-Json (Join-Path $F ".archive/runtime/$Name.manifest.json") @{schema='runtime-retention-manifest/v1';files=@($Entries)}
}
function Run-Scorecard($F, [string]$From = '2026-09-29', [string]$To = '2026-10-06') {
    $output = Join-Path $F 'out.json'
    Invoke-PlatformScorecard -Since $From -Until $To -Out $output -ContainerRoot $F -RuntimeRoots @((Join-Path $F 'm2'),(Join-Path $F 'm1')) | Out-Null
    $script:markdown = [IO.File]::ReadAllText((Join-Path $F 'out.md'))
    return (Get-Content -LiteralPath $output -Raw | ConvertFrom-Json -DateKind String)
}

# Mock only the transport. Pagination, validation, native/ledger/filesystem
# collection, reduction and both renderers remain the production entrypoint.
function gh {
    $global:ScorecardTestApi.calls++
    $query = ''; $cursor = ''
    foreach ($arg in $args) {
        if ([string]$arg -like 'query=*') { $query = ([string]$arg).Substring(6) }
        if ([string]$arg -like 'c=*') { $cursor = ([string]$arg).Substring(2) }
    }
    if ($global:ScorecardTestApi.fault -eq 'transport') { throw 'fixture API unavailable' }
    if ($query -match 'search\(') {
        $q = [string]($args | Where-Object { [string]$_ -like 'q=*' } | Select-Object -First 1)
        $global:ScorecardTestApi.queries.Add($q)
        if($q -notmatch 'merged:2026-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\.\.2026-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z' -or $q -match 'merged:[<>]') {throw 'expected one inclusive GitHub range, exact filtering in reducer'}
        $nodes = @(if ($q -match 'todd-skelton') { $global:ScorecardTestApi.plans } else { $global:ScorecardTestApi.prs })
        $count = $nodes.Count
        $page = @{hasNextPage=$false;endCursor=$null}
        if ($global:ScorecardTestApi.fault -eq 'cap') {
            $count=1000
            $nodes=@(1..1000 | ForEach-Object {
                $p=Pr (10000+$_) @()
                if($q -match 'todd-skelton'){$p.repository.nameWithOwner='todd-skelton/orchestration-platform'}
                $p
            })
        }
        if ($global:ScorecardTestApi.fault -eq 'incomplete') { $count++ }
        if ($global:ScorecardTestApi.fault -eq 'search-pages') {
            if (-not $cursor) { $nodes=@($nodes | Select-Object -First 1);$page=@{hasNextPage=$true;endCursor='page2'} }
            else { $nodes=@($nodes | Select-Object -Skip 1) }
        }
        $value = @{data=@{search=@{issueCount=$count;nodes=$nodes;pageInfo=$page}}}
    } elseif ($query -match 'issue\(number:(\d+)\)') {
        $n=[int]$Matches[1]; $nodes=@($global:ScorecardTestApi.histories[$n])
        $c=Connection $nodes
        if ($global:ScorecardTestApi.fault -eq 'history') { $c.totalCount++; }
        if ($global:ScorecardTestApi.fault -eq 'history-pages') {
            if (-not $cursor) { $c.nodes=@($nodes | Select-Object -First 1);$c.pageInfo=@{hasNextPage=$true;endCursor='page2'} }
            else { $c.nodes=@($nodes | Select-Object -Skip 1) }
        }
        $value=@{data=@{repository=@{issue=@{closedByPullRequestsReferences=$c}}}}
    } elseif ($query -match 'pullRequest\(number:(\d+)\)') {
        $n=[int]$Matches[1];$pr=@($global:ScorecardTestApi.prs | Where-Object number -eq $n)[0]
        $c=if($global:ScorecardTestApi.closures.ContainsKey($n)){$global:ScorecardTestApi.closures[$n].Clone()}else{$pr.closingIssuesReferences.Clone()}
        if (-not $cursor) { $c.nodes=@($c.nodes | Select-Object -First 1);$c.pageInfo=@{hasNextPage=$true;endCursor='page2'} }
        else { $c.nodes=@($c.nodes | Select-Object -Skip 1);$c.pageInfo=@{hasNextPage=$false;endCursor=$null} }
        $value=@{data=@{repository=@{pullRequest=@{closingIssuesReferences=$c}}}}
    } else { throw "unexpected fixture query: $query" }
    $global:LASTEXITCODE = 0
    return (ConvertTo-Json -InputObject $value -Depth 40 -Compress)
}

$mutation=$null
try {
    if ($Mutant -ne 'none') {
        $name,$before,$after = switch ($Mutant) {
            'branch-prefix' { 'Get-ScorecardOwner'; 'if ($Witnesses.ContainsKey([string]$Pr.number))'; 'if ($Pr.headRefName -like ''codex/*'') { return ''branch-prefix-proxy'' }; if ($Witnesses.ContainsKey([string]$Pr.number))' }
            'participant-dedup' { 'Get-ScorecardParticipants'; 'if ($seen.ContainsKey($id))'; 'if ($false)' }
            'ledger-final' { 'Read-ScorecardLedgers'; '$latest[$row.transcript] = $row'; 'if (-not $latest.ContainsKey($row.transcript)) { $latest[$row.transcript] = $row }' }
            'local-date' { 'ConvertTo-ScorecardUtc'; '$Value += ''T00:00:00Z'''; '$Value += ''T05:00:00Z''' }
            'omit-manifests' { 'Get-ScorecardInstalls'; 'foreach ($manifest in $manifests)'; 'foreach ($manifest in @())' }
            'api-cap' { 'Get-ScorecardMergedPrs'; 'if ($expected -ge 1000)'; 'if ($false)' }
        }
        $source=(Get-Item "function:$name").ScriptBlock.ToString()
        Assert-Scorecard ($source.Contains($before) -and $source.IndexOf($before) -eq $source.LastIndexOf($before)) "unique mutant anchor $Mutant"
        $changed=$source.Replace($before,$after)
        Set-Item "function:$name" ([scriptblock]::Create($changed))
        $mutation=@{function=$name;before=$before;after=$after;occurrences=1;
            originalSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($source)));
            mutantSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($changed)))}
        Write-Output "MUTANT $Mutant applied one source change"
    }
    if ($Suite -in @('all','attribution')) {
        Check 'platform-scorecard-attribution each canonical stage independently, depth boundary' {
            $index=0
            foreach($stage in @('source','repair','source/refresh-one','source/gate-correction','repair/gate-stop-continuation/refresh-one','source/a/b/c')){
                $f=Fixture "stage-$index";$index++;$p=Pr 8066 @(10);$global:ScorecardTestApi.prs=@($p);$global:ScorecardTestApi.histories[10]=@($p)
                Add-Witness $f $p $stage | Out-Null
                $r=Run-Scorecard $f
                Assert-Scorecard ($r.systems.platform.deliveredIssues -eq 1) "canonical stage $stage"
            }
            $f=Fixture 'too-deep';$p=Pr 8066 @(10);$global:ScorecardTestApi.prs=@($p);$global:ScorecardTestApi.histories[10]=@($p)
            Add-Witness $f $p 'source/a/b/c/d' | Out-Null
            $r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.incumbent.deliveredIssues -eq 1) 'source depth five is outside declared envelope'
        }
        Check 'platform-scorecard-attribution genuine repair/refresh witnesses, scratch and wrong joins' {
            $f=Fixture 'attribution';$p=Pr 8066 @(10);$scratch=Pr 8055 @(11);$wrong=Pr 9000 @(12);$merge=Pr 9001 @(13)
            $global:ScorecardTestApi.prs=@($p,$scratch,$wrong,$merge);foreach($i in 10..13){$global:ScorecardTestApi.histories[$i]=@($global:ScorecardTestApi.prs[$i-10])}
            Add-Witness $f $p 'repair/gate-stop-continuation/refresh-one' | Out-Null
            Add-Witness $f $p 'source/refresh-one' 'duplicate' 'm1' | Out-Null
            Add-Witness $f $scratch 'source/author-temp' | Out-Null
            Add-Witness $f $scratch 'source/runtime/nested' | Out-Null
            $d=Add-Witness $f $wrong;Write-Json (Join-Path $d 'publication.json') @{number=9000;head=$wrong.headRefOid;repository='other/repo'}
            $d=Add-Witness $f $merge;Write-Json (Join-Path $d 'merge.json') @{number=9001;head=$merge.headRefOid;mergeCommit=('c'*40)}
            $r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.platform.deliveredIssues -eq 1 -and $r.systems.platform.issues[0].pr -eq 8066) 'only matching native witness owns PR8066'
            Assert-Scorecard ($r.systems.incumbent.deliveredIssues -eq 3) 'codex prefix, scratch, wrong repository/merge do not establish ownership'
            Assert-Scorecard ($r.systems.platform.issues[0].witness -match 'refresh-one') 'native witness retained'
        }
        Check 'platform-scorecard-attribution incomplete roots and payload never certify incumbent' {
            $f=Fixture 'missing-root';$p=Pr 8066 @(10);$global:ScorecardTestApi.prs=@($p);$global:ScorecardTestApi.histories[10]=@($p)
            Remove-Item -LiteralPath (Join-Path $f 'm1/runtime')
            $r=Run-Scorecard $f
            Assert-Scorecard ($null -eq $r.systems.platform.deliveredIssues -and $null -eq $r.systems.incumbent.deliveredIssues) 'both delivery cells null on missing runtime'
            Assert-Scorecard ($r.gaps -contains 'platform-witnesses-unavailable') 'missing root named'
            New-Item -ItemType Directory -Path (Join-Path $f 'm1/runtime') | Out-Null
            $d=Add-Witness $f $p;Remove-Item -LiteralPath (Join-Path $d 'publication.json')
            $r=Run-Scorecard $f
            Assert-Scorecard ($null -eq $r.systems.incumbent.deliveredIssues) 'missing adjacent publication unknown'
            Write-Json (Join-Path $d 'publication.json') @{number=$p.number;head=$p.headRefOid;repository='chase-sets/chase-sets'}
            $d=Add-Witness $f $p 'repair' 'conflict'
            Write-Json (Join-Path $d 'merge.json') @{number=$p.number;head=$p.headRefOid;mergeCommit=('c'*40)}
            $r=Run-Scorecard $f
            Assert-Scorecard ($null -eq $r.systems.platform.deliveredIssues -and $r.gaps -contains 'platform-witness-conflict:8066') 'conflicting witness identities unknown'
        }
    }
    if ($Suite -in @('all','cohort')) {
        Check 'platform-scorecard-cohort earliest PR, two issues, redelivery and paged history' {
            $f=Fixture 'cohort';$a=Pr 8066 @(10,11);$b=Pr 8067 @(10) '2026-10-01T00:00:00Z'
            $old=Pr 7000 @(10) '2026-09-01T00:00:00Z';$global:ScorecardTestApi.prs=@($b,$a);$global:ScorecardTestApi.histories[10]=@($old,$a,$b);$global:ScorecardTestApi.histories[11]=@($a)
            Add-Witness $f $a | Out-Null;Add-Witness $f $b | Out-Null
            $global:ScorecardTestApi.fault='history-pages';$r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.platform.deliveredIssues -eq 2) 'two issues, not PR count'
            $i=@($r.systems.platform.issues | Where-Object issue -eq 10)[0]
            Assert-Scorecard ($i.pr -eq 8066 -and $i.redelivered -eq $true) 'earliest PR owns issue and prior-window close marks redelivery'
            $global:ScorecardTestApi.fault='';$r=Run-Scorecard $f '2026-10-01' '2026-10-06'
            Assert-Scorecard ($r.systems.platform.deliveredIssues -eq 1 -and $r.systems.platform.issues[0].redelivered) 'later-window delivery counted again'
            $global:ScorecardTestApi.fault='history';$r=Run-Scorecard $f
            Assert-Scorecard ($null -eq $r.systems.platform.issues[0].redelivered -and $r.gaps -contains 'history-incomplete:10') 'incomplete history stays null'
        }
        Check 'platform-scorecard-cohort #7844 plain/replan launches copied once, unknown totals' {
            $f=Fixture 'participants';$p=Pr 8066 @(7844,20);$global:ScorecardTestApi.prs=@($p);$global:ScorecardTestApi.histories[7844]=@($p);$global:ScorecardTestApi.histories[20]=@($p)
            Add-Witness $f $p | Out-Null
            foreach($n in 1..11){$item=if($n -le 7){'cs-7844:1'}else{'cs-7844-replan-123:1'};Add-Participant $f 7844 "id-$n" $item $n}
            Assert-Scorecard (Test-Path -LiteralPath (Join-Path $f 'm2/runtime/run/cs-7844-replan-123-attempt-1')) 'native accepted-replan attempt directory exercised'
            $copy=Join-Path $f 'm1/runtime/copied/cs-7844-attempt-2';New-Item -ItemType Directory -Path $copy -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $f 'm2/runtime/run/cs-7844-attempt-1/participant-1-terminal.json') -Destination $copy
            Add-Participant $f 20 'unknown' 'cs-20:1' 1 $null
            Add-Participant $f 7844 'not-accepted' 'cs-7844-replan-x:1' 12
            $r=Run-Scorecard $f;$i=@($r.systems.platform.issues | Where-Object issue -eq 7844)[0]
            Assert-Scorecard ($i.launches -eq 11 -and $i.inputTokens -eq 110) '#7844 eleven unique launches and known tokens'
            Assert-Scorecard ($null -eq $r.systems.platform.inputTokens -and $r.gaps -contains 'platform-inputTokens-unavailable:20') 'one unknown propagates to system tokens'
            Assert-Scorecard ($null -eq $r.systems.platform.usd -and $r.gaps -contains 'platform-usd-unpriced') 'USD remains unpriced'
            $r=Run-Scorecard $f
            $p1=Join-Path $f 'm2/runtime/run/cs-7844-attempt-1/participant-1-terminal.json'
            $bad=Read-ScorecardJson $p1;$bad.usage.inputTokens.value=999;Write-Json $p1 $bad
            $r=Run-Scorecard $f
            Assert-Scorecard ($null -eq $r.systems.platform.launches -and $r.gaps -contains 'platform-participants-unavailable:7844') 'conflicting copied participant identity nulls cohort'
        }
        Check 'platform-scorecard-cohort final append-order ledger, dispatch cohort, no unknown fallback' {
            $f=Fixture 'ledger';$p=Pr 8100 @(30);$global:ScorecardTestApi.prs=@($p);$global:ScorecardTestApi.histories[30]=@($p)
            $rows=@(@{kind='dispatch';issue=30;transcript='one'},@{kind='dispatch';issue=30;transcript='two'},@{kind='review-complete';issue=30})
            [IO.File]::WriteAllLines((Join-Path $f '.orchestrator/dispatch-log.jsonl'),[string[]]@($rows|ForEach-Object{$_|ConvertTo-Json -Compress}))
            $rows=@(@{issue=30;transcript='one';usd=99},@{issue=30;transcript='one';usd=2},@{issue=31;transcript='other';usd=1000},@{issue=30;transcript='two';usd=3})
            $ledger=Join-Path $f '.orchestrator/cost-ledger.jsonl'
            [IO.File]::WriteAllLines($ledger,[string[]]@($rows|ForEach-Object{$_|ConvertTo-Json -Compress}))
            $r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.incumbent.dispatches -eq 2 -and $r.systems.incumbent.usd -eq 5) 'all-time dispatches and final revision cost only'
            Add-Content -LiteralPath $ledger -Value (@{issue=30;transcript='one';usd=$null}|ConvertTo-Json -Compress)
            $r=Run-Scorecard $f
            Assert-Scorecard ($null -eq $r.systems.incumbent.usd -and $r.gaps -contains 'incumbent-usd-unavailable:30') 'final unknown never falls back to older price'
        }
        Check 'platform-scorecard-cohort complete paging, capped/incomplete search and zero ratios' {
            $f=Fixture 'api';$a=Pr 8100 @(30);$b=Pr 8101 @(31);$global:ScorecardTestApi.prs=@($a,$b);$global:ScorecardTestApi.histories[30]=@($a);$global:ScorecardTestApi.histories[31]=@($b)
            $global:ScorecardTestApi.fault='search-pages';$r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.incumbent.deliveredIssues -eq 2) 'all search pages consumed'
            $global:ScorecardTestApi.fault='';$multi=Pr 8102 @(40,41)
            $global:ScorecardTestApi.closures[8102]=$multi.closingIssuesReferences.Clone()
            $multi.closingIssuesReferences.nodes=@($multi.closingIssuesReferences.nodes | Select-Object -First 1)
            $multi.closingIssuesReferences.pageInfo=@{hasNextPage=$true;endCursor='page2'}
            $global:ScorecardTestApi.prs=@($multi);$global:ScorecardTestApi.histories[40]=@($multi);$global:ScorecardTestApi.histories[41]=@($multi)
            $r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.incumbent.deliveredIssues -eq 2) 'nested closing connection fully paged'
            foreach($fault in @('cap','incomplete','transport')){
                $global:ScorecardTestApi.fault=$fault;$r=Run-Scorecard $f
                Assert-Scorecard ($null -eq $r.systems.incumbent.deliveredIssues -and $null -eq $r.systems.platform.interventions.planningPrs -and $r.gaps -contains 'github-deliveries-incomplete') "$fault incomplete totals"
            }
            $global:ScorecardTestApi.fault='';$global:ScorecardTestApi.prs=@();$r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.platform.deliveredIssues -eq 0 -and $null -eq $r.systems.platform.launchesPerIssue -and $null -eq $r.systems.incumbent.usdPerIssue) 'zero denominators null'
        }
    }
    if ($Suite -in @('all','interventions')) {
        Check 'platform-scorecard-interventions UTC boundaries, extensions, creation-vs-write retention parity' {
            $f=Fixture 'installs';$a=Add-Install $f 'm1-executor-upgrade-a.out' '2026-09-29T00:00:00Z';$b=Add-Install $f 'm1-executor-upgrade-b.log' '2026-10-05T23:59:59Z'
            Add-Install $f 'm1-executor-upgrade-end.out' '2026-10-06T00:00:00Z' | Out-Null
            Add-Install $f 'm1-executor-upgrade-script.sh' '2026-10-01T00:00:00Z' | Out-Null
            $r=Run-Scorecard $f;Assert-Scorecard ($r.systems.platform.interventions.installs -eq 2) 'Since included, Until excluded, .log included, .sh excluded, last-write not creation'
            Add-Manifest $f @($a,$b);$r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.platform.interventions.installs -eq 2) 'live plus retained identical metadata deduplicates'
            Remove-Item -LiteralPath (Join-Path $f '.orchestrator/logs/m1-executor-upgrade-a.out'),(Join-Path $f '.orchestrator/logs/m1-executor-upgrade-b.log')
            $r=Run-Scorecard $f;Assert-Scorecard ($r.systems.platform.interventions.installs -eq 2) 'manifest-only count survives retention'
            Assert-Scorecard ($script:markdown -match 'last-write UTC' -and $script:markdown -match 'not a complete' -and $script:markdown -match 'proxy') 'scope/time basis visible in Markdown'
            Assert-Scorecard ($r.window.since -eq '2026-09-29T00:00:00.0000000Z') 'date-only is UTC independently of host zone'
        }
        Check 'platform-scorecard-interventions fractional UTC window, invalid local instants rejected' {
            $f=Fixture 'fractional';$items=@()
            foreach($at in @('2026-09-29T00:00:00.4999999Z','2026-09-29T00:00:00.5000000Z','2026-09-29T00:00:01.2000000Z','2026-09-29T00:00:01.5000000Z')){
                $p=Pr (100+$items.Count) @() $at 'plan/fraction';$p.repository.nameWithOwner='todd-skelton/orchestration-platform';$items+=,$p
            }
            $global:ScorecardTestApi.plans=$items
            $r=Run-Scorecard $f '2026-09-29T00:00:00.5000000Z' '2026-09-29T00:00:01.5000000Z'
            Assert-Scorecard ($r.systems.platform.interventions.planningPrs -eq 2) 'fractional Since included and Until excluded'
            Assert-Scorecard (@($global:ScorecardTestApi.queries | Where-Object {$_ -match 'merged:2026-09-29T00:00:00Z\.\.2026-09-29T00:00:02Z'}).Count -eq 2) 'GitHub whole-second range is a complete superset'
            foreach($bad in @('2026-09-29T00:00:00','2026-09-29T00:00:00-05:00','bad-date')){
                $rejected=$false;try{ConvertTo-ScorecardUtc $bad -DateOnly | Out-Null}catch{$rejected=$true}
                Assert-Scorecard $rejected "explicit UTC required: $bad"
            }
        }
        Check 'platform-scorecard-interventions conflicts before window filtering and malformed/unavailable evidence' {
            $f=Fixture 'conflict';$a=Add-Install $f 'm1-executor-upgrade-a.out' '2026-09-29T00:00:00Z';$b=$a.Clone();$b.lastWriteUtc='2026-10-07T00:00:00Z';Add-Manifest $f @($b)
            $r=Run-Scorecard $f
            Assert-Scorecard ($null -eq $r.systems.platform.interventions.installs -and $null -eq $r.systems.platform.interventions.total -and $r.gaps -contains 'install-evidence-conflict') 'cross-window identity conflict nulls installs/total'
            Assert-Scorecard ($script:markdown -match 'install-evidence-conflict' -and $script:markdown -match 'null') 'gap and null survive Markdown'
            $manifest=Join-Path $f '.archive/runtime/one.manifest.json'
            foreach($bad in @('{broken', '{"schema":"wrong","files":[]}', '{"schema":"runtime-retention-manifest/v1"}')){
                [IO.File]::WriteAllText($manifest,$bad);$r=Run-Scorecard $f
                Assert-Scorecard ($null -eq $r.systems.platform.interventions.installs -and $null -eq $r.systems.platform.interventions.total -and
                    $r.gaps -contains 'install-evidence-unavailable' -and $script:markdown -match 'install-evidence-unavailable' -and $script:markdown -match 'null') 'malformed manifest null and gap in both renderers'
            }
            foreach($field in @('lastWriteUtc','length','sha256','source')){
                $bad=$a.Clone();$bad[$field]=switch($field){'lastWriteUtc'{'2026-09-29T00:00:00'}'length'{-1}'sha256'{'bad'}'source'{'../logs/m1-executor-upgrade-a.out'}}
                Add-Manifest $f @($bad);$r=Run-Scorecard $f
                Assert-Scorecard ($null -eq $r.systems.platform.interventions.installs) "invalid entry $field null"
            }
            Remove-Item -LiteralPath $manifest
            $handle=[IO.File]::Open((Join-Path $f '.archive/runtime/locked.manifest.json'),'Create','ReadWrite','None')
            try {$r=Run-Scorecard $f;Assert-Scorecard ($null -eq $r.systems.platform.interventions.installs) 'unreadable manifest null'} finally {$handle.Dispose()}
            Remove-Item -LiteralPath (Join-Path $f '.archive/runtime/locked.manifest.json')
            Remove-Item -LiteralPath (Join-Path $f '.archive/runtime')
            $r=Run-Scorecard $f;Assert-Scorecard ($null -eq $r.systems.platform.interventions.installs) 'unavailable manifest directory null'
        }
        Check 'platform-scorecard-interventions real CLI, complete empty, omitted collector and cap negatives' {
            $f=Fixture 'entrypoint';$output=Join-Path $f 'cli.json'
            & $ScriptPath -Since '2026-09-29' -Until '2026-10-06' -Out $output -ContainerRoot $f -RuntimeRoots @((Join-Path $f 'm2'),(Join-Path $f 'm1')) | Out-Null
            $r=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
            Assert-Scorecard ($r.systems.platform.interventions.total -eq 0 -and $r.systems.platform.interventions.basis -eq 'proxy') 'complete empty sources zero through CLI'
            Remove-Item -LiteralPath (Join-Path $f '.orchestrator/logs')
            & $ScriptPath -Since '2026-09-29' -Until '2026-10-06' -Out $output -ContainerRoot $f -RuntimeRoots @((Join-Path $f 'm2'),(Join-Path $f 'm1')) | Out-Null
            $r=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
            Assert-Scorecard ($null -eq $r.systems.platform.interventions.total -and $r.gaps -contains 'install-evidence-unavailable') 'collector omission negative through CLI'
            $global:ScorecardTestApi.fault='cap'
            & $ScriptPath -Since '2026-09-29' -Until '2026-10-06' -Out $output -ContainerRoot $f -RuntimeRoots @((Join-Path $f 'm2'),(Join-Path $f 'm1')) | Out-Null
            $r=Get-Content -LiteralPath $output -Raw|ConvertFrom-Json
            Assert-Scorecard ($null -eq $r.systems.platform.deliveredIssues -and $null -eq $r.systems.platform.interventions.planningPrs) 'cap negative through real CLI'
        }
        Check 'platform-scorecard-interventions starts creation UTC and platform planning merge UTC' {
            $f=Fixture 'other-proxies';$p=Join-Path $f '.orchestrator/platform-runs/run';New-Item -ItemType Directory -Path $p | Out-Null
            foreach($name in @('start-loop.out','start-loop-resume.out','other.out')){
                $file=Join-Path $p $name;[IO.File]::WriteAllText($file,'start');[IO.File]::SetCreationTimeUtc($file,[datetime]'2026-09-29T00:00:00Z')
            }
            $plan=Pr 100 @();$plan.repository.nameWithOwner='todd-skelton/orchestration-platform';$plan.headRefName='planning/native'
            $notPlan=Pr 101 @();$notPlan.repository.nameWithOwner='todd-skelton/orchestration-platform';$notPlan.headRefName='feature/native'
            $end=Pr 102 @() '2026-10-06T00:00:00Z';$end.repository.nameWithOwner='todd-skelton/orchestration-platform';$end.headRefName='replan/end'
            $global:ScorecardTestApi.plans=@($plan,$notPlan,$end);$r=Run-Scorecard $f
            Assert-Scorecard ($r.systems.platform.interventions.startResume -eq 2 -and $r.systems.platform.interventions.planningPrs -eq 1 -and $r.systems.platform.interventions.total -eq 3) 'separate proxies and sum'
        }
    }
} finally {
    if ($EvidenceRoot) {
        New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
        Write-Json (Join-Path $EvidenceRoot "$Suite-$Mutant.json") @{suite=$Suite;mutant=$Mutant;checks=$checks;failures=@($failures);fixtureRoot=$root;mutation=$mutation;priority=[string][Diagnostics.Process]::GetCurrentProcess().PriorityClass}
    } else {
        $resolved=[IO.Path]::GetFullPath($root)
        if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe fixture cleanup' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Write-Output "RESULT suite=$Suite mutant=$Mutant checks=$checks failures=$($failures.Count)"
if ($failures.Count) { exit 1 }
