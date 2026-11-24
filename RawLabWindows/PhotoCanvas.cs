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
    public void ToggleActualPixelsAt(Point cursor,Rect imageBounds)
    {
        if(ActualPixels || Zoom!=1) { Fit(); return; }
        var wasActual=ActualPixels;
        ActualPixels=true;
        Zoom=1;
        if(imageBounds.Width>0 && imageBounds.Height>0 && imageBounds.Contains(cursor))
        {
            focusX=Math.Clamp((cursor.X-imageBounds.X)/imageBounds.Width,0,1);
            focusY=Math.Clamp((cursor.Y-imageBounds.Y)/imageBounds.Height,0,1);
        }
        else { focusX=focusY=.5; }
        Changed?.Invoke();
        if(!wasActual)ResolutionChanged?.Invoke();
    }
    public void Magnify(double factor) { Zoom=Math.Clamp(Zoom*factor,.1,16); Changed?.Invoke(); }
    public void MagnifyAt(double factor,Point cursor,Rect imageBounds)
    {
        if(!double.IsFinite(factor) || factor<=0)return;
        var old=Zoom;
        var next=Math.Clamp(old*factor,.1,16);
        if(next!=old && imageBounds.Width>0 && imageBounds.Height>0 && imageBounds.Contains(cursor))
        {
            focusX=PhotoViewProjection.ZoomFocus(focusX,(cursor.X-imageBounds.X)/imageBounds.Width,old,next);
            focusY=PhotoViewProjection.ZoomFocus(focusY,(cursor.Y-imageBounds.Y)/imageBounds.Height,old,next);
        }
        Zoom=next;
        Changed?.Invoke();
    }
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
    internal BitmapSource? ImageSource => image;
    internal BitmapSource? MaskSource => mask;
    internal Point? DragPoint => drag;
    internal DispatcherTimer HoldTimer => holdTimer;
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
    internal void SetClippingMask(BitmapSource clipping)
    {
        if (ReferenceEquals(mask, clipping)) return;
        mask = clipping;
        DrawImages();
    }
    public void SetComparison(BitmapSource? source,BitmapSource? clipping) { if(ReferenceEquals(comparison,source) && ReferenceEquals(comparisonMask,clipping))return;comparison=source;comparisonMask=clipping;DrawImages();UpdateComparison(); }
    public PhotoCanvas()
    {
        SetResourceReference(CanvasBrushProperty,"CanvasSurface");
        layers=new VisualCollection(this){referenceLayer,editedLayer,overlay,cropOverlay,hslTargetDrawing,inspectionDrawing};
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
        MouseWheel+=(_,e)=> { CancelHslPointer();CancelHold();if(!GeometryEditing && image!=null)Viewport?.MagnifyAt(e.Delta>0 ? 1.2 : 1/1.2,e.GetPosition(this),ImageBounds);e.Handled=image!=null; };
        MouseLeftButtonDown+=(_,e)=> {
            Focus();var point=e.GetPosition(this);CancelHold();
            if(HandleCropDown(point)){e.Handled=true;return;}
            draggingDivider=ComparisonEnabled && VisibleImageBounds.Contains(point) && Math.Abs(point.X-DividerX)<=18;
            if(HslTargetEnabled) {
                if(draggingDivider)CancelHslPointer();else {BeginHslPointer(point);e.Handled=true;return;}
            }
            if(WbProbeEnabled) {
                if(draggingDivider)WbProbeCancelled?.Invoke();
                else if(HslCoordinates(point) is {} wbSample)WbProbeClicked?.Invoke(wbSample);
                else WbProbeRejected?.Invoke();
                e.Handled=true;return;
            }
            BeginPendingInspectionPin(point);
            if(e.ClickCount==2 && !draggingDivider && !pendingInspectionPin && image!=null)
            {drag=null;Viewport?.ToggleActualPixelsAt(point,ImageBounds);e.Handled=true;return;}
            pressOrigin=point;panning=false;
            if(!draggingDivider){drag=point;if(image!=null && ImageBounds.Contains(point) && !ComparisonEnabled && !pendingInspectionPin)holdTimer.Start();}
            CaptureMouse();e.Handled=true;
        };
        MouseMove+=(_,e)=> {
            var next=e.GetPosition(this);
            if(MoveHslPointer(next)){e.Handled=true;return;}
            if(HandleCropMove(next)){CancelHold();e.Handled=true;return;}
            HandleInspectionMove(next);
            Cursor=ComparisonEnabled && VisibleImageBounds.Contains(next) && (draggingDivider || Math.Abs(next.X-DividerX)<=18) ? Cursors.SizeWE : (WbProbeEnabled || HslTargetEnabled || inspectionPinMode ? Cursors.Cross : Cursors.Hand);
            if(draggingDivider){if(ImageBounds.Width>0)Divider=(next.X-ImageBounds.X)/ImageBounds.Width;return;}
            if(drag is not {} point)return;
            if(!panning && (Math.Abs(next.X-pressOrigin.X)>SystemParameters.MinimumHorizontalDragDistance || Math.Abs(next.Y-pressOrigin.Y)>SystemParameters.MinimumVerticalDragDistance))
            {panning=true;pendingInspectionPin=false;CancelHold();}
            if(panning){Viewport?.Move(next-point,ImageBounds.Size);drag=next;}
        };
        MouseLeftButtonUp+=(_,e)=>{if(FinishHslPointer(e.GetPosition(this)) || HslTargetEnabled && !draggingDivider)return;var shouldPin=pendingInspectionPin && !panning && !draggingDivider;var upPoint=e.GetPosition(this);EndPointer();if(shouldPin)CommitInspectionPin(upPoint);};
        LostMouseCapture+=(_,_)=>{if(hslPointerOrigin!=null)CancelHslPointer();CancelHold();EndCropDrag();drag=null;pendingInspectionPin=draggingDivider=panning=false;};
        MouseLeave+=(_,_)=>InspectionHoverChanged?.Invoke(null);
        LostKeyboardFocus+=(_,_)=>{CancelHslPointer();CancelHold();};
        TouchDown+=(_,_)=>{CancelHslPointer();CancelHold();};
        IsVisibleChanged+=(_,_)=>{if(!IsVisible)CancelPointer();else UpdateTransform();};
        KeyDown+=(_,e)=> { if(HandleHslKey(e)){e.Handled=true;return;}if(WbProbeEnabled && e.Key==Key.Escape){WbProbeCancelled?.Invoke();e.Handled=true;return;}if(HandleCropKey(e)){CancelHold();e.Handled=true;return;}if(!ComparisonEnabled)return;if(e.Key is Key.Left or Key.Right){Divider+=e.Key==Key.Left ? -.025 : .025;e.Handled=true;}if(e.Key==Key.Home){Divider=.5;e.Handled=true;} };
        SizeChanged+=(_,_)=>{CancelPointer();UpdateTransform();};
        IsKeyboardFocusedChanged+=(_,_)=>UpdateComparison();
    }
    internal void CancelHold(){holdTimer.Stop();HoldEnded?.Invoke();}
    internal void CancelPointer(){CancelHslPointer();CancelHold();EndCropDrag();drag=null;pendingInspectionPin=draggingDivider=panning=false;if(IsMouseCaptured)ReleaseMouseCapture();}
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
        Draw(referenceDrawing,comparison,comparisonMask,ShowClipping && !HslTargetEnabled && !WbProbeEnabled);
        Draw(editedDrawing,image,mask,ShowClipping && !HslTargetEnabled && !WbProbeEnabled);
    }
    private void UpdateTransform()
    {
        if(Viewport==null)return;
        var size=Viewport.SourceSize.Width>0 ? Viewport.SourceSize : image!=null ? new Size(image.PixelWidth,image.PixelHeight) : default;
        var dpi=VisualTreeHelper.GetDpi(this);
        var margin=WorkspaceLayout.ContentCanvasMargin(PhotoMargin);
        if(image!=null)
        {
            var oldBounds=ImageBounds;
            ImageBounds=Viewport.Project(RenderSize,size,dpi,margin);
            if(oldBounds!=ImageBounds)CancelHslPointer();
            var w=ImageBounds.Width;var h=ImageBounds.Height;
            // Keep image drawing commands and bitmap resources resident while panning.
            imageTransform.Matrix=new Matrix(w,0,0,h,ImageBounds.X,ImageBounds.Y);
        }
        var demand=PhotoMargin ? new Size(Math.Max(1,ActualWidth-margin*2),Math.Max(1,ActualHeight-margin*2)) : RenderSize;
        var edge=Viewport.PreviewLongEdge(demand,dpi,size);
        if(edge!=PreviewLongEdge){PreviewLongEdge=edge;PreviewSizeChanged?.Invoke(edge);}
        DrawCrop();DrawHslTarget();DrawInspectionAnchors();UpdateComparison();ImageBoundsChanged?.Invoke();
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
    private uint[]? hdrBins;
    private float hdrHeadroom = 1;
    internal double? LuminanceCursor { get; private set; }

    internal void SetLuminanceCursor(double? value)
    {
        var next = value is { } v && double.IsFinite(v) ? Math.Clamp(v, 0.0, 1.0) : (double?)null;
        if (LuminanceCursor == next) return;
        LuminanceCursor = next;
        InvalidateVisual();
    }

    internal void SetHdrStatistics(uint[]? bins, float headroom)
    {
        if (ReferenceEquals(hdrBins, bins) && hdrHeadroom == headroom) return;
        hdrBins = bins;
        hdrHeadroom = headroom;
        InvalidateVisual();
    }
    private static readonly DependencyProperty OutlineBrushProperty=DependencyProperty.Register("OutlineBrush",typeof(Brush),typeof(HistogramView),new FrameworkPropertyMetadata(Brushes.Transparent,FrameworkPropertyMetadataOptions.AffectsRender));
    private static readonly Brush[] ChannelMixBrushes = BuildChannelMixBrushes();
    private static readonly Pen HdrBlackPen = CreateFrozenPen(Brushes.Black, 5);
    private static readonly Pen HdrWhitePen = CreateFrozenPen(Brushes.White, 2);
    private static readonly Pen HdrScreenPen = CreateFrozenPen(Brushes.Yellow, 2, DashStyles.Dash);
    private static readonly Pen CursorBlackPen = CreateFrozenPen(Brushes.Black, 3.0);
    private static readonly Pen CursorWhitePen = CreateFrozenPen(Brushes.White, 1.2);
    private static Brush[] BuildChannelMixBrushes()
    {
        var brushes = new Brush[8];
        for (var mask = 0; mask < 8; mask++)
        {
            var brush = new SolidColorBrush(Color.FromRgb(
                (mask & 1) != 0 ? (byte)190 : (byte)24,
                (mask & 2) != 0 ? (byte)190 : (byte)24,
                (mask & 4) != 0 ? (byte)190 : (byte)24));
            brush.Freeze();
            brushes[mask] = brush;
        }
        return brushes;
    }
    private static Pen CreateFrozenPen(Brush brush, double thickness, DashStyle? dashStyle = null)
    {
        var pen = new Pen(brush, thickness);
        if (dashStyle != null) pen.DashStyle = dashStyle;
        pen.Freeze();
        return pen;
    }
    public HistogramView()=>SetResourceReference(OutlineBrushProperty,"HistogramOutline");
    // 高度不足时由 Grid 收缩图形区域，给下方统计文字保留完整行。
    protected override Size MeasureOverride(Size availableSize)=>new(Math.Min(200,availableSize.Width),Math.Min(105,availableSize.Height));
    public uint[]? Bins { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        if(hdrBins is {Length:256} hdr) {
            uint maximum=1;
            for(var i=0;i<256;i++)if(hdr[i]>maximum)maximum=hdr[i];
            for(var i=0;i<256;i++)dc.DrawRectangle(Brushes.LightGray,null,
                new Rect(i*ActualWidth/256,ActualHeight*(1-hdr[i]/(double)maximum),ActualWidth/256+.2,ActualHeight*hdr[i]/maximum));
            var reference=ActualWidth/2;var screen=Math.Clamp((Math.Log2(Math.Max(1,hdrHeadroom))+8)/16*ActualWidth,0,ActualWidth);
            dc.DrawLine(HdrBlackPen,new Point(reference,0),new Point(reference,ActualHeight));
            dc.DrawLine(HdrWhitePen,new Point(reference,0),new Point(reference,ActualHeight));
            dc.DrawLine(HdrBlackPen,new Point(screen,0),new Point(screen,ActualHeight));
            dc.DrawLine(HdrScreenPen,new Point(screen,0),new Point(screen,ActualHeight));
            DrawLuminanceCursor(dc);
            return;
        }
        if(Bins==null || Bins.Length<768)return;
        uint peak=1;
        for(var i=0;i<768;i++)if(Bins[i]>peak)peak=Bins[i];
        // Shared linear count axis, additive RGB/CMY/gray overlap colors.
        var barWidth = ActualWidth/256+.2;
        for(var x=0;x<256;x++)
        {
            var r=Bins[x]; var g=Bins[256+x]; var b=Bins[512+x];
            var l0=r; var l1=g; var l2=b;
            if(l0>l1)(l0,l1)=(l1,l0);
            if(l1>l2)(l1,l2)=(l2,l1);
            if(l0>l1)(l0,l1)=(l1,l0);
            var barX = x*ActualWidth/256;
            DrawHistogramBand(dc, barX, barWidth, ActualHeight, peak, r, g, b, 0, l0);
            DrawHistogramBand(dc, barX, barWidth, ActualHeight, peak, r, g, b, l0, l1);
            DrawHistogramBand(dc, barX, barWidth, ActualHeight, peak, r, g, b, l1, l2);
        }
        var outline=(Brush)GetValue(OutlineBrushProperty);
        if(outline is not SolidColorBrush { Color.A:0 })
        {
            var pen=new Pen(outline,2);
            for(var x=0;x<256;x++)
            {
                var envelope=ActualHeight*(1-Math.Max(Bins[x],Math.Max(Bins[256+x],Bins[512+x]))/(double)peak);
                dc.DrawLine(pen,new Point(x*ActualWidth/256,envelope),new Point((x+1)*ActualWidth/256,envelope));
            }
        }
        DrawLuminanceCursor(dc);
    }

    private void DrawLuminanceCursor(DrawingContext dc)
    {
        if (LuminanceCursor is not { } cursor || ActualWidth <= 0 || ActualHeight <= 0) return;
        var x = Math.Clamp(cursor, 0.0, 1.0) * ActualWidth;
        dc.DrawLine(CursorBlackPen, new Point(x, 0), new Point(x, ActualHeight));
        dc.DrawLine(CursorWhitePen, new Point(x, 0), new Point(x, ActualHeight));
        var triangle = new StreamGeometry();
        using (var ctx = triangle.Open())
        {
            ctx.BeginFigure(new Point(x, 5), true, true);
            ctx.LineTo(new Point(x - 4, 0), true, false);
            ctx.LineTo(new Point(x + 4, 0), true, false);
        }
        triangle.Freeze();
        dc.DrawGeometry(Brushes.Gold, null, triangle);
    }

    private static void DrawHistogramBand(DrawingContext dc, double barX, double barWidth, double height, uint peak, uint r, uint g, uint b, uint low, uint high)
    {
        if (high <= low) return;
        var top = height * (1 - high / (double)peak);
        var bottom = height * (1 - low / (double)peak);
        var mask = (r >= high ? 1 : 0) | (g >= high ? 2 : 0) | (b >= high ? 4 : 0);
        dc.DrawRectangle(ChannelMixBrushes[mask], null, new Rect(barX, top, barWidth, bottom - top));
    }
}

public sealed class AdjustmentRing : FrameworkElement
{
    private static readonly DependencyProperty ProgressBrushProperty=DependencyProperty.Register("ProgressBrush",typeof(Brush),typeof(AdjustmentRing),new FrameworkPropertyMetadata(Brushes.Gold,FrameworkPropertyMetadataOptions.AffectsRender));
    public AdjustmentRing()=>SetResourceReference(ProgressBrushProperty,"Indicator");
    public bool Compact { get; set; }
    public double Progress { get; set; }
    public bool Selected { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        if(Math.Abs(Progress)>=.001)dc.DrawEllipse((Brush)GetValue(ProgressBrushProperty),null,new Point(ActualWidth-1,ActualHeight-1),2,2);
    }
}
