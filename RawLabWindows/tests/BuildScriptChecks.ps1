[CmdletBinding()]
param([string]$BuildScript)
$ErrorActionPreference='Stop'
if(!$BuildScript){$BuildScript=Join-Path (Split-Path $PSScriptRoot -Parent) 'build.ps1'}
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
