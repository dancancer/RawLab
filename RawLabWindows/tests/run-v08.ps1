[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RawPath,
      [Parameter(Mandatory=$true)][string]$NativeArtifacts,
      [string]$DotNet='dotnet',
      [string]$DenoiseRaw='',
      [string]$Only='',
      [ValidateRange(1,86400)][int]$CheckTimeoutSeconds=600)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CheckProcess.ps1')
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$results=Join-Path $repo 'build/windows-v08-results'
if(!$DenoiseRaw){$DenoiseRaw=Join-Path $repo 'build/windows-fixtures/denoise.dng'}
New-Item -ItemType Directory -Force $results | Out-Null
$summary=@()
$selected=@()
$names=@('build','editing','looks','denoise-model','localization','updates','about','default-isolation','localization-admission','profile-isolation','localization-ui','ai-panel','ai-window','editor-shell','geometry','master-recipes','rendered-dng','denoise','lens','agent-recipe','raster','batch-selection')
[IO.File]::WriteAllText((Join-Path $results 'summary.json'),'[]')
$savedEnv=@{}
foreach($key in @('RAWLAB_TEST_REPO','RAWLAB_TEST_RAW','RAWLAB_TEST_DENOISE_RAW','RAWLAB_TEST_CLI','RAWLAB_TEST_RESULTS')) {
    $savedEnv[$key]=[Environment]::GetEnvironmentVariable($key)
}
function Record-CheckResult([string]$Name,$Result) {
    $script:summary+=@{name=$Name;exitCode=$Result.exitCode;log=($Name+'.log');timedOut=$Result.timedOut;durationSeconds=$Result.durationSeconds;pid=$Result.pid}
    ConvertTo-Json -InputObject @($script:summary) -Depth 4 | Set-Content (Join-Path $results 'summary.json') -Encoding utf8
}
function Invoke-Check([string]$Name,[string[]]$Arguments) {
    if($Name -ne 'build' -and $selected.Count -gt 0 -and $Name -notin $selected){return}
    $log=Join-Path $results ($Name+'.log')
    $result=Invoke-CheckProcess -Name $Name -Executable $DotNet -Arguments $Arguments -Directory $repo -Log $log -TimeoutSeconds $CheckTimeoutSeconds
    Record-CheckResult $Name $result
    if($Name -eq 'build' -and $result.exitCode -ne 0){throw 'Managed WPF build failed.'}
}
function Resolve-Target([string]$Project){
    $name='target-'+[IO.Path]::GetFileNameWithoutExtension($Project)
    $result=Invoke-CheckProcess -Name $name -Executable $DotNet -Arguments @('msbuild',$Project,'-getProperty:TargetDir','-p:Configuration=Release') -Directory $repo -Log (Join-Path $results ($name+'.log')) -TimeoutSeconds $CheckTimeoutSeconds -CaptureOutput
    Record-CheckResult $name $result
    if($result.exitCode -ne 0){throw "Cannot resolve test output: $Project (exit=$($result.exitCode), timeout=$($result.timedOut))"}
    $path=($result.stdout -join [Environment]::NewLine).Trim()
    if(!$path){throw "Empty test output: $Project"}
    return $path
}
try{
    $selected=@($Only.Split(',') | ForEach-Object {$_.Trim().ToLowerInvariant()} | Where-Object {$_} | Select-Object -Unique)
    if($Only.Length -gt 0 -and $selected.Count -eq 0){throw 'Only must contain at least one suite name, or be empty for all suites.'}
    $unknown=@($selected | Where-Object {$_ -notin $names})
    if($unknown.Count -gt 0){throw "Unknown suite selection: $($unknown -join ', '). Available: $($names -join ', ')."}
    $testProject="$PSScriptRoot/RawLabWindows.Tests.csproj"
    Invoke-Check 'build' @('build',$testProject,'-c','Release','--no-incremental')
    $target=Resolve-Target $testProject
    foreach($name in @('sony2fuji.dll','raw.dll')){
        Copy-Item -LiteralPath (Join-Path $NativeArtifacts $name) -Destination $target -Force
    }
    $hdrDll=Join-Path $NativeArtifacts 'rawlab-hdr-display.dll'
    if(Test-Path -LiteralPath $hdrDll){Copy-Item -LiteralPath $hdrDll -Destination $target -Force}
    Get-ChildItem -LiteralPath $NativeArtifacts -File -Filter '*.dll' |
        Where-Object {$_.Name -match '^(vcruntime|msvcp|vcomp|concrt)'} |
        Copy-Item -Destination $target -Force
    Copy-Item (Join-Path $NativeArtifacts 'ExifTool') -Destination $target -Recurse -Force
    $hasAiModel=Test-Path (Join-Path $NativeArtifacts 'AI/DualDn/manifest.json')
    if($hasAiModel) {
        foreach($name in @('onnxruntime.dll','onnxruntime_providers_shared.dll','DirectML.dll')) { Copy-Item (Join-Path $NativeArtifacts $name) $target -Force }
        Copy-Item (Join-Path $NativeArtifacts 'AI') $target -Recurse -Force
    }
    $env:RAWLAB_TEST_REPO=$repo
    $env:RAWLAB_TEST_RAW=$RawPath
    $env:RAWLAB_TEST_DENOISE_RAW=$DenoiseRaw
    $env:RAWLAB_TEST_CLI=(Join-Path $NativeArtifacts 'sony2fuji.exe')
    $env:RAWLAB_TEST_RESULTS=$results
    foreach($name in $names){
        if($name -eq 'build'){continue}
        if($name -eq 'ai-window' -and !$hasAiModel){continue}
        Invoke-Check $name @('test',$testProject,'-c','Release','--no-build','--filter',"Suite=$name",'--logger','console;verbosity=normal')
    }
    $missing=@($selected | Where-Object {$_ -notin $summary.name})
    if($missing.Count -gt 0){throw "Selected suites did not run: $($missing -join ', ')."}
    if(@($summary | Where-Object {$_.exitCode -ne 0}).Count -gt 0){throw 'Some checks failed; inspect summary.json and individual logs.'}
}
catch{
    if(@($summary | Where-Object {$_.exitCode -ne 0}).Count -eq 0){$summary+=@{name='runner';exitCode=1;error=$_.Exception.Message}}
    throw
}
finally{
    foreach($key in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($key,$savedEnv[$key])}
    ConvertTo-Json -InputObject @($summary) -Depth 4 | Set-Content (Join-Path $results 'summary.json') -Encoding utf8
}
Write-Host 'PASS: Windows v08 targeted checks. Physical DPI, Narrator, Snap and hardware require separate evidence.'
