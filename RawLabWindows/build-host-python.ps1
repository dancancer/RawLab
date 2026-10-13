param([Parameter(Mandatory)][string]$Directory)
$ErrorActionPreference = 'Stop'
$python = Join-Path $Directory 'python.exe'
if (!(Test-Path $python)) {
    New-Item -ItemType Directory -Force $Directory | Out-Null
    $archive = Join-Path $Directory 'python-3.11.9-embed-amd64.zip'
    if (!(Test-Path $archive)) {
        Invoke-WebRequest 'https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip' -OutFile $archive -UseBasicParsing
    }
    if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne '009d6bf7e3b2ddca3d784fa09f90fe54336d5b60f0e0f305c37f400bf83cfd3b') {
        throw 'Python build-tool archive checksum mismatch.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $Directory -Force
}
$python
