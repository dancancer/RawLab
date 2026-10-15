using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class EditorShellChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        if(File.Exists(Path.Combine(BatchJournal.DefaultDirectory,"job.json")))throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
        Directory.CreateDirectory(output);
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        var previous=Loc.Preference;
        MainWindow? window=null;
        try
        {
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"})
            {
                Loc.Initialize(language);foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
                window=new MainWindow();window.Show();
                foreach(var size in new[]{new Size(1000,680),new Size(1440,920)})
                {
                    window.Width=size.Width;window.Height=size.Height;window.UpdateLayout();
                    var menu=window.FindName("MainMenu") as Menu;
                    check(menu?.Items.Count==5,"Five discoverable native menus: "+language);
                    check(window.WindowStyle==WindowStyle.SingleBorderWindow && window.ResizeMode==ResizeMode.CanResize,"Standard caption and resizable Windows shell");
                    check(window.ResultCanvas.ActualHeight>=160,"Canvas retains 160 DIP at "+size);
                    check(!window.ExportButton.IsEnabled,"Empty editor cannot export");
                    check(window.ResultCanvas.ToolTip==null,"Empty canvas has no zoom instructions");
                    check(Descendants(window.Welcome).OfType<TextBlock>().Any(t=>t.Text==Loc.Text("打开一张 RAW")),"Exact approved empty-state heading");
                    var bitmap=new RenderTargetBitmap((int)window.ActualWidth,(int)window.ActualHeight,96,96,PixelFormats.Pbgra32);
                    bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
                    using var stream=File.Create(Path.Combine(output,$"empty-{language}-{size.Width}.png"));encoder.Save(stream);
                }
                window.Close();window=null;
            }
            Loc.Initialize("en");
            var row=new ParameterRow();var host=new Window{Content=row,Width=720,SizeToContent=SizeToContent.Height};
            host.Show();row.Refresh("Exposure",new(-4,4,.01,.1,.01,false,2),0,0,"EV");host.UpdateLayout();
            MouseWheelEventArgs Wheel(int delta){var args=new MouseWheelEventArgs(Mouse.PrimaryDevice,Environment.TickCount,delta){RoutedEvent=UIElement.PreviewMouseWheelEvent};row.Number.RaiseEvent(args);return args;}
            check(Wheel(120).Handled && row.Number.Text=="0.10","WPF vertical wheel takes one ordinary exposure step");
            check(Wheel(120).Handled && row.Number.Text=="0.10","Rapid WPF wheel events are consumed but rate limited");
            row.Number.Text="invalid";check(!Wheel(120).Handled,"Invalid numeric draft does not intercept panel scrolling");
            row.RestoreText();row.Number.IsReadOnly=true;check(!Wheel(120).Handled,"Read-only numeric field does not intercept panel scrolling");row.Number.IsReadOnly=false;
            var provider=(IRangeValueProvider)UIElementAutomationPeer.CreatePeerForElement(row.Slider)!.GetPattern(PatternInterface.RangeValue)!;
            check(provider.Minimum==-4 && provider.Maximum==4 && provider.SmallChange==.01 && Math.Abs(provider.Value-.1)<1e-10,"Slider automation reports actual numeric units, not normalized position");
            row.Refresh("Exposure",new(-4,4,.01,.1,.01,false,2),4,0,"EV");check(Wheel(120).Handled,"Boundary wheel remains consumed");
            host.FontSize=26;host.UpdateLayout();check(row.ActualHeight>=32 && row.Number.ActualHeight>=26,"Enlarged parameter text grows its row naturally");
            host.Close();
        }
        finally{window?.Close();Loc.Initialize(previous);app.Shutdown();}
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach(var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>()){
            yield return child;foreach(var descendant in Descendants(child))yield return descendant;
        }
    }
}
