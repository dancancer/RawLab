using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class TransformUiChecks
{
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        if(File.Exists(Path.Combine(BatchJournal.DefaultDirectory,"job.json")))throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
        var output=Path.Combine(Path.GetFullPath(repo),"build","windows-v08-ui");Directory.CreateDirectory(output);
        var directory=Path.Combine(output,Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        var photo=Path.Combine(directory,"photo"+Path.GetExtension(raw));var other=Path.Combine(directory,"other"+Path.GetExtension(raw));
        File.Copy(raw,photo);File.Copy(raw,other);
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        Loc.Initialize("zh-Hans");foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        var window=TestWindowState.CreateIsolatedWindow(directory);var store=new EditStore(Path.Combine(directory,"edits"));window.EditStoreInstance=store;
        try
        {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(photo);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            Click(window.AutoExposureButton);InteractionChecks.PumpUntil(()=>!window.AutoExposing && window.ExportPng.IsEnabled);
            var measured=window.Settings[Parameter.Exposure];
            check(Math.Abs(measured*100-Math.Round(measured*100))<1e-6,"Native auto exposure commits to the visible 0.01 EV grid");
            Commit(window.ValueText,"0.13");InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var invalidLook=Path.Combine(directory,"invalid.cube");File.WriteAllText(invalidLook,"not a CUBE");
            var goodLook=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_PROVIA_65grid_V.1.00.cube");
            var import=window.ImportLookFiles([invalidLook,goodLook]);InteractionChecks.PumpUntil(()=>import.IsCompleted);
            check(import.GetAwaiter().GetResult().Count==1 && window.CurrentLut==goodLook,"Partial look import retains validated success and reports the invalid file");
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var savedLook=window.CurrentLookIdentity();
            window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.CurrentLookIdentity()==null && window.Settings[Parameter.Exposure]==0,
                "A new RAW does not inherit the previous photo's look or exposure");
            window.OpenFile(photo);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.CurrentLookIdentity()==savedLook && window.CurrentLut==goodLook &&
                Math.Abs(window.Settings[Parameter.Exposure]-.13)<1e-6,
                "Reopening an edited RAW restores its saved look and exposure");
            window.SetComparisonMode(true,false);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            // 用不同校准值证明草稿显影回调不会回写 committed WB。
            window.Settings.ResolveWhiteBalance((9000,-30));window.MarkEditedForTests();
            window.SaveEditsForTests();var original=window.Settings.Capture();
            window.SelectToolForTests(EditorAdjustmentTool.BlackPoint);
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            var draft=window.TransformDraft;
            check(draft.Active && !window.ExportPng.IsEnabled,"Real WPF geometry workspace gates export");
            check(ReferenceEquals(((CheckBox)window.GeometryEditor.FindName("HorizontalFlip")).Foreground,
                Application.Current.Resources["Foreground"]),"Native crop flip icons retain the editor foreground");
            window.UpdateLayout();
            var geometryBounds=window.GeometrySurface.TransformToAncestor(window.AdjustmentPanel)
                .TransformBounds(new Rect(window.GeometrySurface.RenderSize));
            var actionBounds=window.DraftActions.TransformToAncestor(window.AdjustmentPanel)
                .TransformBounds(new Rect(window.DraftActions.RenderSize));
            var toolViewport = window.ToolsScroller.TransformToAncestor(window.AdjustmentPanel)
                .TransformBounds(new Rect(window.ToolsScroller.RenderSize));
            check(geometryBounds.Height>40 && actionBounds.Top>=toolViewport.Bottom-.5 &&
                actionBounds.Bottom<=window.AdjustmentPanel.ActualHeight,
                "Crop parameters and fixed draft actions occupy separate visible regions");
            window.SetComparisonMode(true,true);window.BeforeViewMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            check(draft.Active && !window.ViewState.Enabled && !window.ViewState.HoldingBefore,
                "Comparison commands and before action cannot exit or bypass an active geometry draft");
            var unchangedRevision=window.EditRevision;
            check(!window.ApplyDraftButton.IsEnabled && !window.ApplyTransformDraftForTests() &&
                draft.Active && window.EditRevision==unchangedRevision,"Unchanged exact draft cannot apply");
            check(window.Settings.Capture().SameAs(original),"Draft native WB result cannot overwrite deliberately different committed calibration");
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
            var previousLook=window.CurrentLut;window.CurrentLut=Path.Combine(directory,"missing.cube");
            window.ScheduleForTests(false,false);
            check(!window.ApplyDraftButton.IsEnabled && draft.Active,"Failed draft preview invalidates a previously ready Apply gate");
            window.CurrentLut=previousLook;window.ScheduleForTests(false,false);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            var width=(TextBox)window.GeometryEditor.FindName("CropWidth");Commit(width,"60");
            check(draft.Geometry.CropWidth==.6 && window.Settings.Capture().SameAs(original) && store.Find(photo)!.Settings.SameAs(original),
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
            var beforeFailedApply=window.EditRevision;
            var beforeFailedPreview=PreviewRequests(window);
            window.EditStoreInstance=new EditStore(blocked);
            check(!window.ApplyTransformDraftForTests() && draft.Active && draft.Geometry.CropWidth==.62 &&
                window.Settings.Capture().SameAs(original) && window.EditRevision==beforeFailedApply &&
                window.RetrySave.Visibility==Visibility.Visible && PreviewRequests(window)==beforeFailedPreview &&
                File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(savedBytes),
                "Failed draft save preserves committed state, draft, revision and durable record");
            window.EditStoreInstance=store;Click(window.RetrySave);
            check(PreviewRequests(window)==beforeFailedPreview+1,"Successful retry schedules one exact preview while restoring comparison");
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.EditRevision==beforeFailedApply+1 && !window.EditDirty &&
                !window.EditSaveTimer.IsEnabled,"Retry applies the draft once without a second autosave");
            check(!draft.Active && store.Find(photo)!.Settings.Geometry?.CropWidth==.62,"Apply writes the draft once to photo memory");
            check(window.SelectedToneParameter==null && window.SelectedParameter==Parameter.Exposure,
                "Applying geometry after black point returns to exposure without a stale tone selection");
            window.SelectToolForTests(EditorAdjustmentTool.WhitePoint);
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            Commit((TextBox)window.GeometryEditor.FindName("CropWidth"),"bad");
            window.CancelTransformDraftForTests();InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.Settings.Geometry.CropWidth==.62 && !window.GeometryEditor.HasInvalidInput,"Cancel restores committed crop and clears invalid geometry input");
            check(window.SelectedToneParameter==null,"Cancelling geometry clears the previous white point selection");
            window.SelectToolForTests(EditorAdjustmentTool.Vibrance);
            Click(window.LensCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            ((CheckBox)window.LensEditor.FindName("Distortion")).IsChecked=true;
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            check(draft.Active && draft.Lens.Distortion && !window.Settings.Lens.Distortion,"Lens switches remain draft-only until apply");
            Click(window.ApplyDraftButton);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(store.Find(photo)!.Settings.Lens?.Distortion==true,"Lens Apply persists the real correction request");
            check(window.SelectedToneParameter==null,"Applying lens clears the previous vibrance selection");
            window.SelectToolForTests(EditorAdjustmentTool.BlackPoint);
            Click(window.LensCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            var pairCommitted=window.Settings.Capture();
            var pairRecord=File.ReadAllBytes(Path.Combine(directory,"edits","edits.json"));
            var pairRevision=window.EditRevision;var pairPreview=PreviewRequests(window);
            var pairReset=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Geometry))!;
            check(window.CommitReset(pairReset,pairRevision) && draft.Active && draft.Geometry.IsIdentity && draft.Lens==new LensSettings() &&
                window.Settings.Capture().SameAs(pairCommitted) && window.EditRevision==pairRevision &&
                PreviewRequests(window)==pairPreview+1 && !window.EditDirty &&
                File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(pairRecord),
                "Geometry group commits only the complete draft pair and one preview without a save");
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            window.CancelTransformDraftForTests();InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.Settings.Geometry.CropWidth==.62 && window.Settings.Lens.Distortion,
                "Cancelling the group reset retains both committed transform objects");
            check(window.SelectedToneParameter==null,"Cancelling lens clears the previous black point selection");
            var normalRevision=window.EditRevision;var normalPreview=PreviewRequests(window);
            var normalSettings=window.Settings.Capture();
            var staleReset=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Light))!;
            window.Settings.ResolveWhiteBalance((10000,40));
            check(!window.CommitReset(staleReset,normalRevision) && window.EditRevision==normalRevision && PreviewRequests(window)==normalPreview,
                "Same-revision WB metadata invalidates the real prepared reset without an edit or preview");
            window.Settings=normalSettings.Restore();
            var ordinaryReset=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Light))!;
            var normalLook=window.CurrentLut;var recordBeforeReset=File.ReadAllBytes(Path.Combine(directory,"edits","edits.json"));
            var history=window.AdjustmentSessionInstance!;var historyBeforeReset=history.Transactions.Count;
            check(window.CommitReset(ordinaryReset,normalRevision) && window.EditRevision==normalRevision+1 &&
                PreviewRequests(window)==normalPreview+1 && !window.EditDirty && !window.EditSaveTimer.IsEnabled &&
                window.CurrentLut==normalLook && !File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(recordBeforeReset) &&
                store.Find(photo)!.Settings.SameAs(window.Settings.Capture()) && history.Transactions.Count==historyBeforeReset+1,
                "Ordinary reset preserves resolved look and commits one durable history component and preview");
            var resetReceipt=store.ReadState(photo);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);window.SaveEditsForTests();
            check(store.ReadState(photo).SameAs(resetReceipt) && history.Transactions.Count==historyBeforeReset+1,
                "Preview completion and the former autosave boundary cannot append another reset save");
            var noChange=window.PrepareReset(new(EditorResetKind.Group,EditorAdjustmentGroup.Light))!;
            normalPreview=PreviewRequests(window);normalRevision=window.EditRevision;
            check(noChange.Status==EditorResetStatus.NoChange && !window.CommitReset(noChange,normalRevision) &&
                PreviewRequests(window)==normalPreview && window.EditRevision==normalRevision && !window.EditDirty,
                "Unchanged ordinary reset creates no real save or preview request");
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>PreviewReady(window));
            Commit((TextBox)window.GeometryEditor.FindName("CropWidth"),"63");
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            var leaveCommitted=window.Settings.Capture();
            var leaveRecord=File.ReadAllBytes(Path.Combine(directory,"edits","edits.json"));
            var leaveRevision=window.EditRevision;var leaveOpenRevision=window.OpenRevision;
            var leavePreview=PreviewRequests(window);var leaveStage=0;string? leaveFailure=null;Window? retainedDialog=null;
            var leaveWatch=System.Diagnostics.Stopwatch.StartNew();
            var chooseApply=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(20)};
            window.EditStoreInstance=new EditStore(blocked);
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
                    if(dialog!=retainedDialog || !dialog.IsVisible || window.CurrentFile!=photo || !draft.Active ||
                        draft.Geometry.CropWidth!=.63 || !window.Settings.Capture().SameAs(leaveCommitted) ||
                        window.EditRevision!=leaveRevision || window.OpenRevision!=leaveOpenRevision ||
                        PreviewRequests(window)!=leavePreview || !File.ReadAllBytes(Path.Combine(directory,"edits","edits.json")).SequenceEqual(leaveRecord) ||
                        ((TextBlock)body.Children[0]).Text!=Loc.Text("调整未保存 · 重试"))
                    { leaveFailure="Failed Apply-and-leave did not retain its dialog, destination, state, record and localized error";chooseApply.Stop();dialog.Close();return; }
                    window.EditStoreInstance=store;leaveStage=2;chooseApply.Stop();Click(apply);
                }
                catch(Exception error){leaveFailure=error.ToString();chooseApply.Stop();dialog.Close();}
            };
            try { chooseApply.Start();window.OpenFile(other); }
            finally { chooseApply.Stop();window.EditStoreInstance=store;if(retainedDialog?.IsVisible==true)retainedDialog.Close(); }
            check(leaveFailure==null && leaveStage==2 && window.CurrentFile==other && !draft.Active &&
                window.EditRevision==leaveRevision+1 && window.OpenRevision==leaveOpenRevision+1 &&
                !window.EditDirty && !window.EditSaveTimer.IsEnabled &&
                new EditStore(Path.Combine(directory,"edits")).Find(photo)!.Settings.Geometry?.CropWidth==.63,
                leaveFailure ?? "Retry in the retained leave dialog durably applies once and executes the original photo destination once");
            Console.WriteLine("WAIT exact preview after applying draft and leaving photo");
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.OpenRevision==leaveOpenRevision+1,"Completed leave does not replay its original photo navigation");
            window.OpenFile(photo);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            window.EditStoreInstance=new EditStore(blocked);
            Commit(window.ValueText,"0.27");window.SaveEditsForTests();window.OpenFile(other);
            check(window.CurrentFile==photo && window.RetrySave.Visibility==Visibility.Visible,"Persistent save failure blocks switching photos");
            window.EditStoreInstance=store;window.SaveEditsForTests();window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(window.CurrentFile==other,"Retry releases the photo-switch guard after durable save");
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
            Console.Error.WriteLine($"Transform UI failed: {error}\nfile={window.CurrentFile}; openRevision={window.OpenRevision}; exactReady={window.ExactReady}; schedulerBusy={window.SchedulerBusy}; schedulerRevision={window.SchedulerRevision}; schedulerActive={window.SchedulerHasActive}; draftReady={window.TransformPreviewReady}; resizePending={window.PreviewResizeTimer.IsEnabled}; exportEnabled={window.ExportPng.IsEnabled}; renderFailed={window.RenderFailed}; status={window.Status.Text}");
            throw;
        }
        finally
        {
            Console.WriteLine("CLEANUP transform UI: cancel draft, save, close window");
            if(window.TransformDraft.Active)window.CancelTransformDraftForTests();
            window.EditStoreInstance=store;window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);app.Shutdown();
            Console.WriteLine("CLEANUP transform UI completed");
        }
    }
    private static bool PreviewReady(MainWindow window)=>window.TransformPreviewReady && !window.PreviewResizeTimer.IsEnabled;
    private static long PreviewRequests(MainWindow window)=>window.SchedulerRevision;
    private static void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Commit(TextBox field,string text){field.Text=text;field.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice,Environment.TickCount,field,field){RoutedEvent=UIElement.LostKeyboardFocusEvent});}
}
