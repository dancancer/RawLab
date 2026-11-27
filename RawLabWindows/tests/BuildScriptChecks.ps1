[CmdletBinding()]
param([string]$BuildScript, [string]$RumTargets, [string]$SmokeScript)
$ErrorActionPreference='Stop'
if(!$BuildScript){$BuildScript=Join-Path (Split-Path $PSScriptRoot -Parent) 'build.ps1'}
if(!$RumTargets){$RumTargets=Join-Path (Split-Path $PSScriptRoot -Parent) 'RumSdk.targets'}
if(!$SmokeScript){$SmokeScript=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'scripts/release/smoke-windows-gpu.ps1'}
$tokens=$null
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($BuildScript,[ref]$tokens,[ref]$errors)
if($errors.Count -gt 0){throw "Build script parsing failed: $errors"}
$buildCommands=@($ast.FindAll({param($node)
    $node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Invoke-Checked' -and
    $node.CommandElements.Count -ge 3 -and
    $node.CommandElements[2].Extent.Text.Contains("'build'") -and
    $node.CommandElements[2].Extent.Text.Contains('RawLabWindows.Tests.csproj')
},$true))
if($buildCommands.Count -ne 1){throw "Expected one executable managed-test build command; parsed $($buildCommands.Count) with code page $([Text.Encoding]::Default.CodePage)."}
if(@([IO.File]::ReadAllBytes($BuildScript) | Where-Object {$_ -gt 127}).Count -gt 0){throw 'Keep build.ps1 ASCII-safe for Windows PowerShell 5.1 ANSI decoding.'}
Write-Output 'PASS Windows PowerShell parses the managed-test build before output discovery.'
# The release package carries the pinned RUM SDK: build.ps1 and the project must pin the same archive.
$pins=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$rumSdkSha256'},$true))
$projectPin=([xml](Get-Content -LiteralPath $RumTargets -Raw)).Project.PropertyGroup.RawLabRumSdkZipSha256 | Where-Object { $_ } | Select-Object -First 1
if($pins.Count -ne 1 -or $pins[0].Right.Extent.Text.Trim("'") -ne $projectPin){throw "build.ps1 and RumSdk.targets must pin the same RUM SDK archive SHA-256."}
$publish=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$publish' -and $node.Operator -eq 'Equals'},$true))
if($publish.Count -ne 1 -or !$publish[0].Right.Extent.Text.Contains('$rumProperty')){throw 'The release publish must pass the RUM SDK property.'}
Write-Output 'PASS build.ps1 publishes with the RUM SDK archive pinned by RumSdk.targets.'

# Verify AI runtime decoupling and unbundled release checks in build.ps1 and smoke-windows-gpu.ps1.
$params=@($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
if('AIDenoise' -notin $params){throw 'build.ps1 must expose -AIDenoise to compile the AI runtime without a model directory.'}
$buildText=Get-Content -LiteralPath $BuildScript -Raw
if($buildText.Contains('Release packages require -DualDnModel')){throw 'build.ps1 -ReleasePackage must no longer require -DualDnModel.'}
$assertFn=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-ReleaseAIOutput'},$true))
if($assertFn.Count -ne 1){throw 'build.ps1 must define Assert-ReleaseAIOutput.'}
$assertCall=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Assert-ReleaseAIOutput'},$true))
if($assertCall.Count -ne 1){throw 'build.ps1 must invoke Assert-ReleaseAIOutput before release packaging.'}
$vpkCall=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-Checked' -and $node.Extent.Text.Contains('vpk.exe')},$true))
if($vpkCall.Count -ne 1 -or $assertCall[0].Extent.StartOffset -ge $vpkCall[0].Extent.StartOffset){throw 'Assert-ReleaseAIOutput must run before vpk.exe packs the release output.'}

# Execute the actual Assert-ReleaseAIOutput implementation against temporary directories.
. ([scriptblock]::Create($assertFn[0].Extent.Text))
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('rawlab-build-checks-' + [guid]::NewGuid().ToString('N'))
try {
    $validDir=Join-Path $tempRoot 'valid'
    New-Item -ItemType Directory -Force $validDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $validDir 'ai-model-catalog.json'),'{}')
    Assert-ReleaseAIOutput $validDir

    $poisonedDir=Join-Path $tempRoot 'poisoned'
    New-Item -ItemType Directory -Force (Join-Path $poisonedDir 'AI/DualDn') | Out-Null
    [IO.File]::WriteAllText((Join-Path $poisonedDir 'ai-model-catalog.json'),'{}')
    $threw=$false
    try { Assert-ReleaseAIOutput $poisonedDir } catch { $threw=$true }
    if(!$threw){throw 'Assert-ReleaseAIOutput failed to reject a release directory containing AI/DualDn.'}

    $noCatalogDir=Join-Path $tempRoot 'no-catalog'
    New-Item -ItemType Directory -Force $noCatalogDir | Out-Null
    $threw=$false
    try { Assert-ReleaseAIOutput $noCatalogDir } catch { $threw=$true }
    if(!$threw){throw 'Assert-ReleaseAIOutput failed to reject a release directory missing ai-model-catalog.json.'}
    Write-Output 'PASS build.ps1 enforces unbundled release AI output and catalog presence.'

    # Parse and verify smoke-windows-gpu.ps1 (ASCII-safe, external -ModelDir, rejects bundled AI\DualDn).
    $smokeTokens=$null; $smokeErrors=$null
    $smokeAst=[Management.Automation.Language.Parser]::ParseFile($SmokeScript,[ref]$smokeTokens,[ref]$smokeErrors)
    if($smokeErrors.Count -gt 0){throw "smoke-windows-gpu.ps1 parsing failed: $smokeErrors"}
    if(@([IO.File]::ReadAllBytes($SmokeScript) | Where-Object {$_ -gt 127}).Count -gt 0){throw 'Keep smoke-windows-gpu.ps1 ASCII-safe for Windows PowerShell 5.1.'}
    $smokeParams=@($smokeAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    if('ModelDir' -notin $smokeParams){throw 'smoke-windows-gpu.ps1 must accept an external -ModelDir parameter.'}
    $smokeText=Get-Content -LiteralPath $SmokeScript -Raw
    if(!$smokeText.Contains(".TrimEnd('\', '/')")){throw 'smoke-windows-gpu.ps1 must trim trailing path separators before quoting native arguments.'}

    $extModel=Join-Path $tempRoot 'ext-model'
    New-Item -ItemType Directory -Force $extModel | Out-Null
    [IO.File]::WriteAllText((Join-Path $extModel 'manifest.json'),'{}')
    $stubFile=Join-Path $tempRoot 'stub.bin'
    [IO.File]::WriteAllText($stubFile,'stub')

    $badPkgDir=Join-Path $tempRoot 'pkg-with-model'
    New-Item -ItemType Directory -Force (Join-Path $badPkgDir 'AI/DualDn'), (Join-Path $badPkgDir 'ExifTool') | Out-Null
    foreach($f in @('RawLab.exe','sony2fuji.dll','sony2fuji.exe','onnxruntime.dll','DirectML.dll','ai-model-catalog.json','ExifTool/ExifTool.exe','AI/DualDn/manifest.json')) {
        [IO.File]::WriteAllText((Join-Path $badPkgDir $f),'x')
    }
    $badZip=Join-Path $tempRoot 'bad-model.zip'
    Compress-Archive -Path "$badPkgDir/*" -DestinationPath $badZip
    function Invoke-SmokeProbe([string[]]$Arguments) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ($Arguments | ForEach-Object {
            $a = $_ -replace '(\\*)"','$1$1\"'
            if($a.EndsWith('\')){ $a = $a -replace '(\\+)$','$1$1' }
            '"' + $a + '"'
        }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        try {
            $errTask = $p.StandardError.ReadToEndAsync()
            $out = $p.StandardOutput.ReadToEnd()
            $p.WaitForExit()
            [pscustomobject]@{ Code = $p.ExitCode; Output = ($out + "`n" + $errTask.Result) }
        } finally { $p.Dispose() }
    }

    $smokeWork=Join-Path $tempRoot 'smoke-work-1'
    # Pass trailing backslash on -ModelDir to exercise Tab-completed directory paths.
    $r1=Invoke-SmokeProbe @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$SmokeScript,
        '-PackageZip',$badZip,'-DualDnProbe',$stubFile,'-ModelDir',($extModel + '\'),'-ProbeRaw',$stubFile,'-CliRaw',$stubFile,'-WorkRoot',$smokeWork)
    $flat1=$r1.Output -replace '\r?\n',''
    if($r1.Code -eq 0 -or $flat1 -notmatch 'must not contain bundled AI\\DualDn'){
        throw "smoke-windows-gpu.ps1 did not reject a release ZIP containing AI\DualDn (exit=$($r1.Code)): $($r1.Output)"
    }
    if(Test-Path -LiteralPath $smokeWork){throw "smoke-windows-gpu.ps1 leaked WorkRoot: $smokeWork"}

    $noCatPkgDir=Join-Path $tempRoot 'pkg-no-catalog'
    New-Item -ItemType Directory -Force (Join-Path $noCatPkgDir 'ExifTool') | Out-Null
    foreach($f in @('RawLab.exe','sony2fuji.dll','sony2fuji.exe','onnxruntime.dll','DirectML.dll','ExifTool/ExifTool.exe')) {
        [IO.File]::WriteAllText((Join-Path $noCatPkgDir $f),'x')
    }
    $noCatZip=Join-Path $tempRoot 'bad-nocat.zip'
    Compress-Archive -Path "$noCatPkgDir/*" -DestinationPath $noCatZip
    $smokeWork2=Join-Path $tempRoot 'smoke-work-2'
    $r2=Invoke-SmokeProbe @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$SmokeScript,
        '-PackageZip',$noCatZip,'-DualDnProbe',$stubFile,'-ModelDir',$extModel,'-ProbeRaw',$stubFile,'-CliRaw',$stubFile,'-WorkRoot',$smokeWork2)
    $flat2=$r2.Output -replace '\r?\n',''
    if($r2.Code -eq 0 -or $flat2 -notmatch 'Package is missing ai-model-catalog\.json'){
        throw "smoke-windows-gpu.ps1 did not reject a release ZIP missing ai-model-catalog.json (exit=$($r2.Code)): $($r2.Output)"
    }
    if(Test-Path -LiteralPath $smokeWork2){throw "smoke-windows-gpu.ps1 leaked WorkRoot: $smokeWork2"}
    Write-Output 'PASS smoke-windows-gpu.ps1 rejects bundled AI\DualDn and missing ai-model-catalog.json.'
} finally {
    if(Test-Path -LiteralPath $tempRoot){Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue}
}
