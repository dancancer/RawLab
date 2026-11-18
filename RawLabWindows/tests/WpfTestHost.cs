using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Threading;
using RawLab.Windows;

namespace RawLab.Windows.Tests;

internal static class WpfTestHost
{
    private static readonly object Gate = new();
    private static Dispatcher? dispatcher;

    internal static void Run(Action action)
    {
        var ui = EnsureDispatcher();
        Exception? failure = null;
        ui.Invoke(() =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(ui));
            Loc.Initialize("zh-Hans");
            var app = TestWindowState.CreateApplication();
            try
            {
                action();
            }
            catch (Exception error)
            {
                failure = error;
            }
            finally
            {
                CloseStrayWindows(app);
                PumpIdle(ui);
                Loc.Initialize("zh-Hans");
            }
        });
        if (failure != null) ExceptionDispatchInfo.Capture(failure).Throw();
    }

    private static Dispatcher EnsureDispatcher()
    {
        lock (Gate)
        {
            if (dispatcher != null) return dispatcher;
            using var ready = new ManualResetEventSlim(false);
            Dispatcher? created = null;
            var thread = new Thread(() =>
            {
                created = Dispatcher.CurrentDispatcher;
                SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext(created));
                TestWindowState.CreateApplication();
                ready.Set();
                Dispatcher.Run();
            })
            {
                IsBackground = true,
                Name = "RawLab.WpfTestHost",
            };
            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
            ready.Wait();
            dispatcher = created ?? throw new InvalidOperationException("Failed to initialize WPF test host dispatcher.");
            return dispatcher;
        }
    }

    private static void CloseStrayWindows(Application app)
    {
        foreach (var window in app.Windows.OfType<Window>().ToArray())
        {
            try { window.Close(); } catch { }
        }
    }

    private static void PumpIdle(Dispatcher ui)
    {
        var frame = new DispatcherFrame();
        ui.BeginInvoke(DispatcherPriority.ApplicationIdle, new Action(() => frame.Continue = false));
        Dispatcher.PushFrame(frame);
    }
}
