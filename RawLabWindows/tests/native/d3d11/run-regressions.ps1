$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$build = Join-Path $repo 'build/d3d11-warp'

& ctest --test-dir $build -C Release --output-on-failure --no-tests=error
if ($LASTEXITCODE -ne 0) { throw 'D3D11 WARP regressions failed.' }

& (Join-Path $PSScriptRoot 'check-mutations.ps1')
