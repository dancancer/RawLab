using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Threading;

namespace RawLab.Windows;
public sealed class Viewport
{
    public bool ActualPixels { get; private set; }
    public double Zoom { get; private set; } = 1;
    private double focusX=.5,focusY=.5;
    private Size lastProjection;
    public Vector Pan=>new(Math.Round((.5-focusX)*lastProjection.Width,8),Math.Round((.5-focusY)*lastProjection.Height,8));
    public Size SourceSize { get; private set; }
    public void SetSourceSize(int width,int height) { SourceSize=width>0 && height>0 ? new(width,height) : default;Changed?.Invoke(); }
    public event Action? Changed;
    public event Action? ResolutionChanged;
    public void Fit() { var wasActual=ActualPixels;ActualPixels=false; Zoom=1; focusX=focusY=.5; Changed?.Invoke();if(wasActual)ResolutionChanged?.Invoke(); }
    public void Actual() { var wasActual=ActualPixels;ActualPixels=true; Zoom=1; focusX=focusY=.5; Changed?.Invoke();if(!wasActual)ResolutionChanged?.Invoke(); }
    public void ToggleActualPixels() { if(ActualPixels || Zoom!=1)Fit();else Actual(); }
    public void Magnify(double factor) { Zoom=Math.Clamp(Zoom*factor,.1,16); Changed?.Invoke(); }
    public void Move(Vector delta)=>Move(delta,lastProjection);
    internal void Move(Vector delta,Size photo)
    {if(photo.Width<=0 || photo.Height<=0)return;focusX-=delta.X/photo.Width;focusY-=delta.Y/photo.Height;Changed?.Invoke();}
    internal Rect Project(Size area,Size source,DpiScale dpi,double margin)
    {
        var value=PhotoViewProjection.Project(area.Width,area.Height,source.Width,source.Height,Zoom,focusX,focusY,margin,
            ActualPixels ? 1/dpi.DpiScaleX : 0,ActualPixels ? 1/dpi.DpiScaleY : 0);
        lastProjection=new(value.Width,value.Height);return new(value.X,value.Y,value.Width,value.Height);
    }
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
    private bool draggingDivider,comparisonEnabled,showingBefore,photoMargin,panning;
    private Point pressOrigin;
    private readonly DispatcherTimer holdTimer=new();
    public event Action? HoldStarted;
    public event Action? HoldEnded;
    public event Action? ImageBoundsChanged;
    public event Action? DividerChanged;
    public bool PhotoMargin {get=>photoMargin;set{if(photoMargin==value)return;photoMargin=value;UpdateTransform();}}
    public bool ShowingBefore {get=>showingBefore;set{showingBefore=value;UpdateComparison();}}
    internal Rect VisibleImageBounds=>Rect.Intersect(ImageBounds,new Rect(RenderSize));
    private double DividerX=>ImageBounds.X+ImageBounds.Width*Divider;
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
    public bool ComparisonEnabled { get=>comparisonEnabled; set { comparisonEnabled=value;if(value)CancelHold();UpdateComparison(); } }
    public double Divider { get=>divider; set { if(!double.IsFinite(value))throw new ArgumentOutOfRangeException(nameof(value));divider=Math.Clamp(value,0,1);UpdateComparison();DividerChanged?.Invoke(); } }
    public bool ShowClipping { get=>showClipping; set {if(showClipping==value)return;showClipping=value;DrawImages();} }
    public Viewport? Viewport { get => viewport; set { if(viewport!=null) viewport.Changed-=UpdateTransform; viewport=value; if(value!=null)value.Changed+=UpdateTransform;UpdateTransform(); } }
    public void SetImage(BitmapSource? source,BitmapSource? clipping) { if(ReferenceEquals(image,source) && ReferenceEquals(mask,clipping))return;image=source; mask=clipping;DrawImages();UpdateTransform(); }
    public void SetComparison(BitmapSource? source,BitmapSource? clipping) { if(ReferenceEquals(comparison,source) && ReferenceEquals(comparisonMask,clipping))return;comparison=source;comparisonMask=clipping;DrawImages();UpdateComparison(); }
    public PhotoCanvas()
    {
        SetResourceReference(CanvasBrushProperty,"CanvasSurface");
        layers=new VisualCollection(this){referenceLayer,editedLayer,overlay,cropOverlay,hslTargetDrawing};
        SetResourceReference(OverlayInkProperty,"OverlayInk");SetResourceReference(OverlayPaperProperty,"OverlayPaper");SetResourceReference(OverlayAccentProperty,"OverlayAccent");
        SetResourceReference(OverlayGridWidthProperty,"OverlayGridWidth");
        referenceLayer.Children.Add(referenceDrawing);editedLayer.Children.Add(editedDrawing);
        referenceDrawing.Transform=editedDrawing.Transform=imageTransform;
        RenderOptions.SetBitmapScalingMode(this,BitmapScalingMode.LowQuality);
        ClipToBounds=true; Focusable=true; Cursor=Cursors.Hand;
        // 照片只接收查看快捷键，避免输入法组合在焦点往返后吞掉原始按键；文本控件仍保留输入法。
        InputMethod.SetIsInputMethodEnabled(this,false);
        holdTimer.Interval=TimeSpan.FromMilliseconds(Math.Max(1,SystemParameters.MouseHoverTime.TotalMilliseconds));
        holdTimer.Tick+=(_,_)=>{holdTimer.Stop();if(drag!=null && !panning && !GeometryEditing && !ComparisonEnabled && Mouse.LeftButton==MouseButtonState.Pressed)HoldStarted?.Invoke();};
        MouseWheel+=(_,e)=> { CancelHslPointer();CancelHold();if(!GeometryEditing && image!=null)Viewport?.Magnify(e.Delta>0 ? 1.2 : 1/1.2);e.Handled=image!=null; };
        MouseLeftButtonDown+=(_,e)=> {
            Focus();var point=e.GetPosition(this);CancelHold();
            if(HandleCropDown(point)){e.Handled=true;return;}
            draggingDivider=ComparisonEnabled && VisibleImageBounds.Contains(point) && Math.Abs(point.X-DividerX)<=18;
            if(HslTargetEnabled) {
                if(draggingDivider)CancelHslPointer();else {BeginHslPointer(point);e.Handled=true;return;}
            }
            if(e.ClickCount==2 && !draggingDivider && image!=null)
            {drag=null;Viewport?.ToggleActualPixels();e.Handled=true;return;}
            pressOrigin=point;panning=false;
            if(!draggingDivider){drag=point;if(image!=null && ImageBounds.Contains(point) && !ComparisonEnabled)holdTimer.Start();}
            CaptureMouse();e.Handled=true;
        };
        MouseMove+=(_,e)=> {
            var next=e.GetPosition(this);
            if(MoveHslPointer(next)){e.Handled=true;return;}
            if(HandleCropMove(next)){CancelHold();e.Handled=true;return;}
            Cursor=ComparisonEnabled && VisibleImageBounds.Contains(next) && (draggingDivider || Math.Abs(next.X-DividerX)<=18) ? Cursors.SizeWE : Cursors.Hand;
            if(draggingDivider){if(ImageBounds.Width>0)Divider=(next.X-ImageBounds.X)/ImageBounds.Width;return;}
            if(drag is not {} point)return;
            if(!panning && (Math.Abs(next.X-pressOrigin.X)>SystemParameters.MinimumHorizontalDragDistance || Math.Abs(next.Y-pressOrigin.Y)>SystemParameters.MinimumVerticalDragDistance))
            {panning=true;CancelHold();}
            if(panning){Viewport?.Move(next-point,ImageBounds.Size);drag=next;}
        };
        MouseLeftButtonUp+=(_,e)=>{if(FinishHslPointer(e.GetPosition(this)) || HslTargetEnabled && !draggingDivider)return;EndPointer();};
        LostMouseCapture+=(_,_)=>{if(hslPointerOrigin!=null)CancelHslPointer();CancelHold();EndCropDrag();drag=null;draggingDivider=panning=false;};
        LostKeyboardFocus+=(_,_)=>{CancelHslPointer();CancelHold();};
        TouchDown+=(_,_)=>{CancelHslPointer();CancelHold();};
        IsVisibleChanged+=(_,_)=>{if(!IsVisible)CancelPointer();else UpdateTransform();};
        KeyDown+=(_,e)=> { if(HandleHslKey(e)){e.Handled=true;return;}if(HandleCropKey(e)){CancelHold();e.Handled=true;return;}if(!ComparisonEnabled)return;if(e.Key is Key.Left or Key.Right){Divider+=e.Key==Key.Left ? -.025 : .025;e.Handled=true;}if(e.Key==Key.Home){Divider=.5;e.Handled=true;} };
        SizeChanged+=(_,_)=>{CancelPointer();UpdateTransform();};
        IsKeyboardFocusedChanged+=(_,_)=>UpdateComparison();
    }
    internal void CancelHold(){holdTimer.Stop();HoldEnded?.Invoke();}
    internal void CancelPointer(){CancelHslPointer();CancelHold();EndCropDrag();drag=null;draggingDivider=panning=false;if(IsMouseCaptured)ReleaseMouseCapture();}
    private void EndPointer(){CancelPointer();}
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
        Draw(referenceDrawing,comparison,comparisonMask,ShowClipping && !HslTargetEnabled);
        Draw(editedDrawing,image,mask,ShowClipping && !HslTargetEnabled);
    }
    private void UpdateTransform()
    {
        if(Viewport==null)return;
        var size=Viewport.SourceSize.Width>0 ? Viewport.SourceSize : image!=null ? new Size(image.PixelWidth,image.PixelHeight) : default;
        var dpi=VisualTreeHelper.GetDpi(this);
        if(image!=null)
        {
            var oldBounds=ImageBounds;
            ImageBounds=Viewport.Project(RenderSize,size,dpi,PhotoMargin ? 16 : 0);
            if(oldBounds!=ImageBounds)CancelHslPointer();
            var w=ImageBounds.Width;var h=ImageBounds.Height;
            // Keep image drawing commands and bitmap resources resident while panning.
            imageTransform.Matrix=new Matrix(w,0,0,h,ImageBounds.X,ImageBounds.Y);
        }
        var demand=PhotoMargin ? new Size(Math.Max(1,ActualWidth-32),Math.Max(1,ActualHeight-32)) : RenderSize;
        var edge=Viewport.PreviewLongEdge(demand,dpi,size);
        if(edge!=PreviewLongEdge){PreviewLongEdge=edge;PreviewSizeChanged?.Invoke(edge);}
        DrawCrop();DrawHslTarget();UpdateComparison();ImageBoundsChanged?.Invoke();
    }
    private void UpdateComparison()
    {
        var wipe=ComparisonEnabled && comparison!=null;
        referenceLayer.Opacity=wipe || ShowingBefore && comparison!=null ? 1 : 0;
        editedLayer.Opacity=ShowingBefore && comparison!=null ? 0 : 1;
        wipeClip.Rect=ImageBounds.IsEmpty ? Rect.Empty : new Rect(DividerX,ImageBounds.Y,Math.Max(0,ImageBounds.Right-DividerX),ImageBounds.Height);
        editedLayer.Clip=wipe ? wipeClip : null;
        using var dc=overlay.RenderOpen();
        if(wipe && !VisibleImageBounds.IsEmpty)
        {
            var bounds=VisibleImageBounds;dc.PushClip(new RectangleGeometry(bounds));
            var x=DividerX;var y=bounds.Y+bounds.Height/2;
            var pen=new Pen(OverlayInk,1.5);
            dc.DrawLine(new Pen(OverlayPaper,4),new Point(x,ImageBounds.Top),new Point(x,ImageBounds.Bottom));
            dc.DrawLine(pen,new Point(x,ImageBounds.Top),new Point(x,ImageBounds.Bottom));
            dc.DrawEllipse(OverlayPaper,pen,new Point(x,y),16,16);
            dc.DrawLine(pen,new Point(x-4,y-4),new Point(x-8,y));dc.DrawLine(pen,new Point(x-8,y),new Point(x-4,y+4));
            dc.DrawLine(pen,new Point(x+4,y-4),new Point(x+8,y));dc.DrawLine(pen,new Point(x+8,y),new Point(x+4,y+4));
            if(IsKeyboardFocused){dc.DrawEllipse(null,new Pen(OverlayPaper,4),new Point(x,y),19,19);dc.DrawEllipse(null,new Pen((Brush)GetValue(OverlayAccentProperty),2),new Point(x,y),19,19);}
            dc.Pop();
        }
    }
    protected override AutomationPeer OnCreateAutomationPeer()=>new ComparisonPeer(this);
    private sealed class ComparisonPeer(PhotoCanvas owner) : FrameworkElementAutomationPeer(owner),IRangeValueProvider
    {
        protected override string GetClassNameCore()=>nameof(PhotoCanvas);
        protected override string GetNameCore()=>owner.ComparisonEnabled ? Loc.Text("分割位置") : Loc.Text("照片预览");
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
    internal uint[]? HDRBins { get; set; }
    internal float HDRHeadroom { get; set; } = 1;
    private static readonly DependencyProperty OutlineBrushProperty=DependencyProperty.Register("OutlineBrush",typeof(Brush),typeof(HistogramView),new FrameworkPropertyMetadata(Brushes.Transparent,FrameworkPropertyMetadataOptions.AffectsRender));
    public HistogramView()=>SetResourceReference(OutlineBrushProperty,"HistogramOutline");
    // 高度不足时由 Grid 收缩图形区域，给下方统计文字保留完整行。
    protected override Size MeasureOverride(Size availableSize)=>new(Math.Min(200,availableSize.Width),Math.Min(105,availableSize.Height));
    public uint[]? Bins { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        if(HDRBins is {Length:256} hdr) {
            var maximum=Math.Max(1,hdr.Max());
            for(var i=0;i<256;i++)dc.DrawRectangle(Brushes.LightGray,null,
                new Rect(i*ActualWidth/256,ActualHeight*(1-hdr[i]/(double)maximum),ActualWidth/256+.2,ActualHeight*hdr[i]/maximum));
            var reference=ActualWidth/2;var screen=Math.Clamp((Math.Log2(Math.Max(1,HDRHeadroom))+8)/16*ActualWidth,0,ActualWidth);
            dc.DrawLine(new Pen(Brushes.Black,5),new Point(reference,0),new Point(reference,ActualHeight));
            dc.DrawLine(new Pen(Brushes.White,2),new Point(reference,0),new Point(reference,ActualHeight));
            dc.DrawLine(new Pen(Brushes.Black,5),new Point(screen,0),new Point(screen,ActualHeight));
            dc.DrawLine(new Pen(Brushes.Yellow,2){DashStyle=DashStyles.Dash},new Point(screen,0),new Point(screen,ActualHeight));
            return;
        }
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
    public bool Compact { get; set; }
    public double Progress { get; set; }
    public bool Selected { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        if(Compact) {
            if(Math.Abs(Progress)>=.001)dc.DrawEllipse((Brush)GetValue(ProgressBrushProperty),null,new Point(ActualWidth-1,ActualHeight-1),2,2);
            return;
        }
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
