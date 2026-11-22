using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private sealed record WbProbeWork(ulong Token, HslTargetRevision Revision, AdjustmentSnapshot Before, Point Point);
    private bool wbProbeEnabled, wbProbeSampling;
    private ulong wbProbeToken;
    private string? wbProbeNotice;

    private bool CanUseWbProbe =>
        file != null && !settings.IsHDREditing && !closing && !exporting && !transform.Active &&
        (PhotoInput.IsRaster(file) || settings.AsShot != null) &&
        !PhotoInput.IsNormalX3f(file, settings);

    private void InitializeWbProbe()
    {
        WhiteBalanceEditor.EyedropperToggled += SetWbProbeMode;
        ResultCanvas.WbProbeClicked += BeginWbProbe;
        ResultCanvas.WbProbeCancelled += CancelWbProbe;
        ResultCanvas.WbProbeRejected += () => {
            wbProbeNotice = Loc.Text("请在调整后的照片区域取色。");
            RefreshWbProbe();
        };
    }

    private void SetWbProbeMode(bool enabled)
    {
        if (enabled) CancelHslTarget();
        wbProbeEnabled = enabled && CanUseWbProbe;
        if (!wbProbeEnabled) { wbProbeSampling = false; wbProbeNotice = null; ++wbProbeToken; }
        else EndHoldingBefore();
        RefreshWbProbe();
    }

    private void CancelWbProbe() => SetWbProbeMode(false);

    private void RefreshWbProbe()
    {
        ResultCanvas.WbProbeEnabled = wbProbeEnabled && toolMode == EditorToolMode.WhiteBalance &&
            expandedGroup != null && !transform.Active && CanUseWbProbe;
        if (toolMode == EditorToolMode.WhiteBalance)
        {
            var raster = file != null && PhotoInput.IsRaster(file) && !settings.IsHDREditing;
            var notice = wbProbeSampling ? Loc.Text("正在取色…") : wbProbeNotice;
            WhiteBalanceEditor.Refresh(settings,
                WhiteBalanceEditor.IsEnabled && (settings.IsHDREditing || raster || settings.AsShot != null),
                isRaster: raster,
                wbProbeAvailable: CanUseWbProbe && result != null,
                wbProbeEnabled: wbProbeEnabled,
                wbProbeNotice: notice);
        }
    }

    private void BeginWbProbe(Point point)
    {
        if (!wbProbeEnabled || !ResultCanvas.WbProbeEnabled || file == null || closing || exporting ||
            scheduler.Busy || previewResize.IsEnabled || renderFailed || transform.Active ||
            hslAcceptedWork is not {} work || hslAcceptedRevision is not {} revision ||
            hslAcceptedSettings?.SameAs(settings.Capture()) != true || work.OpenRevision != openRevision ||
            work.File != file || work.Lut != lut || CurrentViewSource is not {} source ||
            work.Source?.SameFile(source) != true)
        {
            wbProbeNotice = Loc.Text("预览已变化，请重新取色。");
            RefreshWbProbe();
            return;
        }
        var token = ++wbProbeToken;
        wbProbeSampling = true;
        wbProbeNotice = null;
        var before = settings.Capture();
        scheduler.Submit(work with { WbProbe = new(token, revision, before, point) });
        RefreshWbProbe();
        UpdateBusy();
        Pump();
    }

    private void AcceptWbProbe(Work work, RenderEngine.WbProbeSample? sample, bool current)
    {
        if (work.WbProbe is not {} probe || probe.Token != wbProbeToken) return;
        wbProbeSampling = false;
        if (!current || !wbProbeEnabled || hslAcceptedRevision != probe.Revision ||
            file != work.File || openRevision != work.OpenRevision ||
            CurrentViewSource is not {} source || work.Source?.SameFile(source) != true ||
            lut != work.Lut || transform.Active || !probe.Before.SameAs(settings.Capture()))
        {
            wbProbeNotice = Loc.Text("预览已变化，请重新取色。");
            RefreshWbProbe();
            return;
        }
        if (sample == null || sample.Availability == Native.WbProbeAvailability.Unavailable)
        {
            wbProbeNotice = Loc.Text("取色失败，请重试。");
            RefreshWbProbe();
            return;
        }
        if (sample.Availability == Native.WbProbeAvailability.Overexposed)
        {
            wbProbeNotice = Loc.Text("此像素不可取样。");
            RefreshWbProbe();
            return;
        }
        if (sample.Availability == Native.WbProbeAvailability.Outside)
        {
            wbProbeNotice = Loc.Text("请在调整后的照片区域取色。");
            RefreshWbProbe();
            return;
        }
        BeginEditGesture();
        if (editGesture == null)
        {
            wbProbeNotice = Loc.Text("取色失败，请重试。");
            RefreshWbProbe();
            return;
        }
        try
        {
            if (PhotoInput.IsRaster(file!)) settings.SetRelativeWhiteBalance(sample.Temperature, sample.Tint);
            else
            {
                settings.Set(Parameter.Temperature, sample.Temperature);
                settings.Set(Parameter.Tint, sample.Tint);
            }
            wbProbeEnabled = false;
            wbProbeNotice = null;
            MarkEdited();
            RefreshControls();
            Schedule();
        }
        finally
        {
            editGesture = null;
        }
    }
}
