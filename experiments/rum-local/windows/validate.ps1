# ---------------------------------------------------------------------------
# Windows live RUM validation with the production configuration (env=PROD).
# Run it from the folder made by `run.sh --publish`; the PC needs no .NET SDK.
# The probe sends five synthetic events tagged validation_run=<ValidationRun>,
# keeps consent and the install ID in a private temp folder, and never reads
# the user's RawLab settings. Ingestion is confirmed separately by readback.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][Guid]$ValidationRun,
    [string]$Probe = $PSScriptRoot
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

# The published folder must hold the self-contained probe and the pinned SDK DLL.
$exe = Join-Path $Probe 'WindowsRumLocalProbe.exe'
$dll = Join-Path $Probe 'alibabacloud_rum.dll'
if (!(Test-Path -LiteralPath $exe -PathType Leaf) -or !(Test-Path -LiteralPath $dll -PathType Leaf)) {
    throw "Incomplete probe folder $Probe; publish it with run.sh --publish."
}
if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne '33CEC949309F8025BE35FF19D7AE7F7BFC0F59A9FF0BEF3E05C40460F0BF6E8D') {
    throw 'Unexpected Windows RUM 0.4.4 DLL.'
}
# alibabacloud_rum.dll links the Visual C++ runtime; RawLab packages ship it app-locally.
foreach ($runtime in 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll') {
    if (!(Test-Path -LiteralPath (Join-Path $Probe $runtime)) -and
        !(Test-Path -LiteralPath (Join-Path "$env:SystemRoot\System32" $runtime))) {
        throw "Visual C++ runtime $runtime is missing; copy msvcp140.dll, vcruntime140.dll and vcruntime140_1.dll from a RawLab Windows package into $Probe."
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('rawlab-rum-validate-' + [Guid]::NewGuid().ToString('N'))
$processTemp = Join-Path $work 'sdk-process'
New-Item -ItemType Directory $processTemp | Out-Null
$previous = @{ TEMP = $env:TEMP; TMP = $env:TMP; Run = $env:RAWLAB_RUM_VALIDATION_RUN }
$passed = $false
try {
    # The SDK cache and the probe's private consent/install-ID folder both live here.
    $env:TEMP = $processTemp
    $env:TMP = $processTemp
    $env:RAWLAB_RUM_VALIDATION_RUN = $ValidationRun.ToString()
    $process = Start-Process -FilePath $exe -PassThru -NoNewWindow -WorkingDirectory $Probe `
        -RedirectStandardOutput "$work/probe-stdout.log" -RedirectStandardError "$work/probe-stderr.log"
    # Windows PowerShell 5 needs a retained handle for a reliable ExitCode.
    $null = $process.Handle
    if (-not $process.WaitForExit(60000)) {
        Stop-Process -Id $process.Id -Force
        $process.WaitForExit()
        throw "Probe timed out; no ingestion claim. Local logs: $work"
    }
    $process.Refresh()
    Get-Content "$work/probe-stdout.log" | Where-Object { $_ -match '^(SUBMITTED|validation_run[=:])' }
    if ($null -eq $process.ExitCode -or $process.ExitCode -ne 0) {
        throw "Probe failed; inspect the local logs in $work without sharing raw SDK output."
    }
    if (@(Get-ChildItem -LiteralPath $processTemp -Force).Count -ne 0) { throw "SDK cache cleanup was not confirmed: $processTemp" }
    $passed = $true
    Write-Output 'PASS: SDK process exited; its cache and the private consent/install-ID folder are gone.'
    Write-Output "Cloud API readback required for validation_run=$ValidationRun (platform windows, env PROD)."
} finally {
    $env:TEMP = $previous.TEMP
    $env:TMP = $previous.TMP
    $env:RAWLAB_RUM_VALIDATION_RUN = $previous.Run
    if ($passed) { Remove-Item -LiteralPath $work -Recurse -Force }
}
