using System.Globalization;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using RawLab.Windows;

internal static class StatusLayoutChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        try
        {
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"})
            {
                Loc.Initialize(language);foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
                var window=new MainWindow();
                var updates=new UpdateChecker("0.8.0",Path.Combine(output,Guid.NewGuid().ToString("N"),"updates.json")){Automatic=false};
                typeof(MainWindow).GetField("updates",BindingFlags.Instance|BindingFlags.NonPublic)!.SetValue(window,updates);
                TestWindowState.Isolate(window,output);window.Show();
                window.AdjustmentPanel.Visibility=window.AdjustmentSplitter.Visibility=Visibility.Visible;
                window.DockRow.Height=new GridLength(288);window.SplitterRow.Height=new GridLength(6);window.UpdateLayout();
                try
                {
                    foreach(var font in new[]{13.0,26.0})foreach(var size in new[]{new Size(1000,680),new Size(1440,920)})
                    {
                        window.FontSize=font;var surface=EditorShellChecks.ArrangeLayout(window,size);
                        window.DockRow.Height=new GridLength(window.DockRow.MaxHeight);window.UpdateLayout();
                        var bar=(FrameworkElement)((FrameworkElement)window.Status.Parent).Parent;
                        var before=Frame();
                        foreach(var state in new[]{"saved","retry","export","batch","render-error","all","empty"})
                        {
                            window.SaveState.Text=state is "saved" or "retry" ? Loc.Text(state=="saved" ? "调整已保存" : "无法保存调整") : "";
                            window.RetrySave.Visibility=state is "retry" or "all" ? Visibility.Visible : Visibility.Collapsed;
                            window.ExportRevealButton.Visibility=state is "export" or "all" ? Visibility.Visible : Visibility.Collapsed;
                            window.BatchNotice.Visibility=state is "batch" or "all" ? Visibility.Visible : Visibility.Collapsed;
                            window.RetryButton.Visibility=state is "render-error" or "all" ? Visibility.Visible : Visibility.Collapsed;
                            window.UpdateLayout();var after=Frame();
                            Console.WriteLine($"Status layout {language}/{font}/{size}/{state}: {before} -> {after}");
                            check(Math.Abs(before.Bar-after.Bar)<.5 && Math.Abs(before.Editor-after.Editor)<.5 && Math.Abs(before.Dock-after.Dock)<.5 && Math.Abs(before.Canvas-after.Canvas)<.5,
                                $"Status notification retains bar/editor/dock/canvas frame: {language}/{font}/{size}/{state}");
                            var controls=new FrameworkElement[]{window.GpuMode,window.RetrySave,window.ExportRevealButton,window.BatchNotice,window.RetryButton};
                            check(controls.Where(control=>control.Visibility==Visibility.Visible).All(control=>
                            {
                                var bounds=control.TransformToAncestor(bar).TransformBounds(new Rect(control.RenderSize));
                                var slot=System.Windows.Controls.Primitives.LayoutInformation.GetLayoutSlot(control);
                                return bounds.Left>=-.5 && bounds.Right<=bar.ActualWidth+.5 && slot.Width+.5>=control.RenderSize.Width+control.Margin.Left+control.Margin.Right;
                            }),$"Status commands and GPU selector remain inside the footer: {language}/{font}/{size}/{state}");
                        }
                        var selected=((ComboBoxItem)window.GpuMode.SelectedItem).Content.ToString()!;
                        var text=new TextBlock{Text=selected,FontFamily=window.GpuMode.FontFamily,FontSize=window.GpuMode.FontSize,FontWeight=window.GpuMode.FontWeight};
                        TextOptions.SetTextFormattingMode(text,TextFormattingMode.Display);text.Measure(new Size(double.PositiveInfinity,double.PositiveInfinity));
                        Console.WriteLine($"GPU selector {language}/{font}: actual={window.GpuMode.ActualWidth}, label={text.DesiredSize.Width}, template margins=37");
                        check(window.GpuMode.ActualWidth+.5>=text.DesiredSize.Width+37,"GPU selector accommodates its localized text and arrow: "+language+"/"+font);
                        check(window.ResultCanvas.ActualHeight>=160,"Status layout retains minimum canvas: "+language+"/"+font);
                        if(font==26 && size.Width==1000 && language is "en" or "de")
                        {
                            window.RetrySave.Visibility=window.ExportRevealButton.Visibility=window.BatchNotice.Visibility=window.RetryButton.Visibility=Visibility.Visible;window.UpdateLayout();
                            EditorShellChecks.CaptureLayout(window,surface,Path.Combine(output,"status-"+language+"-large.png"));
                            window.RetrySave.Visibility=window.ExportRevealButton.Visibility=window.BatchNotice.Visibility=window.RetryButton.Visibility=Visibility.Collapsed;
                        }
                        (double Bar,double Editor,double Dock,double Canvas) Frame()=>(bar.ActualHeight,window.EditorArea.ActualHeight,window.DockRow.ActualHeight,window.ResultCanvas.ActualHeight);
                    }
                }
                finally{window.Close();}
            }
        }
        finally{app.Shutdown();}
    }
}
