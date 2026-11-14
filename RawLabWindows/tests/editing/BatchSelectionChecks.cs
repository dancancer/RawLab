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
            var alias=source;
            if(OperatingSystem.IsWindows()) {
                alias=Path.Combine(root,"alias.raw");
                Check(CreateHardLink(alias,source,IntPtr.Zero),"Create source hardlink fixture");
            } else Console.WriteLine("SKIP Windows physical alias fixture on non-Windows; continue identity and export checks");
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
                store.ReadState(source).Edit!,new(source,true));
            var clipboard=transfer.Copy(AdjustmentScope.Custom(new HashSet<AdjustmentField>{AdjustmentField.Contrast}),
                store.ReadState(target).Edit!,new(target,true));
            AdjustmentTransferTarget Descriptor(string path)=>new(path,new(OriginalIdentity.Read(path),new Adjustments().Capture(),null),new(path,true));
            var synchronized=transfer.Prepare(payload,[Descriptor(alias),Descriptor(source),Descriptor(target),Descriptor(target)],
                AdjustmentHistoryAction.Synchronize,OriginalIdentity.Read(source));
            Check(synchronized.Targets.Count==1 && synchronized.Targets[0].ID==target,"Session excludes source hardlinks and duplicate targets");
            var sourceRecord=store.ReadState(source);
            Check(transfer.Apply(synchronized).Single().Status==AdjustmentStatus.Applied,"Scoped synchronization writes target only");
            Check(store.ReadState(source).SameAs(sourceRecord) && store.Find(target)!.Settings.Restore()[Parameter.Contrast]==20,"Synchronization preserves source and target micro-edits");
            Check(ReferenceEquals(transfer.Clipboard,clipboard),"Synchronization retains independent clipboard");
            var sourcePrepared=transfer.Prepare(payload,[Descriptor(source)]).Targets.Single();
            Check(transfer.Apply(synchronized with{ID=Guid.NewGuid(),Targets=new[]{sourcePrepared}}).Single().Status==AdjustmentStatus.Blocked,
                "Write boundary refuses a forged source target");
            transfer.UndoTransaction(synchronized.ID);
            var journal=new BatchJournal(Path.Combine(root,"batch"));var output=Path.Combine(root,"output");Directory.CreateDirectory(output);
            var exporter=new BatchSelectionExport(store,journal,edit=>edit.Look,editGeneration:transfer.EditGeneration);
            string? Draft(string id)=>id==targetKey ? "Save, discard or skip" : null;
            var blocked=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,Draft);
            Check(!blocked.Ready,"All selected target drafts are preflighted");
            var skipped=exporter.Prepare(selection,[targetKey],ExportFormat.Png,1024,output,Draft);
            Check(skipped.Ready && skipped.Rows.Count==1 && selection.Selected.Count==2,"Skip affects only the operation");
            Check(!exporter.Prepare(selection,[sourceKey,targetKey],ExportFormat.Png,1024,output,_=>null).Ready,"Empty export has no confirmation");
            var review=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,_=>null);
            review.Rows[0].Settings!.Values[(int)Parameter.Exposure]=3;
            var mutableJob=exporter.Freeze(selection,review,_=>null);
            Check(mutableJob.Items[0].Frozen!.Settings.Values[(int)Parameter.Exposure]==3,
                "Batch freeze preserves the exact settings shown in the confirmation snapshot");
            journal.Discard(mutableJob);
            review=exporter.Prepare(selection,[],ExportFormat.Png,1024,output,_=>null);
            settings.Set(Parameter.Contrast,30);
            var targetBeforeEdit=store.ReadState(target);
            Check(transfer.CommitEdit(targetBeforeEdit,new(targetBeforeEdit.Identity,settings.Capture(),look)).Status==AdjustmentStatus.Applied,
                "A later local target edit advances its in-memory generation");
            Rejected(()=>exporter.Freeze(selection,review,_=>null),"Late committed edit expires the confirmation snapshot");
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
            },transfer.EditGeneration);
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
            var unavailable=new BatchSelectionExport(store,journal,edit=>edit.Look,_=>throw new InvalidOperationException("GPU unavailable"),transfer.EditGeneration);
            Check(!unavailable.Prepare(selection,[targetKey],ExportFormat.Png,512,output,_=>null).Ready,"Collection preflight reports unavailable AI capability");
            File.Delete(target);selection.RefreshFailures();Check(selection.Failures.ContainsKey(targetKey),"Missing input remains marked per photo");

            // P2-20 Low-Med: Re-adding an existing photo reconciles only its own failure status in place
            // without running a full O(N) RefreshFailures() sweep across unrelated collection items.
            var extraA=Path.Combine(root,"extra-a.raw");var extraB=Path.Combine(root,"extra-b.raw");
            var extraBackup=Path.Combine(root,"extra-a.bak");
            var initiallyMissing=Path.Combine(root,"missing-first.raw");
            File.WriteAllText(extraA,"extra-a");File.WriteAllText(extraB,"extra-b");
            var scoped=new BatchSelectionSession();
            scoped.Add([extraA,extraB,initiallyMissing]);
            var keyA=scoped.Photos[0].ID;var keyB=scoped.Photos[1].ID;var keyMissing=scoped.Photos[2].ID;
            Check(scoped.Failures.ContainsKey(keyMissing),"Missing incoming photo records failure");

            // 1) Delete B quietly, delete A via move-aside, then Add([extraA]):
            //    A is marked failed in place with no duplicate row; B stays untouched (no full RefreshFailures).
            File.Delete(extraB);
            File.Move(extraA,extraBackup);
            scoped.Add([extraA]);
            Check(scoped.Photos.Count==3 && scoped.Failures.ContainsKey(keyA) && !scoped.Failures.ContainsKey(keyB),
                "Add reconciles missing existing photo in place without full collection scan or duplicate rows");

            // 2) Move exact same file back to extraA, then Add([extraA]): clears failure for keyA in place.
            File.Move(extraBackup,extraA);
            scoped.Add([extraA]);
            Check(scoped.Photos.Count==3 && !scoped.Failures.ContainsKey(keyA),
                "Add clears recovered failure for existing photo in place");

            // 3) Overwrite extraA in place with changed size, then Add([extraA]): marks PhotoChangedException failure.
            File.WriteAllText(extraA,"extra-a-modified-longer-payload");
            scoped.Add([extraA]);
            Check(scoped.Photos.Count==3 && scoped.Failures.ContainsKey(keyA),
                "Add marks content-replaced existing photo as failed in place");

            // 4) Recreate initially-missing photo and re-add: upgrades sentinel row in place and clears failure.
            File.WriteAllText(initiallyMissing,"now-present");
            scoped.Add([initiallyMissing]);
            var upgraded=scoped.Photos.Single(p=>StringComparer.OrdinalIgnoreCase.Equals(p.Path,Path.GetFullPath(initiallyMissing)));
            Check(scoped.Photos.Count==3 && !scoped.Failures.ContainsKey(keyMissing) && !scoped.Failures.ContainsKey(upgraded.ID),
                "Add upgrades previously-missing sentinel entry in place and clears failure");
        }finally{Directory.Delete(root,true);}
        Console.WriteLine("PASS: collection identity, navigation, in-memory generation guards and frozen export");
    }
}
