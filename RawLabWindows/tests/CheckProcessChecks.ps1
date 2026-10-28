[CmdletBinding()]
param([string]$Output)
$ErrorActionPreference='Stop'
if(!$Output){$Output=Join-Path ([IO.Path]::GetTempPath()) ('rawlab-process-'+[guid]::NewGuid().ToString('N'))}
$root=Join-Path ([IO.Path]::GetFullPath($Output)) ([guid]::NewGuid().ToString('N')+' process checks')
New-Item -ItemType Directory -Force $root | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'CheckProcess.ps1') $root
$hostExe=(Get-Process -Id $PID).Path
[IO.File]::WriteAllText((Join-Path $root 'child.ps1'),@'
param([string]$Root,[string]$Mode,[string]$Value)
if($Mode -eq 'live') {
    [Console]::WriteLine('stdout ready: '+$Value);[Console]::Error.WriteLine('stderr ready')
    while(!(Test-Path (Join-Path $Root 'release'))){Start-Sleep -Milliseconds 50}
    exit 7
}
$child=Start-Process (Get-Process -Id $PID).Path -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 90"' -PassThru
@{parent=$PID;child=$child.Id}|ConvertTo-Json|Set-Content (Join-Path $Root 'pids.json')
[Console]::WriteLine('tree ready')
Start-Sleep -Seconds 90
'@)
[IO.File]::WriteAllText((Join-Path $root 'host.ps1'),@'
param([string]$Mode)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'CheckProcess.ps1')
$arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'child.ps1'),'-Root',$PSScriptRoot,'-Mode',$Mode,'-Value','space and trailing slash\')
$timeout=if($Mode -eq 'live'){15}else{2}
$result=Invoke-CheckProcess $Mode (Get-Process -Id $PID).Path $arguments $PSScriptRoot (Join-Path $PSScriptRoot ($Mode+'.log')) $timeout
$result|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot ($Mode+'.json'))
'@)
function Check([bool]$Value,[string]$Name){if(!$Value){throw $Name};Write-Output "PASS $Name"}
function Launch([string]$Mode) {
    $p=Start-Process $hostExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$root\host.ps1`" $Mode" -PassThru -RedirectStandardOutput "$root\$Mode-console.log" -RedirectStandardError "$root\$Mode-console.stderr.log"
    $null=$p.Handle;return $p
}
function Contains([string]$Path,[string]$Text){(Test-Path -LiteralPath $Path) -and (Get-Content -LiteralPath $Path -Raw) -like "*$Text*"}
$p=$null
try {
    . (Join-Path $root 'CheckProcess.ps1')
    $savedPath=$env:PATH
    try {
        foreach($name in @('first','second')) {
            $directory=Join-Path $root $name;New-Item -ItemType Directory -Force $directory|Out-Null
            [IO.File]::WriteAllText((Join-Path $directory 'rawlab-probe.cmd'),"@echo off`r`necho $name`r`nexit /b 0`r`n")
        }
        $env:PATH="$root\first;$root\second;$savedPath"
        $result=Invoke-CheckProcess 'path-order' 'rawlab-probe.cmd' @() $root "$root\path-order.log" 10 -CaptureOutput
        Check ($result.exitCode -eq 0 -and $result.stdout[0] -eq 'first') 'Multiple installed commands resolve to the first PATH match'
    }
    finally {$env:PATH=$savedPath}
    $p=Launch 'live';$watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt 10 -and !(Contains "$root\live-console.log" 'stderr ready')){Start-Sleep -Milliseconds 50}
    Check (!$p.HasExited -and !(Test-Path "$root\live.json")) 'Output is observable while the child is still running'
    foreach($path in @("$root\live.log","$root\live-console.log")) {
        Check ((Contains $path 'stdout ready: space and trailing slash\') -and (Contains $path 'stderr ready')) "Both streams reach $path before completion"
    }
    [IO.File]::WriteAllText("$root\release",'continue')
    Check ($p.WaitForExit(10000) -and $p.ExitCode -eq 0) 'Supervisor completes after child release'
    $result=Get-Content "$root\live.json" -Raw|ConvertFrom-Json
    Check ($result.exitCode -eq 7 -and !$result.timedOut) 'A child failure preserves its exit code'
    $p.Dispose();$p=Launch 'timeout'
    Check ($p.WaitForExit(10000) -and $p.ExitCode -eq 0) 'A hung child is bounded by the independent deadline'
    $result=Get-Content "$root\timeout.json" -Raw|ConvertFrom-Json
    $ids=Get-Content "$root\pids.json" -Raw|ConvertFrom-Json
    Check ($result.exitCode -eq 124 -and $result.timedOut -and $result.durationSeconds -lt 10) 'Timeout is explicit in the result'
    Check (!(Get-Process -Id $ids.parent,$ids.child -ErrorAction SilentlyContinue)) 'Timeout terminates only the owned child and grandchild'
    Check ((Contains "$root\timeout.log" 'tree ready') -and (Contains "$root\timeout-console.log" 'TIMEOUT')) 'Timeout preserves preceding output and a visible diagnostic'
    Write-Output "PASS process supervision checks; evidence: $root"
}
finally {
    if($null -ne $p){if(!$p.HasExited){& taskkill.exe /PID $p.Id /T /F 2>&1|Out-Null};$p.Dispose()}
}
