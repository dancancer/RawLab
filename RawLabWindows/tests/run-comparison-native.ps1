[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RawPath,
    [string]$NativeArtifacts,
    [string]$Output,
    [string]$DotNet='dotnet'
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$profile=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'RawLab'
$record=Join-Path $profile 'Batch/job.json'
if(Test-Path -LiteralPath $record){throw "Preserve existing batch job: $record. Use an isolated test account."}
if(!$NativeArtifacts){$NativeArtifacts=Join-Path $repo 'build/RawLab-Windows'}
if(!$Output){$Output=Join-Path $repo ('build/comparison-native/'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))}
$Output=[IO.Path]::GetFullPath($Output)
function ProfileStamp {
    if(!(Test-Path -LiteralPath $profile)){return 'ABSENT'}
    $rows=@(Get-ChildItem -LiteralPath $profile -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
        [ordered]@{path=$_.FullName;hash=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash;written=$_.LastWriteTimeUtc.Ticks}
    })
    return ConvertTo-Json -InputObject $rows -Depth 4 -Compress
}
$before=ProfileStamp
New-Item -ItemType Directory -Force $Output | Out-Null
$code=1;$result='failed';$savedRaw=$env:RAWLAB_COMPARISON_RAW;$savedPhase=$env:RAWLAB_COMPARISON_UI_PHASE
function Invoke-DotNet([string]$Name,[string[]]$Arguments) {
    $previous=$ErrorActionPreference
    try{
        $ErrorActionPreference='Continue';$global:LASTEXITCODE=$null
        & $DotNet @Arguments 2>&1 | ForEach-Object {"$_"} | Out-File (Join-Path $Output ($Name+'.log')) -Encoding utf8 -Width 4096 -ErrorAction Stop
        if($null -eq $LASTEXITCODE){return 1};return [int]$LASTEXITCODE
    }finally{$ErrorActionPreference=$previous}
}
try{
    if((Invoke-DotNet 'build' @('build',"$PSScriptRoot/RawLabWindows.Tests.csproj",'-c','Release','--no-incremental')) -ne 0){throw 'Managed host build failed'}
    if((Invoke-DotNet 'build-driver' @('build',"$PSScriptRoot/ui-automation/RawLabWindows.UiAutomation.csproj",'-c','Release','--no-incremental')) -ne 0){throw 'External UIA driver build failed'}
    $target=(& $DotNet msbuild "$PSScriptRoot/RawLabWindows.Tests.csproj" -getProperty:TargetDir -p:Configuration=Release).Trim()
    if($LASTEXITCODE -ne 0 -or !$target){throw 'Cannot resolve native UIA host output'}
    foreach($name in @('sony2fuji.dll','raw.dll')){Copy-Item -LiteralPath (Join-Path $NativeArtifacts $name) $target -Force}
    Get-ChildItem -LiteralPath $NativeArtifacts -File -Filter '*.dll' | Where-Object {$_.Name -match '^(vcruntime|msvcp|vcomp|concrt)'} | Copy-Item -Destination $target -Force
    Copy-Item (Join-Path $NativeArtifacts 'ExifTool') $target -Recurse -Force
    $env:RAWLAB_COMPARISON_RAW=[IO.Path]::GetFullPath($RawPath)
    $env:RAWLAB_COMPARISON_UI_PHASE=$null
    $code=Invoke-DotNet 'native-interaction' @((Join-Path $target 'RawLabWindows.Tests.dll'),'--comparison-ui-host',$repo,(Join-Path $Output 'private-profile'))
    if($code -eq 0){$result='passed'}elseif($code -eq 2){$result='not_reached'}else{throw "Native UIA interaction failed: $code"}
}
finally{
    $env:RAWLAB_COMPARISON_RAW=$savedRaw
    $env:RAWLAB_COMPARISON_UI_PHASE=$savedPhase
    $after=ProfileStamp
    [IO.File]::WriteAllText((Join-Path $Output 'default-profile-before.json'),[string]$before)
    [IO.File]::WriteAllText((Join-Path $Output 'default-profile-after.json'),[string]$after)
    if([string]$before -cne [string]$after){$code=1;$result='failed';Write-Error 'Default RawLab profile changed' -ErrorAction Continue}
    ConvertTo-Json -InputObject @{name='comparison-native';exitCode=$code;result=$result;output=$Output} -Depth 4 | Set-Content (Join-Path $Output 'summary.json') -Encoding utf8
}
if($code -eq 0){Write-Host 'PASS: external Windows UIA / NativeDialog and restart history checks.'}
elseif($code -eq 2){Write-Host 'NOT REACHED: a usable Windows desktop is required; inspect native-interaction.log.'}
exit $code
