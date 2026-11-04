using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class HDRWorkflowChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(object owner,string field)=>(T)owner.GetType().GetField(field,Private)!.GetValue(owner)!;
    private static void Invoke(object owner,string method)=>owner.GetType().GetMethod(method,Private)!.Invoke(owner,null);
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);

    internal static void RunProRAWBatch(string repo, string fixture, Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(repo),"build","proraw-batch-workflow",Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        string Copy(string name) { var path=Path.Combine(root,name+".dng"); File.Copy(fixture,path); return path; }
        var source=Copy("source"); var low=Copy("sdr-target"); var high=Copy("hdr-target");
        var store=new EditStore(Path.Combine(root,"edits"));
        var hdr=new Adjustments(); hdr.SetHDRMode(true,true,cameraRaw:true,proRAW:true); hdr.Set(Parameter.Exposure,.75);
        var sdr=hdr.Clone(); sdr.SetHDRMode(false,true,cameraRaw:true,proRAW:true);
        sdr.Set(Parameter.Temperature,5200); sdr.Set(Parameter.Tint,9);
        var savedHDR=hdr.Clone(); savedHDR.Set(Parameter.Exposure,-.5);
        store.Save(low,sdr.Capture(),null); store.Save(high,savedHDR.Capture(),"builtin:missing-dormant-look.cube");
        var sdrRecord=store.VersionedState(low); var hdrRecord=store.VersionedState(high);

        var selection=new BatchSelectionSession(); selection.Add([high,low]);
        var collectionJournal=new BatchJournal(Path.Combine(root,"collection-journal"));
        var exporter=new BatchSelectionExport(store,collectionJournal,_=>null);
        var review=exporter.Prepare(selection,[],ExportFormat.HdrJpeg,512,root,_=>null);
        check(review.Rows[0].Error==null && review.Rows[1].Error!=null,"Collection admits HDR ProRAW and rejects the SDR target for HDR JPEG");
        selection.Select(selection.Photos[1].ID,false);
        review=exporter.Prepare(selection,[],ExportFormat.HdrJpeg,512,root,_=>null);
        var collection=exporter.Freeze(selection,review,_=>null);
        check(collection.Items.Single().Frozen?.Settings.ProRAWDecodeVersion==HDRNative.ProRAWDecodeVersion,
            "Collection freeze retains the saved ProRAW HDR settings");

        var journal=new BatchJournal(Path.Combine(root,"uniform-journal"));
        var preparation=new BatchHDRPreparation(store,_=>null);
        BatchJob Job(Adjustments settings) {
            var job=BatchJob.Create(source,settings.Capture(),null,"HDR");
            job.SourceIsProRAW=true; job.OutputDirectory=root; job.Format=ExportFormat.SdrJpeg; job.LongEdge=512;
            return job;
        }
        var tinted=hdr.Clone(); tinted.Set(Parameter.Tint,10);
        var rejected=Job(tinted); rejected.Items=[BatchItem.Create(low) with {Selected=true}];
        try { preparation.Freeze(rejected,journal,CancellationToken.None); check(false,"Non-neutral HDR WB reached an SDR target"); }
        catch(AdjustmentTransferException error) { check(error.Detail=="hdr.relative_white_balance" && journal.Load()==null,
            "Non-neutral HDR WB rejects the SDR target before creating a frozen job"); }

        var legacy=Job(hdr); legacy.Started=true;
        var removed=Copy("already-exported");
        var previousOutput=Path.Combine(root,"previous.jpg");
        File.WriteAllText(previousOutput,"completed output");
        var completed=BatchItem.Create(removed) with { Selected=true,Status=BatchStatus.Succeeded,
            Output=previousOutput,CompletedIdentity=OriginalIdentity.Read(previousOutput) };
        legacy.Items=[completed,BatchItem.Create(low) with {Selected=true}];
        var legacyJournal=new BatchJournal(Path.Combine(root,"legacy-journal"));
        legacyJournal.Save(legacy);
        File.Delete(removed);
        var migrated=preparation.Freeze(legacyJournal.Load()!,legacyJournal,CancellationToken.None);
        check(migrated.Items[0].Id==completed.Id && migrated.Items[0].Status==BatchStatus.Succeeded &&
            migrated.Items[0].Output==completed.Output && migrated.Items[1].Frozen?.Settings.HDR?.Mode==HDRMode.Sdr,
            "Recovering a legacy job does not reopen successful inputs and freezes the remaining SDR target");

        var app=TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var pending=Copy("missing-pending");
        store.Save(pending,sdr.Capture(),null);
        legacy.Items.Insert(1,BatchItem.Create(pending) with { Selected=true });
        legacyJournal.Save(legacy);
        var parked=pending+".parked";
        File.Move(pending,parked);
        void Run(BatchExportWindow batch) {
            var run=batch.StartExecution();
            InteractionChecks.PumpUntil(()=>run.IsCompleted);
            run.GetAwaiter().GetResult();
        }
        BatchExportWindow OpenLegacy() {
            var batch=new BatchExportWindow(legacyJournal.Load()!,legacyJournal,_=>new RenderEngine(0),hdrPreparation:preparation);
            batch.Show();
            return batch;
        }
        var legacyWindow=OpenLegacy();
        try {
            Run(legacyWindow);
            var first=legacyJournal.Load()!;
            var invalid=first.Items.Single(item=>item.Input==pending);
            check(first.SucceededCount==2 && invalid.Status==BatchStatus.Failed && invalid.Selected && invalid.Error!=null &&
                first.Items[0].Id==completed.Id && first.Items[0].Output==completed.Output && first.Error==null,
                "Legacy resume reports a missing unfinished target by row and exports the remaining photo: "+first.Error);
            var savedOutput=first.Items.Single(item=>item.Input==low).Output;
            legacyWindow.Close();
            File.Move(parked,pending);
            legacyWindow=OpenLegacy();
            Run(legacyWindow);
            var retried=legacyJournal.Load()!;
            check(retried.SucceededCount==3 && retried.Items.Single(item=>item.Input==low).Output==savedOutput &&
                retried.Items.Single(item=>item.Input==pending).Frozen?.Settings.HDR?.Mode==HDRMode.Sdr &&
                File.ReadAllText(previousOutput)=="completed output",
                "Legacy retry freezes the restored target in its saved SDR mode and preserves prior outputs: "+retried.Error);
        } finally {legacyWindow.Close();}

        var formatJob=Job(hdr); formatJob.Format=ExportFormat.HdrJpeg;
        var formatJournal=new BatchJournal(Path.Combine(root,"format-journal"));
        var broken=Path.Combine(root,"broken.jpg"); File.WriteAllText(broken,"not a photo");
        var missingLook=Copy("sdr-with-missing-look");
        store.Save(missingLook,sdr.Capture(),"builtin:missing-look.cube");
        var formatWindow=new BatchExportWindow(formatJob,formatJournal,_=>new RenderEngine(0),hdrPreparation:preparation);
        try {
            formatWindow.Show();
            var adding=formatWindow.AddInputs([low,high,broken,missingLook]);
            InteractionChecks.PumpUntil(()=>adding.IsCompleted); adding.GetAwaiter().GetResult();
            if (formatWindow.Job.Items.Count!=4)
                throw new InvalidOperationException("Format preflight did not retain all four inputs: "+formatWindow.Job.Error);
            BatchItem Item(string path)=>formatWindow.Job.Items.Single(item=>item.Input==path);
            check(!Item(low).CanSelect && Item(high).Selected && !Item(broken).CanSelect && !Item(missingLook).CanSelect,
                "HDR JPEG admits the HDR photo and rejects SDR, unreadable inputs and missing looks");
            var sdrId=Item(low).Id; var brokenError=Item(broken).ValidationError; var lookError=Item(missingLook).ValidationError;
            ((RadioButton)formatWindow.FindName("SdrJpeg")).IsChecked=true;
            InteractionChecks.PumpUntil(()=>!formatWindow.Busy);
            check(formatWindow.Job.Format==ExportFormat.SdrJpeg && Item(low).Id==sdrId && Item(low).CanSelect &&
                Item(high).Selected && Item(broken).ValidationError==brokenError && Item(missingLook).ValidationError==lookError,
                "Switching to SDR JPEG restores the same SDR row and preserves file and decode errors");
            var targets=(ListBox)formatWindow.FindName("Targets");
            var sdrRow=targets.Items.Cast<BatchRow>().Single(row=>row.Input==low);
            sdrRow.Selected=true;
            check(Item(low).Selected,"The restored SDR row can be checked in the batch list");
            ((RadioButton)formatWindow.FindName("HdrJpeg")).IsChecked=true;
            InteractionChecks.PumpUntil(()=>!formatWindow.Busy);
            check(!Item(low).CanSelect && Item(high).Selected && Item(broken).ValidationError==brokenError,
                "Switching back recomputes HDR compatibility and preserves the decode error");
            var oldDraft=formatWindow.Job.Copy();
            oldDraft.Items=oldDraft.Items.Select(item=>item with { HDRJpegIncompatible=null }).ToList();
            formatWindow.Close();
            formatJournal.Save(oldDraft);
            formatWindow=new BatchExportWindow(formatJournal.Load()!,formatJournal,_=>new RenderEngine(0),hdrPreparation:preparation);
            formatWindow.Show();
            ((RadioButton)formatWindow.FindName("SdrJpeg")).IsChecked=true;
            InteractionChecks.PumpUntil(()=>!formatWindow.Busy);
            check(Item(low).CanSelect && Item(broken).ValidationError==brokenError && Item(missingLook).ValidationError==lookError,
                "An older draft revalidates missing compatibility data when the format changes");
        } finally {formatWindow.Close();}

        var window=new BatchExportWindow(Job(hdr),journal,_=>new RenderEngine(0),hdrPreparation:preparation);
        try {
            window.Show();
            var adding=window.AddInputs([low,high]); InteractionChecks.PumpUntil(()=>adding.IsCompleted); adding.GetAwaiter().GetResult();
            check(window.Job.SelectedCount==2,"Unified ProRAW preflight accepts both saved target modes");
            var run=window.StartExecution(); InteractionChecks.PumpUntil(()=>run.IsCompleted); run.GetAwaiter().GetResult();
            var saved=journal.Load()!;
            check(saved.Mode==BatchJob.PerTargetFrozen && saved.SucceededCount==2,"Unified ProRAW exports both frozen targets: "+saved.Error);
            var lowSettings=saved.SnapshotFor(saved.Items.Single(item=>item.Input==low)).Settings.Restore();
            var highSettings=saved.SnapshotFor(saved.Items.Single(item=>item.Input==high)).Settings.Restore();
            check(!lowSettings.IsHDREditing && lowSettings[Parameter.Exposure]==.75 && lowSettings[Parameter.Temperature]==5200 &&
                lowSettings[Parameter.Tint]==9 && lowSettings.HDR==sdr.HDR,"Frozen SDR preserves mode, camera WB and dormant HDR settings");
            check(highSettings.IsHDREditing && highSettings[Parameter.Exposure]==.75,"Frozen HDR target keeps HDR mode");
            check(store.VersionedState(low).SameAs(sdrRecord) && store.VersionedState(high).SameAs(hdrRecord),"Batch leaves both edit records unchanged");
            store.Save(low,new Adjustments().Capture(),null);
            var resumed=journal.Load()!;
            check(resumed.SnapshotFor(resumed.Items.Single(item=>item.Input==low)).Settings.SameAs(lowSettings.Capture()),
                "Reloading the batch does not read later target edits");
            var collectionWindow=new BatchExportWindow(collection,collectionJournal,_=>new RenderEngine(0));
            try {
                collectionWindow.Show();
                var export=collectionWindow.StartExecution(); InteractionChecks.PumpUntil(()=>export.IsCompleted); export.GetAwaiter().GetResult();
                var published=collectionJournal.Load()!.Items.Single();
                check(published.Status==BatchStatus.Succeeded && published.Output!=null &&
                    PhotoInput.ProbeHDR(published.Output,out _)==HDRProbeState.Supported,
                    "Per-photo ProRAW collection publishes the HDR gain-map JPEG");
            } finally {collectionWindow.Close();}
        } finally {window.Close(); app.Shutdown();}
    }

    internal static void RunCameraRaw(string repo, string fixture, Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetFullPath(repo), "build", "camera-raw-hdr-workflow", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        var source = Path.Combine(root, Path.GetFileName(fixture));
        File.Copy(fixture, source);
        string SourceHash()
        {
            using var stream = File.OpenRead(source);
            return Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(stream));
        }
        var originalHash = SourceHash();
        Loc.Initialize("en");
        SessionCancellationAfterDisplayReset(root, source, check);
        var app = TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        MainWindow? window = null;
        void Open()
        {
            window = new MainWindow(Path.Combine(root, "looks"));
            TestWindowState.Isolate(window, root, editDirectory: Path.Combine(root, "edits"));
            window.Show();
            window.OpenFile(source);
            Ready(window);
        }
        Adjustments Settings() => Get<Adjustments>(window!, "settings");
        RenderedImage Frame() => Get<RenderedImage>(window!, "result");
        void Toggle(bool enabled)
        {
            check(window!.HDREditMenu.IsEnabled, "Camera RAW offers the HDR edit switch");
            window.HDREditMenu.IsChecked = enabled;
            window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            InteractionChecks.PumpUntil(() => window.ExportPng.IsEnabled && Settings().IsHDREditing == enabled &&
                (Frame().HDR != null) == enabled);
            check(window.HDREditMenu.IsChecked == enabled, "HDR menu matches the rendered edit mode");
        }
        void EditExposure(double value)
        {
            var tools = Get<Dictionary<EditorAdjustmentTool, (Button Button, AdjustmentRing Ring)>>(window!, "workspaceTools");
            tools[EditorAdjustmentTool.Exposure].Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window!.OrdinaryParameter.Number.Text = value.ToString(System.Globalization.CultureInfo.InvariantCulture);
            check(window.OrdinaryParameter.Commit(), "Exposure commits through the visible adjustment");
            Ready(window);
            check(Settings()[Parameter.Exposure] == value, "Active mode receives the exposure edit");
        }
        void Export(ExportFormat format, string output)
        {
            var task = window!.ExportPhoto(format, output);
            InteractionChecks.PumpUntil(() => task.IsCompleted);
            task.GetAwaiter().GetResult();
            check(File.Exists(output) && new FileInfo(output).Length > 100,
                $"Editor exports {format}: {window.Status.Text}");
        }
        try
        {
            Open();
            Capture(window!, Path.Combine(root, "camera-raw-sdr-editor.png"));
            check(!Settings().IsHDREditing && Frame().HDR == null, "Fresh camera RAW opens in SDR");
            EditExposure(.5);
            Toggle(true);
            if (System.Diagnostics.Process.GetCurrentProcess().SessionId == 0)
                check(!window!.ResultHDRSurface.Available, "HDR editing remains usable with the SDR canvas in Windows session 0");
            check(Settings()[Parameter.Exposure] == 0, "First HDR edit starts with independent exposure");
            EditExposure(1.25);
            Toggle(false);
            check(Settings()[Parameter.Exposure] == .5, "Switching to SDR restores the SDR exposure");
            Toggle(true);
            check(Settings()[Parameter.Exposure] == 1.25, "Switching back to HDR restores the HDR exposure");

            var closed = false;
            window!.Closed += (_, _) => closed = true;
            window.Close();
            InteractionChecks.PumpUntil(() => closed);
            Open();
            check(window.HDREditMenu.IsChecked && Settings().IsHDREditing && Frame().HDR != null &&
                Settings()[Parameter.Exposure] == 1.25, "Reopened editor restores the last mode and HDR exposure");
            Toggle(false);
            check(Settings()[Parameter.Exposure] == .5, "Reopened editor also restores the independent SDR exposure");
            Toggle(true);
            Capture(window!, Path.Combine(root, "camera-raw-hdr-editor.png"));

            var menu = window.ExportButton.ContextMenu!;
            menu.PlacementTarget = window.ExportButton;
            menu.IsOpen = true;
            InteractionChecks.PumpUntil(() => window.ExportHdrJpeg.IsVisible && window.ExportSdrJpeg.IsVisible);
            check(window.ExportHdrJpeg.IsEnabled && window.ExportSdrJpeg.IsEnabled,
                "Both JPEG exports are available in the HDR editor");
            menu.IsOpen = false;
            var frame = Frame();
            var hdr = Path.Combine(root, "hdr.jpg");
            var sdr = Path.Combine(root, "sdr.jpg");
            Export(ExportFormat.HdrJpeg, hdr);
            Ready(window);
            Export(ExportFormat.SdrJpeg, sdr);
            check(HDRNative.Probe(hdr, out var info) == HDRProbeState.Supported &&
                info!.Width == frame.NativeWidth && info.Height == frame.NativeHeight,
                "HDR JPEG contains a gain map and retains full rendered dimensions");
            check(HDRNative.Probe(sdr, out _) == HDRProbeState.NotHDR, "SDR JPEG has no HDR gain map");
            using (var stream = File.OpenRead(sdr))
            {
                var jpeg = new JpegBitmapDecoder(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
                check(jpeg.PixelWidth == frame.NativeWidth && jpeg.PixelHeight == frame.NativeHeight,
                    $"SDR JPEG decodes at full size ({jpeg.PixelWidth} × {jpeg.PixelHeight})");
            }
            check(SourceHash() == originalHash, "Camera RAW source remains byte-for-byte unchanged");
        }
        catch
        {
            Console.Error.WriteLine($"Camera RAW HDR editor status: {window?.Status.Text}");
            throw;
        }
        finally
        {
            window?.Close();
            app.Shutdown();
        }
    }

    private static void SessionCancellationAfterDisplayReset(string root, string source, Action<bool, string> check)
    {
        static void WriteRaster(string path, byte value)
        {
            var pixels = Enumerable.Repeat(new byte[] { value, (byte)(value + 7), (byte)(value + 13) }, 16 * 16)
                .SelectMany(pixel => pixel).ToArray();
            var bitmap = BitmapSource.Create(16, 16, 96, 96, PixelFormats.Rgb24, null, pixels, 16 * 3);
            var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var output = File.Create(path); encoder.Save(output);
        }

        var first = Path.Combine(root, "cancel-reset-first.png");
        var second = Path.Combine(root, "cancel-reset-second.png");
        WriteRaster(first, 32); WriteRaster(second, 64);
        using var engine = new RenderEngine(0);
        using var cancellation = new CancellationTokenSource();
        engine.SetCancellation(cancellation.Token);
        engine.Render(first, new(), null, 32, statistics: false, clipping: false);
        engine.Render(second, new(), null, 32, statistics: false, clipping: false);
        var settings = new Adjustments();
        settings.SetHDRMode(true, sourceIsHDR: true, cameraRaw: true, proRAW: true);
        cancellation.Cancel();
        var cancelled = false;
        try { engine.Render(source, settings, null, 32, statistics: false, clipping: false); }
        catch (OperationCanceledException) { cancelled = true; }
        check(cancelled, "Cancellation remains bound after raster session replacement before ProRAW HDR decode");
    }

    internal static void Run(string repo,string fixture,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(repo),"build","hdr-workflow",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        var source=Path.Combine(root,"phone"+Path.GetExtension(fixture));File.Copy(fixture,source);
        var hash=System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(source));
        Loc.Initialize("en");
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=new MainWindow(Path.Combine(root,"looks"));TestWindowState.Isolate(window,root);
        try {
            window.Show();window.OpenFile(source);Ready(window);
            var exportMenu=window.ExportButton.ContextMenu!;
            exportMenu.PlacementTarget=window.ExportButton;exportMenu.IsOpen=true;
            InteractionChecks.PumpUntil(()=>window.ExportSdrJpeg.IsVisible);
            check(Equals(window.ExportSdrJpeg.Header,"Save SDR JPEG") && ExportFormat.SdrJpeg.Title()=="Save SDR JPEG",
                "Visible SDR JPEG export action and file filter use the English catalog");
            Capture(exportMenu,Path.Combine(root,"sdr-export-menu.png"));exportMenu.IsOpen=false;
            var settings=Get<Adjustments>(window,"settings");
            check(settings.IsHDREditing,"Fresh HDR phone photo opens with HDR editing enabled");
            check(!window.AutoExposureButton.IsEnabled && !window.MenuAutoExposure.IsEnabled,"HDR editing disables the SDR-only automatic exposure action");
            window.MenuCompareSwipe.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check((bool)window.GetType().GetProperty("ReferenceCurrent",Private)!.GetValue(window)!,
                "HDR comparison publishes a current neutral reference");
            window.MenuCompareOff.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(window.CapturePresetAdjustments(AdjustmentScope.All).Source.HdrProcessingVersion==1,
                "Fresh import can capture HDR preset before the first edit");
            var scopeEditor=new AdjustmentScopeEditor("hdr-test",true);
            var fields=Get<Dictionary<AdjustmentField,CheckBox>>(scopeEditor,"fields");
            check(fields.ContainsKey(AdjustmentField.HdrTemperature) && fields.ContainsKey(AdjustmentField.HdrTint) &&
                !fields.ContainsKey(AdjustmentField.Temperature) && scopeEditor.SelectedScope.Fields!.SetEquals(AdjustmentFields.HDRCommon),
                "HDR scope offers relative WB and initializes only supported fields");
            var summaryDialog = new AdjustmentScopeDialog(window, source, _ => null, hdr:true,
                preview:window.PreviewAdjustmentPayload,lookName:window.AdjustmentSummaryLookName);
            summaryDialog.Show(); summaryDialog.UpdateLayout();
            T Summary<T>(string id) where T:DependencyObject => UiDetailChecks.Descendants(summaryDialog).OfType<T>()
                .Single(value=>AutomationProperties.GetAutomationId(value)==id);
            check(Summary<TextBlock>("adjustment.copy.summary.count").Text.Contains("7"),
                "Native HDR default summary contains seven shared adjustments");
            Summary<Expander>("adjustment.copy.summary.group.color").IsExpanded=true; summaryDialog.UpdateLayout();
            check(Summary<TextBlock>("adjustment.copy.summary.value.hdr.relative_temperature").Text.Contains(Loc.Text("相对白平衡")),
                "Native HDR temperature summary states relative white balance");
            Capture(summaryDialog,Path.Combine(root,"hdr-summary.png"));
            Summary<ComboBox>("adjustment.copy.scope").SelectedIndex=1; summaryDialog.UpdateLayout();
            check(Summary<TextBlock>("adjustment.copy.summary.count").Text.Contains("17"),
                "Native HDR all summary includes geometry and no unsupported fields");
            Summary<ComboBox>("adjustment.copy.scope").SelectedIndex=2; summaryDialog.UpdateLayout();
            check(!Summary<Button>("adjustment.copy.confirm").IsEnabled &&
                Summary<TextBlock>("adjustment.copy.summary.empty").Text==Loc.Text("尚无已修改的调整。"),
                "Native neutral HDR modified scope is empty and cannot be copied");
            summaryDialog.Close();
            var tools=Get<Dictionary<EditorAdjustmentTool,(Button Button,AdjustmentRing Ring)>>(window,"workspaceTools");
            foreach(var (tool,parameter,value) in new[] {
                (EditorAdjustmentTool.Exposure,Parameter.Exposure,.5),
                (EditorAdjustmentTool.Highlights,Parameter.Highlights,-20d),
                (EditorAdjustmentTool.Shadows,Parameter.Shadows,30d),
                (EditorAdjustmentTool.Contrast,Parameter.Contrast,25d),
                (EditorAdjustmentTool.Saturation,Parameter.Saturation,-10d)}) {
                var button=tools[tool].Button;check(button.IsEnabled,"HDR tool is enabled: "+tool);
                button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                window.OrdinaryParameter.Number.Text=value.ToString(System.Globalization.CultureInfo.InvariantCulture);
                check(window.OrdinaryParameter.Commit(),"HDR parameter commits through the visible editor: "+tool);Ready(window);
                check(Get<Adjustments>(window,"settings")[parameter]==value,"HDR record receives the edited value: "+tool);
            }
            tools[EditorAdjustmentTool.WhiteBalance].Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            foreach(var (field,value) in new[]{("temperature",7300d),("tint",12d)}) {
                var row=Get<ParameterRow>(window.WhiteBalanceEditor,field);
                check(row.IsEnabled,"HDR relative WB row is enabled: "+field);
                row.Number.Text=value.ToString(System.Globalization.CultureInfo.InvariantCulture);
                check(row.Commit(),"HDR relative WB commits: "+field);Ready(window);
            }
            var edited=Get<Adjustments>(window,"settings");
            check(edited.HDR!.Temperature==7300 && edited.HDR.Tint==12,"Both HDR relative WB values reach the active record");
            tools[EditorAdjustmentTool.Exposure].Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var rendered=Get<RenderedImage>(window,"result");
            check(rendered.HDR!=null && rendered.HDR.Statistics.Bins.Sum(x=>(long)x)==rendered.Image.PixelWidth*rendered.Image.PixelHeight,
                "HDR histogram counts floating-point luminance pixels");
            window.HDRFalseColorMenu.IsChecked=true;window.HDRFalseColorMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            InteractionChecks.PumpUntil(()=>Get<Dictionary<HDRFloatImage,BitmapSource>>(window,"hdrFalseColorCache").Count>0);
            Capture(window,Path.Combine(root,"hdr-false-color.png"));
            window.HDRFalseColorMenu.IsChecked=false;window.HDRFalseColorMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            window.HDREditMenu.IsChecked=false;window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(!Get<Adjustments>(window,"settings").IsHDREditing && Get<RenderedImage>(window,"result").HDR==null,
                "HDR toggle produces the ordinary SDR editing frame");
            check(window.AutoExposureButton.IsEnabled && window.MenuAutoExposure.IsEnabled,"SDR editing restores automatic exposure controls");
            var lut=Path.Combine(root,"unknown.cube");File.WriteAllText(lut,"LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n");
            var draft=LUTCompatibility.Inspect(lut)!;
            using var previewWorker=new LUTPreviewWorker(lut,source);
            var preview=previewWorker.Render(null);
            check(Math.Max(preview.Width,preview.Height)<=512 && preview.Pixels.Length>0,
                "HDR source in SDR editing provides a bounded LUT wizard baseline");
            var dialog=new LUTCompatibilityDialog(window,lut,draft,source,[]);dialog.Show();
            InteractionChecks.PumpUntil(()=>Get<Dictionary<string,(Button Button,Image Image)>>(dialog,"thumbnails").Values.Any(value=>value.Button.IsEnabled));
            var candidate=Get<Dictionary<string,(Button Button,Image Image)>>(dialog,"thumbnails").Values.First(value=>value.Button.IsEnabled);
            candidate.Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            check(Get<Button>(dialog,"confirm").IsEnabled,"LUT wizard displays candidates and accepts a compatible SDR configuration");
            dialog.UpdateLayout();
            Capture(dialog,Path.Combine(root,"sdr-lut-wizard.png"));dialog.Close();
            window.HDREditMenu.IsChecked=true;window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            check(Get<Adjustments>(window,"settings").IsHDREditing && Get<RenderedImage>(window,"result").HDR!=null,
                "Returning to HDR invalidates the SDR frame cache");
            Capture(window,Path.Combine(root,"hdr-editor.png"));

            CheckCollectionPreflight(root,source,check);
            HDRNative.Probe(source,out var sourceInfo);
            HDRSourceCache.Clear();
            using(var one=HDRSourceCache.Acquire(source,sourceInfo!,false,128))
            using(var two=HDRSourceCache.Acquire(source,sourceInfo!,false,64)) {
                check(ReferenceEquals(one.Owner,two.Owner) && HDRSourceCache.CachedBytes is >0 and <=128UL*1024*1024,
                    "Source cache shares one process budget across leases");
                HDRSourceCache.Clear();one.Dispose();
                check(HDRSourceCache.CachedBytes==0 && two.Owner.Pair.Hdr.Data!=IntPtr.Zero,
                    "Eviction preserves a concurrently active source lease");
            }
            using var engine=new RenderEngine(0);
            var neutral=new Adjustments { HDR=new HDRSettings() };
            var sdr=neutral.Clone();sdr.SetHDRMode(false,true);
            var first=engine.RenderPreview(source,sdr,null,128,false,true,false);
            var next=engine.RenderPreview(source,neutral,null,128,false,true,false);
            check(first.Result.HDR==null && next.Result.HDR!=null && next.Neutral.HDR!=null,"Result and neutral caches include HDR mode");
            var meter=engine.AutoExposure(source,sdr);check(double.IsFinite(meter),"SDR HDR-source auto exposure completes on bounded input");
            neutral.Geometry=new GeometrySettings { QuarterTurns=1,CropWidth=.75 };
            var geometry=engine.RenderPreview(source,neutral,null,128,false,false,false).Result;
            check(geometry.NativeWidth==geometry.HDR!.OutputNativeWidth && geometry.NativeHeight==geometry.HDR.OutputNativeHeight,
                "HDR geometry publishes the actual output dimensions to the viewport");
            foreach(var format in new[]{ExportFormat.HdrJpeg,ExportFormat.Jpeg,ExportFormat.Png,ExportFormat.RenderedDng}) {
                var output=Path.Combine(root,"export-"+format+"."+format.Suffix());
                engine.Render(source,neutral,null,128,output:output,longEdge:128,formatOverride:format);
                check(new FileInfo(output).Length>100,"Final output exists: "+format);
                if(format==ExportFormat.HdrJpeg)check(HDRNative.Probe(output,out var info)==HDRProbeState.Supported && Math.Max(info!.Width,info.Height)==Math.Min(128,Math.Max(geometry.NativeWidth,geometry.NativeHeight)),
                    "Final resized HDR JPEG retains its gain map and output dimensions");
                if(format==ExportFormat.Png)check(File.ReadAllBytes(output)[24]==16,"Explicit SDR PNG retains 16-bit channel depth");
            }
            var created=File.GetCreationTimeUtc(source);var modified=File.GetLastWriteTimeUtc(source);
            var originalBytes=File.ReadAllBytes(source);var invalidBytes=originalBytes.ToArray();invalidBytes[0]^=0xff;
            try {
                File.WriteAllBytes(source,invalidBytes);File.SetCreationTimeUtc(source,created);File.SetLastWriteTimeUtc(source,modified);
                var rejected=false;
                try {engine.RenderPreview(source,neutral,null,128,false,false,false);}catch(HDRSourceException){rejected=true;}
                check(rejected,"Fresh source fingerprint prevents a stale cached frame when file stamps are preserved");
            } finally {File.WriteAllBytes(source,originalBytes);File.SetCreationTimeUtc(source,created);File.SetLastWriteTimeUtc(source,modified);}
            check(hash.SequenceEqual(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(source))),"Original phone photo remains unchanged");
            Console.WriteLine("HDR screenshots and outputs: "+root);
        } finally {window.Close();app.Shutdown();}
    }
    private static void CheckCollectionPreflight(string root,string source,Action<bool,string> check)
    {
        var other=Path.Combine(root,"sdr-mode"+Path.GetExtension(source));File.Copy(source,other);
        var store=new EditStore(Path.Combine(root,"preflight-edits"));store.Save(other,new Adjustments().Capture(),null);
        var selection=new BatchSelectionSession();selection.Add([source,other]);
        var journal=new BatchJournal(Path.Combine(root,"preflight-journal"));
        var exporter=new BatchSelectionExport(store,journal,_=>null);
        var review=exporter.Prepare(selection,[],ExportFormat.HdrJpeg,128,root,_=>null);
        check(!review.Ready && review.Rows.Count==2 && review.Rows.Count(row=>row.Error!=null)==1,
            "Mixed HDR/SDR-mode collection rejects HDR JPEG during preflight");
        var rejected=false;try {exporter.Freeze(selection,review,_=>null);}catch(InvalidOperationException){rejected=true;}
        check(rejected && journal.Load()==null,"Rejected collection does not freeze or partially publish outputs");
    }
    private static void Capture(FrameworkElement element,string path)
    {
        element.UpdateLayout();
        var bitmap=new RenderTargetBitmap((int)Math.Ceiling(element.ActualWidth),(int)Math.Ceiling(element.ActualHeight),96,96,PixelFormats.Pbgra32);
        bitmap.Render(element);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file=File.Create(path);encoder.Save(file);
    }
}
