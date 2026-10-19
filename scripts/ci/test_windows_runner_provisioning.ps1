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
    $configuredPath = [IO.File]::ReadAllLines('E:\RawLabCI\runner\.env') | Where-Object { $_.StartsWith('Path=') }
    if (@($configuredPath).Count -ne 1) { throw 'The runner needs one explicit Path setting.' }
    $originalPath = $env:Path
    $probe = Join-Path 'E:\RawLabCI\tmp' ('cache-tools-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force "$probe\input", "$probe\restored" | Out-Null
    [IO.File]::WriteAllText("$probe\input\payload.txt", 'native dependency cache probe')
    Push-Location $probe
    try {
        $env:Path = $configuredPath.Substring(5)
        & gzip.exe --version | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'The runner cannot execute gzip.' }
        $tarVersion = & tar.exe --version
        if ($LASTEXITCODE -ne 0 -or ($tarVersion -join "`n") -notmatch 'GNU tar') { throw 'Git GNU tar is required for dependency caches.' }
        & tar.exe -czf cache.tgz -C input payload.txt
        if ($LASTEXITCODE -ne 0) { throw 'Cannot create a compressed dependency cache.' }
        & tar.exe -xzf cache.tgz -C restored
        if ($LASTEXITCODE -ne 0) { throw 'Cannot restore a compressed dependency cache.' }
        if ([IO.File]::ReadAllText("$probe\restored\payload.txt") -ne 'native dependency cache probe') {
            throw 'The compressed dependency cache did not round-trip.'
        }
    }
    finally {
        $env:Path = $originalPath
        Pop-Location
        Remove-Item -LiteralPath $probe -Recurse -Force
    }
    Write-Output 'PASS the configured runner Path supports GNU tar/gzip cache round-trips.'
}
