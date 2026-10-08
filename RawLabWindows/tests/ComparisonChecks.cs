using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

static class ComparisonChecks
{
    internal static void Run(Action<bool,string> check)
    {
        var viewport=new Viewport();var resolutionChanges=0;
        viewport.ResolutionChanged+=()=>resolutionChanges++;
        viewport.Move(new Vector(30,-20));viewport.ToggleActualPixels();
        check(viewport.ActualPixels && viewport.Zoom==1 && viewport.Pan==default && resolutionChanges==1,
            "Double click switches fit to native pixels, clears pan and requests native resolution");
        viewport.Magnify(1.25);viewport.Move(new Vector(10,40));viewport.ToggleActualPixels();
        check(!viewport.ActualPixels && viewport.Zoom==1 && viewport.Pan==default && resolutionChanges==2,
            "Double click returns pixel mode to fit, clears pan and requests preview resolution");
        viewport.Magnify(2);viewport.ToggleActualPixels();
        check(!viewport.ActualPixels && viewport.Zoom==1 && resolutionChanges==2,
            "Double click resets manual fit magnification without redundant rendering");
        BitmapSource Solid(byte b,byte g,byte r)=>BitmapSource.Create(1,1,96,96,PixelFormats.Bgra32,null,new byte[]{b,g,r,255},4);
        var canvas=new PhotoCanvas{Viewport=new Viewport(),ComparisonEnabled=true};
        canvas.SetImage(Solid(255,0,0),null);canvas.SetComparison(Solid(0,0,255),null);
        canvas.Measure(new Size(200,200));canvas.Arrange(new Rect(0,0,200,200));
        byte[] Render()
        {
            canvas.UpdateLayout();
            var bitmap=new RenderTargetBitmap(200,200,96,96,PixelFormats.Pbgra32);bitmap.Render(canvas);
            var pixels=new byte[200*200*4];bitmap.CopyPixels(pixels,800,0);return pixels;
        }
        var split=Render();var left=(30*200+30)*4;var right=(30*200+170)*4;
        check(split[left+2]==255 && split[left]==0 && split[right]==255 && split[right+2]==0,"Wipe shows neutral on left and edit on right");
        canvas.Divider=0;check(Render()[left]==255,"Wipe left endpoint reveals the full edit");
        canvas.Divider=1;check(Render()[right+2]==255,"Wipe right endpoint reveals the full neutral image");
        canvas.ComparisonEnabled=false;check(Render()[left]==255,"Disabling wipe restores the edited image");
        var view=canvas.Viewport!;view.SetSourceSize(6000,4000);view.Actual();
        var dpi=VisualTreeHelper.GetDpi(canvas);
        check(Math.Abs(canvas.ImageBounds.Width-6000/dpi.DpiScaleX)<.01 && Math.Abs(canvas.ImageBounds.Height-4000/dpi.DpiScaleY)<.01,
            "Native zoom immediately scales the existing preview using source pixels and DPI");
        var contentVersion=canvas.ContentVersion;var bounds=canvas.ImageBounds;
        view.Move(new Vector(21,-13));
        check(canvas.ContentVersion==contentVersion && canvas.ImageBounds.X==bounds.X+21 && canvas.ImageBounds.Y==bounds.Y-13,
            "Panning changes retained transforms without rebuilding image drawings");
        canvas.SetImage(Solid(255,0,0),null);
        check(view.ActualPixels && view.Pan==new Vector(21,-13) && canvas.ImageBounds.Width==bounds.Width,
            "Replacing a preview with detail preserves native zoom and pan geometry");
        view.Fit();
        var grid=new PhotoGridPanel();for(var i=0;i<3;i++)grid.Children.Add(new Border());
        grid.Measure(new Size(220,double.PositiveInfinity));grid.Arrange(new Rect(0,0,220,grid.DesiredSize.Height));
        check(grid.Children[1].TranslatePoint(new Point(),grid).X==0 && grid.DesiredSize.Height==420,"Narrow file tree uses one thumbnail column");
        grid.Measure(new Size(320,double.PositiveInfinity));grid.Arrange(new Rect(0,0,320,grid.DesiredSize.Height));
        check(grid.Children[1].TranslatePoint(new Point(),grid).X==160 && grid.DesiredSize.Height==280,"Wide file tree uses two thumbnail columns");
    }
}
