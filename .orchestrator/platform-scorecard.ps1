<#
platform-scorecard/v1: {schemaVersion,window:{since,until},generatedAt,
systems:{platform:{deliveredIssues,issues[],launches,launchesPerIssue,inputTokens,
outputTokens,usd,interventions:{startResume,installs,planningPrs,total,basis:"proxy"}},
incumbent:{deliveredIssues,issues[],dispatches,dispatchesPerIssue,usd,usdPerIssue}},gaps[]}.
Issue: {repository,issue,pr,mergedAt,mergeCommit,redelivered,launches,inputTokens,
outputTokens,usd,witness}. Unknown metrics are null with named gaps.
UTC half-open [Since,Until); date-only means midnight UTC. Diagnostic proxies:
both loops' start creation UTC, M1 install-log last-write UTC (live AND retained),
and platform planning-PR merge UTC share the Chase Sets delivery denominator.
This is not a complete/scope-normalized intervention census, adoption verdict,
or D-T1 proof. Platform USD is unpriced. No source is mutated; only -Out and its
Markdown sibling are written. Retained v1 metadata is read without ZIP extraction.
#>
[CmdletBinding()]
param(
    [string]$Since,
    [string]$Until,
    [string]$Out,
    [string]$ContainerRoot = (Split-Path -Parent $PSScriptRoot),
    [string[]]$RuntimeRoots = @('/root/orchestration-m2', '/root/orchestration-m1'),
    [switch]$FunctionsOnly
)
$ErrorActionPreference = 'Stop'

function Add-ScorecardGap([string]$Gap) { $null = $script:ScorecardGaps.Add($Gap) }

function ConvertTo-ScorecardUtc([string]$Value, [switch]$DateOnly) {
    if ($DateOnly -and $Value -cmatch '^\d{4}-\d{2}-\d{2}$') { $Value += 'T00:00:00Z' }
    if ($Value -cnotmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|\+00:00)$') { throw 'expected explicit UTC instant' }
    return [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime()
}
function Format-ScorecardUtc([DateTimeOffset]$Value) { return $Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function Test-ScorecardWindow([string]$Value, $Window) {
    $at = ConvertTo-ScorecardUtc $Value
    return $at -ge $Window.since -and $at -lt $Window.until
}
function Test-ScorecardNumber($Value) {
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [bigint]) -and
        $Value -ge 0 -and -not [double]::IsInfinity([double]$Value) -and -not [double]::IsNaN([double]$Value)
}
function Test-ScorecardInteger($Value) { return (Test-ScorecardNumber $Value) -and [math]::Truncate([double]$Value) -eq $Value }
function Read-ScorecardJson([string]$Path) {
    return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop)
}
function Invoke-ScorecardGraphQL([string]$Query, [hashtable]$Variables) {
    $arguments = @('api','graphql','-f',"query=$Query")
    foreach ($key in $Variables.Keys) {
        if ($null -ne $Variables[$key]) { $arguments += @('-f',"$key=$($Variables[$key])") }
    }
    $raw = & gh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'GitHub query failed' }
    $response = ($raw | Out-String) | ConvertFrom-Json -AsHashtable -DateKind String
    if ($response.errors -or -not $response.data) { throw 'GitHub returned incomplete authority' }
    return $response.data
}
function Assert-ScorecardPage($Connection, [string]$CountField) {
    if ($null -eq $Connection -or -not (Test-ScorecardInteger $Connection[$CountField]) -or
        $Connection.nodes -isnot [array] -or $Connection.pageInfo.hasNextPage -isnot [bool]) { throw 'invalid connection census' }
}
function Get-ScorecardMergedPrs([string]$Repository, $Window) {
    # Search has a hard provider ceiling. Even exactly 1,000 is not a complete
    # census; do not disguise the boundary as an empty/complete final page.
    $query = 'query($q:String!,$c:String){search(query:$q,type:ISSUE,first:100,after:$c){issueCount pageInfo{hasNextPage endCursor} nodes{... on PullRequest{number repository{nameWithOwner} mergedAt mergeCommit{oid} headRefOid headRefName closingIssuesReferences(first:100){totalCount pageInfo{hasNextPage endCursor} nodes{number repository{nameWithOwner}}}}}}}'
    # GitHub combines repeated merged qualifiers differently from an interval.
    # A single inclusive, whole-second range supplies a superset; exact UTC
    # half-open (including fractional-second) membership is decided below.
    $from=$Window.since.ToString("yyyy-MM-ddTHH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture)
    $upper=$Window.until
    if($upper.UtcTicks % [TimeSpan]::TicksPerSecond){$upper=$upper.AddSeconds(1)}
    $to=$upper.ToString("yyyy-MM-ddTHH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture)
    $q = "repo:$Repository is:pr is:merged merged:$from..$to"
    $nodes = [Collections.Generic.List[object]]::new(); $cursor = $null; $expected = $null
    $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    do {
        $data = Invoke-ScorecardGraphQL $query @{q=$q;c=$cursor}
        $page = $data.search; Assert-ScorecardPage $page 'issueCount'
        if ($null -eq $expected) { $expected = $page.issueCount }
        if ($expected -ge 1000) { throw 'GitHub search cap reached' }
        if ($page.issueCount -ne $expected) { throw 'search census changed' }
        foreach ($pr in $page.nodes) {
            if (-not (Test-ScorecardInteger $pr.number) -or $pr.number -lt 1 -or
                $pr.repository.nameWithOwner -cne $Repository -or -not $identities.Add([string]$pr.number) -or
                $pr.mergeCommit.oid -cnotmatch '^[0-9a-f]{40}$' -or $pr.headRefOid -cnotmatch '^[0-9a-f]{40}$' -or
                $null -eq $pr.headRefName) { throw 'invalid PR identity' }
            if (Test-ScorecardWindow $pr.mergedAt $Window) { $nodes.Add($pr) }
        }
        if ($page.pageInfo.hasNextPage) {
            $cursor = [string]$page.pageInfo.endCursor
            if (-not $cursor -or -not $cursors.Add($cursor) -or $cursors.Count -ge 100) { throw 'search cursor/cap invalid' }
        }
    } while ($page.pageInfo.hasNextPage)
    if ($identities.Count -ne $expected) { throw 'incomplete PR search' }
    return @($nodes)
}
function Get-ScorecardConnection([string]$Kind, [int]$Number) {
    if ($Kind -ceq 'closing') {
        $owner = "pullRequest(number:$Number)"; $name='closingIssuesReferences'; $fields='number repository{nameWithOwner}'
    } else {
        $owner = "issue(number:$Number)"; $name='closedByPullRequestsReferences'; $fields='number repository{nameWithOwner} mergedAt mergeCommit{oid}'
    }
    $query = 'query($c:String){repository(owner:"chase-sets",name:"chase-sets"){' + $owner + '{' + $name + '(first:100,after:$c){totalCount pageInfo{hasNextPage endCursor} nodes{' + $fields + '}}}}}'
    $nodes = [Collections.Generic.List[object]]::new(); $cursor=$null; $expected=$null
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursors=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    do {
        $data=Invoke-ScorecardGraphQL $query @{c=$cursor}
        $connection=if($Kind -ceq 'closing'){$data.repository.pullRequest[$name]}else{$data.repository.issue[$name]}
        Assert-ScorecardPage $connection 'totalCount'
        if($null -eq $expected){$expected=$connection.totalCount}
        if($connection.totalCount -ne $expected){throw 'connection census changed'}
        foreach($node in $connection.nodes){
            if(-not (Test-ScorecardInteger $node.number) -or $node.number -lt 1 -or -not $node.repository.nameWithOwner -or
                -not $seen.Add("$($node.repository.nameWithOwner)#$($node.number)")){throw 'invalid connection identity'}
            if($Kind -cne 'closing'){
                if(-not $node.Contains('mergedAt')){throw 'history merge state missing'}
                if($null -ne $node.mergedAt){
                    $null=ConvertTo-ScorecardUtc $node.mergedAt
                    if($node.mergeCommit.oid -cnotmatch '^[a-f0-9]{40}$'){throw 'history merge identity missing'}
                }
            }
            $nodes.Add($node)
        }
        if($connection.pageInfo.hasNextPage){
            $cursor=[string]$connection.pageInfo.endCursor
            if(-not $cursor -or -not $cursors.Add($cursor) -or $cursors.Count -ge 100){throw 'connection cursor/cap invalid'}
        }
    } while($connection.pageInfo.hasNextPage)
    if($nodes.Count -ne $expected){throw 'incomplete connection'}
    return @($nodes)
}
function Get-ScorecardClosingIssues($Pr) {
    $connection=$Pr.closingIssuesReferences
    Assert-ScorecardPage $connection 'totalCount'
    if($connection.pageInfo.hasNextPage){
        $nodes=@(Get-ScorecardConnection 'closing' $Pr.number)
        if($nodes.Count -ne $connection.totalCount){throw 'closing census changed'}
        return $nodes
    }
    if($connection.nodes.Count -ne $connection.totalCount){throw 'incomplete closing issues'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($node in $connection.nodes){
        if(-not (Test-ScorecardInteger $node.number) -or $node.number -lt 1 -or -not $node.repository.nameWithOwner -or
            -not $seen.Add("$($node.repository.nameWithOwner)#$($node.number)")){throw 'invalid closing issue identity'}
    }
    return @($connection.nodes)
}

function Invoke-ScorecardWsl([string[]]$Arguments) {
    $raw = & wsl -d Ubuntu --exec @Arguments 2>&1
    if($LASTEXITCODE -ne 0){throw 'WSL source unavailable'}
    return @($raw | ForEach-Object { [string]$_ })
}
function Get-ScorecardLocalFiles([string]$Directory, [int]$MaxDepth, [string]$Pattern) {
    if(-not [IO.Directory]::Exists($Directory)){throw 'source directory unavailable'}
    $pending=[Collections.Generic.Queue[object]]::new();$pending.Enqueue(@{path=$Directory;depth=0})
    while($pending.Count){
        $item=$pending.Dequeue()
        foreach($entry in (Get-ChildItem -LiteralPath $item.path -Force -ErrorAction Stop)){
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'source link discovery incomplete'}
            if($entry.PSIsContainer){
                if($item.depth+1 -lt $MaxDepth){$pending.Enqueue(@{path=$entry.FullName;depth=$item.depth+1})}
            } elseif($entry.Name -like $Pattern){$entry.FullName}
        }
    }
}
function Get-ScorecardNativeFiles([string]$Root, [string]$Kind, [int]$Issue = 0) {
    $unix=$Root.StartsWith('/')
    $runtime=if($unix){$Root.TrimEnd('/')+'/runtime'}else{Join-Path $Root 'runtime'}
    if($Kind -ceq 'witness'){
        $files=if($unix){Invoke-ScorecardWsl @('find',$runtime,'-mindepth','4','-maxdepth','7','-type','f','-name','merge.json')}
            else{Get-ScorecardLocalFiles $runtime 7 'merge.json'}
        foreach($file in $files){
            $relative=$file.Substring($runtime.Length).Replace('\','/').TrimStart('/')
            $parts=$relative.Split('/')
            if($parts.Count -lt 4 -or $parts.Count -gt 7 -or $parts[1] -cnotmatch '^.+-attempt-\d+$' -or
                $parts[2] -cnotin @('source','repair') -or @($parts | Where-Object {$_ -cin @('author-temp','runtime')}).Count){continue}
            $file
        }
    } else {
        # Only delivered-issue attempt directories are opened for participants.
        if($unix){
            $attempts=Invoke-ScorecardWsl @('find',$runtime,'-mindepth','2','-maxdepth','2','-type','d','-name',"cs-$Issue*-attempt-*")
        } else {
            if(-not [IO.Directory]::Exists($runtime)){throw 'runtime unavailable'}
            $attempts=@(Get-ChildItem -LiteralPath $runtime -Directory -ErrorAction Stop | ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction Stop | Select-Object -ExpandProperty FullName
            })
        }
        foreach($attempt in $attempts){
            $leaf=($attempt.Replace('\','/').Split('/'))[-1]
            if($leaf -cnotmatch "^cs-$Issue(-replan-\d+)?-attempt-\d+$"){continue}
            if($unix){Invoke-ScorecardWsl @('find',$attempt,'-mindepth','1','-maxdepth','1','-type','f','-name','participant-*-terminal.json')}
            else{Get-ScorecardLocalFiles $attempt 1 'participant-*-terminal.json'}
        }
    }
}
function Read-ScorecardNativeJson([string]$Path) {
    if($Path.StartsWith('/')){return ((Invoke-ScorecardWsl @('cat',$Path)) -join "`n" | ConvertFrom-Json -AsHashtable -DateKind String)}
    return Read-ScorecardJson $Path
}
function Get-ScorecardWitnesses([string[]]$Roots) {
    $witnesses=@{}
    try {
        if($Roots.Count -ne 2){throw 'both native roots required'}
        foreach($root in $Roots){
            foreach($path in (Get-ScorecardNativeFiles $root 'witness')){
                $merge=Read-ScorecardNativeJson $path
                $publication=Read-ScorecardNativeJson ($path -replace 'merge\.json$','publication.json')
                if(-not (Test-ScorecardInteger $merge.number) -or $merge.number -lt 1 -or
                    $merge.head -cnotmatch '^[a-f0-9]{40}$' -or $merge.mergeCommit -cnotmatch '^[a-f0-9]{40}$' -or
                    -not $publication.repository -or -not (Test-ScorecardInteger $publication.number) -or
                    $publication.head -cnotmatch '^[a-f0-9]{40}$'){throw 'invalid native witness payload'}
                if($publication.repository -cne 'chase-sets/chase-sets' -or $publication.number -ne $merge.number -or
                    $publication.head -cne $merge.head){continue}
                $key=[string]$merge.number
                if(-not $witnesses.ContainsKey($key)){$witnesses[$key]=[Collections.Generic.List[object]]::new()}
                elseif($witnesses[$key][0].mergeCommit -cne $merge.mergeCommit -or $witnesses[$key][0].head -cne $merge.head){
                    Add-ScorecardGap "platform-witness-conflict:$key"
                    throw 'conflicting native witness identity'
                } else {continue}
                $witnesses[$key].Add(@{path=$path;mergeCommit=$merge.mergeCommit;head=$merge.head})
            }
        }
        return @{complete=$true;items=$witnesses}
    } catch {
        Add-ScorecardGap 'platform-witnesses-unavailable'
        return @{complete=$false;items=@{}}
    }
}
function Get-ScorecardOwner($Pr, $Witnesses) {
    if ($Witnesses.ContainsKey([string]$Pr.number)) {
        foreach($witness in $Witnesses[[string]$Pr.number]){
            if($witness.mergeCommit -ceq $Pr.mergeCommit.oid -and $witness.head -ceq $Pr.headRefOid){return $witness.path}
        }
    }
    return $null
}
function Get-ScorecardParticipants([string[]]$Roots, [int]$Issue) {
    $seen=@{};$inputValues=[Collections.Generic.List[object]]::new();$outputValues=[Collections.Generic.List[object]]::new()
    try {
        foreach($root in $Roots){
            foreach($file in (Get-ScorecardNativeFiles $root 'participants' $Issue)){
                $row=Read-ScorecardNativeJson $file
                if(-not $row.id -or -not $row.item -or -not $row.role -or -not $row.outcome -or $null -eq $row.usage){throw 'invalid participant'}
                if($row.item -cnotmatch "^cs-$Issue(-replan-\d+)?:"){continue}
                $id=[string]$row.id
                $values=@{}
                foreach($field in @('inputTokens','outputTokens')){
                    $usage=$row.usage[$field]
                    $values[$field]=if($usage.status -ceq 'known' -and (Test-ScorecardInteger $usage.value)){$usage.value}else{$null}
                }
                # Compare the measured identity, not serialization/property order.
                $signature=@($row.item,$row.role,$row.outcome,$values.inputTokens,$values.outputTokens) | ConvertTo-Json -Compress
                if ($seen.ContainsKey($id)) {
                    if($seen[$id] -cne $signature){throw 'conflicting participant identity'}
                    continue
                }
                $seen[$id]=$signature;$inputValues.Add($values.inputTokens);$outputValues.Add($values.outputTokens)
            }
        }
        if(-not $seen.Count){throw 'delivered issue participant evidence missing'}
        $result=@{launches=$seen.Count;inputTokens=(Get-ScorecardSum @($inputValues));outputTokens=(Get-ScorecardSum @($outputValues))}
        foreach($field in @('inputTokens','outputTokens')){if($null -eq $result[$field]){Add-ScorecardGap "platform-$field-unavailable:$Issue"}}
        return $result
    } catch {
        Add-ScorecardGap "platform-participants-unavailable:$Issue"
        return @{launches=$null;inputTokens=$null;outputTokens=$null}
    }
}
function Read-ScorecardLedgers([string]$Container) {
    $runtime=Join-Path $Container '.orchestrator'
    $dispatches=[Collections.Generic.List[object]]::new();$latest=@{};$dispatchComplete=$true;$costComplete=$true
    try {
        foreach($line in [IO.File]::ReadLines((Join-Path $runtime 'dispatch-log.jsonl'))){
            if(-not $line.Trim()){continue}
            $row=$line | ConvertFrom-Json -AsHashtable -DateKind String
            if($null -eq $row -or $row -isnot [System.Collections.IDictionary]){throw 'invalid dispatch row'}
            if($row.kind -ceq 'dispatch'){
                if(-not (Test-ScorecardInteger $row.issue) -or $row.issue -lt 1){throw 'dispatch issue missing'}
                $dispatches.Add($row)
            }
        }
    } catch {$dispatchComplete=$false;Add-ScorecardGap 'dispatch-ledger-unavailable'}
    try {
        foreach($line in [IO.File]::ReadLines((Join-Path $runtime 'cost-ledger.jsonl'))){
            if(-not $line.Trim()){continue}
            $row=$line | ConvertFrom-Json -AsHashtable -DateKind String
            if(-not $row.transcript){throw 'cost transcript missing'}
            $latest[$row.transcript] = $row
        }
    } catch {$costComplete=$false;Add-ScorecardGap 'cost-ledger-unavailable'}
    return @{dispatches=@($dispatches);costs=@($latest.Values);dispatchComplete=$dispatchComplete;costComplete=$costComplete}
}
function Get-ScorecardIncumbent($Ledgers, [int]$Issue) {
    $rows=@($Ledgers.costs | Where-Object {$_.issue -eq $Issue})
    $dispatches=if($Ledgers.dispatchComplete){@($Ledgers.dispatches | Where-Object {$_.issue -eq $Issue}).Count}else{$null}
    $usd=$null
    if($Ledgers.costComplete -and $rows.Count){
        $values=@($rows | ForEach-Object {if(Test-ScorecardNumber $_.usd){$_.usd}else{$null}})
        $usd=Get-ScorecardSum $values
    }
    if($null -eq $usd){Add-ScorecardGap "incumbent-usd-unavailable:$Issue"}
    $result=@{launches=$dispatches;usd=$usd;inputTokens=$null;outputTokens=$null}
    foreach($field in @('inputTokens','outputTokens')){
        if($Ledgers.costComplete -and $rows.Count){
            $values=@($rows | ForEach-Object {if(Test-ScorecardInteger $_[$field]){$_[$field]}else{$null}})
            $result[$field]=Get-ScorecardSum $values
        }
        if($null -eq $result[$field]){Add-ScorecardGap "incumbent-$field-unavailable:$Issue"}
    }
    return $result
}
function ConvertTo-ScorecardSource([string]$Source) {
    if(-not $Source -or [IO.Path]::IsPathRooted($Source) -or $Source.Contains(':')){throw 'invalid relative source'}
    $parts=@($Source.Replace('\','/').Split('/') | Where-Object {$_ -and $_ -cne '.'})
    if(-not $parts.Count -or $parts -contains '..'){throw 'invalid source traversal'}
    return ($parts -join '/').ToLowerInvariant()
}
function Get-ScorecardInstalls([string]$Container, $Window) {
    $records=[Collections.Generic.List[object]]::new();$identities=@{};$conflict=$false
    try {
        $logs=Join-Path $Container '.orchestrator/logs';$archive=Join-Path $Container '.archive/runtime'
        if(-not [IO.Directory]::Exists($logs) -or -not [IO.Directory]::Exists($archive)){throw 'install source directory unavailable'}
        $live=@(foreach($pattern in @('m1-executor-upgrade-*.out','m1-executor-upgrade-*.log')){
            Get-ChildItem -LiteralPath $logs -File -Filter $pattern -Force -ErrorAction Stop
        })
        foreach($entry in $live){
            if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'install log link'}
            $length=$entry.Length;$at=$entry.LastWriteTimeUtc.ToString('o')
            $hash=(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $entry.Refresh()
            if($entry.Length -ne $length -or $entry.LastWriteTimeUtc.ToString('o') -cne $at){throw 'install changed during read'}
            $records.Add(@{source=('logs/'+$entry.Name);length=$length;lastWriteUtc=$at;sha256=$hash;link=$false})
        }
        $manifests=@(Get-ChildItem -LiteralPath $archive -File -Filter '*.manifest.json' -Force -ErrorAction Stop)
        foreach ($manifest in $manifests) {
            if(($manifest.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'manifest link'}
            $data=Read-ScorecardJson $manifest.FullName
            if($data.schema -cne 'runtime-retention-manifest/v1' -or $data.files -isnot [array]){throw 'invalid retention manifest'}
            foreach($entry in $data.files){
                $source=ConvertTo-ScorecardSource $entry.source
                if($source -cmatch '^logs/m1-executor-upgrade-[^/]*\.(out|log)$'){$records.Add($entry)}
            }
        }
        # Identity is reconciled BEFORE time filtering, including outside-window
        # duplicates. Archive/restoration/creation times are never consulted.
        foreach($record in $records){
            $source=ConvertTo-ScorecardSource $record.source
            if(-not (Test-ScorecardInteger $record.length) -or $record.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
                $record.link -isnot [bool] -or $record.link){throw 'invalid install entry metadata'}
            $at=ConvertTo-ScorecardUtc $record.lastWriteUtc
            $signature="$($record.length)|$($record.sha256.ToLowerInvariant())|$($at.UtcTicks)"
            if($identities.ContainsKey($source)){
                if($identities[$source].signature -cne $signature){$conflict=$true}
            } else {$identities[$source]=@{signature=$signature;at=$at}}
        }
        if($conflict){Add-ScorecardGap 'install-evidence-conflict';return $null}
        return @($identities.Values | Where-Object {$_.at -ge $Window.since -and $_.at -lt $Window.until}).Count
    } catch {Add-ScorecardGap 'install-evidence-unavailable';return $null}
}
function Get-ScorecardStarts([string]$Container, $Window) {
    try {
        $runs=Join-Path $Container '.orchestrator/platform-runs'
        if(-not [IO.Directory]::Exists($runs)){throw 'start directory unavailable'}
        $count=0
        foreach($run in (Get-ChildItem -LiteralPath $runs -Directory -Force -ErrorAction Stop)){
            foreach($file in (Get-ChildItem -LiteralPath $run.FullName -File -Filter 'start-loop*.out' -Force -ErrorAction Stop)){
                if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'start link'}
                if(Test-ScorecardWindow $file.CreationTimeUtc.ToString('o') $Window){$count++}
            }
        }
        return $count
    } catch {Add-ScorecardGap 'start-resume-evidence-unavailable';return $null}
}
function Get-ScorecardSum([object[]]$Values) {
    $sum=0
    foreach($value in $Values){if($null -eq $value){return $null};$sum+=$value}
    return $sum
}
function Get-ScorecardRatio($Numerator, $Denominator) {
    if($null -eq $Numerator -or $null -eq $Denominator -or $Denominator -eq 0){return $null}
    return $Numerator/$Denominator
}
function Get-ScorecardDeliveries($Prs, $Witnesses, [string[]]$Roots, $Ledgers) {
    $systems=@{platform=[Collections.Generic.List[object]]::new();incumbent=[Collections.Generic.List[object]]::new()}
    $delivered=[Collections.Generic.HashSet[int]]::new()
    foreach($pr in ($Prs | Sort-Object @{Expression={ConvertTo-ScorecardUtc $_.mergedAt}},number)){
        $closing=Get-ScorecardClosingIssues $pr
        foreach($issue in $closing){
            if($issue.repository.nameWithOwner -cne 'chase-sets/chase-sets' -or -not $delivered.Add([int]$issue.number)){continue}
            $number=[int]$issue.number;$redelivered=$null
            try {
                $history=Get-ScorecardConnection 'history' $number
                $redelivered=@($history | Where-Object {$_.mergedAt -and (ConvertTo-ScorecardUtc $_.mergedAt) -lt (ConvertTo-ScorecardUtc $pr.mergedAt)}).Count -gt 0
            } catch {Add-ScorecardGap "history-incomplete:$number"}
            $witness=Get-ScorecardOwner $pr $Witnesses
            $owner=if($witness){'platform'}else{'incumbent'}
            $cohort=if($witness){Get-ScorecardParticipants $Roots $number}else{Get-ScorecardIncumbent $Ledgers $number}
            $systems[$owner].Add([ordered]@{repository='chase-sets/chase-sets';issue=$number;pr=$pr.number;
                mergedAt=$pr.mergedAt;mergeCommit=$pr.mergeCommit.oid;redelivered=$redelivered;launches=$cohort.launches;
                inputTokens=$cohort.inputTokens;outputTokens=$cohort.outputTokens;usd=$(if($witness){$null}else{$cohort.usd});witness=$witness})
        }
    }
    return $systems
}
function ConvertTo-ScorecardMarkdown($Report) {
    $p=$Report.systems.platform;$i=$Report.systems.incumbent;$v=$p.interventions
    function Cell($Value){if($null -eq $Value){'null'}else{[string]$Value}}
    $lines=@('# Platform Scorecard', '', "UTC half-open [$($Report.window.since), $($Report.window.until)).", '',
        '| System | Delivered issues | Launches / dispatches | Per issue | Input tokens | Output tokens | USD | USD per issue |',
        '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |',
        "| Platform | $(Cell $p.deliveredIssues) | $(Cell $p.launches) | $(Cell $p.launchesPerIssue) | $(Cell $p.inputTokens) | $(Cell $p.outputTokens) | null | n/a |",
        "| Incumbent | $(Cell $i.deliveredIssues) | $(Cell $i.dispatches) | $(Cell $i.dispatchesPerIssue) | n/a | n/a | $(Cell $i.usd) | $(Cell $i.usdPerIssue) |", '',
        '| Intervention proxy | Count | UTC time basis |', '| --- | ---: | --- |',
        "| Starts / resumes (both loops) | $(Cell $v.startResume) | creation UTC |",
        "| M1 logged installs | $(Cell $v.installs) | last-write UTC, live and archived |",
        "| Platform planning PRs | $(Cell $v.planningPrs) | merge UTC |", "| Total | $(Cell $v.total) | proxy |", '',
        'Diagnostic proxies share the Chase Sets delivery denominator; not a complete or scope-normalized intervention census, adoption verdict or D-T1 proof. Platform USD is unpriced.', '',
        '| System | Issue | PR | Redelivered | Witness |', '| --- | ---: | ---: | --- | --- |')
    foreach($name in @('platform','incumbent')){
        foreach($issue in $Report.systems[$name].issues){
            $path=if($issue.witness){([string]$issue.witness).Replace('|','\|')}else{'null'}
            $lines+="| $name | $($issue.issue) | $($issue.pr) | $(Cell $issue.redelivered) | $path |"
        }
    }
    $lines+=@('', 'Gaps:')
    if($Report.gaps.Count){$lines+=@($Report.gaps | ForEach-Object {"- $_"})}else{$lines+='- none'}
    return ($lines -join "`n")+"`n"
}
function Invoke-PlatformScorecard {
    param([string]$Since, [string]$Until, [string]$Out, [string]$ContainerRoot, [string[]]$RuntimeRoots)
    $script:ScorecardGaps=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $window=@{since=(ConvertTo-ScorecardUtc $Since -DateOnly);until=(ConvertTo-ScorecardUtc $Until -DateOnly)}
    if($window.since -ge $window.until){throw 'Since must precede Until'}
    $witnesses=Get-ScorecardWitnesses $RuntimeRoots
    $ledgers=Read-ScorecardLedgers $ContainerRoot
    $complete=$true;$deliveries=@{platform=@();incumbent=@()}
    try {
        $prs=@(Get-ScorecardMergedPrs 'chase-sets/chase-sets' $window)
        if($witnesses.complete){$deliveries=Get-ScorecardDeliveries $prs $witnesses.items $RuntimeRoots $ledgers}
        else{$complete=$false}
    } catch {$complete=$false;Add-ScorecardGap 'github-deliveries-incomplete'}
    $planning=$null
    try {
        $plans=@(Get-ScorecardMergedPrs 'todd-skelton/orchestration-platform' $window)
        $planning=@($plans | Where-Object {$_.headRefName -cmatch '^(plan|planning|replan)/'}).Count
    } catch {Add-ScorecardGap 'github-planning-incomplete'}
    $starts=Get-ScorecardStarts $ContainerRoot $window;$installs=Get-ScorecardInstalls $ContainerRoot $window
    $p=@($deliveries.platform);$i=@($deliveries.incumbent)
    $pd=if($complete){$p.Count}else{$null};$id=if($complete){$i.Count}else{$null}
    $launches=if($complete){Get-ScorecardSum @($p | ForEach-Object {$_.launches})}else{$null}
    $inputTotal=if($complete){Get-ScorecardSum @($p | ForEach-Object {$_.inputTokens})}else{$null}
    $outputTotal=if($complete){Get-ScorecardSum @($p | ForEach-Object {$_.outputTokens})}else{$null}
    $dispatches=if($complete){Get-ScorecardSum @($i | ForEach-Object {$_.launches})}else{$null}
    $usd=if($complete){Get-ScorecardSum @($i | ForEach-Object {$_.usd})}else{$null}
    Add-ScorecardGap 'platform-usd-unpriced'
    $report=[ordered]@{schemaVersion='platform-scorecard/v1';window=@{since=(Format-ScorecardUtc $window.since);until=(Format-ScorecardUtc $window.until)};
        generatedAt=(Format-ScorecardUtc ([DateTimeOffset]::UtcNow));systems=@{
            platform=@{deliveredIssues=$pd;issues=@(if($complete){$p});launches=$launches;launchesPerIssue=(Get-ScorecardRatio $launches $pd);
                inputTokens=$inputTotal;outputTokens=$outputTotal;usd=$null;
                interventions=@{startResume=$starts;installs=$installs;planningPrs=$planning;total=(Get-ScorecardSum @($starts,$installs,$planning));basis='proxy'}};
            incumbent=@{deliveredIssues=$id;issues=@(if($complete){$i});dispatches=$dispatches;dispatchesPerIssue=(Get-ScorecardRatio $dispatches $id);
                usd=$usd;usdPerIssue=(Get-ScorecardRatio $usd $id)}};gaps=@($script:ScorecardGaps | Sort-Object)}
    $json=ConvertTo-Json -InputObject $report -Depth 30
    $markdown=ConvertTo-ScorecardMarkdown $report
    if($Out){
        $jsonPath=[IO.Path]::GetFullPath($Out);$markdownPath=[IO.Path]::ChangeExtension($jsonPath,'.md')
        if($jsonPath -eq $markdownPath){throw '-Out must not name a Markdown file'}
        [IO.File]::WriteAllText($jsonPath,$json+"`n");[IO.File]::WriteAllText($markdownPath,$markdown)
    } else {$json;$markdown}
}

if (-not $FunctionsOnly) {
    Invoke-PlatformScorecard -Since $Since -Until $Until -Out $Out -ContainerRoot $ContainerRoot -RuntimeRoots $RuntimeRoots
}
