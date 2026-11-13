using System.IO;
using RawLab.Windows;

internal static class LUTPreviewCleanupChecks
{
    // 相机“保护”过的照片拷到电脑后带只读属性：LUT 预览换照片后仍能生成，关闭后不留整张照片的副本。
    internal static void Run(string output, string raw, string lut, Action<bool,string> check)
    {
        var directory = Path.Combine(output, "lut-preview-read-only"); Directory.CreateDirectory(directory);
        var photos = new[] { Path.Combine(directory, "protected-1.ARW"), Path.Combine(directory, "protected-2.ARW") };
        var look = Path.Combine(directory, "protected.cube");
        var files = photos.Append(look).ToArray();
        foreach (var photo in photos) File.Copy(raw, photo, true);
        File.Copy(lut, look, true);
        foreach (var file in files) File.SetAttributes(file, File.GetAttributes(file) | FileAttributes.ReadOnly);
        var before = Previews();
        try {
            var service = new LUTPreviewService();
            var first = service.Load(look, photos[0], CancellationToken.None).GetAwaiter().GetResult();
            var second = service.Load(look, photos[1], CancellationToken.None).GetAwaiter().GetResult();
            check(first.Baseline.Pixels.Length > 0 && second.Baseline.Pixels.Length > 0, "Read-only photo and LUT still preview after switching photos");
            check(Previews().Except(before).Count() == 1, "Switching photos removes the previous read-only preview copy");
            service.Dispose();
            var clock = System.Diagnostics.Stopwatch.StartNew();
            while (Previews().Except(before).Any() && clock.Elapsed < TimeSpan.FromSeconds(10)) Thread.Sleep(20);
            check(!Previews().Except(before).Any(), "Closing the preview removes its read-only temporary copies");
        } finally {
            foreach (var file in files) File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(directory, true);
        }
    }
    private static string[] Previews() => Directory.GetDirectories(Path.GetTempPath(), "RawLab-LUT-preview-*");
}
