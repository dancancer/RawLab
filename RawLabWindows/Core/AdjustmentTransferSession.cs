using System.Collections.Concurrent;
using System.IO;

namespace RawLab.Windows;

public sealed record AdjustmentTransferTarget(string Path,SavedEdit DefaultEdit,AdjustmentTransferContext Context,Func<bool>? IsCurrent=null);
public enum AdjustmentStatus { Applied, Unchanged, Skipped, Blocked, Conflict, Failed }
public sealed record AdjustmentOutcome(string TargetID,AdjustmentStatus Status,PhotoEditState? Saved=null,Exception? Error=null,bool RequiresHistoryDecision=false);
public sealed record PreparedAdjustmentTransfer(Guid ID,AdjustmentPayload Payload,IReadOnlyList<PreparedAdjustmentTarget> Targets,
    AdjustmentHistoryAction Action = AdjustmentHistoryAction.Paste, OriginalIdentity? FrozenSource = null,
    IReadOnlyList<AdjustmentTransferNotice>? Notices = null)
{
    public IReadOnlyList<AdjustmentTransferNotice> EffectiveNotices(IReadOnlyList<AdjustmentOutcome> outcomes)
    {
        ArgumentNullException.ThrowIfNull(outcomes);
        if (outcomes.Count == 0) return [];
        var effective = Targets.Where(target => target.Error == null && outcomes.Any(outcome =>
            StringComparer.OrdinalIgnoreCase.Equals(outcome.TargetID, target.ID) &&
            outcome.Status is AdjustmentStatus.Applied or AdjustmentStatus.Unchanged));
        return effective.SelectMany(target => target.Notices ?? []).Distinct().ToArray();
    }
}
public sealed record PreparedAdjustmentTarget(string ID,string DisplayName,PhotoEditState? Original,SavedEdit? Candidate,bool Unchanged,Func<bool>? IsCurrent,Exception? Error,long EditGeneration=0,
    IReadOnlyList<AdjustmentTransferNotice>? Notices=null);
public enum AdjustmentHistoryAction { Paste, Edit, Preset, Synchronize }
public enum AdjustmentHistoryState { Applied, Undone, RedoInvalidated }
public sealed record AdjustmentHistoryPart(Guid ID,Guid? PriorHead,OriginalIdentity Identity,string DisplayName,SavedEdit? Before,SavedEdit? After,AdjustmentHistoryState State);
public sealed record AdjustmentHistoryTransaction(Guid ID,AdjustmentHistoryAction Action,IReadOnlySet<AdjustmentField> Fields,IReadOnlyList<AdjustmentHistoryPart> Parts);

// 编辑器线程拥有提交与历史；prepare 可在独立资源队列运行，不修改会话。
public sealed class AdjustmentTransferSession(EditStore store)
{
    private readonly Dictionary<Guid,Dictionary<string,AdjustmentOutcome>> outcomes=[];
    private readonly Dictionary<string,PhotoEditState> knownRecords=new(StringComparer.OrdinalIgnoreCase);
    // 预检可在后台读取；代次只标记本会话的编辑，不写入磁盘。
    private readonly ConcurrentDictionary<string,long> editGenerations=new(StringComparer.OrdinalIgnoreCase);
    public long EditGeneration(string path)=>editGenerations.GetValueOrDefault(Path.GetFullPath(path));
    private readonly Dictionary<string,Guid?> heads=new(StringComparer.OrdinalIgnoreCase);
    private readonly List<AdjustmentHistoryTransaction> history=[];
    public IReadOnlyList<AdjustmentHistoryTransaction> Transactions => history.Select(t=>t with {
        Fields=t.Fields.ToHashSet(),Parts=t.Parts.Select(p=>p with {Before=p.Before?.Copy(),After=p.After?.Copy()}).ToArray()}).ToArray();
    public AdjustmentPayload? Clipboard {get;private set;}
    public bool IsCurrentSave(PhotoEditState saved)=>saved.SameAs(knownRecords.GetValueOrDefault(saved.Identity.Path));
    internal void RememberExternalSave(PhotoEditState saved)=>Remember(saved);
    internal PhotoEditState RepairLegacyNormalX3f(PhotoEditState loaded,Adjustments settings)
    {
        ArgumentNullException.ThrowIfNull(loaded);
        ArgumentNullException.ThrowIfNull(settings);
        if(loaded.Edit is not {} edit)return loaded;
        var candidate=settings.Clone();
        if(!candidate.RepairLegacyNormalX3f(loaded.Identity.Path))return loaded;
        var repaired=candidate.Capture();
        if(edit.Settings.Lens==null)repaired=repaired with {Lens=null};
        var saved=store.SaveState(loaded.Identity,edit with {Settings=repaired},expectedCurrent:loaded);
        settings.SelectX3fMode(X3fMode.Normal);
        RememberExternalSave(saved);
        return saved;
    }
    internal (PhotoEditState Record,Adjustments Settings) RepairLegacyNormalX3fOnOpen(
        string input,Func<string,(PhotoEditState Record,Adjustments Settings)>? load = null)
    {
        load ??= path => {
            var state=store.ReadState(path);
            return (state,state.Edit?.Settings.Restore() ?? PhotoInput.PrepareDefaultSettings(path));
        };
        for(var attempt=0;;attempt++)
        {
            var (loaded,settings)=load(input);
            try
            {
                var repaired=RepairLegacyNormalX3f(loaded,settings);
                if(attempt>0 && ReferenceEquals(repaired,loaded))RememberExternalSave(repaired);
                return (repaired,settings);
            }
            catch(AdjustmentOperationExpiredException) when(attempt<2)
            {
            }
        }
    }
    internal void AdoptExternalProcessingMigration(PhotoEditState saved)
    {
        var key=saved.Identity.Path;
        for(var i=history.Count-1;i>=0;i--)
        {
            var parts=history[i].Parts.Where(part=>!SamePath(part.Identity.Path,key)).ToArray();
            if(parts.Length==0)history.RemoveAt(i);else history[i]=history[i] with {Parts=parts};
        }
        heads.Remove(key);Remember(saved);
    }
    public PhotoEditState ResetToUnmodified(string path)
    {
        var cleared=store.ResetToUnmodified(path);
        AdoptExternalProcessingMigration(cleared);
        return cleared;
    }
    public AdjustmentPayload Copy(AdjustmentScope scope,SavedEdit source,AdjustmentTransferContext context)
    {var payload=AdjustmentTransfer.Capture(scope,source,context);Clipboard=payload;return payload;}
    public PreparedAdjustmentTransfer Prepare(AdjustmentPayload payload,IEnumerable<AdjustmentTransferTarget> targets,
        AdjustmentHistoryAction action = AdjustmentHistoryAction.Paste,OriginalIdentity? frozenSource=null)
    {
        payload.Validate();
        if(action==AdjustmentHistoryAction.Synchronize && frozenSource==null)throw new ArgumentException("Missing synchronization source identity");
        var physical=new HashSet<string>(StringComparer.Ordinal);
        var prepared=new List<PreparedAdjustmentTarget>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var target in targets) {
            var id=Path.GetFullPath(target.Path);if(!seen.Add(id))continue;
            if(action==AdjustmentHistoryAction.Synchronize &&
                (target.DefaultEdit.Identity.StableKey==frozenSource!.StableKey || !physical.Add(target.DefaultEdit.Identity.StableKey)))continue;
            try {
                if(target.IsCurrent?.Invoke()==false)throw Draft();
                var generation=EditGeneration(id);
                var rawOriginal=store.ReadState(id);
                if(!target.DefaultEdit.Identity.SameFile(rawOriginal.Identity))throw new PhotoChangedException();
                var original=X3fModeReset.RepairLegacyNormalX3f(rawOriginal).State;
                var before=original.Edit ?? X3fModeReset.RepairLegacyNormalX3f(new PhotoEditState(original.Identity,target.DefaultEdit)).State.Edit!;
                if(!before.Identity.SameFile(original.Identity))throw new PhotoChangedException();
                var notices=new List<AdjustmentTransferNotice>();
                var candidate=AdjustmentTransfer.Prepare(payload,before,target.Context with {OnTransferNotice=notices.Add});
                prepared.Add(new(id,Path.GetFileName(id),original,candidate.Copy(),candidate.SameAs(before),target.IsCurrent,null,generation,notices));
            }catch(Exception error) {prepared.Add(new(id,Path.GetFileName(id),null,null,false,target.IsCurrent,error));}
        }
        var mergedNotices=prepared.Where(t=>t.Notices!=null).SelectMany(t=>t.Notices!).Distinct().ToList();
        return new(Guid.NewGuid(),payload,prepared.AsReadOnly(),action,frozenSource,mergedNotices);
    }
    public IReadOnlyList<AdjustmentOutcome> Apply(PreparedAdjustmentTransfer operation,IReadOnlySet<string>? skipping=null)
    {
        skipping ??=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if(operation.Targets.Any(t=>t.Error!=null && !skipping.Contains(t.ID)))return operation.Targets.Select(t=>
            new AdjustmentOutcome(t.ID,AdjustmentStatus.Blocked,Error:t.Error ?? Unresolved("target preflight"))).ToArray();
        if(!outcomes.TryGetValue(operation.ID,out var cache))outcomes[operation.ID]=cache=new(StringComparer.OrdinalIgnoreCase);
        var results=new List<AdjustmentOutcome>();
        foreach(var target in operation.Targets) {
            if(cache.TryGetValue(target.ID,out var cached) && cached.Status is AdjustmentStatus.Applied or AdjustmentStatus.Unchanged or AdjustmentStatus.Skipped) {results.Add(cached);continue;}
            AdjustmentOutcome result;
            if(operation.Action==AdjustmentHistoryAction.Synchronize &&
                (operation.FrozenSource==null || target.Original?.Identity.StableKey==operation.FrozenSource.StableKey))
                result=new(target.ID,AdjustmentStatus.Blocked,Error:Unresolved("synchronization source"));
            else if(skipping.Contains(target.ID))result=new(target.ID,AdjustmentStatus.Skipped);
            else if(target.IsCurrent?.Invoke()==false)result=new(target.ID,AdjustmentStatus.Blocked,Error:Draft());
            else if(target.Original is {} original && target.Candidate is {} candidate) {
                try {
                    original.Identity.RequireCurrent();
                    if(EditGeneration(target.ID)!=target.EditGeneration)throw new AdjustmentOperationExpiredException();
                    if(target.Unchanged)result=new(target.ID,AdjustmentStatus.Unchanged,original);
                    else {
                        var saved=store.SaveState(original.Identity,candidate);
                        Record(operation.ID,operation.Action,operation.Payload.Fields,target.DisplayName,original,saved);
                        result=new(target.ID,AdjustmentStatus.Applied,saved);
                    }
                }catch(Exception error) when(error is PhotoChangedException or AdjustmentOperationExpiredException){result=new(target.ID,AdjustmentStatus.Conflict,Error:error);}
                 catch(Exception error){result=new(target.ID,AdjustmentStatus.Failed,Error:error);}
            }else result=new(target.ID,AdjustmentStatus.Blocked,Error:target.Error);
            cache[target.ID]=result;results.Add(result);
        }
        return results;
    }
    public AdjustmentOutcome CommitEdit(PhotoEditState before,SavedEdit edit,SavedEdit? defaultEdit=null,Func<bool>? isCurrent=null,
        bool clearMigrationReceipt=false)
    {
        var id=before.Identity.Path;
        if(isCurrent?.Invoke()==false)return new(id,AdjustmentStatus.Blocked,Error:Draft());
        try {
            if(!edit.Identity.SameFile(before.Identity))throw new PhotoChangedException();
            if(knownRecords.TryGetValue(id,out var committed) && committed.Identity.SameFile(before.Identity))before=committed;
            var desired=before.Edit==null && edit.SameAs(defaultEdit) ? null : edit;
            var saved=store.SaveState(before.Identity,desired,clearMigrationReceipt);
            if(SavedEdit.Same(before.Edit,saved.Edit)){Remember(saved);return new(id,AdjustmentStatus.Unchanged,saved);}
            Record(Guid.NewGuid(),AdjustmentHistoryAction.Edit,new HashSet<AdjustmentField>(),Path.GetFileName(id),before,saved);
            return new(id,AdjustmentStatus.Applied,saved);
        }catch(Exception error){return new(id,AdjustmentStatus.Failed,Error:error);}
    }
    public Guid? PhotoHistoryID(string path,bool undo)
    {
        var id=Path.GetFullPath(path);var desired=undo ? AdjustmentHistoryState.Applied : AdjustmentHistoryState.Undone;
        return (undo ? history.AsEnumerable().Reverse() : history).FirstOrDefault(t=>t.Parts.Any(p=>SamePath(p.Identity.Path,id) && p.State==desired))?.ID;
    }
    public IReadOnlyList<AdjustmentOutcome> UndoPhoto(string path,Guid? transaction=null,Func<string,bool>? isCurrent=null)=>HistoryPhoto(path,transaction,true,isCurrent);
    public IReadOnlyList<AdjustmentOutcome> RedoPhoto(string path,Guid? transaction=null,Func<string,bool>? isCurrent=null)=>HistoryPhoto(path,transaction,false,isCurrent);
    public IReadOnlyList<AdjustmentOutcome> UndoTransaction(Guid id,IReadOnlySet<string>? skipping=null,Func<string,bool>? isCurrent=null)=>RunHistory(id,null,true,skipping,isCurrent);
    public IReadOnlyList<AdjustmentOutcome> RedoTransaction(Guid id,IReadOnlySet<string>? skipping=null,Func<string,bool>? isCurrent=null)=>RunHistory(id,null,false,skipping,isCurrent);
    private IReadOnlyList<AdjustmentOutcome> HistoryPhoto(string path,Guid? transaction,bool undo,Func<string,bool>? isCurrent)
    {
        var id=transaction ?? PhotoHistoryID(path,undo);
        return id is {} value ? RunHistory(value,Path.GetFullPath(path),undo,null,isCurrent) : [];
    }
    private IReadOnlyList<AdjustmentOutcome> RunHistory(Guid id,string? photo,bool undo,IReadOnlySet<string>? skipping,Func<string,bool>? isCurrent)
    {
        skipping ??=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var transaction=history.FindIndex(t=>t.ID==id);if(transaction<0)return [];
        var desired=undo ? AdjustmentHistoryState.Applied : AdjustmentHistoryState.Undone;
        var selected=history[transaction].Parts.Select((p,i)=>(Part:p,Index:i)).Where(p=>p.Part.State==desired && (photo==null || SamePath(p.Part.Identity.Path,photo))).ToArray();
        var prepared=new Dictionary<int,PhotoEditState>();var rejected=new Dictionary<int,AdjustmentOutcome>();
        foreach(var (part,index) in selected) {
            var key=part.Identity.Path;if(skipping.Contains(key))continue;
            try {
                if(isCurrent?.Invoke(key)==false)throw Draft();
                part.Identity.RequireCurrent();
                if(!knownRecords.TryGetValue(key,out var current) || !current.Identity.SameFile(part.Identity))throw new PhotoChangedException();
                if(heads.GetValueOrDefault(key)!=(undo ? part.ID : part.PriorHead) || !SavedEdit.Same(current.Edit,undo ? part.After : part.Before))
                    throw new AdjustmentHistoryOrderException();
                prepared[index]=current;
            }catch(Exception error){rejected[index]=new(key,error is PhotoChangedException or AdjustmentHistoryOrderException ? AdjustmentStatus.Conflict : AdjustmentStatus.Blocked,Error:error,RequiresHistoryDecision:true);}
        }
        if(rejected.Count>0)return selected.Select(p=>rejected.GetValueOrDefault(p.Index) ?? new(p.Part.Identity.Path,
            skipping.Contains(p.Part.Identity.Path) ? AdjustmentStatus.Skipped : AdjustmentStatus.Blocked,Error:Unresolved("history conflict"))).ToArray();
        var results=new List<AdjustmentOutcome>();
        foreach(var (part,index) in selected) {
            var key=part.Identity.Path;
            if(!prepared.TryGetValue(index,out var current)){results.Add(new(key,AdjustmentStatus.Skipped));continue;}
            if(isCurrent?.Invoke(key)==false){results.Add(new(key,AdjustmentStatus.Blocked,Error:Draft(),RequiresHistoryDecision:true));continue;}
            try {
                var saved=store.SaveState(current.Identity,undo ? part.Before : part.After);
                Remember(saved);heads[key]=undo ? part.PriorHead : part.ID;
                var parts=history[transaction].Parts.ToArray();parts[index]=part with {State=undo ? AdjustmentHistoryState.Undone : AdjustmentHistoryState.Applied};
                history[transaction]=history[transaction] with {Parts=parts};results.Add(new(key,AdjustmentStatus.Applied,saved));
            }catch(PhotoChangedException error){results.Add(new(key,AdjustmentStatus.Conflict,Error:error,RequiresHistoryDecision:true));}
             catch(Exception error){results.Add(new(key,AdjustmentStatus.Failed,Error:error));}
        }
        return results;
    }
    private void Record(Guid id,AdjustmentHistoryAction action,IReadOnlySet<AdjustmentField> fields,string name,PhotoEditState before,PhotoEditState after)
    {
        var key=after.Identity.Path;var priorHead=before.SameAs(knownRecords.GetValueOrDefault(key)) ? heads.GetValueOrDefault(key) : null;
        Remember(after);
        for(var i=0;i<history.Count;i++)history[i]=history[i] with {Parts=history[i].Parts.Select(p=>SamePath(p.Identity.Path,key) && p.State==AdjustmentHistoryState.Undone
            ? p with {State=AdjustmentHistoryState.RedoInvalidated} : p).ToArray()};
        var part=new AdjustmentHistoryPart(Guid.NewGuid(),priorHead,after.Identity,name,before.Edit?.Copy(),after.Edit?.Copy(),AdjustmentHistoryState.Applied);
        heads[key]=part.ID;var index=history.FindIndex(t=>t.ID==id);
        if(index<0)history.Add(new(id,action,fields.ToHashSet(),new[]{part}));
        else history[index]=history[index] with {Parts=history[index].Parts.Append(part).ToArray()};
    }
    private void Remember(PhotoEditState saved)
    {
        var key=saved.Identity.Path;
        knownRecords[key]=saved.Copy();
        editGenerations.AddOrUpdate(key,1,(_,generation)=>generation+1);
    }
    private static bool SamePath(string a,string b)=>StringComparer.OrdinalIgnoreCase.Equals(a,b);
    private static AdjustmentTransferException Draft()=>new(AdjustmentFailure.Draft);
    private static AdjustmentTransferException Unresolved(string detail)=>new(AdjustmentFailure.Incompatible,"unresolved "+detail);
}
