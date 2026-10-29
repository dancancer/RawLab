using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class AIGpuWindowChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var app=Application.Current ?? TestWindowState.CreateApplication();
        var inventory=AIDeviceInventory.Parse("""
            {"version":1,"recommended_id":"gpu-b","devices":[
              {"id":"gpu-a","name":"Intel UHD Graphics 770","available":true,"integrated":true},
              {"id":"gpu-b","name":"NVIDIA GeForce RTX 3060 Ti","available":true,"integrated":false,"dedicated_memory_bytes":8589934592}]}
            """);
        T Find<T>(DependencyObject root,string id) where T:DependencyObject {
            if(root is T value && AutomationProperties.GetAutomationId(root)==id)return value;
            for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++) {
                try{return Find<T>(VisualTreeHelper.GetChild(root,i),id);}catch(InvalidOperationException){}
            }
            throw new InvalidOperationException("Missing UI control "+id);
        }
        void Capture(Window window,string name) {
            window.UpdateLayout();
            var bitmap=new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth),(int)Math.Ceiling(window.ActualHeight),96,96,PixelFormats.Pbgra32);
            bitmap.Render(window);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream=File.Create(Path.Combine(output,name+".png"));encoder.Save(stream);
        }
        foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"}) {
            Loc.Initialize(language,Path.Combine(output,"language.txt"));
            foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
            var exported=0;
            var window=new SettingsWindow(0,new(),inventory,false,_=>{exported++;return Task.FromResult(true);},true);
            Exception? failure=null;
            window.Loaded+=(_,_)=>window.Dispatcher.BeginInvoke(new Action(()=>{
                try {
                    var gpu=Find<ComboBox>(window,"settings.aiGpu");
                    check((string?)gpu.SelectedValue=="","AI GPU defaults to Auto: "+language);
                    gpu.SelectedValue="gpu-a";
                    window.UpdateLayout();
                    IEnumerable<TextBlock> Texts(DependencyObject node) {
                        if(node is TextBlock text)yield return text;
                        for(var i=0;i<VisualTreeHelper.GetChildrenCount(node);i++)
                            foreach(var child in Texts(VisualTreeHelper.GetChild(node,i)))yield return child;
                    }
                    check(Texts(gpu).Any(text=>text.Text=="Intel UHD Graphics 770"),"Selected GPU renders its display name: "+language);
                    check(window.AIPreference.DeviceID=="gpu-a","Explicit iGPU choice survives UI binding: "+language);
                    Find<Button>(window,"settings.exportAiDiagnostics").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    check(exported==1,"Export diagnostic action is reachable: "+language);
                    Capture(window,"ai-gpu-settings-"+language);
                    check(gpu.ActualWidth>200 && window.ActualHeight<800,"GPU settings fit the normal desktop window: "+language);
                    Find<Button>(window,"settings.apply").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                } catch(Exception error){failure=error;window.Close();}
            }),DispatcherPriority.ApplicationIdle);
            var applied=window.ShowDialog();if(failure!=null)throw failure;
            check(applied==true && window.AIPreference.DeviceID=="gpu-a","Apply returns selected AI GPU: "+language);
        }
        Loc.Initialize("zh-Hans",Path.Combine(output,"language.txt"));
        foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        var missing=new SettingsWindow(0,new("gone","Removed GPU"),inventory,true,null,false);
        missing.Loaded+=(_,_)=>missing.Dispatcher.BeginInvoke(new Action(()=>{
            var gpu=Find<ComboBox>(missing,"settings.aiGpu");
            check(!gpu.IsEnabled && missing.AIPreference.DeviceID=="gone","Running task locks selection and missing preference is preserved");
            Capture(missing,"ai-gpu-settings-unavailable");
            Find<Button>(missing,"settings.cancel").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        }),DispatcherPriority.ApplicationIdle);
        check(missing.ShowDialog()!=true,"Cancel did not apply a replacement GPU");
        var panel=new DenoisePanel();var report="fixture-report.json";var exports=0;
        panel.AIDiagnosticsRequested+=()=>exports++;
        var host=new Window{Width=650,Height=260,Content=panel};host.Show();
        try {
            panel.RefreshAI(true,false,true,new(AIDenoiseStatus.Failed,Error:"GPU call failed (0x887A0001)",DiagnosticPath:report));
            host.UpdateLayout();
            var button=(Button)panel.FindName("AIExportDiagnostics");
            check(button.Visibility==Visibility.Visible,"AI failure exposes the diagnostic export action");
            button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));check(exports==1,"AI failure diagnostic export is wired");
            Capture(host,"ai-gpu-error-report");
            panel.RefreshAI(true,false,true,new(AIDenoiseStatus.Cancelled));
            check(button.Visibility==Visibility.Collapsed,"Cancellation hides unrelated diagnostic reports");
        } finally {host.Close();}
    }
}
