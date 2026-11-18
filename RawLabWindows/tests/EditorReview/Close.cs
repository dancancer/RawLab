using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static partial class EditorReviewChecks
{
    private sealed partial class ReviewRun
    {
        void ClosePending()
        {
            foreach(var scenario in new[]{0,1,2,3})
            {
                bool? batchFirst=scenario==0 ? null : scenario==1;
                var recover=scenario==3;
                var window=Open("close-pending-"+batchFirst+"-"+recover);var held=new HeldContext(SynchronizationContext.Current!);
                Task? preflight=null;
                FileStream? journalLock=null;
                using var releaseBatch=new ManualResetEventSlim();
                try
                {
                    BatchExportWindow? batch=null;
                    if(batchFirst!=null)
                    {
                        var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
                        window.BatchJournalInstance.Save(job);window.ShowBatchForTests(job,false);batch=window.BatchWindowInstance;
                    }
                    held.Capture(()=>{window.ValueSlider.Value=.6;window.ValueSlider.Value=.65;});
                    InteractionChecks.PumpUntil(()=>held.Pending);
                    var queued=window.SchedulerPending;
                    check(queued!=null && window.SchedulerHasActive,
                        "Close fixture has a real active render and a distinct queued preview: "+batchFirst);
                    if(batch!=null)preflight=batch.AddInputs(BlockedInputs());
                    if(recover)
                    {
                        check(!window.PreviewDeferred && window.PreviewLongEdge==window.RequestedPreviewLongEdge,
                            "Queued-close recovery has no resize or deferred-content fallback to hide a stranded pending request");
                        journalLock=new FileStream(Path.Combine(window.BatchJournalInstance.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read);
                    }
                    var revision=window.SchedulerRevision;
                    CloseApproved(window);
                    check(window.IsVisible && !window.IsEnabled && !window.CloseFinished,
                        "Close waits for the active worker even with another preview queued: "+batchFirst);
                    if(batchFirst==true){releaseBatch.Set();InteractionChecks.PumpUntil(()=>preflight!.IsCompleted);}
                    held.Release();
                    InteractionChecks.PumpUntil(()=>!window.SchedulerHasActive);
                    if(batchFirst==false){releaseBatch.Set();InteractionChecks.PumpUntil(()=>preflight!.IsCompleted);}
                    if(recover)
                    {
                        check(window.IsVisible && window.IsEnabled && !window.ClosingFlag && batch!.CloseFailed,
                            "Journal cleanup failure restores the owner after its active render already retired");
                        check((!window.SchedulerBusy || window.SchedulerHasActive) &&
                            revision==window.SchedulerRevision,
                            "Failed close resumes the existing queued preview without a new revision or stranded busy state");
                        journalLock!.Dispose();journalLock=null;
                        InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                        var actual=window.CurrentResult!;using var oracle=new RenderEngine(0,appPaths:window.Paths);
                        var expected=oracle.Render(photo,window.Settings.Clone(),window.CurrentLut,
                            Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight),clipping:false,viewportPreview:true)!;
                        check(Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),"Recovered queued preview matches the accepted settings and independent CPU pixels");
                        window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                        continue;
                    }
                    check(!window.IsVisible && window.CloseFinished && window.EngineInstance==null &&
                        ReferenceEquals(queued,window.SchedulerPending) &&
                        revision==window.SchedulerRevision,
                        "Last busy owner closes without starting the queued preview: "+batchFirst);
                }
                finally
                {
                    journalLock?.Dispose();held.Release();releaseBatch.Set();InteractionChecks.PumpUntil(()=>preflight?.IsCompleted ?? true);
                    if(window.IsVisible){window.FinishCloseForTests();window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
                }
                IEnumerable<string> BlockedInputs(){releaseBatch.Wait();yield return photo;}
            }
        }
        void CloseJournalRetry()
        {
            var window=Open("close-journal-retry");var held=new HeldContext(SynchronizationContext.Current!);
            var folder=new LibraryEntry(Path.GetDirectoryName(photo)!,true);
            window.LibraryInstance.Roots.Add(folder);
            if (!window.LibraryPanel.IsVisible) PhotoFeatureChecks.Click(window.LibraryToggleButton);
            InteractionChecks.PumpUntil(()=>window.FolderPhotoCount.Text.Length>0);
            check(folder.Photos.Count==2 && folder.Photos.All(entry=>entry.Path==photo || entry.Path==other),
                "Close recovery library excludes earlier exported images and contains only its two source photos");
            var visible=folder.Photos.First(entry=>entry.Path==photo);
            InteractionChecks.PumpUntil(()=>visible.Thumbnail!=null);
            check(window.VisibleThumbnails.Contains(visible),"Close recovery starts with an actually visible loaded library thumbnail");
            var journal=window.BatchJournalInstance;var engine=window.EngineInstance;
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");journal.Save(job);
            using var releasePreflight=new ManualResetEventSlim();
            Task? preflight=null;var recovered=false;var reported=false;
            try
            {
                window.ShowBatchForTests(job,false);var batch=window.BatchWindowInstance!;
                batch.BusyChanged+=active=>{
                    if(active || !batch.CloseFailed)return;
                    recovered=window.IsVisible && window.IsEnabled && !window.ClosingFlag &&
                        !window.CloseFinished && ReferenceEquals(engine,window.EngineInstance);
                    reported=batch.Job.Error!=null && window.Status.Text==batch.Job.Error;
                };
                held.Capture(()=>preflight=batch.AddInputs(BlockedInputs()));releasePreflight.Set();InteractionChecks.PumpUntil(()=>held.Pending);
                var previousEdge=window.PreviewLongEdge;window.ResultCanvas.Viewport!.Magnify(.5);var edge=window.ResultCanvas.PreviewLongEdge;
                check(edge>0 && edge!=previousEdge && window.RequestedPreviewLongEdge==edge && !window.ExportPng.IsEnabled,
                    "Journal retry fixture retains a genuinely changed viewport request while preflight is busy");
                using(var locked=new FileStream(Path.Combine(journal.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read))
                {
                    window.Close();
                    // The update guard dispatches the actual close request to the batch window.
                    InteractionChecks.PumpUntil(() => batch.CloseRequested || !window.IsVisible);
                    window.Dispatcher.Invoke(() => { }, DispatcherPriority.Normal);
                    var ownerClosing = window.ClosingFlag;
                    var shutdownStarted = window.AnalyticsDisposed;
                    check(window.IsVisible && !window.IsEnabled && ownerClosing && !shutdownStarted &&
                        batch.IsVisible && batch.Busy && !preflight!.IsCompleted &&
                        ReferenceEquals(engine, window.EngineInstance),
                        $"Owner waits for preflight before attempting journal cleanup (visible={window.IsVisible}, " +
                        $"closing={ownerClosing}, shutdownStarted={shutdownStarted}, batchBusy={batch.Busy})");
                    check(visible.Thumbnail==null,"Deferred owner close releases the visible library thumbnail");
                    held.Release();InteractionChecks.PumpUntil(()=>preflight!.IsCompleted);preflight!.GetAwaiter().GetResult();
                    check(batch.IsVisible && batch.CloseFailed && !batch.Discarded && recovered,"Journal cleanup failure restores the real owner without disposing its engine");
                    check(reported,"Journal cleanup failure reaches the restored main-window error state");
                    InteractionChecks.PumpUntil(()=>visible.Thumbnail!=null);
                    check(window.VisibleThumbnails.Contains(visible),"Failed close reloads visible library thumbnails without scroll or resize");
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                    check(window.AdjustmentPanel.IsEnabled && !window.ClosingFlag,"Failed owner close resumes an exact preview and editing");
                    var actual=window.CurrentResult!;using var oracle=new RenderEngine(0,appPaths:window.Paths);
                    var expected=oracle.Render(photo,window.Settings.Clone(),window.CurrentLut,edge,clipping:false,viewportPreview:true)!;
                    check(Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight)==edge && Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),
                        "Failed owner close restores the deferred viewport size and exact preview pixels");
                    var before=window.Settings[Parameter.Exposure];window.ValueSlider.Value+=.025;
                    check(window.Settings[Parameter.Exposure]>before,"Restored owner accepts an actual adjustment after cleanup failure");
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                }
                window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                check(window.CurrentFile==other,"Restored owner permits photo switching after cleanup failure");
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                check(batch.Discarded && journal.Load()==null && window.CloseFinished && window.EngineInstance==null,
                    "Retry closes the recovered owner and discards the journal after its lock is released");
            }
            finally
            {
                releasePreflight.Set();held.Release();InteractionChecks.PumpUntil(()=>preflight?.IsCompleted ?? true);
                if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
            }
            IEnumerable<string> BlockedInputs(){releasePreflight.Wait();yield return photo;}
        }
        void CloseIdleJournalRetry(bool foreground)
        {
            var window=Open("close-idle-"+foreground);var journal=window.BatchJournalInstance;
            var engine=window.EngineInstance;var held=new HeldContext(SynchronizationContext.Current!);Task? import=null;
            var adjustment=window.Settings;adjustment.Denoise=DenoiseSettings.Clean;window.ScheduleForTests(false,false);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var job=BatchJob.Create(photo,adjustment.Capture(),null,"Neutral");journal.Save(job);window.ShowBatchForTests(job,false);
            var batch=window.BatchWindowInstance!;var previous=window.PreviewLongEdge;
            var look=window.CurrentLut;var timer=window.PreviewResizeTimer;
            try
            {
                using(var locked=new FileStream(Path.Combine(journal.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read))
                {
                    window.ResultCanvas.Viewport!.Magnify(.5);var edge=window.ResultCanvas.PreviewLongEdge;
                    check(timer.IsEnabled && edge!=previous && !window.ExportPng.IsEnabled,"Idle-close fixture has a real pending denoise resize: "+foreground);
                    if(foreground){look=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_Velvia_65grid_V.1.00.cube");held.Capture(()=>import=window.ImportLookFiles([look]));}
                    CloseApproved(window);
                    check(window.IsVisible && window.IsEnabled && !window.ClosingFlag && !window.CloseFinished &&
                        batch.IsVisible && batch.CloseFailed && !batch.Busy && !batch.Discarded && ReferenceEquals(engine,window.EngineInstance),
                        "Synchronous journal failure cancels owner close without disposing its engine: "+foreground);
                    var rendering=window.SchedulerBusy;
                    if(foreground)check(!timer.IsEnabled && !rendering && window.RequestedPreviewLongEdge==edge,
                        "Synchronous close failure retains the pending size without rendering during foreground work");
                    else check(timer.IsEnabled || rendering,"Synchronous close failure resubmits the pending resize without another input");
                    check(window.Status.Text==batch.Job.Error,"Synchronous journal failure reaches the main-window error state: "+foreground);
                    if(foreground)
                    {
                        check(!window.AdjustmentPanel.IsEnabled && !window.ExportPng.IsEnabled && window.BusyIndicator.Visibility==Visibility.Collapsed,
                            "Cancelled owner close retains the foreground gate without claiming an active preview");
                        held.Release();InteractionChecks.PumpUntil(()=>import!.IsCompleted);import!.GetAwaiter().GetResult();
                    }
                    InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                    var actual=window.CurrentResult!;using var oracle=new RenderEngine(0,appPaths:window.Paths);
                    var expected=oracle.Render(photo,adjustment.Clone(),look,edge,clipping:false,viewportPreview:true)!;
                    check(window.PreviewLongEdge==edge && !timer.IsEnabled && Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight)==edge &&
                        Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),"Synchronous close failure resumes exact resized pixels: "+foreground);
                    check(window.AdjustmentPanel.IsEnabled && window.BusyIndicator.Visibility==Visibility.Collapsed && !batch.Job.Started,
                        "Synchronous close failure restores editing and clears stale busy state: "+foreground);
                }
                window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
                check(window.CurrentFile==other,"Synchronous close recovery permits photo switching: "+foreground);
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                check(batch.Discarded && journal.Load()==null && window.CloseFinished && window.EngineInstance==null,
                    "Synchronous close retries successfully after releasing the journal: "+foreground);
            }
            finally
            {
                held.Release();InteractionChecks.PumpUntil(()=>import?.IsCompleted ?? true);
                if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
            }
        }
        void CloseRunning()
        {
            var window=Open("close-running");var held=new HeldContext(SynchronizationContext.Current!);
            var journal=window.BatchJournalInstance;var engine=window.EngineInstance;
            var destination=Path.Combine(output,"running-output");Directory.CreateDirectory(destination);
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
            job.Format=ExportFormat.Png;job.LongEdge=128;job.OutputDirectory=destination;
            job.Items=[BatchItem.Create(photo) with{Selected=true},BatchItem.Create(other) with{Selected=true}];journal.Save(job);
            window.ShowBatchForTests(job,false);var batch=window.BatchWindowInstance!;
            using var progress=new BatchProgressGate(window.Dispatcher);
            try
            {
                held.Capture(()=>Click(batch.PrimaryAction));InteractionChecks.PumpUntil(()=>progress.Entered);
                var running=AtomicJson.Read<BatchJob>(Path.Combine(journal.DirectoryPath,"job.json"));
                check(batch.Running && running.Items[0].Status==BatchStatus.Running && running.Items[1].Status==BatchStatus.Waiting,
                    "Running-close fixture pauses the real worker after its first journaled item starts");
                CloseApproved(window);
                check(window.IsVisible && !window.IsEnabled && window.ClosingFlag && !window.CloseFinished &&
                    ReferenceEquals(engine,window.EngineInstance),"Owner close waits for the running batch and retains the render engine");
                check(batch.Cancellation.IsCancellationRequested,"Owner close requests stop-after-current-item on the real batch");
                progress.Release();InteractionChecks.PumpUntil(()=>held.Pending);
                var completed=journal.Load()!;var first=completed.Items[0].Output;
                check(completed.Cancelled && completed.SucceededCount==1 && completed.Items[1].Status==BatchStatus.Waiting &&
                    Directory.GetFiles(destination,"*.png").Length==1 && first!=null && File.ReadAllBytes(first)[24]==16,
                    "Running close publishes the current native PNG and leaves the next item unprocessed");
                check(window.IsVisible && batch.Running && ReferenceEquals(engine,window.EngineInstance),
                    "Owner remains alive until the batch completion callback is released");
                held.Release();InteractionChecks.PumpUntil(()=>!window.IsVisible);
                var saved=journal.Load()!;
                check(saved.Started && saved.Cancelled && saved.SucceededCount==1 && saved.RemainingCount==1 &&
                    saved.Items[0].Output==first && File.Exists(first) && !Directory.GetFiles(destination,".rawlab-*").Any(),
                    "Deferred running close preserves the completed output and recoverable journal without staging files");
                check(window.CloseFinished && window.EngineInstance==null && !batch.IsVisible,
                    "Running batch completion finishes owner close and releases the engine exactly at the end");
            }
            finally
            {
                progress.Release();held.Release();InteractionChecks.PumpUntil(()=>!batch.Running);
                if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
            }
        }
        void CloseIdleNoop()
        {
            var window=Open("close-idle-noop");var journal=window.BatchJournalInstance;
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");journal.Save(job);window.ShowBatchForTests(job,false);
            var batch=window.BatchWindowInstance!;
            long Revision()=>window.SchedulerRevision;
            var revision=Revision();var previous=window.CurrentResult!;
            try
            {
                check(!window.PreviewResizeTimer.IsEnabled && window.PreviewLongEdge==window.RequestedPreviewLongEdge,"No-op close fixture has no pending viewport resize");
                using(var locked=new FileStream(Path.Combine(journal.DirectoryPath,"job.json"),FileMode.Open,FileAccess.Read,FileShare.Read))
                {
                    for(var attempt=0;attempt<3;attempt++)
                    {
                        CloseApproved(window);
                        check(batch.CloseFailed && window.IsVisible && window.IsEnabled && !window.ClosingFlag,"Repeated idle close failure restores the owner");
                        check(Revision()==revision && ReferenceEquals(previous,window.CurrentResult) && window.ExportPng.IsEnabled,
                            "Idle close failure with an exact unchanged frame submits no render: "+attempt);
                    }
                }
            }
            finally{window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
        }
        void CloseThumbnailQueue(bool initial)
        {
            var window=Open("thumbnail-queue-"+initial);var journal=window.BatchJournalInstance;
            var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
            if(initial)job.Items=[BatchItem.Create(photo),BatchItem.Create(other)];journal.Save(job);
            var step=new SteppedContext(SynchronizationContext.Current!);Task? preflight=null;BatchExportWindow? batch=null;
            try
            {
                if(initial)
                {
                    step.Capture(()=>window.ShowBatchForTests(job,false));batch=window.BatchWindowInstance!;
                    // Loaded is delivered by WPF; explicitly step its real async body under the held context.
                    InteractionChecks.PumpUntil(()=>batch.SourceThumbnail.Source!=null);
                    InteractionChecks.PumpUntil(()=>batch.Rows.All(row=>row.Thumbnail!=null));
                    foreach(var row in batch.Rows)row.SetThumbnail(null);
                    step.Capture(()=>preflight=batch.LoadThumbnails());
                }
                else
                {
                    window.ShowBatchForTests(job,false);batch=window.BatchWindowInstance!;
                    InteractionChecks.PumpUntil(()=>batch.SourceThumbnail.Source!=null);
                    step.Capture(()=>preflight=batch.AddInputs([photo,other]));
                    step.Next();
                }
                InteractionChecks.PumpUntil(()=>step.Pending);
                var posts=step.Posts;var rows=batch!.Rows.ToArray();
                check(rows.Length==2,"Thumbnail cancellation fixture has two real RAW rows: "+initial);
                var clock=Stopwatch.StartNew();if(initial)Click(batch!.CloseAction);else window.Close();step.Release();
                InteractionChecks.PumpUntil(()=>preflight!.IsCompleted && (initial ? !batch!.IsVisible : !window.IsVisible));preflight!.GetAwaiter().GetResult();
                check(rows.All(row=>row.Thumbnail==null),"Closing never publishes an in-flight or queued row thumbnail: "+initial);
                check(step.Posts==posts,"Closing starts no later native thumbnail work: "+initial);
                Console.WriteLine($"thumbnail-close initial={initial}; elapsed-ms={clock.Elapsed.TotalMilliseconds:F2}; posts-after-close={step.Posts-posts}");
            }
            finally{step.Release();if(window.IsVisible){window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}}
        }
        void CloseSourceThumbnail()
        {
            var window=Open("source-thumbnail-close");var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
            window.ShowBatchForTests(job,false);var batch=window.BatchWindowInstance!;
            var step=new SteppedContext(SynchronizationContext.Current!);
            try
            {
                InteractionChecks.PumpUntil(()=>batch.SourceThumbnail.Source!=null);batch.SourceThumbnail.Source=null;
                step.Capture(()=>batch.RaiseEvent(new RoutedEventArgs(FrameworkElement.LoadedEvent)));
                InteractionChecks.PumpUntil(()=>step.Pending);Click(batch.CloseAction);step.Next();
                check(!batch.IsVisible && batch.SourceThumbnail.Source==null,"The real Loaded handler never publishes its late source thumbnail after closing");
            }
            finally{step.Release();window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);}
        }
    }
}
