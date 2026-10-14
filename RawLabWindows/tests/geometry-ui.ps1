param(
    [Parameter(Mandatory=$true)][string]$RawPath,
    [Parameter(Mandatory=$true)][string]$NativeDirectory,
    [Parameter(Mandatory=$true)][string]$ResultsDirectory,
    [string]$DotNet = 'dotnet'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $RawPath -PathType Leaf)) { throw 'Supply an existing RAW fixture.' }
if (Test-Path -LiteralPath $ResultsDirectory) { throw 'Use a fresh task-owned results directory.' }
foreach ($name in @('sony2fuji.dll','raw.dll')) {
    if (!(Test-Path -LiteralPath (Join-Path $NativeDirectory $name))) { throw "Missing existing native component: $name" }
}
$results = [IO.Path]::GetFullPath($ResultsDirectory)
$application = Join-Path $results 'application'
New-Item -ItemType Directory -Path $application -Force | Out-Null
$project = Join-Path $PSScriptRoot 'localization-ui/LocalizationUiChecks.csproj'
& $DotNet build $project -c Release -o $application -p:RestoreIgnoreFailedSources=true
if ($LASTEXITCODE -ne 0) { throw 'The native WPF harness build failed.' }
Copy-Item (Join-Path $NativeDirectory '*.dll') $application
# Interactive native WPF checks move the pointer for corner and interior drags.
# The harness copies the RAW and saves only to this private results directory.
& $DotNet (Join-Path $application 'LocalizationUiChecks.dll') --geometry-ui ([IO.Path]::GetFullPath($RawPath)) (Join-Path $results 'checks')
if ($LASTEXITCODE -ne 0) { throw 'Native WPF geometry checks failed; retain the private results for diagnosis.' }
Write-Host "Native WPF geometry results: $results/checks"
