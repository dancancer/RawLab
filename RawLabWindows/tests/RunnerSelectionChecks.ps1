[CmdletBinding()]
param([string]$Output)
$ErrorActionPreference='Stop'
if(!$Output){$Output=Join-Path ([IO.Path]::GetTempPath()) ('rawlab-runner-'+[guid]::NewGuid().ToString('N'))}
$root=Join-Path ([IO.Path]::GetFullPath($Output)) ([guid]::NewGuid().ToString('N').Substring(0,8)+' runner cases')
$tests=Join-Path $root 'RawLabWindows/tests';New-Item -ItemType Directory -Force $tests | Out-Null
$runner=Join-Path $tests 'run-v08.ps1';Copy-Item (Join-Path $PSScriptRoot 'run-v08.ps1') $runner
Copy-Item (Join-Path $PSScriptRoot 'CheckProcess.ps1') $tests
$native=Join-Path $root 'native';New-Item -ItemType Directory -Force (Join-Path $native 'ExifTool') | Out-Null
foreach($name in @('sony2fuji.dll','raw.dll','ExifTool/sentinel')){[IO.File]::WriteAllText((Join-Path $native $name),'private test artifact')}
$stub=Join-Path $root 'dotnet-stub.cmd'
[IO.File]::WriteAllText($stub,"@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0dotnet-stub.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n")
[IO.File]::WriteAllText((Join-Path $root 'dotnet-stub.ps1'),@'
$ErrorActionPreference='Stop'
ConvertTo-Json -InputObject @($args) -Compress | Add-Content -LiteralPath $env:RAWLAB_RUNNER_CALLS
if(($env:RAWLAB_RUNNER_FAIL -eq 'build' -and $args[0] -eq 'build') -or
   ($env:RAWLAB_RUNNER_FAIL -eq 'msbuild' -and $args[0] -eq 'msbuild') -or
   ($env:RAWLAB_RUNNER_FAIL -eq 'about' -and ($args -contains 'Suite=about'))){exit 7}
if($env:RAWLAB_RUNNER_FAIL -eq 'timeout' -and ($args -contains 'Suite=about')){
    Write-Output 'suite reached timeout probe';Start-Sleep -Seconds 90
}
if($env:RAWLAB_RUNNER_FAIL -eq 'msbuild-timeout' -and $args[0] -eq 'msbuild'){Start-Sleep -Seconds 90}
if($args[0] -eq 'msbuild'){
    $path=Join-Path $env:RAWLAB_RUNNER_TARGET 'main'
    New-Item -ItemType Directory -Force $path | Out-Null
    Write-Output ($path+[IO.Path]::DirectorySeparatorChar)
}
if($args[0] -eq 'test'){
    if([string]::IsNullOrWhiteSpace($env:RAWLAB_APPDATA_ROOT)){
        throw 'RAWLAB_APPDATA_ROOT must be set before dotnet test.'
    }
    $trxArg=$args | Where-Object {$_ -like 'trx;LogFileName=*'} | Select-Object -First 1
    if($trxArg){
        $trxPath=$trxArg.Substring('trx;LogFileName='.Length)
        New-Item -ItemType Directory -Force (Split-Path $trxPath -Parent) | Out-Null
        if($env:RAWLAB_RUNNER_FAIL -eq 'zero-tests' -and ($args -contains 'Suite=about')){
            [IO.File]::WriteAllText($trxPath,'<TestRun><ResultSummary outcome="Completed"><Counters total="0" executed="0" passed="0" failed="0" /></ResultSummary></TestRun>')
        } elseif(!($env:RAWLAB_RUNNER_FAIL -eq 'missing-trx' -and ($args -contains 'Suite=about'))){
            [IO.File]::WriteAllText($trxPath,'<TestRun><ResultSummary outcome="Completed"><Counters total="1" executed="1" passed="1" failed="0" /></ResultSummary></TestRun>')
        }
    }
}
exit 0
'@)
$names=@('build','editing','looks','denoise-model','localization','updates','comparison','about','default-isolation','localization-admission','profile-isolation','localization-ui','unhandled-ui','entry-selection','ai-panel','editor-shell','geometry','master-recipes','rendered-dng','denoise','lens','agent-recipe','raster','batch-selection','recipe-white-balance','atmosphere-render','tone-render','grading-render','curve-render','hsl-target-render','inspection-suite','first-preview','hdr-look-import')
$saved=@{};foreach($key in @('RAWLAB_RUNNER_CALLS','RAWLAB_RUNNER_TARGET','RAWLAB_RUNNER_FAIL','RAWLAB_APPDATA_ROOT')){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
$checks=0;$index=0
function Check([bool]$Success,[string]$Name){if(!$Success){throw $Name};$script:checks++;Write-Output "PASS $Name"}
function Run([string]$Selection,[string]$Failure,[string]$FixtureName='fixture.arw'){
    $script:index++
    $env:RAWLAB_RUNNER_CALLS=Join-Path $root ("calls-$index.jsonl");$env:RAWLAB_RUNNER_FAIL=$Failure
    [Environment]::SetEnvironmentVariable('RAWLAB_APPDATA_ROOT',$null)
    $results=Join-Path $root 'build/windows-v08-results';New-Item -ItemType Directory -Force $results | Out-Null
    $summary=Join-Path $results 'summary.json';[IO.File]::WriteAllText($summary,'[{"name":"old-success","exitCode":0}]')
    $log=Join-Path $root ("case-$index.log");$preference=$ErrorActionPreference
    $blocked=Join-Path $results 'about.log';Remove-Item -LiteralPath $blocked -Recurse -Force -ErrorAction SilentlyContinue
    if($Failure -eq 'log'){New-Item -ItemType Directory -Path $blocked | Out-Null}
    $dotnet=if($Failure -eq 'missing-command'){Join-Path $root 'missing.cmd'}else{$stub}
    $artifacts=if($Failure -eq 'missing-artifacts'){Join-Path $root 'missing-native'}else{$native}
    try{
        $ErrorActionPreference='Continue'
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-RawPath',(Join-Path $root $FixtureName),'-NativeArtifacts',$artifacts,'-DotNet',$dotnet)
        if($Selection.Length -gt 0){$arguments+=@('-Only',$Selection)}
        if($Failure -in @('timeout','msbuild-timeout')){$arguments+=@('-CheckTimeoutSeconds','3')}
        & powershell.exe @arguments 2>&1 | Out-File $log -Encoding utf8 -Width 4096
        $code=$LASTEXITCODE
    }finally{$ErrorActionPreference=$preference}
    $calls=@();if(Test-Path -LiteralPath $env:RAWLAB_RUNNER_CALLS){$calls=@(Get-Content -LiteralPath $env:RAWLAB_RUNNER_CALLS)}
    [pscustomobject]@{Code=$code;Rows=@(Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json | ForEach-Object {$_});Calls=$calls;Text=(Get-Content $log -Raw)}
}
try{
    $env:RAWLAB_RUNNER_TARGET=Join-Path $root 'targets'
    foreach($selection in @('profile-isolatoin','about,profile-isolatoin','build-typo',' , , ')){
        $result=Run $selection ''
        Check ($result.Code -ne 0 -and $result.Text -notmatch 'PASS: Windows v08') "Invalid selection fails without PASS: $selection"
        Check ($result.Calls.Count -eq 0) "Invalid selection is rejected before any DotNet work: $selection"
        Check (@($result.Rows | Where-Object {$_.exitCode -ne 0}).Count -gt 0 -and @($result.Rows | Where-Object {$_.name -eq 'old-success'}).Count -eq 0) "Invalid selection replaces stale success summary: $selection"
    }
    foreach($selection in @(' about ','ABOUT','about,, ,ABOUT')){
        $result=Run $selection ''
        Check ($result.Code -eq 0 -and ($result.Rows.name -join ',') -eq 'build,target-RawLabWindows.Tests,about') "Trim, case and duplicates select exactly one suite: $selection"
        Check (@($result.Rows | Where-Object {$_.log -ne ($_.name+'.log')}).Count -eq 0) "Summary log paths stay valid beside downloaded logs: $selection"
        Check ($result.Calls.Count -eq 3) "Only one build, one target query and the selected suite run: $selection"
        $last=ConvertFrom-Json $result.Calls[-1]
        Check ($last[0] -eq 'test' -and $last[1] -like '*RawLabWindows.Tests.csproj' -and ($last -contains 'Suite=about')) "Selected suite uses dotnet test Suite filter: $selection"
    }
    $result=Run '' ''
    $expected=@('build','target-RawLabWindows.Tests')+@($names[1..($names.Count-1)])
    Check ($result.Code -eq 0 -and ($result.Rows.name -join ',') -eq ($expected -join ',') -and @($result.Rows | Where-Object {$_.exitCode -ne 0}).Count -eq 0 -and $result.Calls.Count -eq $names.Count+1) 'Empty selection runs the complete declared suite list successfully'
    $result=Run 'batch-selection' ''
    Check ($result.Code -eq 0 -and ($result.Rows.name -join ',') -eq 'build,target-RawLabWindows.Tests,batch-selection') 'Batch selection runs alone after WPF build and layout prerequisites'
    $last=ConvertFrom-Json $result.Calls[-1]
    Check ($last[0] -eq 'test' -and $last[1] -like '*RawLabWindows.Tests.csproj' -and ($last -contains 'Suite=batch-selection')) 'Batch selection invokes dotnet test with Suite=batch-selection'
    foreach($name in @('sony2fuji.dll','raw.dll','ExifTool/sentinel')) {
        Check (Test-Path (Join-Path $env:RAWLAB_RUNNER_TARGET "main/$name")) "Batch selection receives its runtime dependency: $name"
    }
    $result=Run 'ai-panel' ''
    Check ($result.Code -eq 0 -and 'ai-panel' -in $result.Rows.name -and ((ConvertFrom-Json $result.Calls[-1]) -contains 'Suite=ai-panel')) 'AI panel is selectable without an installed model'
    $result=Run 'ai-window' ''
    Check ($result.Code -ne 0 -and $result.Text -match 'Selected suites did not run: ai-window' -and 'ai-window' -notin $result.Rows.name) 'Explicit AI window selection cannot pass without its model'
    $result=Run 'x3f' '' 'fixture.arw'
    Check ($result.Code -ne 0 -and $result.Text -match 'Selected suites did not run: x3f') 'Explicit x3f selection fails without an X3F fixture'
    $result=Run 'x3f' '' 'fixture.x3f'
    Check ($result.Code -eq 0 -and 'x3f' -in $result.Rows.name) 'X3F fixture enables explicit x3f suite'
    $result=Run 'hdr-workflow' '' 'fixture.arw'
    Check ($result.Code -ne 0 -and $result.Text -match 'Selected suites did not run: hdr-workflow') 'Explicit hdr-workflow selection fails without an HDR container fixture'
    $result=Run 'hdr-workflow' '' 'fixture.jpg'
    Check ($result.Code -eq 0 -and 'hdr-workflow' -in $result.Rows.name) 'HDR JPEG fixture enables explicit hdr-workflow suite'
    $model=Join-Path $native 'AI/DualDn';New-Item -ItemType Directory -Force $model | Out-Null
    foreach($name in @('AI/DualDn/manifest.json','onnxruntime.dll','onnxruntime_providers_shared.dll','DirectML.dll')){[IO.File]::WriteAllText((Join-Path $native $name),'private AI test artifact')}
    $result=Run 'ai-window' ''
    Check ($result.Code -eq 0 -and 'ai-window' -in $result.Rows.name -and ((ConvertFrom-Json $result.Calls[-1]) -contains 'Suite=ai-window')) 'Installed model enables the explicitly selected AI window suite'
    $destination=Join-Path $env:RAWLAB_RUNNER_TARGET 'main'
    Check ((Test-Path (Join-Path $destination 'AI/DualDn/manifest.json')) -and (Test-Path (Join-Path $destination 'DirectML.dll'))) 'AI model and runtime reach the test output'
    foreach($failure in @('build','msbuild','about','zero-tests','missing-trx','log','missing-command','missing-artifacts','timeout','msbuild-timeout')){
        $result=Run 'about,profile-isolation' $failure
        Check ($result.Code -ne 0 -and $result.Text -notmatch 'PASS: Windows v08') "External failure stays nonzero: $failure"
        Check (@($result.Rows | Where-Object {$_.exitCode -ne 0}).Count -gt 0 -and @($result.Rows | Where-Object {$_.name -eq 'old-success'}).Count -eq 0) "Early/suite failure replaces stale summary: $failure"
        if($failure -in @('build','about')){Check (@($result.Rows | Where-Object {$_.name -eq $failure -and $_.exitCode -eq 7}).Count -eq 1) "Summary preserves native exit code: $failure"}
        if($failure -in @('zero-tests','missing-trx')){Check (@($result.Rows | Where-Object {$_.name -eq 'about' -and $_.exitCode -ne 0}).Count -eq 1) "Zero-match or missing TRX marks the suite nonzero: $failure"}
        if($failure -in @('about','zero-tests','missing-trx','timeout')){Check (@($result.Rows | Where-Object {$_.name -eq 'profile-isolation' -and $_.exitCode -eq 0}).Count -eq 1) "A failed suite does not hide subsequent selected suite results: $failure"}
        if($failure -eq 'timeout'){Check (@($result.Rows | Where-Object {$_.name -eq 'about' -and $_.exitCode -eq 124 -and $_.timedOut}).Count -eq 1 -and $result.Text -match 'TIMEOUT') 'Timeout remains nonzero with an explicit summary and live diagnostic'}
        if($failure -in @('msbuild','msbuild-timeout')) {
            $query=$result.Rows|Where-Object {$_.name -eq 'target-RawLabWindows.Tests'}
            $expectedCode=if($failure -eq 'msbuild'){7}else{124}
            Check ($query.exitCode -eq $expectedCode -and $query.pid -gt 0 -and $query.durationSeconds -gt 0 -and $query.timedOut -eq ($failure -eq 'msbuild-timeout') -and 'about' -notin $result.Rows.name) "Failed target query preserves its process evidence and stops dependent tests: $failure"
        }
    }
    Write-Output "PASS $checks runner selection checks; fixtures: $root"
}
finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
# 失败探针会留下非零 LASTEXITCODE；只有全部断言通过才向 CI 返回成功。
exit 0
