[CmdletBinding()]
param(
    [string]$CiRoot = 'E:\RawLabCI',
    [Parameter(Mandatory)][string]$PowerShellZip,
    [Parameter(Mandatory)][string]$RunnerZip,
    [Parameter(Mandatory)][string]$PythonZip,
    [Parameter(Mandatory)][string]$LensSourcesTar,
    [Parameter(Mandatory)][string]$LensManifest
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (!$identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run as an administrator inside the Windows KVM guest.' }
if ((Get-CimInstance Win32_ComputerSystem).Manufacturer -ne 'QEMU') { throw 'A dedicated QEMU/KVM guest is required.' }
if ($CiRoot -notmatch '^[A-Za-z]:\\') { throw 'A drive-qualified CI root is required.' }
$CiRoot = [IO.Path]::GetFullPath($CiRoot).TrimEnd('\')
if ([IO.Path]::GetPathRoot($CiRoot) -eq "$env:SystemDrive\") { throw 'Keep CI outputs on a dedicated data volume, not the Windows system drive.' }
if (!(Test-Path ([IO.Path]::GetPathRoot($CiRoot)))) { throw 'Prepare the dedicated NTFS data volume first.' }

function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}
function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) { throw "Unexpected SHA-256: $Path" }
}
Assert-Hash $PowerShellZip 'd2f952ebdbf24386cb8923553aa58e41a846db35a6155ea04c58142a4b16dbb7'
Assert-Hash $RunnerZip 'f48e0750a21812bca5f82de5f7f5aeae71abee647fab5a582f1742d07eba455f'
Assert-Hash $PythonZip '17e4ee587e0ecee4674040da8b248e151475ff65becae18fe0ec81f8312b5035'

New-Item -ItemType Directory -Force $CiRoot | Out-Null
# Only the service account, SYSTEM and administrators can access runner credentials.
Invoke-Checked icacls.exe @($CiRoot, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-20:(OI)(CI)M')
foreach ($directory in @('runner', '_work', 'toolcache', 'tmp', 'dotnet', 'cache\nuget', 'cache\dotnet', 'cache\pip', 'cache\lens-sources', 'pwsh\7.6.7')) {
    New-Item -ItemType Directory -Force (Join-Path $CiRoot $directory) | Out-Null
}
$runner = Join-Path $CiRoot 'runner'
$pwsh = Join-Path $CiRoot 'pwsh\7.6.7'
if (!(Test-Path "$pwsh\pwsh.exe")) { Expand-Archive -LiteralPath $PowerShellZip -DestinationPath $pwsh }
if (!(Test-Path "$runner\bin\Runner.Listener.exe")) { Expand-Archive -LiteralPath $RunnerZip -DestinationPath $runner }
Invoke-Checked "$pwsh\pwsh.exe" @('-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()')

# setup-python invokes Windows PowerShell without an execution-policy override.
# Seed its official cache once as administrator; keep the job service unprivileged.
$env:AGENT_TOOLSDIRECTORY = Join-Path $CiRoot 'toolcache'
$env:RUNNER_TOOL_CACHE = $env:AGENT_TOOLSDIRECTORY
$env:TEMP = Join-Path $CiRoot 'tmp'
$env:TMP = $env:TEMP
$env:PIP_CACHE_DIR = Join-Path $CiRoot 'cache\pip'
$pythonVersion = Join-Path $env:AGENT_TOOLSDIRECTORY 'Python\3.12.10'
if (!(Test-Path "$pythonVersion\x64.complete")) {
    $registryRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $existingPython = @(Get-ItemProperty $registryRoots -ErrorAction SilentlyContinue | Where-Object DisplayName -match '^Python 3\.12')
    if ($existingPython.Count) { throw 'Inspect the existing Python 3.12 installation before running its official tool-cache installer.' }
    $installer = Join-Path $env:TEMP 'python-3.12.10-installer'
    New-Item -ItemType Directory -Force $installer | Out-Null
    Expand-Archive -LiteralPath $PythonZip -DestinationPath $installer -Force
    Push-Location $installer
    try { Invoke-Checked powershell.exe @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', './setup.ps1') *> (Join-Path $env:TEMP 'python-3.12.10-install.log') }
    finally { Pop-Location }
}
if (!(Test-Path "$pythonVersion\x64.complete")) { throw 'Python tool-cache installation did not complete.' }
Invoke-Checked "$pythonVersion\x64\python.exe" @('--version')

$sources = Join-Path $CiRoot 'cache\lens-sources'
Invoke-Checked tar.exe @('-xf', $LensSourcesTar, '-C', $sources)
$manifest = Get-Content -LiteralPath $LensManifest -Raw | ConvertFrom-Json
foreach ($entry in $manifest.PSObject.Properties) {
    $spec = $entry.Value
    if ([IO.Path]::GetFileName($spec.file) -ne $spec.file) { throw 'Invalid source archive filename.' }
    Assert-Hash (Join-Path $sources $spec.file) $spec.sha256
}
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ($LASTEXITCODE -ne 0 -or !$vs) { throw 'Visual Studio 2022 C++ Build Tools are required.' }
$cmake = Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin'
Invoke-Checked "$cmake\cmake.exe" @('--version')
if (!(Test-Path "$cmake\ctest.exe")) { throw 'CTest is required.' }
$git = (Get-Command git.exe -ErrorAction Stop).Source
Invoke-Checked $git @('--version')
$utf8 = [Text.UTF8Encoding]::new($false)
$path = "$pwsh;$cmake;$(Split-Path $git);" + [Environment]::GetEnvironmentVariable('Path', 'Machine')
[IO.File]::WriteAllLines("$runner\.env", @(
    "Path=$path",
    "TEMP=$CiRoot\tmp", "TMP=$CiRoot\tmp", "AGENT_TOOLSDIRECTORY=$CiRoot\toolcache",
    "RUNNER_TOOL_CACHE=$CiRoot\toolcache", "NUGET_PACKAGES=$CiRoot\cache\nuget",
    "DOTNET_CLI_HOME=$CiRoot\cache\dotnet", "DOTNET_INSTALL_DIR=$CiRoot\dotnet",
    "PIP_CACHE_DIR=$CiRoot\cache\pip", "RAWLAB_LENS_SOURCE_CACHE=$sources"
), $utf8)
Write-Output 'Windows guest tools are ready. Register the runner separately as NT AUTHORITY\NETWORK SERVICE; do not store a GitHub administrator token.'
