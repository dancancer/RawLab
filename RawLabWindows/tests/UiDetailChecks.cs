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
