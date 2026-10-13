using System.IO;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class LensChecks
{
    private static byte[] Pixels(BitmapSource image)
    {
        var bytes = new byte[image.PixelWidth * image.PixelHeight * 4];
        new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0).CopyPixels(bytes, image.PixelWidth * 4, 0);
        return bytes;
    }

    internal static void Run(string repo, string raw, Action<bool, string> check)
    {
        var database = Path.Combine(repo, "lutools/third_party/lensfun/version_1");
        using var cpu = new RenderEngine(0, database);
        using var gpu = new RenderEngine(2, database);
        var off = cpu.Render(raw, new(), null, 300)!;
        var unselected = cpu.Render(raw, new Adjustments { Lens = new(Distortion:true,Manual:true) }, null, 300)!;
        check(unselected.Lens!.State == 4 && Pixels(unselected.Image).SequenceEqual(Pixels(off.Image)),
            "Windows manual mode without selection skips, never auto matches");
        var candidate = off.Lens!.Candidates.First(p => p.IsMatch && p.HasDistortion);
        var settings = new Adjustments { Lens = new(true, true, true, true, candidate.Id) };
        var corrected = cpu.Render(raw, settings, null, 300)!;
        check(corrected.Lens!.AppliedDistortion && corrected.Lens.AppliedTca == candidate.HasTca,
            "Windows manual lens calibration reaches the native core");
        check(corrected.Image.PixelWidth == off.Image.PixelWidth && corrected.Image.PixelHeight == off.Image.PixelHeight &&
            !Pixels(corrected.Image).SequenceEqual(Pixels(off.Image)), "Windows auto crop preserves output dimensions");
        var accelerated = gpu.Render(raw, settings, null, 300)!;
        check(accelerated.Backend == 3 && Pixels(corrected.Image).Zip(Pixels(accelerated.Image), (a,b) => Math.Abs(a-b)).Max() <= 2,
            "Windows corrected RAW CPU/Force D3D11 parity");
        settings.Lens = settings.Lens with { Manual = false };
        var automatic = cpu.Render(raw, settings, null, 300)!;
        check(off.Lens.Candidates.Count(p => p.IsMatch) == 1
            ? Pixels(automatic.Image).SequenceEqual(Pixels(corrected.Image))
            : automatic.Lens!.State == 5, "Windows automatic matching never guesses");
        settings.Lens = new(true, true, true, true, candidate.Id);
        var comparison = cpu.RenderPreview(raw, settings, null, 300, false, true, false);
        check(comparison.Neutral.Lens!.State == 0 && comparison.Result.Lens!.AppliedDistortion,
            "Windows neutral comparison stays uncorrected");
        check(Pixels(cpu.Render(raw, new(), null, 300)!.Image).SequenceEqual(Pixels(off.Image)), "Windows lens reset restores exact baseline");
        var output = Path.Combine(repo, "build/windows-verification/lens-corrected.png");
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        cpu.Render(raw, settings, null, 0, output: output, longEdge: 300);
        check(File.Exists(output) && File.ReadAllBytes(output)[24] == 16, "Windows lens correction reaches sixteen-bit PNG export");
        var panel = new LensPanel();
        panel.Refresh(settings.Lens, corrected.Lens);
        LensSettings? changed = null;
        panel.Changed += value => changed = value;
        ((RadioButton)panel.FindName("Automatic")).IsChecked = true;
        check(changed?.Manual == false, "Windows automatic radio selects automatic mode");
        ((RadioButton)panel.FindName("Manual")).IsChecked = true;
        check(changed?.Manual == true, "Windows manual radio selects manual mode");
        ((TextBox)panel.FindName("Search")).Text = "no-profile-with-this-name";
        check(((ListBox)panel.FindName("Profiles")).Items.Count == 0, "Windows lens search filters profiles");
    }
}
