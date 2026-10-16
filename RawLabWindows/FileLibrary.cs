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
    public string Name => System.IO.Path.GetFileName(IsFolder ? Path.TrimEnd('\\', '/') : Path);
    public bool IsFolder { get; }
    private bool loaded;
    private BitmapSource? thumbnail;
    private bool thumbnailVisible;
    public BitmapSource? Thumbnail { get=>thumbnail; private set { thumbnail=value; OnPropertyChanged(); } }
    public ObservableCollection<LibraryEntry> Children { get; }=[];
    public ObservableCollection<object> TreeChildren { get; }=[];
    private bool isSelected;
    private bool isExpanded;
    public bool IsSelected { get=>isSelected; set { if(isSelected==value)return;isSelected=value;OnPropertyChanged(); } }
    public bool IsExpanded { get=>isExpanded; set { if(isExpanded==value)return;isExpanded=value;OnPropertyChanged(); } }
    public LibraryEntry(string path,bool folder) { Path=path; IsFolder=folder; if(folder){var placeholder=new LibraryEntry("",false);Children.Add(placeholder);TreeChildren.Add(placeholder);} }
    public async Task Load()
    {
        if(!IsFolder || loaded)return;
        loaded=true;
        try
        {
            var entries=await Task.Run(()=>new DirectoryInfo(Path).EnumerateFileSystemInfos()
                .Where(f=>(f.Attributes&(FileAttributes.Hidden|FileAttributes.ReparsePoint))==0)
                .Where(f=>f is DirectoryInfo || IsImage(f.FullName))
                .OrderBy(f=>f is DirectoryInfo ? 0 : 1).ThenBy(f=>f.Name,StringComparer.CurrentCultureIgnoreCase)
                .Select(f=>(f.FullName,Folder:f is DirectoryInfo)).ToArray());
            Children.Clear(); foreach(var entry in entries)Children.Add(new(entry.FullName,entry.Folder));
            TreeChildren.Clear();foreach(var entry in Children.Where(e=>e.IsFolder))TreeChildren.Add(entry);
            var photos=Children.Where(e=>!e.IsFolder).ToArray();
            if(photos.Length>0)TreeChildren.Add(new PhotoGroup(photos));
        }
        catch { loaded=false; throw; }
    }
    private static readonly SemaphoreSlim ThumbnailSlots=new(2);
    public async Task LoadThumbnail()
    {
        thumbnailVisible=true;
        if(IsFolder || loaded || string.IsNullOrEmpty(Path))return;
        loaded=true;
        await ThumbnailSlots.WaitAsync();
        try { if(thumbnailVisible) { var image=await Task.Run(()=>RenderEngine.Thumbnail(Path));if(thumbnailVisible)Thumbnail=image; } }
        catch(Exception ex) when(ex is IOException or InvalidOperationException or DllNotFoundException or BadImageFormatException or EntryPointNotFoundException) { }
        finally { ThumbnailSlots.Release(); }
    }
    public void ReleaseThumbnail() { if(IsFolder)return;thumbnailVisible=false;loaded=false;Thumbnail=null; }
    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName]string? name=null)=>PropertyChanged?.Invoke(this,new(name));
}
public sealed record PhotoGroup(IReadOnlyList<LibraryEntry> Photos);
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
