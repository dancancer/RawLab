param(
    [Parameter(Mandatory=$true)][string]$AppId,
    [Parameter(Mandatory=$true)][string]$ConfigAddress,
    [Parameter(Mandatory=$true)][Guid]$ValidationRun
)
$ErrorActionPreference = 'Stop'
if ($env:RAWLAB_RUM_LIMIT_VERIFIED -ne '1' -or $env:RAWLAB_RUM_NETWORK -ne 'china-telecom') {
    throw 'Operator-confirmed daily cap and direct network are required.'
}
foreach ($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')) {
    if ([Environment]::GetEnvironmentVariable($name)) { throw 'Proxy environment detected.' }
}
$settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
if ($settings.ProxyEnable -eq 1 -or $settings.AutoConfigURL) { throw 'System proxy detected.' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public struct RawLabRumProxyInfo { public uint AccessType; public IntPtr Proxy; public IntPtr Bypass; }
public static class RawLabRumProxyCheck {
    [DllImport("winhttp.dll", SetLastError=true)]
    public static extern bool WinHttpGetDefaultProxyConfiguration(out RawLabRumProxyInfo info);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalFree(IntPtr memory);
}
'@
$proxy = New-Object RawLabRumProxyInfo
if (-not [RawLabRumProxyCheck]::WinHttpGetDefaultProxyConfiguration([ref]$proxy)) {
    throw 'Could not query WinHTTP proxy configuration.'
}
try {
    if ($proxy.AccessType -ne 1) { throw 'WinHTTP direct route not confirmed.' }
} finally {
    if ($proxy.Proxy -ne [IntPtr]::Zero) { [RawLabRumProxyCheck]::GlobalFree($proxy.Proxy) | Out-Null }
    if ($proxy.Bypass -ne [IntPtr]::Zero) { [RawLabRumProxyCheck]::GlobalFree($proxy.Bypass) | Out-Null }
}
$root = (Resolve-Path "$PSScriptRoot/../../..").Path
$cache = Join-Path $root 'probe-temp'
if (Test-Path $cache) { throw 'Refusing to reuse a probe temp directory.' }
New-Item -ItemType Directory $cache | Out-Null
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
try {
    $env:TEMP = $cache
    $env:TMP = $cache
    $env:RAWLAB_RUM_APP_ID = $AppId
    $env:RAWLAB_RUM_CONFIG_ADDRESS = $ConfigAddress
    $env:RAWLAB_RUM_VALIDATION_RUN = $ValidationRun.ToString()
    $project = Join-Path $PSScriptRoot 'WindowsRumLocalProbe.csproj'
    $sdk = Join-Path $root 'sdk/AlibabaCloud_RUM_Windows_0.4.4'
    $output = Join-Path $root 'probe-output'
    dotnet build $project -c Debug "-p:RawLabRumSdkRoot=$sdk" -o $output --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Probe compilation failed.' }
    $processCache = Join-Path $cache 'sdk-process'
    New-Item -ItemType Directory $processCache | Out-Null
    $env:TEMP = $processCache
    $env:TMP = $processCache
    $process = Start-Process -FilePath 'dotnet' -ArgumentList @("$output/WindowsRumLocalProbe.dll") `
        -PassThru -NoNewWindow -RedirectStandardOutput "$root/probe-stdout.log" -RedirectStandardError "$root/probe-stderr.log"
    # Windows PowerShell 5 needs a retained handle for a reliable ExitCode.
    $null = $process.Handle
    if (-not $process.WaitForExit(60000)) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
        throw 'Probe timed out; no ingestion claim.'
    }
    $process.Refresh()
    if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) { throw 'Probe failed; inspect local logs without sharing raw SDK output.' }
    if (@(Get-ChildItem $processCache -Force).Count -ne 0) { throw 'SDK cache cleanup was not confirmed.' }
    Get-Content "$root/probe-stdout.log" | Where-Object { $_ -match '^(SUBMITTED|validation_run[=:])' }
    Write-Output 'PASS: SDK process exited and its private cache is empty.'
    Write-Output 'SDK process exited; cloud API readback required.'
} finally {
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
    Remove-Item $cache -Recurse -Force
}
