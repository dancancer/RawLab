# ---------------------------------------------------------------------------
# Fixture test for verify-licenses.ps1. The default release package must carry
# exactly the pinned SDK DLL; an offline package (build.ps1 -NoRumSdk) must not.
# -SdkZip is the vendor AlibabaCloud_RUM_Windows_0.4.4.zip (the shared-cache
# sdk.zip); the real DLL is needed because only its bytes match the pin.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SdkZip,
    [string]$RepositoryRoot = (Resolve-Path "$PSScriptRoot/../../..")
)
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('rawlab-license-test-' + [Guid]::NewGuid().ToString('N'))
$sdkDll = Join-Path ([IO.Path]::GetTempPath()) ('rawlab-license-sdk-' + [Guid]::NewGuid().ToString('N') + '.dll')
$check = Join-Path $PSScriptRoot 'verify-licenses.ps1'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $SdkZip).Path)
try {
    $entry = $archive.GetEntry('AlibabaCloud_RUM_Windows_0.4.4/bin/x86_64/Release/alibabacloud_rum.dll')
    if (!$entry) { throw 'The SDK archive has no x64 Release DLL.' }
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $sdkDll, $true)
} finally { $archive.Dispose() }
function Populate([bool]$withSdk = $true) {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    New-Item -ItemType Directory -Force "$fixture/Licenses" | Out-Null
    Copy-Item "$RepositoryRoot/LICENSE" "$fixture/LICENSE" -Force
    Copy-Item "$RepositoryRoot/LICENSE" "$fixture/Licenses/RawLab-GPL-3.0.txt" -Force
    Copy-Item "$RepositoryRoot/LICENSE-ALIYUN-RUM-EXCEPTION" "$fixture/Licenses/RawLab-Aliyun-RUM-Exception.txt" -Force
    Copy-Item "$RepositoryRoot/docs/reference/licensing.md" "$fixture/Licenses/RawLab-Licensing.md" -Force
    Copy-Item "$RepositoryRoot/RawLabWindows/ThirdPartyNotices.md" "$fixture/ThirdPartyNotices.md" -Force
    foreach ($name in 'RawLab.exe', 'sony2fuji.dll', 'raw.dll') {
        New-Item -ItemType File -Force (Join-Path $fixture $name) | Out-Null
    }
    if ($withSdk) { Copy-Item -LiteralPath $sdkDll "$fixture/alibabacloud_rum.dll" -Force }
}
function Accept([string]$mode = 'default') {
    & $check -Package $fixture -RepositoryRoot $RepositoryRoot -Mode $mode | Out-Null
}
function Reject([string]$expected, [string]$mode = 'default') {
    try { & $check -Package $fixture -RepositoryRoot $RepositoryRoot -Mode $mode }
    catch {
        if (!$_.Exception.Message.Contains($expected)) { throw }
        return
    }
    throw "Invalid package fixture was accepted ($mode, expected: $expected)."
}
try {
    Populate; Accept
    Remove-Item -LiteralPath "$fixture/Licenses/RawLab-Aliyun-RUM-Exception.txt"
    Reject 'Missing packaged notice'
    Populate; Copy-Item "$RepositoryRoot/LICENSE" "$fixture/Licenses/RawLab-Aliyun-RUM-Exception.txt" -Force
    Reject 'Stale packaged notice'
    Populate; Copy-Item "$RepositoryRoot/LICENSE" "$fixture/Licenses/RawLab-Licensing.md" -Force
    Reject 'Stale packaged notice'
    Populate; Set-Content -LiteralPath "$fixture/ThirdPartyNotices.md" -Value 'stale'
    Reject 'Stale packaged notice'
    Populate $false
    Reject 'Default package must contain exactly one app-local RUM SDK DLL'
    Accept 'offline'
    Populate; Set-Content -LiteralPath "$fixture/alibabacloud_rum.dll" -Value 'not the vendor build'
    Reject 'Unexpected Windows RUM'
    Populate; New-Item -ItemType Directory "$fixture/nested" | Out-Null
    Copy-Item -LiteralPath $sdkDll "$fixture/nested/alibabacloud_rum.dll"
    Reject 'Default package must contain exactly one app-local RUM SDK DLL'
    Populate
    Reject 'Offline package must not contain' 'offline'
    Write-Output 'PASS: license fixtures require current notices, the pinned SDK in default packages and no SDK offline'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    if (Test-Path -LiteralPath $sdkDll) { Remove-Item -LiteralPath $sdkDll -Force }
}
