using System.Reflection;
using System.Text.Json;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using System.Windows.Threading;
using RawLab.Windows;

internal static class Program
{
    private static int failures;
    private static string preferencePath = "";
    private static int changedCount;

    [STAThread]
    private static int Main(string[] args)=>Admit(BatchJournal.DefaultDirectory,()=>
    {
        if(args.Length==2 && args[0]=="--default-isolation"){AdmissionChecks.Run(args[1]);return 0;}
        if(args.Length!=0)throw new ArgumentException("Expected no arguments or --default-isolation <output>.");
        return RunUi();
    });

    internal static int Admit(string journalDirectory,Func<int> startup)
    {
        try{TestWindowState.PreserveExistingBatch(journalDirectory);return startup();}
        catch(Exception error){Console.Error.WriteLine(error);return 1;}
    }

    private static int RunUi()
    {
        try
        {
            var output=Path.Combine(Path.GetTempPath(),"rawlab-localization-"+Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(output);preferencePath=Path.Combine(output,"language.txt");
            Console.WriteLine("Localization fixtures: "+output);
            Loc.SetPreference("en",preferencePath);

            var app = new App();
            app.InitializeComponent();
            EventManager.RegisterClassHandler(typeof(MainWindow),FrameworkElement.LoadedEvent,new RoutedEventHandler((sender,_)=>
                TestWindowState.Isolate((MainWindow)sender,output)));
            app.Startup += (_, _) =>
            {
                Loc.Initialize(null,preferencePath);
                ((Action?)typeof(Loc).GetField("Changed",BindingFlags.Static|BindingFlags.NonPublic)!.GetValue(null))?.Invoke();
                Loc.Changed += LanguageChanged;
                app.Dispatcher.BeginInvoke(DispatcherPriority.ApplicationIdle,new Action(() => RunStartupChecks(app)));
            };
            app.Run();
        }
        catch (Exception error)
        {
            Fail(error.ToString());
        }
        finally
        {
            Loc.Changed -= LanguageChanged;
        }

        Console.WriteLine($"RESULT: {(failures == 0 ? "PASS" : "FAIL")} failures={failures} changed={changedCount}");
        return failures == 0 ? 0 : 1;
    }

    private static void LanguageChanged() => changedCount++;

    private static void RunStartupChecks(App app)
    {
        try
        {
            var window = Application.Current.Windows.OfType<MainWindow>().FirstOrDefault()
                ?? throw new InvalidOperationException("Application startup did not create the editor window.");

            Check(Loc.Language == "en", "Startup test window uses its persisted private English preference");
            var updates=(UpdateChecker)typeof(MainWindow).GetField("updates",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(window)!;
            var updatePath=(string)typeof(UpdateChecker).GetField("settingsPath",BindingFlags.Instance|BindingFlags.NonPublic)!.GetValue(updates)!;
            Check(!updates.Automatic && updatePath.StartsWith(Path.GetDirectoryName(preferencePath)!+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase),
                "Production StartupUri window receives private updates before its Loaded handler");
            Check(Application.Current.Resources["暗角"]?.ToString() == Loc.Text("暗角"), "Application resources contain the active catalog");

            var settingsField = typeof(MainWindow).GetField("settings", BindingFlags.NonPublic | BindingFlags.Instance)
                ?? throw new InvalidOperationException("Editor settings field is missing.");
            var adjustments = (Adjustments)settingsField.GetValue(window)!;
            adjustments.ApplyMasterRecipe(MasterRecipe.All[0]);
            adjustments.Set(Parameter.Exposure, 1.25);
            adjustments.Hsl = adjustments.Hsl.WithValue(0, 2, 19).WithValue(1, 2, -23);
            var effects = new PhotoEffectsSettings(-12, 42, 7, 63, 8, 17, 33, 71);
            adjustments.Effects = effects;
            adjustments.Lens = new LensSettings(true, true, true, true, "profile-id");
            adjustments.Geometry = new(.1, .2, .8, .7, 1, true, false, 3.5);
            var snapshot = JsonSerializer.Serialize(adjustments.Capture());
            var toolsBefore = (Panel)window.FindName("Tools");
            var effectButton = toolsBefore.Children.OfType<Button>()
                .First(button => AutomationProperties.GetAutomationId(button) == "Vignette");
            effectButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var effectPanel = (PhotoEffectsPanel?)window.FindName("PhotoEffectsEditor")
                ?? throw new InvalidOperationException("Photo effects panel is missing.");
            var lensPanel = (LensPanel?)window.FindName("LensEditor")
                ?? throw new InvalidOperationException("Lens panel is missing.");
            var geometryPanel = (GeometryPanel?)window.FindName("GeometryEditor")
                ?? throw new InvalidOperationException("Geometry panel is missing.");
            var lensInfo = new LensInfo(1, "Maker Camera Lens", "24mm", true, true, 1.25f,
                [new LensCandidate("profile-id", "Maker", "24mm", true, true, true)]);
            var batchDirectory = Path.Combine(Path.GetTempPath(), "rawlab-localization-batch-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(batchDirectory);
            var batchJournal = new BatchJournal(Path.Combine(batchDirectory, "journal"));
            var batchJob = BatchJob.Create("source.ARW", adjustments.Capture(), null, "中性");
            batchJob.OutputDirectory = batchDirectory;
            var batch = new BatchExportWindow(batchJob, batchJournal);
            ((RadioButton)batch.FindName("Dng")!).IsChecked = true;
            var batchSnapshot = JsonSerializer.Serialize(batch.Job.Settings);
            var batchDestination = batch.Job.OutputDirectory;

            foreach (var language in new[] { "zh-Hans", "en", "de", "fr", "ja", "es" })
            {
                Loc.SetPreference(language,preferencePath);
                Pump();
                lensPanel.Refresh(adjustments.Lens, lensInfo);
                geometryPanel.Refresh(adjustments.Geometry);
                Check(Loc.Language == language, $"Resolved language {language}");
                foreach(var (name,key) in new[]{("AddDirectoryButton","添加目录"),("ExportRevealButton","在资源管理器中查看"),("BatchNotice","继续上次批量任务"),("RetrySave","重试保存"),("RetryButton","重试")})
                {
                    var button=(Button)window.FindName(name);
                    Check(UIElementAutomationPeer.CreatePeerForElement(button)?.GetName()==Loc.Text(key),$"Sidebar/status action has a localized automation name: {name}/{language}");
                }
                Check(File.ReadAllText(preferencePath).Trim() == language, $"Persisted preference {language}");
                Check(Application.Current.Resources["暗角"]?.ToString() == Loc.Text("暗角"), $"Dynamic catalog resource {language}");

                var groups=(Panel)window.FindName("Groups");
                Check(groups.Children.OfType<Button>().Select(AutomationProperties.GetName).SequenceEqual(
                    Enum.GetValues<EditorAdjustmentGroup>().Select(group=>Loc.Text(EditorAdjustmentRules.Title(group)))), $"Six group captions and accessibility names {language}");
                var tools = (Panel?)window.FindName("Tools");
                var vignette = tools?.Children.OfType<Button>()
                    .FirstOrDefault(button => AutomationProperties.GetAutomationId(button) == "Vignette");
                Check(vignette != null, $"Vignette tool exists {language}");
                Check(AutomationProperties.GetName(vignette) == Loc.Text("暗角"), $"Vignette automation name {language}");

                var hsl = (Button?)window.FindName("HslCategory");
                Check(hsl != null && AutomationProperties.GetName(hsl) == "HSL", $"HSL automation name {language}");

                var effectButtons = Descendants(effectPanel).OfType<Button>().ToArray();
                var reset = effectButtons
                    .FirstOrDefault(button => AutomationProperties.GetName(button) == Loc.Text("重置暗角强度"));
                Check(reset != null, $"Vignette reset automation name {language}");

                Check(Math.Abs(adjustments[Parameter.Exposure] - 1.25) < .0001, $"Exposure preserved {language}");
                Check(adjustments.Effects == effects, $"Photo effects preserved {language}");
                Check(adjustments.Geometry is { CropX: .1, QuarterTurns: 1, FlipHorizontal: true, StraightenDegrees: 3.5 },
                    $"Geometry survives language changes {language}");
                Check(AutomationProperties.GetName((CheckBox)geometryPanel.FindName("HorizontalFlip")!) == Loc.Text("水平翻转") &&
                      AutomationProperties.GetName((TextBox)geometryPanel.FindName("CropWidth")!) == Loc.Text("裁切宽度") &&
                      AutomationProperties.GetName((Slider)geometryPanel.FindName("StraightenSlider")!) == Loc.Text("拉直"),
                    $"Geometry controls have localized automation names {language}");
                Check(ReferenceEquals(settingsField.GetValue(window), adjustments), $"Editor settings identity preserved {language}");
                Check(JsonSerializer.Serialize(adjustments.Capture()) == snapshot, $"Recipe, HSL and editor snapshot preserved {language}");
                var hslPanel = (HslPanel)window.FindName("HslEditor");
                Check(Descendants(hslPanel).OfType<Slider>().Any(slider => AutomationProperties.GetName(slider) == Loc.Text("色相")),
                    $"HSL axis automation name {language}");

                Check(AutomationProperties.GetName((RadioButton)lensPanel.FindName("Automatic")!) == Loc.Text("镜头匹配") &&
                      AutomationProperties.GetName((RadioButton)lensPanel.FindName("Manual")!) == Loc.Text("选择镜头"),
                    $"Lens mode automation names {language}");
                var expectedLensMode = language switch
                {
                    "zh-Hans" => "镜头匹配",
                    "en" => "Lens Matching",
                    "de" => "Objektivzuordnung",
                    "fr" => "Correspondance de l’objectif",
                    "ja" => "レンズの照合",
                    _ => "Coincidencia de lente"
                };
                Check(AutomationProperties.GetName((RadioButton)lensPanel.FindName("Automatic")!) == expectedLensMode,
                    $"Lens mode uses the {language} catalog value");
                Check(AutomationProperties.GetName((CheckBox)lensPanel.FindName("Distortion")!) == Loc.Text("畸变矫正") &&
                      AutomationProperties.GetName((CheckBox)lensPanel.FindName("Tca")!) == Loc.Text("横向色差") &&
                      AutomationProperties.GetName((CheckBox)lensPanel.FindName("AutoCrop")!) == Loc.Text("自动裁边"),
                    $"Lens correction automation names {language}");
                Check(((TextBlock)lensPanel.FindName("StatusText")!).Text ==
                      Loc.Format("已校正{0}", $"{Loc.Text("畸变")}{Loc.Text("、")}{Loc.Text("横向色差")}"),
                    $"Lens status is localized without translating assembled text {language}");
                var expectedCrop = language switch
                {
                    "zh-Hans" => "裁边 20.0%",
                    "en" => "Crop 20.0%",
                    "de" => "Beschnitt 20,0%",
                    "fr" => "Recadrage 20,0%",
                    "ja" => "クロップ 20.0%",
                    _ => "Recorte 20,0%"
                };
                var expectedCropNumber = language is "de" or "fr" or "es" ? "20,0" : "20.0";
                Check(((TextBlock)lensPanel.FindName("CropText")!).Text == expectedCrop &&
                      ((TextBlock)lensPanel.FindName("CropText")!).Text == Loc.Format("裁边 {0}%", expectedCropNumber),
                    $"Lens crop status uses one active-locale decimal {language}");
                Check(((TextBlock)lensPanel.FindName("SelectedTitle")!).Text == "Maker 24mm",
                    $"Native lens maker/model remains unchanged {language}");
                Check(batch.Job.Format == ExportFormat.RenderedDng && batch.Job.OutputDirectory == batchDestination &&
                      JsonSerializer.Serialize(batch.Job.Settings) == batchSnapshot &&
                      ((RadioButton)batch.FindName("Dng")!).Content?.ToString() == Loc.Text("DNG · 渲染型") &&
                      AutomationProperties.GetName((RadioButton)batch.FindName("Dng")!) == Loc.Text("DNG · 渲染型") &&
                      ((TextBlock)batch.FindName("AllSettings")!).Text.Contains(Loc.Text("镜头匹配"), StringComparison.Ordinal),
                    $"Batch format, destination and full settings preserved {language}");
            }

            Check(changedCount == 6, "Changed raised once for each language selection");
            batch.Close();
            try { Directory.Delete(batchDirectory, recursive: true); } catch (IOException) { }
            window.Close();
            app.Shutdown();
        }
        catch (Exception error)
        {
            Fail(error.ToString());
            app.Shutdown(1);
        }
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }

    private static void Pump()
    {
        var frame = new DispatcherFrame();
        Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) Fail(message);
        else Console.WriteLine($"PASS: {message}");
    }

    private static void Fail(string message)
    {
        failures++;
        Console.WriteLine($"FAIL: {message}");
    }

}
