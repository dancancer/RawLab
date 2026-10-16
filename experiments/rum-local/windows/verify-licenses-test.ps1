[CmdletBinding()]
param([string]$RepositoryRoot = (Resolve-Path "$PSScriptRoot/../../.."))
$ErrorActionPreference = 'Stop'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('rawlab-license-test-' + [Guid]::NewGuid().ToString('N'))
$check = Join-Path $PSScriptRoot 'verify-licenses.ps1'
function Populate {
    New-Item -ItemType Directory -Force "$fixture/Licenses" | Out-Null
    Copy-Item "$RepositoryRoot/LICENSE" "$fixture/LICENSE" -Force
    Copy-Item "$RepositoryRoot/LICENSE" "$fixture/Licenses/RawLab-GPL-3.0.txt" -Force
    Copy-Item "$RepositoryRoot/LICENSE-ALIYUN-RUM-EXCEPTION" "$fixture/Licenses/RawLab-Aliyun-RUM-Exception.txt" -Force
    Copy-Item "$RepositoryRoot/docs/licensing.md" "$fixture/Licenses/RawLab-Licensing.md" -Force
    foreach ($name in 'RawLab.exe', 'sony2fuji.dll', 'raw.dll', 'ThirdPartyNotices.md') {
        New-Item -ItemType File -Force (Join-Path $fixture $name) | Out-Null
    }
}
function Reject([string]$expected, [string]$mode = 'default') {
    try { & $check -Package $fixture -RepositoryRoot $RepositoryRoot -Mode $mode }
    catch {
        if (!$_.Exception.Message.Contains($expected)) { throw }
        return
    }
    throw 'Invalid package fixture was accepted.'
}
try {
    Populate
    & $check -Package $fixture -RepositoryRoot $RepositoryRoot
    Remove-Item -LiteralPath "$fixture/Licenses/RawLab-Aliyun-RUM-Exception.txt"
    Reject 'Missing packaged notice'
    Populate
    Copy-Item "$RepositoryRoot/LICENSE" "$fixture/Licenses/RawLab-Aliyun-RUM-Exception.txt" -Force
    Reject 'Stale packaged notice'
    Populate
    Copy-Item "$RepositoryRoot/LICENSE" "$fixture/Licenses/RawLab-Licensing.md" -Force
    Reject 'Stale packaged notice'
    Populate
    New-Item -ItemType File "$fixture/alibabacloud_rum.dll" | Out-Null
    Reject 'Default package must not contain'
    Reject 'Unexpected Windows RUM' 'local'
    Write-Output 'PASS: license fixtures reject missing/stale notices, default SDK inclusion and wrong SDK bytes'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse }
}
