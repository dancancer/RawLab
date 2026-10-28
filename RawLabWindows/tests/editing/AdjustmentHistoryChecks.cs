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
            var store=new EditStore(Path.Combine(root,"edits"));var initial=store.VersionedState(file);
            Check(initial.Edit==null && initial.Revision==null,"unsaved photo starts without record");
            var settings=new Adjustments();settings.Set(Parameter.Exposure,1);
            var one=new SavedEdit(initial.Identity,settings.Capture(),null);
            var saved=store.CompareAndSave(initial,one);
            try {store.CompareAndSave(initial,one);throw new Exception("stale revision accepted");}catch(EditPersistenceConflict) { }
            var deleted=store.CompareAndSave(saved,null);
            Check(deleted.Edit==null && deleted.Revision!=null,"delete retains revision tombstone");
            try {store.CompareAndSave(initial,one);throw new Exception("delete ABA accepted");}catch(EditPersistenceConflict) { }
            var session=new AdjustmentTransferSession(store);
            var first=session.CommitEdit(deleted,one);
            Check(first.Status==AdjustmentStatus.Applied,"ordinary edit commits history");
            var firstID=session.Transactions.Single().ID;
            settings.Set(Parameter.Exposure,2);
            var second=session.CommitEdit(first.Saved!,one with {Settings=settings.Capture()});
            var third=session.CommitEdit(second.Saved!,one);
            Check(session.UndoTransaction(firstID).Single().Status==AdjustmentStatus.Conflict,"matching values cannot bypass history order");
            Check(session.UndoPhoto(file).Single().Status==AdjustmentStatus.Applied,"latest undo");
            Check(session.UndoPhoto(file).Single().Status==AdjustmentStatus.Applied,"second undo");
            Check(session.UndoPhoto(file).Single().Status==AdjustmentStatus.Applied,"first undo");
            Check(store.Find(file)==null,"undo restores no record");
            for(var i=0;i<3;i++)Check(session.RedoPhoto(file).Single().Status==AdjustmentStatus.Applied,"ordered redo");
            Check(store.Find(file)!.Settings.Values[1]==1,"redo final appearance");
            PartialFailure(root);LegacyAndReplacement(root);ConcurrentStores(root);
            Console.WriteLine("PASS: Windows revision CAS, deletion ABA, ordinary history order and undo/redo");
        } finally {Directory.Delete(root,true);}
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
        Check(applied[0].Status==AdjustmentStatus.Applied && applied[1].Status==AdjustmentStatus.Failed && session.Transactions.Single().Parts.Count==1,"Only successful writes enter partial history");
        var revision=store.VersionedState(first).Revision;failSecond=false;
        var retried=session.Apply(operation);
        Check(retried.All(o=>o.Status==AdjustmentStatus.Applied) && store.VersionedState(first).Revision==revision && attempts==3,"Retry skips cached successful writes");
        Check(session.Transactions.Single().Parts.Count==2,"Successful retry joins original transaction");
        Check(session.UndoPhoto(first).Single().Status==AdjustmentStatus.Applied,"One component can undo independently");
        Check(session.UndoTransaction(operation.ID).Single().TargetID==second,"Whole undo skips already undone component");
        var undone=store.VersionedState(first);
        var noChange=session.CommitEdit(undone,new(undone.Identity,new Adjustments().Capture(),null),new(undone.Identity,new Adjustments().Capture(),null));
        Check(noChange.Status==AdjustmentStatus.Unchanged && session.PhotoHistoryID(first,false)!=null,"Default no-op keeps redo available");
        settings.Set(Parameter.Exposure,2);session.CommitEdit(undone,new(undone.Identity,settings.Capture(),null));
        Check(session.PhotoHistoryID(first,false)==null && session.PhotoHistoryID(second,false)!=null,"New edit invalidates redo for only its photo");
        session.RedoPhoto(second);var external=new EditStore(Path.Combine(root,"partial"));settings.Set(Parameter.Exposure,3);external.Save(second,settings.Capture(),null);
        settings.Set(Parameter.Exposure,1);external.Save(second,settings.Capture(),null);
        Check(session.UndoPhoto(second).Single().Status==AdjustmentStatus.Conflict,"Fresh disk revision rejects external ABA");
        var blocked=session.Prepare(payload,[Target(first),Target(second) with {Context=new(second,true,HasUncommittedDraft:true)}]);
        var prior=store.VersionedState(first);
        Check(session.Apply(blocked).All(o=>o.Status==AdjustmentStatus.Blocked) && store.VersionedState(first).SameAs(prior),"Preflight errors block all writes until explicitly skipped");
        Check(session.Apply(blocked,new HashSet<string>{second}).Any(o=>o.Status==AdjustmentStatus.Skipped),"Explicit skip excludes blocked target");
        var empty=session.Prepare(payload,[]);Check(session.Apply(empty).Count==0,"Empty target operation does not report success");
        Console.WriteLine("PASS: partial save failure/retry, explicit skip, per-photo history and external ABA");
    }
    private static void LegacyAndReplacement(string root)
    {
        var directory=Path.Combine(root,"legacy");Directory.CreateDirectory(directory);var file=Path.Combine(root,"legacy.ARW");File.WriteAllText(file,"old");
        var path=Path.Combine(directory,"edits.json");var identity=OriginalIdentity.Read(file);var snapshot=new Adjustments().Capture();
        var record=JsonSerializer.SerializeToNode(new SavedEdit(identity,snapshot,null))!.AsObject();record["Identity"]!.AsObject().Remove("FileID");
        File.WriteAllText(path,new JsonObject{["Version"]=1,["Records"]=new JsonObject{[identity.Path]=record}}.ToJsonString());
        var bytes=File.ReadAllBytes(path);var store=new EditStore(directory);var expected=store.VersionedState(file);
        Check(expected.Edit!=null && expected.Revision==null && File.ReadAllBytes(path).SequenceEqual(bytes),"Legacy registry is read without migration or rewrite");
        var settings=new Adjustments();settings.Set(Parameter.Exposure,1);store.CompareAndSave(expected,new(expected.Identity,settings.Capture(),null));
        Check(store.VersionedState(file).Revision!=null,"Explicit legacy edit adds a revision");
        expected=store.VersionedState(file);
        if(OperatingSystem.IsWindows()) {
            var replacement=Path.Combine(root,"replacement.ARW");File.WriteAllText(replacement,"new");
            File.SetCreationTimeUtc(replacement,new DateTime(expected.Identity.Created,DateTimeKind.Utc));File.SetLastWriteTimeUtc(replacement,new DateTime(expected.Identity.Modified,DateTimeKind.Utc));
            File.Move(replacement,file,true);var current=OriginalIdentity.Read(file);
            Check(expected.Identity.Length==current.Length && expected.Identity.Created==current.Created && expected.Identity.Modified==current.Modified && expected.Identity.FileID!=current.FileID,
                "Windows physical identity distinguishes identical path/length/timestamps replacement");
            try{store.CompareAndSave(expected,expected.Edit);throw new Exception("Replacement bypassed CAS");}catch(EditPersistenceConflict) { }
        } else {
            File.WriteAllText(file,"replaced with different content");
            try{store.CompareAndSave(expected,expected.Edit);throw new Exception("Replacement bypassed CAS");}catch(EditPersistenceConflict) { }
        }
        Console.WriteLine("PASS: legacy read-only compatibility and source replacement rejection");
    }
    private static void ConcurrentStores(string root)
    {
        var directory=Path.Combine(root,"concurrent");var file=Path.Combine(root,"concurrent.ARW");File.WriteAllText(file,"original");
        var store=new EditStore(directory);var expected=store.VersionedState(file);var committed=0;var conflicts=0;
        Parallel.For(0,8,index=>{
            var writer=new EditStore(directory);var settings=new Adjustments();settings.Set(Parameter.Exposure,(index+1)/10.0);
            try{writer.CompareAndSave(expected,new(expected.Identity,settings.Capture(),null));Interlocked.Increment(ref committed);}
            catch(EditPersistenceConflict){Interlocked.Increment(ref conflicts);}
        });
        Check(committed==1 && conflicts==7,"Competing store instances serialize compare-and-save under the same file lock");
        Console.WriteLine("PASS: concurrent conditional saves have exactly one winner");
    }
}
