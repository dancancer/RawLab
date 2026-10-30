using System.IO;

namespace RawLab.Windows;

public sealed record CollectionPhoto(string ID,string Path,OriginalIdentity Identity)
{
    public static string Key(OriginalIdentity identity)=>identity.StableKey;
    public static CollectionPhoto Read(string path)
    {
        var identity=OriginalIdentity.Read(path);return new(Key(identity),identity.Path,identity);
    }
    public void Validate()
    {
        var current=OriginalIdentity.Read(Path);
        if(Key(current)!=ID || !Identity.SameFile(current))throw new EditPersistenceConflict();
    }
}

public sealed class BatchSelectionSession
{
    private readonly List<CollectionPhoto> photos=[];
    private readonly HashSet<string> selected=new(StringComparer.Ordinal);
    private readonly Dictionary<string,string> failures=new(StringComparer.Ordinal);
    public IReadOnlyList<CollectionPhoto> Photos=>photos.AsReadOnly();
    public IReadOnlySet<string> Selected=>selected;
    public IReadOnlyDictionary<string,string> Failures=>failures;
    public IEnumerable<CollectionPhoto> SelectedPhotos=>photos.Where(photo=>selected.Contains(photo.ID));
    public string? CurrentID {get;private set;}
    public int ReturnPosition {get;private set;}
    public Guid? LastSynchronization {get;private set;}
    public void Add(IEnumerable<string> paths,string? currentPath=null)
    {
        CollectionPhoto? current=null;
        if(currentPath!=null)try{current=CollectionPhoto.Read(currentPath);}catch(IOException){}catch(UnauthorizedAccessException){}
        foreach(var path in paths) {
            CollectionPhoto photo;
            try {
                photo=CollectionPhoto.Read(path);
                if(current?.ID==photo.ID)photo=current;
            }catch(Exception error) {
                var full=System.IO.Path.GetFullPath(path);var id=full.ToUpperInvariant();
                photo=new(id,full,new(full,0,0,0));failures[id]=error.Message;
            }
            if(photos.Any(existing=>existing.ID==photo.ID))continue;
            photos.Add(photo);selected.Add(photo.ID);
        }
    }
    public void Select(string id,bool value) {if(!photos.Any(photo=>photo.ID==id))return;if(value)selected.Add(id);else selected.Remove(id);}
    public void SelectAll(bool value) {selected.Clear();if(value)selected.UnionWith(photos.Select(photo=>photo.ID));}
    public void Remove(string id) {
        var index=photos.FindIndex(photo=>photo.ID==id);if(index<0)return;
        photos.RemoveAt(index);selected.Remove(id);failures.Remove(id);if(CurrentID==id)CurrentID=null;
        if(index<ReturnPosition)ReturnPosition--;
        ReturnPosition=Math.Clamp(ReturnPosition,0,Math.Max(0,photos.Count-1));
    }
    public void BeginEditing(string id) {var index=photos.FindIndex(photo=>photo.ID==id);if(index<0){CurrentID=null;return;}CurrentID=id;ReturnPosition=index;}
    public void ReturnToCollection()=>CurrentID=null;
    public void RecordSynchronization(Guid id,bool changed) {if(changed)LastSynchronization=id;}
    public IReadOnlyList<CollectionPhoto> SynchronizationTargets(string sourceID)=>SelectedPhotos.Where(photo=>photo.ID!=sourceID).ToArray();
    public string CanonicalPath(string path)
    {
        var key=CollectionPhoto.Key(OriginalIdentity.Read(path));return photos.FirstOrDefault(photo=>photo.ID==key)?.Path ?? path;
    }
    public void RefreshFailures()
    {
        foreach(var photo in photos)try{photo.Validate();failures.Remove(photo.ID);}catch(Exception error){failures[photo.ID]=error.Message;}
    }
}

public sealed record CollectionExportRow(CollectionPhoto Photo,VersionedPhotoEdit? Record=null,
    AdjustmentSnapshot? Settings=null,string? Look=null,string? LookSHA256=null,string? LookName=null,string? Error=null);
public sealed record CollectionExportReview(IReadOnlyList<string> SelectionIDs,IReadOnlyList<CollectionExportRow> Rows,
    ExportFormat Format,int? LongEdge,string OutputDirectory)
{
    public bool Ready=>Rows.Count>0 && Rows.All(row=>row.Error==null && row.Record!=null && row.Settings!=null);
}

public sealed class BatchSelectionExport(EditStore store,BatchJournal journal,Func<SavedEdit,string?> resolveLook,
    Action<string>? validateAI=null)
{
    public CollectionExportReview Prepare(BatchSelectionSession selection,IReadOnlyCollection<string> skipping,
        ExportFormat format,int? longEdge,string outputDirectory,Func<string,string?> activeFailure)
        =>Prepare(selection.SelectedPhotos.ToArray(),skipping,format,longEdge,outputDirectory,activeFailure);
    public CollectionExportReview Prepare(IReadOnlyList<CollectionPhoto> photos,IReadOnlyCollection<string> skipping,
        ExportFormat format,int? longEdge,string outputDirectory,Func<string,string?> activeFailure)
    {
        if(!Enum.IsDefined(format) || longEdge is {} edge && !ExportSize.IsValid(edge))throw new ArgumentException("Invalid output settings");
        if(!Directory.Exists(outputDirectory))throw new DirectoryNotFoundException(Loc.Text("请选择输出文件夹。"));
        var rows=new List<CollectionExportRow>();
        foreach(var photo in photos.Where(photo=>!skipping.Contains(photo.ID))) {
            try {
                if(activeFailure(photo.ID) is {} draft)throw new InvalidOperationException(draft);
                photo.Validate();var record=store.VersionedState(photo.Path);
                if(!record.Identity.SameFile(photo.Identity))throw new EditPersistenceConflict();
                var settings=(record.Edit?.Settings.Restore() ?? PhotoInput.PrepareHDRInputSettings(photo.Path,new Adjustments())).Capture();
                if(format==ExportFormat.HdrJpeg && (settings.HDR is not {Mode:HDRMode.Hdr} || PhotoInput.ProbeHDR(photo.Path,out _)!=HDRProbeState.Supported))
                    throw new InvalidOperationException(Loc.Text("HDR JPEG 需要启用 HDR 编辑。"));
                if(settings.AIDenoiseEnabled) {
                    if(PhotoInput.IsX3f(photo.Path) && settings.X3fMode==X3fMode.Normal)throw new InvalidOperationException(Loc.Text("此 X3F 显影模式不支持 AI 降噪。"));
                    if(!PhotoInput.IsRaw(photo.Path))throw new InvalidOperationException(Loc.Text("AI 降噪仅支持 RAW 照片。"));
                    validateAI?.Invoke(photo.Path);
                }
                var look=record.Edit is {} edit ? resolveLook(edit) : null;
                if((record.Edit?.Look!=null || settings.MasterRecipeID!=null) && look==null)throw new FileNotFoundException(Loc.Text("外观不可用。"));
                var hash=look==null ? null : BatchFrozenSettings.Checksum(look);
                rows.Add(new(photo,record.Copy(),settings.Copy(),look,hash,look==null ? Loc.Text("中性") : System.IO.Path.GetFileNameWithoutExtension(look)));
            }catch(Exception error){rows.Add(new(photo,Error:error.Message));}
        }
        return new(photos.Select(photo=>photo.ID).ToArray(),rows,format,longEdge,System.IO.Path.GetFullPath(outputDirectory));
    }
    public BatchJob Freeze(BatchSelectionSession selection,CollectionExportReview review,Func<string,string?> activeFailure,int aiBackend=2,string aiDeviceID="")
    {
        if(!review.Ready || !selection.SelectedPhotos.Select(photo=>photo.ID).SequenceEqual(review.SelectionIDs))
            throw new InvalidOperationException(Loc.Text("照片选择已变化，请重新检查。"));
        var previous=journal.Load();
        if(previous!=null && previous.SelectedCount>previous.SucceededCount)
            throw new InvalidOperationException(Loc.Text("请先结束或完成当前导出任务。"));
        void Validate() {
            foreach(var row in review.Rows) {
                if(activeFailure(row.Photo.ID) is {} draft)throw new InvalidOperationException(draft);
                row.Photo.Validate();
                var current=store.VersionedState(row.Photo.Path);
                if(!current.SameAs(row.Record))throw new EditPersistenceConflict();
                var expected=(current.Edit?.Settings.Restore() ?? PhotoInput.PrepareHDRInputSettings(row.Photo.Path,new Adjustments())).Capture();
                if(review.Format==ExportFormat.HdrJpeg && (expected.HDR is not {Mode:HDRMode.Hdr} || PhotoInput.ProbeHDR(row.Photo.Path,out _)!=HDRProbeState.Supported))
                    throw new InvalidOperationException(Loc.Text("HDR JPEG 需要启用 HDR 编辑。"));
                if(!expected.SameAs(row.Settings!))throw new EditPersistenceConflict();
                if(expected.AIDenoiseEnabled) {
                    if(PhotoInput.IsX3f(row.Photo.Path) && expected.X3fMode==X3fMode.Normal)throw new InvalidOperationException(Loc.Text("此 X3F 显影模式不支持 AI 降噪。"));
                    if(!PhotoInput.IsRaw(row.Photo.Path))throw new InvalidOperationException(Loc.Text("AI 降噪仅支持 RAW 照片。"));
                    validateAI?.Invoke(row.Photo.Path);
                }
                if(row.Look!=null && BatchFrozenSettings.Checksum(row.Look)!=row.LookSHA256)
                    throw new InvalidOperationException(Loc.Text("外观已变化，请重新检查。"));
            }
        }
        Validate();var owned=new List<string>();
        try {
            Directory.CreateDirectory(journal.DirectoryPath);
            var items=review.Rows.Select((row,index)=>{
                var id=Guid.NewGuid();string? look=null;
                if(row.Look!=null) {
                    look=System.IO.Path.Combine(journal.DirectoryPath,id+System.IO.Path.GetExtension(row.Look));
                    owned.Add(look);File.Copy(row.Look,look);
                    if(BatchFrozenSettings.Checksum(look)!=row.LookSHA256)throw new IOException("Look changed while freezing");
                }
                return new BatchItem(id,row.Photo.Path,row.Photo.Identity){Selected=true,Frozen=new(){Ordinal=index,
                    Settings=row.Settings!,Look=look,LookSha256=row.LookSHA256,LookName=row.LookName!,
                    OutputFormat=review.Format,LongEdge=review.LongEdge}};
            }).ToList();
            Validate();
            var job=new BatchJob{Version=3,AIBackend=aiBackend,AIDeviceID=aiDeviceID,SettingsMode=BatchJob.PerTargetFrozen,Source=items[0].Input,
                Settings=items[0].Frozen!.Settings,Items=items,OutputFormat=review.Format,Png=review.Format==ExportFormat.Png,
                LongEdge=review.LongEdge,OutputDirectory=review.OutputDirectory};
            journal.Save(job);owned.Clear();
            if(previous!=null)try{journal.ReleaseResources(previous);}catch(IOException){}catch(UnauthorizedAccessException){}
            return job;
        }catch {foreach(var path in owned)if(File.Exists(path))File.Delete(path);throw;}
    }
}
