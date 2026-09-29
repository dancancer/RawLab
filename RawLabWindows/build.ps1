[CmdletBinding()]
param([switch]$Test, [switch]$SelfContained, [string]$DotNet, [string]$CMake,
    [string]$RawPath, [string]$RawDirectory = 'Z:\Photo\2019\2019-02-02')
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$native = Join-Path $repo 'build/windows-native'
$output = Join-Path $repo 'build/RawLab-Windows'
if (!$DotNet) {
    $localSdk = Join-Path $repo 'build/tools/dotnet/dotnet.exe'
    $DotNet = if (Test-Path $localSdk) { $localSdk } else { 'dotnet' }
}
if (!$CMake) {
    $command = Get-Command cmake -ErrorAction SilentlyContinue
    if ($command) { $CMake = $command.Source }
    else {
        $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
        if (!(Test-Path $vswhere)) { throw 'Install Visual Studio 2022 Build Tools with Desktop development with C++ and CMake.' }
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        $CMake = Join-Path $vs 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
    }
}
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed with exit code $LASTEXITCODE" }
}
$fixture = ''
if ($Test) {
    if (!$RawPath) { $RawPath = (Get-ChildItem -LiteralPath $RawDirectory -File -Filter '*.ARW' | Sort-Object Name | Select-Object -First 1).FullName }
    if (!$RawPath -or !(Test-Path -LiteralPath $RawPath)) { throw 'Supply -RawPath pointing to an external RAW fixture.' }
    # Test only a local copy; the external photo directory is read-only input.
    $fixtureDir = Join-Path $repo 'build/windows-fixtures'
    New-Item -ItemType Directory -Force $fixtureDir | Out-Null
    $fixture = Join-Path $fixtureDir ('primary' + [IO.Path]::GetExtension($RawPath))
    Copy-Item -LiteralPath $RawPath -Destination $fixture -Force
    Write-Host "Test fixture: $RawPath"
}
Invoke-Checked $CMake @('-S',"$PSScriptRoot/native",'-B',$native,'-A','x64','-DBUILD_TESTING=ON',"-DSONY2FUJI_TEST_RAW=$($fixture.Replace('\','/'))")
Invoke-Checked $CMake @('--build',$native,'--config','Release','--parallel')
$iconPath=Join-Path $native 'RawLab.ico'
& "$PSScriptRoot/build-icon.ps1" -Source "$repo/RawLabMac/Resources/AppIcon.png" -Output $iconPath
$publish = @('publish',"$PSScriptRoot/RawLabWindows.csproj",'-c','Release','-r','win-x64','-o',$output,'--self-contained',([bool]$SelfContained).ToString().ToLowerInvariant(),"-p:ApplicationIcon=$iconPath")
Invoke-Checked $DotNet $publish
& "$PSScriptRoot/build-exiftool.ps1" -Output $output
Copy-Item "$native/core/Release/sony2fuji.dll", "$native/Release/raw.dll" $output -Force
# Package the compiler runtime app-locally; users do not need Visual Studio.
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$redist = Get-ChildItem "$vs/VC/Redist/MSVC" -Directory | Where-Object Name -Match '^\d+\.' | Sort-Object Name -Descending | Select-Object -First 1
$crt = Get-ChildItem "$($redist.FullName)/x64" -Directory -Filter '*.CRT' | Select-Object -First 1
if (!$crt) { throw 'Cannot locate the Visual C++ redistributable runtime.' }
Copy-Item "$($crt.FullName)/*.dll" $output -Force
$licenses = Join-Path $output 'Licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
Copy-Item "$native/licenses/*", "$repo/lutools/third_party/Adobe-DNG-SDK-LICENSE.txt", "$repo/RawLabMac/Resources/Licenses/stb-MIT-LICENSE.txt" $licenses -Force
Copy-Item "$PSScriptRoot/Licenses/*" $licenses -Force
Copy-Item "$PSScriptRoot/ThirdPartyNotices.md", "$PSScriptRoot/README.md", "$PSScriptRoot/verification.md" $output -Force
Copy-Item "$repo/LICENSE" $output -Force
Copy-Item "$repo/lutools/flog-2-new/F-Log2_LUT_overview_Ver.2.0E.pdf" "$output/LUTs" -Force
if ($Test) {
    Copy-Item "$native/Release/raw.dll" "$native/core/Release" -Force
    $env:PATH = "$output;$env:PATH"
    $ctest = Join-Path (Split-Path $CMake) 'ctest.exe'
    Invoke-Checked $ctest @('--test-dir',$native,'-C','Release','--output-on-failure','--no-tests=error')
    Invoke-Checked $DotNet @('build',"$PSScriptRoot/tests/RawLabWindows.Tests.csproj",'-c','Release')
    $testOut = "$PSScriptRoot/tests/bin/Release/net8.0-windows"
    Copy-Item "$native/core/Release/sony2fuji.dll", "$native/Release/raw.dll", "$($crt.FullName)/*.dll" $testOut -Force
    Copy-Item "$output/ExifTool" $testOut -Recurse -Force
    Invoke-Checked $DotNet @("$testOut/RawLabWindows.Tests.dll",$repo,$fixture)
}
Write-Host "Built: $output/RawLab.exe"
