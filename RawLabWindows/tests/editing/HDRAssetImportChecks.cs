using System.Runtime.InteropServices;
using RawLab.Windows;

internal static class HDRAssetImportChecks
{
    internal static void Run()
    {
        if (Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_HDR_LIBRARY") is { Length: > 0 } library)
            NativeLibrary.SetDllImportResolver(typeof(Native).Assembly,
                (name, _, _) => name == "sony2fuji.dll" ? NativeLibrary.Load(library) : IntPtr.Zero);
        var root = Path.Combine(Path.GetTempPath(), "rawlab-hdr-import-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try {
            var source = Path.Combine(root, "test.cube");
            var assets = Path.Combine(root, "assets");
            var lines = new List<string> {
                "# RawLabHDRLook: display-linear-srgb-v1", "DOMAIN_MAX 4 4 4", "LUT_3D_SIZE 2"
            };
            for (var b = 0; b <= 4; b += 4) for (var g = 0; g <= 4; g += 4) for (var r = 0; r <= 4; r += 4)
                lines.Add($"{r} {g} {b}");
            File.WriteAllText(source, string.Join('\n', lines) + "\n");
            var original = File.ReadAllBytes(source);
            var look = HDRNative.ImportLook(source, assets);
            var destination = look.AssetPath(assets)!;
            Check(look.AssetIsAvailable(assets), "First import publishes the verified HDR look");
            Check(HDRNative.ImportLook(source, assets) == look && look.AssetIsAvailable(assets),
                "Importing a valid existing HDR look succeeds");
            File.WriteAllText(destination, "corrupted cache");
            Check(!look.AssetIsAvailable(assets), "Corrupted HDR look is detected");
            Check(HDRNative.ImportLook(source, assets) == look && look.AssetIsAvailable(assets) &&
                File.ReadAllBytes(destination).SequenceEqual(original), "Reimport repairs a corrupted HDR look");
            Check(File.ReadAllBytes(source).SequenceEqual(original), "Import preserves the original look");
            Check(!Directory.EnumerateFiles(assets, ".import-*").Any(), "Import removes staging files");
            Console.WriteLine("PASS: HDR look import, duplicate import and corrupted asset recovery");
        } finally { Directory.Delete(root, recursive: true); }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }
}
