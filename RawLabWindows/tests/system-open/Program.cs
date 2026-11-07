using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Text;
using RawLab.Windows;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    Console.WriteLine("PASS: " + message);
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
    if (!args.Contains("--protocol-only"))
    {
        var received = new ConcurrentQueue<string[]>();
        using var server = new SystemPhotoOpenServer(SystemPhotoOpen.PipeName(root), received.Enqueue);
        Check(await SystemPhotoOpen.ForwardAsync(server.Name, [first, second]), "A second process can hand off every file to a live pipe");
        Check(await SystemPhotoOpen.ForwardAsync(server.Name, [second]), "The primary listener accepts another request after the first");
        Check(received.ToArray().Length == 2 && received.ToArray()[0].SequenceEqual([first, second]) &&
              received.ToArray()[1].SequenceEqual([second]), "Acknowledged requests arrive once in connection order");
        Check(!await SystemPhotoOpen.ForwardAsync(SystemPhotoOpen.PipeName(root + "-missing"), [first], 100),
              "An unavailable primary reports handoff failure instead of dropping the request");
    }
}
finally { Directory.Delete(root, true); }
