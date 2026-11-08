using System.Diagnostics;
using System.IO;

namespace RawLab.Windows;

public sealed class UpdateRunLease : IDisposable
{
    private readonly FileStream file;
    public UpdateRunLease(string directory)
    {
        Directory.CreateDirectory(directory);
        try { file = new FileStream(Path.Combine(directory, "run.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33 ||
            !OperatingSystem.IsWindows() && (error.HResult & 0xffff) is 11 or 35)
        { throw new IOException("other_instance", error); }
        try
        {
            // 新版只以锁选主；进程扫描仅阻止尚不认识 run.lock 的旧 ZIP 写同一份数据。
            using var current = Process.GetCurrentProcess();
            foreach (var process in Process.GetProcessesByName("RawLab"))
            {
                using (process)
                {
                    try
                    {
                        if (process.Id == current.Id || process.SessionId != current.SessionId || process.HasExited) continue;
                        var executable = process.MainModule?.FileName;
                        if (executable != null && SupportsRunLease(Path.ChangeExtension(executable, ".dll"))) continue;
                        throw new IOException("other_instance");
                    }
                    catch (InvalidOperationException) { }
                    catch (System.ComponentModel.Win32Exception error) { throw new IOException("other_instance", error); }
                }
            }
        }
        catch { file.Dispose(); throw; }
    }
    internal static bool SupportsRunLease(string assemblyPath)
    {
        try
        {
            using var input = File.OpenRead(assemblyPath);
            using var pe = new System.Reflection.PortableExecutable.PEReader(input);
            if (!pe.HasMetadata) return false;
            var metadata = System.Reflection.Metadata.PEReaderExtensions.GetMetadataReader(pe);
            return metadata.TypeDefinitions.Any(handle => {
                var type = metadata.GetTypeDefinition(handle);
                return metadata.GetString(type.Namespace) == "RawLab.Windows" && metadata.GetString(type.Name) == "UpdateRunLease";
            });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or BadImageFormatException) { return false; }
    }
    public void Dispose() => file.Dispose();
}
