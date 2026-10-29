using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class MasterRecipeChecks
{
    internal static void Run(string repo, string raw)
    {
        static byte[] Pixels(BitmapSource image) {
            var data = new byte[image.PixelWidth * image.PixelHeight * 4];
            new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0).CopyPixels(data, image.PixelWidth * 4, 0);
            return data;
        }
        static void Check(bool value, string name) { if (!value) throw new Exception(name); Console.WriteLine("PASS " + name); }
        using var cpu = new RenderEngine(0);
        using var auto = new RenderEngine(1);
        var neutral = cpu.Render(raw, new(), null, 256, statistics: false, clipping: false)!;
        var camera = neutral.WhiteBalance!.Value;
        foreach (var recipe in MasterRecipe.All) {
            Check(File.Exists(recipe.LutPath) && File.Exists(recipe.ArtworkPath), recipe.Id + " bundled assets");
            var current = new Adjustments(); current.ApplyMasterRecipe(recipe);
            current.Hsl = current.Hsl.WithValue(0, 7, 37);
            foreach (var strength in new[] { 0.0, .5, 1, 2 }) {
                current.Set(Parameter.Strength, strength * 100);
                var manual = new Adjustments(); manual.ResolveWhiteBalance(camera);
                manual.Set(Parameter.Strength, strength * 100);
                foreach (var parameter in new[] { Parameter.Exposure, Parameter.Highlights, Parameter.Shadows, Parameter.Contrast, Parameter.Saturation })
                    manual.Set(parameter, current[parameter] * strength);
                if (strength != 0) manual.Set(Parameter.Tint, Math.Clamp(camera.Tint + current[Parameter.Tint] * strength, -150, 150));
                manual.Hsl = current.RenderHsl;
                manual.ToneControls = current.ToneControls.Scaled(strength);
                manual.Atmosphere = current.Atmosphere.Scaled(strength);
                manual.ColorGrading = current.ColorGrading.Scaled(strength);
                manual.Curve = current.Curve.Scaled(strength);
                var actual = Pixels(cpu.Render(raw, current, recipe.LutPath, 256, statistics: false, clipping: false)!.Image);
                var expected = Pixels(cpu.Render(raw, manual, recipe.LutPath, 256, statistics: false, clipping: false)!.Image);
                Check(actual.SequenceEqual(expected), recipe.Id + " " + strength + " explicit manual parity");
                var automatic = Pixels(auto.Render(raw, current, recipe.LutPath, 256, statistics: false, clipping: false)!.Image);
                Check(actual.Zip(automatic, (a, b) => Math.Abs(a - b)).Max() <= 2, recipe.Id + " Auto/CPU parity");
                if (strength == 0) Check(actual.SequenceEqual(Pixels(neutral.Image)), recipe.Id + " zero neutral");
            }
        }
        Console.WriteLine("PASS all fourteen Windows master recipes on actual RAW");
    }
}
