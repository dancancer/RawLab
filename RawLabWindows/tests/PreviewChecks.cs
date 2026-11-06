using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class PreviewChecks
{
    internal static void RunViewport(string repo,string raw,Action<bool,string> check)
    {
        var app=TestWindowState.CreateApplication();
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=new MainWindow{Width=1280,Height=820};
        TestWindowState.Isolate(window,Path.Combine(repo,"build","viewport-reuse"));
        window.GpuMode.SelectedIndex=1;
        window.Show();
        var field=typeof(MainWindow).GetField("result",BindingFlags.Instance|BindingFlags.NonPublic)!;
        RenderedImage Ready()
        {
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            return (RenderedImage)field.GetValue(window)!;
        }
        var status=DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty,typeof(TextBlock));
        var developments=0;
        EventHandler onStatus=(_,_)=>{if(window.Status.Text==Loc.Text("正在显影…"))developments++;};
        try
        {
            window.OpenFile(raw);
            var fit=Ready();
            status.AddValueChanged(window.Status,onStatus);
            var viewport=window.ResultCanvas.Viewport;
            viewport!.ToggleActualPixels();
            var actual=Ready();
            check(actual.Image.PixelWidth>fit.Image.PixelWidth && developments>0,
                "First native-size request develops a larger frame and reports real work");
            developments=0;
            viewport.ToggleActualPixels();
            check(ReferenceEquals(fit,Ready()),"Returning to Fit publishes the same WPF pixels");
            viewport.ToggleActualPixels();
            check(ReferenceEquals(actual,Ready()) && developments==0,
                "Returning to Actual pixels reuses the native frame without a developing status");
            window.MenuCompareSwipe.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            check(ReferenceEquals(actual,Ready()) &&
                (bool)typeof(MainWindow).GetProperty("ReferenceCurrent",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(window)!,
                "Turning comparison on develops only the missing reference");
            window.MenuCompareOff.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            check(ReferenceEquals(actual,Ready()),"Turning comparison off retains the edited WPF pixels");
            var maskField=typeof(PhotoCanvas).GetField("mask",BindingFlags.Instance|BindingFlags.NonPublic)!;
            BitmapSource? Mask()=>maskField.GetValue(window.ResultCanvas) as BitmapSource;
            void ToggleClipping()=>window.ClippingButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            developments=0;
            ToggleClipping();
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled && Mask()!=null);
            var mask=Mask();
            check(ReferenceEquals(actual,Ready()) && developments==0,
                "Turning clipping on generates only the overlay and leaves the current WPF frame ready");
            ToggleClipping();
            check(!window.ResultCanvas.ShowClipping && ReferenceEquals(actual,Ready()) && developments==0,
                "Turning clipping off hides the overlay without developing the image");
            ToggleClipping();
            InteractionChecks.PumpUntil(()=>Mask()!=null);
            check(ReferenceEquals(mask,Mask()) && ReferenceEquals(actual,Ready()),
                "Re-enabling clipping reuses the current overlay and image");
            using var oracle=new RenderEngine(0);
            var settings=(Adjustments)typeof(MainWindow).GetField("settings",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(window)!;
            var expected=oracle.Render(raw,settings,null,0,statistics:false,clipping:true,viewportPreview:true)!.Clipping!;
            check(SameMask(expected,mask!),"The displayed RAW clipping overlay matches the native highlight and shadow mask");
            viewport.ToggleActualPixels();
            check(ReferenceEquals(fit,Ready()),"Clipping remains a display option when the viewport reuses a different frame");
            InteractionChecks.PumpUntil(()=>Mask()?.PixelWidth==fit.Image.PixelWidth);
            check(!ReferenceEquals(mask,Mask()),"A new preview size receives its own clipping mask");
        }
        finally {status.RemoveValueChanged(window.Status,onStatus);window.Close();app.Shutdown();}
    }

    internal static bool SameMask(BitmapSource expected,BitmapSource actual)
    {
        if(expected.PixelWidth!=actual.PixelWidth || expected.PixelHeight!=actual.PixelHeight)return false;
        var pixels=new FormatConvertedBitmap(actual,PixelFormats.Bgra32,null,0);
        var stride=expected.PixelWidth*4;
        var left=new byte[stride];var right=new byte[stride];
        for(var row=0;row<expected.PixelHeight;row++)
        {
            var bounds=new Int32Rect(0,row,expected.PixelWidth,1);
            expected.CopyPixels(bounds,left,stride,0);
            pixels.CopyPixels(bounds,right,stride,0);
            if(!left.AsSpan().SequenceEqual(right))return false;
        }
        return true;
    }

    internal static void Run(RenderEngine engine,string raw,string lut,Action<bool,string> check)
    {
        var embedded=RenderEngine.ReadEmbeddedPreview(raw);
        check(embedded.Image!=null && embedded.Image.IsFrozen && Math.Max(embedded.Image.PixelWidth,embedded.Image.PixelHeight)<=1600,
            "Embedded camera preview is decoded and frozen without RAW development");
        var settings=new Adjustments();
        PreviewFrame Frame(int edge=2000,bool interactive=false,bool compare=true,bool clipping=false)=>
            engine.RenderPreview(raw,settings,lut,edge,interactive,compare,clipping);
        var fit=Frame();var full=Frame(0);
        check(embedded.Width==full.Result.Image.PixelWidth && embedded.Height==full.Result.Image.PixelHeight,
            "Embedded metadata supplies the exact active source dimensions before development");
        check(full.Result.Image.Format==PixelFormats.Pbgra32,"Opaque photo buffers use the WPF compositor pixel format");
        check(engine.CachedPreviewBytes<=256L*1024*1024,"Preview cache stays within the 256 MiB pixel budget");
        if((long)embedded.Width*embedded.Height*8+2000L*2000*8<=256L*1024*1024)
        {
            check(ReferenceEquals(fit,Frame()) && ReferenceEquals(full,Frame(0)),"Fit/native toggles reuse exact frames without processing or readback");
            check(ReferenceEquals(fit,Frame(2000,true)),"An exact cached preview may satisfy a same-size proxy request");
            check(!ReferenceEquals(fit,Frame(1000,true)),"A viewport-size change cannot reuse a different-size frame");
        }
        settings.Set(Parameter.Exposure,.35);
        var proxy=Frame(1000,true);var changed=Frame();
        check(!ReferenceEquals(proxy,changed) && !ReferenceEquals(fit,changed),"Editing invalidates cached pixels and proxy quality never satisfies an exact request");
        var single=Frame(compare:false);
        check(ReferenceEquals(single.Neutral,single.Result) && ReferenceEquals(changed.Result,single.Result),
            "Turning comparison off reuses the edited pixels without publishing a reference");
        check(ReferenceEquals(changed,Frame()),"Turning comparison back on reuses both completed frames");
        var masked=Frame(clipping:true);
        check(masked.Neutral.Clipping==null && masked.Result.Clipping!=null && ReferenceEquals(changed.Result.Image,masked.Result.Image),
            "The clipping overlay belongs to the existing edited pixels and leaves the reference unchanged");
        engine.SetGpuMode(0);var cpu=Frame();
        check(cpu.Result.Backend!=3,"CPU mode cannot reuse a GPU-labelled cached frame");engine.SetGpuMode(1);
        var versioned = new Adjustments();
        versioned.ApplyMasterRecipe(MasterRecipe.All[0]);
        versioned.Set(Parameter.Strength, 50);
        versioned.ToneControls = new(35, -20, 30);
        versioned = (versioned.Capture() with { MasterRecipeSettingsVersion = 3 }).Restore();
        var legacyFrame = engine.RenderPreview(raw, versioned, lut, 256, false, false, false);
        check(ReferenceEquals(legacyFrame, engine.RenderPreview(raw, versioned, lut, 256, false, false, false)),
            "Legacy recipe frame is cached before changing its settings version");
        versioned = (versioned.Capture() with { MasterRecipeSettingsVersion = 4 }).Restore();
        var refinedFrame = engine.RenderPreview(raw, versioned, lut, 256, false, false, false);
        check(!ReferenceEquals(legacyFrame, refinedFrame), "Changing only recipe settings version invalidates preview pixels");
        foreach (var parameter in new[] { Parameter.Exposure, Parameter.Contrast, Parameter.Saturation,
            Parameter.Highlights, Parameter.Shadows, Parameter.Tint }) versioned.Set(parameter, 0);
        var halfRefinement = engine.RenderPreview(raw, versioned, null, 256, false, false, false);
        versioned.Set(Parameter.Strength, 100);
        check(!ReferenceEquals(halfRefinement, engine.RenderPreview(raw, versioned, null, 256, false, false, false)),
            "Modern controls invalidate the preview when only strength changes, including without a LUT");
        var originalTime=File.GetLastWriteTimeUtc(raw);
        try
        {
            var original=Frame();File.SetLastWriteTimeUtc(raw,originalTime.AddSeconds(2));
            check(!ReferenceEquals(original,Frame()),"Replacing a RAW invalidates managed and native cached data");
        }
        finally{File.SetLastWriteTimeUtc(raw,originalTime);}
    }
}
