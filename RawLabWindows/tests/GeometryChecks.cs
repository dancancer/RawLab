using System.IO;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class GeometryChecks
{
    internal static void Run(string repo, string raw, Action<bool, string> check)
    {
        var originalHash = SHA256.HashData(File.ReadAllBytes(raw));
        check(Marshal.SizeOf<Native.GeometryConfig>()==40 && Marshal.SizeOf<Native.PerspectiveConfig>()==16 &&
            Marshal.OffsetOf<Native.PerspectiveConfig>(nameof(Native.PerspectiveConfig.Vertical)).ToInt32()==12,"Native geometry and additive perspective ABI layouts");
        using var engine = new RenderEngine(0, Path.Combine(repo, "lutools", "third_party", "lensfun", "version_1"));
        var settings = new Adjustments();
        var original = engine.Render(raw, settings, null, 0, clipping: false)!;
        check(original.NativeWidth == original.Image.PixelWidth && original.NativeHeight == original.Image.PixelHeight,
            "Identity reports the original canvas before resizing");
        settings.Geometry = new(QuarterTurns: 1);
        var rotated = engine.Render(raw, settings, null, 0, clipping: false)!;
        check(rotated.NativeWidth == original.NativeHeight && rotated.NativeHeight == original.NativeWidth &&
              rotated.Image.PixelWidth == rotated.NativeWidth && rotated.Image.PixelHeight == rotated.NativeHeight,
            "Clockwise quarter rotation swaps native dimensions");
        settings.Geometry = settings.Geometry.Rotate(-1);
        check(Pixels(original.Image).SequenceEqual(Pixels(engine.Render(raw, settings, null, 0, clipping: false)!.Image)),
            "Returning to identity replaces the complete session geometry");

        settings.Geometry = new(.2, .1, .6, .8, 1, true, false, 12.5);
        var exact = engine.Render(raw, settings, null, 256, clipping: false)!;
        var interactive = engine.Render(raw, settings, null, 256, interactive: true, clipping: false, viewportPreview: true)!;
        check(exact.NativeWidth == interactive.NativeWidth && exact.NativeHeight == interactive.NativeHeight &&
              Pixels(exact.Image).SequenceEqual(Pixels(interactive.Image)),
            "Geometry bypasses approximate input reduction and preserves exact preview pixels");
        var full = engine.Render(raw, settings, null, 0, clipping: false)!;
        check(full.Image.PixelWidth == exact.NativeWidth && full.Image.PixelHeight == exact.NativeHeight &&
              Math.Max(exact.Image.PixelWidth, exact.Image.PixelHeight) <= 256,
            "Full and resized outputs share the native geometry canvas");
        var frame = engine.RenderPreview(raw, settings, null, 256, false, true, false);
        check(frame.Neutral.NativeWidth == frame.Result.NativeWidth && frame.Neutral.NativeHeight == frame.Result.NativeHeight,
            "Reference comparison uses the edited geometry canvas");
        check(ReferenceEquals(frame, engine.RenderPreview(raw, settings, null, 256, false, true, false)),
            "Unchanged geometry reuses its exact preview");
        settings.Geometry = settings.Geometry with { FlipVertical = true };
        var changed = engine.RenderPreview(raw, settings, null, 256, false, true, false);
        check(!ReferenceEquals(frame, changed) && !ReferenceEquals(frame.Neutral, changed.Neutral),
            "Geometry changes invalidate edited and reference caches");
        settings.Geometry = new();
        var reset = engine.RenderPreview(raw, settings, null, 256, false, true, false);
        check(reset.Result.NativeWidth == original.NativeWidth && reset.Result.NativeHeight == original.NativeHeight,
            "Reset restores the original dimensions after active geometry");
        settings.Geometry=new(PerspectiveHorizontal:.25,PerspectiveVertical:-.15);
        var perspective=engine.Render(raw,settings,null,256,clipping:false)!;
        check(!Pixels(perspective.Image).SequenceEqual(Pixels(reset.Result.Image)),"Perspective changes real RAW output pixels");
        var perspectiveInteractive=engine.Render(raw,settings,null,256,interactive:true,clipping:false,viewportPreview:true)!;
        check(Pixels(perspective.Image).SequenceEqual(Pixels(perspectiveInteractive.Image)),"Perspective bypasses approximate viewport input");
        var perspectiveFrame=engine.RenderPreview(raw,settings,null,256,false,true,false);
        check(perspectiveFrame.Neutral.NativeWidth==perspectiveFrame.Result.NativeWidth && perspectiveFrame.Neutral.NativeHeight==perspectiveFrame.Result.NativeHeight,
            "Perspective comparison shares the transformed canvas");
        settings.Geometry=new();
        check(Pixels(reset.Result.Image).SequenceEqual(Pixels(engine.RenderPreview(raw,settings,null,256,false,true,false).Result.Image)),
            "Zero perspective is submitted and clears reused native session state");
        check(SHA256.HashData(File.ReadAllBytes(raw)).SequenceEqual(originalHash), "Geometry never writes the original RAW");
    }
    private static byte[] Pixels(BitmapSource image)
    {
        var stride = image.PixelWidth * 4; var pixels = new byte[stride * image.PixelHeight];
        image.CopyPixels(pixels, stride, 0); return pixels;
    }
}
