[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$CacheDirectory, [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem
New-Item -ItemType Directory -Force $CacheDirectory,$Output | Out-Null
function Get-Package([string]$Name,[string]$Version,[string]$Sha256) {
    $file = Join-Path $CacheDirectory "$Name.$Version.nupkg"
    if (!(Test-Path -LiteralPath $file)) {
        $partial = "$file.download-$PID"
        try {
            Invoke-WebRequest "https://api.nuget.org/v3-flatcontainer/$Name/$Version/$Name.$Version.nupkg" -OutFile $partial -UseBasicParsing
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Sha256) { throw "Unexpected AI dependency archive: $Name" }
            Move-Item -LiteralPath $partial -Destination $file
        } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial } }
    }
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $Sha256) { throw "Corrupt AI dependency archive: $Name" }
    [IO.Compression.ZipFile]::OpenRead($file)
}
function Copy-Entry($Archive,[string]$Name,[string]$Relative) {
    $entry = $Archive.GetEntry($Name)
    if (!$entry) { throw "AI dependency resource missing: $Name" }
    $target = Join-Path $Output $Relative
    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$true)
}
$ort = Get-Package 'microsoft.ml.onnxruntime.directml' '1.23.0' 'a33ec2382b3c440bab74042a135733bb6e5085f293b908d3997688a58fe307e7'
try {
    foreach ($entry in $ort.Entries) {
        if ($entry.FullName.StartsWith('build/native/include/') -and $entry.Name) {
            Copy-Entry $ort $entry.FullName "include/$($entry.Name)"
        }
    }
    foreach ($name in @('onnxruntime.dll','onnxruntime.lib','onnxruntime_providers_shared.dll')) {
        Copy-Entry $ort "runtimes/win-x64/native/$name" "lib/$name"
    }
    foreach ($name in @('LICENSE','ThirdPartyNotices.txt')) { Copy-Entry $ort $name $name }
} finally { $ort.Dispose() }
$dml = Get-Package 'microsoft.ai.directml' '1.15.4' '4e7cb7ddce8cf837a7a75dc029209b520ca0101470fcdf275c1f49736a3615b9'
try {
    Copy-Entry $dml 'bin/x64-win/DirectML.dll' 'lib/DirectML.dll'
    foreach ($name in @('DirectML.h','DirectMLConfig.h')) { Copy-Entry $dml "include/$name" "include/$name" }
    foreach ($name in @('LICENSE.txt','LICENSE-CODE.txt','ThirdPartyNotices.txt')) { Copy-Entry $dml $name "licenses/DirectML/$name" }
} finally { $dml.Dispose() }
Set-Content -LiteralPath (Join-Path $Output 'VERSION_NUMBER') -Value '1.23.0' -Encoding Ascii
Write-Output ([IO.Path]::GetFullPath($Output))
