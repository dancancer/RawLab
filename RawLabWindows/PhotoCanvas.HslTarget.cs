using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed partial class PhotoCanvas
{
    private readonly DrawingVisual hslTargetDrawing=new();
    private bool hslTargetEnabled;
    private Point? hslTargetPoint,hslPointerOrigin;
    private double hslPointerScale;
    internal event Action<Point>? HslTargetStarted;
    internal event Action<double>? HslTargetMoved;
    internal event Action? HslTargetEnded,HslTargetCancelled,HslTargetRejected;
    internal event Action<double>? HslTargetKey;
    internal Func<Point,bool>? HslTargetAllowed;
    internal bool HslTargetEnabled {
        get=>hslTargetEnabled;
        set {if(hslTargetEnabled==value)return;hslTargetEnabled=value;ResetHslPointer();CancelHold();DrawImages();DrawHslTarget();}
    }
    internal Point? HslTargetPoint {get=>hslTargetPoint;set{hslTargetPoint=value;DrawHslTarget();}}
    internal Point? HslCoordinates(Point point)
    {
        if(image==null || ShowingBefore || GeometryEditing || !VisibleImageBounds.Contains(point) ||
            ImageBounds.Width<=0 || ImageBounds.Height<=0 || ComparisonEnabled && point.X<=DividerX+18 || HslTargetAllowed?.Invoke(point)==false)return null;
        return new((point.X-ImageBounds.X)/ImageBounds.Width,(point.Y-ImageBounds.Y)/ImageBounds.Height);
    }
    private void BeginHslPointer(Point point)
    {
        if(HslCoordinates(point) is not {} sample){HslTargetRejected?.Invoke();return;}
        hslPointerOrigin=point;hslPointerScale=(Keyboard.Modifiers&ModifierKeys.Shift)!=0 ? .125 : .5;
        CaptureMouse();HslTargetStarted?.Invoke(sample);
    }
    private bool MoveHslPointer(Point point)
    {
        if(hslPointerOrigin is not {} origin)return false;
        HslTargetMoved?.Invoke((origin.Y-point.Y)*hslPointerScale);return true;
    }
    private bool FinishHslPointer(Point point)
    {
        if(!MoveHslPointer(point))return false;
        hslPointerOrigin=null;HslTargetEnded?.Invoke();
        if(IsMouseCaptured)ReleaseMouseCapture();return true;
    }
    internal void ResetHslPointer()
    {
        var captured=hslPointerOrigin!=null;hslPointerOrigin=null;
        if(captured && IsMouseCaptured)ReleaseMouseCapture();
    }
    private void CancelHslPointer()
    {ResetHslPointer();if(HslTargetEnabled)HslTargetCancelled?.Invoke();}
    private bool HandleHslKey(KeyEventArgs e)
    {
        if(!HslTargetEnabled)return false;
        if(e.Key==Key.Escape){CancelHslPointer();return true;}
        if(e.Key is not (Key.Left or Key.Right or Key.Up or Key.Down))return false;
        if(hslPointerOrigin==null)HslTargetKey?.Invoke((e.Key is Key.Left or Key.Down ? -1 : 1)*((Keyboard.Modifiers&ModifierKeys.Shift)!=0 ? .1 : 1));
        return true;
    }
    private void DrawHslTarget()
    {
        using var dc=hslTargetDrawing.RenderOpen();
        if(!HslTargetEnabled || hslTargetPoint is not {} point || ImageBounds.IsEmpty || VisibleImageBounds.IsEmpty)return;
        var center=new Point(ImageBounds.X+point.X*ImageBounds.Width,ImageBounds.Y+point.Y*ImageBounds.Height);
        dc.PushClip(new RectangleGeometry(VisibleImageBounds));
        dc.DrawEllipse(null,new Pen(Brushes.Black,4),center,8,8);
        dc.DrawEllipse(null,new Pen(Brushes.White,2),center,8,8);
        dc.DrawLine(new Pen(Brushes.White,1),new(center.X-12,center.Y),new(center.X-5,center.Y));
        dc.DrawLine(new Pen(Brushes.White,1),new(center.X+5,center.Y),new(center.X+12,center.Y));
        dc.Pop();
    }
}
