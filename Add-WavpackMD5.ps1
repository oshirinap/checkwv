#requires -Version 7
<#
.SYNOPSIS
  Add an internal MD5 checksum to WavPack files listed in NoMD5Files.txt, or
  repack old (e.g. WavPack 4) files listed in WavPackV4Files.txt with the current
  encoder (-Repack), keeping every timestamp (created / modified / accessed, and
  folder modified).

.DESCRIPTION
  For each path in the list file the script:
    1. skips files that already have an MD5 (unless -Repack, which instead skips
       files that are already WavPack 5 or newer), hybrid/lossy files, files
       with a .wvc, and DSD files (unless -IncludeDSD);
    2. re-encodes the file losslessly with "wavpack -m" into a temporary file,
       using the same compression level as the original;
    3. verifies the new file: wvunpack -vv passes, it now stores an MD5, that
       MD5 equals the MD5 of the original's decoded audio, channels/duration/
       source format are unchanged, and all APE tag items (including artwork
       and cuesheets) are identical;
    4. only then swaps it in (File.Replace), keeps the old file as "<name>.wv.bak"
       (unless -DeleteBackups), and copies the original timestamps onto it.
  Any failed check leaves the original untouched.

.EXAMPLE
  # 1. see what would happen, without touching anything
  .\Add-WavpackMD5.ps1 D:\music\NoMD5Files.txt -DryRun -Limit 20

.EXAMPLE
  # 2. really process just the first file
  .\Add-WavpackMD5.ps1 D:\music\NoMD5Files.txt -Limit 1

.EXAMPLE
  # upgrade the old WavPack 4 files that checkwv -v4 listed
  .\Add-WavpackMD5.ps1 D:\music\WavPackV4Files.txt -Repack -Limit 1

.EXAMPLE
  # 3. everything, 3 at a time
  .\Add-WavpackMD5.ps1 D:\music\NoMD5Files.txt -Parallel 3

.NOTES
  wavpack.exe and wvunpack.exe (5.x) are looked for next to this script, then in
  PATH, or give them with -Wavpack / -Wvunpack. A log is written to
  <list file>.log.csv. When you are happy with the results, delete the backups:
    Get-ChildItem D:\music -Recurse -Filter *.wv.bak | Remove-Item
  Retries: occasionally (roughly 1 file in 1000) wavpack cannot write its output
  file, or the final file swap hits a file that is briefly locked (antivirus,
  indexer, a player...). Such errors are retried up to -Attempts times per file
  (waiting -RetryDelay, 2x, 3x ... seconds), and files that still fail are
  tried again in up to -RetryPasses extra passes after everything else is done.
  Verification failures (audio MD5 mismatch, tag differences, a corrupt
  original) are never retried.

  Media players that monitor your library folder (foobar2000, for example) pick
  up the temporary *.wv file the moment wavpack creates it and can lock it while
  scanning. By default the temporary files therefore go to a subfolder named
  Add-WavpackMD5 inside the Windows temp folder (taken from the TMP / TEMP
  environment variables), which is outside the monitored music folders. Use
  -TempDir to choose another place (a RAM disk such as R:\Temp is fine). The finished,
  verified file is then copied next to the original under a non-audio name
  (*.md5copy, checked by SHA-256 against the temporary file) and swapped in, so
  the player never sees a half-written *.wv file. If -TempDir is on the same
  drive as the music, no extra copy is needed.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$ListFile,
    [int]$Parallel = 2,
    [int]$Limit = 0,
    [switch]$DryRun,
    [switch]$IncludeDSD,
    [switch]$Repack,
    [switch]$DeleteBackups,
    [switch]$NoCompare,
    [int]$Attempts = 3,        # tries per file for the encode and file-swap steps
    [int]$RetryDelay = 5,      # seconds; doubles/triples between attempts
    [int]$RetryPasses = 1,     # extra passes over temporarily-failed files at the end
    [string]$TempDir,          # folder for temporary files (default: <Windows temp>\Add-WavpackMD5, from TMP/TEMP; any drive)
    [string[]]$ExtraArgs = @(),
    # Default locations; override with -Wavpack / -Wvunpack. If a default does not
    # exist, the script falls back to the script's folder, then PATH.
    [string]$Wavpack  = 'C:\Program Files\foobar2000\wavpack\wavpack.exe',
    [string]$Wvunpack = 'C:\Program Files\foobar2000\wavpack\wvunpack.exe'
)

$ErrorActionPreference = 'Stop'

function Resolve-Tool([string]$explicit, [string]$name) {
    if ($explicit -and (Test-Path -LiteralPath $explicit)) { return (Resolve-Path -LiteralPath $explicit).Path }
    if ($PSScriptRoot) {
        $local = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $local) { return $local }
    }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "Cannot find $name (put it next to this script, in PATH, or use -Wavpack / -Wvunpack)."
}

# The per-file work lives in a string so it can be re-created inside each
# parallel runspace.
$workText = @'
param([string]$src, [hashtable]$o)
$ErrorActionPreference = 'Stop'

function Result($status, $reason, [bool]$retry = $false) {
    [pscustomobject]@{ Path = $src; Status = $status; Reason = $reason; Retryable = $retry }
}

function Run($exe, [string[]]$a) {
    $out = & $exe @a 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

# Reads the APE tag at the end of a file (optionally followed by an ID3v1 tag)
# and returns @{ lowercased-key = base64-of-value }.
function Get-ApeTags([string]$path) {
    $tags = @{}
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $len = $fs.Length
        $footerPos = -1
        foreach ($back in 32, 160) {
            if ($len -lt $back) { continue }
            $buf = New-Object byte[] 8
            $fs.Position = $len - $back
            [void]$fs.Read($buf, 0, 8)
            if ([Text.Encoding]::ASCII.GetString($buf) -eq 'APETAGEX') { $footerPos = $len - $back; break }
        }
        if ($footerPos -lt 0) { return $tags }

        $f = New-Object byte[] 32
        $fs.Position = $footerPos
        [void]$fs.Read($f, 0, 32)
        $size  = [int64][BitConverter]::ToUInt32($f, 12)   # items + footer
        $count = [int64][BitConverter]::ToUInt32($f, 16)
        if ($size -lt 32 -or $size -gt ($footerPos + 32)) { throw 'unreadable APE tag size' }

        $itemsLen = [int]($size - 32)
        $data = New-Object byte[] $itemsLen
        $fs.Position = $footerPos + 32 - $size
        $read = 0
        while ($read -lt $itemsLen) {
            $n = $fs.Read($data, $read, $itemsLen - $read)
            if ($n -le 0) { throw 'short read in APE tag' }
            $read += $n
        }

        $p = 0
        for ($i = 0; $i -lt $count; $i++) {
            $vlen = [int][BitConverter]::ToUInt32($data, $p)
            $p += 8                                         # value length + item flags
            $z = [Array]::IndexOf($data, [byte]0, $p)
            if ($z -lt 0) { throw 'bad APE item' }
            $key = [Text.Encoding]::UTF8.GetString($data, $p, $z - $p).ToLowerInvariant()
            $p = $z + 1
            # items with an empty value carry no information, and wavpack does not
            # write them when it rewrites a file, so they are not compared
            if ($vlen -gt 0) { $tags[$key] = [Convert]::ToBase64String($data, $p, $vlen) }
            $p += $vlen
        }
    }
    finally { $fs.Dispose() }
    return $tags
}

# Human-readable summary of how two tag sets differ (for the failure message).
function Describe-TagDiff($a, $b) {
    $parts = @("original has $($a.Count) item(s), new file has $($b.Count)")
    $missing = @($a.Keys | Where-Object { -not $b.ContainsKey($_) })
    $added   = @($b.Keys | Where-Object { -not $a.ContainsKey($_) })
    $changed = @($a.Keys | Where-Object { $b.ContainsKey($_) -and $a[$_] -ne $b[$_] })
    if ($missing.Count) { $parts += 'missing in new: ' + ($missing -join ', ') }
    if ($added.Count)   { $parts += 'only in new: ' + ($added -join ', ') }
    if ($changed.Count) { $parts += 'value differs: ' + ($changed -join ', ') }
    return ($parts -join '; ')
}

function Same-Tags($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($k in $a.Keys) {
        if (-not $b.ContainsKey($k) -or $a[$k] -ne $b[$k]) { return $false }
    }
    return $true
}

if (-not (Test-Path -LiteralPath $src)) { return Result 'Skipped' 'file not found' }
if (Test-Path -LiteralPath ($src + 'c'))  { return Result 'Skipped' 'has a .wvc file (hybrid)' }

$s = Run $o.Wvunpack @('-s', $src)
if ($s.Code -ne 0) { return Result 'Failed' 'wvunpack -s failed' $true }
$ver = 0
if ($s.Out -match '(?im)^encoder version:\s*(\d+)') { $ver = [int]$Matches[1] }
if ($o.Repack) {
    if ($ver -eq 0)  { return Result 'Skipped' 'could not read the encoder version' }
    if ($ver -ge 5)  { return Result 'Skipped' 'already WavPack 5 or newer' }
} elseif ($s.Out -match '(?im)^original md5:\s*[0-9a-f]{32}') {
    return Result 'Skipped' 'already has MD5'
}

$mod = ''
if ($s.Out -match '(?im)^modalities:\s*(.+)$') { $mod = $Matches[1] }
if ($mod -match 'hybrid|lossy') { return Result 'Skipped' 'hybrid/lossy file' }

$isDsd = $false
$srcLine = [regex]::Match($s.Out, '(?im)^source:.*$').Value
if ($srcLine -match '\bDSD\b') { $isDsd = $true }
elseif ($srcLine -match 'at (\d+) Hz' -and [int64]$Matches[1] -gt 1000000) { $isDsd = $true }
if ($isDsd -and -not $o.IncludeDSD) { return Result 'Skipped' 'DSD (use -IncludeDSD)' }

# same compression level as the original
$encArgs = @('-m', '-y', '-q')
if     ($mod -match 'very high') { $encArgs += '-hh' }
elseif ($mod -match '\bhigh\b')  { $encArgs += '-h' }
elseif ($mod -match '\bfast\b')  { $encArgs += '-f' }
if ($mod -match 'extra-?\s*(\d)?') {   # wvunpack prints e.g. "extra-1"
    if ($Matches[1]) { $encArgs += ('-x' + $Matches[1]) } else { $encArgs += '-x' }
}
$encArgs += $o.ExtraArgs

if ($o.DryRun) { return Result 'WouldRewrite' ('wavpack ' + ($encArgs -join ' ')) }

$tmp = $src + '.md5tmp.wv'
if ($o.TempDir) { $tmp = Join-Path $o.TempDir ([guid]::NewGuid().ToString('N') + '.wv') }
# File.Replace needs both files on the same drive. If the temporary file lives on
# another drive, it is first copied next to the original under a non-audio name.
$stage = $null
if ([IO.Path]::GetPathRoot($tmp) -ine [IO.Path]::GetPathRoot($src)) { $stage = $src + '.md5copy' }
$bak = $src + '.bak'
if (Test-Path -LiteralPath $bak) { return Result 'Skipped' 'backup file already exists' }

try {
    # MD5 of the original's decoded audio (independent check)
    $origMd5 = $null
    if (-not $o.NoCompare) {
        $u = Run $o.Wvunpack @('-v', '-m', $src)
        if ($u.Code -ne 0) { return Result 'Failed' 'original failed verification' }
        $all = [regex]::Matches($u.Out, '(?im)md5[^0-9a-f\r\n]*([0-9a-f]{32})')
        if ($all.Count -eq 0) {
            return Result 'Failed' 'could not read the audio MD5 from "wvunpack -v -m" (use -NoCompare to skip this check)'
        }
        $origMd5 = $all[$all.Count - 1].Groups[1].Value.ToLower()
    }

    # wavpack reads the .wv source itself (no pipe from wvunpack is involved).
    # If it cannot write its output (a temporary lock), wait and try again.
    $encoded  = $false
    $lastOut  = ''
    $encTries = 0
    while ($encTries -lt $o.Attempts -and -not $encoded) {
        $encTries++
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        $e = Run $o.Wavpack ($encArgs + @($src, '-o', $tmp))
        if ($e.Code -eq 0 -and (Test-Path -LiteralPath $tmp)) {
            $encoded = $true
        } else {
            $lastOut = $e.Out.Trim()
            if ($encTries -lt $o.Attempts) { Start-Sleep -Seconds ($o.RetryDelay * $encTries) }
        }
    }
    if (-not $encoded) {
        return Result 'Failed' ("wavpack failed after $encTries attempt(s): $lastOut") $true
    }

    $v = Run $o.Wvunpack @('-vv', $tmp)
    if ($v.Code -ne 0) { return Result 'Failed' 'new file failed verification' }

    $ns = Run $o.Wvunpack @('-s', $tmp)
    $mm = [regex]::Match($ns.Out, '(?im)^original md5:\s*([0-9a-f]{32})')
    if ($ns.Code -ne 0 -or -not $mm.Success) { return Result 'Failed' 'new file has no MD5' }
    if ($origMd5 -and $mm.Groups[1].Value.ToLower() -ne $origMd5) {
        return Result 'Failed' 'audio MD5 differs from the original'
    }

    foreach ($key in 'channels', 'duration', 'source') {
        $pat = '(?im)^' + $key + ':.*$'
        $x = [regex]::Match($s.Out,  $pat).Value.Trim()
        $y = [regex]::Match($ns.Out, $pat).Value.Trim()
        if ($x -ne $y) { return Result 'Failed' "$key differs after rewrite" }
    }

    $tagsOld = Get-ApeTags $src
    $tagsNew = Get-ApeTags $tmp
    if (-not (Same-Tags $tagsOld $tagsNew)) {
        return Result 'Failed' ('tags/artwork differ after rewrite (original untouched): ' + (Describe-TagDiff $tagsOld $tagsNew))
    }

    # swap in, then restore timestamps
    $item = Get-Item -LiteralPath $src -Force
    $ct = $item.CreationTimeUtc
    $wt = $item.LastWriteTimeUtc
    $at = $item.LastAccessTimeUtc
    $attr = $item.Attributes
    if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($src, [IO.FileAttributes]::Normal) }

    $swapFrom = $tmp
    if ($stage) {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Force }
        $copied  = $false
        $cpTries = 0
        $cpErr   = ''
        while ($cpTries -lt $o.Attempts -and -not $copied) {
            $cpTries++
            try {
                Copy-Item -LiteralPath $tmp -Destination $stage -Force
                $same = ((Get-Item -LiteralPath $stage).Length -eq (Get-Item -LiteralPath $tmp).Length) -and
                        ((Get-FileHash -LiteralPath $stage).Hash -eq (Get-FileHash -LiteralPath $tmp).Hash)
                if (-not $same) { throw 'the copy does not match the temporary file' }
                $copied = $true
            }
            catch {
                $cpErr = $_.Exception.Message
                Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
                if ($cpTries -lt $o.Attempts) { Start-Sleep -Seconds ($o.RetryDelay * $cpTries) }
            }
        }
        if (-not $copied) {
            return Result 'Failed' "could not copy the new file next to the original after $cpTries attempt(s): $cpErr" $true
        }
        $swapFrom = $stage
    }

    $replaced = $false
    $repTries = 0
    $repErr   = ''
    while ($repTries -lt $o.Attempts -and -not $replaced) {
        $repTries++
        try {
            [IO.File]::Replace($swapFrom, $src, $bak, $true)
            $replaced = $true
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            $repErr = $_.Exception.Message
            # make sure the original is still in place
            if (-not (Test-Path -LiteralPath $src) -and (Test-Path -LiteralPath $bak)) {
                Move-Item -LiteralPath $bak -Destination $src -Force
            }
            if ($repTries -lt $o.Attempts) { Start-Sleep -Seconds ($o.RetryDelay * $repTries) }
        }
    }
    if (-not $replaced) {
        if (Test-Path -LiteralPath $src) { [IO.File]::SetAttributes($src, $attr) }
        return Result 'Failed' "could not replace the file after $repTries attempt(s) (in use?): $repErr" $true
    }

    $stamped  = $false
    $stTries  = 0
    while ($stTries -lt $o.Attempts -and -not $stamped) {
        $stTries++
        try {
            [IO.File]::SetCreationTimeUtc($src, $ct)
            [IO.File]::SetLastWriteTimeUtc($src, $wt)
            [IO.File]::SetLastAccessTimeUtc($src, $at)
            [IO.File]::SetAttributes($src, $attr)
            $stamped = $true
        }
        catch [System.IO.IOException], [System.UnauthorizedAccessException] {
            if ($stTries -lt $o.Attempts) { Start-Sleep -Seconds ($o.RetryDelay * $stTries) }
        }
    }
    if (-not $stamped) {
        # not retryable: the file is already replaced
        return Result 'Failed' ('file was replaced but its timestamps could not be restored (original kept as .bak); original times: created {0:o}, modified {1:o}' -f $ct, $wt)
    }

    if ($o.DeleteBackups) { Remove-Item -LiteralPath $bak -Force }
    $note = ''
    if ($encTries -gt 1 -or $repTries -gt 1) { $note = "needed retries (encode: $encTries, swap: $repTries)" }
    return Result 'Done' $note
}
catch {
    return Result 'Failed' $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    if ($stage -and (Test-Path -LiteralPath $stage)) { Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue }
}
'@

# ---------------------------------------------------------------- main ----
$defaultTemp = -not $PSBoundParameters.ContainsKey('TempDir')
if ($defaultTemp) { $TempDir = Join-Path ([IO.Path]::GetTempPath()) 'Add-WavpackMD5' }
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $TempDir | Out-Null }
Write-Host "temp    : $TempDir"
$wavpackExe  = Resolve-Tool $Wavpack  'wavpack.exe'
$wvunpackExe = Resolve-Tool $Wvunpack 'wvunpack.exe'
Write-Host "wavpack : $wavpackExe"
Write-Host "wvunpack: $wvunpackExe"

$files = @(Get-Content -LiteralPath $ListFile -Encoding utf8 |
    ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } |
    Where-Object { $_ })
if ($Limit -gt 0) { $files = @($files | Select-Object -First $Limit) }
if ($files.Count -eq 0) { Write-Host 'Nothing to do.'; return }
Write-Host ("{0} file(s) to look at{1}" -f $files.Count, $(if ($DryRun) { ' (dry run)' } else { '' }))

# remember folder modified times (they change when files are replaced)
$dirTimes = @{}
if (-not $DryRun) {
    foreach ($d in ($files | ForEach-Object { [IO.Path]::GetDirectoryName($_) } | Sort-Object -Unique)) {
        if ($d -and (Test-Path -LiteralPath $d)) {
            $dirTimes[$d] = (Get-Item -LiteralPath $d -Force).LastWriteTimeUtc
        }
    }
}

$opts = @{
    Wavpack       = $wavpackExe
    Wvunpack      = $wvunpackExe
    IncludeDSD    = [bool]$IncludeDSD
    Repack        = [bool]$Repack
    DeleteBackups = [bool]$DeleteBackups
    NoCompare     = [bool]$NoCompare
    DryRun        = [bool]$DryRun
    ExtraArgs     = $ExtraArgs
    Attempts      = [Math]::Max(1, $Attempts)
    TempDir       = $TempDir
    RetryDelay    = [Math]::Max(0, $RetryDelay)
}
$start   = Get-Date

function Invoke-Batch([string[]]$list) {
    $total = $list.Count
    $state = [hashtable]::Synchronized(@{ n = 0 })   # shared progress counter
    $list | ForEach-Object -Parallel {
        $sb = [scriptblock]::Create($using:workText)
        $r  = @(& $sb $_ $using:opts) | Select-Object -Last 1
        $st = $using:state
        [System.Threading.Monitor]::Enter($st.SyncRoot)
        try { $st.n = $st.n + 1; $n = $st.n } finally { [System.Threading.Monitor]::Exit($st.SyncRoot) }
        $color = switch ($r.Status) {
            'Done'         { 'Green' }
            'WouldRewrite' { 'Cyan' }
            'Skipped'      { 'DarkGray' }
            default        { 'Red' }
        }
        $line = '{0}/{1} [{2}] {3}' -f $n, $using:total, $r.Status, $r.Path
        if ($r.Reason) { $line += '  -- ' + $r.Reason }
        Write-Host $line -ForegroundColor $color
        $r
    } -ThrottleLimit ([Math]::Max(1, $Parallel))
}

$results = @(Invoke-Batch $files)

# Extra passes: files that failed with a possibly temporary error get another
# chance once the rest of the run is finished.
for ($pass = 1; $pass -le $RetryPasses; $pass++) {
    $again = @($results | Where-Object { $_.Status -eq 'Failed' -and $_.Retryable } | ForEach-Object { $_.Path })
    if ($again.Count -eq 0) { break }
    $wait = [Math]::Max(10, $RetryDelay * 6)
    Write-Host ''
    Write-Host ('Retry pass {0}: {1} file(s) failed with a possibly temporary error; waiting {2} s first...' -f $pass, $again.Count, $wait) -ForegroundColor Yellow
    Start-Sleep -Seconds $wait
    $second  = @(Invoke-Batch $again)
    $results = @($results | Where-Object { $again -notcontains $_.Path }) + $second
}

# tidy up the default temp subfolder if nothing is left in it
if ($defaultTemp -and -not $DryRun -and (Test-Path -LiteralPath $TempDir) -and
    -not (Get-ChildItem -LiteralPath $TempDir -Force)) {
    Remove-Item -LiteralPath $TempDir -Force -ErrorAction SilentlyContinue
}

# restore folder modified times
foreach ($d in $dirTimes.Keys) {
    if (Test-Path -LiteralPath $d) { [IO.Directory]::SetLastWriteTimeUtc($d, $dirTimes[$d]) }
}

$logPath = $ListFile + '.log.csv'
$results | Export-Csv -LiteralPath $logPath -NoTypeInformation -Encoding utf8BOM

Write-Host ''
Write-Host ('Finished in {0:hh\:mm\:ss}' -f ((Get-Date) - $start))
$results | Group-Object Status | Sort-Object Name | ForEach-Object {
    Write-Host ('  {0,-13} {1}' -f $_.Name, $_.Count)
}
Write-Host "Log: $logPath"
if (-not $DryRun -and -not $DeleteBackups -and ($results | Where-Object Status -eq 'Done')) {
    Write-Host 'Originals were kept as *.wv.bak. When satisfied, remove them with:'
    Write-Host '  Get-ChildItem <your music folder> -Recurse -Filter *.wv.bak | Remove-Item'
}
