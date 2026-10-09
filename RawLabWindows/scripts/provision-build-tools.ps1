param([Parameter(Mandatory=$true)][string]$InstallerDirectory)
$ErrorActionPreference = 'Stop'
$admin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run from an elevated PowerShell session.'
}
$logRoot = 'C:\RawLabBuild\Logs'
New-Item -ItemType Directory -Force $logRoot | Out-Null
Start-Transcript -Path "$logRoot\provision-build-tools.log" -Append
try {
    function Install-MicrosoftTool([string]$File, [string]$Arguments) {
        $signature = Get-AuthenticodeSignature $File
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
            throw "Invalid Microsoft installer signature: $File"
        }
        $process = Start-Process -FilePath $File -ArgumentList $Arguments -Wait -PassThru
        if ($process.ExitCode -notin 0, 3010) { throw "$File exited with $($process.ExitCode)" }
        Write-Output "Installer completed: $File (exit $($process.ExitCode))"
    }

    $dotnetInstaller = Join-Path $InstallerDirectory 'dotnet-sdk-8.0.425-win-x64.exe'
    $expected = 'ebe1eb4d0d8c30cb7863586e9580bd51bfca8bbd0eece636941bd72e3136834c6f82ffa0ad4d395d7a9996ecb045d2a3882035d3feeec8c99547d73cc66c9d97'
    if ((Get-FileHash $dotnetInstaller -Algorithm SHA512).Hash -ne $expected) {
        throw 'The .NET installer does not match the official release metadata.'
    }
    if (-not (Test-Path 'C:\Program Files\dotnet\sdk\8.0.425')) {
        Install-MicrosoftTool $dotnetInstaller '/install /quiet /norestart'
    }
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    $installation = if (Test-Path $vswhere) {
        & $vswhere -latest -version '[17.8,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    }
    if (-not $installation) {
        $vsInstaller = Join-Path $InstallerDirectory 'vs_BuildTools_17.14.41.exe'
        if ((Get-FileHash $vsInstaller -Algorithm SHA256).Hash -ne '37bb0fb429d163ecebd272a865d11a37b906d152bef960da2ddb29c2e2fd6eeb') {
            throw 'The Visual Studio installer does not match the pinned Microsoft download.'
        }
        Install-MicrosoftTool $vsInstaller `
            '--quiet --wait --norestart --installPath C:\BuildTools --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools --includeRecommended'
    }
    & 'C:\Program Files\dotnet\dotnet.exe' --list-sdks
    if ($LASTEXITCODE -ne 0) { throw '.NET SDK verification failed.' }
    $installation = & $vswhere -latest -version '[17.8,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) { throw 'The MSVC x64 build tools were not installed.' }
    & "$installation\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe" --version
    if ($LASTEXITCODE -ne 0) { throw 'Visual Studio CMake verification failed.' }
    & $vswhere -latest -products '*' -format json | Set-Content "$logRoot\visual-studio.json"
    Write-Output 'PASS: .NET 8 SDK, MSVC x64 and CMake are available.'
} finally {
    Stop-Transcript
}
