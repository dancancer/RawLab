using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
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
            EditorAdjustmentTool.Clarity,EditorAdjustmentTool.Denoise,EditorAdjustmentTool.Geometry};
        check(window.Groups.Children.OfType<Button>().Select(AutomationProperties.GetAutomationId).SequenceEqual(groupIds.Select(id=>"editor.group."+id)),
            "Six persistent groups have stable ordered IDs");
        Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);
        var snapshot=Get<Adjustments>(window,"settings").Capture();var revision=Get<long>(window,"editRevision");
        window.HslEditor.SelectChannel(6);
        foreach(var (group,index) in Enum.GetValues<EditorAdjustmentGroup>().Select((group,index)=>(group,index))) {
            // Repeated group clicks collapse; the next click selects the descriptor default.
            Invoke(window,"SelectTool",defaults[index]);Invoke(window,"SelectGroup",group);window.UpdateLayout();
            check(window.ToolsScroller.Visibility==Visibility.Collapsed && window.Groups.IsVisible,"Repeated click collapses content but retains group navigation: "+group);
            Invoke(window,"SelectGroup",group);window.UpdateLayout();
            check((EditorAdjustmentTool)typeof(MainWindow).GetProperty("CurrentTool",Private)!.GetValue(window)! ==defaults[index],"Group opens its default tool: "+group);
            var expectedTools=group==EditorAdjustmentGroup.Geometry ? new[]{"Geometry","Perspective","Lens"}
                : EditorAdjustmentRules.Tools(group).Select(tool=>tool.ToString());
            check(window.Tools.Children.OfType<Button>().Where(button=>button.Visibility==Visibility.Visible)
                .Select(AutomationProperties.GetAutomationId).SequenceEqual(expectedTools),
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
        var preferencePath=Path.Combine(output,"workspace-language.txt");
        try {
            foreach(var language in new[]{"de","zh-Hans","en","fr","ja","es"})foreach(var size in new[]{new Size(1024,720),new Size(1440,920)})foreach(var font in new[]{13.0,26.0}) {
                // 与设置入口一样触发 Changed，刷新已创建控件；语言偏好只写测试目录。
                Loc.SetPreference(language,preferencePath);foreach(var pair in Loc.Strings)Application.Current.Resources[pair.Key]=pair.Value;
                window.FontSize=font;
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
                FrameworkElement? presenter=reset;
                while(presenter!=null && presenter is not ScrollContentPresenter)presenter=VisualTreeHelper.GetParent(presenter) as FrameworkElement;
                Console.WriteLine("Workspace layout "+JsonSerializer.Serialize(new {
                    language,size.Width,size.Height,window.FontSize,dock=window.AdjustmentPanel.ActualHeight,
                    rows=((Grid)window.DockHeader.Parent).RowDefinitions.Select(row=>row.ActualHeight),
                    header=window.DockHeader.ActualHeight,headerDesired=window.DockHeader.DesiredSize,
                    hslVisible=window.HslSurface.IsVisible,hsl=window.HslSurface.ActualHeight,
                    window.HslSurface.ViewportHeight,window.HslSurface.ExtentHeight,window.HslSurface.VerticalOffset,window.HslSurface.ScrollableHeight,
                    resetVisible=reset.IsVisible,resetSize=reset.RenderSize,
                    resetBounds=reset.TransformToAncestor(window.HslSurface).TransformBounds(new Rect(reset.RenderSize)),resetCenter=last.Y,
                    presenterSize=presenter?.RenderSize,presenterBounds=presenter==null ? (Rect?)null : reset.TransformToAncestor(presenter).TransformBounds(new Rect(reset.RenderSize))
                }));
                var before=EditorShellChecks.ArrangeLayout(window,size);
                EditorShellChecks.CaptureLayout(window,before,Path.Combine(output,$"workspace-hsl-{language}-{size.Width}-{font}.png"));
                EditorShellChecks.ArrangeLayout(window,size);window.HslSurface.ScrollToBottom();window.UpdateLayout();
                try {
                    var resetBounds=presenter==null ? Rect.Empty : reset.TransformToAncestor(presenter).TransformBounds(new Rect(reset.RenderSize));
                    check(presenter!=null && presenter.ActualHeight>=reset.ActualHeight && resetBounds.Top>=-.5 && resetBounds.Bottom<=presenter.ActualHeight+.5,
                        "Complete last HSL action remains reachable through internal scrolling: "+language+"/"+size);
                    PhotoFeatureChecks.Click(window.ProcessingSettingsButton);
                    InteractionChecks.PumpUntil(()=>window.EditorContextScroller.IsVisible);
                    foreach(var control in new FrameworkElement[]{window.ProcessingVersion,window.ExposureMode,window.AsShotButton}) {
                        control.BringIntoView();window.UpdateLayout();
                        var contextViewport=PhotoFeatureChecks.Descendants<ScrollContentPresenter>(window.EditorContextScroller).First();
                        var bounds=control.TransformToAncestor(contextViewport).TransformBounds(new Rect(control.RenderSize));
                        check(bounds.Left>=-.5 && bounds.Right<=contextViewport.ActualWidth+.5 && bounds.Top>=-.5 && bounds.Bottom<=contextViewport.ActualHeight+.5,
                            "Context control remains fully reachable: "+control.Name+"/"+language+"/"+size);
                    }
                    window.EditorContextScroller.ScrollToTop();window.ProcessingPopup.IsOpen=false;window.UpdateLayout();
                    CheckHistogramStatistics(window,language,size,check);
                } finally {
                    // 断言失败也保留对应截图，尺寸检查仍在拍摄重排之前执行。
                    var surface=EditorShellChecks.ArrangeLayout(window,size);
                    EditorShellChecks.CaptureLayout(window,surface,Path.Combine(output,$"workspace-hsl-{language}-{size.Width}-{font}.png"));
                }
            }
        } finally {window.FontSize=originalFont;Loc.SetPreference(previous,preferencePath);foreach(var pair in Loc.Strings)Application.Current.Resources[pair.Key]=pair.Value;}
        Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);
        WorkspaceParameterChecks.Run(window,output,check);
    }
    private static void CheckHistogramStatistics(MainWindow window,string language,Size size,Action<bool,string> check)
    {
        var text=window.ClipStats;var clipped=new List<string>();var reachedContent=false;
        for(var parent=VisualTreeHelper.GetParent(text) as FrameworkElement;parent!=null && parent!=window;
            parent=VisualTreeHelper.GetParent(parent) as FrameworkElement) {
            var bounds=text.TransformToAncestor(parent).TransformBounds(new Rect(text.RenderSize));
            if(bounds.Left<-.5 || bounds.Top<-.5 || bounds.Right>parent.ActualWidth+.5 || bounds.Bottom>parent.ActualHeight+.5)
                clipped.Add($"{parent.Name}/{parent.GetType().Name}: text={bounds}, parent={parent.RenderSize}");
            // ArrangeLayout 验证的内容可大于 CI 桌面的 HWND；边界止于同一绘制目标。
            if(ReferenceEquals(parent,window.Content)){reachedContent=true;break;}
        }
        check(reachedContent && text.IsVisible && text.ActualHeight>0 && text.ActualHeight+.5>=text.DesiredSize.Height &&
            System.Windows.Controls.Primitives.LayoutInformation.GetLayoutClip(text)==null && clipped.Count==0,
            $"Histogram statistics fit every editor-content ancestor: {language}/{size}; "+string.Join("; ",clipped));
    }
}
