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
    internal void OpenFile(string path,BitmapSource? placeholder=null)
    {
        if(exporting || closing)return;
        try
        {
            path=Path.GetFullPath(path);
            if(!LibraryEntry.IsImage(path))throw new InvalidOperationException(Loc.Text("请选择支持的照片文件。"));
            if(!ResolveTransformDraft() || !SaveEdits())return;
            RestoreEdits(path);
            compare=swipe=false;
            lastExportedPath=null;ExportRevealButton.Visibility=Visibility.Collapsed;
            if(file==null){AdjustmentPanel.Visibility=AdjustmentSplitter.Visibility=Visibility.Visible;DockRow.MinHeight=216;DockRow.Height=new(dockHeight);SplitterRow.Height=new(6);}
            previewResize.Stop();previewLongEdge=requestedPreviewLongEdge=2000;previewDeferred=false;
            file=path; interacting=false; exactReady=false; result=null; photoInfo=null; ++photoInfoRevision; syncing=true;viewport.Fit();
            RefreshComparisonToolTip();
            viewport.SetSourceSize(0,0);
            NeutralCanvas.SetImage(placeholder,null); ResultCanvas.SetImage(placeholder,null);ResultCanvas.SetComparison(placeholder,null); Histogram.Bins=null; Histogram.InvalidateVisual(); ClipStats.Text="";
            previewLongEdge=requestedPreviewLongEdge=ResultCanvas.PreviewLongEdge>0 ? ResultCanvas.PreviewLongEdge : 2000;
            syncing=false;
            RefreshPhotoInfo();
            BackendLabel.Text=Loc.Text("相机预览 · 正在显影");BaselineLabel.Text="";
            Title="RawLab · "+Path.GetFileName(path); Welcome.Visibility=Visibility.Collapsed;
            embeddedScheduler.Submit(new(path,++openRevision));PumpEmbedded();
            _ = LoadPhotoInfo(path, photoInfoRevision);
            RefreshControls(); Schedule(initialPreview:true);QueueThumbnailRefresh();
        }
        catch(Exception ex) { Report(ex); }
    }
    private async Task LoadPhotoInfo(string path, long revision)
    {
        var info = await Task.Run(() => PhotoInfoReader.Read(path));
        if (closing || revision != photoInfoRevision || !StringComparer.OrdinalIgnoreCase.Equals(path, file)) return;
        photoInfo = info;
        RefreshPhotoInfo();
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
    private async void PumpEmbedded()
    {
        var ticket=embeddedScheduler.Start();if(ticket==null)return;
        EmbeddedPreview? preview=null;
        try{preview=await Task.Run(()=>RenderEngine.ReadEmbeddedPreview(ticket.Value.Path));}
        catch(Exception ex) when(ex is IOException or InvalidOperationException or DllNotFoundException or BadImageFormatException or EntryPointNotFoundException) { }
        var current=embeddedScheduler.Finish(ticket);
        if(closing)return;
        if(current && ticket.Value.Revision==openRevision && ticket.Value.Path==file && preview!=null && settings.Geometry.IsIdentity)
        {
            if(viewport.SourceSize.Width==0)viewport.SetSourceSize(preview.Width,preview.Height);
            if(result==null && !renderFailed && preview.Image!=null)
            {
                NeutralCanvas.SetImage(preview.Image,null);ResultCanvas.SetImage(preview.Image,null);ResultCanvas.SetComparison(preview.Image,null);
                SetStatus(() => Loc.Text("相机内嵌预览 · 正在显影…"));
            }
        }
        PumpEmbedded();
    }
    private void UpdatePreviewSize(int edge)
    {
        if(syncing || file==null || closing || (edge==requestedPreviewLongEdge && (edge==previewLongEdge || previewResize.IsEnabled)))return;
        requestedPreviewLongEdge=edge;previewResize.Stop();
        if(exporting)return;
        if(edge==previewLongEdge){UpdateBusy();return;}
        if(settings.Denoise.Enabled && edge>0 && previewLongEdge>0){previewResize.Start();UpdateBusy();}
        else CommitPreviewSize();
    }
    private void CommitPreviewSize()
    {
        previewResize.Stop();previewLongEdge=requestedPreviewLongEdge;Schedule(initialPreview:result==null);
    }
    private void ResumePreview()
    {
        if(exporting || closing)return;
        if(previewDeferred || requestedPreviewLongEdge!=previewLongEdge)CommitPreviewSize();
        else {UpdateBusy();Pump();}
    }
    private int RenderEdge(bool proxy)=>proxy && previewLongEdge==0 ? 2000 : previewLongEdge;
    private void Schedule(bool initialPreview=false)
    {
        if(!ready || file==null || closing)return;
        if(exporting){previewDeferred=true;return;}
        previewDeferred=false;
        if(transform.Active){transformPreviewReady=false;RefreshCropDraft();}
        if(!settings.Denoise.Enabled && previewResize.IsEnabled){previewResize.Stop();previewLongEdge=requestedPreviewLongEdge;}
        if(!LookAvailable){exactReady=false;result=null;renderFailed=true;RefreshRenderLabels();SetStatus(() => Loc.Text("上次使用的外观不可用，请重新选择或导入外观。"),true);UpdateBusy();return;}
        renderFailed=false;
        var proxy=interacting || initialPreview;
        var previewSettings=settings.Clone();previewSettings.Geometry=PreviewGeometry;previewSettings.Lens=PreviewLens;
        scheduler.Submit(new(file,previewSettings,lut,RenderEdge(proxy),proxy,GpuMode.SelectedIndex==0 ? 1 : GpuMode.SelectedIndex==1 ? 0 : 2,compare,clipping,initialPreview,transformGeneration));
        exactReady=false; SetStatus(() => interacting ? Loc.Text("正在生成交互预览…") : Loc.Text("正在显影…")); UpdateBusy();
        Pump();
    }
    private async void Pump()
    {
        var ticket=scheduler.Start(); if(ticket==null)return;
        RenderedImage? neutral=null,rendered=null; Exception? failure=null;
        try
        {
            (neutral,rendered)=await Task.Run(()=> {
                engine ??= new(); var w=ticket.Value;engine.SetGpuMode(w.GpuMode);
                var frame=engine.RenderPreview(w.File,w.Settings,w.Lut,w.Edge,w.Interactive,w.Compare,w.Clipping);
                return(frame.Neutral,frame.Result);
            });
        }
        catch(Exception ex) { failure=ex; }
        var current=scheduler.Finish(ticket);
        if(closing) { FinishClose(); return; }
        var work=ticket.Value;
        // A current-file proxy may publish while dragging; stale exact work never publishes.
        if(work.File==file && work.Lut==lut && work.Settings.Geometry==PreviewGeometry && work.Settings.Lens==PreviewLens && work.TransformGeneration==transformGeneration && work.Compare==compare && work.Clipping==clipping && (current || (work.Interactive && interacting && work.Edge==RenderEdge(true))))
        {
            if(failure!=null) { if(current){result=null;exactReady=false;transformPreviewReady=false;renderFailed=true;RefreshCropDraft();RefreshRenderLabels();Report(failure);} }
            else if(rendered!=null && neutral!=null)
            {
                result=rendered;if(!transform.Active)settings.ResolveWhiteBalance(rendered.WhiteBalance);
                // The core supplies the post-geometry canvas before preview/export resizing.
                syncing=true;
                try { viewport.SetSourceSize(rendered.NativeWidth,rendered.NativeHeight); }
                finally { syncing=false; }
                renderedGpuMode=work.GpuMode;
                NeutralCanvas.SetImage(neutral.Image,neutral.Clipping); ResultCanvas.SetImage(rendered.Image,rendered.Clipping);
                ResultCanvas.SetComparison(neutral.Image,neutral.Clipping);
                Histogram.Bins=rendered.Histogram; Histogram.InvalidateVisual();
                RefreshRenderLabels();
                exactReady=current && !work.Interactive && !transform.Active;
                if(transform.Active)
                {
                    transformPreviewReady=current && !work.Interactive;
                    if(transform.Tool==TransformTool.Geometry)GeometryEditor.SetCanvasSize(rendered.NativeWidth,rendered.NativeHeight);
                    RefreshCropDraft();
                }
                SetStatus(() => $"{(work.Interactive ? Loc.Text("交互预览") : work.Edge==0 ? Loc.Text("原尺寸") : Loc.Text("预览"))} {rendered.Image.PixelWidth} × {rendered.Image.PixelHeight} · {Path.GetFileName(work.File)}");
                if (current && openRevision != photoImportReportedRevision)
                {
                    photoImportReportedRevision = openRevision;
                    usageAnalytics.Record(new PhotoImportedEvent());
                }
                RefreshControls();
                UpdatePreviewSize(ResultCanvas.PreviewLongEdge);
            }
        }
        // A quick RAW proxy shortens the blank wait. Only its exact successor enables export.
        if(current && work.Refine && failure==null && work.File==file && !interacting)Schedule();
        UpdateBusy(); Pump();
    }
    private void ExposureModeChanged(object sender,SelectionChangedEventArgs e) { if(!ready || syncing || exporting || transform.Active)return;settings.ExposureMode=ExposureMode.SelectedIndex;MarkEdited();Schedule(); }
    private void ProcessingVersionChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!ready || syncing || exporting || transform.Active || file==null || ProcessingVersion.SelectedIndex is < 0 or > 1)return;
        settings.Processing=ProcessingVersion.SelectedIndex==0 ? ProcessingIdentity.Legacy : ProcessingIdentity.Current;
        MarkEdited();Schedule();
    }
    private void GpuModeChanged(object sender,SelectionChangedEventArgs e) { if(ready && !syncing && !exporting)Schedule(); }
    private void ResetGroupClicked(object sender,RoutedEventArgs e) { if(exporting || !ResolveTransformDraft())return;var group=ParameterSpec.All[(int)selectedParameter].Group;if(group=="胶片" && settings.MasterRecipeID!=null){settings.ClearMasterRecipe();lut=null;}settings.ResetGroup(group);MarkEdited();RefreshControls();Schedule(); }
    private void ResetAllClicked(object sender,RoutedEventArgs e) { if(file==null || exporting || !ResolveTransformDraft())return;if(settings.MasterRecipeID!=null)lut=null;settings.ResetAll();MarkEdited();RefreshControls();Schedule(); }
    private async void AutoExposureClicked(object sender,RoutedEventArgs e)
    {
        if(file==null || result==null || autoExposing || exporting || transform.Active)return;
        var path=file;var snapshot=settings.Clone();var revision=editRevision;var photoRevision=openRevision;
        autoExposing=true;RefreshControls();
        try
        {
            var ev=await Task.Run(()=>{using var meter=new RenderEngine();return meter.AutoExposure(path,snapshot);});
            if(closing || file!=path || openRevision!=photoRevision || editRevision!=revision || !snapshot.Capture().SameAs(settings.Capture()))return;
            settings.Set(Parameter.Exposure,NumericRange.For(ParameterSpec.All[(int)Parameter.Exposure]).Clamp(ev));MarkEdited();Schedule();
        }
        catch(Exception error) {if(!closing && file==path && openRevision==photoRevision && editRevision==revision)Report(error);}
        finally {autoExposing=false;if(!closing)RefreshControls();}
    }
    private void AsShotClicked(object sender,RoutedEventArgs e) { if(transform.Active || exporting)return;settings.ResetWhiteBalance();MarkEdited();RefreshControls();Schedule(); }
}
