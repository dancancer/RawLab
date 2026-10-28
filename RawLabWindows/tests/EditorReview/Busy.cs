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
    private sealed partial class ReviewRun
    {
        void BusyOrder(bool foregroundFirst,bool export,bool resumePreview=false)
        {
            var name="busy-"+export+"-"+foregroundFirst+"-"+resumePreview;
            var window=Open(name);var destination=Path.Combine(output,name+".png");
            Set(window,"exportLongEdge",128);
            var held=new HeldContext(SynchronizationContext.Current!);
            using var releaseBatch=new ManualResetEventSlim();
            Task? foreground=null,preflight=null;
            try
            {
                var job=BatchJob.Create(photo,new Adjustments().Capture(),null,"Neutral");
                Invoke(window,"ShowBatch",job);
                var batch=Get<BatchExportWindow>(window,"batchWindow");
                check(batch.Owner==window,"Busy regression uses the real MainWindow batch owner wiring");
                var look=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_Velvia_65grid_V.1.00.cube");
                held.Capture(()=>foreground=export ? window.ExportPhoto(ExportFormat.Png,destination) : window.ImportLookFiles([look]));
                InteractionChecks.PumpUntil(()=>held.Pending);
                check(!foreground!.IsCompleted && (!export || !File.Exists(destination)),"Foreground completion is held before publication: "+name);
                preflight=batch.AddInputs(foregroundFirst ? BlockedInputs() : [photo]);
                if(foregroundFirst)
                {
                    held.Release();InteractionChecks.PumpUntil(()=>foreground!.IsCompleted);
                    check(!preflight.IsCompleted && batch.Busy,"Foreground completion leaves batch preflight active");
                }
                else
                {
                    InteractionChecks.PumpUntil(()=>preflight.IsCompleted);preflight.GetAwaiter().GetResult();
                    check(!foreground!.IsCompleted && !batch.Busy,"Batch completion leaves foreground work active: "+name);
                }
                // 预览指示器只表示显影；导入和批量任务仍须独立守住编辑与导出入口。
                check(!window.AdjustmentPanel.IsEnabled && !window.ExportPng.IsEnabled && !window.BatchExportMenu.IsEnabled,
                    "The remaining busy owner keeps editing and export gated: "+name);
                window.OpenFile(other);
                check(Get<string>(window,"file")==photo,"The remaining busy owner blocks photo switching: "+name);
                if(resumePreview)
                {
                    releaseBatch.Set();InteractionChecks.PumpUntil(()=>preflight.IsCompleted && window.ExportPng.IsEnabled);
                    var actual=Get<RenderedImage>(window,"result");
                    using var oracle=new RenderEngine(0);
                    var expected=oracle.Render(photo,Get<Adjustments>(window,"settings").Clone(),look,
                        Math.Max(actual.Image.PixelWidth,actual.Image.PixelHeight),clipping:false,viewportPreview:true)!;
                    check(Pixels(actual.Image).SequenceEqual(Pixels(expected.Image)),
                        "The last batch owner resumes the imported look preview before export is enabled");
                    return;
                }
                window.Close();
                check(window.IsVisible && Get<object?>(window,"engine")!=null && !Get<bool>(window,"closeFinished"),
                    "Close waits for the remaining busy owner without releasing the render engine: "+name);
                held.Release();releaseBatch.Set();
                InteractionChecks.PumpUntil(()=>foreground!.IsCompleted && preflight.IsCompleted && !window.IsVisible);
                foreground!.GetAwaiter().GetResult();preflight.GetAwaiter().GetResult();
                check(Get<bool>(window,"closeFinished"),"The final busy owner releases deferred close: "+name);
                if(export)check(File.Exists(destination) && File.ReadAllBytes(destination)[24]==16 && Get<string>(window,"lastExportedPath")==destination &&
                    !Directory.EnumerateFiles(output,".rawlab-*").Any(),"Deferred close publishes the actual sixteen-bit single export without staging files: "+name);
                else check(((Task<IReadOnlyList<string>>)foreground).Result.Count==0,"Foreground import completes without validation errors: "+name);
            }
            finally
            {
                held.Release();releaseBatch.Set();
                InteractionChecks.PumpUntil(()=>(foreground?.IsCompleted ?? true) && (preflight?.IsCompleted ?? true));
                window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);
            }
            IEnumerable<string> BlockedInputs(){releaseBatch.Wait();yield return photo;}
        }
    }
}
