using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
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
                window=new MainWindow();TestWindowState.Isolate(window,output);window.Show();
                foreach(var size in new[]{new Size(1024,720),new Size(1440,920)})
                {
                    var surface=ArrangeLayout(window,size);
                    var menu=window.FindName("MainMenu") as Menu;
                    check(menu?.Items.Count==5,"Five discoverable native menus: "+language);
                    check(window.WindowStyle==WindowStyle.SingleBorderWindow && window.ResizeMode==ResizeMode.CanResize,"Standard caption and resizable Windows shell");
                    check(window.FontSize==(double)app.Resources["EditorBodySize"],"Editor uses the shared Windows text scale");
                    check(window.ResultCanvas.ActualHeight>=160,"Canvas retains 160 DIP at "+size);
                    check(!window.ExportButton.IsEnabled,"Empty editor cannot export");
                    check(window.AdjustmentPanel.Visibility==Visibility.Collapsed && !window.Groups.IsVisible,"No photo hides all adjustment groups and parameters");
                    check(window.NeutralCanvas.Visibility==Visibility.Collapsed && window.NeutralColumn.ActualWidth==0,"Empty editor has a single unbroken canvas");
                    check(window.ResultCanvas.ToolTip==null,"Empty canvas has no zoom instructions");
                    check(Descendants(window.Welcome).OfType<TextBlock>().Any(t=>t.Text==Loc.Text("打开照片")),"Exact approved empty-state heading");
                    CaptureLayout(window,surface,Path.Combine(output,$"empty-{language}-{size.Width}.png"));
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
            host.FontSize=26;host.UpdateLayout();check(row.ActualHeight>=32 && row.Number.ActualHeight>=26 && row.Number.Width>=144,"Enlarged parameter text grows its row and numeric field naturally");
            host.Content=null;var details=new Expander{Content=row,IsExpanded=true};
            var checkbox=new CheckBox{Content="Enabled"};var radio=new RadioButton{Content="Automatic"};
            var themed=new StackPanel();themed.Children.Add(details);themed.Children.Add(checkbox);themed.Children.Add(radio);host.Content=themed;host.UpdateLayout();
            check(ReferenceEquals(row.Children.OfType<TextBlock>().First().Foreground,app.Resources["Foreground"]) &&
                ReferenceEquals(checkbox.Foreground,app.Resources["Foreground"]) && ReferenceEquals(radio.Foreground,app.Resources["Foreground"]),
                "Native expanders and binary controls retain readable editor foreground");
            host.Close();
        }
        finally{window?.Close();Loc.Initialize(previous);app.Shutdown();}
    }
    internal static FrameworkElement ArrangeLayout(Window window,Size requested)
    {
        var content=(FrameworkElement)window.Content;
        content.ClearValue(FrameworkElement.WidthProperty);content.ClearValue(FrameworkElement.HeightProperty);
        window.Width=requested.Width;window.Height=requested.Height;window.UpdateLayout();
        var chrome=new Size(window.ActualWidth-content.ActualWidth,window.ActualHeight-content.ActualHeight);
        var client=new Size(requested.Width-chrome.Width,requested.Height-chrome.Height);
        Console.WriteLine($"Native window requested={requested}, actual={window.ActualWidth}x{window.ActualHeight}; WPF client layout={client}");
        // SSH 桌面可能限制 HWND 尺寸；单独验证精确 DIP 客户区，不冒充物理屏幕截图。
        content.Width=client.Width;content.Height=client.Height;content.Measure(client);content.Arrange(new Rect(client));content.UpdateLayout();
        if(Math.Abs(content.ActualWidth-client.Width)>.5 || Math.Abs(content.ActualHeight-client.Height)>.5)
            throw new InvalidOperationException("WPF client layout did not reach the requested DIP size.");
        return content;
    }
    internal static void CaptureLayout(Window window,FrameworkElement content,string path)
    {
        var size=new Size(content.Width,content.Height);
        window.Content=null;window.UpdateLayout();
        var host=new Grid{Width=size.Width,Height=size.Height};host.Children.Add(content);
        try
        {
            TextElement.SetFontSize(content,window.FontSize);TextElement.SetFontFamily(content,window.FontFamily);
            content.InvalidateMeasure();content.InvalidateArrange();host.Measure(size);host.Arrange(new Rect(size));host.UpdateLayout();
            Console.WriteLine($"Offscreen WPF composition={content.RenderSize}; layout clip={System.Windows.Controls.Primitives.LayoutInformation.GetLayoutClip(content)?.Bounds}");
            var bitmap=new RenderTargetBitmap((int)size.Width,(int)size.Height,96,96,PixelFormats.Pbgra32);bitmap.Render(host);
            var corner=new byte[4];bitmap.CopyPixels(new Int32Rect(bitmap.PixelWidth-1,bitmap.PixelHeight-1,1,1),corner,4,0);
            if(corner[3]!=255)throw new InvalidOperationException("WPF layout composition is clipped or transparent at the requested bounds.");
            var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(path);encoder.Save(stream);
        }
        finally
        {
            host.Children.Remove(content);window.Content=content;content.ClearValue(TextElement.FontSizeProperty);content.ClearValue(TextElement.FontFamilyProperty);
            content.ClearValue(FrameworkElement.WidthProperty);content.ClearValue(FrameworkElement.HeightProperty);window.UpdateLayout();
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach(var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>()){
            yield return child;foreach(var descendant in Descendants(child))yield return descendant;
        }
    }
}
