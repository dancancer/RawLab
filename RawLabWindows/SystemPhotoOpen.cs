using System.Buffers.Binary;
using System.IO;
using System.IO.Pipes;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RawLab.Windows;

internal static class SystemPhotoOpen
{
    private const int MaxMessageBytes = 1024 * 1024;
    internal static string[] Paths(IEnumerable<string> arguments, string? directory = null)
    {
        var paths = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var argument in arguments)
        {
            if (string.IsNullOrWhiteSpace(argument) || argument.StartsWith("--", StringComparison.Ordinal)) continue;
            try
            {
                var path = Path.GetFullPath(argument, directory ?? Environment.CurrentDirectory);
                if (seen.Add(path)) paths.Add(path);
            }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { }
        }
        return paths.ToArray();
    }

    internal static string PipeName(string directory)
    {
        var path = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory));
        if (OperatingSystem.IsWindows()) path = path.ToUpperInvariant();
        var key = Environment.UserName + "\n" + path;
        return "RawLab.PhotoOpen." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(key)))[..32];
    }

    internal static async Task WriteAsync(Stream stream, string[] paths, CancellationToken cancellation)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(paths);
        if (bytes.Length > MaxMessageBytes) throw new IOException("Photo open request is too large");
        var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
        await stream.WriteAsync(header, cancellation);
        await stream.WriteAsync(bytes, cancellation);
        await stream.FlushAsync(cancellation);
    }

    internal static async Task<string[]> ReadAsync(Stream stream, CancellationToken cancellation)
    {
        var header = new byte[4]; await stream.ReadExactlyAsync(header, cancellation);
        var size = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (size <= 0 || size > MaxMessageBytes) throw new IOException("Invalid photo open request size");
        var bytes = new byte[size]; await stream.ReadExactlyAsync(bytes, cancellation);
        var paths = JsonSerializer.Deserialize<string[]>(bytes);
        if (paths == null || paths.Length == 0 || paths.Length > 1024 ||
            paths.Any(path => string.IsNullOrWhiteSpace(path) || path.Contains('\0') || !Path.IsPathFullyQualified(path)))
            throw new IOException("Invalid photo open paths");
        return paths;
    }

    [DllImport("user32.dll")]
    private static extern bool AllowSetForegroundWindow(uint processId);

    internal static async Task<UpdateRunLease?> AcquireOrForwardAsync(string directory, string name, string[] paths,
        int timeoutMilliseconds = 5000)
    {
        var elapsed = Stopwatch.StartNew();
        while (true)
        {
            try { return new UpdateRunLease(directory); }
            catch (IOException error) when (error.Message == "other_instance")
            {
                if (paths.Length > 0)
                {
                    if (OperatingSystem.IsWindows()) AllowSetForegroundWindow(uint.MaxValue);
                    if (await ForwardAsync(name, paths, 200)) return null;
                }
                if (elapsed.ElapsedMilliseconds >= timeoutMilliseconds) throw;
                await Task.Delay(100);
            }
        }
    }

    internal static async Task<bool> ForwardAsync(string name, string[] paths, int timeoutMilliseconds = 5000)
    {
        try
        {
            using var timeout = new CancellationTokenSource(timeoutMilliseconds);
            using var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            await pipe.ConnectAsync(timeout.Token);
            await WriteAsync(pipe, paths, timeout.Token);
            var reply = new byte[1]; await pipe.ReadExactlyAsync(reply, timeout.Token);
            return reply[0] == 1;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or OperationCanceledException or TimeoutException)
        { return false; }
    }
}

internal sealed class SystemPhotoOpenServer : IDisposable
{
    internal string Name { get; }
    private readonly CancellationTokenSource stop = new();
    private readonly Task listening;
    private readonly Func<string[], bool> received;

    internal SystemPhotoOpenServer(string name, Func<string[], bool> received)
    {
        Name = name; this.received = received;
        listening = Task.Run(ListenAsync);
    }

    private async Task ListenAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(Name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stop.Token);
                // 已连接但不发送完整消息的进程不能永久占用入口。
                using var request = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                request.CancelAfter(TimeSpan.FromSeconds(5));
                var paths = await SystemPhotoOpen.ReadAsync(pipe, request.Token);
                var accepted = !stop.IsCancellationRequested && received(paths);
                await pipe.WriteAsync(new byte[] { accepted ? (byte)1 : (byte)0 }, request.Token);
                await pipe.FlushAsync(request.Token);
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
            catch (UnauthorizedAccessException) { break; }
            catch (ArgumentException) { break; }
            catch (Exception error) when (error is IOException or JsonException or OperationCanceledException)
            {
                try { await Task.Delay(100, stop.Token); }
                catch (OperationCanceledException) { break; }
            }
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        try { listening.GetAwaiter().GetResult(); }
        // 监听异常不能在主窗口已经关闭后变成用户可见的启动错误。
        catch (Exception) { }
        stop.Dispose();
    }
}

internal sealed class SystemPhotoOpenQueue
{
    private sealed class Request(string[] paths, DateTimeOffset started)
    {
        internal string[] Paths = paths;
        internal DateTimeOffset Started = started;
        internal bool Sealed;
    }
    private readonly List<Request> requests = [];
    private bool accepting = true;
    internal bool Accepting { get { lock (requests) return accepting; } set { lock (requests) accepting = value; } }
    internal bool HasRequests { get { lock (requests) return requests.Count > 0; } }

    internal bool Enqueue(string[] paths, DateTimeOffset now)
    {
        lock (requests)
        {
            if (!accepting) return false;
            if (paths.Length == 0) return true;
            var last = requests.LastOrDefault();
            if (last != null && !last.Sealed && now - last.Started < TimeSpan.FromMilliseconds(400) &&
                last.Paths.Length + paths.Length <= 1024)
                last.Paths = SystemPhotoOpen.Paths(last.Paths.Concat(paths));
            else requests.Add(new(paths, now));
            return true;
        }
    }
    internal string[]? Peek(DateTimeOffset now)
    {
        lock (requests)
        {
            if (requests.Count == 0 || now - requests[0].Started < TimeSpan.FromMilliseconds(400)) return null;
            // 首次交给 UI 后固定边界，保存失败或模态等待期间不能再合并后续请求。
            requests[0].Sealed = true;
            return requests[0].Paths;
        }
    }
    internal void RemoveFirst() { lock (requests) requests.RemoveAt(0); }
}
