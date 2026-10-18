[CmdletBinding()]
param([string]$Output)
$ErrorActionPreference='Stop'
if(!$Output){$Output=Join-Path ([IO.Path]::GetTempPath()) ('rawlab-runner-'+[guid]::NewGuid().ToString('N'))}
$root=Join-Path ([IO.Path]::GetFullPath($Output)) ([guid]::NewGuid().ToString('N').Substring(0,8)+' runner cases')
$tests=Join-Path $root 'RawLabWindows/tests';New-Item -ItemType Directory -Force $tests | Out-Null
$runner=Join-Path $tests 'run-v08.ps1';Copy-Item (Join-Path $PSScriptRoot 'run-v08.ps1') $runner
$native=Join-Path $root 'native';New-Item -ItemType Directory -Force (Join-Path $native 'ExifTool') | Out-Null
foreach($name in @('sony2fuji.dll','raw.dll','ExifTool/sentinel')){[IO.File]::WriteAllText((Join-Path $native $name),'private test artifact')}
$stub=Join-Path $root 'dotnet-stub.cmd'
[IO.File]::WriteAllText($stub,"@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0dotnet-stub.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n")
[IO.File]::WriteAllText((Join-Path $root 'dotnet-stub.ps1'),@'
$ErrorActionPreference='Stop'
ConvertTo-Json -InputObject @($args) -Compress | Add-Content -LiteralPath $env:RAWLAB_RUNNER_CALLS
if(($env:RAWLAB_RUNNER_FAIL -eq 'build' -and $args[0] -eq 'build') -or
   ($env:RAWLAB_RUNNER_FAIL -eq 'msbuild' -and $args[0] -eq 'msbuild') -or
   ($env:RAWLAB_RUNNER_FAIL -eq 'about' -and $args -contains '--about')){exit 7}
if($args[0] -eq 'msbuild'){
    $name=if($args[1] -like '*localization-ui*'){'ui'}else{'main'}
    $path=Join-Path $env:RAWLAB_RUNNER_TARGET $name
    New-Item -ItemType Directory -Force $path | Out-Null
    Write-Output ($path+[IO.Path]::DirectorySeparatorChar)
}
exit 0
'@)
$names=@('build','build-localization-ui','editing','looks','denoise-model','localization','updates','about','default-isolation','localization-admission','profile-isolation','localization-ui','status-layout','appearance','editor-shell','ui-details','geometry','transform-ui','editor-review','tool-groups','photo-features','interactions','master-recipes','rendered-dng','denoise','lens','agent-recipe','raster','comparison-default')
$saved=@{};foreach($key in @('RAWLAB_RUNNER_CALLS','RAWLAB_RUNNER_TARGET','RAWLAB_RUNNER_FAIL')){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
$checks=0;$index=0
function Check([bool]$Success,[string]$Name){if(!$Success){throw $Name};$script:checks++;Write-Output "PASS $Name"}
function Run([string]$Selection,[string]$Failure){
    $script:index++
    $env:RAWLAB_RUNNER_CALLS=Join-Path $root ("calls-$index.jsonl");$env:RAWLAB_RUNNER_FAIL=$Failure
    $results=Join-Path $root 'build/windows-v08-results';New-Item -ItemType Directory -Force $results | Out-Null
    $summary=Join-Path $results 'summary.json';[IO.File]::WriteAllText($summary,'[{"name":"old-success","exitCode":0}]')
    $log=Join-Path $root ("case-$index.log");$preference=$ErrorActionPreference
    $blocked=Join-Path $results 'about.log';Remove-Item -LiteralPath $blocked -Recurse -Force -ErrorAction SilentlyContinue
    if($Failure -eq 'log'){New-Item -ItemType Directory -Path $blocked | Out-Null}
    $dotnet=if($Failure -eq 'missing-command'){Join-Path $root 'missing.cmd'}else{$stub}
    $artifacts=if($Failure -eq 'missing-artifacts'){Join-Path $root 'missing-native'}else{$native}
    try{
        $ErrorActionPreference='Continue'
        $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,'-RawPath',(Join-Path $root 'fixture.arw'),'-NativeArtifacts',$artifacts,'-DotNet',$dotnet)
        if($Selection.Length -gt 0){$arguments+=@('-Only',$Selection)}
        & powershell.exe @arguments 2>&1 | Out-File $log -Encoding utf8 -Width 4096
        $code=$LASTEXITCODE
    }finally{$ErrorActionPreference=$preference}
    $calls=@();if(Test-Path -LiteralPath $env:RAWLAB_RUNNER_CALLS){$calls=@(Get-Content -LiteralPath $env:RAWLAB_RUNNER_CALLS)}
    [pscustomobject]@{Code=$code;Rows=@(Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json);Calls=$calls;Text=(Get-Content $log -Raw)}
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
        Check ($result.Code -eq 0 -and ($result.Rows.name -join ',') -eq 'build,build-localization-ui,about') "Trim, case and duplicates select exactly one suite: $selection"
        Check ($result.Calls.Count -eq 5) "Only two builds, two target queries and the selected suite run: $selection"
        $last=ConvertFrom-Json $result.Calls[-1]
        Check ($last[1] -eq '--about' -and $last[0] -like '*RawLabWindows.Tests.dll') "Selected suite uses its actual DLL mode: $selection"
    }
    $result=Run '' ''
    Check ($result.Code -eq 0 -and ($result.Rows.name -join ',') -eq ($names -join ',') -and @($result.Rows | Where-Object {$_.exitCode -ne 0}).Count -eq 0 -and $result.Calls.Count -eq $names.Count+2) 'Empty selection runs the complete declared suite list successfully'
    foreach($failure in @('build','msbuild','about','log','missing-command','missing-artifacts')){
        $result=Run 'about,profile-isolation' $failure
        Check ($result.Code -ne 0 -and $result.Text -notmatch 'PASS: Windows v08') "External failure stays nonzero: $failure"
        Check (@($result.Rows | Where-Object {$_.exitCode -ne 0}).Count -gt 0 -and @($result.Rows | Where-Object {$_.name -eq 'old-success'}).Count -eq 0) "Early/suite failure replaces stale summary: $failure"
        if($failure -in @('build','about')){Check (@($result.Rows | Where-Object {$_.name -eq $failure -and $_.exitCode -eq 7}).Count -eq 1) "Summary preserves native exit code: $failure"}
        if($failure -eq 'about'){Check (@($result.Rows | Where-Object {$_.name -eq 'profile-isolation' -and $_.exitCode -eq 0}).Count -eq 1) 'A failed suite does not hide subsequent selected suite results'}
    }
    Write-Output "PASS $checks runner selection checks; fixtures: $root"
}
finally{foreach($key in $saved.Keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
