using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using RawLab.Windows;

internal static class WorkspaceGroupChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(MainWindow window,string name)=>(T)typeof(MainWindow).GetField(name,Private)!.GetValue(window)!;
    private static object? Invoke(MainWindow window,string name,params object[] args)=>typeof(MainWindow).GetMethod(name,Private)!.Invoke(window,args);
    internal static void Run(MainWindow window,string output,Action<bool,string> check)
    {
        var groupIds=new[]{"looks","light","color","effects","detail","geometry"};
        var defaults=new[]{EditorAdjustmentTool.Film,EditorAdjustmentTool.Exposure,EditorAdjustmentTool.WhiteBalance,
            EditorAdjustmentTool.Vignette,EditorAdjustmentTool.Denoise,EditorAdjustmentTool.Geometry};
        check(window.Groups.Children.OfType<Button>().Select(AutomationProperties.GetAutomationId).SequenceEqual(groupIds.Select(id=>"editor.group."+id)),
            "Six persistent groups have stable ordered IDs");
        Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);
        var snapshot=Get<Adjustments>(window,"settings").Capture();var revision=Get<long>(window,"editRevision");
        window.HslEditor.SelectChannel(6);
        foreach(var (group,index) in Enum.GetValues<EditorAdjustmentGroup>().Select((group,index)=>(group,index))) {
            // Repeated group clicks collapse; the next click selects the descriptor default.
            Invoke(window,"SelectTool",defaults[index]);Invoke(window,"SelectGroup",group);window.UpdateLayout();
            check(window.DockHeader.Visibility==Visibility.Collapsed && window.Groups.IsVisible,"Repeated click collapses content but retains group navigation: "+group);
            Invoke(window,"SelectGroup",group);window.UpdateLayout();
            check((EditorAdjustmentTool)typeof(MainWindow).GetProperty("CurrentTool",Private)!.GetValue(window)! ==defaults[index],"Group opens its default tool: "+group);
            check(window.Tools.Children.OfType<Button>().Where(button=>button.Visibility==Visibility.Visible)
                .Select(AutomationProperties.GetAutomationId).SequenceEqual(EditorAdjustmentRules.Tools(group).Select(tool=>tool.ToString())),
                "Group renders only its own tools in descriptor order: "+group);
        }
        Invoke(window,"SelectTool",EditorAdjustmentTool.Hsl);
        check(window.HslEditor.SelectedChannel==6 && Get<long>(window,"editRevision")==revision && Get<Adjustments>(window,"settings").Capture().SameAs(snapshot),
            "Group and tool navigation preserves HSL channel, processing identity and all edits without writes");
        Invoke(window,"ResetMenuClicked",window.ResetAllButton,new RoutedEventArgs());
        var menu=window.ResetAllButton.ContextMenu;
        check(menu.Items.OfType<MenuItem>().Select(item=>((EditorResetScope)item.Tag).Kind).SequenceEqual(new[]{
            EditorResetKind.HslChannel,EditorResetKind.AllHsl,EditorResetKind.Group,EditorResetKind.All}),
            "Production HSL menu orders current color, all HSL, color group and All");
        check(menu.Items.OfType<MenuItem>().First().Header.ToString()!.Contains(window.HslEditor.SelectedChannelName),"HSL current-color reset includes its selected color name");
        menu.IsOpen=false;
        var state=Get<Adjustments>(window,"settings");
        state.Hsl=state.Hsl.WithValue(0,6,.12345).WithValue(1,1,.33333);
        var beforeChannel=state.Capture();var channelRevision=Get<long>(window,"editRevision");
        Invoke(window,"RequestReset",new EditorResetScope(EditorResetKind.HslChannel,Channel:6));
        var afterChannel=Get<Adjustments>(window,"settings").Capture();
        var expectedChannel=beforeChannel.Hsl!;for(var axis=0;axis<3;axis++)expectedChannel=expectedChannel.WithValue(axis,6,0);
        check(afterChannel.SameAs(beforeChannel with{Hsl=expectedChannel}) && afterChannel.Hsl!.Value(1,1)==.33333 &&
            window.HslEditor.SelectedChannel==6 && Get<long>(window,"editRevision")==channelRevision+1,
            "Production current-color reset makes one edit and preserves sibling precision, tool and channel");
        Invoke(window,"RequestReset",new EditorResetScope(EditorResetKind.HslChannel,Channel:6));
        check(Get<long>(window,"editRevision")==channelRevision+1,"Repeated production color reset is a zero-edit NoChange");
        InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
        var previous=Loc.Preference;var originalFont=window.FontSize;
        try {
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"})foreach(var size in new[]{new Size(1024,720),new Size(1440,920)}) {
                Loc.Initialize(language);foreach(var pair in Loc.Strings)Application.Current.Resources[pair.Key]=pair.Value;
                window.FontSize=language=="de" ? 26 : originalFont;
                EditorShellChecks.ArrangeLayout(window,size);window.UpdateLayout();
                var boundary=window.AdjustmentPanel.TransformToAncestor(window).Transform(new Point()).Y;
                var height=window.AdjustmentPanel.ActualHeight;
                foreach(var tool in Enum.GetValues<EditorAdjustmentTool>()) {
                    Invoke(window,"SelectTool",tool);window.UpdateLayout();
                    check(Math.Abs(window.AdjustmentPanel.ActualHeight-height)<1 &&
                        Math.Abs(window.AdjustmentPanel.TransformToAncestor(window).Transform(new Point()).Y-boundary)<1,
                        $"Tool content never resizes the photo/dock boundary: {language}/{size}/{tool}");
                }
                Invoke(window,"SelectTool",EditorAdjustmentTool.Hsl);window.UpdateLayout();
                check(window.Groups.Children.OfType<Button>().Select(AutomationProperties.GetName)
                    .SequenceEqual(Enum.GetValues<EditorAdjustmentGroup>().Select(group=>Loc.Text(EditorAdjustmentRules.Title(group)))),
                    "All group captions/accessibility names use the selected language: "+language);
                check(window.HslEditor.SelectedChannel==6,"Language and layout retain session HSL channel: "+language);
                window.HslSurface.ScrollToBottom();window.UpdateLayout();
                var reset=PhotoFeatureChecks.Descendants<Button>(window.HslEditor).Single(button=>Equals(button.Content,Loc.Text("重置 HSL")));
                var last=reset.TransformToAncestor(window.HslSurface).Transform(new Point(0,reset.ActualHeight/2));
                check(last.Y>=0 && last.Y<=window.HslSurface.ActualHeight,"Last HSL action remains reachable through internal scrolling: "+language+"/"+size);
                var surface=EditorShellChecks.ArrangeLayout(window,size);
                EditorShellChecks.CaptureLayout(window,surface,Path.Combine(output,$"workspace-hsl-{language}-{size.Width}.png"));
            }
        } finally {window.FontSize=originalFont;Loc.Initialize(previous);foreach(var pair in Loc.Strings)Application.Current.Resources[pair.Key]=pair.Value;}
        Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);
    }
}
