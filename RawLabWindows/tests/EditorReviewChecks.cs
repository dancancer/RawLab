using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static partial class EditorReviewChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    internal enum Part { All, BusyBatchFirst, BusyForegroundFirst, BusyExportBatchFirst, BusyExportFirst, BusyResumePreview,
        CloseJournalRetry, CloseJournalSync, CloseIdleNoop, CloseThumbnailQueue, CloseRunning, ResizeImportFirst,
        ResizeBatchBeforeImport, ResizeExportFirst, ResizeBatchBeforeExport, LibraryDrop, DialogGeometry, DialogLens, UsageLifecycle, ClosePending, WorkspaceReset }
    internal static readonly IReadOnlyDictionary<string,Part> Parts=new Dictionary<string,Part>(StringComparer.OrdinalIgnoreCase){
        ["all"]=Part.All,["busy-batch-first"]=Part.BusyBatchFirst,["busy-foreground-first"]=Part.BusyForegroundFirst,
        ["busy-export-batch-first"]=Part.BusyExportBatchFirst,["busy-export-first"]=Part.BusyExportFirst,["busy-resume-preview"]=Part.BusyResumePreview,
        ["close-journal-retry"]=Part.CloseJournalRetry,["close-journal-sync"]=Part.CloseJournalSync,["close-idle-noop"]=Part.CloseIdleNoop,
        ["close-thumbnail-queue"]=Part.CloseThumbnailQueue,["close-running"]=Part.CloseRunning,["resize-import-first"]=Part.ResizeImportFirst,
        ["resize-batch-before-import"]=Part.ResizeBatchBeforeImport,["resize-export-first"]=Part.ResizeExportFirst,
        ["resize-batch-before-export"]=Part.ResizeBatchBeforeExport,["library-drop"]=Part.LibraryDrop,
        ["dialog-geometry"]=Part.DialogGeometry,["dialog-lens"]=Part.DialogLens,["usage-lifecycle"]=Part.UsageLifecycle,
        ["close-pending"]=Part.ClosePending,["workspace-reset"]=Part.WorkspaceReset};
    internal static Part ParsePart(string part)=>Parts.TryGetValue(part.Trim(),out var value) ? value :
        throw new ArgumentException("Unknown editor-review part: '"+part+"'. Available: "+string.Join(", ",Parts.Keys));
    internal static void Run(string repo,string raw,Action<bool,string> check,string part="all") =>
        new ReviewRun(repo,raw,check,part).Execute();

    private sealed partial class ReviewRun(string repo,string raw,Action<bool,string> check,string part)
    {
        private string output=null!,photo=null!,other=null!;
        private Application app=null!;

        internal void Execute()
        {
            var selected=ParsePart(part);
            repo=Path.GetFullPath(repo);raw=Path.GetFullPath(raw);
            if(File.Exists(Path.Combine(BatchJournal.DefaultDirectory,"job.json")))throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
            var originalHash=SHA256.HashData(File.ReadAllBytes(raw));
            output=Path.Combine(repo,"build","windows-editor-review",DateTime.Now.ToString("yyyyMMdd-HHmmss"));
            Directory.CreateDirectory(output);
            var inputs=Path.Combine(output,"inputs");Directory.CreateDirectory(inputs);
            photo=Path.Combine(inputs,"photo"+Path.GetExtension(raw));File.Copy(raw,photo);
            other=Path.Combine(inputs,"other"+Path.GetExtension(raw));File.Copy(raw,other);
            app=TestWindowState.CreateApplication();
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
            try
            {
                var executed=0;
                void RunPart(Part candidate,Action action){if(selected==Part.All || selected==candidate){action();executed++;}}
                RunPart(Part.BusyBatchFirst,()=>BusyOrder(false,false));RunPart(Part.BusyForegroundFirst,()=>BusyOrder(true,false));
                RunPart(Part.BusyExportBatchFirst,()=>BusyOrder(false,true));RunPart(Part.BusyExportFirst,()=>BusyOrder(true,true));
                RunPart(Part.BusyResumePreview,()=>BusyOrder(true,false,true));RunPart(Part.CloseJournalRetry,CloseJournalRetry);
                RunPart(Part.CloseJournalSync,()=>{CloseIdleJournalRetry(false);CloseIdleJournalRetry(true);});
                RunPart(Part.CloseIdleNoop,CloseIdleNoop);RunPart(Part.CloseThumbnailQueue,()=>{CloseThumbnailQueue(false);CloseThumbnailQueue(true);CloseSourceThumbnail();});
                RunPart(Part.CloseRunning,CloseRunning);RunPart(Part.ResizeImportFirst,()=>ResizeOrder(true,false));
                RunPart(Part.ResizeBatchBeforeImport,()=>ResizeOrder(false,false));RunPart(Part.ResizeExportFirst,()=>ResizeOrder(true,true));
                RunPart(Part.ResizeBatchBeforeExport,()=>ResizeOrder(false,true));RunPart(Part.LibraryDrop,LibraryDrop);
                RunPart(Part.DialogGeometry,()=>DraftDialog(false));RunPart(Part.DialogLens,()=>DraftDialog(true));
                RunPart(Part.UsageLifecycle,()=>UsageIntegrationChecks.Run(Path.Combine(output,"usage-lifecycle"),photo,check));
                RunPart(Part.ClosePending,ClosePending);RunPart(Part.WorkspaceReset,WorkspaceReset);
                check(executed==(selected==Part.All ? Parts.Count-1 : 1),"Every selected editor scenario actually executes");
                check(new[]{raw,photo,other}.All(path=>originalHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(path)))),
                    "Editor review regressions preserve the external RAW and both source copies");
            }
            finally{app.Shutdown();}
        }

        MainWindow Open(string name)
        {
            var window=new MainWindow();
            TestWindowState.Isolate(window,Path.Combine(output,name));
            Set(window,"editStore",new EditStore(Path.Combine(output,name,"edits")));
            Set(window,"batchJournal",new BatchJournal(Path.Combine(output,name,"batch")));
            window.GpuMode.SelectedIndex=1;window.Show();
            InteractionChecks.PumpUntil(()=>window.IsLoaded);window.OpenFile(photo);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(app.Windows.Count==1,"Manual editor fixture creates exactly one private main window: "+name);return window;
        }
    }
}
