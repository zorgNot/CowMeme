# Watches the addon directory and copies changed files to your WoW AddOns folder.
# Usage: .\watch.ps1 [-WowPath "C:\path\to\AddOns"]

param(
    [string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_anniversary_\Interface\AddOns\CowMeme"
)

$source = $PSScriptRoot
$extensions = @("*.lua", "*.toc", "*.xml", "*.tga", "*.blp", "*.ogg")

if (-not (Test-Path $WowPath)) {
    Write-Host "Destination not found: $WowPath" -ForegroundColor Yellow
    Write-Host "Creating it..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $WowPath | Out-Null
}

function Copy-Changed {
    param([string]$FilePath)
    $relative = $FilePath.Substring($source.Length).TrimStart('\','/')
    $dest = Join-Path $WowPath $relative
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Copy-Item -Force $FilePath $dest
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Copied: $relative" -ForegroundColor Cyan
}

# Initial sync
Write-Host "Syncing to $WowPath ..." -ForegroundColor Green
foreach ($ext in $extensions) {
    Get-ChildItem -Path $source -Filter $ext -Recurse | ForEach-Object { Copy-Changed $_.FullName }
}
Write-Host "Watching for changes. Press Ctrl+C to stop.`n" -ForegroundColor Green

# Set up watcher
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $source
$watcher.IncludeSubdirectories = $true
$watcher.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::FileName

$action = {
    $path = $Event.SourceEventArgs.FullPath
    $ext = [System.IO.Path]::GetExtension($path)
    if ($ext -in @(".lua", ".toc", ".xml", ".tga", ".blp")) {
        Copy-Changed $path
    }
}

$handlers = @(
    Register-ObjectEvent $watcher Changed -Action $action
    Register-ObjectEvent $watcher Created -Action $action
    Register-ObjectEvent $watcher Renamed -Action $action
)

$watcher.EnableRaisingEvents = $true

try {
    while ($true) { Start-Sleep -Seconds 1 }
} finally {
    $watcher.EnableRaisingEvents = $false
    $handlers | ForEach-Object { Unregister-Event -SubscriptionId $_.Id }
    $watcher.Dispose()
    Write-Host "`nWatcher stopped." -ForegroundColor Yellow
}
