using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private sealed record HslProbeWork(ulong Token,int Axis,HslTargetRevision Revision,AdjustmentSnapshot Before,Point Point);
    private readonly HslTargetInteraction hslTarget=new();
    private readonly CurveTargetInteraction curveTarget=new();
    private bool hslTargetEnabled,hslHistoryActive;
    private bool curveTargetEnabled,curveHistoryActive;
    private int hslTargetAxis;
    private ToneCurveChannel curveTargetChannel;
    private Point? hslTargetPoint,curveTargetPoint;
    private HslTargetAvailability? hslTargetNotice,curveTargetNotice;
    private Work? hslAcceptedWork;
    private AdjustmentSnapshot? hslAcceptedSettings;
    private HslTargetRevision? hslAcceptedRevision;

    private void InitializeHslTarget()
    {
        HslEditor.TargetChanged+=SetHslTargetMode;
        HslEditor.TargetInputCancelled+=CancelHslTarget;
        CurveEditor.TargetChanged+=SetCurveTargetMode;
        CurveEditor.TargetInputCancelled+=CancelCurveTarget;
        ResultCanvas.HslTargetStarted+=point=>{if(CurrentTool==EditorAdjustmentTool.ToneCurve)BeginCurveTarget(point);else BeginHslTarget(point);};
        ResultCanvas.HslTargetMoved+=delta=>{if(CurrentTool==EditorAdjustmentTool.ToneCurve)MoveCurveTarget(delta);else MoveHslTarget(delta);};
        ResultCanvas.HslTargetEnded+=()=>{if(CurrentTool==EditorAdjustmentTool.ToneCurve)EndCurveTarget();else EndHslTarget();};
        ResultCanvas.HslTargetCancelled+=()=>{if(CurrentTool==EditorAdjustmentTool.ToneCurve)CancelCurveTarget();else CancelHslTarget();};
        ResultCanvas.HslTargetKey+=delta=>{if(CurrentTool==EditorAdjustmentTool.ToneCurve)KeyCurveTarget(delta);else KeyHslTarget(delta);};
        ResultCanvas.HslTargetRejected+=()=>{
            if(CurrentTool==EditorAdjustmentTool.ToneCurve){CancelCurveTarget();curveTargetNotice=HslTargetAvailability.Outside;RefreshCurveTarget();}
            else{CancelHslTarget();hslTargetNotice=HslTargetAvailability.Outside;RefreshHslTarget();}
        };
        ResultCanvas.HslTargetAllowed=point=>new FrameworkElement[]{NeutralLabel,FilmLabel,InfoOverlay,ExternalReloadBanner,HslTargetBanner,InspectionOverlayChip,InspectionHud}.All(element=>
            !element.IsVisible || !new Rect(element.TranslatePoint(new Point(),ResultCanvas),element.RenderSize).Contains(point));
    }
    private void SetHslTargetMode(bool enabled,int axis)
    {
        CancelHslTarget();hslTargetEnabled=enabled;hslTargetAxis=axis;
        if(enabled){CancelWbProbe();CancelPointColorProbe();SetCurveTargetMode(false,curveTargetChannel);EndHoldingBefore();inspection.PinModeEnabled=false;RefreshInspection();}
        RefreshHslTarget();
    }
    private void RefreshHslTarget()
    {
        var hslActive=hslTargetEnabled && toolMode==EditorToolMode.Hsl && expandedGroup!=null && !transform.Active;
        var curveActive=curveTargetEnabled && CurrentTool==EditorAdjustmentTool.ToneCurve && expandedGroup!=null && !transform.Active;
        ResultCanvas.HslTargetEnabled=hslActive || curveActive;
        HslTargetBanner.Visibility=ResultCanvas.HslTargetEnabled && AdjustmentPanel.Visibility!=Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        HslTargetBannerCaption.Text=Loc.Text(curveActive ? "拖动照片调整曲线；退出目标模式后可平移。" : "拖动照片调整颜色；退出目标模式后可平移。");
        if(curveActive) {
            var chTitle=curveTargetChannel switch {ToneCurveChannel.Red=>Loc.Text("红"),ToneCurveChannel.Green=>Loc.Text("绿"),ToneCurveChannel.Blue=>Loc.Text("蓝"),_=>"RGB"};
            HslTargetBannerTitle.Text=Loc.Format("目标调整：{0}",chTitle);
            ResultCanvas.HslTargetPoint=curveTargetPoint;
        } else {
            HslTargetBannerTitle.Text=Loc.Format("目标调整：{0}",Loc.Text(hslTargetAxis switch {1=>"饱和度",2=>"明度",_=>"色相"}));
            ResultCanvas.HslTargetPoint=hslTargetPoint;
        }
        HslEditor.SetTarget(hslTargetEnabled,hslTargetAxis,hslTarget.Waiting,hslTarget.Selection,hslTargetNotice);
        RefreshHDRPresentation();
    }
    private void ExitHslTargetClicked(object sender,RoutedEventArgs e)
    {
        if(curveTargetEnabled)SetCurveTargetMode(false,curveTargetChannel);
        if(hslTargetEnabled)SetHslTargetMode(false,hslTargetAxis);
    }
    private void BeginHslTarget(Point point,double? keyDelta=null)
    {
        CancelHslTarget(false);
        if(!hslTargetEnabled || !ResultCanvas.HslTargetEnabled || file==null || closing || exporting || scheduler.Busy ||
            previewResize.IsEnabled || renderFailed || transform.Active || hslAcceptedWork is not {} work || hslAcceptedRevision is not {} revision ||
            hslAcceptedSettings?.SameAs(settings.Capture())!=true || work.OpenRevision!=openRevision || work.File!=file || work.Lut!=lut ||
            CurrentViewSource is not {} source || work.Source?.SameFile(source) != true)
        {hslTargetNotice=HslTargetAvailability.Stale;RefreshHslTarget();return;}
        var before=settings.Capture();
        var token=hslTarget.Begin(settings.EditingHsl,hslTargetAxis,revision);hslTargetPoint=point;
        if(keyDelta is {} delta){hslTarget.Move(delta);hslTarget.End();}
        scheduler.Submit(work with {Probe=new(token,hslTargetAxis,revision,before,point)});
        RefreshHslTarget();UpdateBusy();Pump();
    }
    private void AcceptHslTarget(Work work,HslTargetSample sample,bool current)
    {
        if(work.Probe is not {} probe || !hslTarget.Matches(probe.Token))return;
        if(!current || !hslTargetEnabled || probe.Axis!=hslTargetAxis || hslAcceptedRevision!=probe.Revision ||
            file!=work.File || openRevision!=work.OpenRevision || CurrentViewSource is not {} source || work.Source?.SameFile(source) != true ||
            lut!=work.Lut || transform.Active || !probe.Before.SameAs(settings.Capture()))
        {CancelHslTarget();hslTargetNotice=HslTargetAvailability.Stale;RefreshHslTarget();return;}
        var next=hslTarget.Accept(sample,probe.Token,hslAcceptedRevision);
        hslTargetNotice=next==null ? hslTarget.Selection?.Availability ?? HslTargetAvailability.Stale : null;
        if(next!=null) {
            BeginEditGesture();hslHistoryActive=editGesture!=null;
            if(!hslHistoryActive){CancelHslTarget();hslTargetNotice=HslTargetAvailability.Failed;}
            else {
                interacting=true;settings.EditingHsl=next;MarkEdited();RefreshControls();Schedule();
                if(!hslTarget.Dragging)EndHslTarget();
            }
        }
        RefreshHslTarget();
    }
    private void MoveHslTarget(double delta)
    {
        var next=hslTarget.Move(delta);
        if(next==null || !hslHistoryActive)return;
        settings.EditingHsl=next;interacting=true;MarkEdited();RefreshControls();Schedule();
    }
    private void EndHslTarget()
    {
        hslTarget.End();
        if(hslHistoryActive) {
            hslHistoryActive=false;interacting=false;
            try { MarkEdited();RefreshControls();Schedule(); }
            finally { editGesture=null; }
        }
        RefreshHslTarget();
    }
    private void CancelHslTarget()=>CancelHslTarget(true);
    private void CancelHslTarget(bool pointer)
    {
        if(pointer)ResultCanvas.ResetHslPointer();
        hslTarget.Cancel();hslTargetPoint=null;hslTargetNotice=null;
        var active=hslHistoryActive;hslHistoryActive=false;
        if(active)CancelEditGesture();
        RefreshHslTarget();
    }
    private void KeyHslTarget(double delta)
    {
        if(hslTarget.Dragging || hslTargetPoint is not {} point)return;
        if(hslTarget.Waiting){hslTarget.AccumulateReleased(delta);return;}
        BeginHslTarget(point,delta);
    }

    private void SetCurveTargetMode(bool enabled, ToneCurveChannel channel)
    {
        CancelCurveTarget(); curveTargetEnabled = enabled; curveTargetChannel = channel;
        if (enabled) { CancelWbProbe(); CancelPointColorProbe(); SetHslTargetMode(false, hslTargetAxis); EndHoldingBefore(); inspection.PinModeEnabled = false; RefreshInspection(); }
        RefreshCurveTarget();
    }
    private void RefreshCurveTarget()
    {
        RefreshHslTarget();
        CurveEditor.SetTarget(curveTargetEnabled, curveTargetChannel, curveTarget.Waiting, curveTarget.Selection, curveTargetNotice);
    }
    private void BeginCurveTarget(Point point, double? keyDelta = null)
    {
        CancelCurveTarget(false);
        if (!curveTargetEnabled || !ResultCanvas.HslTargetEnabled || file == null || closing || exporting || scheduler.Busy ||
            previewResize.IsEnabled || renderFailed || transform.Active || hslAcceptedWork is not {} work || hslAcceptedRevision is not {} revision ||
            hslAcceptedSettings?.SameAs(settings.Capture()) != true || work.OpenRevision != openRevision || work.File != file || work.Lut != lut ||
            CurrentViewSource is not {} source || work.Source?.SameFile(source) != true)
        { curveTargetNotice = HslTargetAvailability.Stale; RefreshCurveTarget(); return; }
        var before = settings.Capture();
        var curve = settings.EditingCurve;
        var sampledCurve = ToneCurveSampling.Samples(curve, curveTargetChannel);
        Func<double, double>? parametricEval = curveTargetChannel == ToneCurveChannel.Rgb && !curve.Parametric.IsIdentity
            ? x => ToneCurveSampling.SampleParametricValue(curve, x)
            : null;
        var token = curveTarget.Begin(curve, curveTargetChannel, revision, sampledCurve, settings.IsHDREditing, parametricEval);
        curveTargetPoint = point;
        if (keyDelta is {} delta) { curveTarget.Move(delta); curveTarget.End(); }
        scheduler.Submit(work with { Probe = new(token, (int)curveTargetChannel, revision, before, point) });
        RefreshCurveTarget(); UpdateBusy(); Pump();
    }
    private void AcceptCurveTarget(Work work, HslTargetSample sample, bool current)
    {
        if (work.Probe is not {} probe || !curveTarget.Matches(probe.Token)) return;
        if (!current || !curveTargetEnabled || probe.Axis != (int)curveTargetChannel || hslAcceptedRevision != probe.Revision ||
            file != work.File || openRevision != work.OpenRevision || CurrentViewSource is not {} source || work.Source?.SameFile(source) != true ||
            lut != work.Lut || transform.Active || !probe.Before.SameAs(settings.Capture()))
        { CancelCurveTarget(); curveTargetNotice = HslTargetAvailability.Stale; RefreshCurveTarget(); return; }
        var next = curveTarget.Accept(sample, probe.Token, hslAcceptedRevision);
        curveTargetNotice = next == null ? curveTarget.Selection?.Availability ?? HslTargetAvailability.Stale : null;
        if (next != null) {
            BeginEditGesture(); curveHistoryActive = editGesture != null;
            if (!curveHistoryActive) { CancelCurveTarget(); curveTargetNotice = HslTargetAvailability.Failed; }
            else {
                interacting = true; settings.EditingCurve = next; MarkEdited(); RefreshControls(); Schedule();
                if (!curveTarget.Dragging) EndCurveTarget();
            }
        }
        RefreshCurveTarget();
    }
    private void MoveCurveTarget(double delta)
    {
        var next = curveTarget.Move(delta);
        if (next == null || !curveHistoryActive) return;
        settings.EditingCurve = next; interacting = true; MarkEdited(); RefreshControls(); Schedule();
    }
    private void EndCurveTarget()
    {
        curveTarget.End();
        if (curveHistoryActive) {
            curveHistoryActive = false; interacting = false;
            try { MarkEdited(); RefreshControls(); Schedule(); }
            finally { editGesture = null; }
        }
        RefreshCurveTarget();
    }
    private void CancelCurveTarget() => CancelCurveTarget(true);
    private void CancelCurveTarget(bool pointer)
    {
        if (pointer) ResultCanvas.ResetHslPointer();
        curveTarget.Cancel(); curveTargetPoint = null; curveTargetNotice = null;
        var active = curveHistoryActive; curveHistoryActive = false;
        if (active) CancelEditGesture();
        RefreshCurveTarget();
    }
    private void KeyCurveTarget(double delta)
    {
        if (curveTarget.Dragging || curveTargetPoint is not {} point) return;
        if (curveTarget.Waiting) { curveTarget.AccumulateReleased(delta); return; }
        BeginCurveTarget(point, delta);
    }
}
