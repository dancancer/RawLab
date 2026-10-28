using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AdjustmentHistoryUiChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        repo=Path.GetFullPath(repo);raw=Path.GetFullPath(raw);
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        var output=Path.Combine(repo,"build","windows-adjustment-history",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(output);
        var photo=Path.Combine(output,"source"+Path.GetExtension(raw));var target=Path.Combine(output,"target"+Path.GetExtension(raw));
        File.Copy(raw,photo);File.Copy(raw,target);
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        Loc.Initialize("zh-Hans");foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        var window=new MainWindow();TestWindowState.Isolate(window,output);var store=new EditStore(Path.Combine(output,"edits"));Set(window,"editStore",store);
        try {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(photo);Ready(window);
            check(((MenuItem)window.MainMenu.Items[1]).Items.Contains(window.CopyAdjustmentMenu),"Initialized Edit menu retains the actual Copy adjustment item");
            var session=(AdjustmentTransferSession)typeof(MainWindow).GetProperty("TransferSession",Private)!.GetValue(window)!;
            check(session.Transactions.Count==0 && store.Find(photo)==null,"Opening and native metadata resolution create no edit history");
            var row=window.OrdinaryParameter;var slider=row.Slider;
            slider.RaiseEvent(new DragStartedEventArgs(0,0){RoutedEvent=Thumb.DragStartedEvent});
            slider.Value=.6;slider.Value=.65;
            var elapsed=Stopwatch.StartNew();InteractionChecks.PumpUntil(()=>elapsed.ElapsedMilliseconds>650);
            check(session.Transactions.Count==0 && store.Find(photo)==null,"Live WPF drag does not save at the former debounce boundary");
            slider.RaiseEvent(new DragCompletedEventArgs(0,0,false){RoutedEvent=Thumb.DragCompletedEvent});Ready(window);
            check(session.Transactions.Count==1 && Math.Abs(store.Find(photo)!.Settings.Values[1]-1.2)<1e-9,"One completed slider drag creates one saved history component");
            var saved=store.VersionedState(photo);var before=Get<Adjustments>(window,"settings").Capture();
            slider.RaiseEvent(new DragStartedEventArgs(0,0){RoutedEvent=Thumb.DragStartedEvent});slider.Value=.75;
            slider.RaiseEvent(new DragCompletedEventArgs(0,0,true){RoutedEvent=Thumb.DragCompletedEvent});Ready(window);
            check(session.Transactions.Count==1 && store.VersionedState(photo).SameAs(saved) && Get<Adjustments>(window,"settings").Capture().SameAs(before),
                "Cancelled native Thumb drag restores preview and leaves the saved revision unchanged");
            slider.RaiseEvent(new DragStartedEventArgs(0,0){RoutedEvent=Thumb.DragStartedEvent});slider.Value=.8;row.CancelInput();Ready(window);
            slider.RaiseEvent(new DragCompletedEventArgs(0,0,false){RoutedEvent=Thumb.DragCompletedEvent});
            check(session.Transactions.Count==1 && store.VersionedState(photo).SameAs(saved),"Navigation cancellation ignores the late drag completion");
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(store.Find(photo)==null && Get<Adjustments>(window,"settings")[Parameter.Exposure]==0,"Edit menu undo restores an absent edit record");
            window.RedoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(store.Find(photo)!.Settings.Values[1]==1.2,"Edit menu redo restores the full saved appearance");
            var payload=session.Copy(AdjustmentScope.Custom([AdjustmentField.Exposure]),new(OriginalIdentity.Read(photo),Get<Adjustments>(window,"settings").Capture(),null),new(photo,true));
            window.OpenFile(target);Ready(window);
            var preparing=window.PrepareAdjustmentTargets(payload,[target,photo]);InteractionChecks.PumpUntil(()=>preparing.IsCompleted);
            var operation=preparing.GetAwaiter().GetResult()!;
            check(operation.Targets.Count==2 && operation.Targets.All(t=>t.Error==null),"Native preflight resolves independent target calibration");
            var applied=session.Apply(operation);
            var receipt=applied.Single(o=>o.TargetID==target).Saved!;Invoke(window,"AdoptSavedEdit",receipt);Ready(window);
            check(Get<Adjustments>(window,"settings")[Parameter.Exposure]==1.2 && store.Find(target)!.Settings.Values[1]==1.2,"Native target adopts only its successful paste receipt");
            var paste=session.Transactions.Last();check(paste.Action==AdjustmentHistoryAction.Paste && paste.Parts.Count==1,"Unchanged source is excluded from successful paste history");
            var undo=session.UndoPhoto(target).Single();Invoke(window,"AdoptSavedEdit",undo.Saved!);Ready(window);
            check(store.Find(target)==null && store.Find(photo)!=null,"Single-photo undo preserves the other photo");
            var redo=session.RedoPhoto(target).Single();Invoke(window,"AdoptSavedEdit",redo.Saved!);Ready(window);
            window.OpenFile(photo);Ready(window);window.OpenFile(target);Ready(window);
            check(Get<Adjustments>(window,"settings")[Parameter.Exposure]==1.2,"File reopen restores successful saved paste");
            var historyBefore=session.Transactions.Count;
            window.GeometryCategory.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));InteractionChecks.PumpUntil(()=>Get<bool>(window,"transformPreviewReady"));
            ((CheckBox)window.GeometryEditor.FindName("HorizontalFlip")).IsChecked=true;InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            check(session.Transactions.Count==historyBefore,"Native geometry draft stays outside history before Apply");
            window.ApplyDraftButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready(window);
            check(session.Transactions.Count==historyBefore+1 && store.Find(target)!.Settings.Geometry!.FlipHorizontal,"Geometry Apply shares the saved history transaction");
            window.UndoAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(!Get<Adjustments>(window,"settings").Geometry.FlipHorizontal,"Geometry undo restores the full native snapshot");
            window.GeometryCategory.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));InteractionChecks.PumpUntil(()=>Get<bool>(window,"transformPreviewReady"));
            ((Expander)window.GeometryEditor.FindName("PreciseCrop")).IsExpanded=true;
            var cropWidth=(TextBox)window.GeometryEditor.FindName("CropWidth");cropWidth.Focus();cropWidth.Text="80";
            window.MainMenu.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice,Environment.TickCount,MouseButton.Left){RoutedEvent=UIElement.PreviewMouseDownEvent});
            check(cropWidth.Text=="80","Edit-menu navigation preserves an uncommitted geometry number");
            var sawDraftDialog=false;var draftTimer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(50)};
            draftTimer.Tick+=(_,_)=>{
                var draftDialog=Application.Current.Windows.OfType<Window>().FirstOrDefault(w=>w!=window && w.Title==Loc.Text("保留这次几何或镜头修改？"));
                if(draftDialog==null)return;sawDraftDialog=true;draftTimer.Stop();draftDialog.Close();
            };
            draftTimer.Start();window.CopyAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));draftTimer.Stop();
            check(sawDraftDialog && Math.Abs(Get<TransformDraft>(window,"transform").Geometry.CropWidth-.8)<1e-9,
                "Copy command resolves the complete geometry draft before continuing");
            window.CancelDraftButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready(window);
            DialogChecks(window,session,photo,output,check);
            DialogLocales(window,session,photo,output,check);
            var external=new EditStore(Path.Combine(output,"edits"));var externallyEdited=Get<Adjustments>(window,"settings").Clone();externallyEdited.Set(Parameter.Exposure,2.4);
            external.Save(target,externallyEdited.Capture(),null);
            window.OrdinaryParameter.Slider.Value=.7;
            check(Get<bool>(window,"editDirty") && window.ReloadEditsButton.Visibility==Visibility.Visible && !window.AdjustmentPanel.IsEnabled,
                "External-save conflict preserves the unsaved intent and exposes explicit reload recovery");
            window.ReloadCurrentAdjustments();Ready(window);
            check(!Get<bool>(window,"editDirty") && Get<Adjustments>(window,"settings")[Parameter.Exposure]==2.4 && window.AdjustmentPanel.IsEnabled,
                "Confirmed reload reads the external revision and leaves editing usable");
            var expected=store.VersionedState(target);var outgoing=Get<Adjustments>(window,"settings").Clone();outgoing.Set(Parameter.Exposure,2.6);
            var written=session.CommitEdit(expected,new(expected.Identity,outgoing.Capture(),null));
            outgoing.Set(Parameter.Exposure,2.8);external.Save(target,outgoing.Capture(),null);
            var adopted=new Dictionary<string,Exception?>();
            var firstReceipt=(IReadOnlyList<AdjustmentOutcome>)Invoke(window,"AdoptAdjustmentOutcomes",new[]{written},adopted)!;
            var repeatedReceipt=(IReadOnlyList<AdjustmentOutcome>)Invoke(window,"AdoptAdjustmentOutcomes",new[]{written},adopted)!;
            check(firstReceipt.Single().Status==AdjustmentStatus.Applied && firstReceipt.Single().Error is EditPersistenceConflict && repeatedReceipt.Single().Error is EditPersistenceConflict &&
                Get<Adjustments>(window,"settings")[Parameter.Exposure]==2.4,"Saved receipt external conflict stays visible across retries without reclaiming the current UI");
            window.ReloadCurrentAdjustments();Ready(window);
            check(Get<Adjustments>(window,"settings")[Parameter.Exposure]==2.8,"Receipt recovery reloads the newest disk state rather than the cached success");
            PartialResultsDialog(window,photo,output,check);
            Console.WriteLine("Native adjustment artifacts: "+output);
        }catch(Exception error){Console.Error.WriteLine("History check failed before teardown: "+error);throw;}finally{window.Close();app.Shutdown();}
    }
    private static void DialogChecks(MainWindow owner,AdjustmentTransferSession session,string photo,string output,Action<bool,string> check)
    {
        var copied=false;
        var dialog=new AdjustmentScopeDialog(owner,photo,scope=>{copied=scope.Kind=="custom" && scope.Fields!.SetEquals([AdjustmentField.Exposure]);return null;});
        dialog.Show();InteractionChecks.PumpUntil(()=>dialog.IsLoaded);dialog.UpdateLayout();
        var scope=Find<ComboBox>(dialog,"adjustment.copy.scope");scope.SelectedIndex=3;
        Find<Button>(dialog,"adjustment.copy.clear").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        Find<CheckBox>(dialog,"adjustment.field.light.exposure").IsChecked=true;dialog.UpdateLayout();Screenshot(dialog,Path.Combine(output,"copy-scope.png"));
        check(dialog.SelectedScope.Fields!.SetEquals([AdjustmentField.Exposure]),"Real copy scope dialog selects an individual field without hidden defaults");
        // 非模态布局测试不设置 DialogResult；正式入口在下方通过真实菜单 ShowDialog 验证。
        dialog.Close();
        var history=new AdjustmentHistoryDialog(owner,()=>session.Transactions,(_,_)=>{});history.Show();InteractionChecks.PumpUntil(()=>history.IsLoaded);history.UpdateLayout();
        Screenshot(history,Path.Combine(output,"history.png"));check(history.ActualWidth>=480 && history.ActualHeight>300,"History window renders native transaction rows");history.Close();
        var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(50)};
        timer.Tick+=(_,_)=>{
            var shown=Application.Current.Windows.OfType<Window>().FirstOrDefault(w=>AutomationProperties.GetAutomationId(w)=="adjustment.copy");
            if(shown==null)return;timer.Stop();Find<Button>(shown,"adjustment.copy.confirm").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        };
        timer.Start();owner.CopyAdjustmentMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));timer.Stop();
        check(session.Clipboard!=null && session.Clipboard.Fields.Count==AdjustmentFields.Common.Count,"Production menu copy commits default field scope through a native modal dialog");
        _=copied;
    }
    private static void DialogLocales(MainWindow owner,AdjustmentTransferSession session,string photo,string output,Action<bool,string> check)
    {
        try {
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"})foreach(var fontSize in new[]{13d,26d}) {
                Loc.Initialize(language);foreach(var pair in Loc.Strings)Application.Current.Resources[pair.Key]=pair.Value;
                if(fontSize==13) {
                    Invoke(owner,"BuildResetMenu");var edit=(MenuItem)owner.MainMenu.Items[1];edit.IsSubmenuOpen=true;
                    check(new[]{owner.CopyAdjustmentMenu,owner.PasteAdjustmentMenu,owner.PastePhotosAdjustmentMenu,owner.HistoryAdjustmentMenu,owner.UndoAdjustmentMenu,owner.RedoAdjustmentMenu}.All(edit.Items.Contains) &&
                        Equals(owner.CopyAdjustmentMenu.Header,Loc.Text("复制调整…")) && edit.Items.OfType<MenuItem>().Count(item=>item.Tag is EditorResetScope)>=3,
                        "Localized Edit menu preserves transfer/history commands and rebuilt reset scopes: "+language);
                    edit.IsSubmenuOpen=false;
                }
                var copy=new AdjustmentScopeDialog(owner,photo,_=>null){Width=520,FontSize=fontSize};copy.Show();
                Find<ComboBox>(copy,"adjustment.copy.scope").SelectedIndex=3;copy.UpdateLayout();
                var confirm=Find<Button>(copy,"adjustment.copy.confirm");var cancel=Find<Button>(copy,"adjustment.cancel");
                var root=(Grid)copy.Content;
                bool Visible(Button button) {
                    var bounds=button.TransformToAncestor(root).TransformBounds(new Rect(button.RenderSize));
                    return bounds.Left>=-.5 && bounds.Right<=root.ActualWidth+.5 && bounds.Top>=0 && bounds.Bottom<=root.ActualHeight+.5;
                }
                check(Visible(confirm) && Visible(cancel),"Copy actions fit narrow native layout: "+language+"/"+fontSize);
                Screenshot(copy,Path.Combine(output,$"copy-{language}-{fontSize}.png"));copy.Close();
                var history=new AdjustmentHistoryDialog(owner,()=>session.Transactions,(_,_)=>{}){Width=520,FontSize=fontSize};
                history.Show();history.UpdateLayout();root=(Grid)history.Content;
                check(Visible(Find<Button>(history,"adjustment.history.close")),"History close remains reachable: "+language+"/"+fontSize);
                Screenshot(history,Path.Combine(output,$"history-{language}-{fontSize}.png"));history.Close();
                var parts=session.Transactions.Last().Parts;var outcomes=parts.Select(p=>new AdjustmentOutcome(p.Identity.Path,AdjustmentStatus.Applied)).ToArray();
                var results=new AdjustmentResultDialog(owner,"粘贴调整",outcomes,false,_=>outcomes,
                    sourceSummary:Loc.Format("来源：{0} · {1} 项调整",Path.GetFileName(photo),1),historyParts:()=>parts,changeHistory:_=>{}){Width=520,FontSize=fontSize};
                results.Show();results.UpdateLayout();root=(Grid)results.Content;
                check(new[]{"undo","redo","close","apply"}.All(id=>Visible(Find<Button>(results,"adjustment.results."+id))),
                    "Batch result history and retry actions fit narrow native layout: "+language+"/"+fontSize);
                Screenshot(results,Path.Combine(output,$"results-{language}-{fontSize}.png"));results.Close();
            }
        }finally{Loc.Initialize("zh-Hans");foreach(var pair in Loc.Strings)Application.Current.Resources[pair.Key]=pair.Value;}
    }
    private static void PartialResultsDialog(MainWindow window,string raw,string output,Action<bool,string> check)
    {
        var first=raw;var second=Path.Combine(output,"target"+Path.GetExtension(raw));
        var writes=0;var replaceNextReceipt=false;
        var store=new EditStore(Path.Combine(output,"partial-edits"),(path,value)=>{
            if(++writes==2)throw new IOException("Injected second target save failure");AtomicJson.Write(path,value);
            if(replaceNextReceipt) {
                replaceNextReceipt=false;var external=new Adjustments();external.Set(Parameter.Exposure,1.75);
                var registry=JsonSerializer.SerializeToNode(value)!;
                registry["Records"]![first]=JsonSerializer.SerializeToNode(new SavedEdit(OriginalIdentity.Read(first),external.Capture(),null));
                registry["Revisions"]![first]=Guid.NewGuid().ToString();AtomicJson.Write(path,registry);
            }
        });
        Set(window,"editStore",store);window.OpenFile(first);Ready(window);
        var settings=new Adjustments();settings.Set(Parameter.Exposure,1.25);
        var payload=AdjustmentTransfer.Capture(AdjustmentScope.Custom([AdjustmentField.Exposure]),new(OriginalIdentity.Read(raw),settings.Capture(),null),new(raw,true));
        var stage=0;Exception? failure=null;VersionedPhotoEdit? undone=null;VersionedPhotoEdit? secondSaved=null;Window? outer=null;DispatcherTimer? recoveryTimer=null;
        var timer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(80)};
        timer.Tick+=(_,_)=>{
            var dialog=Application.Current.Windows.OfType<Window>().FirstOrDefault(w=>AutomationProperties.GetAutomationId(w)=="adjustment.results");
            if(dialog==null)return;
            try {
                if(stage==0) {
                    outer=dialog;
                    Find<Button>(dialog,"adjustment.results.apply").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    check(store.Find(first)!.Settings.Values[1]==1.25 && store.Find(second)==null,"Native batch results retain a real second-target write failure");
                    check(Find<Button>(dialog,"adjustment.results.undo").IsEnabled,"Batch results expose undo for the successful paste components");stage++;return;
                }
                if(stage==1) {
                    Find<Button>(dialog,"adjustment.results.undo").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));undone=store.VersionedState(first);
                    check(undone.Edit==null && Get<Adjustments>(window,"settings")[Parameter.Exposure]==0 && Find<Button>(dialog,"adjustment.results.apply").IsEnabled,
                        "Undoing the successful component preserves the failed-target retry action");stage++;return;
                }
                if(stage==2) {
                    Find<Button>(dialog,"adjustment.results.apply").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));secondSaved=store.VersionedState(second);
                    check(store.VersionedState(first).SameAs(undone) && secondSaved.Edit!.Settings.Values[1]==1.25 &&
                        Get<Adjustments>(window,"settings")[Parameter.Exposure]==0,"Retry saves only the failed target and never rewrites the undone photo or its UI");
                    check(Find<TextBlock>(dialog,"adjustment.results.summary").Text.Contains("已撤销 1 张"),"Results distinguish undone components from currently saved targets");
                    Screenshot(dialog,Path.Combine(output,"partial-retry-after-undo.png"));stage++;return;
                }
                if(stage==3) {
                    Find<Button>(dialog,"adjustment.results.redo").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    check(store.Find(first)!.Settings.Values[1]==1.25 && store.VersionedState(second).SameAs(secondSaved),"Batch redo restores only the undone component");stage++;return;
                }
                if(stage==4) {
                    Find<Button>(dialog,"adjustment.results.undo").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    check(store.Find(first)==null && store.Find(second)==null,"Whole-paste undo traverses the same successful components after retry");stage++;return;
                }
                if(stage==5) {
                    // 当前 Tick 会阻塞在嵌套 ShowDialog；用独立 timer 驱动恢复页。
                    timer.Stop();replaceNextReceipt=true;
                    recoveryTimer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(80)};
                    recoveryTimer.Tick+=(_,_)=>{
                        var recovery=Application.Current.Windows.OfType<Window>().FirstOrDefault(w=>w.Owner==outer && AutomationProperties.GetAutomationId(w)=="adjustment.results");
                        if(recovery==null)return;
                        recoveryTimer.Stop();
                        try {
                            var reload=Find<Button>(recovery,"adjustment.results.reload");
                            check(reload.IsVisible && Get<bool>(window,"adjustmentReloadRequired"),"A changed history save receipt exposes reload in its nested recovery dialog");
                            stage=6;reload.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                        }catch(Exception error){failure=error;recovery.Close();outer?.Close();}
                    };
                    recoveryTimer.Start();
                    Find<Button>(dialog,"adjustment.results.redo").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));return;
                }
            }catch(Exception error){failure=error;timer.Stop();dialog.Close();}
        };
        timer.Start();var pending=(Task)Invoke(window,"ShowAdjustmentPreflight",payload,new[]{first,second},AdjustmentHistoryAction.Paste,null)!;
        InteractionChecks.PumpUntil(()=>pending.IsCompleted);timer.Stop();recoveryTimer?.Stop();pending.GetAwaiter().GetResult();
        if(failure!=null)throw failure;
        check(stage==6,"Production modal partial-save, undo, retry and redo flow completes");Ready(window);
        check(outer?.IsVisible==false && Application.Current.Windows.OfType<Window>().All(w=>AutomationProperties.GetAutomationId(w)!="adjustment.results") &&
            Get<Adjustments>(window,"settings")[Parameter.Exposure]==1.75 && !Get<bool>(window,"adjustmentReloadRequired"),
            "Nested receipt recovery closes the old batch results and reloads the newest saved photo");
    }
    private static T Find<T>(DependencyObject root,string id) where T:DependencyObject
    {
        if(root is T match && AutomationProperties.GetAutomationId(match)==id)return match;
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++)try{return Find<T>(VisualTreeHelper.GetChild(root,i),id);}catch(InvalidOperationException) { }
        throw new InvalidOperationException("Missing UI control "+id);
    }
    private static void Screenshot(Window window,string path)
    {
        var bitmap=new RenderTargetBitmap((int)window.ActualWidth,(int)window.ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(window);
        var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var output=File.Create(path);encoder.Save(output);
    }
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    private static T Get<T>(object value,string name)=>(T)value.GetType().GetField(name,Private)!.GetValue(value)!;
    private static void Set(object value,string name,object state)=>value.GetType().GetField(name,Private)!.SetValue(value,state);
    private static object? Invoke(object value,string name,params object?[] args)=>value.GetType().GetMethod(name,Private)!.Invoke(value,args);
}
