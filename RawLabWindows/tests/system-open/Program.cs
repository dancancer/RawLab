using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Text;
using System.Diagnostics;
using RawLab.Windows;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    Console.WriteLine("PASS: " + message);
}

if (args.Length == 4 && args[0] == "--lease-child")
{
    File.WriteAllText(Path.Combine(args[1], "started-" + Path.GetFileName(args[2])), "started");
    var startingDeadline = DateTime.UtcNow.AddSeconds(5);
    while (Directory.GetFiles(args[1], "started-*").Length < 2 && DateTime.UtcNow < startingDeadline) await Task.Delay(10);
    using var childLease = await SystemPhotoOpen.AcquireOrForwardAsync(args[1], SystemPhotoOpen.PipeName(args[1]), [], 5000);
    File.WriteAllText(args[2], "primary");
    var deadline = DateTime.UtcNow.AddSeconds(5);
    while (!File.Exists(args[3]) && DateTime.UtcNow < deadline) await Task.Delay(20);
    return;
}

var root = Path.Combine(Path.GetTempPath(), "RawLab-SystemOpen-" + Guid.NewGuid());
Directory.CreateDirectory(root);
try
{
    var first = Path.Combine(root, "one photo.dng");
    var second = Path.Combine(root, "中文 second.jpg");
    var parsed = SystemPhotoOpen.Paths(["one photo.dng", second, first, "", "--test", "bad\0.jpg"], root);
    Check(parsed.SequenceEqual([first, second]), "All arguments preserve spaces, Unicode, order and relative sender paths without duplicates");
    Check(SystemPhotoOpen.PipeName(root) == SystemPhotoOpen.PipeName(Path.Combine(root, ".")) &&
          SystemPhotoOpen.PipeName(root) != SystemPhotoOpen.PipeName(root + "-other"), "The pipe is scoped to the data directory");

    using var encoded = new MemoryStream();
    await SystemPhotoOpen.WriteAsync(encoded, [first, second], CancellationToken.None);
    encoded.Position = 0;
    Check((await SystemPhotoOpen.ReadAsync(encoded, CancellationToken.None)).SequenceEqual([first, second]),
          "One framed pipe message retains the entire multi-file request");
    foreach (var invalid in new[] { "null", "[]", "[null]", "[\"relative.jpg\"]", "{}", "[1]" })
    {
        using var stream = new MemoryStream();
        var json = Encoding.UTF8.GetBytes(invalid);
        var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, json.Length);
        stream.Write(header); stream.Write(json); stream.Position = 0;
        var rejected = false;
        try { await SystemPhotoOpen.ReadAsync(stream, CancellationToken.None); }
        catch (Exception error) when (error is IOException or System.Text.Json.JsonException) { rejected = true; }
        Check(rejected, "Malformed requests cannot reach the editor: " + invalid);
    }
    using (var tooLarge = new MemoryStream([0xff, 0xff, 0xff, 0x7f]))
    {
        var rejected = false;
        try { await SystemPhotoOpen.ReadAsync(tooLarge, CancellationToken.None); }
        catch (IOException) { rejected = true; }
        Check(rejected, "Oversized frames are rejected before allocating their payload");
    }
    var queue = new SystemPhotoOpenQueue();
    var now = DateTimeOffset.UtcNow;
    Check(queue.Enqueue([first], now) && queue.Peek(now) == null, "A cold single-file request waits for the Explorer burst window");
    queue.Enqueue([second, first], now.AddMilliseconds(200));
    Check(queue.Peek(now.AddMilliseconds(399)) == null, "The burst cannot dispatch before 400ms");
    Check(queue.Peek(now.AddMilliseconds(400))!.SequenceEqual([first, second]), "Explorer processes form one ordered de-duplicated collection");
    queue.Enqueue([second], now.AddSeconds(1));
    Check(queue.Peek(now.AddSeconds(2))!.SequenceEqual([first, second]), "A blocked group retains its boundary when later requests arrive");
    queue.RemoveFirst();
    Check(queue.Peek(now.AddSeconds(2))!.SequenceEqual([second]), "A later request stays separate after the blocked group completes");
    queue.Accepting = false;
    Check(!queue.Enqueue([first], now.AddSeconds(3)), "Closing rejects requests before an acknowledgement can be returned");
    queue.Accepting = true;
    Check(queue.Enqueue([first], now.AddSeconds(3)), "A cancelled close permits later requests again");
    using (var lease = new UpdateRunLease(root)) {
        var blocked = false;
        try { using var other = new UpdateRunLease(root); }
        catch (IOException error) when (error.Message == "other_instance") { blocked = true; }
        Check(blocked, "The run lock admits one primary");
    }
    using (var lease = new UpdateRunLease(root)) { Check(true, "The run lock is released for a successor"); }
    Check(UpdateRunLease.SupportsRunLease(typeof(UpdateRunLease).Assembly.Location) &&
          !UpdateRunLease.SupportsRunLease(first), "Only binaries that contain the run-lock protocol bypass legacy ZIP detection");
    Process StartContender(int index)
    {
        // 使用真实 RawLab 进程名，回归旧版按名称互相拒绝的冷启动竞争。
        var executable = Path.Combine(AppContext.BaseDirectory, OperatingSystem.IsWindows() ? "RawLab.exe" : "RawLab");
        var info = new ProcessStartInfo(executable) { UseShellExecute = false };
        if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "dotnet", StringComparison.OrdinalIgnoreCase))
            info.Environment["DOTNET_ROOT"] = Path.GetDirectoryName(Environment.ProcessPath);
        foreach (var argument in new[] { "--lease-child", root, Path.Combine(root, $"ready{index}"), Path.Combine(root, $"release{index}") })
            info.ArgumentList.Add(argument);
        return Process.Start(info)!;
    }
    using (var contender1 = StartContender(1))
    using (var contender2 = StartContender(2))
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (!Directory.GetFiles(root, "ready*").Any() && DateTime.UtcNow < deadline) await Task.Delay(20);
        Check(Directory.GetFiles(root, "ready*").Length == 1, "Concurrent cold processes elect exactly one lock owner");
        var winner = File.Exists(Path.Combine(root, "ready1")) ? 1 : 2;
        File.WriteAllText(Path.Combine(root, $"release{winner}"), "release");
        while (Directory.GetFiles(root, "ready*").Length != 2 && DateTime.UtcNow < deadline) await Task.Delay(20);
        Check(Directory.GetFiles(root, "ready*").Length == 2, "The waiting process takes the lock after its predecessor exits");
        File.WriteAllText(Path.Combine(root, $"release{3 - winner}"), "release");
        await Task.WhenAll(contender1.WaitForExitAsync(), contender2.WaitForExitAsync()).WaitAsync(TimeSpan.FromSeconds(6));
        Check(contender1.ExitCode == 0 && contender2.ExitCode == 0, "Both cold launches complete without mutually rejecting each other");
    }
    if (!args.Contains("--protocol-only"))
    {
        var received = new ConcurrentQueue<string[]>();
        using var server = new SystemPhotoOpenServer(SystemPhotoOpen.PipeName(root), paths => { received.Enqueue(paths); return true; });
        Check(await SystemPhotoOpen.ForwardAsync(server.Name, [first, second]), "A second process can hand off every file to a live pipe");
        Check(await SystemPhotoOpen.ForwardAsync(server.Name, [second]), "The primary listener accepts another request after the first");
        Check(received.ToArray().Length == 2 && received.ToArray()[0].SequenceEqual([first, second]) &&
              received.ToArray()[1].SequenceEqual([second]), "Acknowledged requests arrive once in connection order");
        using (var rejecting = new SystemPhotoOpenServer(SystemPhotoOpen.PipeName(root + "-closing"), _ => false))
        {
            Check(!await SystemPhotoOpen.ForwardAsync(rejecting.Name, [first], 500), "A closing primary replies not accepted");
            var previous = new UpdateRunLease(root);
            var release = Task.Run(async () => { await Task.Delay(150); previous.Dispose(); });
            using var successor = await SystemPhotoOpen.AcquireOrForwardAsync(root, rejecting.Name, [first], 2000);
            await release;
            Check(successor != null, "A refused request waits for the old lock and becomes the successor primary");
        }
        using (var throwing = new SystemPhotoOpenServer(SystemPhotoOpen.PipeName(root + "-fault"), _ => throw new InvalidOperationException("listener failure")))
            Check(!await SystemPhotoOpen.ForwardAsync(throwing.Name, [first], 500), "Listener callback failure cannot acknowledge an unaccepted request");
        using (var faulty = new SystemPhotoOpenServer("invalid/pipe", _ => true)) { await Task.Delay(30); }
        Check(true, "Disposing a listener whose pipe construction failed does not throw");
        Check(!await SystemPhotoOpen.ForwardAsync(SystemPhotoOpen.PipeName(root + "-missing"), [first], 100),
              "An unavailable primary reports handoff failure instead of dropping the request");
    }
}
finally { Directory.Delete(root, true); }
