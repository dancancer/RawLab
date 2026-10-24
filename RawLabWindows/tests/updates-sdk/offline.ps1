param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path (Split-Path $PSScriptRoot))
$out=[IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $out | Out-Null
if(Test-Path "$out/tools/vpk.exe") {
    $installed = dotnet tool list --tool-path "$out/tools"
    if(-not ($installed -match 'vpk\s+1\.2\.161\s')){throw 'Unexpected vpk version in fixture tools'}
} else {
    dotnet tool install vpk --version 1.2.161 --tool-path "$out/tools"
    if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
}
dotnet publish "$repo/RawLabWindows/tests/update-fixture/UpdateFixture.csproj" -c Release -o "$out/publish"
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
$feed=Join-Path $out ("feed-"+[Guid]::NewGuid().ToString('N'))
& "$out/tools/vpk.exe" pack --packId RawLab.Desktop --packVersion 0.9.1 --runtime win-x64 --packDir "$out/publish" --mainExe RawLab.exe --channel stable --outputDir $feed
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
dotnet run --project "$repo/RawLabWindows/tests/updates-sdk/UpdateSdkChecks.csproj" -c Release -- --offline $feed
exit $LASTEXITCODE
