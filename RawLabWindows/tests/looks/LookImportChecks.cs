using RawLab.Windows;
using System.Runtime.InteropServices;
using System.Text;

internal static class LookImportChecks
{
    private static void Check(bool value, string message)
    {
        if (!value) throw new Exception(message);
        Console.WriteLine("PASS: " + message);
    }

    internal static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-look-import-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var source = Path.Combine(root, "Camera look.dcp");
            File.WriteAllBytes(source, [1, 2, 3, 4]);
            var rlook = System.Text.Encoding.ASCII.GetBytes("RLOOKDCP synthetic");
            var validations = new List<string>();
            var library = new LookLibrary(
                root,
                compileDcp: _ => rlook,
                validateLook: path =>
                {
                    validations.Add(path);
                    Check(Path.GetExtension(path).Equals(".rlook", StringComparison.OrdinalIgnoreCase),
                        "DCP validation runs on the converted RLOOK staging file");
                    Check(File.Exists(path), "staging output exists while native validation runs");
                    return new LookValidation(LookFormat.Rlook, 1);
                });

            var imported = library.ImportLook(source);
            Check(imported.Format == LookFormat.Rlook && imported.Name == "Camera look",
                "DCP import creates a managed RLOOK entry with the source name");
            Check(imported.Path != source && File.Exists(imported.Path),
                "DCP import stores converted bytes in the managed look directory");
            Check(validations.Count == 1, "DCP import performs exactly one native validation");
            var identity = library.IdentityForPath(imported.Path);
            Check(identity == "managed:" + imported.Id && library.ResolveIdentity(identity) == imported.Path,
                "managed DCP edits persist a stable look identity instead of the source path");

            var snapshotRoot = Path.Combine(root, "snapshot");
            var snapshotSource = Path.Combine(snapshotRoot, "snapshot.dcp");
            Directory.CreateDirectory(snapshotRoot);
            File.WriteAllBytes(snapshotSource, [5, 6, 7]);
            var snapshotLibrary = new LookLibrary(
                snapshotRoot,
                compileDcp: _ => rlook,
                validateLook: _ => new LookValidation(LookFormat.Rlook, 1));
            var beforeImport = snapshotLibrary.Looks;
            _ = snapshotLibrary.ImportLook(snapshotSource);
            Check(beforeImport.Count == 0 && snapshotLibrary.Looks.Count == 1,
                "look snapshots remain unchanged while the library publishes a new entry");

            var invalidRegistryRoot = Path.Combine(root, "invalid-registry");
            Directory.CreateDirectory(invalidRegistryRoot);
            var invalidRegistryPath = Path.Combine(invalidRegistryRoot, "registry.json");
            File.WriteAllText(invalidRegistryPath, "{ not valid registry }");
            var invalidRegistryBytes = File.ReadAllBytes(invalidRegistryPath);
            Check(!LookLibrary.TryLoad(invalidRegistryRoot, out var unavailable, out var loadError) &&
                  unavailable == null && loadError is LookLibraryException { Error: LookLibraryError.InvalidRegistry } &&
                  File.ReadAllBytes(invalidRegistryPath).SequenceEqual(invalidRegistryBytes),
                "invalid registry keeps the original file and leaves the look library unavailable");

            File.Delete(source);
            var restored = new LookLibrary(root);
            Check(restored.Looks.Count == 1 && restored.Looks[0].Id == imported.Id,
                "managed DCP look survives restart and source deletion");

            var activeStaging = Path.Combine(root, ".remove-" + imported.FileName);
            File.Move(imported.Path, activeStaging);
            var recovered = new LookLibrary(root);
            Check(recovered.Looks.Count == 1 && File.Exists(imported.Path) && !File.Exists(activeStaging),
                "an interrupted remove restores the managed file when the registry still references it");

            var beforeRegistry = File.ReadAllBytes(Path.Combine(root, "registry.json"));
            var invalid = Path.Combine(root, "rejected.dcp");
            File.WriteAllBytes(invalid, [9, 8, 7]);
            var rejected = new LookLibrary(
                root,
                compileDcp: _ => rlook,
                validateLook: _ => throw new LookLibraryException(LookLibraryError.InvalidLook));
            try
            {
                rejected.ImportLook(invalid);
                throw new Exception("invalid DCP import was accepted");
            }
            catch (LookLibraryException error)
            {
                Check(error.Error == LookLibraryError.InvalidLook,
                    "native validation failure is reported as an invalid look");
            }
            Check(rejected.Looks.Count == 1 && File.ReadAllBytes(Path.Combine(root, "registry.json")).SequenceEqual(beforeRegistry),
                "rejected DCP leaves the registry and existing selection candidates unchanged");
            Check(Directory.GetFiles(root, ".import-*", SearchOption.TopDirectoryOnly).Length == 0,
                "rejected DCP removes its staging file");

            var committedStaging = Path.Combine(root, ".remove-" + imported.FileName);
            File.Move(imported.Path, committedStaging);
            File.WriteAllText(Path.Combine(root, "registry.json"), "{\"Version\":1,\"Looks\":[]}");
            _ = new LookLibrary(root);
            Check(!File.Exists(committedStaging),
                "an interrupted remove cleans its staged file after the registry commit");

            var oversized = Path.Combine(root, "oversized.dcp");
            using (var stream = new FileStream(oversized, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                stream.SetLength(DcpCompiler.MaxSourceBytes + 1L);
            try
            {
                DcpCompiler.Compile(oversized);
                throw new Exception("oversized DCP was accepted");
            }
            catch (DcpCompileException error)
            {
                Check(error.Reason == DcpErrorReason.TooLarge,
                    "DCP source bound is enforced before native compilation");
            }

            RunRealNativeRegression(root);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static void RunRealNativeRegression(string root)
    {
        var nativePath = Environment.GetEnvironmentVariable("RAWLAB_TEST_DCP_NATIVE_LIB");
        var fixtureDirectory = Environment.GetEnvironmentVariable("RAWLAB_TEST_DCP_FIXTURE_DIR")
            ?? Environment.GetEnvironmentVariable("RAWLAB_DCP_FIXTURE_DIR");
        if (string.IsNullOrWhiteSpace(nativePath) || string.IsNullOrWhiteSpace(fixtureDirectory))
        {
            Console.WriteLine("SKIP real DCP ABI regression: RAWLAB_TEST_DCP_NATIVE_LIB and fixture directory are not both set");
            return;
        }
        if (!File.Exists(nativePath)) throw new FileNotFoundException("Real DCP ABI library was not found", nativePath);
        if (!Directory.Exists(fixtureDirectory)) throw new DirectoryNotFoundException(fixtureDirectory);

        var valid = Directory.GetFiles(fixtureDirectory, "*.dcp")
            .FirstOrDefault(path => Path.GetFileName(path).Contains("supported", StringComparison.OrdinalIgnoreCase));
        var missingTone = Directory.GetFiles(fixtureDirectory, "*.dcp")
            .FirstOrDefault(path => Path.GetFileName(path).Contains("missing tone", StringComparison.OrdinalIgnoreCase) ||
                                    Path.GetFileName(path).Contains("missing-tone", StringComparison.OrdinalIgnoreCase));
        if (valid == null || missingTone == null)
            throw new FileNotFoundException("Real DCP ABI regression needs supported and missing-tone fixtures");

        NativeLibrary.SetDllImportResolver(typeof(PInvokeNative).Assembly, (name, _, _) =>
            string.Equals(name, "sony2fuji.dll", StringComparison.OrdinalIgnoreCase)
                ? NativeLibrary.Load(nativePath)
                : IntPtr.Zero);

        var sourceName = "真实😀 DCP look.dcp";
        var source = Path.Combine(root, sourceName);
        File.Copy(valid, source);
        var output = DcpCompiler.Compile(source);
        var header = Encoding.ASCII.GetBytes("RLOOKDCP");
        Check(output.AsSpan().StartsWith(header), "real shared compiler returns an RLOOK payload");
        Check(output.Length >= 12 && System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(output.AsSpan(8, 4)) == 1,
            "real synthetic profile keeps the expected RLOOK v1 header");
        Check(output.AsSpan().IndexOf(Encoding.UTF8.GetBytes(sourceName)) >= 0,
            "real ABI preserves a non-BMP UTF-8 source filename");

        for (var index = 0; index < 8; index++)
        {
            var repeated = DcpCompiler.Compile(source);
            Check(repeated.AsSpan().StartsWith(header), "real blob release loop iteration " + (index + 1));
        }

        for (var index = 0; index < 8; index++)
        {
            try
            {
                _ = DcpCompiler.Compile(missingTone);
                throw new Exception("missing-tone DCP was accepted");
            }
            catch (DcpCompileException error)
            {
                Check(error.Reason == DcpErrorReason.MissingToneCurve,
                    "real ABI preserves the missing-tone error reason (iteration " + (index + 1) + ")");
            }
        }
    }
}
