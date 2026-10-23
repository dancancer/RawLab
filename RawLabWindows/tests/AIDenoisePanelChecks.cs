using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class AIDenoisePanelChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        var app=Application.Current ?? TestWindowState.CreateApplication();
        var panel=new DenoisePanel();panel.Refresh(DenoiseSettings.Clean);
        panel.RefreshAI(true,false,true,new(AIDenoiseStatus.Idle));
        var toggle=(CheckBox)panel.FindName("AIEnabledBox");var ordinary=(StackPanel)panel.FindName("OrdinaryDenoise");
        check(toggle.IsEnabled && toggle.IsChecked==false && ordinary.IsEnabled,"Idle AI preserves ordinary controls");
        bool? enabled=null;var cancelled=false;var retry=false;
        panel.AIChanged+=v=>enabled=v;panel.AICancelRequested+=()=>cancelled=true;panel.AIRetryRequested+=()=>retry=true;
        toggle.IsChecked=true;check(enabled==true,"AI toggle dispatches explicit preparation request");
        panel.RefreshAI(true,false,true,new(AIDenoiseStatus.Running,2,7,70));
        check(toggle.IsChecked==true && !ordinary.IsEnabled && ((ProgressBar)panel.FindName("AIProgress")).Value==.1,
            "Pending AI reports real progress and retains disabled ordinary parameters");
        ((Button)panel.FindName("AICancel")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));check(cancelled,"Cancel remains reachable while preparing");
        panel.RefreshAI(true,true,true,new(AIDenoiseStatus.Cancelled));
        check(toggle.IsChecked==true && ((Button)panel.FindName("AIRetry")).Visibility==Visibility.Visible,
            "Cancelled rebuild preserves enabled appearance with explicit retry");
        ((Button)panel.FindName("AIRetry")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));check(retry,"Retry dispatches a new explicit request");
        foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"}) {
            Loc.Initialize(language);foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
            var localized=new DenoisePanel {FontSize=14};localized.Refresh(DenoiseSettings.Clean);
            check(((CheckBox)localized.FindName("AIEnabledBox")).Content?.ToString()==Loc.Text("AI 降噪（实验）"),"AI toggle uses selected language: "+language);
            var surface=new Border {Background=(Brush)app.FindResource("Surface"),Padding=new Thickness(12),Child=localized};
            foreach(var state in new[]{new AIDenoiseState(AIDenoiseStatus.Running,3,90,140),
                new AIDenoiseState(AIDenoiseStatus.Failed,Error:"Fixture failure detail"),new AIDenoiseState(AIDenoiseStatus.Ready)}) {
                localized.RefreshAI(true,true,true,state);surface.Measure(new Size(440,double.PositiveInfinity));
                surface.Arrange(new Rect(new Point(),surface.DesiredSize));surface.UpdateLayout();
                check(surface.DesiredSize.Width<=440,"AI localized panel stays within available width: "+language);
                var bitmap=new RenderTargetBitmap(440,(int)Math.Ceiling(surface.ActualHeight),96,96,PixelFormats.Pbgra32);bitmap.Render(surface);
                Directory.CreateDirectory(output);using var stream=File.Create(Path.Combine(output,$"ai-{language}-{state.Status}.png"));
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));encoder.Save(stream);
            }
        }
        panel.RefreshAI(false,false,false,new(AIDenoiseStatus.Idle));
        check(((StackPanel)panel.FindName("AISurface")).Visibility==Visibility.Collapsed,"AI-off build hides unused experimental controls");
    }
}
