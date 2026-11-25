param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-p]{32}$')]
    [string]$ExtensionId
)

$ErrorActionPreference = "Stop"

$HostDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BatPath = (Join-Path $HostDir "pingglass_native_host.bat")
$AppDataHostDir = Join-Path $env:LOCALAPPDATA "PingGlass\NativeHost"
New-Item -ItemType Directory -Path $AppDataHostDir -Force | Out-Null

$ManifestOut = Join-Path $AppDataHostDir "com.pingglass.bridge.json"

$ManifestObj = @{
    name            = "com.pingglass.bridge"
    description     = "PingGlass Windows Local UI Automation Native Messaging Bridge"
    path            = $BatPath
    type            = "stdio"
    allowed_origins = @("chrome-extension://$ExtensionId/")
}

$ManifestObj | ConvertTo-Json -Depth 4 | Set-Content -Path $ManifestOut -Encoding UTF8

$RegPaths = @(
    "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.pingglass.bridge",
    "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.pingglass.bridge",
    "HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.pingglass.bridge"
)

foreach ($RegPath in $RegPaths) {
    New-Item -Path $RegPath -Force | Out-Null
    Set-ItemProperty -Path $RegPath -Name "(Default)" -Value $ManifestOut
}

Write-Host "Registered Chrome/Edge/Brave Native Messaging Host:" -ForegroundColor Green
Write-Host "  Manifest: $ManifestOut"
Write-Host "  Bat Host: $BatPath"
Write-Host "  Extension ID: $ExtensionId"
