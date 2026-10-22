using System.Diagnostics;
using System.Windows.Automation;
using System.Windows.Automation.Provider;

internal static class Program
{
    private static readonly TimeSpan TotalTimeout = TimeSpan.FromMinutes(8);

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length != 6) throw new ArgumentException(
                "Expected <host-pid> <profile> <raw> <png> <jpeg> <first|restart>.");
            var context = new DriverContext(
                int.Parse(args[0]), args[1], args[2], args[3], args[4], args[5]);
            return context.Run();
        }
        catch (NotReachedException error)
        {
            Console.WriteLine("NOT REACHED " + error.Message);
            return 2;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private sealed class DriverContext
    {
        private readonly int hostPid;
        private readonly string profile, raw, png, jpeg, phase;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private AutomationElement root = null!;
        private AutomationElement main = null!;

        internal DriverContext(int hostPid, string profile, string raw, string png, string jpeg, string phase)
        {
            this.hostPid = hostPid;
            this.profile = profile;
            this.raw = raw;
            this.png = png;
            this.jpeg = jpeg;
            this.phase = phase;
        }

        internal int Run()
        {
            Trace("started");
            root = AutomationElement.RootElement;
            main = WaitForMainWindow();
            Trace("main-window");
            WaitMode("off",false);
            Check(true,"A fresh native window exposes single mode before a photo is opened");
            if (phase.Equals("restart", StringComparison.OrdinalIgnoreCase))
            {
                OpenPhoto(raw);
                WaitMode("off");
                var value = GetRangeValue("ParameterValueSlider");
                Check(Math.Abs(value - 1.25) < .02, "Restarted profile restores RAW exposure history");
                CloseMainWindow();
                return 0;
            }

            OpenPhoto(raw);
            WaitMode("off");
            SelectMode("side");
            WaitReady();
            WaitBusyThenReady(() => SetRangeValue("ParameterValueSlider", 1));
            WaitMode("side");
            SelectMode("swipe");
            WaitReady();
            WaitBusyThenReady(() =>
            {
                SetRangeValue("ResultCanvas", 35);
                SetRangeValue("ParameterValueSlider", 1.25);
            });
            WaitMode("swipe");
            Check(Math.Abs(GetRangeValue("ResultCanvas") - 35)<.01,
                "Async exposure preserves the native swipe divider");

            OpenPhoto(png);
            WaitMode("off");
            OpenPhoto(jpeg);
            WaitMode("off");
            OpenPhoto(raw);
            WaitMode("off");
            Check(Math.Abs(GetRangeValue("ParameterValueSlider") - 1.25) < .02,
                "Same-profile RAW reopen restores the edited exposure");
            CloseMainWindow();
            return 0;
        }

        private AutomationElement WaitForMainWindow()
        {
            var process = Process.GetProcessById(hostPid);
            AutomationElement? found = null;
            var startup = Stopwatch.StartNew();
            while (startup.Elapsed < TimeSpan.FromSeconds(15) && clock.Elapsed < TotalTimeout)
            {
                try
                {
                    var condition = new AndCondition(
                        new PropertyCondition(AutomationElement.ProcessIdProperty, hostPid),
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
                    found = root.FindFirst(TreeScope.Children, condition);
                    if (found != null) break;
                }
                catch (ElementNotAvailableException) { }
                Thread.Sleep(50);
            }
            if (found == null)
            {
                if (process.SessionId == 0 || !Environment.UserInteractive)
                    throw new NotReachedException("No interactive desktop window is available.");
                throw new InvalidOperationException("The host window did not enter the UIA tree.");
            }
            return found;
        }

        private void OpenPhoto(string path)
        {
            Trace("open-start " + System.IO.Path.GetFileName(path));
            WaitBusyThenReady(() =>
            {
                var open = FindById(main, "OpenPhoto") ?? FindByNames(main, "打开照片", "打开 RAW", "Open photo", "Open RAW");
                if (open == null) throw new InvalidOperationException("OpenPhoto UIA control is missing.");
                var invocation = Task.Run(() => Invoke(open));
                var dialog = Wait(() => FindDialog(), TimeSpan.FromSeconds(15));
                if (dialog == null) throw new InvalidOperationException("OpenFileDialog did not appear through UIA.");
                Trace("open-dialog " + System.IO.Path.GetFileName(path) + " name=" + dialog.Current.Name + " hwnd=" + dialog.Current.NativeWindowHandle);
                if (invocation.IsFaulted) throw invocation.Exception!.GetBaseException();
                var edit = Wait(() => dialog.FindFirst(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.AutomationIdProperty, "1148")), TimeSpan.FromSeconds(10)) ??
                    dialog.FindFirst(TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
                if (edit == null) throw new InvalidOperationException("OpenFileDialog file-name edit is missing.");
                Trace("open-filename-found " + edit.Current.ControlType.ProgrammaticName);
                SetValue(edit, path);
                Trace("open-filename-set " + System.IO.Path.GetFileName(path));
                var accept = FindByNames(dialog, "打开", "Open", "选择", "Select") ??
                    dialog.FindFirst(TreeScope.Descendants, new AndCondition(
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                        new PropertyCondition(AutomationElement.AutomationIdProperty, "1")));
                if (accept == null) throw new InvalidOperationException("OpenFileDialog accept button is missing.");
                Invoke(accept);
                Trace("open-accepted " + System.IO.Path.GetFileName(path));
                if (!invocation.Wait(TimeSpan.FromSeconds(10)))
                    throw new TimeoutException("OpenPhoto modal Invoke did not return.");
                Wait(() => main.Current.Name.EndsWith(System.IO.Path.GetFileName(path), StringComparison.OrdinalIgnoreCase));
                Trace("open-title " + System.IO.Path.GetFileName(path));
            });
            Trace("open-ready " + System.IO.Path.GetFileName(path));
            var raster=path.Equals(png,StringComparison.OrdinalIgnoreCase) || path.Equals(jpeg,StringComparison.OrdinalIgnoreCase);
            var gpu=Environment.GetEnvironmentVariable("RAWLAB_COMPARISON_GPU") ?? "Cpu";
            var backend=FindByNames(main,"CPU · sRGB","Direct3D 11 · GPU · sRGB","CPU · GPU 已回退 · sRGB");
            Check(backend!=null,"Completed native preview exposes its actual backend");
            var expected=raster || gpu.Equals("Cpu",StringComparison.OrdinalIgnoreCase) ? "CPU · sRGB" :
                gpu.Equals("Force",StringComparison.OrdinalIgnoreCase) ? "Direct3D 11 · GPU · sRGB" : null;
            if(expected!=null)Check(backend!.Current.Name==expected,"Native preview backend matches "+(raster ? "raster CPU" : gpu));
            Trace("backend " + backend!.Current.Name);
        }

        private AutomationElement? FindDialog()
        {
            var condition = new AndCondition(
                new PropertyCondition(AutomationElement.ProcessIdProperty, hostPid),
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
            // WPF 会保留无标题辅助窗口；只接系统文件选择器，避免第二次打开时选到它。
            return main.FindAll(TreeScope.Children, condition).Cast<AutomationElement>()
                .Concat(root.FindAll(TreeScope.Children, condition).Cast<AutomationElement>())
                .FirstOrDefault(element => element.Current.NativeWindowHandle != main.Current.NativeWindowHandle &&
                    !element.Current.IsOffscreen && element.Current.ClassName == "#32770");
        }

        private void SelectMode(string mode)
        {
            var compare = FindById(main, "CompareModeButton") ?? throw new InvalidOperationException("Comparison mode UIA control is missing.");
            Invoke(compare);
            var item = Wait(() => FindById(root, "Compare" + char.ToUpperInvariant(mode[0]) + mode[1..])) ??
                throw new InvalidOperationException("Comparison mode UIA item is missing: " + mode);
            Invoke(item);
            WaitMode(mode);
        }

        private void WaitReady()
        {
            var export = Wait(() => FindById(main, "ExportButton"));
            if (export == null) throw new InvalidOperationException("ExportButton UIA control is missing.");
            Wait(() => export.Current.IsEnabled);
        }

        private void WaitMode(string mode,bool loaded=true)
        {
            Wait(() => !string.IsNullOrWhiteSpace(FindById(main, "CompareButton")?.Current.ItemStatus));
            if(loaded)
            {
                var canvas=Wait(()=>FindById(main,"ResultCanvas"),TimeSpan.FromSeconds(10)) ?? throw new InvalidOperationException("Result canvas is missing.");
                Wait(()=>canvas.TryGetCurrentPattern(RangeValuePattern.Pattern,out _)==(mode=="swipe"));
                var range=canvas.TryGetCurrentPattern(RangeValuePattern.Pattern,out _);
                Check(range==(mode=="swipe"),"Native canvas range support matches "+mode);
                Wait(()=>{var current=FindById(main,"NeutralCanvas");return (current!=null && !current.Current.IsOffscreen)==(mode=="side");});
                var neutral=FindById(main,"NeutralCanvas");
                Check((neutral!=null && !neutral.Current.IsOffscreen)==(mode=="side"),"Native neutral canvas visibility matches "+mode);
                Invoke(FindById(main,"CompareModeButton")!);
                AutomationElement? selected=null;
                foreach(var option in new[]{"off","side","swipe"})
                {
                    var item=Wait(()=>FindById(root,"Compare"+char.ToUpperInvariant(option[0])+option[1..]),TimeSpan.FromSeconds(10))!;
                    var toggle=(TogglePattern)item.GetCurrentPattern(TogglePattern.Pattern);
                    Check((toggle.Current.ToggleState==ToggleState.On)==(option==mode),"Native comparison menu selection "+option+" in "+mode);
                    if(option==mode)selected=item;
                }
                Check(FindById(main,"CompareButton")!.Current.ItemStatus==selected!.Current.Name,"Comparison status uses the selected localized mode label");
                Invoke(selected!);
            }
            Trace("mode " + mode);
        }

        private void WaitBusyThenReady(Action action)
        {
            var export = Wait(() => FindById(main, "ExportButton"));
            if (export == null) throw new InvalidOperationException("ExportButton UIA control is missing.");
            var busy = 0;
            AutomationPropertyChangedEventHandler handler = (_, args) =>
            {
                if (args.Property == AutomationElement.IsEnabledProperty &&
                    args.NewValue is bool enabled && !enabled)
                    Interlocked.Exchange(ref busy, 1);
            };
            Automation.AddAutomationPropertyChangedEventHandler(
                export, TreeScope.Element, handler, AutomationElement.IsEnabledProperty);
            try
            {
                if (!export.Current.IsEnabled) Interlocked.Exchange(ref busy, 1);
                action();
                Trace("wait-busy observed=" + Volatile.Read(ref busy) + " enabled=" + export.Current.IsEnabled);
                Wait(() => Volatile.Read(ref busy) != 0 || !export.Current.IsEnabled);
                Wait(() => export.Current.IsEnabled);
            }
            finally
            {
                Automation.RemoveAutomationPropertyChangedEventHandler(export, handler);
            }
        }

        private RangeValuePattern RangePattern(string id) => Wait(() =>
        {
            var element = FindById(main, id);
            return element != null && element.TryGetCurrentPattern(RangeValuePattern.Pattern, out var pattern)
                ? pattern as RangeValuePattern : null;
        }, TimeSpan.FromSeconds(10)) ?? throw new InvalidOperationException("Range UIA control is unavailable: " + id);

        private void SetRangeValue(string id, double value) => RangePattern(id).SetValue(value);
        private double GetRangeValue(string id) => RangePattern(id).Current.Value;

        private void CloseMainWindow()
        {
            var pattern = (WindowPattern)main.GetCurrentPattern(WindowPattern.Pattern);
            pattern.Close();
        }

        private static void Invoke(AutomationElement element)
        {
            var pattern = (InvokePattern)element.GetCurrentPattern(InvokePattern.Pattern);
            pattern.Invoke();
        }

        private static void SetValue(AutomationElement element, string value)
        {
            var pattern = (ValuePattern)element.GetCurrentPattern(ValuePattern.Pattern);
            pattern.SetValue(value);
        }

        private AutomationElement? FindById(AutomationElement scope, string id)
        {
            try
            {
                return scope.FindFirst(TreeScope.Descendants,new AndCondition(
                    new PropertyCondition(AutomationElement.ProcessIdProperty,hostPid),
                    new PropertyCondition(AutomationElement.AutomationIdProperty, id)));
            }
            catch (ElementNotAvailableException) { return null; }
        }

        private static AutomationElement? FindByNames(AutomationElement scope, params string[] names)
        {
            foreach (var name in names)
            {
                var value = scope.FindFirst(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.NameProperty, name));
                if (value != null) return value;
            }
            return null;
        }

        private T? Wait<T>(Func<T?> probe, TimeSpan? timeout = null) where T : class
        {
            var step = Stopwatch.StartNew();
            while (clock.Elapsed < TotalTimeout && (timeout == null || step.Elapsed < timeout))
            {
                try
                {
                    var value = probe();
                    if (value != null) return value;
                }
                catch (ElementNotAvailableException) { }
                Thread.Sleep(50);
            }
            throw new TimeoutException("UIA element did not appear within its timeout.");
        }

        private bool Wait(Func<bool> probe)
        {
            while (clock.Elapsed < TotalTimeout)
            {
                try { if (probe()) return true; }
                catch (ElementNotAvailableException) { }
                Thread.Sleep(50);
            }
            throw new TimeoutException("UIA driver exceeded its total timeout.");
        }

        private static void Check(bool success, string message)
        {
            if (!success) throw new InvalidOperationException(message);
            Console.WriteLine("PASS " + message);
        }

        private void Trace(string message)
        {
            var line = $"{DateTime.UtcNow:O} host={hostPid} phase={phase} {message}";
            System.IO.File.AppendAllText(System.IO.Path.Combine(profile, "driver-" + phase + ".log"), line + Environment.NewLine);
            Console.WriteLine(line);
        }
    }

    private sealed class NotReachedException(string message) : Exception(message);
}
