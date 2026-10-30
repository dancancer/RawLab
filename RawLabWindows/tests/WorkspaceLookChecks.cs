using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using RawLab.Windows;

internal static class WorkspaceLookChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(MainWindow window,string name)=>(T)typeof(MainWindow).GetField(name,Private)!.GetValue(window)!;
    private static void Set(MainWindow window,string name,object value)=>typeof(MainWindow).GetField(name,Private)!.SetValue(window,value);
    private static object? Invoke(MainWindow window,string name,params object[] args)=>typeof(MainWindow).GetMethod(name,Private)!.Invoke(window,args);
    private static void Ready(MainWindow window)=>InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        var output=Path.Combine(Path.GetFullPath(repo),".cache","tmp","workspace-looks",Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);var source=Path.Combine(output,"source.dng");File.Copy(raw,source);
        var app=TestWindowState.CreateApplication();SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        var window=new MainWindow();TestWindowState.Isolate(window,output);
        var storePath=Path.Combine(output,"edits");var store=new EditStore(storePath);Set(window,"editStore",store);
        try {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(source);Ready(window);
            foreach(var language in new[]{"en","de"}) {
                Loc.SetPreference(language,Path.Combine(output,"language.txt"));foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
                var surface=EditorShellChecks.ArrangeLayout(window,new Size(1024,720));
                Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);window.UpdateLayout();
                check(window.LibraryPanel.Visibility==Visibility.Collapsed && Math.Abs(window.AdjustmentPanel.ActualHeight-220)<1,
                    "Narrow empty workspace uses automatic 220 DIP single-value panel: "+language);
                check(window.PhotoArea.ActualWidth>=500 && window.PhotoArea.ActualHeight>=300,"Actual WPF photo area retains at least 500x300 DIP: "+language);
                check(window.HistogramSurface.ActualWidth<=48 && window.HistogramPanel.Parent==window.HistogramPopupContent,"Small canvas uses native histogram popup: "+language);
                window.HistogramButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));window.UpdateLayout();
                check(window.HistogramPopup.IsOpen && window.Histogram.IsVisible,"Compact histogram opens full native content");window.HistogramPopup.IsOpen=false;
                EditorShellChecks.CaptureLayout(window,surface,Path.Combine(output,"exposure-"+language+".png"));
            }
            var layout=Get<WorkspaceLayout>(window,"workspaceLayout");layout.Resize(270,window.EditorArea.ActualHeight);
            Invoke(window,"SelectTool",EditorAdjustmentTool.Hsl);window.UpdateLayout();
            check(Math.Abs(window.AdjustmentPanel.ActualHeight-270)<1 && window.PanelAutomatic.IsVisible,"Manual panel height persists across complex tool changes");
            window.PanelAutomatic.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));window.UpdateLayout();
            check(Math.Abs(window.AdjustmentPanel.ActualHeight-344)<1 && !window.PanelAutomatic.IsVisible,"Restore automatic gives complex controls their own height");
            window.LibraryToggleButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));window.UpdateLayout();
            EditorShellChecks.ArrangeLayout(window,new Size(1100,760));EditorShellChecks.ArrangeLayout(window,new Size(1024,720));
            check(window.LibraryPanel.Visibility==Visibility.Visible,"Manual file tree choice survives resizing");
            window.LibraryToggleButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Invoke(window,"SelectTool",EditorAdjustmentTool.Film);window.UpdateLayout();
            var edits=Get<Adjustments>(window,"settings");edits.Set(Parameter.Exposure,.1);Invoke(window,"MarkEdited");
            var acros=Path.Combine(AppContext.BaseDirectory,"LUTs","FLog2_to_ACROS_65grid_V.1.00.cube");
            check(File.Exists(acros),"Native test uses bundled ACROS asset");
            window.LookSearch.Text="acros";window.UpdateLayout();
            var choices=Get<Dictionary<string,Button>>(window,"filmButtons");
            check(choices.Count==1 && choices.ContainsKey(acros),"Case-insensitive search narrows the live native list");
            using(var held=new FileStream(Path.Combine(storePath,"edits.json"),FileMode.Open,FileAccess.Read,FileShare.Read)) {
                choices[acros].RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                check(Get<RecentLooks>(window,"recentLooks").IDs.Count==0 && window.RetrySave.IsVisible,"Failed look save is excluded from Recent");
            }
            Invoke(window,"SaveEdits");Ready(window);
            var recent=Get<RecentLooks>(window,"recentLooks");
            check(recent.IDs.SequenceEqual(new[]{"builtin:"+Path.GetFileName(acros)}),"Successful retry records the stable built-in identity once");
            var saved=store.VersionedState(source);window.LookSearch.Text="no matching look";window.UpdateLayout();
            check(window.LookEmpty.IsVisible && window.LookImport.IsVisible && window.LookImport.IsEnabled && store.VersionedState(source).SameAs(saved),
                "Empty search retains the committed look and fixed import action");
            window.LookEmptyAction.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            window.LookCategory.SelectedIndex=(int)LookBrowserCategory.Recent;window.UpdateLayout();
            check(Get<Dictionary<string,Button>>(window,"filmButtons").Keys.SequenceEqual(new[]{acros}),"Recent filters only the successfully saved look");
            Invoke(window,"LoadRecentLooks");check(Get<RecentLooks>(window,"recentLooks").IDs.SequenceEqual(recent.IDs),"Recent preferences survive reload independently of photo data");
            var final=EditorShellChecks.ArrangeLayout(window,new Size(1024,720));
            check(window.LookImport.TransformToAncestor(window).Transform(new Point(window.LookImport.ActualWidth,window.LookImport.ActualHeight)).X<=window.ActualWidth,
                "Fixed import action stays inside narrow native window");
            EditorShellChecks.CaptureLayout(window,final,Path.Combine(output,"recent-de.png"));
            Invoke(window,"SelectTool",EditorAdjustmentTool.MasterRecipe);window.UpdateLayout();
            var recipes=Get<Dictionary<string,Button>>(window,"recipeButtons");
            recipes.Values.Last().RaiseEvent(new RoutedEventArgs(Button.ClickEvent));Ready(window);
            check(Get<Dictionary<string,TextBlock>>(window,"recipeSelectionMarkers").Values.Count(marker=>marker.Visibility==Visibility.Visible)==1,
                "Applied recipe has one visible non-color selection mark");
            var recipeSurface=EditorShellChecks.ArrangeLayout(window,new Size(1024,720));
            EditorShellChecks.CaptureLayout(window,recipeSurface,Path.Combine(output,"recipe-selected-de.png"));
            var lens=new LensPanel();
            lens.Refresh(new LensSettings(Distortion:true),new LensInfo(6,"","",false,false,1,[new("fixture","Fixture","24mm",false,false,true)]));
            var distortion=(CheckBox)lens.FindName("Distortion");var tca=(CheckBox)lens.FindName("Tca");
            check(distortion.IsEnabled && !tca.IsEnabled && !string.IsNullOrEmpty(System.Windows.Automation.AutomationProperties.GetHelpText(tca)),
                "Unavailable lens calibration explains why while retained correction can be disabled");
            distortion.IsChecked=false;check(!distortion.IsEnabled,"Turning off a retained unavailable correction prevents re-enabling it");
            Console.WriteLine("Workspace artifacts: "+output);
        } finally {window.Close();app.Shutdown();}
    }
}
