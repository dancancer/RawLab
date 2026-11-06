using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;
public sealed class LibraryEntry : INotifyPropertyChanged
{
    public static readonly HashSet<string> RawExtensions = PhotoInput.RawExtensions;
    public static bool IsRaw(string path) => PhotoInput.IsRaw(path);
    public static readonly HashSet<string> RasterExtensions = PhotoInput.RasterExtensions;
    public static bool IsRaster(string path) => PhotoInput.IsRaster(path);
    public static bool IsImage(string path) => IsRaw(path) || IsRaster(path);
    internal static string ImageFilter => string.Join(';',RawExtensions.Concat(RasterExtensions).Select(x=>"*."+x));
    public string Path { get; }
    public string Name => System.IO.Path.GetFileName(IsFolder ? System.IO.Path.TrimEndingDirectorySeparator(Path) : Path) is { Length: > 0 } name ? name : Path;
    public bool IsFolder { get; }
    private Task? directoryLoad;
    private bool directoryLoaded;
    private BitmapSource? thumbnail;
    private bool thumbnailVisible;
    private int thumbnailRequest;
    public BitmapSource? Thumbnail { get=>thumbnail; private set { thumbnail=value; OnPropertyChanged(); } }
    public LibraryEntry? Parent { get; private set; }
    public ObservableCollection<LibraryEntry> Children { get; } = [];
    public ObservableCollection<LibraryEntry> Folders { get; } = [];
    public IReadOnlyList<LibraryEntry> Photos { get; private set; } = [];
    private bool isSelected;
    private bool isMarked;
    private bool isExpanded;
    public bool IsSelected { get=>isSelected; set { if(isSelected==value)return;isSelected=value;OnPropertyChanged(); } }
    public bool IsMarked { get=>isMarked; set { if(isMarked==value)return;isMarked=value;OnPropertyChanged(); } }
    public bool IsExpanded { get=>isExpanded; set { if(isExpanded==value)return;isExpanded=value;OnPropertyChanged(); } }
    public LibraryEntry(string path, bool folder)
    {
        Path = path;
        IsFolder = folder;
        if (folder)
        {
            var placeholder = new LibraryEntry("", false);
            Children.Add(placeholder);
            Folders.Add(placeholder);
        }
    }
    public async Task Load()
    {
        if (!IsFolder || directoryLoaded) return;
        var load = directoryLoad ??= ReadDirectory();
        try { await load; }
        finally { if (ReferenceEquals(load, directoryLoad)) directoryLoad = null; }
    }
    internal async Task Reload()
    {
        if (directoryLoad != null)
        {
            try { await Load(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        directoryLoaded = false;
        await Load();
    }
    private async Task ReadDirectory()
    {
        var paths = await Task.Run(() => new DirectoryInfo(Path).EnumerateFileSystemInfos()
            .Where(entry => (entry.Attributes & (FileAttributes.Hidden | FileAttributes.ReparsePoint)) == 0)
            .Where(entry => entry is DirectoryInfo || IsImage(entry.FullName))
            .OrderBy(entry => entry is DirectoryInfo ? 0 : 1).ThenBy(entry => entry.Name, StringComparer.CurrentCultureIgnoreCase)
            .Select(entry => (entry.FullName, Folder: entry is DirectoryInfo)).ToArray());
        var existing = Children.ToDictionary(entry => entry.Path, StringComparer.Ordinal);
        var entries = paths.Select(path =>
            existing.TryGetValue(path.FullName, out var entry) && entry.IsFolder == path.Folder
                ? entry : new LibraryEntry(path.FullName, path.Folder) { Parent = this }).ToArray();
        Photos = entries.Where(entry => !entry.IsFolder).ToArray();
        // Keep existing folder instances and expansion state while refreshing children.
        foreach (var removed in Folders.Except(entries).ToArray()) Folders.Remove(removed);
        var index = 0;
        foreach (var child in entries.Where(entry => entry.IsFolder))
        {
            var position = Folders.IndexOf(child);
            if (position < 0) Folders.Insert(index, child);
            else if (position != index) Folders.Move(position, index);
            index++;
        }
        Children.Clear();
        foreach (var entry in entries) Children.Add(entry);
        directoryLoaded = true;
    }
    private static readonly SemaphoreSlim ThumbnailSlots = new(2);
    public async Task LoadThumbnail()
    {
        if (IsFolder || thumbnailVisible || string.IsNullOrEmpty(Path)) return;
        thumbnailVisible = true;
        var request = ++thumbnailRequest;
        await ThumbnailSlots.WaitAsync();
        try
        {
            if (request != thumbnailRequest) return;
            var image = await Task.Run(() => RenderEngine.Thumbnail(Path));
            if (request == thumbnailRequest) Thumbnail = image;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or DllNotFoundException or BadImageFormatException or EntryPointNotFoundException) { }
        finally { ThumbnailSlots.Release(); }
    }
    public void ReleaseThumbnail()
    {
        if (!thumbnailVisible) return;
        thumbnailVisible = false;
        ++thumbnailRequest;
        Thumbnail = null;
    }
    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName]string? name=null)=>PropertyChanged?.Invoke(this,new(name));
    // 文件树的读屏名称取自 ToString：读目录或文件名，不读类型名
    public override string ToString()=>Name;
}
internal sealed class Library
{
    private readonly string settingsPath=System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"RawLab","folders.json");
    public ObservableCollection<LibraryEntry> Roots { get; }=[];
    public Library()
    {
        try { foreach(var path in JsonSerializer.Deserialize<string[]>(File.ReadAllText(settingsPath)) ?? [])Roots.Add(new(path,true)); }
        catch(Exception ex) when(ex is IOException or UnauthorizedAccessException or JsonException) { }
    }
    public void Add(string path) { path=System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path)); if(!Roots.Any(r=>System.IO.Path.TrimEndingDirectorySeparator(r.Path).Equals(path,StringComparison.OrdinalIgnoreCase)))Roots.Add(new(path,true)); Save(); }
    public void Remove(LibraryEntry entry) { Roots.Remove(entry); Save(); }
    private void Save() { Directory.CreateDirectory(System.IO.Path.GetDirectoryName(settingsPath)!); var temp=settingsPath+".tmp"; File.WriteAllText(temp,JsonSerializer.Serialize(Roots.Select(r=>r.Path))); File.Move(temp,settingsPath,true); }
}
