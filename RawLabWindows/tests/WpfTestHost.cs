using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.ExceptionServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

namespace RawLab.Windows.Tests;

internal static class WpfTestHost
{
    private static readonly object Gate = new();
    private static Dispatcher? dispatcher;

    internal static void PumpUntil(
        Func<bool> done,
        [CallerArgumentExpression(nameof(done))] string condition = "",
        [CallerMemberName] string caller = "")
    {
        var clock = Stopwatch.StartNew();
        while (!done())
        {
            if (clock.Elapsed > TimeSpan.FromMinutes(2))
                throw new TimeoutException($"{caller} did not complete within 120s: {condition}");
            var frame = new DispatcherFrame();
            var timer = new DispatcherTimer(DispatcherPriority.Background) { Interval = TimeSpan.FromMilliseconds(5) };
            timer.Tick += (_, _) => { timer.Stop(); frame.Continue = false; };
            timer.Start();
            Dispatcher.PushFrame(frame);
        }
    }

    internal static void Click(ButtonBase button) =>
        button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    internal static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            yield return child;
            foreach (var nested in Descendants(child)) yield return nested;
        }
    }

    internal static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject =>
        Descendants(root).OfType<T>();

    internal static FrameworkElement ArrangeLayout(Window window, Size requested)
    {
        var content = (FrameworkElement)window.Content;
        content.ClearValue(FrameworkElement.WidthProperty);
        content.ClearValue(FrameworkElement.HeightProperty);
        window.Width = requested.Width;
        window.Height = requested.Height;
        window.UpdateLayout();
        var chrome = new Size(window.ActualWidth - content.ActualWidth, window.ActualHeight - content.ActualHeight);
        var client = new Size(requested.Width - chrome.Width, requested.Height - chrome.Height);
        content.Width = client.Width;
        content.Height = client.Height;
        content.Measure(client);
        content.Arrange(new Rect(client));
        content.UpdateLayout();
        if (Math.Abs(content.ActualWidth - client.Width) > .5 || Math.Abs(content.ActualHeight - client.Height) > .5)
            throw new InvalidOperationException("WPF client layout did not reach the requested DIP size.");
        return content;
    }

    internal static void CaptureLayout(Window window, FrameworkElement content, string path)
    {
        var size = new Size(content.Width, content.Height);
        window.Content = null;
        window.UpdateLayout();
        var host = new Grid { Width = size.Width, Height = size.Height };
        host.Children.Add(content);
        try
        {
            TextElement.SetFontSize(content, window.FontSize);
            TextElement.SetFontFamily(content, window.FontFamily);
            content.InvalidateMeasure();
            content.InvalidateArrange();
            host.Measure(size);
            host.Arrange(new Rect(size));
            host.UpdateLayout();
            var bitmap = new RenderTargetBitmap((int)size.Width, (int)size.Height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(host);
            var corner = new byte[4];
            bitmap.CopyPixels(new Int32Rect(bitmap.PixelWidth - 1, bitmap.PixelHeight - 1, 1, 1), corner, 4, 0);
            if (corner[3] != 255)
                throw new InvalidOperationException("WPF layout composition is clipped or transparent at the requested bounds.");
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var stream = File.Create(path);
            encoder.Save(stream);
        }
        finally
        {
            host.Children.Remove(content);
            window.Content = content;
            content.ClearValue(TextElement.FontSizeProperty);
            content.ClearValue(TextElement.FontFamilyProperty);
        }
    }

    internal static void CheckHistogram(RenderedImage frame, Action<bool, string> check, string label)
    {
        var bytes = new byte[frame.Image.PixelWidth * frame.Image.PixelHeight * 4];
        new FormatConvertedBitmap(frame.Image, PixelFormats.Bgra32, null, 0).CopyPixels(bytes, frame.Image.PixelWidth * 4, 0);
        var expected = new uint[768];
        for (var i = 0; i < bytes.Length; i += 4)
        {
            expected[bytes[i + 2]]++;
            expected[256 + bytes[i + 1]]++;
            expected[512 + bytes[i]]++;
        }
        check(frame.Histogram.SequenceEqual(expected), label + ": all 768 bins match the actual frame pixels");
        check(Enumerable.Range(0, 3).All(c => frame.Histogram.Skip(c * 256).Take(256).Sum(v => (long)v) == (long)frame.Image.PixelWidth * frame.Image.PixelHeight),
            label + ": each RGB channel counts the displayed dimensions");
    }

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
