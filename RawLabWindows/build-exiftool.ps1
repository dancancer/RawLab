[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$cache = Join-Path $repo 'build/tools'
$archive = Join-Path $cache 'exiftool-13.59_64.zip'
$sha256 = '577257dd22baebe77157d905792d6ed2c5916cd03aa627f40b2175db12110ac6'
New-Item -ItemType Directory -Force $cache | Out-Null
# This is the Windows packager linked by exiftool.org. Its ZIP differs from
# the SourceForge distribution, so pin this archive's own SHA-256.
if (!(Test-Path $archive) -or (Get-FileHash $archive -Algorithm SHA256).Hash -ne $sha256) {
    Invoke-WebRequest 'https://oliverbetz.de/cms/files/Artikel/ExifTool-for-Windows/exiftool-13.59_64.zip' -OutFile $archive
}
if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne $sha256) { throw 'ExifTool archive checksum mismatch.' }
$destination = Join-Path $Output 'ExifTool'
New-Item -ItemType Directory -Force $destination | Out-Null
Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force
# Preserve -config "": Windows PowerShell 5.1 drops empty native arguments.
$process = New-Object System.Diagnostics.Process
$process.StartInfo.FileName = Join-Path $destination 'ExifTool.exe'
$process.StartInfo.Arguments = '-config "" -ver'
$process.StartInfo.UseShellExecute = $false
$process.StartInfo.RedirectStandardOutput = $true
try {
    $process.Start() | Out-Null
    $version = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0 -or $version.Trim() -ne '13.59') { throw 'Unexpected ExifTool version.' }
} finally {
    $process.Dispose()
}
# Keep the complete distribution, including Perl, licenses and source files.
