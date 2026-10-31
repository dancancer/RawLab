using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class HDRReviewChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(object owner,string field)=>(T)owner.GetType().GetField(field,Private)!.GetValue(owner)!;
    private static object? Call(object owner,string method,params object?[] args)=>owner.GetType().GetMethods(Private)
        .Single(value=>value.Name==method && value.GetParameters().Length==args.Length).Invoke(owner,args);
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled &&
        !Get<DispatcherTimer>(window,"previewResize").IsEnabled && !Get<bool>(window,"editDirty"));

    internal static void StatisticsFlags(string source,Action<bool,string> check)
    {
        var calls=0;
        int Analyze(ref Native.Buffer buffer,bool clipping,uint[] bins,out uint shadows,out uint highlights,out Native.Buffer mask) {
            calls++;return RenderEngine.AnalyzeStatistics(ref buffer,clipping,bins,out shadows,out highlights,out mask);
        }
        using var engine=new RenderEngine(0,statisticsAnalyzer:Analyze);
        foreach(var hdr in new[]{true,false}) {
            var settings=new Adjustments {HDR=new HDRSettings {Mode=hdr ? HDRMode.Hdr : HDRMode.Sdr}};
            var before=calls;
            var skipped=engine.Render(source,settings,null,128,statistics:false,clipping:false)!;
            check(skipped.Histogram.Length==0 && skipped.Clipping==null && skipped.Shadows==0 && skipped.Highlights==0 && calls==before,
                "HDR-source preflight skips optional statistics and masks in mode "+hdr);
            var analyzed=engine.Render(source,settings,null,128,statistics:true,clipping:false)!;
            check(analyzed.Histogram.Length==768 && Pixels(skipped.Image,PixelFormats.Bgra32).SequenceEqual(Pixels(analyzed.Image,PixelFormats.Bgra32)),
                "Statistics flags preserve rendered pixels and normal histogram behavior");
        }
    }

    internal static void Run(string repo,string fixture,Action<bool,string> check)
    {
        var root=Path.Combine(Path.GetFullPath(repo),"build","hdr-review",Guid.NewGuid().ToString("N"));Directory.CreateDirectory(root);
        var source=Path.Combine(root,"phone"+Path.GetExtension(fixture));File.Copy(fixture,source);
        Loc.Initialize("en");var app=TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=new MainWindow(Path.Combine(root,"looks"));TestWindowState.Isolate(window,root);
        var failures=new List<string>();
        try {
            window.Show();window.OpenFile(source);Ready(window);
            RunCase("optional statistics",()=>StatisticsFlags(source,check));
            RunCase("frozen SDR batch",()=>FrozenSDRBatch(window,repo,root,source,check));
            RunCase("SDR HSL picker",()=>HslPicker(window,root,source,check));
            RunCase("HDR and SDR clipping overlays",()=>Clipping(window,root,check));
            Console.WriteLine("HDR review outputs: "+root);
            if(failures.Count>0)throw new Exception(string.Join("; ",failures));
        } finally {window.Close();app.Shutdown();}
        void RunCase(string name,Action action) {
            try {action();} catch(Exception error) {failures.Add(name+": "+error.GetBaseException().Message);Console.WriteLine("REGRESSION FAILED "+failures[^1]);}
        }
    }

    private static void FrozenSDRBatch(MainWindow owner,string repo,string root,string source,Action<bool,string> check)
    {
        var ordinary=Path.Combine(root,"ordinary.jpg");
        var pixels=Enumerable.Repeat(new byte[]{180,80,30},48*32).SelectMany(value=>value).ToArray();
        var encoder=new JpegBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(BitmapSource.Create(48,32,96,96,PixelFormats.Rgb24,null,pixels,48*3)));
        using(var stream=File.Create(ordinary))encoder.Save(stream);
        var raw=Path.Combine(repo,"lutools","tests","fixtures","linear-uncompressed.dng");
        var sdr=new Adjustments {HDR=new HDRSettings {Mode=HDRMode.Sdr}};sdr.Set(Parameter.Exposure,.5);
        var reset=EditorAdjustmentRules.PrepareReset(new(EditorResetKind.All),new(OriginalIdentity.Read(source),sdr.Capture(),null));
        check(reset.Status==EditorResetStatus.Ready && reset.Candidate!.Settings.HDR==null,"SDR reset produces the legacy-compatible snapshot without an HDR field");
        foreach(var snapshot in new[]{reset.Candidate!.Settings,new Adjustments().Capture(),sdr.Capture()}) {
            var job=BatchJob.Create(source,snapshot,null,"Neutral");
            foreach(var target in new[]{source,ordinary,raw}) {
                var frozen=job.SnapshotFor(BatchItem.Create(target)).Settings;
                check(frozen.HDR==snapshot.HDR && !frozen.Restore().IsHDREditing,"Uniform batch preserves frozen SDR mode for "+Path.GetExtension(target));
            }
            check(job.Settings.SameAs(snapshot),"Preparing targets leaves the source snapshot unchanged");
        }
        var export=BatchJob.Create(source,reset.Candidate.Settings,null,"Neutral");export.LongEdge=128;
        export.OutputDirectory=Path.Combine(root,"batch-outputs");Directory.CreateDirectory(export.OutputDirectory);
        var journal=new BatchJournal(Path.Combine(root,"batch-journal"));
        var dialog=new BatchExportWindow(export,journal){Owner=owner};dialog.Show();
        try {
            var prepare=dialog.AddInputs([source,ordinary,raw]);InteractionChecks.PumpUntil(()=>prepare.IsCompleted);prepare.GetAwaiter().GetResult();
            check(export.Items.Count==3 && export.Items.All(item=>item.CanSelect),"Actual batch preflight accepts HDR, ordinary JPEG and RAW targets in frozen SDR mode");
        } finally {dialog.Close();}
        using var engine=new RenderEngine(0);
        BatchRunner.Run(export,journal,false,CancellationToken.None,(_,_)=>{},(input,settings,look,destination,edge)=>
            engine.Render(input,settings,look,128,output:destination,longEdge:edge,formatOverride:ExportFormat.Jpeg));
        check(export.SucceededCount==3 && export.FailedCount==0,"Frozen SDR batch publishes JPEG output for all three source types");
    }

    private static void HslPicker(MainWindow window,string root,string source,Action<bool,string> check)
    {
        if(Get<Adjustments>(window,"settings").IsHDREditing) {
            window.HDREditMenu.IsChecked=false;window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
        }
        using var engine=new RenderEngine(0);
        var settings=Get<Adjustments>(window,"settings").Clone();
        var revision=new HslTargetRevision(17,29);Point? usable=null;
        foreach(var point in new[]{new Point(.25,.25),new Point(.5,.5),new Point(.75,.75),new Point(.25,.75),new Point(.75,.25)}) {
            var sample=engine.SampleHsl(source,settings,null,128,false,revision,point.X,point.Y);
            check(sample.Revision==revision && sample.Preview && sample.Rgb.Count==3 && sample.Rgb.All(double.IsFinite) &&
                sample.Availability is HslTargetAvailability.Available or HslTargetAvailability.NearGray,"HDR source HSL sampling uses a bounded SDR input with valid revisions");
            if(sample.Usable){usable=point;break;}
        }
        check(engine.CachedDisplayBytes==0,"HSL HDR-source analysis does not fill the ordinary full-size decoder cache");
        window.HslCategory.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Call(window,"SetHslTargetMode",true,0);
        Ready(window);
        check(window.HslEditor.IsEnabled && window.ResultCanvas.HslTargetEnabled,"SDR mode exposes the actual HSL picker on an HDR source");
        Call(window,"BeginHslTarget",usable ?? new Point(.5,.5),20d);
        InteractionChecks.PumpUntil(()=>!Get<HslTargetInteraction>(window,"hslTarget").Waiting && window.ExportPng.IsEnabled);
        var selection=Get<HslTargetInteraction>(window,"hslTarget").Selection;
        check(selection!=null && selection.Availability!=HslTargetAvailability.Failed &&
            (usable==null || !Get<Adjustments>(window,"settings").Hsl.IsIdentity),"Visible HSL picker accepts the SDR rendition and commits a usable target");
        Capture(window,Path.Combine(root,"sdr-hsl-picker.png"));Call(window,"SetHslTargetMode",false,0);Ready(window);
    }

    private static void Clipping(MainWindow window,string root,Action<bool,string> check)
    {
        foreach(var hdr in new[]{true,false}) {
            if(Get<Adjustments>(window,"settings").IsHDREditing!=hdr) {
                window.HDREditMenu.IsChecked=hdr;window.HDREditMenu.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));Ready(window);
            }
            Get<Dictionary<EditorAdjustmentTool,(Button Button,AdjustmentRing Ring)>>(window,"workspaceTools")[EditorAdjustmentTool.Exposure].Button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.OrdinaryParameter.Number.Text="4";check(window.OrdinaryParameter.Commit(),"Exposure commits before clipping check");Ready(window);
            window.ClippingButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready(window);
            var frame=Get<RenderedImage>(window,"result");
            check(window.ResultCanvas.ShowClipping && frame.Clipping!=null,"Clipping toggle supplies the actual canvas mask in mode "+hdr);
            var photo=Pixels(frame.Image,PixelFormats.Bgra32);var mask=Pixels(frame.Clipping!,PixelFormats.Bgra32);
            check(frame.Clipping!.PixelWidth==frame.Image.PixelWidth && frame.Clipping.PixelHeight==frame.Image.PixelHeight,"Clipping mask matches the displayed SDR dimensions");
            var expected=new byte[photo.Length];
            for(var i=0;i<photo.Length;i+=4) {
                if(photo[i]==255 || photo[i+1]==255 || photo[i+2]==255){expected[i+2]=255;expected[i+3]=160;}
                else if(photo[i]==0 && photo[i+1]==0 && photo[i+2]==0){expected[i]=255;expected[i+1]=130;expected[i+3]=160;}
            }
            check(mask.SequenceEqual(expected) && Enumerable.Range(0,mask.Length/4).Any(i=>mask[i*4+3]==160),"Highlight and black warnings follow the corresponding SDR output pixels");
            Capture(window,Path.Combine(root,hdr ? "hdr-clipping.png" : "sdr-clipping.png"));
            window.ClippingButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready(window);
            check(!window.ResultCanvas.ShowClipping && Get<RenderedImage>(window,"result").Clipping==null,"Disabling clipping removes the mask and invalidates the masked preview");
        }
    }

    private static byte[] Pixels(BitmapSource image,PixelFormat format)
    {
        var converted=new FormatConvertedBitmap(image,format,null,0);var bytes=new byte[image.PixelWidth*image.PixelHeight*4];
        converted.CopyPixels(bytes,image.PixelWidth*4,0);return bytes;
    }
    private static void Capture(FrameworkElement element,string path)
    {
        element.UpdateLayout();var bitmap=new RenderTargetBitmap((int)Math.Ceiling(element.ActualWidth),(int)Math.Ceiling(element.ActualHeight),96,96,PixelFormats.Pbgra32);
        bitmap.Render(element);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var file=File.Create(path);encoder.Save(file);
    }
}
