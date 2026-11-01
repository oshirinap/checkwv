#requires -Version 7
<#
.SYNOPSIS
  Add an internal MD5 checksum to WavPack files listed in NoMD5Files.txt,
  keeping every timestamp (created / modified / accessed, and folder modified).

.DESCRIPTION
  For each path in the list file the script:
    1. skips files that already have an MD5, hybrid/lossy files, files with a
       .wvc, and DSD files (unless -IncludeDSD);
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
  # 3. everything, 3 at a time
  .\Add-WavpackMD5.ps1 D:\music\NoMD5Files.txt -Parallel 3

.NOTES
  wavpack.exe and wvunpack.exe (5.x) are looked for next to this script, then in
  PATH, or give them with -Wavpack / -Wvunpack. A log is written to
  <list file>.log.csv. When you are happy with the results, delete the backups:
    Get-ChildItem D:\music -Recurse -Filter *.wv.bak | Remove-Item
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][string]$ListFile,
    [int]$Parallel = 2,
    [int]$Limit = 0,
    [switch]$DryRun,
    [switch]$IncludeDSD,
    [switch]$DeleteBackups,
    [switch]$NoCompare,
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

function Result($status, $reason) {
    [pscustomobject]@{ Path = $src; Status = $status; Reason = $reason }
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
            $tags[$key] = [Convert]::ToBase64String($data, $p, $vlen)
            $p += $vlen
        }
    }
    finally { $fs.Dispose() }
    return $tags
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
if ($s.Code -ne 0) { return Result 'Failed' 'wvunpack -s failed' }
if ($s.Out -match '(?im)^original md5:\s*[0-9a-f]{32}') { return Result 'Skipped' 'already has MD5' }

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
if ($mod -match 'extra\s*(\d)?') {
    if ($Matches[1]) { $encArgs += ('-x' + $Matches[1]) } else { $encArgs += '-x' }
}
$encArgs += $o.ExtraArgs

if ($o.DryRun) { return Result 'WouldRewrite' ('wavpack ' + ($encArgs -join ' ')) }

$tmp = $src + '.md5tmp.wv'
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

    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
    $e = Run $o.Wavpack ($encArgs + @($src, '-o', $tmp))
    if ($e.Code -ne 0 -or -not (Test-Path -LiteralPath $tmp)) {
        return Result 'Failed' ('wavpack failed: ' + $e.Out.Trim())
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

    if (-not (Same-Tags (Get-ApeTags $src) (Get-ApeTags $tmp))) {
        return Result 'Failed' 'tags/artwork differ after rewrite (original untouched)'
    }

    # swap in, then restore timestamps
    $item = Get-Item -LiteralPath $src -Force
    $ct = $item.CreationTimeUtc
    $wt = $item.LastWriteTimeUtc
    $at = $item.LastAccessTimeUtc
    $attr = $item.Attributes
    if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($src, [IO.FileAttributes]::Normal) }

    [IO.File]::Replace($tmp, $src, $bak, $true)

    [IO.File]::SetCreationTimeUtc($src, $ct)
    [IO.File]::SetLastWriteTimeUtc($src, $wt)
    [IO.File]::SetLastAccessTimeUtc($src, $at)
    [IO.File]::SetAttributes($src, $attr)

    if ($o.DeleteBackups) { Remove-Item -LiteralPath $bak -Force }
    return Result 'Done' ''
}
catch {
    return Result 'Failed' $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
'@

# ---------------------------------------------------------------- main ----
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
    DeleteBackups = [bool]$DeleteBackups
    NoCompare     = [bool]$NoCompare
    DryRun        = [bool]$DryRun
    ExtraArgs     = $ExtraArgs
}
$total   = $files.Count
$counter = [int[]]::new(1)
$start   = Get-Date

$results = $files | ForEach-Object -Parallel {
    $sb = [scriptblock]::Create($using:workText)
    $r  = @(& $sb $_ $using:opts) | Select-Object -Last 1
    $c  = $using:counter
    $n  = [System.Threading.Interlocked]::Increment([ref]$c[0])
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
