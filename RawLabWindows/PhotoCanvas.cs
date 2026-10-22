using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;

namespace RawLab.Windows;
public sealed class Viewport
{
    public bool ActualPixels { get; private set; }
    public double Zoom { get; private set; } = 1;
    public Vector Pan { get; private set; }
    public Size SourceSize { get; private set; }
    public void SetSourceSize(int width,int height) { SourceSize=width>0 && height>0 ? new(width,height) : default;Changed?.Invoke(); }
    public event Action? Changed;
    public event Action? ResolutionChanged;
    public void Fit() { var wasActual=ActualPixels;ActualPixels=false; Zoom=1; Pan=default; Changed?.Invoke();if(wasActual)ResolutionChanged?.Invoke(); }
    public void Actual() { var wasActual=ActualPixels;ActualPixels=true; Zoom=1; Pan=default; Changed?.Invoke();if(!wasActual)ResolutionChanged?.Invoke(); }
    public void ToggleActualPixels() { if(ActualPixels || Zoom!=1)Fit();else Actual(); }
    public void Magnify(double factor) { Zoom=Math.Clamp(Zoom*factor,.1,16); Changed?.Invoke(); }
    public void Move(Vector delta) { Pan+=delta; Changed?.Invoke(); }
    internal int PreviewLongEdge(Size area,DpiScale dpi,Size fallback)
    {
        if(ActualPixels)return 0;
        var size=SourceSize.Width>0 ? SourceSize : fallback;
        if(size.Width<=0 || size.Height<=0 || area.Width<=0 || area.Height<=0)return 2000;
        var fit=Math.Min(area.Width*dpi.DpiScaleX/size.Width,area.Height*dpi.DpiScaleY/size.Height);
        var edge=Math.Max(size.Width,size.Height);
        return (int)Math.Min(edge,Math.Max(64,Math.Ceiling(edge*fit*Zoom/64)*64));
    }
}
public sealed partial class PhotoCanvas : FrameworkElement
{
    private static readonly DependencyProperty CanvasBrushProperty=DependencyProperty.Register("CanvasBrush",typeof(Brush),typeof(PhotoCanvas),new FrameworkPropertyMetadata(new SolidColorBrush(Color.FromRgb(28,28,30)),FrameworkPropertyMetadataOptions.AffectsRender));
    private static DependencyProperty OverlayBrush(string name,Brush fallback)=>DependencyProperty.Register(name,typeof(Brush),typeof(PhotoCanvas),
        new FrameworkPropertyMetadata(fallback,(owner,_)=>{var canvas=(PhotoCanvas)owner;canvas.UpdateComparison();canvas.DrawCrop();}));
    private static readonly DependencyProperty OverlayInkProperty=OverlayBrush("OverlayInk",Brushes.White);
    private static readonly DependencyProperty OverlayPaperProperty=OverlayBrush("OverlayPaper",new SolidColorBrush(Color.FromRgb(36,39,45)));
    private static readonly DependencyProperty OverlayAccentProperty=OverlayBrush("OverlayAccent",Brushes.Gold);
    private static readonly DependencyProperty OverlayGridWidthProperty=DependencyProperty.Register("OverlayGridWidth",typeof(double),typeof(PhotoCanvas),new FrameworkPropertyMetadata(.6,(owner,_)=>((PhotoCanvas)owner).DrawCrop()));
    private Brush OverlayInk=>(Brush)GetValue(OverlayInkProperty);
    private Brush OverlayPaper=>(Brush)GetValue(OverlayPaperProperty);
    private BitmapSource? image,mask,comparison,comparisonMask;
    private Viewport? viewport;
    private Point? drag;
    private bool draggingDivider,comparisonEnabled;
    private bool showClipping;
    private readonly VisualCollection layers;
    private readonly ContainerVisual referenceLayer=new(),editedLayer=new();
    private readonly DrawingVisual referenceDrawing=new(),editedDrawing=new(),overlay=new();
    private readonly MatrixTransform imageTransform=new();
    private readonly RectangleGeometry wipeClip=new();
    internal int ContentVersion { get; private set; }
    internal Rect ImageBounds { get; private set; }
    private double divider=.5;
    internal int PreviewLongEdge { get; private set; } = 2000;
    internal event Action<int>? PreviewSizeChanged;
    public bool ComparisonEnabled { get=>comparisonEnabled; set { comparisonEnabled=value;UpdateComparison(); } }
    public double Divider { get=>divider; set { if(!double.IsFinite(value))throw new ArgumentOutOfRangeException(nameof(value));divider=Math.Clamp(value,0,1);UpdateComparison(); } }
    public bool ShowClipping { get=>showClipping; set {if(showClipping==value)return;showClipping=value;DrawImages();} }
    public Viewport? Viewport { get => viewport; set { if(viewport!=null) viewport.Changed-=UpdateTransform; viewport=value; if(value!=null)value.Changed+=UpdateTransform;UpdateTransform(); } }
    public void SetImage(BitmapSource? source,BitmapSource? clipping) { image=source; mask=clipping;DrawImages();UpdateTransform(); }
    public void SetComparison(BitmapSource? source,BitmapSource? clipping) { comparison=source;comparisonMask=clipping;DrawImages();UpdateComparison(); }
    public PhotoCanvas()
    {
        SetResourceReference(CanvasBrushProperty,"CanvasSurface");
        layers=new VisualCollection(this){referenceLayer,editedLayer,overlay,cropOverlay};
        SetResourceReference(OverlayInkProperty,"OverlayInk");SetResourceReference(OverlayPaperProperty,"OverlayPaper");SetResourceReference(OverlayAccentProperty,"OverlayAccent");
        SetResourceReference(OverlayGridWidthProperty,"OverlayGridWidth");
        referenceLayer.Children.Add(referenceDrawing);editedLayer.Children.Add(editedDrawing);
        referenceDrawing.Transform=editedDrawing.Transform=imageTransform;
        RenderOptions.SetBitmapScalingMode(this,BitmapScalingMode.LowQuality);
        ClipToBounds=true; Focusable=true; Cursor=Cursors.Hand;
        MouseWheel+=(_,e)=> { if(!GeometryEditing && image!=null)Viewport?.Magnify(e.Delta>0 ? 1.2 : 1/1.2); e.Handled=image!=null; };
        MouseLeftButtonDown+=(_,e)=> {
            Focus();var point=e.GetPosition(this);
            if(HandleCropDown(point)){e.Handled=true;return;}
            draggingDivider=ComparisonEnabled && Math.Abs(point.X-ActualWidth*Divider)<=18;
            if(e.ClickCount==2 && !draggingDivider && image!=null)
            {
                drag=null;Viewport?.ToggleActualPixels();e.Handled=true;return;
            }
            if(!draggingDivider)drag=point;CaptureMouse();
            e.Handled=true;
        };
        MouseMove+=(_,e)=> {
            var next=e.GetPosition(this);
            if(HandleCropMove(next)){e.Handled=true;return;}
            Cursor=ComparisonEnabled && (draggingDivider || Math.Abs(next.X-ActualWidth*Divider)<=18) ? Cursors.SizeWE : Cursors.Hand;
            if(draggingDivider){if(ActualWidth>0)Divider=next.X/ActualWidth;return;}
            if(drag is not {} point)return;Viewport?.Move(next-point);drag=next;
        };
        MouseLeftButtonUp+=(_,_)=> { EndCropDrag();drag=null;draggingDivider=false;ReleaseMouseCapture(); };
        LostMouseCapture+=(_,_)=>{EndCropDrag();drag=null;draggingDivider=false;};
        KeyDown+=(_,e)=> { if(HandleCropKey(e)){e.Handled=true;return;}if(!ComparisonEnabled)return;if(e.Key is Key.Left or Key.Right){Divider+=e.Key==Key.Left ? -.025 : .025;e.Handled=true;}if(e.Key==Key.Home){Divider=.5;e.Handled=true;} };
        SizeChanged+=(_,_)=>{UpdateTransform();UpdateComparison();};
        IsKeyboardFocusedChanged+=(_,_)=>UpdateComparison();
    }
    protected override int VisualChildrenCount=>layers.Count;
    protected override Visual GetVisualChild(int index)=>layers[index];
    protected override void OnDpiChanged(DpiScale oldDpi,DpiScale newDpi) {base.OnDpiChanged(oldDpi,newDpi);UpdateTransform();}
    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle((Brush)GetValue(CanvasBrushProperty),null,new Rect(RenderSize));
    }
    private void DrawImages()
    {
        ContentVersion++;
        static void Draw(DrawingVisual visual,BitmapSource? bitmap,BitmapSource? clipping,bool show)
        {
            using var dc=visual.RenderOpen();
            if(bitmap==null)return;
            var unit=new Rect(0,0,1,1);dc.DrawImage(bitmap,unit);
            if(show && clipping!=null)dc.DrawImage(clipping,unit);
        }
        Draw(referenceDrawing,comparison,comparisonMask,ShowClipping);
        Draw(editedDrawing,image,mask,ShowClipping);
    }
    private void UpdateTransform()
    {
        if(Viewport==null)return;
        var size=Viewport.SourceSize.Width>0 ? Viewport.SourceSize : image!=null ? new Size(image.PixelWidth,image.PixelHeight) : default;
        var dpi=VisualTreeHelper.GetDpi(this);
        if(image!=null)
        {
            var fit=Math.Min(ActualWidth/size.Width,ActualHeight/size.Height);
            var w=size.Width*(Viewport.ActualPixels ? 1/dpi.DpiScaleX : fit)*Viewport.Zoom;
            var h=size.Height*(Viewport.ActualPixels ? 1/dpi.DpiScaleY : fit)*Viewport.Zoom;
            ImageBounds=new Rect((ActualWidth-w)/2+Viewport.Pan.X,(ActualHeight-h)/2+Viewport.Pan.Y,w,h);
            // Keep image drawing commands and bitmap resources resident while panning.
            imageTransform.Matrix=new Matrix(w,0,0,h,ImageBounds.X,ImageBounds.Y);
        }
        var edge=Viewport.PreviewLongEdge(RenderSize,dpi,size);
        if(edge!=PreviewLongEdge){PreviewLongEdge=edge;PreviewSizeChanged?.Invoke(edge);}
        DrawCrop();
    }
    private void UpdateComparison()
    {
        var wipe=ComparisonEnabled && comparison!=null;
        referenceLayer.Opacity=wipe ? 1 : 0;
        wipeClip.Rect=new Rect(ActualWidth*Divider,0,ActualWidth*(1-Divider),ActualHeight);
        editedLayer.Clip=wipe ? wipeClip : null;
        using var dc=overlay.RenderOpen();
        if(wipe)
        {
            var x=ActualWidth*Divider;var y=ActualHeight/2;
            var pen=new Pen(OverlayInk,1.5);
            dc.DrawLine(new Pen(OverlayPaper,4),new Point(x,0),new Point(x,ActualHeight));
            dc.DrawLine(pen,new Point(x,0),new Point(x,ActualHeight));
            dc.DrawEllipse(OverlayPaper,pen,new Point(x,y),16,16);
            dc.DrawLine(pen,new Point(x-4,y-4),new Point(x-8,y));dc.DrawLine(pen,new Point(x-8,y),new Point(x-4,y+4));
            dc.DrawLine(pen,new Point(x+4,y-4),new Point(x+8,y));dc.DrawLine(pen,new Point(x+8,y),new Point(x+4,y+4));
            if(IsKeyboardFocused){dc.DrawEllipse(null,new Pen(OverlayPaper,4),new Point(x,y),19,19);dc.DrawEllipse(null,new Pen((Brush)GetValue(OverlayAccentProperty),2),new Point(x,y),19,19);}
        }
    }
    protected override AutomationPeer OnCreateAutomationPeer()=>new ComparisonPeer(this);
    private sealed class ComparisonPeer(PhotoCanvas owner) : FrameworkElementAutomationPeer(owner),IRangeValueProvider
    {
        protected override string GetClassNameCore()=>nameof(PhotoCanvas);
        protected override string GetNameCore()=>owner.ComparisonEnabled ? Loc.Text("滑动对比，左侧中性，右侧修改后") : Loc.Text("照片预览");
        public override object? GetPattern(PatternInterface pattern)=>pattern==PatternInterface.RangeValue && owner.ComparisonEnabled ? this : base.GetPattern(pattern);
        public bool IsReadOnly=>false;
        public double LargeChange=>10;
        public double SmallChange=>2.5;
        public double Maximum=>100;
        public double Minimum=>0;
        public double Value=>owner.Divider*100;
        public void SetValue(double value)=>owner.Divider=value/100;
    }
}

public sealed class HistogramView : FrameworkElement
{
    private static readonly DependencyProperty OutlineBrushProperty=DependencyProperty.Register("OutlineBrush",typeof(Brush),typeof(HistogramView),new FrameworkPropertyMetadata(Brushes.Transparent,FrameworkPropertyMetadataOptions.AffectsRender));
    public HistogramView()=>SetResourceReference(OutlineBrushProperty,"HistogramOutline");
    // 高度不足时由 Grid 收缩图形区域，给下方统计文字保留完整行。
    protected override Size MeasureOverride(Size availableSize)=>new(Math.Min(200,availableSize.Width),Math.Min(105,availableSize.Height));
    public uint[]? Bins { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        if(Bins==null)return;
        var peak=Math.Max(1,Bins.Max());
        // Shared linear count axis, additive RGB/CMY/gray overlap colors.
        for(var x=0;x<256;x++)
        {
            var heights=new[]{Bins[x],Bins[256+x],Bins[512+x]};
            var levels=heights.Append(0u).Distinct().Order().ToArray();
            for(var i=1;i<levels.Length;i++)
            {
                var level=levels[i]; var top=ActualHeight*(1-level/(double)peak);
                var bottom=ActualHeight*(1-levels[i-1]/(double)peak);
                var color=Color.FromRgb(heights[0]>=level ? (byte)190 : (byte)24,heights[1]>=level ? (byte)190 : (byte)24,heights[2]>=level ? (byte)190 : (byte)24);
                dc.DrawRectangle(new SolidColorBrush(color),null,new Rect(x*ActualWidth/256,top,ActualWidth/256+.2,bottom-top));
            }
        }
        var outline=(Brush)GetValue(OutlineBrushProperty);
        if(outline is SolidColorBrush { Color.A:0 })return;
        var pen=new Pen(outline,2);
        for(var x=0;x<256;x++)
        {
            var envelope=ActualHeight*(1-Math.Max(Bins[x],Math.Max(Bins[256+x],Bins[512+x]))/(double)peak);
            dc.DrawLine(pen,new Point(x*ActualWidth/256,envelope),new Point((x+1)*ActualWidth/256,envelope));
        }
    }
}

public sealed class AdjustmentRing : FrameworkElement
{
    private static readonly DependencyProperty TrackBrushProperty=DependencyProperty.Register("TrackBrush",typeof(Brush),typeof(AdjustmentRing),new FrameworkPropertyMetadata(Brushes.Gray,FrameworkPropertyMetadataOptions.AffectsRender));
    private static readonly DependencyProperty ProgressBrushProperty=DependencyProperty.Register("ProgressBrush",typeof(Brush),typeof(AdjustmentRing),new FrameworkPropertyMetadata(Brushes.Gold,FrameworkPropertyMetadataOptions.AffectsRender));
    public AdjustmentRing(){SetResourceReference(TrackBrushProperty,"Outline");SetResourceReference(ProgressBrushProperty,"Indicator");}
    public double Progress { get; set; }
    public bool Selected { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        var center=new Point(ActualWidth/2,ActualHeight/2); var radius=Math.Min(ActualWidth,ActualHeight)/2-3;
        var active=Selected ? System.Windows.Documents.TextElement.GetForeground(this) : (Brush)GetValue(ProgressBrushProperty);
        dc.DrawEllipse(null,new Pen(Selected ? active : (Brush)GetValue(TrackBrushProperty),1),center,radius,radius);
        if(Math.Abs(Progress)<.001)return;
        var geometry=new StreamGeometry();
        using(var context=geometry.Open())
        {
            context.BeginFigure(new Point(center.X,center.Y-radius),false,false);
            var angle=Math.Clamp(Progress,-.99999,.99999)*Math.PI*2;
            context.ArcTo(new Point(center.X+radius*Math.Sin(angle),center.Y-radius*Math.Cos(angle)),new Size(radius,radius),0,Math.Abs(Progress)>.5,Progress>0 ? SweepDirection.Clockwise : SweepDirection.Counterclockwise,true,false);
        }
        dc.DrawGeometry(null,new Pen(active,3),geometry);
    }
}
