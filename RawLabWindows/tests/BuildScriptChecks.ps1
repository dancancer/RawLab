[CmdletBinding()]
param([string]$BuildScript, [string]$RumTargets)
$ErrorActionPreference='Stop'
if(!$BuildScript){$BuildScript=Join-Path (Split-Path $PSScriptRoot -Parent) 'build.ps1'}
if(!$RumTargets){$RumTargets=Join-Path (Split-Path $PSScriptRoot -Parent) 'RumSdk.targets'}
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
$publish=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$publish'},$true))
if($publish.Count -ne 1 -or !$publish[0].Right.Extent.Text.Contains('$rumProperty')){throw 'The release publish must pass the RUM SDK property.'}
Write-Output 'PASS build.ps1 publishes with the RUM SDK archive pinned by RumSdk.targets.'
