using System.Diagnostics;
using System.IO;

namespace RawLab.Windows;

public sealed class UpdateRunLease : IDisposable
{
    private readonly FileStream file;
    public UpdateRunLease(string directory)
    {
        // 旧 ZIP 不认识新锁，只能在开放数据写入前识别其仍在运行的进程。
        using var current = Process.GetCurrentProcess();
        foreach (var process in Process.GetProcessesByName("RawLab"))
        {
            using (process)
                if (process.Id != current.Id && process.SessionId == current.SessionId && !process.HasExited)
                    throw new IOException("other_instance");
        }
        Directory.CreateDirectory(directory);
        file = new FileStream(Path.Combine(directory, "run.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }
    public void Dispose() => file.Dispose();
}
