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
    internal static HDRSourceInfo? ValidateHDRFormat(string path, AdjustmentSnapshot settings, ExportFormat format)
    {
        if (settings.HDR is not { Mode: HDRMode.Hdr } hdr) {
            if (format == ExportFormat.HdrJpeg) throw new InvalidOperationException(Loc.Text("HDR JPEG 需要启用 HDR 编辑。"));
            return null;
        }
        var raw = PhotoInput.IsRaw(path);
        var probe = raw ? PhotoInput.ProbeCameraRaw(path,out var info) : PhotoInput.ProbeHDR(path,out info);
        if (probe != HDRProbeState.Supported || info == null)
            throw new InvalidOperationException(Loc.Text(raw ? "不支持此相机 RAW 的 HDR 显影。" : "此照片没有可编辑的 HDR 增益图。"));
        if (settings.ProRAWDecodeVersion != (info.IsProRAW ? HDRNative.ProRAWDecodeVersion : (int?)null))
            throw new InvalidOperationException(Loc.Text("不支持此相机 RAW 的 HDR 显影。"));
        if (!hdr.CameraSettings.IsDefault && (!info.IsCameraRaw || info.IsProRAW))
            throw new HDRModeException(HDRModeFailure.UnsupportedSource);
        hdr.CameraSettings.CameraProfile?.RequireAsset();
        if (settings.HDRCameraAIEnabled && !PhotoInput.IsHDRCameraAICandidate(path,info))
            throw new InvalidOperationException(Loc.Text("此照片或构建尚不能使用 AI 降噪。"));
        if (!hdr.LookSettings.AssetIsAvailable())
            throw new AdjustmentTransferException(AdjustmentFailure.MissingLook, hdr.LookSettings.Name ?? "HDR LUT");
        return info;
    }

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
                ValidateHDRFormat(photo.Path,settings,format);
                var hdr = settings.HDR is { Mode: HDRMode.Hdr };
                if(settings.ActiveAIDenoise) {
                    if(PhotoInput.IsX3f(photo.Path) && settings.X3fMode==X3fMode.Normal)throw new InvalidOperationException(Loc.Text("此 X3F 显影模式不支持 AI 降噪。"));
                    if(!PhotoInput.IsRaw(photo.Path))throw new InvalidOperationException(Loc.Text("AI 降噪仅支持 RAW 照片。"));
                    validateAI?.Invoke(photo.Path);
                }
                var look=!hdr && record.Edit is {} edit ? resolveLook(edit) : null;
                if(!hdr && (record.Edit?.Look!=null || settings.MasterRecipeID!=null) && look==null)throw new FileNotFoundException(Loc.Text("外观不可用。"));
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
                ValidateHDRFormat(row.Photo.Path,expected,review.Format);
                if(!expected.SameAs(row.Settings!))throw new EditPersistenceConflict();
                if(expected.ActiveAIDenoise) {
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
                SourceIsProRAW=items[0].Frozen!.Settings.HDR is { Mode: HDRMode.Hdr } &&
                    items[0].Frozen!.Settings.ProRAWDecodeVersion == HDRNative.ProRAWDecodeVersion,
                SourceSupportsCameraHDR=items[0].Frozen!.Settings.HDR is { Mode: HDRMode.Hdr } && PhotoInput.IsCameraRaw(items[0].Input),
                Settings=items[0].Frozen!.Settings,Items=items,OutputFormat=review.Format,Png=review.Format==ExportFormat.Png,
                LongEdge=review.LongEdge,OutputDirectory=review.OutputDirectory};
            journal.Save(job);owned.Clear();
            if(previous!=null)try{journal.ReleaseResources(previous);}catch(IOException){}catch(UnauthorizedAccessException){}
            return job;
        }catch {foreach(var path in owned)if(File.Exists(path))File.Delete(path);throw;}
    }
}

internal sealed class BatchHDRPreparation(EditStore store, Func<SavedEdit,string?> resolveLook)
{
    internal static bool Required(BatchJob job) => job.Mode == BatchJob.UniformFrozen &&
        job.HasCameraHDRSource && job.Settings.HDR is { Mode: HDRMode.Hdr };

    private (VersionedPhotoEdit Record, BatchFrozenSettings Frozen) Candidate(BatchJob job, BatchItem item, int ordinal, bool validateFormat)
    {
        var record = store.VersionedState(item.Input);
        if (!record.Identity.SameFile(item.Identity)) throw new EditPersistenceConflict();
        var target = record.Edit ?? new SavedEdit(record.Identity,
            PhotoInput.PrepareHDRInputSettings(item.Input,new Adjustments()).Capture(),null);
        var source = new SavedEdit(new OriginalIdentity(job.Source,0,0,0),job.Settings,null);
        var hdr = job.Settings.HDR!;
        var fields = AdjustmentFields.HDRSupportedFor(hdr.ProcessingVersion);
        if (target.Settings.HDR is not { Mode: HDRMode.Hdr }) {
            if (hdr.Temperature == 6500 && hdr.Tint == 0) fields = fields.Where(field => !field.IsHDRRelative()).ToHashSet();
            if (hdr.ToneSettings.IsDefault) fields = fields.Except(AdjustmentFields.HDRTone).ToHashSet();
            if (hdr.ColorSettings.IsDefault) fields = fields.Except(AdjustmentFields.HDRColor).ToHashSet();
            if (hdr.RenditionSettings.IsDefault) fields = fields.Except(AdjustmentFields.HDRRendition).ToHashSet();
            if (hdr.EffectSettings == PhotoEffectsSettings.Default) fields = fields.Except(AdjustmentFields.HDREffects).ToHashSet();
            if (hdr.DetailSettings.IsDefault) fields = fields.Except(AdjustmentFields.HDRDetail).ToHashSet();
            if (hdr.LookSettings.IsDefault) fields = fields.Where(field => field != AdjustmentField.HdrLook).ToHashSet();
        }
        var targetInfo = BatchSelectionExport.ValidateHDRFormat(item.Input,target.Settings,validateFormat ? job.Format : ExportFormat.SdrJpeg);
        var payload = AdjustmentTransfer.Capture(AdjustmentScope.Custom(fields),source,
            new(job.Source,true,IsProRAW:job.SourceIsProRAW,SupportsCameraHDR:job.HasCameraHDRSource));
        var prepared = AdjustmentTransfer.Prepare(payload,target,
            new(item.Input,PhotoInput.IsRaw(item.Input),IsProRAW:targetInfo?.IsProRAW == true,SupportsCameraHDR:targetInfo?.IsCameraRaw == true));
        var isHDR = prepared.Settings.HDR is { Mode: HDRMode.Hdr };
        var look = isHDR ? null : resolveLook(prepared);
        if (!isHDR && (prepared.Look != null || prepared.Settings.MasterRecipeID != null) && look == null)
            throw new FileNotFoundException(Loc.Text("外观不可用。"));
        var frozen = new BatchFrozenSettings { Ordinal=ordinal,Settings=prepared.Settings,Look=look,
            LookSha256=look == null ? null : BatchFrozenSettings.Checksum(look),
            LookName=isHDR ? "HDR" : look == null ? Loc.Text("中性") : Path.GetFileNameWithoutExtension(look),
            OutputFormat=job.Format,LongEdge=job.LongEdge };
        frozen.Validate();
        return (record,frozen);
    }

    internal BatchFrozenSettings Prepare(BatchJob job, BatchItem item) => Candidate(job,item,0,false).Frozen;

    internal BatchJob Freeze(BatchJob job, BatchJournal journal, CancellationToken cancellation)
    {
        var work = job.Copy();
        var migrating = work.Mode != BatchJob.PerTargetFrozen;
        if (migrating) work.Items = work.Items.Where(item => item.Selected && item.CanSelect).ToList();
        var owned = new List<string>();
        try {
            Directory.CreateDirectory(journal.DirectoryPath);
            for (var index=0; index<work.Items.Count; index++) {
                cancellation.ThrowIfCancellationRequested();
                var item = work.Items[index];
                if (!migrating && !item.AwaitingTargetSettings) continue;
                // 已成功的旧任务项只保留原有结果，无需访问其原片或外观。
                if (item.Status == BatchStatus.Succeeded) {
                    work.Items[index] = item with { Frozen=work.SnapshotFor(item) with { Ordinal=index,Look=null } };
                    continue;
                }
                BatchFrozenSettings frozen;
                try {
                    var candidate = Candidate(work,item,index,true);
                    if (!store.VersionedState(item.Input).SameAs(candidate.Record)) throw new EditPersistenceConflict();
                    frozen = candidate.Frozen;
                } catch (Exception error) when (work.Started &&
                    error is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception) {
                    // 保存逐行失败，恢复后重试时再读取目标的调整。
                    work.Items[index] = item with { Status=BatchStatus.Failed,Error=error.Message,AwaitingTargetSettings=true };
                    continue;
                }
                if (frozen.Look is {} look) {
                    // 每次冻结使用新的资源名，避免异常退出留下的副本阻断重试。
                    item = item with { Id=Guid.NewGuid() };
                    var copy = Path.Combine(journal.DirectoryPath,item.Id+Path.GetExtension(look));
                    using (var output = new FileStream(copy,FileMode.CreateNew)) {
                        owned.Add(copy);
                        using var input = File.OpenRead(look);
                        input.CopyTo(output);
                    }
                    frozen = frozen with { Look=copy };
                    frozen.VerifyLook();
                }
                work.Items[index] = item with { Frozen=frozen,AwaitingTargetSettings=false };
            }
            work.Version=3; work.SettingsMode=BatchJob.PerTargetFrozen;
            cancellation.ThrowIfCancellationRequested();
            journal.Save(work);
            return work;
        } catch {
            foreach (var path in owned) File.Delete(path);
            throw;
        }
    }
}
