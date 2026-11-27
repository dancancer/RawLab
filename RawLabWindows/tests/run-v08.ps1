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
$names=@('build','editing','looks','denoise-model','localization','updates','comparison','about','default-isolation','localization-admission','profile-isolation','localization-ui','unhandled-ui','entry-selection','ai-panel','ai-window','editor-shell','geometry','master-recipes','rendered-dng','denoise','lens','agent-recipe','raster','batch-selection','recipe-white-balance','atmosphere-render','tone-render','grading-render','curve-render','hsl-target-render','inspection-suite','x3f','hdr-workflow','first-preview','hdr-look-import','agent-hot-reload')
[IO.File]::WriteAllText((Join-Path $results 'summary.json'),'[]')
$savedEnv=@{}
foreach($key in @('RAWLAB_TEST_REPO','RAWLAB_TEST_RAW','RAWLAB_TEST_DENOISE_RAW','RAWLAB_TEST_CLI','RAWLAB_TEST_RESULTS','RAWLAB_APPDATA_ROOT')) {
    $savedEnv[$key]=[Environment]::GetEnvironmentVariable($key)
}
function Test-TrxExecution([string]$TrxPath) {
    if(!(Test-Path -LiteralPath $TrxPath -PathType Leaf)){
        return [pscustomobject]@{ok=$false;reason="Missing TRX report: $TrxPath"}
    }
    [xml]$doc=Get-Content -LiteralPath $TrxPath -Raw
    $counters=$doc.TestRun.ResultSummary.Counters
    if($null -eq $counters){
        return [pscustomobject]@{ok=$false;reason="TRX report missing ResultSummary Counters: $TrxPath"}
    }
    $total=0;$executed=0;$passed=0;$failed=0
    [void][int]::TryParse([string]$counters.total,[ref]$total)
    [void][int]::TryParse([string]$counters.executed,[ref]$executed)
    [void][int]::TryParse([string]$counters.passed,[ref]$passed)
    [void][int]::TryParse([string]$counters.failed,[ref]$failed)
    if($total -le 0 -or $executed -le 0 -or $passed -le 0 -or $failed -gt 0){
        return [pscustomobject]@{ok=$false;reason="Zero or failing tests executed (total=$total, executed=$executed, passed=$passed, failed=$failed)"}
    }
    return [pscustomobject]@{ok=$true;total=$total;executed=$executed;passed=$passed;failed=$failed}
}
function Record-CheckResult([string]$Name,$Result,[string]$ErrorMessage='') {
    $entry=@{name=$Name;exitCode=$Result.exitCode;log=($Name+'.log');timedOut=$Result.timedOut;durationSeconds=$Result.durationSeconds;pid=$Result.pid}
    if($ErrorMessage){$entry.error=$ErrorMessage}
    $script:summary+=$entry
    ConvertTo-Json -InputObject @($script:summary) -Depth 4 | Set-Content (Join-Path $results 'summary.json') -Encoding utf8
}
function Invoke-Check([string]$Name,[string[]]$Arguments) {
    if($Name -ne 'build' -and $selected.Count -gt 0 -and $Name -notin $selected){return}
    $log=Join-Path $results ($Name+'.log')
    $trx=$null
    $effectiveArgs=$Arguments
    if($Name -ne 'build'){
        $trx=Join-Path $results ($Name+'.trx')
        if(Test-Path -LiteralPath $trx){Remove-Item -LiteralPath $trx -Force}
        $effectiveArgs=$Arguments + @('--logger',"trx;LogFileName=$trx")
    }
    $result=Invoke-CheckProcess -Name $Name -Executable $DotNet -Arguments $effectiveArgs -Directory $repo -Log $log -TimeoutSeconds $CheckTimeoutSeconds
    $errorMessage=''
    if($trx -and $result.exitCode -eq 0){
        $trxCheck=Test-TrxExecution $trx
        if(!$trxCheck.ok){
            $result=[pscustomobject]@{exitCode=1;timedOut=$result.timedOut;durationSeconds=$result.durationSeconds;pid=$result.pid;stdout=$result.stdout}
            $errorMessage=$trxCheck.reason
            Add-Content -LiteralPath $log -Value ("[$Name] ERROR: $errorMessage")
            Write-Host "[$Name] ERROR: $errorMessage"
        }
    }
    Record-CheckResult $Name $result $errorMessage
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
    # AI-enabled builds without bundled models still link ONNX Runtime / DirectML DLLs into sony2fuji.dll.
    foreach($name in @('onnxruntime.dll','onnxruntime_providers_shared.dll','DirectML.dll')) {
        $dll=Join-Path $NativeArtifacts $name
        if(Test-Path -LiteralPath $dll -PathType Leaf){Copy-Item -LiteralPath $dll -Destination $target -Force}
    }
    $hasAiModel=Test-Path (Join-Path $NativeArtifacts 'AI/DualDn/manifest.json')
    if($hasAiModel) {
        Copy-Item (Join-Path $NativeArtifacts 'AI') $target -Recurse -Force
    }
    if([string]::IsNullOrWhiteSpace($env:RAWLAB_APPDATA_ROOT)){
        $isolatedAppData=Join-Path $results 'appdata'
        New-Item -ItemType Directory -Force $isolatedAppData | Out-Null
        $env:RAWLAB_APPDATA_ROOT=$isolatedAppData
    }
    $env:RAWLAB_TEST_REPO=$repo
    $env:RAWLAB_TEST_RAW=$RawPath
    $env:RAWLAB_TEST_DENOISE_RAW=$DenoiseRaw
    $env:RAWLAB_TEST_CLI=(Join-Path $NativeArtifacts 'sony2fuji.exe')
    $env:RAWLAB_TEST_RESULTS=$results
    $rawExtension=[IO.Path]::GetExtension($RawPath)
    $isX3f=$rawExtension -ieq '.x3f'
    $isHdrContainer=$rawExtension -in @('.jpg','.jpeg','.heic','.heif')
    foreach($name in $names){
        if($name -eq 'build'){continue}
        if($name -eq 'ai-window' -and !$hasAiModel){continue}
        if($name -eq 'x3f' -and !$isX3f){continue}
        if($name -eq 'hdr-workflow' -and !$isHdrContainer){continue}
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
