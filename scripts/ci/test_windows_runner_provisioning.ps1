param([switch]$VerifyToolchain)
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'provision-windows-runner.ps1'
$arguments = @{ PowerShellZip='not-used'; RunnerZip='not-used'; PythonZip='not-used'; LensSourcesTar='not-used'; LensManifest='not-used' }
foreach ($case in @(
    @{ Root="$env:SystemDrive\RawLabCI"; Message='Keep CI outputs on a dedicated data volume*' },
    @{ Root='relative-ci-root'; Message='A drive-qualified CI root is required.' }
)) {
    $rejected = $false
    try { & $script -CiRoot $case.Root @arguments }
    catch { $rejected = $_.Exception.Message -like $case.Message }
    if (!$rejected) { throw "Unsafe CI root was not rejected before installation: $($case.Root)" }
}
Write-Output 'PASS Windows provisioning rejects system-drive and relative CI roots before installation.'
if ($VerifyToolchain) {
    $version = 'E:\RawLabCI\toolcache\Python\3.12.10'
    if (!(Test-Path "$version\x64.complete")) { throw 'The non-administrator runner needs a complete preinstalled Python tool cache.' }
    & "$version\x64\python.exe" -c 'import sys; assert sys.version_info[:3] == (3, 12, 10)'
    if ($LASTEXITCODE -ne 0) { throw 'The preinstalled Python is not executable.' }
    Write-Output 'PASS Python 3.12.10 is ready without changing the service execution policy.'
}
