using RawLab.Windows;
using System.Text;
using System.Text.Json;

internal static class LookLibraryToleranceChecks
{
    private static int checks;

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        checks++;
    }

    private static void Reject(Action action, string message, LookLibraryError? expected = null)
    {
        try
        {
            action();
        }
        catch (LookLibraryException error)
        {
            Check(expected == null || error.Error == expected, message + $" (got {error.Error})");
            return;
        }
        throw new Exception("Accepted invalid look library operation: " + message);
    }

    internal static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "RawLab-looks-tolerance-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            MixedOneBadAndManyGood(Path.Combine(root, "mixed"));
            IdentityOverlapsAndPreciseDelete(Path.Combine(root, "overlaps"));
            PathSafetyAndSurrogates(Path.Combine(root, "safety-surrogates"));
            FileLevelFailuresPreserveBytes(Path.Combine(root, "file-failures"));
            Console.WriteLine($"PASS: {checks} look library tolerance checks");
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { }
        }
    }

    // 分支 1：「1 坏 + N 好」逐条容错、ID 占用、写回字节兼容（unreadable 排有效条目后）与精确删除。
    private static void MixedOneBadAndManyGood(string directory)
    {
        Directory.CreateDirectory(directory);
        var sourceA = Path.Combine(directory, "alpha.cube");
        var sourceB = Path.Combine(directory, "beta.vlt");
        var sourceC = Path.Combine(directory, "gamma.dcp");
        File.WriteAllText(sourceA, "cube-a");
        File.WriteAllText(sourceB, "vlt-b");
        File.WriteAllBytes(sourceC, [1, 2, 3]);

        var library = new LookLibrary(
            directory,
            compileDcp: _ => Encoding.ASCII.GetBytes("RLOOKDCP"),
            validateLook: path => Path.GetExtension(path).ToLowerInvariant() switch
            {
                ".cube" => new LookValidation(LookFormat.Cube, 0),
                ".vlt" => new LookValidation(LookFormat.Vlt, 1, true),
                _ => new LookValidation(LookFormat.Rlook, 1)
            });

        var goodA = library.ImportLook(sourceA);
        var goodB = library.ImportLook(sourceB);
        var registryPath = Path.Combine(directory, "registry.json");
        var badId = Guid.NewGuid().ToString("D");
        var badFileName = badId + ".cube";
        File.WriteAllText(Path.Combine(directory, badFileName), "future-lut");

        // 含未知字段与 \u00e9 转义的坏条目插在有效条目之前，验证重读隔离且写回时退至有效条目之后并逐字节保留原文。
        var badJson = "{\"Id\":\"" + badId + "\",\"Name\":\"Future\\u00e9\",\"FileName\":\"" + badFileName + "\",\"SourceName\":\"future.cube\",\"Format\":99,\"FormatVersion\":0,\"FutureField\":\"caf\\u00e9\"}";
        var originalJson = File.ReadAllText(registryPath);
        var looksStart = originalJson.IndexOf("\"Looks\": [", StringComparison.Ordinal);
        Check(looksStart >= 0, "registry splice point");
        var spliced = originalJson.Insert(looksStart + "\"Looks\": [".Length, "\n    " + badJson + ",");
        File.WriteAllText(registryPath, spliced);

        var reloaded = new LookLibrary(
            directory,
            compileDcp: _ => Encoding.ASCII.GetBytes("RLOOKDCP"),
            validateLook: _ => new LookValidation(LookFormat.Rlook, 1));
        Check(reloaded.Looks.Select(item => item.Id).SequenceEqual([goodA.Id, goodB.Id]),
            "one unreadable look entry leaves all valid looks readable");
        var unreadable = reloaded.ListUnreadable().Single();
        Check(unreadable.Id == badId && unreadable.Name == "Future\u00e9" && unreadable.FileName == badFileName && unreadable.Json == badJson,
            "unreadable look retains best-effort identity, name, file name, and exact raw JSON");

        // 重命名与新增导入：写回必须保留原文，且坏条目排在所有有效条目之后，旧版格式字段顺序一致。
        reloaded.RenamePath(goodA.Path, "Alpha Renamed");
        var goodCId = Guid.NewGuid().ToString("D");
        var ids = new Queue<string>([badId, badId, goodCId]);
        var idChecked = new LookLibrary(
            directory,
            compileDcp: _ => Encoding.ASCII.GetBytes("RLOOKDCP"),
            validateLook: _ => new LookValidation(LookFormat.Rlook, 1),
            makeId: () => ids.Dequeue());
        var goodC = idChecked.ImportLook(sourceC);
        Check(goodC.Id == goodCId, "new look import skips ID occupied by an unreadable entry");

        var afterWrite = File.ReadAllText(registryPath);
        Check(afterWrite.Contains(badJson, StringComparison.Ordinal),
            "rename and import pass the unreadable look entry through byte-for-byte");
        using (var doc = JsonDocument.Parse(afterWrite))
        {
            var array = doc.RootElement.GetProperty("Looks").EnumerateArray().ToArray();
            Check(array.Length == 4 &&
                  array[0].GetProperty("Id").GetString() == goodA.Id &&
                  array[1].GetProperty("Id").GetString() == goodB.Id &&
                  array[2].GetProperty("Id").GetString() == goodC.Id &&
                  array[3].GetRawText() == badJson,
                "valid looks precede unreadable entries in persisted registry array");
        }

        // 若 ID 生成器持续碰撞坏条目 ID，拒绝覆盖并报错。
        var alwaysCollides = new LookLibrary(
            directory,
            compileDcp: _ => Encoding.ASCII.GetBytes("RLOOKDCP"),
            validateLook: _ => new LookValidation(LookFormat.Rlook, 1),
            makeId: () => badId);
        Reject(() => alwaysCollides.ImportLook(sourceC), "exhausted ID collision against unreadable entry", LookLibraryError.InvalidRegistry);

        // 删除坏条目后清理关联孤立文件、保留有效条目，且回到旧版完全可读结构。
        idChecked.RemoveUnreadable(unreadable);
        Check(idChecked.ListUnreadable().Count == 0 && !File.Exists(Path.Combine(directory, badFileName)),
            "removing unreadable look deletes its entry and unreferenced file");
        Check(new LookLibrary(directory).Looks.Select(item => item.Name).SequenceEqual(["Alpha Renamed", "beta", "gamma"]),
            "valid looks survive unreadable look removal");
        Reject(() => idChecked.RemoveUnreadable(unreadable), "stale unreadable removal requires fresh snapshot", LookLibraryError.Changed);
    }

    private static void IdentityOverlapsAndPreciseDelete(string directory)
    {
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "valid.cube");
        File.WriteAllText(source, "valid-cube");
        var library = new LookLibrary(directory, validateLook: _ => new LookValidation(LookFormat.Cube, 0));
        var valid = library.ImportLook(source);
        var registryPath = Path.Combine(directory, "registry.json");

        // 同 ID 坏条目、两个共用真实磁盘 <guid>.cube 的重复非法 ID 坏条目、以及非对象坏条目共存。
        var sharedBadId = Guid.NewGuid().ToString("D");
        var sharedBadFileName = sharedBadId + ".cube";
        var sharedBadPath = Path.Combine(directory, sharedBadFileName);
        File.WriteAllText(sharedBadPath, "shared-unreadable-cube");
        var twin = "{\"Id\":\"" + valid.Id + "\",\"Name\":\"Twin\",\"FileName\":\"" + valid.FileName + "\",\"SourceName\":\"twin.cube\",\"Format\":99,\"FormatVersion\":0}";
        var alpha = "{\"Id\":\"0\",\"Name\":\"Alpha\",\"FileName\":\"" + sharedBadFileName + "\",\"SourceName\":\"alpha.cube\",\"Format\":99,\"FormatVersion\":0}";
        var beta = "{\"Id\":\"0\",\"Name\":\"Beta\",\"FileName\":\"" + sharedBadFileName + "\",\"SourceName\":\"beta.cube\",\"Format\":99,\"FormatVersion\":0}";
        var scalar = "123";
        var text = File.ReadAllText(registryPath);
        var idx = text.IndexOf("\"Looks\": [", StringComparison.Ordinal) + "\"Looks\": [".Length;
        File.WriteAllText(registryPath, text.Insert(idx, "\n    " + twin + ",\n    " + alpha + ",\n    " + beta + ",\n    " + scalar + ","));

        var reloaded = new LookLibrary(directory);
        Check(reloaded.Looks.Single().Id == valid.Id && reloaded.ListUnreadable().Count == 4,
            "twin ID, duplicate illegal IDs, and scalar item isolate without breaking valid look");

        var twinEntry = reloaded.ListUnreadable().Single(item => item.Json == twin);
        reloaded.RemoveUnreadable(twinEntry);
        Check(File.Exists(valid.Path) && reloaded.Looks.Single().Id == valid.Id,
            "removing twin-ID unreadable entry preserves the valid look and its shared file");

        var betaEntry = reloaded.ListUnreadable().Single(item => item.Json == beta);
        reloaded.RemoveUnreadable(betaEntry);
        Check(reloaded.ListUnreadable().Select(item => item.Json).SequenceEqual([alpha, scalar]) &&
              File.ReadAllText(registryPath).Contains(alpha, StringComparison.Ordinal) &&
              !File.ReadAllText(registryPath).Contains(beta, StringComparison.Ordinal) &&
              File.Exists(sharedBadPath),
            "deleting second duplicate-ID unreadable entry removes only itself and preserves shared guid cube on disk");

        var alphaEntry = reloaded.ListUnreadable().Single(item => item.Json == alpha);
        reloaded.RemoveUnreadable(alphaEntry);
        Check(!File.Exists(sharedBadPath) && reloaded.ListUnreadable().Select(item => item.Json).SequenceEqual([scalar]),
            "deleting last unreadable reference removes the orphaned guid cube on disk");
    }

    // 路径越界、非 GUID 同目录外部 LUT、ADS 语法、非规范大括号 GUID 与单条孤立 UTF-16 代理转义（\uD800）。
    private static void PathSafetyAndSurrogates(string directory)
    {
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "valid.cube");
        File.WriteAllText(source, "valid-cube");
        var library = new LookLibrary(directory, validateLook: _ => new LookValidation(LookFormat.Cube, 0));
        var valid = library.ImportLook(source);
        var registryPath = Path.Combine(directory, "registry.json");

        var parentOutside = Path.Combine(Path.GetDirectoryName(directory)!, "outside.cube");
        var unmanagedInside = Path.Combine(directory, "external-unmanaged.cube");
        var bracedGuidFile = Path.Combine(directory, "{00000000-0000-0000-0000-000000000001}.cube");
        File.WriteAllText(parentOutside, "outside-user-lut");
        File.WriteAllText(unmanagedInside, "unmanaged-user-lut");
        File.WriteAllText(bracedGuidFile, "braced-guid-lut");

        var surrogateId = Guid.NewGuid().ToString("D");
        var badEntries = new[]
        {
            "{\"Id\":\"1\",\"Name\":\"ParentSlash\",\"FileName\":\"../outside.cube\",\"SourceName\":\"outside.cube\",\"Format\":99,\"FormatVersion\":0}",
            "{\"Id\":\"2\",\"Name\":\"ParentBackslash\",\"FileName\":\"..\\\\outside.cube\",\"SourceName\":\"outside.cube\",\"Format\":99,\"FormatVersion\":0}",
            "{\"Id\":\"3\",\"Name\":\"AbsoluteOutside\",\"FileName\":\"" + JsonEncodedText.Encode(parentOutside).ToString() + "\",\"SourceName\":\"outside.cube\",\"Format\":99,\"FormatVersion\":0}",
            "{\"Id\":\"4\",\"Name\":\"RegistrySelf\",\"FileName\":\"registry.json\",\"SourceName\":\"registry.json\",\"Format\":99,\"FormatVersion\":0}",
            "{\"Id\":\"5\",\"Name\":\"AdsStream\",\"FileName\":\"registry.json:stream.cube\",\"SourceName\":\"stream.cube\",\"Format\":99,\"FormatVersion\":0}",
            "{\"Id\":\"6\",\"Name\":\"UnmanagedExternal\",\"FileName\":\"external-unmanaged.cube\",\"SourceName\":\"external-unmanaged.cube\",\"Format\":99,\"FormatVersion\":0}",
            "{\"Id\":\"7\",\"Name\":\"BracedGuid\",\"FileName\":\"{00000000-0000-0000-0000-000000000001}.cube\",\"SourceName\":\"braced.cube\",\"Format\":99,\"FormatVersion\":0}",
            "{\"Id\":\"" + surrogateId + "\",\"Name\":\"Bad\\uD800\",\"FileName\":\"" + surrogateId + ".cube\",\"SourceName\":\"bad.cube\",\"Format\":1,\"FormatVersion\":0}",
            "{\"\\uD800\":1}"
        };

        var raw = File.ReadAllText(registryPath);
        var idx = raw.IndexOf("\"Looks\": [", StringComparison.Ordinal) + "\"Looks\": [".Length;
        File.WriteAllText(registryPath, raw.Insert(idx, "\n    " + string.Join(",\n    ", badEntries) + ","));

        var reloaded = new LookLibrary(directory);
        Check(reloaded.Looks.Single().Id == valid.Id && reloaded.ListUnreadable().Count == badEntries.Length,
            "path-unsafe and lone-surrogate items isolate without failing valid looks");
        var surrogateNameEntry = reloaded.ListUnreadable().Single(item => item.Id == surrogateId);
        var surrogateKeyEntry = reloaded.ListUnreadable().Single(item => item.Json == "{\"\\uD800\":1}");
        Check(surrogateNameEntry.Name == null && surrogateKeyEntry.Id == null && surrogateKeyEntry.Name == null,
            "lone surrogate escapes clear undecodable string fields while retaining raw JSON");

        reloaded.RenamePath(valid.Path, "Valid Renamed");
        var persisted = File.ReadAllText(registryPath);
        Check(persisted.Contains(surrogateNameEntry.Json, StringComparison.Ordinal) &&
              persisted.Contains(surrogateKeyEntry.Json, StringComparison.Ordinal),
            "lone-surrogate entries pass through Persist byte-for-byte");

        foreach (var bad in reloaded.ListUnreadable().ToArray())
            reloaded.RemoveUnreadable(bad);

        Check(File.ReadAllText(parentOutside) == "outside-user-lut" &&
              File.ReadAllText(unmanagedInside) == "unmanaged-user-lut" &&
              File.ReadAllText(bracedGuidFile) == "braced-guid-lut" &&
              File.Exists(registryPath) &&
              File.Exists(valid.Path) &&
              reloaded.Looks.Single().Name == "Valid Renamed" &&
              reloaded.ListUnreadable().Count == 0,
            "removing path-unsafe and non-GUID unreadable entries never deletes external files or registry.json");
    }

    // 分支 2：文件级整体损坏（语法、根结构、未知/重复根键、版本、有效条目重复 ID、非法外部别名、根级孤立代理对）仍整库报错且保留原字节。
    private static void FileLevelFailuresPreserveBytes(string directory)
    {
        Directory.CreateDirectory(directory);
        var registryPath = Path.Combine(directory, "registry.json");
        var sharedId = Guid.NewGuid().ToString("D");
        var validEntry = "{\"Id\":\"" + sharedId + "\",\"Name\":\"A\",\"FileName\":\"" + sharedId + ".cube\",\"SourceName\":\"a.cube\",\"Format\":1,\"FormatVersion\":0}";
        var validEntryDup = "{\"Id\":\"" + sharedId + "\",\"Name\":\"B\",\"FileName\":\"" + sharedId + ".cube\",\"SourceName\":\"b.cube\",\"Format\":1,\"FormatVersion\":0}";

        var invalidRegistries = new (string Label, string Json)[]
        {
            ("malformed-json", "{ broken"),
            ("non-object-root", "[]"),
            ("missing-version", "{\"Looks\":[]}"),
            ("future-version", "{\"Version\":2,\"Looks\":[]}"),
            ("decimal-version", "{\"Version\":1.5,\"Looks\":[]}"),
            ("duplicate-root-key", "{\"Version\":1,\"Version\":1,\"Looks\":[]}"),
            ("unknown-root-key", "{\"Version\":1,\"Looks\":[],\"FutureRoot\":true}"),
            ("missing-looks", "{\"Version\":1}"),
            ("null-looks", "{\"Version\":1,\"Looks\":null}"),
            ("duplicate-valid-id", "{\"Version\":1,\"Looks\":[" + validEntry + "," + validEntryDup + "]}"),
            ("relative-external-name", "{\"Version\":1,\"Looks\":[],\"ExternalNames\":{\"relative.cube\":\"Rel\"}}"),
            ("control-char-external-name", "{\"Version\":1,\"Looks\":[],\"ExternalNames\":{\"" + JsonEncodedText.Encode(Path.Combine(directory, "ext.cube")).ToString() + "\":\"Bad\\nName\"}}"),
            ("surrogate-root-key", "{\"\\uD800\":1,\"Version\":1,\"Looks\":[]}"),
            ("surrogate-external-key", "{\"Version\":1,\"Looks\":[],\"ExternalNames\":{\"\\uD800\":\"Alias\"}}"),
            ("surrogate-external-value", "{\"Version\":1,\"Looks\":[],\"ExternalNames\":{\"" + JsonEncodedText.Encode(Path.Combine(directory, "ext.cube")).ToString() + "\":\"Bad\\uD800\"}}")
        };

        foreach (var (label, json) in invalidRegistries)
        {
            File.WriteAllText(registryPath, json);
            var bytes = File.ReadAllBytes(registryPath);
            Reject(() => new LookLibrary(directory), label + " direct load", LookLibraryError.InvalidRegistry);
            var loaded = LookLibrary.TryLoad(directory, out var unavailable, out var loadError);
            Check(!loaded && unavailable == null &&
                  loadError is LookLibraryException { Error: LookLibraryError.InvalidRegistry } &&
                  File.ReadAllBytes(registryPath).SequenceEqual(bytes),
                label + " fails whole library with InvalidRegistry and preserves bytes");
        }
    }
}
