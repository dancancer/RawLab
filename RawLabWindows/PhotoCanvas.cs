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
public sealed class PhotoCanvas : FrameworkElement
{
    private BitmapSource? image,mask,comparison,comparisonMask;
    private Viewport? viewport;
    private Point? drag;
    private bool draggingDivider,comparisonEnabled;
    private bool geometryEditing;
    private GeometrySettings? cropDraft;
    private CropHandle? cropHandle;
    private CropRect cropBaseline;
    private Point cropStart;
    private double? cropRatio;
    private bool correctionGrid;
    public bool GeometryEditing {
        get => geometryEditing;
        set { geometryEditing=value; drag=null;draggingDivider=false;cropHandle=null;if(IsMouseCaptured)ReleaseMouseCapture();UpdateComparison(); }
    }
    public event Action<CropRect>? CropChanged;
    public void SetCropDraft(GeometrySettings? value, double? ratio, bool denseGrid)
    {
        cropDraft=value;cropRatio=ratio;correctionGrid=denseGrid;UpdateComparison();
    }
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
    internal (BitmapSource? Image, BitmapSource? Clipping) CurrentImage => (image,mask);
    public void SetImage(BitmapSource? source,BitmapSource? clipping) { image=source; mask=clipping;DrawImages();UpdateTransform(); }
    public void SetComparison(BitmapSource? source,BitmapSource? clipping) { comparison=source;comparisonMask=clipping;DrawImages();UpdateComparison(); }
    public PhotoCanvas()
    {
        layers=new VisualCollection(this){referenceLayer,editedLayer,overlay};
        referenceLayer.Children.Add(referenceDrawing);editedLayer.Children.Add(editedDrawing);
        referenceDrawing.Transform=editedDrawing.Transform=imageTransform;
        RenderOptions.SetBitmapScalingMode(this,BitmapScalingMode.LowQuality);
        ClipToBounds=true; Focusable=true; Cursor=Cursors.Hand;
        MouseWheel+=(_,e)=> { if(GeometryEditing){e.Handled=true;return;} Viewport?.Magnify(e.Delta>0 ? 1.2 : 1/1.2); e.Handled=true; };
        MouseLeftButtonDown+=(_,e)=> {
            Focus();var point=e.GetPosition(this);
            if (GeometryEditing) {
                if(cropDraft!=null && ImageBounds.Width>0 && ImageBounds.Height>0) {
                    cropHandle=HitCrop(point);
                    if(cropHandle!=null) { cropBaseline=CropInteraction.FromGeometry(cropDraft);cropStart=point;CaptureMouse(); }
                }
                e.Handled=true;return;
            }
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
            if(GeometryEditing) {
                var handle=cropHandle ?? HitCrop(next);
                Cursor=handle switch { CropHandle.Move=>Cursors.SizeAll, CropHandle.TopLeft or CropHandle.BottomRight=>Cursors.SizeNWSE, CropHandle.TopRight or CropHandle.BottomLeft=>Cursors.SizeNESW, _=>Cursors.Arrow };
                if(cropHandle is {} selected && ImageBounds.Width>0 && ImageBounds.Height>0) {
                    var size=Viewport?.SourceSize ?? default;
                    CropChanged?.Invoke(CropInteraction.Dragging(cropBaseline,selected,(next.X-cropStart.X)/ImageBounds.Width,
                        (next.Y-cropStart.Y)/ImageBounds.Height,size.Width,size.Height,cropRatio));
                }
                e.Handled=true;return;
            }
            Cursor=ComparisonEnabled && (draggingDivider || Math.Abs(next.X-ActualWidth*Divider)<=18) ? Cursors.SizeWE : Cursors.Hand;
            if(draggingDivider){if(ActualWidth>0)Divider=next.X/ActualWidth;return;}
            if(drag is not {} point)return;Viewport?.Move(next-point);drag=next;
        };
        MouseLeftButtonUp+=(_,_)=> { drag=null;draggingDivider=false;cropHandle=null;ReleaseMouseCapture(); };
        LostMouseCapture+=(_,_)=>{drag=null;draggingDivider=false;cropHandle=null;};
        KeyDown+=(_,e)=> {
            if(GeometryEditing && cropDraft!=null && e.Key is Key.Left or Key.Right or Key.Up or Key.Down) {
                var step=Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? .02 : .005;
                CropChanged?.Invoke(CropInteraction.Dragging(CropInteraction.FromGeometry(cropDraft),CropHandle.Move,
                    e.Key==Key.Left ? -step : e.Key==Key.Right ? step : 0,
                    e.Key==Key.Up ? -step : e.Key==Key.Down ? step : 0,1,1,null));
                e.Handled=true;return;
            }
            if(!ComparisonEnabled)return;if(e.Key is Key.Left or Key.Right){Divider+=e.Key==Key.Left ? -.025 : .025;e.Handled=true;}if(e.Key==Key.Home){Divider=.5;e.Handled=true;} };
        SizeChanged+=(_,_)=>{UpdateTransform();UpdateComparison();};
        IsKeyboardFocusedChanged+=(_,_)=>UpdateComparison();
    }
    protected override int VisualChildrenCount=>layers.Count;
    protected override Visual GetVisualChild(int index)=>layers[index];
    protected override void OnDpiChanged(DpiScale oldDpi,DpiScale newDpi) {base.OnDpiChanged(oldDpi,newDpi);UpdateTransform();}
    protected override void OnRender(DrawingContext dc)
    {
        dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(20,21,24)),null,new Rect(RenderSize));
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
        UpdateComparison();
        var edge=Viewport.PreviewLongEdge(RenderSize,dpi,size);
        if(edge!=PreviewLongEdge){PreviewLongEdge=edge;PreviewSizeChanged?.Invoke(edge);}
    }
    private void UpdateComparison()
    {
        var wipe=!GeometryEditing && ComparisonEnabled && comparison!=null;
        referenceLayer.Opacity=wipe ? 1 : 0;
        wipeClip.Rect=new Rect(ActualWidth*Divider,0,ActualWidth*(1-Divider),ActualHeight);
        editedLayer.Clip=wipe ? wipeClip : null;
        using var dc=overlay.RenderOpen();
        if(GeometryEditing && cropDraft!=null && ImageBounds.Width>0 && ImageBounds.Height>0) DrawCrop(dc);
        if(wipe)
        {
            var x=ActualWidth*Divider;var y=ActualHeight/2;
            var pen=new Pen(Brushes.White,1.5);
            dc.DrawLine(new Pen(new SolidColorBrush(Color.FromArgb(120,0,0,0)),4),new Point(x,0),new Point(x,ActualHeight));
            dc.DrawLine(pen,new Point(x,0),new Point(x,ActualHeight));
            dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(36,39,45)),pen,new Point(x,y),16,16);
            dc.DrawLine(pen,new Point(x-4,y-4),new Point(x-8,y));dc.DrawLine(pen,new Point(x-8,y),new Point(x-4,y+4));
            dc.DrawLine(pen,new Point(x+4,y-4),new Point(x+8,y));dc.DrawLine(pen,new Point(x+8,y),new Point(x+4,y+4));
            if(IsKeyboardFocused)dc.DrawEllipse(null,new Pen(new SolidColorBrush(Color.FromRgb(242,210,89)),2),new Point(x,y),19,19);
        }
    }
    private Rect CropBounds => cropDraft is {} value ? new(ImageBounds.X+value.CropX*ImageBounds.Width,
        ImageBounds.Y+value.CropY*ImageBounds.Height,value.CropWidth*ImageBounds.Width,value.CropHeight*ImageBounds.Height) : Rect.Empty;
    private CropHandle? HitCrop(Point point)
    {
        if(cropDraft==null)return null;
        var crop=CropBounds;
        var corners=new[] { (crop.TopLeft,CropHandle.TopLeft), (crop.TopRight,CropHandle.TopRight),
            (crop.BottomLeft,CropHandle.BottomLeft), (crop.BottomRight,CropHandle.BottomRight) };
        foreach(var (corner,handle) in corners) if(Math.Abs(point.X-corner.X)<=18 && Math.Abs(point.Y-corner.Y)<=18)return handle;
        return crop.Contains(point) ? CropHandle.Move : null;
    }
    private void DrawCrop(DrawingContext dc)
    {
        var crop=CropBounds;var full=ImageBounds;
        dc.PushClip(new RectangleGeometry(full));
        var shade=new SolidColorBrush(Color.FromArgb(150,0,0,0));
        dc.DrawRectangle(shade,null,new Rect(full.Left,full.Top,full.Width,Math.Max(0,crop.Top-full.Top)));
        dc.DrawRectangle(shade,null,new Rect(full.Left,crop.Bottom,full.Width,Math.Max(0,full.Bottom-crop.Bottom)));
        dc.DrawRectangle(shade,null,new Rect(full.Left,crop.Top,Math.Max(0,crop.Left-full.Left),crop.Height));
        dc.DrawRectangle(shade,null,new Rect(crop.Right,crop.Top,Math.Max(0,full.Right-crop.Right),crop.Height));
        var gridPen=new Pen(new SolidColorBrush(Color.FromArgb(155,255,255,255)),1);
        var divisions=correctionGrid ? 6 : 3;
        for(var i=1;i<divisions;i++) {
            var x=crop.Left+crop.Width*i/divisions;var y=crop.Top+crop.Height*i/divisions;
            dc.DrawLine(gridPen,new(x,crop.Top),new(x,crop.Bottom));dc.DrawLine(gridPen,new(crop.Left,y),new(crop.Right,y));
        }
        dc.DrawRectangle(null,new Pen(Brushes.White,1),crop);
        dc.Pop();
        var handles=new Pen(Brushes.White,3){StartLineCap=PenLineCap.Square,EndLineCap=PenLineCap.Square};
        foreach(var (point,dx,dy) in new[] { (crop.TopLeft,1,1),(crop.TopRight,-1,1),(crop.BottomLeft,1,-1),(crop.BottomRight,-1,-1) }) {
            dc.DrawLine(new Pen(Brushes.Black,5),new(point.X+dx*16,point.Y),point);
            dc.DrawLine(new Pen(Brushes.Black,5),point,new(point.X,point.Y+dy*16));
            dc.DrawLine(handles,new(point.X+dx*16,point.Y),point);dc.DrawLine(handles,point,new(point.X,point.Y+dy*16));
        }
        if(IsKeyboardFocused)dc.DrawRectangle(null,new Pen(new SolidColorBrush(Color.FromRgb(242,210,89)),1),new Rect(crop.Left-3,crop.Top-3,crop.Width+6,crop.Height+6));
    }
    protected override AutomationPeer OnCreateAutomationPeer()=>new ComparisonPeer(this);
    private sealed class ComparisonPeer(PhotoCanvas owner) : FrameworkElementAutomationPeer(owner),IRangeValueProvider
    {
        protected override string GetClassNameCore()=>nameof(PhotoCanvas);
        protected override string GetNameCore()=>owner.GeometryEditing ? Loc.Text("裁切框：拖动四角调整，方向键移动。Enter 应用，Escape 取消。") : owner.ComparisonEnabled ? Loc.Text("滑动对比，左侧中性，右侧修改后") : Loc.Text("照片预览");
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
    }
}

public sealed class AdjustmentRing : FrameworkElement
{
    public double Progress { get; set; }
    public bool Selected { get; set; }
    protected override void OnRender(DrawingContext dc)
    {
        var center=new Point(ActualWidth/2,ActualHeight/2); var radius=Math.Min(ActualWidth,ActualHeight)/2-3;
        dc.DrawEllipse(Selected ? new SolidColorBrush(Color.FromArgb(24,242,210,89)) : null,new Pen(new SolidColorBrush(Selected ? Color.FromRgb(242,210,89) : Color.FromRgb(91,95,104)),1),center,radius,radius);
        if(Math.Abs(Progress)<.001)return;
        var geometry=new StreamGeometry();
        using(var context=geometry.Open())
        {
            context.BeginFigure(new Point(center.X,center.Y-radius),false,false);
            var angle=Math.Clamp(Progress,-.99999,.99999)*Math.PI*2;
            context.ArcTo(new Point(center.X+radius*Math.Sin(angle),center.Y-radius*Math.Cos(angle)),new Size(radius,radius),0,Math.Abs(Progress)>.5,Progress>0 ? SweepDirection.Clockwise : SweepDirection.Counterclockwise,true,false);
        }
        dc.DrawGeometry(null,new Pen(new SolidColorBrush(Color.FromRgb(242,210,89)),3),geometry);
    }
}
