using System.Diagnostics;
using System.IO;
using System.Text;

namespace RawLab.Windows;

internal static class AtomicFileWrite
{
    private const int SharingViolationHResult = unchecked((int)0x80070020);
    private const int LockViolationHResult = unchecked((int)0x80070021);
    private static readonly int[] TransientRetryDelaysMs = [10, 50, 200];
    private static readonly TimeSpan TransientRetryBudget = TimeSpan.FromMilliseconds(500);
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    public static void Write(string path, byte[] data, Action<string, string>? moveFile = null,
        Action<TimeSpan>? sleep = null, Func<TimeSpan>? elapsed = null, Func<string, bool>? deleteTemporary = null, bool createDirectory = true) =>
        Write(path, data, WriteTemporaryFile, moveFile ?? ReplaceFile, sleep, elapsed, deleteTemporary, createDirectory);

    public static void WriteText(string path, string text, Action<string, string>? moveFile = null,
        Action<TimeSpan>? sleep = null, Func<TimeSpan>? elapsed = null, Func<string, bool>? deleteTemporary = null, bool createDirectory = true) =>
        Write(path, Utf8NoBom.GetBytes(text), WriteTemporaryFile, moveFile ?? ReplaceFile, sleep, elapsed, deleteTemporary, createDirectory);

    public static void Write(string path, byte[] data, Action<string, byte[]> writeTemporary, Action<string, string> moveFile,
        Action<TimeSpan>? sleep = null, Func<TimeSpan>? elapsed = null, Func<string, bool>? deleteTemporary = null, bool createDirectory = true) =>
        WriteWithTemporary(path, temporary => writeTemporary(temporary, data), moveFile, sleep, elapsed, deleteTemporary, createDirectory);

    public static void WriteWithTemporary(string path, Action<string> writeTemporary, Action<string, string>? moveFile = null,
        Action<TimeSpan>? sleep = null, Func<TimeSpan>? elapsed = null, Func<string, bool>? deleteTemporary = null, bool createDirectory = true)
    {
        if (createDirectory && Path.GetDirectoryName(path) is { Length: > 0 } directory) Directory.CreateDirectory(directory);
        var replace = moveFile ?? ReplaceFile;
        var cleanup = deleteTemporary ?? TryDeleteTemporary;
        string? writtenTemporary = null;
        List<string>? staleTemporaries = null;
        try
        {
            RetryTransientIo(() =>
            {
                var temporary = writtenTemporary;
                if (temporary == null)
                {
                    var candidate = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                    try
                    {
                        writeTemporary(candidate);
                        writtenTemporary = temporary = candidate;
                    }
                    catch
                    {
                        if (!cleanup(candidate)) (staleTemporaries ??= []).Add(candidate);
                        throw;
                    }
                }
                replace(temporary, path);
                writtenTemporary = null;
            }, sleep, elapsed);
        }
        finally
        {
            if (writtenTemporary != null) cleanup(writtenTemporary);
            if (staleTemporaries != null)
            {
                foreach (var stale in staleTemporaries) cleanup(stale);
            }
        }
    }

    public static void WriteTemporaryStream(string temporary, Action<Stream> writeStream)
    {
        using var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough);
        writeStream(file);
        file.Flush(true);
    }

    internal static void WriteTemporaryFile(string temporary, byte[] data) =>
        WriteTemporaryStream(temporary, stream => stream.Write(data));

    internal static void ReplaceFile(string source, string destination) => File.Move(source, destination, true);

    internal static bool TryDeleteTemporary(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    internal static bool IsTransientSharingIo(Exception error) =>
        error is IOException and not FileNotFoundException and not DirectoryNotFoundException and not PathTooLongException &&
        error.HResult is SharingViolationHResult or LockViolationHResult;

    internal static void RetryTransientIo(Action action, Action<TimeSpan>? sleep = null, Func<TimeSpan>? elapsed = null)
    {
        sleep ??= Thread.Sleep;
        Func<TimeSpan> clock;
        if (elapsed != null) clock = elapsed;
        else
        {
            var stopwatch = Stopwatch.StartNew();
            clock = () => stopwatch.Elapsed;
        }
        var start = clock();
        var retries = 0;
        while (true)
        {
            try
            {
                action();
                return;
            }
            catch (Exception error) when (IsTransientSharingIo(error) && retries < TransientRetryDelaysMs.Length &&
                clock() - start + TimeSpan.FromMilliseconds(TransientRetryDelaysMs[retries]) <= TransientRetryBudget)
            {
                var delay = TimeSpan.FromMilliseconds(TransientRetryDelaysMs[retries++]);
                sleep(delay);
            }
        }
    }
}
