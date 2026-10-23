using System.IO;

namespace RawLab.Windows;

public sealed record AdjustmentTransferTarget(string Path,SavedEdit DefaultEdit,AdjustmentTransferContext Context,Func<bool>? IsCurrent=null);
public enum AdjustmentStatus { Applied, Unchanged, Skipped, Blocked, Conflict, Failed }
public sealed record AdjustmentOutcome(string TargetID,AdjustmentStatus Status,VersionedPhotoEdit? Saved=null,Exception? Error=null,bool RequiresHistoryDecision=false);
public sealed record PreparedAdjustmentTransfer(Guid ID,AdjustmentPayload Payload,IReadOnlyList<PreparedAdjustmentTarget> Targets);
public sealed record PreparedAdjustmentTarget(string ID,string DisplayName,VersionedPhotoEdit? Original,SavedEdit? Candidate,bool Unchanged,Func<bool>? IsCurrent,Exception? Error);
public enum AdjustmentHistoryAction { Paste, Edit }
public enum AdjustmentHistoryState { Applied, Undone, RedoInvalidated }
public sealed record AdjustmentHistoryPart(Guid ID,Guid? PriorHead,OriginalIdentity Identity,string DisplayName,SavedEdit? Before,SavedEdit? After,AdjustmentHistoryState State);
public sealed record AdjustmentHistoryTransaction(Guid ID,AdjustmentHistoryAction Action,IReadOnlySet<AdjustmentField> Fields,IReadOnlyList<AdjustmentHistoryPart> Parts);

// 编辑器线程拥有提交与历史；prepare 可在独立资源队列运行，不修改会话。
public sealed class AdjustmentTransferSession(EditStore store)
{
    private readonly Dictionary<Guid,Dictionary<string,AdjustmentOutcome>> outcomes=[];
    private readonly Dictionary<string,VersionedPhotoEdit> knownRecords=new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string,Guid?> heads=new(StringComparer.OrdinalIgnoreCase);
    private readonly List<AdjustmentHistoryTransaction> history=[];
    public IReadOnlyList<AdjustmentHistoryTransaction> Transactions => history.Select(t=>t with {
        Fields=t.Fields.ToHashSet(),Parts=t.Parts.Select(p=>p with {Before=p.Before?.Copy(),After=p.After?.Copy()}).ToArray()}).ToArray();
    public AdjustmentPayload? Clipboard {get;private set;}
    public AdjustmentPayload Copy(AdjustmentScope scope,SavedEdit source,AdjustmentTransferContext context)
    {var payload=AdjustmentTransfer.Capture(scope,source,context);Clipboard=payload;return payload;}
    public PreparedAdjustmentTransfer Prepare(AdjustmentPayload payload,IEnumerable<AdjustmentTransferTarget> targets)
    {
        payload.Validate();
        var prepared=new List<PreparedAdjustmentTarget>();var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var target in targets) {
            var id=Path.GetFullPath(target.Path);if(!seen.Add(id))continue;
            try {
                if(target.IsCurrent?.Invoke()==false)throw Draft();
                var original=store.VersionedState(id);var before=original.Edit ?? target.DefaultEdit;
                if(!target.DefaultEdit.Identity.SameFile(original.Identity) || !before.Identity.SameFile(original.Identity))throw new EditPersistenceConflict();
                var candidate=AdjustmentTransfer.Prepare(payload,before,target.Context);
                prepared.Add(new(id,Path.GetFileName(id),original,candidate.Copy(),candidate.SameAs(before),target.IsCurrent,null));
            }catch(Exception error) {prepared.Add(new(id,Path.GetFileName(id),null,null,false,target.IsCurrent,error));}
        }
        return new(Guid.NewGuid(),payload,prepared.AsReadOnly());
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
            if(skipping.Contains(target.ID))result=new(target.ID,AdjustmentStatus.Skipped);
            else if(target.IsCurrent?.Invoke()==false)result=new(target.ID,AdjustmentStatus.Blocked,Error:Draft());
            else if(target.Original is {} original && target.Candidate is {} candidate) {
                try {
                    if(!store.VersionedState(target.ID).SameAs(original))throw new EditPersistenceConflict();
                    if(target.Unchanged)result=new(target.ID,AdjustmentStatus.Unchanged,original);
                    else {
                        var saved=store.CompareAndSave(original,candidate);
                        Record(operation.ID,AdjustmentHistoryAction.Paste,operation.Payload.Fields,target.DisplayName,original,saved);
                        result=new(target.ID,AdjustmentStatus.Applied,saved);
                    }
                }catch(EditPersistenceConflict error){result=new(target.ID,AdjustmentStatus.Conflict,Error:error);}
                 catch(Exception error){result=new(target.ID,AdjustmentStatus.Failed,Error:error);}
            }else result=new(target.ID,AdjustmentStatus.Blocked,Error:target.Error);
            cache[target.ID]=result;results.Add(result);
        }
        return results;
    }
    public AdjustmentOutcome CommitEdit(VersionedPhotoEdit expected,SavedEdit edit,SavedEdit? defaultEdit=null,Func<bool>? isCurrent=null)
    {
        var id=expected.Identity.Path;
        if(isCurrent?.Invoke()==false)return new(id,AdjustmentStatus.Blocked,Error:Draft());
        try {
            if(expected.Edit==null && edit.SameAs(defaultEdit)) {
                if(!store.VersionedState(id).SameAs(expected))throw new EditPersistenceConflict();
                return new(id,AdjustmentStatus.Unchanged,expected);
            }
            var saved=store.CompareAndSave(expected,edit);
            if(saved.SameAs(expected))return new(id,AdjustmentStatus.Unchanged,saved);
            Record(Guid.NewGuid(),AdjustmentHistoryAction.Edit,new HashSet<AdjustmentField>(),Path.GetFileName(id),expected,saved);
            return new(id,AdjustmentStatus.Applied,saved);
        }catch(EditPersistenceConflict error){return new(id,AdjustmentStatus.Conflict,Error:error);}
         catch(Exception error){return new(id,AdjustmentStatus.Failed,Error:error);}
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
        var prepared=new Dictionary<int,VersionedPhotoEdit>();var rejected=new Dictionary<int,AdjustmentOutcome>();
        foreach(var (part,index) in selected) {
            var key=part.Identity.Path;if(skipping.Contains(key))continue;
            try {
                if(isCurrent?.Invoke(key)==false)throw Draft();
                var current=store.VersionedState(key);
                if(!current.Identity.SameFile(part.Identity) || !current.SameAs(knownRecords.GetValueOrDefault(key)) ||
                    heads.GetValueOrDefault(key)!=(undo ? part.ID : part.PriorHead) || !SavedEdit.Same(current.Edit,undo ? part.After : part.Before))throw new EditPersistenceConflict();
                prepared[index]=current;
            }catch(Exception error){rejected[index]=new(key,error is EditPersistenceConflict ? AdjustmentStatus.Conflict : AdjustmentStatus.Blocked,Error:error,RequiresHistoryDecision:true);}
        }
        if(rejected.Count>0)return selected.Select(p=>rejected.GetValueOrDefault(p.Index) ?? new(p.Part.Identity.Path,
            skipping.Contains(p.Part.Identity.Path) ? AdjustmentStatus.Skipped : AdjustmentStatus.Blocked,Error:Unresolved("history conflict"))).ToArray();
        var results=new List<AdjustmentOutcome>();
        foreach(var (part,index) in selected) {
            var key=part.Identity.Path;
            if(!prepared.TryGetValue(index,out var current)){results.Add(new(key,AdjustmentStatus.Skipped));continue;}
            if(isCurrent?.Invoke(key)==false){results.Add(new(key,AdjustmentStatus.Blocked,Error:Draft(),RequiresHistoryDecision:true));continue;}
            try {
                var saved=store.CompareAndSave(current,undo ? part.Before : part.After);
                knownRecords[key]=saved;heads[key]=undo ? part.PriorHead : part.ID;
                var parts=history[transaction].Parts.ToArray();parts[index]=part with {State=undo ? AdjustmentHistoryState.Undone : AdjustmentHistoryState.Applied};
                history[transaction]=history[transaction] with {Parts=parts};results.Add(new(key,AdjustmentStatus.Applied,saved));
            }catch(EditPersistenceConflict error){results.Add(new(key,AdjustmentStatus.Conflict,Error:error,RequiresHistoryDecision:true));}
             catch(Exception error){results.Add(new(key,AdjustmentStatus.Failed,Error:error));}
        }
        return results;
    }
    private void Record(Guid id,AdjustmentHistoryAction action,IReadOnlySet<AdjustmentField> fields,string name,VersionedPhotoEdit before,VersionedPhotoEdit after)
    {
        var key=after.Identity.Path;var priorHead=before.SameAs(knownRecords.GetValueOrDefault(key)) ? heads.GetValueOrDefault(key) : null;
        knownRecords[key]=after.Copy();
        for(var i=0;i<history.Count;i++)history[i]=history[i] with {Parts=history[i].Parts.Select(p=>SamePath(p.Identity.Path,key) && p.State==AdjustmentHistoryState.Undone
            ? p with {State=AdjustmentHistoryState.RedoInvalidated} : p).ToArray()};
        var part=new AdjustmentHistoryPart(Guid.NewGuid(),priorHead,after.Identity,name,before.Edit?.Copy(),after.Edit?.Copy(),AdjustmentHistoryState.Applied);
        heads[key]=part.ID;var index=history.FindIndex(t=>t.ID==id);
        if(index<0)history.Add(new(id,action,fields.ToHashSet(),new[]{part}));
        else history[index]=history[index] with {Parts=history[index].Parts.Append(part).ToArray()};
    }
    private static bool SamePath(string a,string b)=>StringComparer.OrdinalIgnoreCase.Equals(a,b);
    private static AdjustmentTransferException Draft()=>new(AdjustmentFailure.Draft);
    private static AdjustmentTransferException Unresolved(string detail)=>new(AdjustmentFailure.Incompatible,"unresolved "+detail);
}
