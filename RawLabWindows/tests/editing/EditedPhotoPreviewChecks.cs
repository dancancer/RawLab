using RawLab.Windows;

internal static class EditedPhotoPreviewChecks
{
    internal static void Run()
    {
        var root=Path.Combine(Path.GetTempPath(),"rawlab-edited-previews-"+Guid.NewGuid());
        Directory.CreateDirectory(root);
        try {
            var path=Path.Combine(root,"photo.jpg");File.WriteAllBytes(path,[1,2,3]);
            var store=new EditStore(Path.Combine(root,"edits"));var record=store.ReadState(path);
            Check(!EditedPhotoPreviewKey.IsEdited(record),"No record is unedited");
            var settings=PhotoInput.PrepareInputSettings(path,new Adjustments());
            var defaults=new SavedEdit(record.Identity,settings.Capture(),null);
            record=store.SaveState(record.Identity,defaults);
            Check(!EditedPhotoPreviewKey.IsEdited(record),"Saved defaults are unedited");
            settings.Set(Parameter.Exposure,1);
            record=store.SaveState(record.Identity,new(record.Identity,settings.Capture(),null));
            Check(EditedPhotoPreviewKey.IsEdited(record),"Saved exposure is edited");
            var key=EditedPhotoPreviewKey.Create(record,null);
            Check(key==EditedPhotoPreviewKey.Create(record.Copy(),null),"Key is stable");
            Check(EditedPhotoPreviewKey.Create(record,null,rendererVersion:"1")!=EditedPhotoPreviewKey.Create(record,null,rendererVersion:"2"),"Renderer upgrade invalidates key");
            Check(key!=EditedPhotoPreviewKey.Create(record,null,edge:128),"Size participates in key");
            var lut=Path.Combine(root,"look.cube");File.WriteAllText(lut,"first");
            var lookRecord=record with {Edit=record.Edit! with {Look=lut}};
            var lookKey=EditedPhotoPreviewKey.Create(lookRecord,lut);
            File.WriteAllText(lut,"other");
            Check(lookKey!=EditedPhotoPreviewKey.Create(lookRecord,lut),"Resource content participates in key");
            var changed=0;store.Changed+=_=>changed++;
            store.SaveState(record.Identity,defaults);
            Check(changed==1 && !EditedPhotoPreviewKey.IsEdited(store.ReadState(path)),"Reset notifies and clears marker");
            store.SaveState(record.Identity,defaults);Check(changed==1,"Unchanged writes do not notify");
            var failing=new EditStore(Path.Combine(root,"edits"),(_,_)=>throw new IOException("injected"));
            var failedChanges=0;failing.Changed+=_=>failedChanges++;
            try {failing.SaveState(record.Identity,record.Edit);throw new Exception("Expected write failure");}catch(IOException){}
            Check(failedChanges==0,"Failed save never announces new state");
            var cache=new EditedPhotoPreviewCache(Path.Combine(root,"cache"),maximumEntries:2,maximumBytes:5);
            cache.Write(key,[1,2,3]);Check(cache.Read(key)!.SequenceEqual(new byte[]{1,2,3}),"Persistent cache roundtrip");
            cache.Write(lookKey,[4,5,6]);Check(cache.Read(key)==null && cache.Read(lookKey)!=null,"Byte budget evicts old entry");
            Check(new EditedPhotoPreviewCache(Path.Combine(root,"cache")).Read(lookKey)!=null,"Cache survives process restart");
            File.WriteAllBytes(path,[4,5,6,7]);
            Check(!EditedPhotoPreviewKey.IsEdited(store.ReadState(path)),"Replaced source does not inherit edit marker");
            using(var changedResource=new ManualResetEventSlim()) {
                using var watch=new PhotoPreviewResourceWatch(changedResource.Set);
                watch.Watch(new[]{lut});
                foreach(var content in new[]{"replacement-one","replacement-two"}) {
                    changedResource.Reset();
                    var temporary=lut+".new";File.WriteAllText(temporary,content);File.Move(temporary,lut,true);
                    Check(changedResource.Wait(TimeSpan.FromSeconds(5)),"Repeated atomic look replacement refreshes previews");
                }
                File.Delete(lut);Thread.Sleep(50);changedResource.Reset();
                File.WriteAllText(lut,"restored");
                Check(changedResource.Wait(TimeSpan.FromSeconds(5)),"Restored missing look refreshes previews");
            }
            Console.WriteLine("PASS: edited preview semantics, key invalidation, notifications, disk cache");
        } finally {Directory.Delete(root,true);}
    }
    private static void Check(bool value,string message) {if(!value)throw new Exception(message);}
}
