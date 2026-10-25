[CmdletBinding()]
param([string]$DotNet='dotnet',[ValidateRange(1,86400)][int]$TimeoutSeconds=300)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'RawLabWindows/tests/CheckProcess.ps1')
$results=Join-Path $repo 'build/ci/windows-models'
New-Item -ItemType Directory -Force $results|Out-Null
$summary=@()
[IO.File]::WriteAllText((Join-Path $results 'summary.json'),'[]')
$projects=[ordered]@{
    editing='editing/EditWorkflow.Tests.csproj'
    denoise='denoise/DenoiseSettingsTests.csproj'
    localization='localization/LocalizationChecks.csproj'
    updates='updates/UpdateChecks.csproj'
    updateSdk='updates-sdk/UpdateSdkChecks.csproj'
    usage='usage/UsageAnalytics.Tests.csproj'
}
try {
    foreach($name in $projects.Keys) {
        $project=Join-Path $repo ('RawLabWindows/tests/'+$projects[$name])
        $result=Invoke-CheckProcess -Name $name -Executable $DotNet -Arguments @('run','--project',$project,'-c','Release') -Directory $repo -Log (Join-Path $results ($name+'.log')) -TimeoutSeconds $TimeoutSeconds
        $summary+=@{name=$name;exitCode=$result.exitCode;timedOut=$result.timedOut;durationSeconds=$result.durationSeconds;log=($name+'.log')}
        ConvertTo-Json -InputObject @($summary) -Depth 4|Set-Content (Join-Path $results 'summary.json') -Encoding utf8
    }
    if(@($summary|Where-Object {$_.exitCode -ne 0}).Count){throw 'Some Windows model checks failed.'}
}
catch {
    $summary+=@{name='runner';exitCode=1;error=$_.Exception.Message}
    throw
}
finally {ConvertTo-Json -InputObject @($summary) -Depth 4|Set-Content (Join-Path $results 'summary.json') -Encoding utf8}
Write-Host 'PASS: Windows model checks (no WPF or native rendering).'
