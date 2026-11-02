<#
.SYNOPSIS
Report seven-day runtime retention, or archive verified bytes before object-bound deletion.
.DESCRIPTION
I/O: metadata/age walk before hashing old candidates; metadata/path-set rechecks after
harvest and verification; archive source reads, closed-partial-ZIP and locked
published-ZIP read-back hashes (also reverified for cadence);
one additional full content-hash read through each exclusive CreateFile deletion
handle (also used for FileDispositionInfo). No recursive delete or archive pruning.
Reference text and cached protection matches are built once per run. Each delete
batch (at most 128 items) refreshes only git ls-files and the process snapshot.
Report mode never harvests or writes. Apply runs the unchanged cost harvester
with -Backfill only when due. Dependencies are library-only hermetic test seams.
#>
[CmdletBinding()]
param([switch]$Apply, [string]$Root = (Split-Path -Parent $PSScriptRoot), [switch]$Library)
$ErrorActionPreference = 'Stop'

function Initialize-RetentionNative {
    if ('RuntimeRetention.Handle' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace RuntimeRetention {
 public sealed class Handle : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct Info {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
   public uint Volume, High, Low, Links, IndexHigh, IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFile(string p,uint a,uint s,IntPtr sa,uint d,uint f,IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle h,StringBuilder s,uint n,uint f);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetFileInformationByHandle(SafeFileHandle h,int c,ref byte b,uint n);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool DeviceIoControl(SafeFileHandle h,uint c,IntPtr i,uint ni,byte[] o,uint no,out uint got,IntPtr overlapped);
  SafeFileHandle handle; FileStream stream;
  static Exception Failure() { int e=Marshal.GetLastWin32Error(); return new IOException(e==32 || e==33 ? "in-use" : "changed-during-apply",new Win32Exception(e)); }
  static string Canonical(string p) { if(p.StartsWith(@"\\?\UNC\")) return @"\\"+p.Substring(8); return p.StartsWith(@"\\?\") ? p.Substring(4) : p; }
  Handle(string path,bool directory,bool link,bool deletion) {
   // Directory guards deny rename/delete but allow ordinary child I/O.
   uint access=0x80000000u | (deletion ? 0x10000u : 0u);
   handle=CreateFile(path,access,directory && !link ? 3u : 0u,IntPtr.Zero,3,0x02200000u,IntPtr.Zero);
   if(handle.IsInvalid) { handle.Dispose(); throw Failure(); }
   try {
    Info info; if(!GetFileInformationByHandle(handle,out info)) throw Failure();
    bool reparse=(info.Attributes & 0x400)!=0;
    if(reparse!=link || (info.Attributes & 1)!=0 || (!link && ((info.Attributes & 16)!=0)!=directory)) throw new IOException("changed-during-apply");
    var final=new StringBuilder(32768); uint n=GetFinalPathNameByHandle(handle,final,(uint)final.Capacity,0);
    if(n==0 || n>=final.Capacity || !String.Equals(Canonical(final.ToString()).TrimEnd('\\'),Path.GetFullPath(path).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)) throw new IOException("changed-during-apply");
   } catch { Dispose(); throw; }
  }
  public static Handle DirectoryGuard(string p) { return new Handle(p,true,false,false); }
  byte[] LinkBytes() {
   byte[] data=new byte[16384]; uint got;
   if(!DeviceIoControl(handle,0x000900A8,IntPtr.Zero,0,data,(uint)data.Length,out got,IntPtr.Zero)) throw Failure();
   return Encoding.UTF8.GetBytes(Convert.ToBase64String(data,0,(int)got)+"\n");
  }
  public static byte[] ReadLink(string p) { using(var h=new Handle(p,false,true,false)) return h.LinkBytes(); }
  public static Handle Verified(string p,long length,long ticks,string hash,bool link) {
   var h=new Handle(p,false,link,true);
   try {
    Info info; if(!GetFileInformationByHandle(h.handle,out info)) throw Failure();
    long time=DateTime.FromFileTimeUtc(((long)info.Write.dwHighDateTime<<32)|(uint)info.Write.dwLowDateTime).Ticks;
    if(time!=ticks) throw new IOException("changed-during-apply");
    string actual; long size;
    if(link) { byte[] bytes=h.LinkBytes(); size=bytes.Length; actual=Convert.ToHexString(SHA256.HashData(bytes)); }
    else {
     h.stream=new FileStream(h.handle,FileAccess.Read);
     size=h.stream.Length;
     if(size!=length) throw new IOException("changed-during-apply");
     actual=Convert.ToHexString(SHA256.HashData(h.stream));
    }
    if(size!=length || !String.Equals(actual,hash,StringComparison.OrdinalIgnoreCase)) throw new IOException("changed-during-apply");
    return h;
   } catch { h.Dispose(); throw; }
  }
  public void MarkDelete() { byte disposition=1; if(!SetFileInformationByHandle(handle,4,ref disposition,1)) throw Failure(); }
  public static void RemoveEmptyDirectory(string p) {
   using(var h=new Handle(p,true,false,true)) h.MarkDelete(); // Kernel refuses a nonempty directory.
  }
  public void Dispose() { if(stream!=null) stream.Dispose(); if(handle!=null) handle.Dispose(); }
 }
}
'@
}

function ConvertTo-RetentionAuthority($Capture) {
    $numbers=[Collections.Generic.HashSet[long]]::new()
    try {
        foreach($kind in @('openIssues','openPrs')) {
            $collections=@($Capture.$kind)
            if($collections.Count -ne 2){throw 'missing repositories'}
            foreach($repo in @('chase-sets/chase-sets','todd-skelton/orchestration-platform')) {
                $rows=@($collections | Where-Object repository -CEQ $repo)
                if($rows.Count -ne 1){throw 'repository ambiguity'}
                $c=$rows[0]; $seen=[Collections.Generic.HashSet[long]]::new()
                $values=if($kind -eq 'openIssues'){@($c.numbers)}else{@($c.nodesData | ForEach-Object number)}
                $collection=if($kind -eq 'openIssues'){'issues(states:OPEN)'}else{'pullRequests(states:OPEN)'}
                if($c.complete -isnot [bool] -or -not $c.complete -or $c.collection -cne $collection -or
                   ($c.pages -isnot [int] -and $c.pages -isnot [long]) -or $c.pages -lt 1 -or
                   ($c.totalCount -isnot [int] -and $c.totalCount -isnot [long]) -or $c.totalCount -lt 0 -or
                   ($c.nodes -isnot [int] -and $c.nodes -isnot [long]) -or $c.nodes -ne $values.Count -or $c.totalCount -ne $values.Count){throw 'incomplete'}
                foreach($n in $values) {
                    if(($n -isnot [int] -and $n -isnot [long]) -or $n -lt 1 -or -not $seen.Add([long]$n)){throw 'invalid number'}
                    [void]$numbers.Add([long]$n)
                }
            }
        }
        return @{known=$true;numbers=$numbers}
    } catch { return @{known=$false;numbers=[Collections.Generic.HashSet[long]]::new()} }
}

function Get-RetentionAuthority {
    param([scriptblock]$ReadPages = {
        param($query,$owner,$name)
        $json=& gh api graphql --paginate --slurp -f "query=$query" -f "owner=$owner" -f "name=$name" 2>$null
        if($LASTEXITCODE -ne 0){throw 'authority read failed'}
        ($json -join "`n") | ConvertFrom-Json
    })
    $capture=@{openIssues=@();openPrs=@()}
    try {
        foreach($repo in @('chase-sets/chase-sets','todd-skelton/orchestration-platform')) {
            $owner,$name=$repo.Split('/')
            foreach($kind in @('issues','pullRequests')) {
                $fields=if($kind -eq 'issues'){'number'}else{'number headRefName headRefOid baseRefName'}
                $query='query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){'+$kind+'(states:OPEN,first:100,after:$endCursor){totalCount nodes{'+$fields+'} pageInfo{hasNextPage endCursor}}}}'
                $pages=@(& $ReadPages $query $owner $name)
                $nodes=[Collections.Generic.List[object]]::new(); $total=$null; $cursors=[Collections.Generic.HashSet[string]]::new()
                if($pages.Count -lt 1){throw 'no pages'}
                for($i=0;$i -lt $pages.Count;$i++) {
                    if($pages[$i].errors){throw 'graphql errors'}
                    $p=$pages[$i].data.repository.$kind
                    if($null -eq $p -or ($p.totalCount -isnot [int] -and $p.totalCount -isnot [long]) -or ($null -ne $total -and $total -ne $p.totalCount)){throw 'moving total'}
                    $total=$p.totalCount
                    if($p.pageInfo.hasNextPage -isnot [bool] -or $p.pageInfo.hasNextPage -ne ($i -lt $pages.Count-1)){throw 'missing page'}
                    if($p.pageInfo.hasNextPage -and ([string]::IsNullOrEmpty($p.pageInfo.endCursor) -or -not $cursors.Add($p.pageInfo.endCursor))){throw 'cursor'}
                    foreach($n in $p.nodes){$nodes.Add($n)}
                }
                $row=@{repository=$repo;collection="$kind(states:OPEN)";totalCount=$total;nodes=$nodes.Count;pages=$pages.Count;complete=$true}
                if($kind -eq 'issues'){$row.numbers=@($nodes | ForEach-Object number);$capture.openIssues+=,$row}
                else{$row.nodesData=@($nodes);$capture.openPrs+=,$row}
            }
        }
        return $capture
    } catch { return $null }
}

function Get-RetentionContext([string]$Root) {
    try {
        $tracked=@(& git -C $Root -c core.quotepath=false ls-files -- .orchestrator)
        if($LASTEXITCODE -ne 0){throw 'tracked unknown'}
        $refs=[Text.StringBuilder]::new()
        foreach($p in $tracked) {
            if($p -match '\.(ps1|psm1|mjs|js|cjs|sh|vbs|py)$' -or $p -like '.orchestrator/controller-skills/*') {
                [void]$refs.AppendLine([IO.File]::ReadAllText((Join-Path $Root $p)))
            }
        }
        # Installed skills are additional readers, never inferred from source alone.
        foreach($base in @((Join-Path $HOME '.codex/skills'),(Join-Path $HOME '.claude/skills'))) {
            foreach($skill in @('milestone-orchestrator','model-routing')) {
                $p=Join-Path $base "$skill/SKILL.md"
                if(Test-Path -LiteralPath $p){
                    foreach($file in Get-ChildItem -LiteralPath (Split-Path $p -Parent) -File -Recurse -ErrorAction Stop){
                        [void]$refs.AppendLine([IO.File]::ReadAllText($file.FullName))
                    }
                }
            }
        }
        $commands=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object CommandLine | ForEach-Object CommandLine)
        return @{complete=$true;tracked=$tracked;references=$refs.ToString();commands=$commands}
    } catch { return @{complete=$false;tracked=@();references='';commands=@()} }
}

function Get-RetentionProtectionSnapshot([string]$Root) {
    try {
        $tracked=@(& git -C $Root -c core.quotepath=false ls-files -- .orchestrator)
        if($LASTEXITCODE -ne 0){throw 'tracked unknown'}
        $commands=@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object CommandLine | ForEach-Object CommandLine)
        return @{complete=$true;tracked=$tracked;commands=$commands}
    } catch { return @{complete=$false;tracked=@();commands=@()} }
}

function New-RetentionProtectionSets($Context,$Snapshot,$ReferenceMatches) {
    if($ReferenceMatches.text -cne $Context.references){$ReferenceMatches.matches.Clear();$ReferenceMatches.text=$Context.references}
    $trackedItems=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($p in $Snapshot.tracked) {
        $q=$p -replace '^\.orchestrator/',''
        while($q){[void]$trackedItems.Add($q);$i=$q.LastIndexOf('/');if($i -lt 0){break};$q=$q.Substring(0,$i)}
    }
    return @{complete=($Context.complete -and $Snapshot.complete);trackedItems=$trackedItems;
        referenceText=$ReferenceMatches.text;referenceMatches=$ReferenceMatches.matches;
        processText=(@($Snapshot.commands | ForEach-Object {$_.Replace('\','/')}) -join "`n");
        liveMatches=[Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::OrdinalIgnoreCase)}
}

function Get-RetentionLedger([string]$Root) {
    $ledger=@{}
    try {
        $path=Join-Path $Root '.orchestrator/cost-ledger.jsonl'
        if(Test-Path -LiteralPath $path) {
            foreach($line in [IO.File]::ReadLines($path)) {
                if(-not $line.Trim()){continue}
                $r=$line | ConvertFrom-Json
                if([string]::IsNullOrEmpty($r.transcript)){throw 'invalid ledger'}
                $ledger[$r.transcript]=$r
            }
        }
        return $ledger
    } catch { return @{} }
}
function Invoke-RetentionHarvest([string]$Root) {
    & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $Root '.orchestrator/cost-harvest.ps1') -Backfill -TranscriptDir (Join-Path $Root '.orchestrator') -Ledger (Join-Path $Root '.orchestrator/cost-ledger.jsonl') *> $null
    return @{ok=($LASTEXITCODE -eq 0);ledger=(Get-RetentionLedger $Root)}
}

function Get-RetentionSnapshot([string]$Runtime,[string]$Relative,[switch]$MetadataOnly) {
    $files=[Collections.Generic.List[object]]::new(); $dirs=[Collections.Generic.List[string]]::new()
    $reason=''; $newest=[datetime]::MinValue
    try {
        $top=Get-Item -LiteralPath (Join-Path $Runtime $Relative) -Force -ErrorAction Stop
        $stack=[Collections.Generic.Stack[object]]::new();$stack.Push($top)
        while($stack.Count) {
            $entry=$stack.Pop();$entry.Refresh()
            $relativePath=[IO.Path]::GetRelativePath($Runtime,$entry.FullName).Replace('\','/')
            if($entry.LastWriteTimeUtc -gt $newest){$newest=$entry.LastWriteTimeUtc}
            if($entry.Attributes -band [IO.FileAttributes]::ReadOnly){$reason='read-only';break}
            $link=[bool]($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)
            if($link -and $relativePath -cne $Relative){$reason='reparse-descendant';break}
            if($link -and $Relative.Contains('/')){$reason='reparse-descendant';break}
            if($entry.PSIsContainer -and -not $link) {
                $dirs.Add($relativePath)
                foreach($child in Get-ChildItem -LiteralPath $entry.FullName -Force -ErrorAction Stop){$stack.Push($child)}
                continue
            }
            $bytes=$null;$hash='';$length=0
            if($link) {
                if($MetadataOnly){$length=-1}
                else{Initialize-RetentionNative; $bytes=[RuntimeRetention.Handle]::ReadLink($entry.FullName); $length=$bytes.Length}
            }
            else { $length=$entry.Length }
            if(-not $MetadataOnly) {
                if($link){$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes)).ToLowerInvariant()}
                else{$hash=(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
                $entry.Refresh()
                if(-not $link -and $entry.Length -ne $length){throw 'changed while hashing'}
            }
            $files.Add([pscustomobject]@{path=$(if($link){$relativePath+'.link.txt'}else{$relativePath});source=$relativePath;length=$length;lastWriteUtc=$entry.LastWriteTimeUtc.ToString('o');sha256=$hash;link=$link;bytes=$bytes})
        }
    } catch { $reason='enumeration-failed' }
    return @{files=@($files | Sort-Object path);directories=@($dirs | Sort-Object);newest=$newest;reason=$reason}
}

function Get-RetentionReason($Item,$Context,$Authority,$Harvest,[datetime]$Now) {
    $paths=@($Item.path)+@($Item.snapshot.files | ForEach-Object source)+@($Item.snapshot.directories)
    if($Context.trackedItems.Contains($Item.path)){return 'tracked'}
    $protected='^(logs|artifacts|salvage|platform-runs|contracts|controller-skills|fixtures|lease\.json|.*\.d|.*ledger.*|dispatch-log\.jsonl|flow-log\.jsonl|main-sync\.log|platform-handoff\.md|.*\.schema\.json|.*lkg.*|.*\.toml|.*config.*|.*\.fixture\.json|controller-review-.*\.json|breaker-.*\.json|host-.*guardrails\.md|.*ownership.*|.*owner.*\.json|README.*|\.gitignore)$'
    foreach($p in $paths){if([IO.Path]::GetFileName($p) -match $protected){return 'protected-name'}}
    if(-not $Context.complete){return 'protection-authority-unknown'}
    foreach($p in $paths) {
        if(-not $Context.liveMatches.ContainsKey($p)){$Context.liveMatches[$p]=$Context.processText.IndexOf($p,[StringComparison]::OrdinalIgnoreCase) -ge 0}
        if($Context.liveMatches[$p]){return 'live-process'}
    }
    if($Item.snapshot.reason){return $Item.snapshot.reason}
    if($Item.snapshot.newest -ge $Now.AddDays(-7)){return 'recent'}
    foreach($p in $paths){
        $name=[IO.Path]::GetFileName($p)
        if(-not $Context.referenceMatches.ContainsKey($name)){$Context.referenceMatches[$name]=$Context.referenceText.IndexOf($name,[StringComparison]::OrdinalIgnoreCase) -ge 0}
        if($Context.referenceMatches[$name]){return 'referenced'}
    }
    foreach($p in $paths) {
        if($p -notmatch '\.(md|json)$'){continue}
        $matches=[regex]::Matches([IO.Path]::GetFileName($p),'(?<!\d)\d+(?!\d)')
        if($matches.Count -and -not $Authority.known){return 'open-number-authority-unknown'}
        foreach($m in $matches){$n=0L;if([long]::TryParse($m.Value,[ref]$n) -and $Authority.numbers.Contains($n)){return 'open-number-receipt'}}
    }
    foreach($f in $Item.snapshot.files) {
        if($f.source -notlike '*.jsonl'){continue}
        if($f.source.Contains('/')){return 'nested-transcript-unsupported'}
        $row=$Harvest.ledger[$f.source]
        if(-not $Harvest.ok -or $null -eq $row -or ($row.bytes -isnot [int] -and $row.bytes -isnot [long]) -or $row.bytes -ne $f.length){return 'transcript-not-covered'}
    }
    return 'eligible'
}

function Test-RetentionUnchanged($Before,$After) {
    if($After.reason -or $Before.files.Count -ne $After.files.Count -or ($Before.directories -join "`n") -cne ($After.directories -join "`n")){return $false}
    for($i=0;$i -lt $Before.files.Count;$i++){
        $a=$Before.files[$i];$b=$After.files[$i]
        if($a.path -cne $b.path -or (-not $a.link -and $a.length -ne $b.length) -or $a.lastWriteUtc -cne $b.lastWriteUtc -or $a.link -ne $b.link){return $false}
    }
    return $true
}
function Write-RetentionZip([string]$Path,$Files) {
    $s=[IO.File]::Open($Path,'CreateNew','Write','None');$zip=[IO.Compression.ZipArchive]::new($s,'Create')
    try {
        foreach($f in $Files) {
            $e=$zip.CreateEntry($f.path);$out=$e.Open()
            try {
                if($f.link){$out.Write([byte[]]$f.bytes,0,$f.bytes.Length)}
                else{$input=[IO.File]::OpenRead($f.fullPath);try{$input.CopyTo($out)}finally{$input.Dispose()}}
            } finally {$out.Dispose()}
        }
    } finally {$zip.Dispose();$s.Dispose()}
}
function Test-RetentionZip([string]$Path,$Files) {
    try {
        $zip=[IO.Compression.ZipFile]::OpenRead($Path)
        try {
            if($zip.Entries.Count -ne @($Files).Count){return $false}
            $expected=@{};foreach($f in $Files){if($expected.ContainsKey($f.path)){return $false};$expected[$f.path]=$f}
            foreach($e in $zip.Entries) {
                if(-not $expected.ContainsKey($e.FullName)){return $false}
                $f=$expected[$e.FullName]
                if($e.FullName -cne $f.path -or $e.Length -ne $f.length){return $false}
                $s=$e.Open();try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($s)).ToLowerInvariant()}finally{$s.Dispose()}
                if($hash -cne $f.sha256){return $false}
                $expected.Remove($e.FullName)
            }
            return $expected.Count -eq 0
        } finally {$zip.Dispose()}
    } catch {return $false}
}
function Test-RetentionDue([string]$Archive,[datetime]$Now) {
    if(-not (Test-Path -LiteralPath $Archive)){return $true}
    foreach($p in Get-ChildItem -LiteralPath $Archive -Filter '*.manifest.json' -File -ErrorAction Stop) {
        try {
            $m=[IO.File]::ReadAllText($p.FullName)|ConvertFrom-Json -DateKind String
            $at=[datetime]::Parse($m.verifiedAt).ToUniversalTime()
            if($m.schema -cne 'runtime-retention-manifest/v1' -or $at -gt $Now -or $at -le $Now.AddHours(-24)){continue}
            $zip=$p.FullName -replace '\.manifest\.json$','.zip'
            if(Test-RetentionZip $zip $m.files){return $false}
        } catch {continue}
    }
    return $true
}

function Remove-RetentionItem($Item,[string]$Runtime) {
    $guards=[Collections.Generic.List[object]]::new();$handles=[Collections.Generic.List[object]]::new()
    try {
        $parents=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($d in $Item.snapshot.directories){[void]$parents.Add((Join-Path $Runtime $d))}
        foreach($f in $Item.snapshot.files) {
            $p=Split-Path (Join-Path $Runtime $f.source) -Parent
            while($p.Length -ge $Runtime.Length){[void]$parents.Add($p);$p=Split-Path $p -Parent}
        }
        foreach($p in @($parents | Sort-Object Length)){$guards.Add([RuntimeRetention.Handle]::DirectoryGuard($p))}
        foreach($f in $Item.snapshot.files) {
            $handles.Add([RuntimeRetention.Handle]::Verified((Join-Path $Runtime $f.source),$f.length,([datetime]::Parse($f.lastWriteUtc).ToUniversalTime().Ticks),$f.sha256,$f.link))
        }
        $after=Get-RetentionSnapshot $Runtime $Item.path -MetadataOnly
        if(-not (Test-RetentionUnchanged $Item.snapshot $after)){throw 'changed-during-apply'}
        foreach($h in $handles){$h.MarkDelete()}
        return 'deleted'
    } catch {
        if($_.Exception.ToString().Contains('in-use')){return 'in-use'}
        return 'changed-during-apply'
    } finally {
        foreach($h in $handles){$h.Dispose()}
        for($i=$guards.Count-1;$i -ge 0;$i--){$guards[$i].Dispose()}
    }
}

function Invoke-RuntimeRetention {
    param([string]$Root,[datetime]$Now=[datetime]::UtcNow,[switch]$Apply,[hashtable]$Dependencies=@{})
    $Root=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$runtime=Join-Path $Root '.orchestrator';$archive=Join-Path $Root '.archive/runtime'
    $defaults=@{Context={param($r)Get-RetentionContext $r};ProtectionSnapshot={param($r)Get-RetentionProtectionSnapshot $r};Authority={Get-RetentionAuthority};Harvest={param($r)Invoke-RetentionHarvest $r};Phase={param($s,$r)};ZipWriter={param($p,$f)Write-RetentionZip $p $f}}
    foreach($k in $defaults.Keys){if(-not $Dependencies.ContainsKey($k)){$Dependencies[$k]=$defaults[$k]}}
    # No walk or write through a linked runtime/archive ancestor.
    foreach($p in @($Root,$runtime,(Join-Path $Root '.archive'),$archive)){
        if((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'retention root is a reparse point'}
    }
    $due=Test-RetentionDue $archive $Now
    if($Apply -and -not $due){return [pscustomobject]@{schema='runtime-retention-report/v1';mode='apply';due=$false;published=$false;archive=$null;manifest=$null;error=$null;items=@()}}
    $authority=ConvertTo-RetentionAuthority (& $Dependencies.Authority)
    $context=& $Dependencies.Context $Root
    $referenceMatches=@{text=$context.references;matches=[Collections.Generic.Dictionary[string,bool]]::new([StringComparer]::OrdinalIgnoreCase)}
    $protection=New-RetentionProtectionSets $context $context $referenceMatches
    $harvest=@{ok=$true;ledger=(Get-RetentionLedger $Root)}
    $items=[Collections.Generic.List[object]]::new()
    foreach($top in Get-ChildItem -LiteralPath $runtime -Force -ErrorAction Stop) {
        if($top.Name -in @('logs','artifacts') -and $top.PSIsContainer -and -not ($top.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            foreach($child in Get-ChildItem -LiteralPath $top.FullName -Force -ErrorAction Stop){$items.Add(@{path=$top.Name+'/'+$child.Name;action='retain';reason='';snapshot=$null;entries=$null;oversized=$null})}
        } else {$items.Add(@{path=$top.Name;action='retain';reason='';snapshot=$null;entries=$null;oversized=$null})}
    }
    foreach($item in $items) {
        # Protected/tracked trees need not be opened at all.
        $item.snapshot=@{files=@();directories=@();newest=[datetime]::MinValue;reason=''}
        $reason=Get-RetentionReason $item $protection $authority $harvest $Now
        if($reason -in @('tracked','protected-name','live-process','protection-authority-unknown')){$item.reason=$reason;continue}
        $item.snapshot=Get-RetentionSnapshot $runtime $item.path -MetadataOnly
        $collected=$item.snapshot.files.Count+$item.snapshot.directories.Count
        if(-not $item.snapshot.reason){$item.entries=$collected}
        if($collected -gt 2000){$item.oversized=$true}
        elseif(-not $item.snapshot.reason){$item.oversized=$false}
        $item.reason=Get-RetentionReason $item $protection $authority $harvest $Now
        if($item.reason -in @('eligible','transcript-not-covered')) {
            $metadata=$item.snapshot
            $item.snapshot=Get-RetentionSnapshot $runtime $item.path
            if(-not (Test-RetentionUnchanged $metadata $item.snapshot)){$item.reason='changed-during-apply';continue}
            $item.reason=Get-RetentionReason $item $protection $authority $harvest $Now
        }
        if($item.reason -eq 'eligible'){$item.action='archive'}
    }
    $report=[ordered]@{schema='runtime-retention-report/v1';mode=$(if($Apply){'apply'}else{'report'});due=$due;published=$false;archive=$null;manifest=$null;error=$null;items=$items}
    if(-not $Apply -or -not $report.due){return [pscustomobject]$report}
    Initialize-RetentionNative
    & $Dependencies.Phase 'after-gather' $Root
    try{$harvest=& $Dependencies.Harvest $Root}catch{$harvest=@{ok=$false;ledger=@{}}}
    & $Dependencies.Phase 'after-harvest' $Root
    foreach($item in $items) {
        if($item.reason -notin @('eligible','transcript-not-covered')){continue}
        $fresh=Get-RetentionSnapshot $runtime $item.path -MetadataOnly
        if(-not (Test-RetentionUnchanged $item.snapshot $fresh)){$item.action='retain';$item.reason='changed-during-apply';continue}
        $item.reason=Get-RetentionReason $item $protection $authority $harvest $Now
        $item.action=if($item.reason -eq 'eligible'){'archive'}else{'retain'}
    }
    $files=@($items | Where-Object action -eq 'archive' | ForEach-Object {$_.snapshot.files} | ForEach-Object {
        $_ | Add-Member -NotePropertyName fullPath -NotePropertyValue (Join-Path $runtime $_.source) -Force -PassThru
    })
    $archiveGuards=[Collections.Generic.List[object]]::new()
    try {
        # Hold each existing ancestor before creating its child or publishing.
        $archiveGuards.Add([RuntimeRetention.Handle]::DirectoryGuard($Root))
        foreach($p in @((Join-Path $Root '.archive'),$archive)){
            [IO.Directory]::CreateDirectory($p)|Out-Null
            $archiveGuards.Add([RuntimeRetention.Handle]::DirectoryGuard($p))
        }
        $stem=Join-Path $archive $Now.ToString('yyyyMMddTHHmmssZ')
        foreach($suffix in @('.zip','.manifest.json','.zip.partial','.manifest.json.partial')){if(Test-Path -LiteralPath ($stem+$suffix)){throw 'archive-name-collision'}}
        & $Dependencies.ZipWriter ($stem+'.zip.partial') $files
        if(-not (Test-RetentionZip ($stem+'.zip.partial') $files)){throw 'archive-verification-failed'}
        $manifest=@{schema='runtime-retention-manifest/v1';verifiedAt=$Now.ToString('o');files=@($files | Select-Object path,source,length,lastWriteUtc,sha256,link)}
        $bytes=[Text.Encoding]::UTF8.GetBytes(($manifest|ConvertTo-Json -Depth 8))
        $s=[IO.File]::Open(($stem+'.manifest.json.partial'),'CreateNew','Write','None');try{$s.Write($bytes,0,$bytes.Length);$s.Flush($true)}finally{$s.Dispose()}
        & $Dependencies.Phase 'before-publish' $Root
        [IO.File]::Move(($stem+'.zip.partial'),($stem+'.zip'))
        [IO.File]::Move(($stem+'.manifest.json.partial'),($stem+'.manifest.json'))
        $report.published=$true;$report.archive=$stem+'.zip';$report.manifest=$stem+'.manifest.json'
    } catch {
        $report.error=$_.Exception.Message
        for($i=$archiveGuards.Count-1;$i -ge 0;$i--){$archiveGuards[$i].Dispose()}
        return [pscustomobject]$report
    }
    $publishedHandles=[Collections.Generic.List[object]]::new()
    try {
      # Publication is followed by a locked reverify: the published bytes cannot
      # be replaced or written while any source deletion relies on them.
      foreach($p in @($report.archive,$report.manifest)){$publishedHandles.Add([IO.File]::Open($p,'Open','Read','Read'))}
      if(-not (Test-RetentionZip $report.archive $files)){throw 'published-archive-verification-failed'}
      & $Dependencies.Phase 'after-verify' $Root
      $batchRemaining=0
      foreach($item in $items | Where-Object action -eq 'archive') {
        if($batchRemaining -eq 0) {
            $snapshot=& $Dependencies.ProtectionSnapshot $Root
            # The reference authority is run-scoped; no script/skill reads here.
            $protection=New-RetentionProtectionSets $context $snapshot $referenceMatches
            $batchRemaining=128
        }
        $batchRemaining--
        $fresh=Get-RetentionSnapshot $runtime $item.path -MetadataOnly
        if(-not (Test-RetentionUnchanged $item.snapshot $fresh)){$item.action='retain';$item.reason='changed-during-apply';continue}
        $current=@{path=$item.path;snapshot=$fresh}
        $reason=Get-RetentionReason $current $protection $authority $harvest $Now
        if($reason -ne 'eligible'){$item.action='retain';$item.reason=$reason;continue}
        & $Dependencies.Phase 'before-delete' $Root
        $reason=Remove-RetentionItem $item $runtime
        $item.reason=$reason;$item.action=if($reason -eq 'deleted'){'deleted'}else{'retain'}
        if($reason -eq 'deleted'){
            foreach($dir in @($item.snapshot.directories | Sort-Object Length -Descending)){
                try{[RuntimeRetention.Handle]::RemoveEmptyDirectory((Join-Path $runtime $dir))}catch{$item.action='retain';$item.reason='changed-during-apply'}
            }
        }
      }
    } catch {$report.error=$_.Exception.Message}
    finally{
        foreach($h in $publishedHandles){$h.Dispose()}
        for($i=$archiveGuards.Count-1;$i -ge 0;$i--){$archiveGuards[$i].Dispose()}
    }
    return [pscustomobject]$report
}

if(-not $Library) {
    $report=Invoke-RuntimeRetention -Root $Root -Apply:$Apply
    # Report contains metadata only, never raw archived file/link content.
    $report.items=@($report.items | ForEach-Object {[pscustomobject]@{path=$_.path;action=$_.action;reason=$_.reason;entries=$_.entries;oversized=$_.oversized}})
    $report | ConvertTo-Json -Depth 5
    if($report.error){exit 1}
}
