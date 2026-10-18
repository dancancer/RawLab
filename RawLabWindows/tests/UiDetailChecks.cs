using System.IO;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Threading;
using RawLab.Windows;

// ┌─ 发布前界面细节回归：主窗口与对话框 ──────────────────────────────────────────────┐
// │ 不需要 RAW、native DLL 或网络；窗口用 TestWindowState 的私有配置。               │
// │ 每类细节问题一个检查方法；调整面板、对话框与图标形状的检查在 UiPanelChecks。     │
// └──────────────────────────────────────────────────────────────────────────────────┘
internal static class UiDetailChecks
{
    private const BindingFlags PrivateInstance=BindingFlags.Instance|BindingFlags.NonPublic;
    internal static readonly Regex Cjk=new("[㐀-鿿]");

    internal static void Run(string output,Action<bool,string> strict)
    {
        // 逐项记录失败、跑完全部语言再汇总，一次看清所有细节问题
        var failures=new List<string>();
        void check(bool success,string name){try{strict(success,name);}catch(Exception){failures.Add(name);}}
        try { RunAll(output,check); }
        finally { foreach(var failure in failures)Console.WriteLine("FAILED "+failure); }
        if(failures.Count>0)throw new Exception($"{failures.Count} UI detail checks failed");
    }

    private static void RunAll(string output,Action<bool,string> check)
    {
        TestWindowState.PreserveExistingBatch(BatchJournal.DefaultDirectory);
        Directory.CreateDirectory(output);
        var previous=Loc.Preference;
        Loc.Initialize("zh-Hans");
        var app=TestWindowState.CreateApplication();
        // 打开照片的异步续体回到界面线程，与产品里的 Dispatcher 同步上下文一致
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        try
        {
            foreach(var language in new[]{"zh-Hans","en","de","fr","ja","es"})
            {
                Loc.Initialize(language);foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
                var window=new MainWindow();TestWindowState.Isolate(window,output);window.Show();window.UpdateLayout();
                try
                {
                    Icons(window,language,check);
                    ToolTips(window,language,check);
                    ActiveLook(window,language,check);
                    TypeNames(window,output,language,check);
                    IdleStatus(window,check);
                    Selection(window,language,check);
                    MenuPlacement(window,check);
                    CopyCompletionChecks.Run(window,language,check);
                    ResetMenus(window,language,check);
                    LibraryHint(window,output,language,check);
                    FailedOpen(window,output,language,check);
                    AboutFooter(window,output,check);
                    ToolCaptions(window,language,check);
                    WholeText(window,language,check);
                }
                finally { window.Close(); }
                UiPanelChecks.Run(output,language,check);
            }
        }
        finally { Loc.Initialize(previous);app.Shutdown(); }
    }

    // 工具栏、工具条与“自动”按钮：每个功能一个图标，不能两个按钮长得一样
    private static void Icons(MainWindow window,string language,Action<bool,string> check)
    {
        var buttons=Descendants(Toolbar(window)).OfType<Button>().Concat(window.Tools.Children.OfType<Button>()).Append(window.AutoExposureButton)
            .Select(button=>(Name:AutomationProperties.GetName(button),Icon:Descendants(button).OfType<EditorIcon>().FirstOrDefault()))
            .Where(item=>item.Icon!=null).ToList();
        var repeated=buttons.GroupBy(item=>item.Icon!.Kind).Where(group=>group.Count()>1)
            .Select(group=>"\n  "+group.Key+": "+string.Join(" / ",group.Select(item=>item.Name))).ToList();
        check(buttons.Count>=25 && repeated.Count==0,$"Toolbar and adjustment tools use distinct icons ({language}){string.Concat(repeated)}");
    }
    // 中文提示不夹英文；配方名与“中性”按界面语言显示
    private static void ToolTips(MainWindow window,string language,Action<bool,string> check)
    {
        if(language!="zh-Hans")return;
        var tips=window.Tools.Children.OfType<Button>().Where(button=>button.ToolTip is string tip &&
            Regex.IsMatch(tip,"[A-Za-z]") && !Regex.IsMatch(Caption(button),"[A-Za-z]")).Select(button=>"\n  "+button.ToolTip).ToList();
        check(tips.Count==0,"Chinese tool tooltips carry no English words"+string.Concat(tips));
    }
    private static void ActiveLook(MainWindow window,string language,Action<bool,string> check)
    {
        var recipe=MasterRecipe.All.First(item=>Cjk.IsMatch(item.Name));
        var settings=(Adjustments)typeof(MainWindow).GetField("settings",PrivateInstance)!.GetValue(window)!;
        var lut=typeof(MainWindow).GetField("lut",PrivateInstance)!;
        settings.ApplyMasterRecipe(recipe);lut.SetValue(window,recipe.LutPath);Refresh(window);
        check(window.ActiveFilm.Text==Loc.Text(recipe.Name) && window.FilmLabelText.Text==Loc.Text(recipe.Name),
            $"Active look and comparison label show the recipe name in {language}: {window.ActiveFilm.Text} / {window.FilmLabelText.Text}");
        settings.ClearMasterRecipe();lut.SetValue(window,null);Refresh(window);
        check(window.ActiveFilm.Text==Loc.Text("中性"),$"Neutral look is named in {language}: {window.ActiveFilm.Text}");
    }
    // 语言下拉框、文件树的读屏名称：显示名字，不显示记录或类的类型名
    private static void TypeNames(MainWindow window,string output,string language,Action<bool,string> check)
    {
        var expected=Loc.Choices.Single(choice=>choice.Code==language).NativeName;
        var settings=new SettingsWindow(0){Owner=window};settings.Show();settings.UpdateLayout();
        try { var box=Descendants(settings).OfType<ComboBox>().First();check(Shown(box)==expected,$"Settings language picker shows {expected}: {Shown(box)}"); }
        finally { settings.Close(); }
        var about=About(window,output);
        try { check(Shown(about.LanguageBox)==expected,$"About language picker shows {expected}: {Shown(about.LanguageBox)}"); }
        finally { about.Close(); }
        var folder=new LibraryEntry(Path.GetFullPath(output),true);
        window.Files.ItemsSource=new[]{folder};window.UpdateLayout();
        var names=UIElementAutomationPeer.CreatePeerForElement(window.Files)!.GetChildren()?.Select(child=>child.GetName()).ToList() ?? [];
        check(names.SequenceEqual(new[]{folder.Name}),"Folder tree items are announced by name: "+string.Join(" / ",names));
        var group=new PhotoGroup([new LibraryEntry(Path.Combine(output,"a.ARW"),false)]);
        check(group.ToString()==Loc.Text("照片"),"Photo group is announced as photos: "+group);
        window.Files.ItemsSource=Array.Empty<LibraryEntry>();window.UpdateLayout();
    }
    // 空闲状态栏既不重复也不违背旁边的 GPU 选择
    private static void IdleStatus(MainWindow window,Action<bool,string> check)
    {
        foreach(var index in new[]{0,1})
        {
            window.GpuMode.SelectedIndex=index;
            var mode=((ComboBoxItem)window.GpuMode.SelectedItem).Content.ToString()!;
            var other=((ComboBoxItem)window.GpuMode.Items[1-index]).Content.ToString()!;
            check(!window.BackendLabel.Text.Contains(mode,StringComparison.Ordinal) && !window.BackendLabel.Text.Contains(other,StringComparison.Ordinal),
                $"Idle status bar neither repeats nor contradicts the GPU selector: {window.BackendLabel.Text} / {mode}");
        }
        window.GpuMode.SelectedIndex=0;
    }
    private static void Selection(MainWindow window,string language,Action<bool,string> check)
    {
        Click(window.MasterRecipeCategory);
        check(Equals(window.MasterRecipeCategory.Tag,"selected") && window.FilmCategory.Tag==null,"Master recipe tool shows the selected state: "+language);
        Click(window.FilmCategory);
        check(window.MasterRecipeCategory.Tag==null && Equals(window.FilmCategory.Tag,"selected"),"Leaving master recipes clears its selected state: "+language);
    }
    // 工具栏下拉菜单贴着按钮弹出；键盘打开时不跟着鼠标跑到别处
    private static void MenuPlacement(MainWindow window,Action<bool,string> check)
    {
        foreach(var button in Descendants(Toolbar(window)).OfType<Button>().Where(button=>button.ContextMenu!=null))
        {
            Click(button);
            var menu=button.ContextMenu!;
            check(menu.IsOpen && menu.Placement==PlacementMode.Bottom && ReferenceEquals(menu.PlacementTarget,button),
                $"Toolbar menu opens under its button, not at the pointer: {AutomationProperties.GetName(button)} ({menu.Placement})");
            menu.IsOpen=false;
        }
    }
    // 编辑菜单与调整栏重置菜单：分组重置写成“重置…”，两处叫法一致
    private static void ResetMenus(MainWindow window,string language,Action<bool,string> check)
    {
        var edit=(MenuItem)window.MainMenu.Items[1];
        var editLabels=edit.Items.OfType<MenuItem>().Where(item=>item.Tag is string).Select(item=>(Group:(string)item.Tag,Header:(string)item.Header)).ToList();
        var unnamed=editLabels.Where(item=>item.Header!=Loc.Format("重置{0}",Loc.Text(item.Group=="输入" ? "输入调整" : item.Group))).Select(item=>"\n  "+item.Header).ToList();
        check(editLabels.Count==6 && unnamed.Count==0,"Edit menu names each group reset as a reset action: "+language+string.Concat(unnamed));
        Click(window.ResetAllButton);
        var reset=window.ResetAllButton.ContextMenu;
        var resetLabels=reset?.Items.OfType<MenuItem>().Where(item=>item.Tag is string).Select(item=>(string)item.Header).ToList() ?? [];
        check(resetLabels.SequenceEqual(editLabels.Select(item=>item.Header)),"Dock reset menu and Edit menu use the same group names: "+language);
        if(reset!=null)reset.IsOpen=false;
    }
    // 启动时从磁盘恢复的目录同样显示右键提示
    private static void LibraryHint(MainWindow window,string output,string language,Action<bool,string> check)
    {
        window.Files.ItemsSource=new[]{new LibraryEntry(Path.GetFullPath(output),true)};window.UpdateLayout();
        check(window.LibraryHint.Visibility==Visibility.Visible,"Folder hint follows restored library folders: "+language);
        window.Files.ItemsSource=Array.Empty<LibraryEntry>();window.UpdateLayout();
        check(window.LibraryHint.Visibility==Visibility.Collapsed,"Folder hint hides without folders: "+language);
    }
    // 打开失败：状态栏不再显示“正在显影”，也不留下空的直方图框
    private static void FailedOpen(MainWindow window,string output,string language,Action<bool,string> check)
    {
        var broken=Path.Combine(output,"broken-"+language+".ARW");File.WriteAllText(broken,"not a raw file");
        window.OpenFile(broken);
        var failed=typeof(MainWindow).GetField("renderFailed",PrivateInstance)!;
        Pump(()=>(bool)failed.GetValue(window)!,TimeSpan.FromSeconds(20));
        check((bool)failed.GetValue(window)! && window.BackendLabel.Text!=Loc.Text("相机预览 · 正在显影"),$"Failed open does not keep reporting development: {window.BackendLabel.Text}");
        check(window.HistogramSurface.Visibility!=Visibility.Visible,"Failed open leaves no empty histogram box: "+language);
    }
    // 关于窗口变矮时，“关闭”按钮仍完整可见，不随内容一起被截掉
    private static void AboutFooter(MainWindow window,string output,Action<bool,string> check)
    {
        var about=About(window,output);
        try
        {
            about.SizeToContent=SizeToContent.Manual;about.Height=420;about.UpdateLayout();
            var close=Descendants(about).OfType<Button>().Single(button=>button.IsCancel);
            var content=(FrameworkElement)about.Content;
            var bottom=close.TransformToAncestor(content).TransformBounds(new Rect(close.RenderSize)).Bottom;
            check(close.IsVisible && bottom<=content.ActualHeight+.5,$"About close button stays visible in a short window: {bottom:0} / {content.ActualHeight:0}");
        }
        finally { about.Close(); }
    }
    // 工具条：说明文字只在空格或连字符处换行，不把一个词拆成两行；图标保持同一高度
    private static void ToolCaptions(MainWindow window,string language,Action<bool,string> check)
    {
        BuildTools(window);window.AdjustmentPanel.Visibility=Visibility.Visible;window.DockRow.Height=new GridLength(288);window.UpdateLayout();
        var buttons=window.Tools.Children.OfType<Button>().ToList();
        var broken=buttons.Select(button=>Descendants(button).OfType<TextBlock>().Last()).Where(caption=>
            caption.ActualHeight>LineHeight(caption)*1.5 && !caption.Text.Any(c=>c is ' ' or '-'))
            .Select(caption=>"\n  "+caption.Text).ToList();
        check(broken.Count==0,"Tool captions never break inside a word: "+language+string.Concat(broken));
        var tops=buttons.Select(button=>Descendants(button).OfType<EditorIcon>().First()).Select(icon=>icon.TranslatePoint(new Point(),window.Tools).Y).ToList();
        check(tops.Max()-tops.Min()<.5,$"Tool icons stay on one line: {tops.Min():0.#}-{tops.Max():0.#} ({language})");
    }
    private static double LineHeight(TextBlock text)=>new System.Windows.Media.FormattedText("Ag",System.Globalization.CultureInfo.InvariantCulture,
        FlowDirection.LeftToRight,new System.Windows.Media.Typeface(text.FontFamily,text.FontStyle,text.FontWeight,text.FontStretch),text.FontSize,
        System.Windows.Media.Brushes.Black,1).Height;
    private static void BuildTools(MainWindow window)=>typeof(MainWindow).GetMethod("BuildTools",PrivateInstance)!.Invoke(window,null);
    // 直方图统计与曝光基准选择框：译文完整显示，不被硬生生截掉半个词
    private static void WholeText(MainWindow window,string language,Action<bool,string> check)
    {
        window.HistogramSurface.Visibility=Visibility.Visible;
        window.ClipStats.Text=Loc.Format("暗部 {0:P1}   高光 {1:P1} · 显示图统计",0.0,0.0);window.UpdateLayout();
        check(System.Windows.Controls.Primitives.LayoutInformation.GetLayoutClip(window.ClipStats)==null,$"Histogram statistics are not clipped: {window.ClipStats.Text}");
        window.HistogramSurface.Visibility=Visibility.Collapsed;
        // 选中项的文字在框内完整排下：用 WPF 自己的布局裁切判断，与屏幕缩放无关
        window.AdjustmentPanel.Visibility=Visibility.Visible;window.UpdateLayout();
        var shown=Visuals(window.ExposureMode).OfType<TextBlock>().First();
        check(System.Windows.Controls.Primitives.LayoutInformation.GetLayoutClip(shown)==null,
            $"Exposure baseline selector shows its choice whole: {shown.Text} {shown.ActualWidth:0}/{shown.DesiredSize.Width:0} ({language})");
    }

    private static AboutWindow About(MainWindow window,string output)
    {
        var root=Path.Combine(output,"about-"+Guid.NewGuid().ToString("N")[..8]);Directory.CreateDirectory(root);
        var updates=new UpdateChecker("0.8.0",Path.Combine(root,"updates.json")){Automatic=false};
        var usage=new UsageAnalytics(Path.Combine(root,"usage.json"),new UnavailableUsageAnalyticsTransport());
        var about=new AboutWindow(updates,usage){Owner=window};about.Show();about.UpdateLayout();
        return about;
    }
    private static void Refresh(MainWindow window)=>typeof(MainWindow).GetMethod("RefreshControls",PrivateInstance)!.Invoke(window,null);
    internal static FrameworkElement Toolbar(MainWindow window)=>(FrameworkElement)((FrameworkElement)window.OpenPhoto.Parent).Parent;
    internal static void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static string Caption(Button button)=>string.Concat(Descendants(button).OfType<TextBlock>().Select(text=>text.Text));
    private static string Shown(ComboBox box)=>string.Concat(Visuals(box).OfType<TextBlock>().Select(text=>text.Text));
    private static void Pump(Func<bool> done,TimeSpan timeout)
    {
        var deadline=DateTime.UtcNow+timeout;
        while(!done() && DateTime.UtcNow<deadline)
        {
            var frame=new DispatcherFrame();
            var timer=new DispatcherTimer(DispatcherPriority.Background){Interval=TimeSpan.FromMilliseconds(30)};
            timer.Tick+=(_,_)=>{timer.Stop();frame.Continue=false;};timer.Start();Dispatcher.PushFrame(frame);
        }
    }
    internal static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach(var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            yield return child;
            foreach(var descendant in Descendants(child))yield return descendant;
        }
    }
    private static IEnumerable<DependencyObject> Visuals(DependencyObject root)
    {
        for(var i=0;i<System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);i++)
        {
            var child=System.Windows.Media.VisualTreeHelper.GetChild(root,i);
            yield return child;
            foreach(var descendant in Visuals(child))yield return descendant;
        }
    }
}
