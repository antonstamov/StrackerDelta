<#
.SYNOPSIS
    Packs the Stracker Delta application into a Content Manager ready zip.

.DESCRIPTION
    Takes the files Assetto Corsa needs from the root of the project and
    writes them into an archive with the paths relative to the game folder:

        apps/lua/StrackerDelta/manifest.ini
        apps/lua/StrackerDelta/StrackerDelta.lua
        apps/lua/StrackerDelta/modules/web.lua
        ...

    The entry names use forward slashes on purpose. Content Manager unpacks the
    archive as it is, so a backslash inside an entry name would make it drop the
    folder in the wrong place. That is also why Compress-Archive is not used here.

    Nothing else is taken: no logs, no caches, no tests.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pack.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $projectRoot 'manifest.ini'
$distDir = Join-Path $projectRoot 'dist'

# the name of the main script gives the folder name inside the game:
# StrackerDelta.lua -> apps/lua/StrackerDelta
$mainScript = 'StrackerDelta.lua'

# the complete list of what the game reads. Anything outside of it is our business.
$packFiles = @(
    'manifest.ini',
    $mainScript,
    'README.md',
    'LICENSE',
    'modules/web.lua',
    'modules/stracker.lua',
    'modules/html.lua',
    'modules/lap.lua',
    'modules/addresses.lua'
)

function Read-Manifest {
    # the windows carry their own NAME, so only the [ABOUT] one is the app name
    param([string]$Path)
    $sections = @{}
    $current = ''
    foreach ($line in Get-Content -LiteralPath $Path) {
        $text = $line.Trim()
        if ($text -match '^\[(.+)\]$') {
            $current = $Matches[1].ToUpper()
            continue
        }
        if ($text -match '^([A-Za-z_]+)\s*=\s*(.*)$') {
            if (-not $sections.ContainsKey($current)) { $sections[$current] = @{} }
            $sections[$current][$Matches[1].ToUpper()] = $Matches[2].Trim()
        }
    }
    return $sections
}

Write-Host 'Stracker Delta: packing'
Write-Host ''

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Host "manifest.ini not found in $projectRoot" -ForegroundColor Red
    exit 1
}

$manifest = Read-Manifest $manifestPath
$about = $manifest['ABOUT']
if (-not $about -or -not $about.NAME) { Write-Host 'NAME is missing in manifest.ini' -ForegroundColor Red; exit 1 }
if (-not $about.VERSION) { Write-Host 'VERSION is missing in manifest.ini' -ForegroundColor Red; exit 1 }

if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $mainScript) -PathType Leaf)) {
    Write-Host "$mainScript not found in $projectRoot" -ForegroundColor Red
    Write-Host 'The app folder name and the main script name have to match in the game.' -ForegroundColor Red
    exit 1
}
$appFolder = [System.IO.Path]::GetFileNameWithoutExtension($mainScript)

# check every file before writing anything, so a broken project cannot produce a broken package
foreach ($file in $packFiles) {
    $source = Join-Path $projectRoot $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-Host "missing file: $file" -ForegroundColor Red
        exit 1
    }
}

# a module that is not in the list would be missing from the package and take the app
# down in the game with a require error, so the list has to cover every file there is
$onDisk = Get-ChildItem (Join-Path $projectRoot 'modules') -Filter '*.lua' -File |
          ForEach-Object { 'modules/' + $_.Name }
$notListed = $onDisk | Where-Object { $packFiles -notcontains $_ }
if ($notListed) {
    Write-Host ("modules missing from the list: " + ($notListed -join ', ')) -ForegroundColor Red
    exit 1
}

$zipName = "$($about.NAME) v$($about.VERSION).zip"
$zipPath = Join-Path $distDir $zipName

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::Create)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $packFiles) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $projectRoot $file))
            $entry = $archive.CreateEntry("apps/lua/$appFolder/$file", [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try { $entryStream.Write($bytes, 0, $bytes.Length) } finally { $entryStream.Dispose() }
            Write-Host ('  {0,-22} {1,8} bytes' -f $file, $bytes.Length)
        }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }

Write-Host ''
Write-Host "Package: $zipPath"
