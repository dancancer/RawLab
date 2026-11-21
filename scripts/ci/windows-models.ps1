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
$modelsTrx=Join-Path $results 'models.trx'
$savedAppDataRoot=[Environment]::GetEnvironmentVariable('RAWLAB_APPDATA_ROOT')
if([string]::IsNullOrWhiteSpace($savedAppDataRoot)){
    $isolatedAppData=Join-Path $results 'appdata'
    New-Item -ItemType Directory -Force $isolatedAppData|Out-Null
    $env:RAWLAB_APPDATA_ROOT=$isolatedAppData
}
$checks=@(
    @{name='list-tests';args=@('test',$project,'-c','Release','--list-tests');capture=$true}
    @{name='models';args=@('test',$project,'-c','Release','--no-build','--filter','Category=Model','--logger','console;verbosity=normal','--logger',"trx;LogFileName=$modelsTrx");trx=$modelsTrx}
)
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
try {
    foreach($check in $checks) {
        $name=$check.name
        if($check.trx -and (Test-Path -LiteralPath $check.trx)){Remove-Item -LiteralPath $check.trx -Force}
        $capture=[bool]$check.capture
        $result=Invoke-CheckProcess -Name $name -Executable $DotNet -Arguments $check.args -Directory $repo -Log (Join-Path $results ($name+'.log')) -TimeoutSeconds $TimeoutSeconds -CaptureOutput:$capture
        $exitCode=$result.exitCode
        $entry=@{name=$name;exitCode=$exitCode;timedOut=$result.timedOut;durationSeconds=$result.durationSeconds;log=($name+'.log')}
        if($exitCode -eq 0 -and $name -eq 'list-tests') {
            $listed=@($result.stdout|Where-Object {$_ -match '^\s{4}\S'})
            if($listed.Count -le 0) {
                $exitCode=1
                $entry.exitCode=1
                $entry.error='dotnet test --list-tests discovered zero tests.'
            } else {
                $entry.discovered=$listed.Count
            }
        }
        if($exitCode -eq 0 -and $check.trx) {
            $trxCheck=Test-TrxExecution $check.trx
            if(!$trxCheck.ok) {
                $exitCode=1
                $entry.exitCode=1
                $entry.error=$trxCheck.reason
            } else {
                $entry.total=$trxCheck.total
                $entry.executed=$trxCheck.executed
                $entry.passed=$trxCheck.passed
            }
        }
        $summary+=$entry
        ConvertTo-Json -InputObject @($summary) -Depth 4|Set-Content (Join-Path $results 'summary.json') -Encoding utf8
        if($exitCode -ne 0){
            $detail=if($entry.error){" ($($entry.error))"}else{''}
            throw "Windows model check '$name' failed$detail."
        }
    }
}
catch {
    if(@($summary|Where-Object {$_.exitCode -ne 0}).Count -eq 0){$summary+=@{name='runner';exitCode=1;error=$_.Exception.Message}}
    throw
}
finally {
    [Environment]::SetEnvironmentVariable('RAWLAB_APPDATA_ROOT',$savedAppDataRoot)
    ConvertTo-Json -InputObject @($summary) -Depth 4|Set-Content (Join-Path $results 'summary.json') -Encoding utf8
}
Write-Host 'PASS: Windows model checks (no WPF or native rendering).'
