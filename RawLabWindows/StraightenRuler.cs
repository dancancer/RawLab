using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace RawLab.Windows;
public sealed class StraightenRuler : FrameworkElement
{
    public double Value { get; set; }
    public event Action<double,bool>? Changed;
    public StraightenRuler()
    {
        Focusable=true;Cursor=Cursors.SizeWE;
        MouseLeftButtonDown+=(_,e)=>{Focus();if(e.ClickCount==2){Changed?.Invoke(0,false);return;}CaptureMouse();Update(e.GetPosition(this).X,true);e.Handled=true;};
        MouseMove+=(_,e)=>{if(IsMouseCaptured)Update(e.GetPosition(this).X,true);};
        MouseLeftButtonUp+=(_,e)=>{if(IsMouseCaptured){ReleaseMouseCapture();Update(e.GetPosition(this).X,false);e.Handled=true;}};
        KeyDown+=(_,e)=>{if(e.Key==Key.Home){Changed?.Invoke(0,false);e.Handled=true;}else if(e.Key is Key.Left or Key.Right){Changed?.Invoke(Math.Clamp(Value+(e.Key==Key.Left ? -.1 : .1),-45,45),false);e.Handled=true;}};
    }
    private void Update(double x,bool dragging)=>Changed?.Invoke(Math.Round(Math.Clamp(x/Math.Max(1,ActualWidth)*90-45,-45,45),2),dragging);
    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(Brushes.Transparent,null,new Rect(RenderSize));
        var pen=new Pen((Brush)FindResource("Muted"),1);
        for(var i=0;i<=90;i+=5){var x=ActualWidth*i/90;dc.DrawLine(pen,new(x,i%15==0 ? 8 : 14),new(x,24));}
        var marker=ActualWidth*(Value+45)/90;dc.DrawLine(new Pen((Brush)FindResource("Accent"),2),new(marker,2),new(marker,28));
        if(IsKeyboardFocused)dc.DrawRectangle(null,new Pen((Brush)FindResource("Accent"),2),new Rect(1,1,Math.Max(0,ActualWidth-2),Math.Max(0,ActualHeight-2)));
    }
}
