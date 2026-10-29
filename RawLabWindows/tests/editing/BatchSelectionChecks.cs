using RawLab.Windows;
using System.Runtime.InteropServices;

static class BatchSelectionChecks
{
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateHardLink(string link, string existing, IntPtr unused);
    static void Check(bool condition,string message) { if(!condition)throw new Exception(message); }
    static void Rejected(Action action,string message) { try { action(); }catch { return; }throw new Exception(message); }
    public static void Run()
    {
        var root=Path.Combine(Path.GetTempPath(),"rawlab-collection-"+Guid.NewGuid());Directory.CreateDirectory(root);
        try {
            var source=Path.Combine(root,"same.raw");var other=Path.Combine(root,"other");Directory.CreateDirectory(other);
            var target=Path.Combine(other,"same.raw");File.WriteAllText(source,"source");File.WriteAllText(target,"target");
            var alias=Path.Combine(root,"alias.raw");Check(CreateHardLink(alias,source,IntPtr.Zero),"Create source hardlink fixture");
            var selection=new BatchSelectionSession();selection.Add([alias,source,target,target],source);
            Check(selection.Photos.Count==2 && selection.Photos[0].Path==source,"Stable identity deduplicates aliases and retains current record path");
            var sourceKey=selection.Photos[0].ID;var targetKey=selection.Photos[1].ID;
            Check(selection.SynchronizationTargets(sourceKey).Single().Path==target,"Source is excluded even when selected with alias and same basename");
            selection.BeginEditing(targetKey);selection.ReturnToCollection();
            Check(selection.CurrentID==null && selection.ReturnPosition==1 && selection.Selected.Count==2,"Micro-edit return retains selection and position");
            var sync=Guid.NewGuid();selection.RecordSynchronization(sync,true);selection.RecordSynchronization(Guid.NewGuid(),false);
            Check(selection.LastSynchronization==sync,"Unchanged operation does not replace collection history");
            var store=new EditStore(Path.Combine(root,"edits"));var settings=new Adjustments();settings.Set(Parameter.Exposure,.5);
            store.Save(source,settings.Capture(),null);settings.Set(Parameter.Exposure,1);settings.Set(Parameter.Contrast,20);
            var look=Path.Combine(root,"look.cube");File.WriteAllText(look,"original look");store.Save(target,settings.Capture(),look);
            var transfer=new AdjustmentTransferSession(store);
            var payload=AdjustmentTransfer.Capture(AdjustmentScope.Custom(new HashSet<AdjustmentField>{AdjustmentField.Exposure}),
                store.VersionedState(source).Edit!,new(source,true));
            var clipboard=transfer.Copy(AdjustmentScope.Custom(new HashSet<AdjustmentField>{AdjustmentField.Contrast}),
                store.VersionedState(target).Edit!,new(target,true));
            AdjustmentTransferTarget Descriptor(string path)=>new(path,new(OriginalIdentity.Read(path),new Adjustments().Capture(),null),new(path,true));
            var synchronized=transfer.Prepare(payload,[Descriptor(alias),Descriptor(source),Descriptor(target),Descriptor(target)],
                AdjustmentHistoryAction.Synchronize,OriginalIdentity.Read(source));
            Check(synchronized.Targets.Count==1 && synchronized.Targets[0].ID==target,"Session excludes source hardlinks and duplicate targets");
            var sourceRecord=store.VersionedState(source);
            Check(transfer.Apply(synchronized).Single().Status==AdjustmentStatus.Applied,"Scoped synchronization writes target only");
            Check(store.VersionedState(source).SameAs(sourceRecord) && store.Find(target)!.Settings.Restore()[Parameter.Contrast]==20,"Synchronization preserves source and target micro-edits");
            Check(ReferenceEquals(transfer.Clipboard,clipboard),"Synchronization retains independent clipboard");
            var sourcePrepared=transfer.Prepare(payload,[Descriptor(source)]).Targets.Single();
            Check(transfer.Apply(synchronized with{ID=Guid.NewGuid(),Targets=new[]{sourcePrepared}}).Single().Status==AdjustmentStatus.Blocked,
                "Write boundary refuses a forged source target");
            transfer.UndoTransaction(synchronized.ID);
            var journal=new BatchJournal(Path.Combine(root,"batch"));var output=Path.Combine(root,"output");Directory.CreateDirectory(output);
            var exporter=new BatchSelectionExport(store,journal,edit=>edit.Look);
            string? Draft(string id)=>id==targetKey ? "Save, discard or skip" : null;
            var blocked=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,Draft);
            Check(!blocked.Ready,"All selected target drafts are preflighted");
            var skipped=exporter.Prepare(selection,[targetKey],ExportFormat.Png,1024,output,Draft);
            Check(skipped.Ready && skipped.Rows.Count==1 && selection.Selected.Count==2,"Skip affects only the operation");
            Check(!exporter.Prepare(selection,[sourceKey,targetKey],ExportFormat.Png,1024,output,_=>null).Ready,"Empty export has no confirmation");
            var review=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,_=>null);
            review.Rows[0].Settings!.Values[(int)Parameter.Exposure]=3;
            Rejected(()=>exporter.Freeze(selection,review,_=>null),"Mutable UI snapshot cannot diverge from committed record");
            review=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,_=>null);
            settings.Set(Parameter.Contrast,30);store.Save(target,settings.Capture(),look);
            Rejected(()=>exporter.Freeze(selection,review,_=>null),"Late committed edit invalidates confirmation");
            review=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,_=>null);
            Rejected(()=>exporter.Freeze(selection,review,Draft),"Late active draft invalidates confirmation");
            File.WriteAllText(look,"changed look");Rejected(()=>exporter.Freeze(selection,review,_=>null),"Look checksum invalidates confirmation");
            review=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,_=>null);
            selection.Select(sourceKey,false);Rejected(()=>exporter.Freeze(selection,review,_=>null),"Late selection invalidates confirmation");selection.Select(sourceKey,true);
            var job=exporter.Freeze(selection,review,_=>null);
            Rejected(()=>exporter.Freeze(selection,review,_=>null),"Pending task is preserved until explicitly discarded");
            Check(job.Mode==BatchJob.PerTargetFrozen && job.Items[1].Frozen!.Settings.Restore()[Parameter.Contrast]==30,"Each item keeps its own micro-edit");
            settings.Set(Parameter.Exposure,3);store.Save(target,settings.Capture(),look);File.Delete(look);
            var exposures=new List<double>();BatchRunner.Run(journal.Load()!,journal,false,CancellationToken.None,(_,_)=>{},(_,edit,_,path)=>{
                exposures.Add(edit[Parameter.Exposure]);File.WriteAllText(path,"rendered");
            });
            Check(exposures.SequenceEqual([.5,1]),"Runner never reads live editor or deleted library look");
            var owned=job.Items[1].Frozen!.Look!;Check(File.Exists(owned),"Task owns copied look");
            journal.Discard(job);Check(!File.Exists(owned) && File.Exists(source) && File.Exists(target),"Cleanup preserves original photos");
            var aiSettings=new Adjustments { AIDenoiseEnabled=true };store.Save(source,aiSettings.Capture(),null);
            var capabilityChecks=0;var capabilityAvailable=true;
            var aiExporter=new BatchSelectionExport(store,journal,edit=>edit.Look,_=>{
                capabilityChecks++;if(!capabilityAvailable)throw new InvalidOperationException("GPU unavailable");
            });
            var aiReview=aiExporter.Prepare(selection,[targetKey],ExportFormat.Png,512,output,_=>null);
            Check(aiReview.Ready && capabilityChecks==1 && aiReview.Rows[0].Settings!.AIDenoiseEnabled,
                "RAW collection preflight checks AI capability and retains enabled AI without preparing pixels");
            capabilityAvailable=false;
            Rejected(()=>aiExporter.Freeze(selection,aiReview,_=>null),"AI becoming unavailable invalidates collection confirmation");
            capabilityAvailable=true;
            var aiJob=aiExporter.Freeze(selection,aiReview,_=>null,3,"selected-gpu");
            Check(journal.Load() is {AIBackend:3,AIDeviceID:"selected-gpu"},"Collection GPU choice is persisted before the export window opens");
            Check(aiJob.Items.Single().Frozen!.Settings.AIDenoiseEnabled,"Collection freeze retains AI for export-stage preparation");
            journal.Discard(aiJob);
            var unavailable=new BatchSelectionExport(store,journal,edit=>edit.Look,_=>throw new InvalidOperationException("GPU unavailable"));
            Check(!unavailable.Prepare(selection,[targetKey],ExportFormat.Png,512,output,_=>null).Ready,"Collection preflight reports unavailable AI capability");
            File.Delete(target);selection.RefreshFailures();Check(selection.Failures.ContainsKey(targetKey),"Missing input remains marked per photo");
        }finally{Directory.Delete(root,true);}
        Console.WriteLine("PASS: collection identity, navigation, preflight, revision guards and frozen export");
    }
}
