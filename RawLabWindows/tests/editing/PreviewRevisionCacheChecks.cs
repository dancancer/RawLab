using System.Text.Json;
using RawLab.Windows;

internal static class PreviewRevisionCacheChecks
{
    private sealed record TestRevisionKey(
        string Path,
        OriginalIdentity Source,
        OriginalIdentity? Lut,
        string RecipeFingerprint,
        int Edge);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    internal static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-preview-rev-cache-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var photoA = Path.Combine(root, "photoA.dng");
            var photoB = Path.Combine(root, "photoB.dng");
            var photoC = Path.Combine(root, "photoC.dng");
            var lutPath = Path.Combine(root, "film.cube");
            File.WriteAllBytes(photoA, new byte[64]);
            File.WriteAllBytes(photoB, new byte[96]);
            File.WriteAllBytes(photoC, new byte[80]);
            File.WriteAllText(lutPath, "LUT_3D_SIZE 2\n");

            var cache = new PreviewRevisionCache<TestRevisionKey, byte[]>(
                maximumBytes: 256,
                bytes => bytes.Length,
                maximumEntries: 8);

            var renders = 0;
            byte[] RenderOrReuse(string photo, string? lut, Adjustments settings, int edge)
            {
                var source = OriginalIdentity.Read(photo);
                var lutId = lut == null ? null : OriginalIdentity.Read(lut);
                var recipeFingerprint = JsonSerializer.Serialize(settings.Capture());
                var key = new TestRevisionKey(photo, source, lutId, recipeFingerprint, edge);
                if (cache.TryGet(key, out var hit))
                {
                    return hit;
                }
                renders++;
                var frame = new byte[64];
                frame[0] = (byte)renders;
                cache.Set(key, frame);
                return frame;
            }

            var recipeA = new Adjustments();
            var recipeB = new Adjustments();

            // 1. 同一张图、同一 revision 重复请求命中缓存；切去另一张图再切回原图仍命中（不被清空）。
            var firstA = RenderOrReuse(photoA, lutPath, recipeA, 2000);
            var secondA = RenderOrReuse(photoA, lutPath, recipeA, 2000);
            Check(ReferenceEquals(firstA, secondA) && renders == 1,
                "Repeated preview request with unchanged revision must hit cache");

            _ = RenderOrReuse(photoB, lutPath, recipeB, 2000);
            Check(renders == 2, "Second photo must render once");

            var backToA = RenderOrReuse(photoA, lutPath, recipeA, 2000);
            Check(ReferenceEquals(firstA, backToA) && renders == 2,
                "Switching back to photoA with unchanged revision must reuse cached preview");

            // 2. 失效路径一（编辑提交）：修改 recipe 参数后必须失效重渲；撤销回原参数可再次命中。
            recipeA.Set(Parameter.Exposure, 0.5);
            var editedA = RenderOrReuse(photoA, lutPath, recipeA, 2000);
            Check(!ReferenceEquals(firstA, editedA) && renders == 3,
                "Editing recipe must invalidate preview cache and trigger re-render");

            recipeA.Set(Parameter.Exposure, 0.0);
            var revertedA = RenderOrReuse(photoA, lutPath, recipeA, 2000);
            Check(ReferenceEquals(firstA, revertedA) && renders == 3,
                "Reverting recipe back to cached revision hits existing entry");

            // 3. 失效路径二（文件外部改动）：外部修改源文件内容/长度/时间戳后必须失效重渲。
            File.WriteAllBytes(photoA, new byte[128]);
            var modifiedFileA = RenderOrReuse(photoA, lutPath, recipeA, 2000);
            Check(!ReferenceEquals(firstA, modifiedFileA) && renders == 4,
                "External file modification must invalidate preview cache via stat identity");

            // 4. LRU 字节预算淘汰：第 5 条插入超预算，必须淘汰最久未用的 photoB，刚命中的 photoA 保留。
            var recipeC = new Adjustments();
            _ = RenderOrReuse(photoC, lutPath, recipeC, 2000);
            Check(renders == 5 && cache.TotalBytes <= 256 && cache.Count == 4,
                "5th entry exceeding byte budget must evict LRU entry and stay within 256-byte budget");

            var photoAAfterEviction = RenderOrReuse(photoA, lutPath, recipeA, 2000);
            Check(ReferenceEquals(modifiedFileA, photoAAfterEviction) && renders == 5,
                "Recently used photoA must remain cached after LRU eviction");

            _ = RenderOrReuse(photoB, lutPath, recipeB, 2000);
            Check(renders == 6,
                "Least-recently-used photoB must have been evicted and re-rendered");
            Check(cache.Hits >= 4 && cache.Misses >= 6,
                "PreviewRevisionCache must track Hits and Misses accurately");
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
        Console.WriteLine("PASS: PreviewRevisionCache checks passed");
    }
}
