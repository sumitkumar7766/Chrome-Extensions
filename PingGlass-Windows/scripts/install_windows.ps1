param(
    [Parameter(Mandatory = $false)]
    [string]$ExtensionId = ""
)

$ErrorActionPreference = "Stop"
$RootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

Write-Host "=== PingGlass Windows Installer ===" -ForegroundColor Cyan
& (Join-Path $RootDir "scripts\build_windows.ps1") -Install

if (-not [string]::IsNullOrWhiteSpace($ExtensionId)) {
    & (Join-Path $RootDir "WindowsNativeHost\install_native_host.ps1") -ExtensionId $ExtensionId
} else {
    Write-Host ""
    Write-Host "Next steps to connect the Chrome Extension:" -ForegroundColor Yellow
    Write-Host "  1. Open chrome://extensions in Google Chrome (or edge://extensions)"
    Write-Host "  2. Enable 'Developer mode' (top-right toggle)"
    Write-Host "  3. Click 'Load unpacked' and select: $RootDir\chrome-extension"
    Write-Host "  4. Copy the 32-character Extension ID from the PingGlass card"
    Write-Host "  5. Run: .\WindowsNativeHost\install_native_host.ps1 <YOUR_32_CHAR_EXTENSION_ID>"
}

$ExePath = Join-Path $env:LOCALAPPDATA "PingGlass\App\PingGlassWindows.exe"
Write-Host ""
Write-Host "Launch app: $ExePath" -ForegroundColor Green
