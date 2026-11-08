using RawLab.Windows;
using System.Text.Json;
using System.Text.Json.Nodes;

internal static class AdjustmentHistoryChecks
{
    private static void Check(bool condition,string message){if(!condition)throw new Exception(message);}

    internal static void Run()
    {
        var root=Path.Combine(Path.GetTempPath(),"RawLab-transfer-"+Guid.NewGuid());Directory.CreateDirectory(root);
        try {
            var file=Path.Combine(root,"photo.ARW");File.WriteAllText(file,"original");
            var store=new EditStore(Path.Combine(root,"edits"));var initial=store.ReadState(file);
            Check(initial.Edit==null,"unsaved photo starts without record");

            var settings=new Adjustments();settings.Set(Parameter.Exposure,1);
            var one=new SavedEdit(initial.Identity,settings.Capture(),null);
            var saved=store.SaveState(initial.Identity,one);
            Check(saved.Edit?.Settings.Values[1]==1,"ordinary SaveState writes the requested appearance");
            var firstDocument=JsonNode.Parse(File.ReadAllText(Path.Combine(root,"edits","edits.json")))!.AsObject();
            Check(!firstDocument.ContainsKey("Revisions"),"new edit registry does not create the removed Revisions map");

            var deleted=store.SaveState(initial.Identity,null);
            Check(deleted.Edit==null,"SaveState can remove the current record without a version tombstone");

            var session=new AdjustmentTransferSession(store);
            var first=session.CommitEdit(deleted,one);
            Check(first.Status==AdjustmentStatus.Applied,"ordinary edit commits the first history component");
            var firstID=session.Transactions.Single().ID;
            settings.Set(Parameter.Exposure,2);
            var second=session.CommitEdit(deleted,one with {Settings=settings.Capture()});
            Check(second.Status==AdjustmentStatus.Applied,"ordinary edit uses the session's latest state even when the window receipt is old");
            var third=session.CommitEdit(second.Saved!,one);
            Check(third.Status==AdjustmentStatus.Applied,"a later edit creates another ordered history component");
            Check(session.UndoTransaction(firstID).Single().Error is AdjustmentHistoryOrderException,
                "undoing a non-head transaction is rejected by in-memory history order");
            Check(session.UndoPhoto(file).Single().Status==AdjustmentStatus.Applied,"latest undo");
            Check(session.UndoPhoto(file).Single().Status==AdjustmentStatus.Applied,"second undo");
            Check(session.UndoPhoto(file).Single().Status==AdjustmentStatus.Applied,"first undo");
            Check(store.Find(file)==null,"undo restores no record");
            for(var i=0;i<3;i++)Check(session.RedoPhoto(file).Single().Status==AdjustmentStatus.Applied,"ordered redo");
            Check(store.Find(file)!.Settings.Values[1]==1,"redo restores the final appearance in order");

            ExpiredOperation(root);
            PartialFailure(root);
            ConcurrentIndependentWrites(root);
            LegacyAndReplacement(root);
            Console.WriteLine("PASS: Windows in-memory edit generations, ordered history, retry, legacy registry and photo identity");
        } finally {Directory.Delete(root,true);}
    }

    private static void ExpiredOperation(string root)
    {
        var file=Path.Combine(root,"generation.ARW");File.WriteAllText(file,"generation");
        var store=new EditStore(Path.Combine(root,"generation-edits"));var session=new AdjustmentTransferSession(store);
        var source=new Adjustments();source.Set(Parameter.Exposure,.5);
        var payload=AdjustmentTransfer.Capture(AdjustmentScope.Custom([AdjustmentField.Exposure]),
            new(OriginalIdentity.Read(file),source.Capture(),null),new(file,true));
        AdjustmentTransferTarget Target(string path)=>new(path,new(OriginalIdentity.Read(path),new Adjustments().Capture(),null),new(path,true));
        var operation=session.Prepare(payload,[Target(file)]);
        var newer=source.Clone();newer.Set(Parameter.Exposure,1.75);
        var current=store.ReadState(file);
        Check(session.CommitEdit(current,new(current.Identity,newer.Capture(),null)).Status==AdjustmentStatus.Applied,
            "a later local edit advances the photo generation");
        var expired=session.Apply(operation).Single();
        Check(expired.Status==AdjustmentStatus.Conflict && expired.Error is AdjustmentOperationExpiredException &&
            store.Find(file)!.Settings.Values[1]==1.75,
            "a prepared operation cannot overwrite a later in-memory edit");
        var fresh=session.Apply(session.Prepare(payload,[Target(file)])).Single();
        Check(fresh.Status==AdjustmentStatus.Applied && store.Find(file)!.Settings.Values[1]==.5,
            "a fresh operation can be applied after the stale operation is rejected");
    }

    private static void PartialFailure(string root)
    {
        var first=Path.Combine(root,"first.ARW");var second=Path.Combine(root,"second.ARW");File.WriteAllText(first,"first");File.WriteAllText(second,"second");
        var attempts=0;var failSecond=true;
        var store=new EditStore(Path.Combine(root,"partial"),(path,value)=>{
            if(++attempts==2 && failSecond)throw new IOException("Injected second target failure");AtomicJson.Write(path,value);
        });
        var session=new AdjustmentTransferSession(store);var settings=new Adjustments();settings.Set(Parameter.Exposure,1);
        var payload=AdjustmentTransfer.Capture(AdjustmentScope.Custom([AdjustmentField.Exposure]),new(OriginalIdentity.Read(first),settings.Capture(),null),new(first,true));
        AdjustmentTransferTarget Target(string path)=>new(path,new(OriginalIdentity.Read(path),new Adjustments().Capture(),null),new(path,true));
        var operation=session.Prepare(payload,[Target(first),Target(second),Target(first)]);
        Check(operation.Targets.Count==2,"Repeated target canonical path is deduplicated");
        var applied=session.Apply(operation);
        Check(applied[0].Status==AdjustmentStatus.Applied && applied[1].Status==AdjustmentStatus.Failed && session.Transactions.Single().Parts.Count==1,
            "Only successful writes enter partial history");
        failSecond=false;
        var retried=session.Apply(operation);
        Check(retried.All(o=>o.Status==AdjustmentStatus.Applied) && store.Find(first)!.Settings.Values[1]==1 && attempts==3,
            "Retry skips the cached successful target and writes only the failed target");
        Check(session.Transactions.Single().Parts.Count==2,"Successful retry joins the original transaction");
        Check(session.UndoPhoto(first).Single().Status==AdjustmentStatus.Applied,"One component can undo independently");
        Check(session.UndoTransaction(operation.ID).Single().TargetID==second,"Whole undo skips an already undone component");
        var undone=store.ReadState(first);
        var noChange=session.CommitEdit(undone,new(undone.Identity,new Adjustments().Capture(),null),new(undone.Identity,new Adjustments().Capture(),null));
        Check(noChange.Status==AdjustmentStatus.Unchanged && session.PhotoHistoryID(first,false)!=null,"Default no-op keeps redo available");
        var settings2=new Adjustments();settings2.Set(Parameter.Exposure,2);
        Check(session.CommitEdit(undone,new(undone.Identity,settings2.Capture(),null)).Status==AdjustmentStatus.Applied,
            "a new edit succeeds after undo");
        Check(session.PhotoHistoryID(first,false)==null && session.PhotoHistoryID(second,false)!=null,
            "New edit invalidates redo for only its photo");
        var blocked=session.Prepare(payload,[Target(first),Target(second) with {Context=new(second,true,HasUncommittedDraft:true)}]);
        var prior=store.ReadState(first);
        Check(session.Apply(blocked).All(o=>o.Status==AdjustmentStatus.Blocked) && store.ReadState(first).SameAs(prior),
            "Preflight errors block all writes until explicitly skipped");
        Check(session.Apply(blocked,new HashSet<string>{second}).Any(o=>o.Status==AdjustmentStatus.Skipped),
            "Explicit skip excludes the blocked target");
        var empty=session.Prepare(payload,[]);Check(session.Apply(empty).Count==0,"Empty target operation does not report success");
    }

    private static void ConcurrentIndependentWrites(string root)
    {
        var directory=Path.Combine(root,"concurrent-independent");var photos=Enumerable.Range(0,8)
            .Select(index=>Path.Combine(root,$"concurrent-{index}.ARW")).ToArray();
        foreach(var photo in photos)File.WriteAllText(photo,"independent");
        Parallel.For(0,photos.Length,index=>{
            var writer=new EditStore(directory);var settings=new Adjustments();settings.Set(Parameter.Exposure,(index+1)/10.0);
            writer.Save(photos[index],settings.Capture(),null);
        });
        var reader=new EditStore(directory);
        Check(photos.Select((photo,index)=>reader.Find(photo) is {} saved &&
            Math.Abs(saved.Settings.Values[1]-(index+1)/10.0)<1e-9).All(value=>value),
            "Independent store writers preserve every photo record without conditional-save winners");
    }

    private static void LegacyAndReplacement(string root)
    {
        var directory=Path.Combine(root,"legacy");Directory.CreateDirectory(directory);var file=Path.Combine(root,"legacy.ARW");File.WriteAllText(file,"old");
        var path=Path.Combine(directory,"edits.json");var identity=OriginalIdentity.Read(file);var snapshot=new Adjustments().Capture();
        var record=JsonSerializer.SerializeToNode(new SavedEdit(identity,snapshot,null))!.AsObject();record["Identity"]!.AsObject().Remove("FileID");
        File.WriteAllText(path,new JsonObject{["Version"]=1,["Records"]=new JsonObject{[identity.Path]=record},["Revisions"]=new JsonObject{[identity.Path]="legacy-revision"}}.ToJsonString());
        var bytes=File.ReadAllBytes(path);var store=new EditStore(directory);var expected=store.ReadState(file);
        Check(expected.Edit!=null && File.ReadAllBytes(path).SequenceEqual(bytes),"Old registry with Revisions is read without migration or rewrite");
        var settings=new Adjustments();settings.Set(Parameter.Exposure,1);store.SaveState(expected.Identity,new(expected.Identity,settings.Capture(),null));
        var rewritten=JsonNode.Parse(File.ReadAllText(path))!.AsObject();
        Check(!rewritten.ContainsKey("Revisions") && rewritten["Records"]!=null,"New writes omit the removed Revisions map");

        var replacement=Path.Combine(root,"replacement.ARW");File.WriteAllText(replacement,"new");
        if(OperatingSystem.IsWindows()) {
            File.SetCreationTimeUtc(replacement,new DateTime(expected.Identity.Created,DateTimeKind.Utc));
            File.SetLastWriteTimeUtc(replacement,new DateTime(expected.Identity.Modified,DateTimeKind.Utc));
        }
        File.Move(replacement,file,true);
        try { store.SaveState(expected.Identity,expected.Edit); throw new Exception("Photo replacement bypassed identity guard"); }
        catch(PhotoChangedException) { }
        Console.WriteLine("PASS: old Revisions records remain readable, new writes omit Revisions, and photo replacement is rejected");
    }
}
