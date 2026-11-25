param(
    [switch]$Install
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$ProjPath = Join-Path $RootDir "WindowsApp\PingGlassWindows.csproj"
$BuildOut = Join-Path $RootDir "build"

Write-Host "=== Building PingGlass for Windows (.NET 8) ===" -ForegroundColor Cyan

dotnet publish $ProjPath `
    -c Release `
    -r win-x64 `
    --self-contained false `
    -o $BuildOut

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

Write-Host "Built PingGlassWindows.exe in: $BuildOut" -ForegroundColor Green

if ($Install) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "PingGlass\App"
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -Path (Join-Path $BuildOut "*") -Destination $InstallDir -Recurse -Force
    Write-Host "Installed to: $InstallDir\PingGlassWindows.exe" -ForegroundColor Green
}
