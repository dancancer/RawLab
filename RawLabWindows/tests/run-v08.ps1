[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RawPath,
      [Parameter(Mandatory=$true)][string]$NativeArtifacts,
      [string]$DotNet='dotnet',
      [string]$Only='')
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$results=Join-Path $repo 'build/windows-v08-results'
New-Item -ItemType Directory -Force $results | Out-Null
$summary=@()
$selected=@($Only.Split(',',[StringSplitOptions]::RemoveEmptyEntries))
function Invoke-Check([string]$Name,[string[]]$Arguments) {
    if($Name -ne 'build' -and $selected.Count -gt 0 -and $Name -notin $selected){return}
    $log=Join-Path $results ($Name+'.log')
    $preference=$ErrorActionPreference
    Push-Location $repo
    try {
        $ErrorActionPreference='Continue'
        & $DotNet @Arguments 2>&1 | ForEach-Object {"$_"} | Out-File -FilePath $log -Encoding utf8 -Width 4096
        $code=$LASTEXITCODE
    }
    finally {$ErrorActionPreference=$preference;Pop-Location}
    $script:summary+=@{name=$Name;exitCode=$code;log=$log}
    Write-Host "$Name exit=$code log=$log"
    if($Name -eq 'build' -and $code -ne 0){throw 'Managed WPF build failed.'}
}
Invoke-Check 'build' @('build',"$PSScriptRoot/RawLabWindows.Tests.csproj",'-c','Release','--no-incremental')
$target=(& $DotNet msbuild "$PSScriptRoot/RawLabWindows.Tests.csproj" -getProperty:TargetDir -p:Configuration=Release).Trim()
if($LASTEXITCODE -ne 0){throw 'Cannot resolve test output.'}
foreach($name in @('sony2fuji.dll','raw.dll')){
    Copy-Item -LiteralPath (Join-Path $NativeArtifacts $name) -Destination $target -Force
}
Get-ChildItem -LiteralPath $NativeArtifacts -File -Filter '*.dll' |
    Where-Object {$_.Name -match '^(vcruntime|msvcp|vcomp|concrt)'} |
    Copy-Item -Destination $target -Force
Copy-Item (Join-Path $NativeArtifacts 'ExifTool') -Destination $target -Recurse -Force
$runner=Join-Path $target 'RawLabWindows.Tests.dll'
Invoke-Check 'editing' @('run','--project',"$PSScriptRoot/editing/EditWorkflow.Tests.csproj",'-c','Release')
Invoke-Check 'denoise-model' @('run','--project',"$PSScriptRoot/denoise/DenoiseSettingsTests.csproj",'-c','Release')
Invoke-Check 'localization' @('run','--project',"$PSScriptRoot/localization/LocalizationChecks.csproj",'-c','Release')
Invoke-Check 'about' @($runner,'--about')
Invoke-Check 'editor-shell' @($runner,'--editor-shell',"$results/screenshots")
foreach($name in @('geometry','transform-ui','photo-features','master-recipes','rendered-dng','denoise','lens')){
    Invoke-Check $name @($runner,('--'+$name),$repo,$RawPath)
}
$summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $results 'summary.json') -Encoding utf8
if(@($summary | Where-Object {$_.exitCode -ne 0}).Count -gt 0){throw 'Some checks failed; inspect summary.json and individual logs.'}
Write-Host 'PASS: Windows v08 targeted checks. Physical DPI, Narrator, Snap and hardware require separate evidence.'
