using System.Buffers.Binary;
using System.IO;
using System.IO.Pipes;
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
    private readonly Action<string[]> received;

    internal SystemPhotoOpenServer(string name, Action<string[]> received)
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
                received(paths);
                await pipe.WriteAsync(new byte[] { 1 }, request.Token);
                await pipe.FlushAsync(request.Token);
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
            catch (Exception error) when (error is IOException or JsonException or OperationCanceledException)
            { }
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        try { listening.GetAwaiter().GetResult(); }
        catch (OperationCanceledException) { }
        stop.Dispose();
    }
}
