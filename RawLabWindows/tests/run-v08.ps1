[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RawPath,
      [Parameter(Mandatory=$true)][string]$NativeArtifacts,
      [string]$DotNet='dotnet',
      [string]$DenoiseRaw='',
      [string]$Only='')
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$results=Join-Path $repo 'build/windows-v08-results'
if(!$DenoiseRaw){$DenoiseRaw=Join-Path $repo 'build/windows-fixtures/denoise.dng'}
New-Item -ItemType Directory -Force $results | Out-Null
$summary=@()
$selected=@()
$names=@('build','build-localization-ui','editing','denoise-model','localization','updates','about','default-isolation','localization-admission','profile-isolation','localization-ui','status-layout','appearance','editor-shell','geometry','transform-ui','editor-review','photo-features','interactions','master-recipes','rendered-dng','denoise','lens')
[IO.File]::WriteAllText((Join-Path $results 'summary.json'),'[]')
function Invoke-Check([string]$Name,[string[]]$Arguments) {
    if($Name -notlike 'build*' -and $selected.Count -gt 0 -and $Name -notin $selected){return}
    $log=Join-Path $results ($Name+'.log')
    $preference=$ErrorActionPreference
    Push-Location $repo
    try {
        $ErrorActionPreference='Continue'
        $global:LASTEXITCODE=$null
        & $DotNet @Arguments 2>&1 | ForEach-Object {"$_"} | Out-File -FilePath $log -Encoding utf8 -Width 4096 -ErrorAction Stop
        $code=if($null -eq $LASTEXITCODE){1}else{[int]$LASTEXITCODE}
    }
    finally {$ErrorActionPreference=$preference;Pop-Location}
    $script:summary+=@{name=$Name;exitCode=$code;log=$log}
    Write-Host "$Name exit=$code log=$log"
    if($Name -like 'build*' -and $code -ne 0){throw 'Managed WPF build failed.'}
}
function Resolve-Target([string]$Project){
    $global:LASTEXITCODE=$null
    $value=@(& $DotNet msbuild $Project -getProperty:TargetDir -p:Configuration=Release)
    if($null -eq $LASTEXITCODE -or $LASTEXITCODE -ne 0){throw "Cannot resolve test output: $Project"}
    $path=($value -join [Environment]::NewLine).Trim()
    if(!$path){throw "Empty test output: $Project"}
    return $path
}
try{
    $selected=@($Only.Split(',') | ForEach-Object {$_.Trim().ToLowerInvariant()} | Where-Object {$_} | Select-Object -Unique)
    if($Only.Length -gt 0 -and $selected.Count -eq 0){throw 'Only must contain at least one suite name, or be empty for all suites.'}
    $unknown=@($selected | Where-Object {$_ -notin $names})
    if($unknown.Count -gt 0){throw "Unknown suite selection: $($unknown -join ', '). Available: $($names -join ', ')."}
Invoke-Check 'build' @('build',"$PSScriptRoot/RawLabWindows.Tests.csproj",'-c','Release','--no-incremental')
Invoke-Check 'build-localization-ui' @('build',"$PSScriptRoot/localization-ui/LocalizationUiChecks.csproj",'-c','Release','--no-incremental')
$target=Resolve-Target "$PSScriptRoot/RawLabWindows.Tests.csproj"
$uiTarget=Resolve-Target "$PSScriptRoot/localization-ui/LocalizationUiChecks.csproj"
foreach($destination in @($target,$uiTarget)){
foreach($name in @('sony2fuji.dll','raw.dll')){
    Copy-Item -LiteralPath (Join-Path $NativeArtifacts $name) -Destination $destination -Force
}
Get-ChildItem -LiteralPath $NativeArtifacts -File -Filter '*.dll' |
    Where-Object {$_.Name -match '^(vcruntime|msvcp|vcomp|concrt)'} |
    Copy-Item -Destination $destination -Force
Copy-Item (Join-Path $NativeArtifacts 'ExifTool') -Destination $destination -Recurse -Force
}
$runner=Join-Path $target 'RawLabWindows.Tests.dll'
$localizationRunner=Join-Path $uiTarget 'LocalizationUiChecks.dll'
Invoke-Check 'editing' @('run','--project',"$PSScriptRoot/editing/EditWorkflow.Tests.csproj",'-c','Release')
Invoke-Check 'denoise-model' @('run','--project',"$PSScriptRoot/denoise/DenoiseSettingsTests.csproj",'-c','Release')
Invoke-Check 'localization' @('run','--project',"$PSScriptRoot/localization/LocalizationChecks.csproj",'-c','Release')
Invoke-Check 'updates' @('run','--project',"$PSScriptRoot/updates/UpdateChecks.csproj",'-c','Release')
Invoke-Check 'about' @($runner,'--about')
Invoke-Check 'default-isolation' @($runner,'--default-isolation',"$results/default-isolation")
Invoke-Check 'localization-admission' @($localizationRunner,'--default-isolation',"$results/localization-admission")
Invoke-Check 'profile-isolation' @($runner,'--profile-isolation',"$results/profile-isolation")
Invoke-Check 'localization-ui' @($localizationRunner)
Invoke-Check 'status-layout' @($runner,'--status-layout',"$results/status-layout")
Invoke-Check 'appearance' @($runner,'--appearance',"$results/appearance")
Invoke-Check 'editor-shell' @($runner,'--editor-shell',"$results/screenshots")
foreach($name in @('geometry','transform-ui','editor-review','photo-features','interactions','master-recipes','rendered-dng','denoise','lens')){
    $arguments=@($runner,('--'+$name),$repo,$RawPath)
    if($name -eq 'denoise'){$arguments+=$DenoiseRaw}
    Invoke-Check $name $arguments
}
$missing=@($selected | Where-Object {$_ -notin $summary.name})
if($missing.Count -gt 0){throw "Selected suites did not run: $($missing -join ', ')."}
if(@($summary | Where-Object {$_.exitCode -ne 0}).Count -gt 0){throw 'Some checks failed; inspect summary.json and individual logs.'}
}
catch{
    if(@($summary | Where-Object {$_.exitCode -ne 0}).Count -eq 0){$summary+=@{name='runner';exitCode=1;error=$_.Exception.Message}}
    throw
}
finally{ConvertTo-Json -InputObject @($summary) -Depth 4 | Set-Content (Join-Path $results 'summary.json') -Encoding utf8}
Write-Host 'PASS: Windows v08 targeted checks. Physical DPI, Narrator, Snap and hardware require separate evidence.'
