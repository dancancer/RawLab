using System.IO;
using System.Security.Cryptography;
using System.Reflection;
using System.Text.Json;

namespace RawLab.Windows;

internal static class EditedPhotoPreviewKey
{
    internal const int Edge = 256;
    internal static long ResourceHashCount => FileDigestCache.Shared.ComputeCount;
    internal static PhotoEditState PrepareState(PhotoEditState state) =>
        X3fModeReset.RepairLegacyNormalX3f(state).State;
    internal static PhotoEditState ReadState(EditStore store, string path) =>
        PrepareState(store.ReadState(path));
    internal static bool IsEdited(PhotoEditState state) => state.Edit is {} edit &&
        EditorAdjustmentRules.IsModified(new(EditorResetKind.All), edit);

    internal static string Create(PhotoEditState state, string? look, int edge = Edge, int aiBackend = 2, string aiDevice = "", string? rendererVersion = null)
    {
        if (state.Edit == null) throw new AdjustmentOperationExpiredException();
        var resources = ResourceFingerprint(state.Edit.Settings, look, FileDigestCache.Shared, aiBackend, aiDevice);
        return Digest(JsonSerializer.SerializeToUtf8Bytes(new { Schema = 1,
            Renderer = rendererVersion ?? typeof(EditedPhotoPreviewKey).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "development",
            Source = state.Identity,
            Adjustments = state.Edit, Resources = resources, Edge = edge }));
    }

    internal static string ResourceFingerprint(AdjustmentSnapshot settings, string? look, int aiBackend = 2, string aiDevice = "") =>
        ResourceFingerprint(settings, look, FileDigestCache.Shared, aiBackend, aiDevice);

    internal static string ResourceFingerprint(AdjustmentSnapshot settings, string? look, FileDigestCache digestCache, int aiBackend = 2, string aiDevice = "")
    {
        if (settings.HDR is { Mode: HDRMode.Hdr } hdr && !hdr.LookSettings.AssetIsAvailable(null, digestCache))
            throw new FileNotFoundException(Loc.Text("外观不可用。"));
        var fingerprints = ResourcePaths(settings, look).Select(path => {
            var (identity, sha256) = digestCache.GetDigest(path);
            return new { Identity = identity, SHA256 = sha256 };
        }).ToArray();
        return Digest(JsonSerializer.SerializeToUtf8Bytes(new { Files = fingerprints,
            Backend = settings.ActiveAIDenoise ? aiBackend : 0, Device = settings.ActiveAIDenoise ? aiDevice : "" }));
    }
    internal static IEnumerable<string> ResourcePaths(AdjustmentSnapshot settings, string? look)
    {
        if (settings.HDR is { Mode: HDRMode.Hdr } hdr) {
            if (hdr.LookSettings.AssetPath() is {} hdrLook) yield return hdrLook;
            if (hdr.CameraDevelopment?.CameraProfile is {} profile) yield return profile.AssetPath;
        } else if (look != null) yield return look;
        if (settings.ActiveAIDenoise) yield return Path.Combine(AppContext.BaseDirectory,"AI","DualDn","manifest.json");
    }
    private static string Digest(byte[] data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
}

internal sealed class EditedPhotoPreviewCache(string directory, int maximumEntries = 256, long maximumBytes = 64 * 1024 * 1024,
    Action<string, string>? moveFile = null, Action<TimeSpan>? sleep = null, Func<TimeSpan>? elapsed = null)
{
    private readonly object gate = new();
    internal byte[]? Read(string key)
    {
        lock (gate) {
            var path = Location(key);
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }
    }
    internal void Write(string key, byte[] data)
    {
        if (data.LongLength > maximumBytes) return;
        lock (gate) {
            var path = Location(key);
            AtomicFileWrite.Write(path, data, moveFile, sleep, elapsed);
            var entries = new DirectoryInfo(directory).EnumerateFiles("*.preview")
                .OrderBy(file => file.FullName == path ? 1 : 0).ThenBy(file => file.LastWriteTimeUtc).ToArray();
            var remaining = entries.Length; var bytes = entries.Sum(file => file.Length);
            foreach (var entry in entries) {
                if (remaining <= Math.Max(1,maximumEntries) && bytes <= maximumBytes) break;
                var length = entry.Length;entry.Delete();remaining--;bytes -= length;
            }
        }
    }
    private string Location(string key)
    {
        if (key.Length != 64 || key.Any(c => !char.IsAsciiHexDigit(c))) throw new ArgumentException("Invalid preview key.");
        return Path.Combine(directory,key + ".preview");
    }
}

// 监听资源的父目录，让原子替换及删除后恢复仍能使可见照片重新请求预览。
internal sealed class PhotoPreviewResourceWatch(Action changed) : IDisposable
{
    private readonly object gate = new();
    private readonly Dictionary<string,FileSystemWatcher> directories = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> files = new(StringComparer.OrdinalIgnoreCase);
    private bool disposed;
    internal void Watch(IEnumerable<string> paths)
    {
        lock(gate) {
            if(disposed)return;
            foreach(var path in paths) {
                var file=Path.GetFullPath(path);files.Add(file);
                var directory=Path.GetDirectoryName(file)!;
                if(directories.ContainsKey(directory) || !Directory.Exists(directory))continue;
                try {
                    var watcher=new FileSystemWatcher(directory) {
                        NotifyFilter=NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.CreationTime
                    };
                    watcher.Changed+=OnChanged;watcher.Created+=OnChanged;watcher.Deleted+=OnChanged;
                    watcher.Renamed+=(_,e)=> {Notify(e.OldFullPath);Notify(e.FullPath);};
                    watcher.EnableRaisingEvents=true;directories.Add(directory,watcher);
                } catch(Exception error) when(error is IOException or UnauthorizedAccessException) { }
            }
        }
    }
    private void OnChanged(object sender,FileSystemEventArgs args)=>Notify(args.FullPath);
    private void Notify(string path)
    {
        lock(gate) {if(!disposed && files.Contains(path))changed();}
    }
    public void Dispose()
    {
        FileSystemWatcher[] watchers;
        lock(gate) {
            disposed=true;watchers=directories.Values.ToArray();
            directories.Clear();files.Clear();
        }
        foreach(var watcher in watchers)watcher.Dispose();
    }
}
