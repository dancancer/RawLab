using System;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class AgentHotReloadWpfTests
{
    private static void PumpUntil(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition() && DateTime.UtcNow < deadline)
        {
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(
                DispatcherPriority.Background,
                new Action(() => frame.Continue = false));
            Dispatcher.PushFrame(frame);
            Thread.Sleep(15);
        }
        Assert.True(condition(), "Timed out waiting for WPF dispatcher condition.");
    }

    private static string WriteTestPng(string directory, string name = "photo.png")
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, name);
        const int w = 16, h = 16, stride = w * 4;
        var pixels = new byte[stride * h];
        for (var i = 0; i < pixels.Length; i += 4)
        {
            pixels[i] = 110;
            pixels[i + 1] = 130;
            pixels[i + 2] = 150;
            pixels[i + 3] = 255;
        }
        var bmp = BitmapSource.Create(w, h, 96, 96, PixelFormats.Pbgra32, null, pixels, stride);
        bmp.Freeze();
        var enc = new PngBitmapEncoder();
        enc.Frames.Add(BitmapFrame.Create(bmp));
        using var fs = File.Create(path);
        enc.Save(fs);
        return path;
    }

    [StaFact]
    [Trait("Category", "WpfModel")]
    [Trait("Suite", "agent-hot-reload")]
    public void MainWindowHotReloadsExternalEditsPresetsAndPreviewInvalidationEndToEnd()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-wpf-hotreload-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        TestWindowState.CreateApplication();
        MainWindow? window = null;
        try
        {
            var photo = WriteTestPng(Path.Combine(root, "photos"));
            var out1 = Path.Combine(root, "win-1");
            var out2 = Path.Combine(root, "win-2");

            window = TestWindowState.CreateIsolatedWindow(out1, width: 1200, height: 800);
            window.Show();

            // Verify IsolateForTests hooks PhotoPreviews and restarts ExternalStoreWatcher on isolated paths
            TestWindowState.Isolate(window, out2);
            var previews = window.PhotoPreviewsForTests();
            Assert.NotNull(previews);
            Assert.Same(window.EditStoreInstance, previews!.Store);

            // External edits.json write while no photo is open (file == null) still executes cleanly without throwing
            var externalEditsStore = new EditStore(window.Paths.EditsDirectory);
            var externalPresetStore = new AdjustmentPresetStore(window.Paths.PresetsDirectory);
            var identity = OriginalIdentity.Read(photo);
            var initialExt = new Adjustments { ExposureMode = 2 };
            initialExt.Set(Parameter.Exposure, 0.35);
            externalEditsStore.SaveState(identity, new SavedEdit(identity, initialExt.Capture(), null));
            window.HandleExternalEditsFileChangeForTests();

            // Open photo -> picks up 0.35 EV
            window.OpenFile(photo);
            PumpUntil(() => window.ExactReady && !window.SchedulerBusy, TimeSpan.FromSeconds(30));
            Assert.Equal(0.35, window.Settings[Parameter.Exposure], precision: 6);
            Assert.False(window.HasActiveExternalReloadBannerForTests);

            // 1. Clean external update auto-reloads via ExternalStoreWatcher & is 1-step Undoable
            var ext1 = new Adjustments { ExposureMode = 2 };
            ext1.Set(Parameter.Exposure, 0.95);
            ext1.Set(Parameter.Contrast, 1.2);
            externalEditsStore.SaveState(identity, new SavedEdit(identity, ext1.Capture(), null));

            PumpUntil(
                () => Math.Abs(window.Settings[Parameter.Exposure] - 0.95) < 1e-6 &&
                      Math.Abs(window.Settings[Parameter.Contrast] - 1.2) < 1e-6,
                TimeSpan.FromSeconds(6));
            Assert.False(window.HasActiveExternalReloadBannerForTests);
            Assert.False(window.HasUnsavedManualDraftForTests);
            PumpUntil(() => window.ExactReady && !window.SchedulerBusy, TimeSpan.FromSeconds(30));

            window.RunPhotoHistoryForTests(undo: true);
            Assert.Equal(0.35, window.Settings[Parameter.Exposure], precision: 6);
            window.RunPhotoHistoryForTests(undo: false);
            Assert.Equal(0.95, window.Settings[Parameter.Exposure], precision: 6);

            // 2. Dirty manual draft protection -> banner shown, sliders untouched
            window.Interacting = true;
            window.Settings.Set(Parameter.Exposure, -0.75);
            window.MarkEditedForTests();
            Assert.True(window.HasUnsavedManualDraftForTests);

            var ext2 = new Adjustments { ExposureMode = 2 };
            ext2.Set(Parameter.Exposure, 1.45);
            externalEditsStore.SaveState(identity, new SavedEdit(identity, ext2.Capture(), null));

            PumpUntil(() => window.HasActiveExternalReloadBannerForTests, TimeSpan.FromSeconds(6));
            Assert.Equal(-0.75, window.Settings[Parameter.Exposure], precision: 6);

            // 3. Keep Manual Draft dismisses banner and preserves -0.75
            window.KeepManualDraftOnExternalUpdateForTests();
            Assert.False(window.HasActiveExternalReloadBannerForTests);
            Assert.Equal(-0.75, window.Settings[Parameter.Exposure], precision: 6);

            // 4. Subsequent external update re-surfaces banner; Reload Sliders applies and is 1-step Undoable
            Thread.Sleep(30);
            var ext3 = new Adjustments { ExposureMode = 2 };
            ext3.Set(Parameter.Exposure, 1.65);
            externalEditsStore.SaveState(identity, new SavedEdit(identity, ext3.Capture(), null));

            PumpUntil(() => window.HasActiveExternalReloadBannerForTests, TimeSpan.FromSeconds(6));
            window.ReloadExternalUpdateForTests();
            Assert.False(window.HasActiveExternalReloadBannerForTests);
            Assert.False(window.HasUnsavedManualDraftForTests);
            Assert.Equal(1.65, window.Settings[Parameter.Exposure], precision: 6);

            window.RunPhotoHistoryForTests(undo: true);
            Assert.Equal(0.95, window.Settings[Parameter.Exposure], precision: 6);

            // 5. External presets.json update is handled cleanly without errors
            var ctx = new AdjustmentTransferContext(photo, IsRaw: false, AvailableLookIDs: new System.Collections.Generic.HashSet<string>());
            var payload = AdjustmentTransfer.Capture(
                AdjustmentScope.Custom([AdjustmentField.Exposure]),
                new SavedEdit(identity, ext3.Capture(), null),
                ctx);
            externalPresetStore.Create("External WPF Preset", payload);
            window.HandleExternalPresetsFileChangeForTests();
            Assert.Single(window.PresetStoreInstance.List());
        }
        finally
        {
            if (window != null)
            {
                window.UpdateQuitApproved = true;
                window.Close();
            }
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }
}
