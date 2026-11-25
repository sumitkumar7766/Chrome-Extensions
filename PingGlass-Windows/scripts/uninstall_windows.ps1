$ErrorActionPreference = "Continue"

Write-Host "Stopping PingGlassWindows..." -ForegroundColor Cyan
Get-Process -Name "PingGlassWindows" -ErrorAction SilentlyContinue | Stop-Process -Force

$RegKeys = @(
    "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.pingglass.bridge",
    "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.pingglass.bridge",
    "HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.pingglass.bridge"
)

foreach ($Key in $RegKeys) {
    Remove-Item -Path $Key -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "PingGlassWindows" -ErrorAction SilentlyContinue

$AppDataDir = Join-Path $env:LOCALAPPDATA "PingGlass"
if (Test-Path $AppDataDir) {
    Remove-Item -Path $AppDataDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "PingGlass Windows uninstalled cleanly." -ForegroundColor Green
