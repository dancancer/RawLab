using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Automation;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RawLab.Windows;
public partial class MainWindow
{
    private BitmapSource? openingPreview;
    internal void OpenFile(string path,BitmapSource? placeholder=null)
    {
        if(exporting || closing)return;
        CloseQuickPresets();
        CancelParameterInputs();
        var sourceChanged=false;
        try
        {
            path=Collection.CanonicalPath(Path.GetFullPath(path));
            if(!LibraryEntry.IsImage(path))throw new InvalidOperationException(Loc.Text("请选择支持的照片文件。"));
            HDRSourceInfo? openedHDR = null;
            if (PhotoInput.IsHDRContainer(path)) PhotoInput.ProbeHDR(path, out openedHDR);
            else if (PhotoInput.IsRaw(path)) PhotoInput.ProbeCameraRaw(path, out openedHDR);
            CancelViewingInput();
            if(!ResolveTransformDraft() || !SaveEdits())return;
            ClearTransferNoticesOnSourceChange();
            ResetAITask();CancelProcessingMigration();RestoreEdits(path); hdrSource = openedHDR;
            CancelViewingInput();view.SourceChanged();neutralResult=null;
            lastExportedPath=null;ExportRevealButton.Visibility=Visibility.Collapsed;
            previewResize.Stop();previewLongEdge=requestedPreviewLongEdge=2000;previewDeferred=false;
            file=path;sourceChanged=true;openingPreview=placeholder;renderFailed=false;interacting=false;exactReady=false;result=null;photoInfo=null;++photoInfoRevision;syncing=true;
            Collection.BeginEditing(Collection.Photos.FirstOrDefault(photo=>StringComparer.OrdinalIgnoreCase.Equals(photo.Path,path))?.ID ?? "");viewport.Fit();
            clippingOverlay=null;
            suspendedTransform = null;
            workspaceLayout.PhotoOpened();
            RefreshWorkspace();
            WorkspacePhotoOpened();
            RefreshComparisonToolTip();
            viewport.SetSourceSize(0,0);
            RefreshViewingFrames();
            previewLongEdge=requestedPreviewLongEdge=ResultCanvas.PreviewLongEdge>0 ? ResultCanvas.PreviewLongEdge : 2000;
            syncing=false;
            RefreshPhotoInfo();
            BackendLabel.Text=Loc.Text("相机预览 · 正在显影");BaselineLabel.Text="";
            Title="RawLab · "+Path.GetFileName(path); Welcome.Visibility=Visibility.Collapsed;
            embeddedScheduler.Submit(new(path,++openRevision));PumpEmbedded();
            _ = LoadPhotoInfo(path, photoInfoRevision);
            RefreshControls(); Schedule(initialPreview:true);BeginProcessingMigration(path);QueueThumbnailRefresh();
        }
        catch(Exception ex) { if(sourceChanged){syncing=false;exactReady=false;renderFailed=true;RefreshRenderLabels();UpdateBusy();}Report(ex); }
    }
    private async Task LoadPhotoInfo(string path, long revision)
    {
        try
        {
            var info = await Task.Run(() => PhotoInfoReader.Read(path));
            if (closing || revision != photoInfoRevision || !StringComparer.OrdinalIgnoreCase.Equals(path, file)) return;
            photoInfo = info;
            RefreshPhotoInfo();
        }
        catch (Exception ex) when (PreviewFallback.ShouldDegrade(ex))
        {
            Trace.WriteLine($"Photo info read skipped for {path}: {ex.Message}");
        }
    }
    private void RefreshPhotoInfo()
    {
        if (photoInfo == null || photoInfoMode == PhotoInfoMode.Hidden)
        {
            InfoOverlay.Visibility = Visibility.Collapsed;
            InfoFileText.Text = InfoCaptureText.Text = "";
            return;
        }
        var text = photoInfoMode == PhotoInfoMode.File ? photoInfo.FileLine : photoInfo.CaptureLine;
        if (string.IsNullOrWhiteSpace(text))
        {
            InfoOverlay.Visibility = Visibility.Collapsed;
            InfoFileText.Text = InfoCaptureText.Text = "";
            return;
        }
        InfoFileText.Text = photoInfoMode == PhotoInfoMode.File ? text : "";
        InfoCaptureText.Text = photoInfoMode == PhotoInfoMode.Capture ? text : "";
        InfoOverlay.Visibility = Visibility.Visible;
    }
    private void InfoClicked(object sender, RoutedEventArgs e)
    {
        photoInfoMode = photoInfoMode.Next();
        RefreshPhotoInfo(); RefreshControls();
    }
    internal Func<string, EmbeddedPreview> ReadEmbeddedPreviewHook { get; set; } = path => RenderEngine.ReadEmbeddedPreview(path);
    internal Func<string, Adjustments, string?, int, bool, bool, Action?, PreviewFrame>? RenderPreviewHook { get; set; }

    private async void PumpEmbedded()
    {
        var ticket=embeddedScheduler.Start();if(ticket==null)return;
        EmbeddedPreview? preview=null;
        var current=false;
        try
        {
            try{preview=await Task.Run(()=>ReadEmbeddedPreviewHook(ticket.Value.Path));}
            catch(Exception ex) when(PreviewFallback.ShouldDegrade(ex))
            {
                Trace.WriteLine($"Embedded preview fallback for {ticket.Value.Path}: {ex.Message}");
                preview=null;
            }
        }
        finally { current=embeddedScheduler.Finish(ticket); }
        if(closing)return;
        try
        {
            if(current && ticket.Value.Revision==openRevision && ticket.Value.Path==file && preview!=null && settings.Geometry.IsIdentity)
            {
                if(viewport.SourceSize.Width==0)viewport.SetSourceSize(preview.Width,preview.Height);
                if(result==null && !renderFailed && preview.Image!=null)
                {
                    openingPreview=preview.Image;RefreshViewingFrames();
                    SetStatus(() => Loc.Text("相机内嵌预览 · 正在显影…"));
                }
            }
        }
        catch(Exception ex) when(PreviewFallback.ShouldDegrade(ex))
        {
            Trace.WriteLine($"Embedded preview update error for {ticket.Value.Path}: {ex.Message}");
        }
        PumpEmbedded();
    }
    private void UpdatePreviewSize(int edge)
    {
        if(syncing || file==null || closing || (edge==requestedPreviewLongEdge && (edge==previewLongEdge || previewResize.IsEnabled)))return;
        CancelHslTarget();
        requestedPreviewLongEdge=edge;previewResize.Stop();
        if(exporting)return;
        if(edge==previewLongEdge){UpdateBusy();return;}
        if(settings.Denoise.Enabled && edge>0 && previewLongEdge>0){previewResize.Start();UpdateBusy();}
        else CommitPreviewSize();
    }
    private void CommitPreviewSize()
    {
        previewResize.Stop();previewLongEdge=requestedPreviewLongEdge;Schedule(initialPreview:result==null,viewportOnly:!previewDeferred);
    }
    private void ResumePreview()
    {
        if(exporting || closing)return;
        if(previewDeferred || requestedPreviewLongEdge!=previewLongEdge)CommitPreviewSize();
        else {UpdateBusy();Pump();}
    }
    private int RenderEdge(bool proxy)=>proxy && previewLongEdge==0 ? 2000 : previewLongEdge;
    private long quietViewportRevision = -1;
    private void Schedule(bool initialPreview=false,bool viewportOnly=false)
    {
        if(!ready || file==null || closing)return;
        if(exporting){previewDeferred=true;return;}
        ReconcileAI();
        if(settings.ActiveAIDenoise && !AIResultReady) { exactReady=false;UpdateBusy();return; }
        previewDeferred=false;
        if(transform.Active){transformPreviewReady=false;RefreshCropDraft();}
        if(!settings.Denoise.Enabled && previewResize.IsEnabled){previewResize.Stop();previewLongEdge=requestedPreviewLongEdge;}
        if(!LookAvailable){exactReady=false;renderFailed=true;RefreshRenderLabels();SetStatus(() => Loc.Text("上次使用的外观不可用，请重新选择或导入外观。"),true);UpdateBusy();return;}
        renderFailed=false;
        var proxy=interacting || initialPreview;
        var previewSettings=settings.Clone();previewSettings.Geometry=PreviewGeometry;previewSettings.Lens=PreviewLens;
        if(CurrentViewSource is not {} source) {exactReady=false;renderFailed=true;RefreshRenderLabels();SetStatus(()=>Loc.Text("预览未更新"),true);UpdateBusy();return;}
        var referenceKey=new NeutralReferenceKey(source,PhotoInput.IsRaster(file),previewSettings.Processing,previewSettings.Geometry,previewSettings.Lens,RenderEdge(proxy),previewSettings.IsHDREditing,previewSettings.X3fMode,NeutralReference.HDRCameraSettings(previewSettings.IsHDREditing ? previewSettings.HDR : null));
        if(acceptedReference!=referenceKey){neutralResult=null;acceptedReference=null;RefreshViewingFrames();}
        var quiet=viewportOnly && exactReady && !scheduler.Busy && !proxy && !transform.Active;
        scheduler.Submit(new(file,previewSettings,lut,RenderEdge(proxy),proxy,RequestedGpuMode,view.NeedsReference,initialPreview,transformGeneration,openRevision,source,settings.ActiveAIDenoise ? aiJob.Identity : null));
        quietViewportRevision=quiet ? scheduler.Revision : -1;
        exactReady=false;
        if(!quiet)SetStatus(() => interacting ? Loc.Text("正在生成交互预览…") : Loc.Text("正在显影…"));
        UpdateBusy();
        Pump();
    }
    private async void Pump()
    {
        var ticket=scheduler.Start(); if(ticket==null)return;
        RenderedImage? neutral=null,rendered=null; HslTargetSample? hslSample=null;Exception? failure=null;
        string? thumbnailResources=null;var thumbnailAIBackend=RequestedAIBackend;var thumbnailAIDevice=aiPreference.DeviceID;
        var current=false;
        try
        {
            Action? renderStarted=ticket.Id==quietViewportRevision ? () => Dispatcher.BeginInvoke(new Action(() => {
                if(closing || scheduler.Active!=ticket || scheduler.Revision!=ticket.Id)return;
                quietViewportRevision=-1;
                SetStatus(()=>Loc.Text("正在显影…"));UpdateBusy();
            })) : null;
            (neutral,rendered)=await Task.Run(()=> {
                var w=ticket.Value;
                if(w.Probe is {} probe) {
                    engine ??= new(aiDiagnostics:aiDiagnostics); engine.SetGpuMode(w.GpuMode);engine.SetAIDevice(w.AIIdentity?.DeviceID ?? "");
                    hslSample=engine.SampleHsl(w.File,w.Settings,w.Lut,w.Edge,w.Interactive,probe.Revision,probe.Point.X,probe.Point.Y);
                    return ((RenderedImage?)null,(RenderedImage?)null);
                }
                try {thumbnailResources=EditedPhotoPreviewKey.ResourceFingerprint(w.Settings.Capture(),w.Lut,thumbnailAIBackend,thumbnailAIDevice);}catch { }
                PreviewFrame frame;
                if (RenderPreviewHook != null)
                    frame=RenderPreviewHook(w.File,w.Settings,w.Lut,w.Edge,w.Interactive,w.Compare,renderStarted);
                else {
                    engine ??= new(aiDiagnostics:aiDiagnostics); engine.SetGpuMode(w.GpuMode);engine.SetAIDevice(w.AIIdentity?.DeviceID ?? "");
                    frame=engine.RenderPreview(w.File,w.Settings,w.Lut,w.Edge,w.Interactive,w.Compare,clipping:false,renderStarted:renderStarted);
                }
                return(frame.Neutral,frame.Result);
            });
        }
        catch(Exception ex) when(PreviewFallback.ShouldDegrade(ex)) { failure=ex; }
        finally { current=scheduler.Finish(ticket); }
        if(closing) { FinishClose(); return; }
        var work=ticket.Value;
        if(work.Probe is {} probeWork) {
            AcceptHslTarget(work,hslSample ?? HslTargetSample.Unavailable(probeWork.Revision,HslTargetAvailability.Failed),current);
            if(current && failure!=null && work.OpenRevision==openRevision && work.File==file && work.AIIdentity==aiJob.Identity)
                HandleAIFailure(failure);
            UpdateBusy();Pump();QueuePendingReset();return;
        }
        try
        {
            var currentSource = CurrentViewSource;
            var sameSource = currentSource != null && work.Source.SameFile(currentSource);
            var sameOpenFile = work.OpenRevision == openRevision && work.File == file;
            var sameRenderInputs = work.Lut == lut &&
                work.Settings.IsHDREditing == settings.IsHDREditing &&
                work.Settings.ActiveAIDenoise == settings.ActiveAIDenoise &&
                work.Settings.X3fMode == settings.X3fMode &&
                (!work.Settings.ActiveAIDenoise || AIResultReady && work.AIIdentity == aiJob.Identity) &&
                work.Settings.Geometry == PreviewGeometry &&
                work.Settings.Lens == PreviewLens &&
                work.TransformGeneration == transformGeneration &&
                (!view.NeedsReference || work.Compare) &&
                (current || (work.Interactive && interacting && work.Edge == RenderEdge(true)));
            var aiRunning = settings.ActiveAIDenoise && aiJob.State.IsRunning;
            var disposition = PreviewFallback.ResolveMainPreviewDisposition(
                current, sameOpenFile, sameRenderInputs, sameSource, previewDeferred, aiRunning, renderFailed, failure != null);

            if (disposition == MainPreviewDisposition.DegradeWithError)
            {
                ApplyMainPreviewFailure(failure!);
            }
            else if (disposition == MainPreviewDisposition.DegradeSourceUnavailable)
            {
                ApplyMainPreviewFailure(null);
            }
            else if (disposition == MainPreviewDisposition.PublishFrame)
            {
                if(rendered!=null && neutral!=null)
                {
                    if(work.Settings.ActiveAIDenoise) { aiNotReadyIdentity=null;aiNotReadyAttempts=0; }
                    var previousResult = result;
                    var previousAcceptedAfter = acceptedAfter;
                    var previousNeutral = neutralResult;
                    var previousNeutralRevision = neutralRevision;
                    var previousAcceptedReference = acceptedReference;
                    var previousHslWork = hslAcceptedWork;
                    var previousHslSettings = hslAcceptedSettings;
                    var previousHslRevision = hslAcceptedRevision;
                    var previousGpuMode = renderedGpuMode;
                    try
                    {
                        result=rendered;acceptedAfter=new(work.Source,PhotoInput.IsRaster(work.File),work.Settings.Processing,work.Settings.Geometry,work.Settings.Lens,work.Edge,work.Settings.IsHDREditing,work.Settings.X3fMode,NeutralReference.HDRCameraSettings(work.Settings.IsHDREditing ? work.Settings.HDR : null));
                        // HDR camera rendering has no legacy RAW WB result. Keep the
                        // dormant SDR AsShot calibration intact across HDR previews.
                        if(!transform.Active && rendered.WhiteBalance is { } whiteBalance)
                            settings.ResolveWhiteBalance(whiteBalance);
                        hslAcceptedWork=work;
                        var acceptedSettings=work.Settings.Clone();
                        if (rendered.WhiteBalance is { } acceptedWhiteBalance)
                            acceptedSettings.ResolveWhiteBalance(acceptedWhiteBalance);
                        hslAcceptedSettings=acceptedSettings.Capture();
                        hslAcceptedRevision=new((ulong)openRevision,(ulong)ticket.Id);
                        // The core supplies the post-geometry canvas before preview/export resizing.
                        syncing=true;
                        try { viewport.SetSourceSize(rendered.NativeWidth,rendered.NativeHeight); }
                        finally { syncing=false; }
                        renderedGpuMode=work.GpuMode;
                        if(work.Compare) {
                            neutralResult=neutral;neutralRevision=openRevision;acceptedReference=new(work.Source,PhotoInput.IsRaster(work.File),work.Settings.Processing,work.Settings.Geometry,work.Settings.Lens,work.Edge,work.Settings.IsHDREditing,work.Settings.X3fMode,NeutralReference.HDRCameraSettings(work.Settings.IsHDREditing ? work.Settings.HDR : null));
                        }
                        RefreshViewingFrames();
                        RefreshRenderLabels();
                    }
                    catch(Exception ex) when(PreviewFallback.ShouldDegrade(ex))
                    {
                        result = previousResult;
                        acceptedAfter = previousAcceptedAfter;
                        neutralResult = previousNeutral;
                        neutralRevision = previousNeutralRevision;
                        acceptedReference = previousAcceptedReference;
                        hslAcceptedWork = previousHslWork;
                        hslAcceptedSettings = previousHslSettings;
                        hslAcceptedRevision = previousHslRevision;
                        renderedGpuMode = previousGpuMode;
                        throw;
                    }
                    exactReady=current && !work.Interactive && !transform.Active;
                    if(exactReady && thumbnailResources!=null) {
                        acceptedPhotoPreviewResources=thumbnailResources;
                        CacheCurrentPhotoPreview(thumbnailResources);
                    }
                    if(transform.Active)
                    {
                        transformPreviewReady=current && !work.Interactive;
                        if(transform.Tool==TransformTool.Geometry)GeometryEditor.SetCanvasSize(rendered.NativeWidth,rendered.NativeHeight);
                        RefreshCropDraft();
                    }
                    // W1（#301 收口）：仅在当前帧满足 OpenRevision/EditRevision 时绑定提示，
                    // Refine 或待执行缩放预览先保留，直到最终稳态帧消费一次并保持活跃横幅引用待清理。
                    var isSettledFrame = !WillScheduleNextPreview(work, current, failure);
                    Func<string> cleanPreviewStatus = () => $"{(work.Interactive ? Loc.Text("交互预览") : work.Edge==0 ? Loc.Text("原尺寸") : Loc.Text("预览"))} {rendered.Image.PixelWidth} × {rendered.Image.PixelHeight} · {Path.GetFileName(work.File)}";
                    var (nextBannerState, status) = transferNoticeBanner.DeliverRender(
                        work.OpenRevision,
                        editRevision,
                        isSettledFrame,
                        cleanPreviewStatus,
                        transferNotices => () => cleanPreviewStatus() + "；" + FormatTransferNotices(transferNotices));
                    transferNoticeBanner = nextBannerState;
                    SetStatus(status);
                    if (current && openRevision != photoImportReportedRevision)
                    {
                        photoImportReportedRevision = openRevision;
                        usageAnalytics.Record(new PhotoImportedEvent());
                    }
                    RefreshControls();
                    UpdatePreviewSize(ResultCanvas.PreviewLongEdge);
                }
                else if (current && !previewDeferred && !aiRunning && !renderFailed)
                {
                    ApplyMainPreviewFailure(null);
                }
            }
            // A quick RAW proxy shortens the blank wait. Only its exact successor enables export.
            if(current && work.Refine && failure==null && !renderFailed && work.File==file && !interacting)Schedule();
        }
        catch(Exception ex) when(PreviewFallback.ShouldDegrade(ex))
        {
            failure=ex;
            if(current)ApplyMainPreviewFailure(ex);
        }
        UpdateBusy(); TryFinishPendingProcessingMigration(); Pump();QueuePendingReset();
    }

    private void ApplyMainPreviewFailure(Exception? failure)
    {
        Trace.WriteLine($"Main preview fallback for {file}: {failure?.Message ?? "Source unavailable"}");
        var outcome = failure != null
            ? PreviewFallback.DegradeMainPreview(failure, result != null, openingPreview != null)
            : PreviewFallback.DegradeUnavailableSource(result != null, openingPreview != null);
        ClearPendingAllReset();
        transferNoticeBanner = transferNoticeBanner.AfterRenderFailure();
        exactReady = outcome.ExactReady;
        transformPreviewReady = outcome.TransformPreviewReady;
        renderFailed = outcome.RenderFailed;
        RefreshCropDraft();
        RefreshRenderLabels();
        CancelProcessingMigration();
        if (failure == null)
        {
            SetStatus(() => Loc.Text("预览未更新"), true);
            return;
        }
        if (!HandleAIFailure(failure))
            SetStatus(() => Loc.Text("预览未更新") + " · " + outcome.StatusError, true);
    }

    private bool WillScheduleNextPreview(Work work, bool current, Exception? failure)
    {
        if (!current || work.Interactive) return true;
        if (work.Refine && failure == null && work.File == file && !interacting) return true;
        if (scheduler.Busy || previewResize.IsEnabled) return true;
        return !syncing && !closing && !exporting && file != null && ResultCanvas.PreviewLongEdge != previewLongEdge;
    }
    private void ExposureModeChanged(object sender,SelectionChangedEventArgs e) { if(!ready || syncing || exporting || transform.Active)return;settings.ExposureMode=ExposureMode.SelectedIndex;MarkEdited();Schedule(); }
    private void X3fRenderingChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ready || syncing || exporting || transform.Active || !PhotoInput.IsX3f(file) || X3fRendering.SelectedIndex is < 0 or > 1)return;
        var mode=(X3fMode)X3fRendering.SelectedIndex;
        if(mode==X3fMode.Normal)ResetAITask();
        settings.SelectX3fMode(mode);
        MarkEdited();RefreshControls();Schedule();
    }
    private void ProcessingVersionChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ready || syncing || exporting || transform.Active || file==null || ProcessingVersion.SelectedIndex is < 0 or > 2)return;
        settings.Processing=ProcessingVersion.SelectedIndex switch {
            0 => ProcessingIdentity.Legacy, 1 => ProcessingIdentity.C5, _ => ProcessingIdentity.Current
        };
        MarkEdited();Schedule();
    }
    private void GpuModeChanged(object sender,SelectionChangedEventArgs e) { if(ready && !syncing && !exporting) {RefreshAIControls();Schedule();} }
    private void ResetGroupClicked(object sender,RoutedEventArgs e) => RequestReset(new(EditorResetKind.Group,EditorAdjustmentRules.GroupFor(CurrentTool)));
    private void ResetAllClicked(object sender,RoutedEventArgs e) => RequestReset(new(EditorResetKind.All));
    private int RequestedGpuMode => GpuMode.SelectedIndex == 0 ? 1 : GpuMode.SelectedIndex == 1 ? 0 : 2;
    private bool CanAutoExpose => !closing && file != null && result != null && !AIBlocksOutput &&
        !autoExposing && !exporting && !scheduler.Busy && !transform.Active && (!settings.IsHDREditing || RequestedGpuMode != 2);
    private async void AutoExposureClicked(object sender,RoutedEventArgs e)
    {
        if(file==null || !CanAutoExpose)return;
        var path=file;var snapshot=settings.Clone();var revision=editRevision;var photoRevision=openRevision;
        var gpuMode=snapshot.IsHDREditing ? RequestedGpuMode : 1;
        var aiBackend=RequestedAIBackend;
        var aiDevice=aiPreference.DeviceID;
        autoExposing=true;RefreshControls();
        try
        {
            var ev=await Task.Run(()=>{using var meter=new RenderEngine(gpuMode:gpuMode,aiBackend:aiBackend,aiDeviceID:aiDevice,aiDiagnostics:aiDiagnostics);return meter.AutoExposure(path,snapshot);});
            if(closing || file!=path || openRevision!=photoRevision || editRevision!=revision || !snapshot.Capture().SameAs(settings.Capture()) ||
                snapshot.IsHDREditing && RequestedGpuMode!=gpuMode)return;
            var exposure=settings.IsHDREditing ? ev : NumericRange.For(ParameterSpec.All[(int)Parameter.Exposure]).Clamp(ev);
            if (settings.IsHDREditing && settings[Parameter.Exposure] == exposure) return;
            settings.Set(Parameter.Exposure,exposure);MarkEdited();Schedule();
        }
        catch(Exception error) {if(!closing && file==path && openRevision==photoRevision && editRevision==revision && !HandleAIFailure(error))Report(error);}
        finally {autoExposing=false;if(!closing)RefreshControls();}
    }
    private void AsShotClicked(object sender,RoutedEventArgs e) { if(transform.Active || exporting)return;RequestReset(new(EditorResetKind.Tool,Tool:EditorAdjustmentTool.WhiteBalance)); }
}
