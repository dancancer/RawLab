[CmdletBinding()]
param([string]$DotNet='dotnet',[ValidateRange(1,86400)][int]$TimeoutSeconds=300)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'RawLabWindows/tests/CheckProcess.ps1')
$results=Join-Path $repo 'build/ci/windows-models'
New-Item -ItemType Directory -Force $results|Out-Null
$summary=@()
[IO.File]::WriteAllText((Join-Path $results 'summary.json'),'[]')
$project=Join-Path $repo 'RawLabWindows/tests/RawLabWindows.Tests.csproj'
$checks=@(
    @{name='list-tests';args=@('test',$project,'-c','Release','--list-tests')}
    @{name='models';args=@('test',$project,'-c','Release','--no-build','--filter','Category=Model','--logger','console;verbosity=normal')}
)
try {
    foreach($check in $checks) {
        $name=$check.name
        $result=Invoke-CheckProcess -Name $name -Executable $DotNet -Arguments $check.args -Directory $repo -Log (Join-Path $results ($name+'.log')) -TimeoutSeconds $TimeoutSeconds
        $summary+=@{name=$name;exitCode=$result.exitCode;timedOut=$result.timedOut;durationSeconds=$result.durationSeconds;log=($name+'.log')}
        ConvertTo-Json -InputObject @($summary) -Depth 4|Set-Content (Join-Path $results 'summary.json') -Encoding utf8
        if($result.exitCode -ne 0){throw "Windows model check '$name' failed."}
    }
}
catch {
    if(@($summary|Where-Object {$_.exitCode -ne 0}).Count -eq 0){$summary+=@{name='runner';exitCode=1;error=$_.Exception.Message}}
    throw
}
finally {ConvertTo-Json -InputObject @($summary) -Depth 4|Set-Content (Join-Path $results 'summary.json') -Encoding utf8}
Write-Host 'PASS: Windows model checks (no WPF or native rendering).'
