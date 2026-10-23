[CmdletBinding()]
param([switch]$Test, [switch]$SelfContained, [string]$DotNet, [string]$CMake, [string]$Python,
    [string]$RawPath, [string]$RawDirectory = 'Z:\Photo\2019\2019-02-02',
    [string]$RumSdkZip, [switch]$NoRumSdk, [string]$DualDnModel, [string]$OnnxRuntimeRoot)
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
# ---------------------------------------------------------------------------
# Aliyun RUM PC SDK 0.4.4 (usage analytics). Release packages carry it by
# default and report env=PROD. -NoRumSdk builds an offline package without
# analytics; -RumSdkZip uses a local copy of the vendor archive. Otherwise the
# archive comes from the main worktree's .cache/shared, downloaded once from
# the vendor URL. The archive and DLL SHA-256 are pinned; a mismatch fails.
# ---------------------------------------------------------------------------
$rumSdkUrl = 'https://rum-sdk.oss-cn-hangzhou.aliyuncs.com/native/AlibabaCloud_RUM_Windows_0.4.4.zip'
$rumSdkSha256 = 'bfa05c0718a57eb7e94c9494499bd3c84305a3cc39b76d6a9096667553928994'
function Get-SharedCache {
    # Native stderr must not stop the build when this is not a git checkout.
    $ErrorActionPreference = 'Continue'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $common = & $git.Source -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null
        if ($LASTEXITCODE -eq 0 -and $common) { return Join-Path (Split-Path $common -Parent) '.cache/shared' }
    }
    Join-Path $repo '.cache/shared'
}
function Get-RumSdkZip {
    if ($RumSdkZip) {
        if (!(Test-Path -LiteralPath $RumSdkZip -PathType Leaf)) { throw "RUM SDK archive not found: $RumSdkZip" }
        $archive = (Resolve-Path -LiteralPath $RumSdkZip).Path
    } else {
        $archive = Join-Path (Get-SharedCache) 'aliyun-rum/windows/0.4.4/sdk.zip'
        if (!(Test-Path -LiteralPath $archive)) {
            New-Item -ItemType Directory -Force (Split-Path $archive) | Out-Null
            $partial = "$archive.download"
            try { Invoke-WebRequest $rumSdkUrl -OutFile $partial -UseBasicParsing }
            catch { throw "Cannot download the RUM SDK from $rumSdkUrl. Pass -RumSdkZip <AlibabaCloud_RUM_Windows_0.4.4.zip>, or -NoRumSdk for an offline package without analytics." }
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $rumSdkSha256) {
                Remove-Item -LiteralPath $partial
                throw "Downloaded RUM SDK archive has an unexpected SHA-256: $rumSdkUrl"
            }
            Move-Item -LiteralPath $partial -Destination $archive
        }
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $rumSdkSha256) { throw "Unexpected RUM SDK archive SHA-256: $archive" }
    $archive
}
$rumProperty = if ($NoRumSdk) { '-p:RawLabRumSdk=false' } else { "-p:RawLabRumSdkZip=$(Get-RumSdkZip)" }
$aiOptions = @('-DSONY2FUJI_ENABLE_AI_DENOISE=OFF','-DSONY2FUJI_ENABLE_DIRECTML=OFF')
if ($DualDnModel) {
    $DualDnModel = (Resolve-Path -LiteralPath $DualDnModel).Path
    $modelManifest = Get-Content -LiteralPath "$DualDnModel/manifest.json" -Raw | ConvertFrom-Json
    if ($modelManifest.coreml) { throw 'Use the base ONNX package from export.py for Windows, without Apple CoreML resources.' }
    if (!$OnnxRuntimeRoot) {
        $OnnxRuntimeRoot = & "$PSScriptRoot/build-ai-dependencies.ps1" -CacheDirectory (Join-Path (Get-SharedCache) 'onnxruntime/windows-directml-1.23.0') -Output "$repo/build/windows-ai-deps"
    }
    $OnnxRuntimeRoot = (Resolve-Path -LiteralPath $OnnxRuntimeRoot).Path
    if ((Get-Content -LiteralPath "$OnnxRuntimeRoot/VERSION_NUMBER" -Raw).Trim() -ne '1.23.0') { throw 'Windows DualDn requires ONNX Runtime DirectML 1.23.0.' }
    $runtimePins = @{
        'onnxruntime.dll' = 'f5131591edac6b0a8090d0e329040a49319d7a689cb5b465235fbf7030fa8027'
        'onnxruntime_providers_shared.dll' = '3b27e1417d12b73a6a34d80414c083e359e092d2f0ce572d7e67be8cdbe9e825'
        'DirectML.dll' = '9c9e6d822561c6c41b90e6994b3e8857cf1d66dbfb1e0c4c799c7c89b4e92da1'
    }
    foreach ($name in $runtimePins.Keys) {
        if ((Get-FileHash -LiteralPath "$OnnxRuntimeRoot/lib/$name" -Algorithm SHA256).Hash -ne $runtimePins[$name]) { throw "Unexpected AI runtime: $name" }
    }
    $aiOptions = @('-DSONY2FUJI_ENABLE_AI_DENOISE=ON','-DSONY2FUJI_ENABLE_DIRECTML=ON',"-DONNXRUNTIME_ROOT=$($OnnxRuntimeRoot.Replace('\','/'))","-DRAWLAB_DUALDN_TEST_PACKAGE=$($DualDnModel.Replace('\','/'))")
}
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$environment = & cmd.exe /d /s /c "`"$vs/VC/Auxiliary/Build/vcvars64.bat`" >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the MSVC x64 build environment.' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
}
if (!$Python) { $Python = & "$PSScriptRoot/build-host-python.ps1" -Directory "$repo/build/tools/python-lens" }
$fixture = ''
if ($Test) {
    & "$PSScriptRoot/tests/BuildScriptChecks.ps1"
    Invoke-Checked $DotNet @('run','--project',"$PSScriptRoot/tests/updates/UpdateChecks.csproj",'-c','Release')
    if (!$RawPath) { $RawPath = (Get-ChildItem -LiteralPath $RawDirectory -File -Filter '*.ARW' | Sort-Object Name | Select-Object -First 1).FullName }
    if (!$RawPath -or !(Test-Path -LiteralPath $RawPath)) { throw 'Supply -RawPath pointing to an external RAW fixture.' }
    # Test only a local copy; the external photo directory is read-only input.
    $fixtureDir = Join-Path $repo 'build/windows-fixtures'
    New-Item -ItemType Directory -Force $fixtureDir | Out-Null
    $fixture = Join-Path $fixtureDir ('primary' + [IO.Path]::GetExtension($RawPath))
    Copy-Item -LiteralPath $RawPath -Destination $fixture -Force
    Write-Host "Test fixture: $RawPath"
}
Invoke-Checked $CMake (@('-S',"$PSScriptRoot/native",'-B',$native,'-A','x64','-DBUILD_TESTING=ON',"-DPython3_EXECUTABLE=$Python","-DSONY2FUJI_TEST_RAW=$($fixture.Replace('\','/'))") + $aiOptions)
Invoke-Checked $CMake @('--build',$native,'--config','Release','--parallel')
$iconPath=Join-Path $native 'RawLab.ico'
& "$PSScriptRoot/build-icon.ps1" -Source "$repo/RawLabMac/Resources/AppIcon.png" -Output $iconPath
$publish = @('publish',"$PSScriptRoot/RawLabWindows.csproj",'-c','Release','-r','win-x64','-o',$output,'--self-contained',([bool]$SelfContained).ToString().ToLowerInvariant(),"-p:ApplicationIcon=$iconPath",$rumProperty)
Invoke-Checked $DotNet $publish
if ((Test-Path -LiteralPath "$output/alibabacloud_rum.dll") -eq [bool]$NoRumSdk) { throw 'The package RUM SDK presence does not match -NoRumSdk.' }
& "$PSScriptRoot/build-exiftool.ps1" -Output $output
Copy-Item "$native/core/Release/sony2fuji.dll", "$native/cli/Release/sony2fuji.exe", "$native/Release/raw.dll" $output -Force
$aiDestination = Join-Path $output 'AI/DualDn'
if (Test-Path -LiteralPath $aiDestination) { Remove-Item -LiteralPath $aiDestination -Recurse -Force }
if ($DualDnModel) {
    foreach ($name in $runtimePins.Keys) { Copy-Item -LiteralPath "$OnnxRuntimeRoot/lib/$name" $output -Force }
    $env:PATH = "$output;$env:PATH"
    $probe = "$native/bin/Release/dualdn_probe.exe"
    Invoke-Checked $probe @('--validate',$DualDnModel)
    New-Item -ItemType Directory -Force $aiDestination | Out-Null
    foreach ($name in @('manifest.json','raw.onnx','isp.onnx','rgb.onnx','DualDn-LICENSE.txt')) { Copy-Item -LiteralPath "$DualDnModel/$name" $aiDestination -Force }
    Invoke-Checked $probe @('--validate',$aiDestination)
} else {
    foreach ($name in @('onnxruntime.dll','onnxruntime_providers_shared.dll','DirectML.dll')) {
        if (Test-Path -LiteralPath "$output/$name") { Remove-Item -LiteralPath "$output/$name" }
    }
}
$schemas = Join-Path $output 'AgentSchemas'
New-Item -ItemType Directory -Force $schemas | Out-Null
Copy-Item "$repo/lutools/docs/edit-json-v*.schema.json", "$repo/lutools/examples/edit-recipes/complete-v4.json" $schemas -Force
# Package the compiler runtime app-locally; users do not need Visual Studio.
$vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$redist = Get-ChildItem "$vs/VC/Redist/MSVC" -Directory | Where-Object Name -Match '^\d+\.' | Sort-Object Name -Descending | Select-Object -First 1
$crt = Get-ChildItem "$($redist.FullName)/x64" -Directory -Filter '*.CRT' | Select-Object -First 1
if (!$crt) { throw 'Cannot locate the Visual C++ redistributable runtime.' }
Copy-Item "$($crt.FullName)/*.dll" $output -Force
$openmp = Get-ChildItem "$($redist.FullName)/x64" -Directory -Filter '*.OpenMP' | Select-Object -First 1
if (!$openmp) { throw 'Cannot locate the Visual C++ OpenMP runtime.' }
Copy-Item "$($openmp.FullName)/*.dll" $output -Force
$licenses = Join-Path $output 'Licenses'
New-Item -ItemType Directory -Force $licenses | Out-Null
$aiLicenses = Join-Path $licenses 'DualDn'
if (Test-Path -LiteralPath $aiLicenses) { Remove-Item -LiteralPath $aiLicenses -Recurse -Force }
if ($DualDnModel) {
    New-Item -ItemType Directory -Force $aiLicenses | Out-Null
    Copy-Item -LiteralPath "$DualDnModel/DualDn-LICENSE.txt" "$aiLicenses/LICENSE" -Force
    Copy-Item -LiteralPath "$OnnxRuntimeRoot/LICENSE" "$aiLicenses/ONNX-Runtime-LICENSE" -Force
    Copy-Item -LiteralPath "$OnnxRuntimeRoot/ThirdPartyNotices.txt" "$aiLicenses/ONNX-Runtime-ThirdPartyNotices.txt" -Force
    Copy-Item -LiteralPath "$OnnxRuntimeRoot/licenses/DirectML" $aiLicenses -Recurse -Force
}
$libtiffLicense = Join-Path $native 'licenses/libtiff/LICENSE.md'
if (!(Test-Path $libtiffLicense)) { throw 'The native build did not export the libtiff license.' }
Copy-Item "$native/licenses/*" $licenses -Recurse -Force
Copy-Item "$repo/lutools/third_party/Adobe-DNG-SDK-LICENSE.txt", "$repo/lutools/third_party/rawspeed-camera-calibration.inc", "$repo/RawLabMac/Resources/Licenses/stb-MIT-LICENSE.txt" $licenses -Force
Copy-Item "$PSScriptRoot/Licenses/*" $licenses -Force
Copy-Item "$PSScriptRoot/ThirdPartyNotices.md", "$PSScriptRoot/README.md", "$PSScriptRoot/verification.md", "$PSScriptRoot/performance.md" $output -Force
Copy-Item "$repo/LICENSE" $output -Force
Copy-Item "$repo/LICENSE" "$licenses/RawLab-GPL-3.0.txt" -Force
Copy-Item "$repo/LICENSE-ALIYUN-RUM-EXCEPTION" "$licenses/RawLab-Aliyun-RUM-Exception.txt" -Force
Copy-Item "$repo/docs/reference/licensing.md" "$licenses/RawLab-Licensing.md" -Force
Copy-Item "$repo/lutools/flog-2-new/F-Log2_LUT_overview_Ver.2.0E.pdf" "$output/LUTs" -Force
if ($Test) {
    Copy-Item "$native/Release/raw.dll", "$($openmp.FullName)/*.dll" "$native/core/Release" -Force
    $env:PATH = "$output;$env:PATH"
    $ctest = Join-Path (Split-Path $CMake) 'ctest.exe'
    Invoke-Checked $ctest @('--test-dir',$native,'-C','Release','--output-on-failure','--no-tests=error')
    # Archives preserve timestamps; force a fresh managed test assembly.
    Invoke-Checked $DotNet @('build',"$PSScriptRoot/tests/RawLabWindows.Tests.csproj",'-c','Release','--no-incremental')
    $testOut = (& $DotNet msbuild "$PSScriptRoot/tests/RawLabWindows.Tests.csproj" -getProperty:TargetDir -p:Configuration=Release).Trim()
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $testOut)) { throw 'Cannot resolve the WPF test output directory.' }
    Copy-Item "$native/core/Release/sony2fuji.dll", "$native/Release/raw.dll", "$($crt.FullName)/*.dll", "$($openmp.FullName)/*.dll" $testOut -Force
    Copy-Item "$output/ExifTool" $testOut -Recurse -Force
    if ($DualDnModel) {
        foreach ($name in $runtimePins.Keys) { Copy-Item -LiteralPath "$output/$name" $testOut -Force }
        Copy-Item "$output/AI" $testOut -Recurse -Force
        Invoke-Checked $DotNet @("$testOut/RawLabWindows.Tests.dll",'--ai-window',"$repo/lutools/tests/fixtures/bayer-demosaic.dng","$repo/build/windows-ai-window")
    }
    Invoke-Checked $DotNet @("$testOut/RawLabWindows.Tests.dll",'--ai-panel',"$repo/build/windows-ai-panel")
    Invoke-Checked $DotNet @("$testOut/RawLabWindows.Tests.dll",'--about')
    Invoke-Checked $DotNet @("$testOut/RawLabWindows.Tests.dll",$repo,$fixture)
}
Write-Host "Built: $output/RawLab.exe"
