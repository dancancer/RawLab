# ---------------------------------------------------------------------------
# Check a built Windows package: packaged notices must match the source tree,
# and the RUM SDK must match the build mode. A default release package carries
# exactly one app-local alibabacloud_rum.dll with the pinned 0.4.4 hash; an
# offline package (build.ps1 -NoRumSdk) carries none.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [string]$RepositoryRoot = (Resolve-Path "$PSScriptRoot/../../.."),
    [ValidateSet('default', 'offline')][string]$Mode = 'default'
)
$ErrorActionPreference = 'Stop'
foreach ($pair in @(
    @('LICENSE', 'LICENSE'),
    @('LICENSE', 'Licenses/RawLab-GPL-3.0.txt'),
    @('LICENSE-ALIYUN-RUM-EXCEPTION', 'Licenses/RawLab-Aliyun-RUM-Exception.txt'),
    @('docs/reference/licensing.md', 'Licenses/RawLab-Licensing.md'),
    @('RawLabWindows/ThirdPartyNotices.md', 'ThirdPartyNotices.md')
)) {
    $source = Join-Path $RepositoryRoot $pair[0]
    $target = Join-Path $Package $pair[1]
    if (!(Test-Path -LiteralPath $target -PathType Leaf)) { throw "Missing packaged notice: $($pair[1])" }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
        throw "Stale packaged notice: $($pair[1])"
    }
}
foreach ($name in 'RawLab.exe', 'sony2fuji.dll', 'raw.dll') {
    if (!(Test-Path -LiteralPath (Join-Path $Package $name) -PathType Leaf)) { throw "Incomplete package: $name" }
}
$sdk = @(Get-ChildItem -LiteralPath $Package -Recurse -File -Filter 'alibabacloud_rum.dll')
if ($Mode -eq 'offline' -and $sdk.Count -ne 0) { throw 'Offline package must not contain the RUM SDK.' }
if ($Mode -eq 'default') {
    if ($sdk.Count -ne 1 -or $sdk[0].Directory.FullName -ne (Resolve-Path -LiteralPath $Package).Path) {
        throw 'Default package must contain exactly one app-local RUM SDK DLL.'
    }
    if ((Get-FileHash -LiteralPath $sdk[0].FullName -Algorithm SHA256).Hash -ne
        '33cec949309f8025be35ff19d7ae7f7bfc0f59a9ff0bef3e05c40460f0bf6e8d') {
        throw 'Unexpected Windows RUM 0.4.4 DLL.'
    }
}
Write-Output "PASS: $Mode Windows package licenses match source and SDK policy"
