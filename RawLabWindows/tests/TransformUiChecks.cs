using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class TransformUiChecks
{
    private const BindingFlags Private=BindingFlags.NonPublic|BindingFlags.Instance;
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        if(File.Exists(Path.Combine(BatchJournal.DefaultDirectory,"job.json")))throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
        var output=Path.Combine(repo,"build","windows-v08-ui");Directory.CreateDirectory(output);
        var directory=Path.Combine(output,Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        var photo=Path.Combine(directory,"photo"+Path.GetExtension(raw));var other=Path.Combine(directory,"other"+Path.GetExtension(raw));
        File.Copy(raw,photo);File.Copy(raw,other);
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        Loc.Initialize("zh-Hans");foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        var window=new MainWindow();TestWindowState.Isolate(window,directory);var store=new EditStore(Path.Combine(directory,"edits"));Set(window,"editStore",store);
        try
        {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(photo);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            Click(window.AutoExposureButton);InteractionChecks.PumpUntil(()=>!Get<bool>(window,"autoExposing") && window.ExportPng.IsEnabled);
            var measured=Get<Adjustments>(window,"settings")[Parameter.Exposure];
            check(Math.Abs(measured*100-Math.Round(measured*100))<1e-6,"Native auto exposure commits to the visible 0.01 EV grid");
            Commit(window.ValueText,"0.13");InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var invalidLook=Path.Combine(directory,"invalid.cube");File.WriteAllText(invalidLook,"not a CUBE");
            var goodLook=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_PROVIA_65grid_V.1.00.cube");
            var import=window.ImportLookFiles([invalidLook,goodLook]);InteractionChecks.PumpUntil(()=>import.IsCompleted);
            check(import.GetAwaiter().GetResult().Count==1 && Get<string>(window,"lut")==goodLook,"Partial look import retains validated success and reports the invalid file");
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var savedLook=window.CurrentLookIdentity();
            window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.CurrentLookIdentity()==null && Get<Adjustments>(window,"settings")[Parameter.Exposure]==0,
                "A new RAW does not inherit the previous photo's look or exposure");
            window.OpenFile(photo);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.CurrentLookIdentity()==savedLook && Get<string>(window,"lut")==goodLook &&
                Math.Abs(Get<Adjustments>(window,"settings")[Parameter.Exposure]-.13)<1e-6,
                "Reopening an edited RAW restores its saved look and exposure");
            window.SetComparisonMode(true,false);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            // 用不同校准值证明草稿显影回调不会回写 committed WB。
            Get<Adjustments>(window,"settings").ResolveWhiteBalance((9000,-30));Invoke(window,"MarkEdited");
            Invoke(window,"SaveEdits");var original=Get<Adjustments>(window,"settings").Capture();
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            var draft=Get<TransformDraft>(window,"transform");
            check(draft.Active && !window.ExportPng.IsEnabled,"Real WPF geometry workspace gates export");
            check(ReferenceEquals(((CheckBox)window.GeometryEditor.FindName("HorizontalFlip")).Foreground,
                Application.Current.Resources["Foreground"]),"Native crop flip icons retain the editor foreground");
            window.UpdateLayout();
            var geometryBounds=window.GeometrySurface.TransformToAncestor(window.AdjustmentPanel)
                .TransformBounds(new Rect(window.GeometrySurface.RenderSize));
            var actionBounds=window.DraftActions.TransformToAncestor(window.AdjustmentPanel)
                .TransformBounds(new Rect(window.DraftActions.RenderSize));
            check(geometryBounds.Height>40 && actionBounds.Top>=geometryBounds.Bottom-.5 &&
                actionBounds.Bottom<=window.AdjustmentPanel.ActualHeight,
                "Crop parameters and fixed draft actions occupy separate visible regions");
            window.SetComparisonMode(true,true);window.BeforeViewMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            check(draft.Active && !Get<EditorViewState>(window,"view").Enabled && !Get<EditorViewState>(window,"view").HoldingBefore,
                "Comparison commands and before action cannot exit or bypass an active geometry draft");
            var unchangedRevision=Get<long>(window,"editRevision");
            check(!window.ApplyDraftButton.IsEnabled && !(bool)Invoke(window,"ApplyTransformDraft")! &&
                draft.Active && Get<long>(window,"editRevision")==unchangedRevision,"Unchanged exact draft cannot apply");
            check(Get<Adjustments>(window,"settings").Capture().SameAs(original),"Draft native WB result cannot overwrite deliberately different committed calibration");
            foreach(var horizontal in new[]{true,false})
            {
                var edge=CropInteraction.Dragging(new(0,0,.1,.1),CropHandle.Move,2,2,6000,4000,null);
                window.GeometryEditor.Refresh(CropInteraction.Applying(edge,new()));
                ((CheckBox)window.GeometryEditor.FindName(horizontal ? "HorizontalFlip" : "VerticalFlip")).IsChecked=true;
                _=draft.Geometry.NativeConfig();
                check((horizontal ? draft.Geometry.CropX : draft.Geometry.CropY)==0 && draft.Geometry.CropWidth==.1 && draft.Geometry.CropHeight==.1,
                    "Real geometry flip keeps a boundary-moved 10 percent crop valid: "+horizontal);
                InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            }
            Click((Button)window.GeometryEditor.FindName("ResetGeometry"));InteractionChecks.PumpUntil(()=>PreviewReady(window));
            var previousLook=Get<string>(window,"lut");Set(window,"lut",Path.Combine(directory,"missing.cube"));
            typeof(MainWindow).GetMethod("Schedule",Private)!.Invoke(window,[false]);
            check(!window.ApplyDraftButton.IsEnabled && draft.Active,"Failed draft preview invalidates a previously ready Apply gate");
            Set(window,"lut",previousLook);typeof(MainWindow).GetMethod("Schedule",Private)!.Invoke(window,[false]);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            var width=(TextBox)window.GeometryEditor.FindName("CropWidth");Commit(width,"60");
            check(draft.Geometry.CropWidth==.6 && Get<Adjustments>(window,"settings").Capture().SameAs(original) && store.Find(photo)!.Settings.SameAs(original),
                "Crop preview changes neither committed settings nor saved record");
            var cropSurface=EditorShellChecks.ArrangeLayout(window,new Size(1000,680));
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            EditorShellChecks.CaptureLayout(window,cropSurface,Path.Combine(output,"geometry-draft.png"));
            width.Text="bad";width.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,PresentationSource.FromVisual(window),Environment.TickCount,Key.Escape){RoutedEvent=Keyboard.PreviewKeyDownEvent});
            check(draft.Active && width.Text=="60","Escape restores only the current numeric input, not the geometry draft");
            Commit(width,"bad");Click(window.ApplyDraftButton);
            check(draft.Active && width.Text=="bad","Invalid geometry stays available for correction and cannot apply");
            Click((Button)window.GeometryEditor.FindName("ResetGeometry"));InteractionChecks.PumpUntil(()=>PreviewReady(window));
            check(!window.GeometryEditor.HasInvalidInput && draft.Geometry.IsIdentity,"Geometry reset clears invalid fields and resets the draft");
            Commit(width,"62");InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            var blocked=Path.Combine(directory,"blocked");File.WriteAllText(blocked,"not a directory");
            var savedBytes=File.ReadAllBytes(Path.Combine(directory,"edits","edits.json"));
            var beforeFailedApply=Get<long>(window,"editRevision");
            var beforeFailedPreview=PreviewRequests(window);
            Set(window,"editStore",new EditStore(blocked));
            check(!(bool)Invoke(window,"ApplyTransformDraft")! && draft.Active && draft.Geometry.CropWidth==.62 &&
                Get<Adjustments>(window,"settings").Capture().SameAs(original) && Get<long>(window,"editRevision")==beforeFailedApply &&
                window.RetrySave.Visibility==Visibility.Visible && PreviewRequests(window)==beforeFailedPreview &&
                File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(savedBytes),
                "Failed draft save preserves committed state, draft, revision and durable record");
            Set(window,"editStore",store);Click(window.RetrySave);
            check(PreviewRequests(window)==beforeFailedPreview+1,"Successful retry schedules one exact preview while restoring comparison");
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(Get<long>(window,"editRevision")==beforeFailedApply+1 && !Get<bool>(window,"editDirty") &&
                !Get<DispatcherTimer>(window,"editSaveTimer").IsEnabled,"Retry applies the draft once without a second autosave");
            check(!draft.Active && store.Find(photo)!.Settings.Geometry?.CropWidth==.62,"Apply writes the draft once to photo memory");
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            Commit((TextBox)window.GeometryEditor.FindName("CropWidth"),"bad");
            Invoke(window,"CancelTransformDraft");InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(Get<Adjustments>(window,"settings").Geometry.CropWidth==.62 && !window.GeometryEditor.HasInvalidInput,"Cancel restores committed crop and clears invalid geometry input");
            Click(window.LensCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            ((CheckBox)window.LensEditor.FindName("Distortion")).IsChecked=true;
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            check(draft.Active && draft.Lens.Distortion && !Get<Adjustments>(window,"settings").Lens.Distortion,"Lens switches remain draft-only until apply");
            Click(window.ApplyDraftButton);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(store.Find(photo)!.Settings.Lens?.Distortion==true,"Lens Apply persists the real correction request");
            Click(window.LensCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            var pairCommitted=Get<Adjustments>(window,"settings").Capture();
            var pairRecord=File.ReadAllBytes(Path.Combine(directory,"edits","edits.json"));
            var pairRevision=Get<long>(window,"editRevision");var pairPreview=PreviewRequests(window);
            var pairReset=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Geometry))!;
            check(window.CommitReset(pairReset,pairRevision) && draft.Active && draft.Geometry.IsIdentity && draft.Lens==new LensSettings() &&
                Get<Adjustments>(window,"settings").Capture().SameAs(pairCommitted) && Get<long>(window,"editRevision")==pairRevision &&
                PreviewRequests(window)==pairPreview+1 && !Get<bool>(window,"editDirty") &&
                File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(pairRecord),
                "Geometry group commits only the complete draft pair and one preview without a save");
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            Invoke(window,"CancelTransformDraft");InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(Get<Adjustments>(window,"settings").Geometry.CropWidth==.62 && Get<Adjustments>(window,"settings").Lens.Distortion,
                "Cancelling the group reset retains both committed transform objects");
            var normalRevision=Get<long>(window,"editRevision");var normalPreview=PreviewRequests(window);
            var normalSettings=Get<Adjustments>(window,"settings").Capture();
            var staleReset=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Light))!;
            Get<Adjustments>(window,"settings").ResolveWhiteBalance((10000,40));
            check(!window.CommitReset(staleReset,normalRevision) && Get<long>(window,"editRevision")==normalRevision && PreviewRequests(window)==normalPreview,
                "Same-revision WB metadata invalidates the real prepared reset without an edit or preview");
            Set(window,"settings",normalSettings.Restore());
            var ordinaryReset=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Light))!;
            var normalLook=Get<string>(window,"lut");var recordBeforeReset=File.ReadAllBytes(Path.Combine(directory,"edits","edits.json"));
            var history=Get<AdjustmentTransferSession>(window,"adjustmentSession");var historyBeforeReset=history.Transactions.Count;
            check(window.CommitReset(ordinaryReset,normalRevision) && Get<long>(window,"editRevision")==normalRevision+1 &&
                PreviewRequests(window)==normalPreview+1 && !Get<bool>(window,"editDirty") && !Get<DispatcherTimer>(window,"editSaveTimer").IsEnabled &&
                Get<string>(window,"lut")==normalLook && !File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(recordBeforeReset) &&
                store.Find(photo)!.Settings.SameAs(Get<Adjustments>(window,"settings").Capture()) && history.Transactions.Count==historyBeforeReset+1,
                "Ordinary reset preserves resolved look and commits one durable history component and preview");
            var resetReceipt=store.VersionedState(photo);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);Invoke(window,"SaveEdits");
            check(store.VersionedState(photo).SameAs(resetReceipt) && history.Transactions.Count==historyBeforeReset+1,
                "Preview completion and the former autosave boundary cannot append another reset save");
            var noChange=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Light))!;
            normalPreview=PreviewRequests(window);normalRevision=Get<long>(window,"editRevision");
            check(noChange.Status==EditorResetStatus.NoChange && !window.CommitReset(noChange,normalRevision) &&
                PreviewRequests(window)==normalPreview && Get<long>(window,"editRevision")==normalRevision && !Get<bool>(window,"editDirty"),
                "Unchanged ordinary reset creates no real save or preview request");
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            Commit((TextBox)window.GeometryEditor.FindName("CropWidth"),"63");
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            var leaveCommitted=Get<Adjustments>(window,"settings").Capture();
            var leaveRecord=File.ReadAllBytes(Path.Combine(directory,"edits","edits.json"));
            var leaveRevision=Get<long>(window,"editRevision");var leaveOpenRevision=Get<long>(window,"openRevision");
            var leavePreview=PreviewRequests(window);var leaveStage=0;string? leaveFailure=null;Window? retainedDialog=null;
            var leaveWatch=System.Diagnostics.Stopwatch.StartNew();
            var chooseApply=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(20)};
            Set(window,"editStore",new EditStore(blocked));
            chooseApply.Tick+=(_,_)=>{
                var dialog=app.Windows.OfType<Window>().SingleOrDefault(candidate=>candidate.Title==Loc.Text("保留这次几何或镜头修改？"));
                if(leaveWatch.Elapsed>TimeSpan.FromMinutes(3))
                { leaveFailure="Apply-and-leave dialog did not complete";chooseApply.Stop();dialog?.Close();return; }
                if(dialog==null)return;
                try
                {
                    var body=(StackPanel)dialog.Content;
                    var apply=((WrapPanel)body.Children[1]).Children.OfType<Button>().Single(button=>Equals(button.Content,Loc.Text("应用并离开")));
                    if(leaveStage==0){retainedDialog=dialog;leaveStage=1;Click(apply);return;}
                    if(dialog!=retainedDialog || !dialog.IsVisible || Get<string>(window,"file")!=photo || !draft.Active ||
                        draft.Geometry.CropWidth!=.63 || !Get<Adjustments>(window,"settings").Capture().SameAs(leaveCommitted) ||
                        Get<long>(window,"editRevision")!=leaveRevision || Get<long>(window,"openRevision")!=leaveOpenRevision ||
                        PreviewRequests(window)!=leavePreview || !File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(leaveRecord) ||
                        ((TextBlock)body.Children[0]).Text!=Loc.Text("调整未保存 · 重试"))
                    { leaveFailure="Failed Apply-and-leave did not retain its dialog, destination, state, record and localized error";chooseApply.Stop();dialog.Close();return; }
                    Set(window,"editStore",store);leaveStage=2;chooseApply.Stop();Click(apply);
                }
                catch(Exception error){leaveFailure=error.ToString();chooseApply.Stop();dialog.Close();}
            };
            try { chooseApply.Start();window.OpenFile(other); }
            finally { chooseApply.Stop();Set(window,"editStore",store);if(retainedDialog?.IsVisible==true)retainedDialog.Close(); }
            check(leaveFailure==null && leaveStage==2 && Get<string>(window,"file")==other && !draft.Active &&
                Get<long>(window,"editRevision")==leaveRevision+1 && Get<long>(window,"openRevision")==leaveOpenRevision+1 &&
                !Get<bool>(window,"editDirty") && !Get<DispatcherTimer>(window,"editSaveTimer").IsEnabled &&
                new EditStore(Path.Combine(directory,"edits")).Find(photo)!.Settings.Geometry?.CropWidth==.63,
                leaveFailure ?? "Retry in the retained leave dialog durably applies once and executes the original photo destination once");
            Console.WriteLine("WAIT exact preview after applying draft and leaving photo");
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(Get<long>(window,"openRevision")==leaveOpenRevision+1,"Completed leave does not replay its original photo navigation");
            window.OpenFile(photo);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            Set(window,"editStore",new EditStore(blocked));
            Commit(window.ValueText,"0.27");Invoke(window,"SaveEdits");window.OpenFile(other);
            check(Get<string>(window,"file")==photo && window.RetrySave.Visibility==Visibility.Visible,"Persistent save failure blocks switching photos");
            Set(window,"editStore",store);Invoke(window,"SaveEdits");window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(Get<string>(window,"file")==other,"Retry releases the photo-switch guard after durable save");
            foreach(var size in new[]{new Size(1000,680),new Size(1440,920)})
            {
                var surface=EditorShellChecks.ArrangeLayout(window,size);
                InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                check(window.ResultCanvas.ActualHeight>=160,"Real RAW layout retains 160 DIP canvas");
                EditorShellChecks.CaptureLayout(window,surface,Path.Combine(output,$"raw-{size.Width}.png"));
            }
        }
        catch(Exception error)
        {
            // 清理也可能等待 native worker，先落下原始异常和状态，避免被关闭等待掩盖。
            var scheduler=Get<object>(window,"scheduler");
            object? Scheduler(string property)=>scheduler.GetType().GetProperty(property)!.GetValue(scheduler);
            Console.Error.WriteLine($"Transform UI failed: {error}\nfile={Get<string>(window,"file")}; openRevision={Get<long>(window,"openRevision")}; exactReady={Get<bool>(window,"exactReady")}; schedulerBusy={Scheduler("Busy")}; schedulerRevision={Scheduler("Revision")}; schedulerActive={Scheduler("Active")}; draftReady={Get<bool>(window,"transformPreviewReady")}; resizePending={Get<DispatcherTimer>(window,"previewResize").IsEnabled}; exportEnabled={window.ExportPng.IsEnabled}; renderFailed={Get<bool>(window,"renderFailed")}; status={window.Status.Text}");
            throw;
        }
        finally
        {
            Console.WriteLine("CLEANUP transform UI: cancel draft, save, close window");
            if(Get<TransformDraft>(window,"transform").Active)Invoke(window,"CancelTransformDraft");
            Set(window,"editStore",store);window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);app.Shutdown();
            Console.WriteLine("CLEANUP transform UI completed");
        }
    }
    private static T Get<T>(object owner,string name)=>(T)owner.GetType().GetField(name,Private)!.GetValue(owner)!;
    private static void Set(object owner,string name,object value)=>owner.GetType().GetField(name,Private)!.SetValue(owner,value);
    private static object? Invoke(object owner,string name)=>owner.GetType().GetMethod(name,Private)!.Invoke(owner,null);
    private static bool PreviewReady(MainWindow window)=>Get<bool>(window,"transformPreviewReady") && !Get<DispatcherTimer>(window,"previewResize").IsEnabled;
    private static long PreviewRequests(MainWindow window)=>(long)Get<object>(window,"scheduler").GetType().GetProperty("Revision")!.GetValue(Get<object>(window,"scheduler"))!;
    private static void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Commit(TextBox field,string text){field.Text=text;field.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice,Environment.TickCount,field,field){RoutedEvent=UIElement.LostKeyboardFocusEvent});}
}
