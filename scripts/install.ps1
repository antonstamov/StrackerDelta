<#
.SYNOPSIS
    Installs the Stracker Delta application into an Assetto Corsa folder.

.DESCRIPTION
    Copies the files the game needs from the root of the project into
    <Assetto Corsa>\apps\lua\StrackerDelta.

    Without an argument the script asks for the path and keeps the console open,
    so it can be started by a double click. With an argument it stays silent about
    that and simply exits with a code.

    The path is checked before anything is copied: a folder without apps\lua is
    almost surely not the game, and a half installed app is worse than none.

    Files that the app writes at runtime (debug.log, cache_lap.csv, cache_index.txt,
    last_lap.csv) live in the same folder and are never touched.

.EXAMPLE
    scripts\install.cmd
    scripts\install.cmd "<path to Assetto Corsa>"
    scripts\install.cmd "<path to Assetto Corsa>" -Backup
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Path,

    [switch] $Backup
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$mainScript = 'StrackerDelta.lua'

# the complete list of what the game reads. Anything outside of it is our business.
$installFiles = @(
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

function Complete {
    param([int] $Code, [bool] $Interactive)

    if ($Interactive) {
        Write-Host ''
        [void] (Read-Host 'Press Enter to close')
    }
    exit $Code
}

function Get-Sha256 {
    # straight .NET on purpose: Get-FileHash needs a module autoload, and a failed
    # autoload surfaces as "command not found" in the middle of an install
    param([string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        return [System.BitConverter]::ToString($sha.ComputeHash($bytes))
    } finally { $sha.Dispose() }
}

# ---------------------------------------------------------------- target folder

$interactive = [string]::IsNullOrWhiteSpace($Path)

if ($interactive) {
    Write-Host ''
    Write-Host 'Stracker Delta: install'
    Write-Host 'Enter the Assetto Corsa folder, the one that contains apps\lua.'
    Write-Host ''
    $Path = Read-Host 'Assetto Corsa folder'

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Write-Host ''
        Write-Host 'No path given, nothing installed.'
        Complete 1 $true
    }
}

# quotes survive a Read-Host paste and can come with an argument of a shell wrapper
$Path = $Path.Trim().Trim('"')

$luaDir = Join-Path $Path 'apps\lua'
$appDir = Join-Path $Path "apps\lua\$([System.IO.Path]::GetFileNameWithoutExtension($mainScript))"

Write-Host ''
Write-Host 'Stracker Delta: install'
Write-Host "  source: $projectRoot"
Write-Host "  target: $appDir"
Write-Host ''

if (-not (Test-Path -LiteralPath $luaDir -PathType Container)) {
    Write-Host "$luaDir does not exist." -ForegroundColor Red
    Write-Host 'That folder does not look like Assetto Corsa, nothing was copied.' -ForegroundColor Red
    Complete 1 $interactive
}

# check the source before creating anything in the game folder
foreach ($file in $installFiles) {
    $source = Join-Path $projectRoot $file
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        Write-Host "missing file: $source" -ForegroundColor Red
        Complete 1 $interactive
    }
}

if ($Backup -and (Test-Path -LiteralPath $appDir -PathType Container)) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $projectRoot "backups\$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -Path (Join-Path $appDir '*') -Destination $backupDir -Recurse -Force
    Write-Host "  backup: $backupDir"
    Write-Host ''
}

# ---------------------------------------------------------------- copy

$created = 0
$updated = 0
$manifestChanged = $false

foreach ($file in $installFiles) {
    $source = Join-Path $projectRoot $file
    $destination = Join-Path $appDir $file

    # modules/ has to exist before the first file lands in it
    $destinationFolder = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $destinationFolder | Out-Null
    }

    $sourceHash = Get-Sha256 $source

    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $destinationHash = Get-Sha256 $destination
        if ($sourceHash -eq $destinationHash) {
            Write-Host ('  unchanged  {0}' -f $file)
            continue
        }
        $state = 'updated'
        $updated++
    } else {
        $state = 'created'
        $created++
    }

    Copy-Item -LiteralPath $source -Destination $destination -Force
    if ($file -eq 'manifest.ini') { $manifestChanged = $true }
    Write-Host ('  {0,-10} {1}' -f $state, $file)
}

Write-Host ''
Write-Host "Installed into: $appDir" -ForegroundColor Green

if ($manifestChanged) {
    Write-Host ''
    Write-Host 'manifest.ini changed: restart Assetto Corsa, it reads window names and sizes only at start.'
}

Complete 0 $interactive
