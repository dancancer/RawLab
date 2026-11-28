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
    # The packager's host times out now and then (it failed hosted checks more than once), so an
    # unmodified copy on the project's asset release is tried next; the checksum below gates either one.
    $sources = @(
        'https://oliverbetz.de/cms/files/Artikel/ExifTool-for-Windows/exiftool-13.59_64.zip',
        'https://github.com/dancancer/RawLab/releases/download/assets-v1/exiftool-13.59_64.zip'
    )
    $downloaded = $false
    foreach ($attempt in 1..3) {
        foreach ($source in $sources) {
            try {
                Invoke-WebRequest $source -OutFile $archive
                $downloaded = $true
                break
            } catch {
                $failure = $_
            }
        }
        if ($downloaded) { break }
        if ($attempt -eq 3) { throw $failure }
        Start-Sleep -Seconds (5 * $attempt)
    }
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
