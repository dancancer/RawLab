$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
$build = Join-Path $repo 'build/d3d11-warp'
function Invoke-Checked([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed: $LASTEXITCODE" }
}
foreach ($mutation in @('no-reuse', 'no-trim')) {
    Invoke-Checked cmake @('-S', $PSScriptRoot, '-B', $build, '-A', 'x64', "-DD3D11_TEST_MUTATION=$mutation")
    Invoke-Checked cmake @('--build', $build, '--config', 'Release', '--target', 'd3d11_reuse_tests', '--parallel', '2')
    $output = & ctest --test-dir $build -C Release --output-on-failure --no-tests=error -R '^d3d11_reuse_warp$' 2>&1
    $status = $LASTEXITCODE
    $output | Write-Host
    $expected = if ($mutation -eq 'no-reuse') { 'C21: guided tiles reallocated warmed buffers' }
        else { 'C21: D3D11 idle pool exceeds 64 MiB after context release' }
    if ($status -eq 0 -or ($output -join "`n") -notmatch [regex]::Escape($expected)) {
        throw "C21 mutation $mutation did not fail at the intended assertion."
    }
    Write-Host "PASS: C21 mutation $mutation rejected at its behavioral assertion."
}
Invoke-Checked cmake @('-S', $PSScriptRoot, '-B', $build, '-A', 'x64', '-DD3D11_TEST_MUTATION=none')
Invoke-Checked cmake @('--build', $build, '--config', 'Release', '--target', 'd3d11_reuse_tests', '--parallel', '2')
Invoke-Checked ctest @('--test-dir', $build, '-C', 'Release', '--output-on-failure', '--no-tests=error', '-R', '^d3d11_reuse_warp$')
