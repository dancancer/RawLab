using System.Windows;

namespace RawLab.Windows;

public partial class MainWindow
{
    private sealed record HslProbeWork(ulong Token,int Axis,HslTargetRevision Revision,AdjustmentSnapshot Before,Point Point);
    private readonly HslTargetInteraction hslTarget=new();
    private bool hslTargetEnabled,hslHistoryActive;
    private int hslTargetAxis;
    private Point? hslTargetPoint;
    private HslTargetAvailability? hslTargetNotice;
    private Work? hslAcceptedWork;
    private AdjustmentSnapshot? hslAcceptedSettings;
    private HslTargetRevision? hslAcceptedRevision;

    private void InitializeHslTarget()
    {
        HslEditor.TargetChanged+=SetHslTargetMode;
        HslEditor.TargetInputCancelled+=CancelHslTarget;
        ResultCanvas.HslTargetStarted+=point=>BeginHslTarget(point);
        ResultCanvas.HslTargetMoved+=MoveHslTarget;
        ResultCanvas.HslTargetEnded+=EndHslTarget;
        ResultCanvas.HslTargetCancelled+=CancelHslTarget;
        ResultCanvas.HslTargetKey+=KeyHslTarget;
        ResultCanvas.HslTargetRejected+=()=>{CancelHslTarget();hslTargetNotice=HslTargetAvailability.Outside;RefreshHslTarget();};
        ResultCanvas.HslTargetAllowed=point=>new FrameworkElement[]{NeutralLabel,FilmLabel,InfoOverlay,InfoEntryButton}.All(element=>
            !element.IsVisible || !new Rect(element.TranslatePoint(new Point(),ResultCanvas),element.RenderSize).Contains(point));
    }
    private void SetHslTargetMode(bool enabled,int axis)
    {
        CancelHslTarget();hslTargetEnabled=enabled;hslTargetAxis=axis;
        if(enabled)EndHoldingBefore();
        RefreshHslTarget();
    }
    private void RefreshHslTarget()
    {
        ResultCanvas.HslTargetEnabled=hslTargetEnabled && choosingHsl && expandedGroup!=null && !transform.Active;
        ResultCanvas.HslTargetPoint=hslTargetPoint;
        HslEditor.SetTarget(hslTargetEnabled,hslTargetAxis,hslTarget.Waiting,hslTarget.Selection,hslTargetNotice);
    }
    private void BeginHslTarget(Point point,double? keyDelta=null)
    {
        CancelHslTarget(false);
        if(!hslTargetEnabled || !ResultCanvas.HslTargetEnabled || file==null || closing || exporting || scheduler.Busy ||
            previewResize.IsEnabled || renderFailed || transform.Active || hslAcceptedWork is not {} work || hslAcceptedRevision is not {} revision ||
            hslAcceptedSettings?.SameAs(settings.Capture())!=true || work.OpenRevision!=openRevision || work.File!=file || work.Lut!=lut ||
            CurrentViewSource is not {} source || !work.Source.SameFile(source))
        {hslTargetNotice=HslTargetAvailability.Stale;RefreshHslTarget();return;}
        var before=settings.Capture();
        var token=hslTarget.Begin(settings.Hsl,hslTargetAxis,revision);hslTargetPoint=point;
        if(keyDelta is {} delta){hslTarget.Move(delta);hslTarget.End();}
        scheduler.Submit(work with {Probe=new(token,hslTargetAxis,revision,before,point)});
        RefreshHslTarget();UpdateBusy();Pump();
    }
    private void AcceptHslTarget(Work work,HslTargetSample sample,bool current)
    {
        if(work.Probe is not {} probe || !hslTarget.Matches(probe.Token))return;
        if(!current || !hslTargetEnabled || probe.Axis!=hslTargetAxis || hslAcceptedRevision!=probe.Revision ||
            file!=work.File || openRevision!=work.OpenRevision || CurrentViewSource is not {} source || !work.Source.SameFile(source) ||
            lut!=work.Lut || transform.Active || !probe.Before.SameAs(settings.Capture()))
        {CancelHslTarget();hslTargetNotice=HslTargetAvailability.Stale;RefreshHslTarget();return;}
        var next=hslTarget.Accept(sample,probe.Token,hslAcceptedRevision);
        hslTargetNotice=next==null ? hslTarget.Selection?.Availability ?? HslTargetAvailability.Stale : null;
        if(next!=null) {
            BeginEditGesture();hslHistoryActive=editGesture!=null;
            if(!hslHistoryActive){CancelHslTarget();hslTargetNotice=HslTargetAvailability.Failed;}
            else {
                interacting=true;settings.Hsl=next;MarkEdited();RefreshControls();Schedule();
                if(!hslTarget.Dragging)EndHslTarget();
            }
        }
        RefreshHslTarget();
    }
    private void MoveHslTarget(double delta)
    {
        var next=hslTarget.Move(delta);
        if(next==null || !hslHistoryActive)return;
        settings.Hsl=next;interacting=true;MarkEdited();RefreshControls();Schedule();
    }
    private void EndHslTarget()
    {
        hslTarget.End();
        if(hslHistoryActive){hslHistoryActive=false;interacting=false;MarkEdited();Schedule();}
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
}
