$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'provision-windows-runner.ps1'
$arguments = @{ PowerShellZip='not-used'; RunnerZip='not-used'; LensSourcesTar='not-used'; LensManifest='not-used' }
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
