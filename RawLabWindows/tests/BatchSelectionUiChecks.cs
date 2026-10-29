using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class BatchSelectionUiChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(repo),"build","windows-collection",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        var source=Path.Combine(root,"source"+Path.GetExtension(raw));var target=Path.Combine(root,"target"+Path.GetExtension(raw));File.Copy(raw,source);File.Copy(raw,target);
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        Loc.Initialize("zh-Hans");foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        var window=new MainWindow();TestWindowState.Isolate(window,root);var store=new EditStore(Path.Combine(root,"edits"));Set(window,"editStore",store);
        try {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(source);Ready(window);
            window.OrdinaryParameter.Number.Text="0.5";check(window.OrdinaryParameter.Commit(),"Exact source value commits through existing editor");Ready(window);
            window.AddCollectionPhotos([source,target,target]);window.MenuCollection.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            var collection=app.Windows.OfType<BatchSelectionWindow>().Single();collection.UpdateLayout();
            check(window.Collection.Photos.Count==2 && window.Collection.Selected.Count==2,"Collection keeps two stable selected photos after duplicate input");
            var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(50)};Exception? failure=null;var stage=0;
            timer.Tick+=(_,_)=>{
                try {
                    var scope=app.Windows.OfType<AdjustmentScopeDialog>().FirstOrDefault(dialog=>dialog.IsVisible);
                    if(scope!=null && stage==0) {
                        scope.UpdateLayout();Find<ComboBox>(scope,"adjustment.copy.scope").SelectedIndex=3;
                        if(Get<Adjustments>(window,"settings").IsHDREditing) {
                            check(Find<CheckBox>(scope,"adjustment.field.hdr.relative_temperature").IsVisible &&
                                Find<CheckBox>(scope,"adjustment.field.hdr.relative_tint").IsVisible,
                                "Actual HDR collection scope shows relative WB controls");
                        }
                        Find<Button>(scope,"adjustment.copy.clear").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                        Find<CheckBox>(scope,"adjustment.field.light.exposure").IsChecked=true;stage=1;
                        Find<Button>(scope,"adjustment.copy.confirm").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));return;
                    }
                    var results=app.Windows.OfType<AdjustmentResultDialog>().FirstOrDefault(dialog=>dialog.IsVisible);
                    if(results!=null && stage==1) {
                        results.UpdateLayout();Find<Button>(results,"adjustment.results.apply").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));stage=2;
                        Find<Button>(results,"adjustment.results.close").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    }
                }catch(Exception error){failure=error;timer.Stop();foreach(var dialog in app.Windows.OfType<Window>().Where(w=>w is AdjustmentScopeDialog or AdjustmentResultDialog).ToArray())dialog.Close();}
            };
            timer.Start();var synchronization=window.SynchronizeCollection(collection);InteractionChecks.PumpUntil(()=>synchronization.IsCompleted);timer.Stop();synchronization.GetAwaiter().GetResult();
            if(failure!=null)throw failure;
            check(stage==2 && window.Collection.LastSynchronization!=null && store.Find(target)!.Settings.Restore()[Parameter.Exposure]==.5,
                "Actual scope and result dialogs save the frozen source payload to the target");
            var synchronizationID=window.Collection.LastSynchronization;
            var targetID=window.Collection.Photos.Single(photo=>photo.Path==target).ID;
            collection.UpdateLayout();Find<Button>(collection,"collection.edit."+targetID).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready(window);
            check(window.Collection.CurrentID==targetID && !collection.IsVisible,"Micro-edit reuses the existing MainWindow editor");
            window.OrdinaryParameter.Number.Text="1.25";check(window.OrdinaryParameter.Commit(),"Target micro-edit commits");Ready(window);
            window.CollectionReturn.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            check(collection.IsVisible && window.Collection.CurrentID==null && window.Collection.Selected.Count==2 && window.Collection.ReturnPosition==1,
                "Return action preserves collection order, selection and position");
            check(window.Collection.LastSynchronization==synchronizationID,"Ordinary micro-edit does not replace the synchronization history entry");
            window.GeometryCategory.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));InteractionChecks.PumpUntil(()=>Get<bool>(window,"transformPreviewReady"));
            ((CheckBox)window.GeometryEditor.FindName("HorizontalFlip")).IsChecked=true;InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            var blocked=window.PrepareCollectionExport([],ExportFormat.Png,256,root);check(!blocked.Ready,"Export sees the currently open geometry draft");
            var skipped=window.PrepareCollectionExport([targetID],ExportFormat.Png,256,root);
            check(skipped.Ready && skipped.Rows.Count==1 && window.Collection.Selected.Count==2,"Skipping draft preserves collection selection");
            check(window.ResolveCollectionDraft(targetID,false),"Explicit discard resolves the active draft");Ready(window);
            var review=window.PrepareCollectionExport([],ExportFormat.Png,256,root);check(review.Ready,"Both committed target snapshots are shown after draft resolution");
            var job=window.FreezeCollectionExport(review);
            var batch=app.Windows.OfType<BatchExportWindow>().Single();batch.UpdateLayout();
            check(!batch.FormatOptions.IsEnabled && !batch.ChooseFolder.IsEnabled && !batch.SizeSelection.IsEnabled,"Frozen task output controls are locked");
            window.OrdinaryParameter.Number.Text="2";check(window.OrdinaryParameter.Commit(),"Later editor value changes independently");Ready(window);
            var frozen=job.Items.Single(item=>item.Input==target).Frozen!;
            check(frozen.Settings.Restore()[Parameter.Exposure]==1.25 && store.Find(target)!.Settings.Restore()[Parameter.Exposure]==2,
                "Frozen task keeps the target micro-edit after a later saved change");
            using(var engine=new RenderEngine(1)) {
                var before=engine.Render(target,frozen.Settings.Restore(),frozen.Look,128,statistics:false,clipping:false)!.Image;
                var after=engine.Render(target,Get<Adjustments>(window,"settings"),null,128,statistics:false,clipping:false)!.Image;
                check(!Pixels(before).SequenceEqual(Pixels(after)),"Native frozen preview differs from the later editor state");
            }
            batch.Close();collection.Close();
            check(store.Find(target)!.Settings.Restore()[Parameter.Exposure]==2 && File.Exists(target),"Cancelling the frozen export preserves saved micro-edits and source files");
        }finally{window.Close();app.Shutdown();}
    }
    private static byte[] Pixels(BitmapSource image)
    {
        var stride=(image.PixelWidth*image.Format.BitsPerPixel+7)/8;var bytes=new byte[stride*image.PixelHeight];image.CopyPixels(bytes,stride,0);return bytes;
    }
    private static T Find<T>(DependencyObject root,string id) where T:DependencyObject
    {
        if(root is T match && AutomationProperties.GetAutomationId(match)==id)return match;
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++)try{return Find<T>(VisualTreeHelper.GetChild(root,i),id);}catch(InvalidOperationException){}
        throw new InvalidOperationException("Missing UI control "+id);
    }
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    private static T Get<T>(object value,string name)=>(T)value.GetType().GetField(name,Private)!.GetValue(value)!;
    private static void Set(object value,string name,object state)=>value.GetType().GetField(name,Private)!.SetValue(value,state);
}
