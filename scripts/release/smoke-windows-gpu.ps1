<#
.SYNOPSIS
  Non-destructive DirectML GPU smoke of a RawLab Windows release ZIP on the physical
  GPU test PC (DESKTOP-216). Windows PowerShell 5.1 compatible; keep this file ASCII.

.DESCRIPTION
  Runs on the Windows host. It extracts the release ZIP into a throwaway directory and checks:
    1. guard  : this process does not run with the PreferSystem32Images image-load mitigation
                (set when entering through WSL on port 22), which would load
                System32\onnxruntime.dll instead of the packaged runtime;
    2. dualdn : dualdn_probe.exe --validate on the packaged AI\DualDn model, then a forced
                DirectML pipeline run whose pipeline.json must report a DirectML producer and
                no fallback;
    3. cli    : packaged sony2fuji.exe renders a RAW to a non-empty JPEG;
    4. exif   : packaged ExifTool reports the pinned version;
    5. c-abi  : in a child process, the packaged sony2fuji.dll exports
                sony2fuji_ai_available()=1 and sony2fuji_ai_hardware_available()=1, and any
                loaded onnxruntime.dll / DirectML.dll comes from the package, not System32.
  The work directory (and -StagingDir when given) is removed in finally and must be gone
  afterwards. %LOCALAPPDATA%\RawLab is fingerprinted before and after; any change fails.
  The GUI is never launched.

  Launch from the release Mac through the native Windows OpenSSH on port 2222 (port 22 is WSL):
    H=xup@192.168.88.125; K=~/.ssh/id_ed25519; S='C:/RawLabBuild/gpu-smoke-in'
    ssh -p 2222 -i $K $H "mkdir C:\RawLabBuild\gpu-smoke-in"
    scp -P 2222 -i $K scripts/release/smoke-windows-gpu.ps1 "$DIST/RawLab-Windows-$VERSION-x64.zip" \
        <Paul-dev build tree>/dualdn_probe.exe lutools/tests/fixtures/bayer-demosaic.dng \
        .cache/shared/assets/.../lutools/examples/DJI_20250602164503_0444_D.DNG "$H:$S/"
    ssh -p 2222 -i $K $H "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $S/smoke-windows-gpu.ps1 \
        -PackageZip $S/RawLab-Windows-$VERSION-x64.zip -DualDnProbe $S/dualdn_probe.exe \
        -ProbeRaw $S/bayer-demosaic.dng -CliRaw $S/DJI_20250602164503_0444_D.DNG -StagingDir $S"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageZip,
    [Parameter(Mandatory)][string]$DualDnProbe,
    [Parameter(Mandatory)][string]$ProbeRaw,
    [Parameter(Mandatory)][string]$CliRaw,
    [string]$ExpectedExifTool = '13.59',
    [string]$StagingDir = '',
    [string]$WorkRoot = ''
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Pass([string]$message) { Write-Output "PASS: $message" }

# One line per entry so a failure can name what changed. Enumerated directory timestamps come from
# NTFS parent-index entries that are updated lazily and drift without any write (a false alarm seen
# on DESKTOP-216), so directories are recorded by presence and files by their own size and write time.
function Get-LocalStateSnapshot {
    $state = Join-Path $env:LOCALAPPDATA 'RawLab'
    if (-not (Test-Path -LiteralPath $state)) { return @('<absent>') }
    $lines = @(Get-ChildItem -LiteralPath $state -Recurse -Force -ErrorAction Stop | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($state.Length)
        if ($_.PSIsContainer) { '{0}|dir' -f $relative } else {
            $file = New-Object IO.FileInfo $_.FullName
            '{0}|{1}|{2}' -f $relative, $file.Length, $file.LastWriteTimeUtc.ToString('o')
        }
    })
    if ($lines.Count -eq 0) { return @('<empty>') }
    return $lines
}

function Invoke-Native([string]$exe, [string]$arguments, [string]$label) {
    # Process.Start keeps empty arguments such as -config "" that PowerShell 5.1 would drop.
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo.FileName = $exe
    $process.StartInfo.Arguments = $arguments
    $process.StartInfo.WorkingDirectory = Split-Path -Parent $exe
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        $process.Start() | Out-Null
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $stdout = $process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $stderr = $stderrTask.Result
        if ($process.ExitCode -ne 0) {
            throw "$label failed with exit code $($process.ExitCode)`n$stdout`n$stderr"
        }
        return $stdout
    } finally {
        $process.Dispose()
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RawLabSmokeMitigation {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessMitigationPolicy(IntPtr process, int policy, out uint flags, UIntPtr length);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    // PROCESS_MITIGATION_IMAGE_LOAD_POLICY: bit 2 is PreferSystem32Images.
    public static bool PreferSystem32Images() {
        uint flags;
        if (!GetProcessMitigationPolicy(GetCurrentProcess(), 10, out flags, (UIntPtr)4))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return (flags & 4u) != 0;
    }
}
'@

$stateBefore = Get-LocalStateSnapshot
if (-not $WorkRoot) { $WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ("rawlab-gpu-smoke-" + [Guid]::NewGuid().ToString('N')) }
$failure = $null
# Guards run inside try so a refused run still removes the staged inputs.
try {
    foreach ($required in @($PackageZip, $DualDnProbe, $ProbeRaw, $CliRaw)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Input not found: $required" }
    }
    if (-not [Environment]::Is64BitProcess) { throw 'Run the smoke from 64-bit PowerShell.' }
    if ([RawLabSmokeMitigation]::PreferSystem32Images()) {
        throw 'PreferSystem32Images is active (WSL entry on port 22); System32\onnxruntime.dll would shadow the packaged runtime. Reconnect with ssh -p 2222.'
    }
    Pass 'PreferSystem32Images=False (native Windows OpenSSH session)'

    $package = Join-Path $WorkRoot 'pkg'
    New-Item -ItemType Directory -Force $package | Out-Null
    Expand-Archive -LiteralPath $PackageZip -DestinationPath $package -Force
    $app = Get-ChildItem -LiteralPath $package -Recurse -Filter 'RawLab.exe' | Select-Object -First 1
    if (-not $app) { throw 'RawLab.exe not found in the release ZIP.' }
    $package = $app.DirectoryName
    $model = Join-Path $package 'AI\DualDn'
    foreach ($name in @('sony2fuji.dll', 'sony2fuji.exe', 'onnxruntime.dll', 'DirectML.dll', 'ExifTool\ExifTool.exe', 'AI\DualDn\manifest.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $package $name))) { throw "Package is missing $name" }
    }
    Pass "extracted $(Split-Path -Leaf $PackageZip)"

    # The probe must sit next to the packaged runtime DLLs: Windows searches the system
    # directory before PATH, so a probe elsewhere could bind a different onnxruntime.dll.
    $probe = Join-Path $package 'dualdn_probe.exe'
    Copy-Item -LiteralPath $DualDnProbe -Destination $probe -Force
    $validated = Invoke-Native $probe ('--validate "{0}"' -f $model) 'dualdn_probe --validate'
    if ($validated -notmatch 'Validated DualDn package') { throw "Unexpected validate output: $validated" }
    Pass 'dualdn_probe --validate on packaged AI\DualDn'

    $probeOut = Join-Path $WorkRoot 'dualdn-pipeline'
    Invoke-Native $probe ('"{0}" "{1}" "{2}" pipeline directml' -f $ProbeRaw, $model, $probeOut) 'dualdn_probe pipeline directml' | Out-Null
    $pipeline = Get-Content -LiteralPath (Join-Path $probeOut 'pipeline.json') -Raw | ConvertFrom-Json
    # Forced DirectML must not hide a partial CPU/unknown stage behind one DirectML stage.
    $producer = [string]$pipeline.producer
    if ($producer -notmatch 'DirectML' -or $producer -match 'CPU|unknown') { throw "DualDn producer is not DirectML only: $producer" }
    if ($pipeline.raw_fallback -or $pipeline.rgb_fallback) {
        throw "DualDn reported a fallback: raw='$($pipeline.raw_fallback)' rgb='$($pipeline.rgb_fallback)'"
    }
    Pass "dualdn_probe DirectML pipeline (route=$($pipeline.route), producer=$($pipeline.producer))"

    $jpeg = Join-Path $WorkRoot 'cli.jpg'
    Invoke-Native (Join-Path $package 'sony2fuji.exe') ('"{0}" --no-lut -o "{1}"' -f $CliRaw, $jpeg) 'sony2fuji.exe' | Out-Null
    $bytes = [IO.File]::ReadAllBytes($jpeg)
    if ($bytes.Length -lt 1024 -or $bytes[0] -ne 0xFF -or $bytes[1] -ne 0xD8) { throw "sony2fuji.exe wrote an invalid JPEG ($($bytes.Length) bytes)" }
    Pass "sony2fuji.exe CLI ($(Split-Path -Leaf $CliRaw) -> $($bytes.Length) bytes JPEG)"

    $exifVersion = (Invoke-Native (Join-Path $package 'ExifTool\ExifTool.exe') '-config "" -ver' 'ExifTool -ver').Trim()
    if ($exifVersion -ne $ExpectedExifTool) { throw "ExifTool $exifVersion, expected $ExpectedExifTool" }
    Pass "ExifTool $exifVersion"

    # Load the DLL in a child process so it is unloaded before the work directory is removed.
    $abiScript = @'
$ErrorActionPreference = 'Stop'
$package = $args[0]
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RawLabSmokeAbi {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] public delegate int Int32Fn();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern IntPtr GetProcAddress(IntPtr module, string name);
    public static int Call(IntPtr module, string name) {
        IntPtr fn = GetProcAddress(module, name);
        if (fn == IntPtr.Zero) throw new Exception("missing export " + name);
        return ((Int32Fn)Marshal.GetDelegateForFunctionPointer(fn, typeof(Int32Fn)))();
    }
}
"@
$dll = Join-Path $package 'sony2fuji.dll'
# LOAD_WITH_ALTERED_SEARCH_PATH: resolve dependencies from the package directory first.
$module = [RawLabSmokeAbi]::LoadLibraryExW($dll, [IntPtr]::Zero, 8)
if ($module -eq [IntPtr]::Zero) { throw "LoadLibraryExW failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
$available = [RawLabSmokeAbi]::Call($module, 'sony2fuji_ai_available')
$hardware = [RawLabSmokeAbi]::Call($module, 'sony2fuji_ai_hardware_available')
$foreign = @((Get-Process -Id $PID).Modules | Where-Object {
    $_.ModuleName -in @('onnxruntime.dll', 'DirectML.dll') -and
    -not $_.FileName.StartsWith($package, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.FileName })
Write-Output ("available={0};hardware={1};foreign={2}" -f $available, $hardware, ($foreign -join ','))
'@
    $abiFile = Join-Path $WorkRoot 'abi-check.ps1'
    Set-Content -LiteralPath $abiFile -Value $abiScript -Encoding ASCII
    $abi = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $abiFile $package | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "C ABI child failed with exit code ${LASTEXITCODE}: $abi" }
    if ($abi -notmatch '^available=1;hardware=1;foreign=$') { throw "C ABI check failed: $abi" }
    Pass 'sony2fuji.dll sony2fuji_ai_available=1 sony2fuji_ai_hardware_available=1 (runtime DLLs from package)'

    $gpu = (Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon|Intel\(R\) Arc' } |
        ForEach-Object { "$($_.Name) driver $($_.DriverVersion)" }) -join '; '
    $os = (Get-CimInstance Win32_OperatingSystem).Version
    Write-Output "SUMMARY: $env:COMPUTERNAME (Windows $os, $gpu) PreferSystem32=False; $(Split-Path -Leaf $PackageZip): dualdn_probe DirectML route=$($pipeline.route) producer=$($pipeline.producer); sony2fuji.exe $($bytes.Length) bytes; ExifTool $exifVersion; sony2fuji_ai_hardware_available=1"
} catch {
    $failure = $_
} finally {
    foreach ($path in @($WorkRoot, $StagingDir)) {
        # Antivirus may briefly hold freshly extracted executables; retry before reporting.
        for ($attempt = 1; $path -and (Test-Path -LiteralPath $path) -and $attempt -le 3; $attempt++) {
            if ($attempt -gt 1) { Start-Sleep -Seconds 2 }
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($path -and (Test-Path -LiteralPath $path)) {
            $message = "Cleanup failed; remove $path manually."
            if ($failure) { Write-Error $message -ErrorAction Continue } else { $failure = $message }
        }
    }
}
$stateDiff = @(Compare-Object -ReferenceObject $stateBefore -DifferenceObject @(Get-LocalStateSnapshot) |
    ForEach-Object { '{0} {1}' -f $(if ($_.SideIndicator -eq '<=') { 'before' } else { 'after ' }), $_.InputObject })
if ($stateDiff.Count -gt 0) {
    $shown = ($stateDiff | Select-Object -First 20) -join "`n  "
    $failure = "$env:LOCALAPPDATA\RawLab changed during the smoke (path|size|UTC write time):`n  $shown`n$failure"
}
if ($failure) {
    Write-Error "FAIL: $failure" -ErrorAction Continue
    exit 1
}
Pass 'work directory removed (Test-Path=False) and %LOCALAPPDATA%\RawLab untouched'
