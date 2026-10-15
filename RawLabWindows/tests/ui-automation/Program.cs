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
            root = AutomationElement.RootElement;
            main = WaitForMainWindow();
            WaitMode("off");
            Check(true,"A fresh native window exposes single mode before a photo is opened");
            if (phase.Equals("restart", StringComparison.OrdinalIgnoreCase))
            {
                OpenPhoto(raw);
                WaitMode("off");
                var slider = FindById(main, "ParameterValueSlider") ??
                    throw new InvalidOperationException("ParameterValueSlider UIA control is missing.");
                var value = GetRangeValue(slider);
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

            OpenPhoto(png);
            WaitMode("off");
            OpenPhoto(jpeg);
            WaitMode("off");
            OpenPhoto(raw);
            WaitMode("off");
            Check(Math.Abs(GetRangeValue(FindById(main, "ParameterValueSlider") ??
                throw new InvalidOperationException("ParameterValueSlider UIA control is missing.")) - 1.25) < .02,
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
            WaitBusyThenReady(() =>
            {
                var open = FindById(main, "OpenPhoto") ?? FindByNames(main, "打开照片", "打开 RAW", "Open photo", "Open RAW");
                if (open == null) throw new InvalidOperationException("OpenPhoto UIA control is missing.");
                var invocation = Task.Run(() => Invoke(open));
                var dialog = Wait(() => FindDialog());
                if (dialog == null) throw new InvalidOperationException("OpenFileDialog did not appear through UIA.");
                if (invocation.IsFaulted) throw invocation.Exception!.GetBaseException();
                var edit = Wait(() => dialog.FindFirst(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.AutomationIdProperty, "1148"))) ??
                    dialog.FindFirst(TreeScope.Descendants,
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit));
                if (edit == null) throw new InvalidOperationException("OpenFileDialog file-name edit is missing.");
                SetValue(edit, path);
                var accept = FindByNames(dialog, "打开", "Open", "选择", "Select") ??
                    dialog.FindFirst(TreeScope.Descendants, new AndCondition(
                        new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
                        new PropertyCondition(AutomationElement.AutomationIdProperty, "1")));
                if (accept == null) throw new InvalidOperationException("OpenFileDialog accept button is missing.");
                Invoke(accept);
                if (!invocation.Wait(TimeSpan.FromSeconds(10)))
                    throw new TimeoutException("OpenPhoto modal Invoke did not return.");
                Wait(() => main.Current.Name.EndsWith(System.IO.Path.GetFileName(path), StringComparison.OrdinalIgnoreCase));
            });
        }

        private AutomationElement? FindDialog()
        {
            var condition = new AndCondition(
                new PropertyCondition(AutomationElement.ProcessIdProperty, hostPid),
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
            return root.FindAll(TreeScope.Children, condition).Cast<AutomationElement>()
                .FirstOrDefault(element => element.Current.NativeWindowHandle != main.Current.NativeWindowHandle);
        }

        private void SelectMode(string mode)
        {
            var compare = FindById(main, "CompareButton") ?? throw new InvalidOperationException("CompareButton UIA control is missing.");
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

        private void WaitMode(string mode)
        {
            Wait(() => string.Equals(FindById(main, "CompareButton")?.Current.ItemStatus,
                mode, StringComparison.OrdinalIgnoreCase));
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
                Wait(() => Volatile.Read(ref busy) != 0 || !export.Current.IsEnabled);
                Wait(() => export.Current.IsEnabled);
            }
            finally
            {
                Automation.RemoveAutomationPropertyChangedEventHandler(export, handler);
            }
        }

        private void SetRangeValue(string id, double value)
        {
            var element = FindById(main, id) ?? throw new InvalidOperationException("Range UIA control is missing: " + id);
            var pattern = (RangeValuePattern)element.GetCurrentPattern(RangeValuePattern.Pattern);
            pattern.SetValue(value);
        }

        private static double GetRangeValue(AutomationElement element)
        {
            var pattern = (RangeValuePattern)element.GetCurrentPattern(RangeValuePattern.Pattern);
            return pattern.Current.Value;
        }

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

        private T? Wait<T>(Func<T?> probe) where T : class
        {
            while (clock.Elapsed < TotalTimeout)
            {
                try
                {
                    var value = probe();
                    if (value != null) return value;
                }
                catch (ElementNotAvailableException) { }
                Thread.Sleep(50);
            }
            throw new TimeoutException("UIA driver exceeded its total timeout.");
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
    }

    private sealed class NotReachedException(string message) : Exception(message);
}
