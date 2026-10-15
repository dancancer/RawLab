using System.Windows;
using System.Windows.Input;
using System.Windows.Media;

namespace RawLab.Windows;
public sealed partial class PhotoCanvas
{
    private readonly DrawingVisual cropOverlay=new();
    private GeometrySettings? cropDraft;
    private double? cropRatio;
    private bool cropGrid;
    private CropHandle? cropHandle;
    private Point cropStart;
    private CropRect originalCrop;
    public bool GeometryEditing { get; set; }
    public event Action<GeometrySettings,bool>? CropChanged;
    public void SetCropDraft(GeometrySettings? value,double? aspect,bool grid)
    {cropDraft=value;cropRatio=aspect;cropGrid=grid;DrawCrop();}
    private Rect CropBounds=>cropDraft==null || ImageBounds.IsEmpty ? Rect.Empty : new(
        ImageBounds.X+cropDraft.CropX*ImageBounds.Width,ImageBounds.Y+cropDraft.CropY*ImageBounds.Height,
        cropDraft.CropWidth*ImageBounds.Width,cropDraft.CropHeight*ImageBounds.Height);
    private static (CropHandle Handle,Point Point)[] Handles(Rect r)=>[
        (CropHandle.TopLeft,r.TopLeft),(CropHandle.Top,new(r.X+r.Width/2,r.Top)),(CropHandle.TopRight,r.TopRight),
        (CropHandle.Right,new(r.Right,r.Y+r.Height/2)),(CropHandle.BottomRight,r.BottomRight),
        (CropHandle.Bottom,new(r.X+r.Width/2,r.Bottom)),(CropHandle.BottomLeft,r.BottomLeft),(CropHandle.Left,new(r.Left,r.Y+r.Height/2))];
    private CropHandle? HitCrop(Point point)
    {
        var bounds=CropBounds;if(bounds.IsEmpty)return null;
        foreach(var (handle,center) in Handles(bounds))if(Math.Abs(point.X-center.X)<=10 && Math.Abs(point.Y-center.Y)<=10)return handle;
        return bounds.Contains(point) ? CropHandle.Move : null;
    }
    private bool HandleCropDown(Point point)
    {
        if(!GeometryEditing)return false;
        if(cropDraft!=null && HitCrop(point) is {} handle){cropHandle=handle;cropStart=point;originalCrop=CropInteraction.FromGeometry(cropDraft);CaptureMouse();}
        return true;
    }
    private bool HandleCropMove(Point point)
    {
        if(!GeometryEditing)return false;
        var handle=cropHandle ?? HitCrop(point);
        Cursor=handle switch{
            CropHandle.TopLeft or CropHandle.BottomRight=>Cursors.SizeNWSE,
            CropHandle.TopRight or CropHandle.BottomLeft=>Cursors.SizeNESW,
            CropHandle.Top or CropHandle.Bottom=>Cursors.SizeNS,
            CropHandle.Left or CropHandle.Right=>Cursors.SizeWE,CropHandle.Move=>Cursors.SizeAll,_=>Cursors.Arrow};
        if(cropHandle is {} active && cropDraft!=null && ImageBounds.Width>0 && ImageBounds.Height>0)
        {
            var rectangle=CropInteraction.Dragging(originalCrop,active,(point.X-cropStart.X)/ImageBounds.Width,
                (point.Y-cropStart.Y)/ImageBounds.Height,Viewport?.SourceSize.Width ?? 0,Viewport?.SourceSize.Height ?? 0,cropRatio);
            cropDraft=CropInteraction.Applying(rectangle,cropDraft);DrawCrop();CropChanged?.Invoke(cropDraft,true);
        }
        return true;
    }
    private void EndCropDrag()
    {
        if(cropHandle==null)return;cropHandle=null;if(cropDraft!=null)CropChanged?.Invoke(cropDraft,false);
    }
    private bool HandleCropKey(KeyEventArgs e)
    {
        if(!GeometryEditing || cropDraft==null || e.Key is not(Key.Left or Key.Right or Key.Up or Key.Down))return false;
        var step=(Keyboard.Modifiers&ModifierKeys.Shift)!=0 ? .01 : .001;
        var x=e.Key==Key.Left ? -step : e.Key==Key.Right ? step : 0;
        var y=e.Key==Key.Up ? -step : e.Key==Key.Down ? step : 0;
        cropDraft=CropInteraction.Applying(CropInteraction.Dragging(CropInteraction.FromGeometry(cropDraft),CropHandle.Move,x,y,1,1,null),cropDraft);
        DrawCrop();CropChanged?.Invoke(cropDraft,false);return true;
    }
    private void DrawCrop()
    {
        using var dc=cropOverlay.RenderOpen();
        if(!GeometryEditing || cropDraft==null || ImageBounds.Width<=0 || ImageBounds.Height<=0)return;
        var r=CropBounds;var bounds=ImageBounds;
        var shade=new SolidColorBrush(Color.FromArgb(150,0,0,0));
        dc.PushClip(new RectangleGeometry(bounds));
        dc.DrawRectangle(shade,null,new Rect(bounds.X,bounds.Y,bounds.Width,Math.Max(0,r.Top-bounds.Top)));
        dc.DrawRectangle(shade,null,new Rect(bounds.X,r.Bottom,bounds.Width,Math.Max(0,bounds.Bottom-r.Bottom)));
        dc.DrawRectangle(shade,null,new Rect(bounds.X,r.Top,Math.Max(0,r.Left-bounds.Left),r.Height));
        dc.DrawRectangle(shade,null,new Rect(r.Right,r.Top,Math.Max(0,bounds.Right-r.Right),r.Height));
        if(cropGrid)for(var i=1;i<3;++i){
            var top=new Point(r.Left+r.Width*i/3,r.Top);var bottom=new Point(top.X,r.Bottom);
            var left=new Point(r.Left,r.Top+r.Height*i/3);var right=new Point(r.Right,left.Y);
            dc.DrawLine(new Pen(OverlayPaper,2.6),top,bottom);dc.DrawLine(new Pen(OverlayPaper,2.6),left,right);
            var pen=new Pen(OverlayInk,(double)GetValue(OverlayGridWidthProperty));dc.DrawLine(pen,top,bottom);dc.DrawLine(pen,left,right);
        }
        dc.Pop();
        var accent=(Brush)GetValue(OverlayAccentProperty);dc.DrawRectangle(null,new Pen(OverlayPaper,3.5),r);dc.DrawRectangle(null,new Pen(accent,1.5),r);
        foreach(var (_,p) in Handles(r))dc.DrawRectangle(OverlayPaper,new Pen(accent,1),new Rect(p.X-4,p.Y-4,8,8));
    }
}
