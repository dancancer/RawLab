namespace RawLab.Windows;

public enum CropAspectPreset { Free, Original, Square, ThreeTwo, FourThree, SixteenNine }
public enum CropHandle { TopLeft, Top, TopRight, Right, BottomRight, Bottom, BottomLeft, Left, Move }
public readonly record struct CropRect(double X,double Y,double Width,double Height)
{
    public double Right=>X+Width;
    public double Bottom=>Y+Height;
}
public static class CropInteraction
{
    public static CropRect FromGeometry(GeometrySettings value)=>new(value.CropX,value.CropY,value.CropWidth,value.CropHeight);
    public static GeometrySettings Applying(CropRect rect,GeometrySettings value)=>value with {
        CropX=rect.X,CropY=rect.Y,CropWidth=rect.Width,CropHeight=rect.Height};
    public static double? Ratio(CropAspectPreset preset,double originalWidth,double originalHeight,bool swapped=false)
    {
        if(originalWidth<=0 || originalHeight<=0)return null;
        double? ratio=preset switch{CropAspectPreset.Original=>originalWidth/originalHeight,CropAspectPreset.Square=>1,
            CropAspectPreset.ThreeTwo=>3.0/2,CropAspectPreset.FourThree=>4.0/3,CropAspectPreset.SixteenNine=>16.0/9,_=>null};
        return swapped && ratio.HasValue ? 1/ratio : ratio;
    }
    public static CropRect Fitting(double? ratio,double canvasWidth,double canvasHeight,CropRect rect,bool preserveArea=false)
    {
        if(ratio is not {} aspect || !double.IsFinite(aspect) || aspect<=0 || canvasWidth<=0 || canvasHeight<=0)return rect;
        var normalized=aspect*canvasHeight/canvasWidth;
        var cx=rect.X+rect.Width/2;var cy=rect.Y+rect.Height/2;
        var width=Math.Min(2*Math.Min(cx,1-cx),2*Math.Min(cy,1-cy)*normalized);
        if(preserveArea)width=Math.Min(width,Math.Sqrt(rect.Width*rect.Height*normalized));
        return new(cx-width/2,cy-width/normalized/2,width,width/normalized);
    }
    public static CropRect Dragging(CropRect rect,CropHandle handle,double dx,double dy,double canvasWidth,double canvasHeight,double? ratio)
    {
        if(!double.IsFinite(dx) || !double.IsFinite(dy))return rect;
        if(handle==CropHandle.Move)return rect with{X=Math.Clamp(rect.X+dx,0,1-rect.Width),Y=Math.Clamp(rect.Y+dy,0,1-rect.Height)};
        var left=handle is CropHandle.TopLeft or CropHandle.Left or CropHandle.BottomLeft;
        var top=handle is CropHandle.TopLeft or CropHandle.Top or CropHandle.TopRight;
        var horizontalEdge=handle is CropHandle.Left or CropHandle.Right;
        var verticalEdge=handle is CropHandle.Top or CropHandle.Bottom;
        var anchorX=left ? rect.Right : rect.X;var anchorY=top ? rect.Bottom : rect.Y;
        var width=rect.Width+(left ? -dx : dx);var height=rect.Height+(top ? -dy : dy);
        var maxWidth=left ? anchorX : 1-anchorX;var maxHeight=top ? anchorY : 1-anchorY;
        var normalized=ratio is >0 && canvasWidth>0 && canvasHeight>0 ? ratio.Value*canvasHeight/canvasWidth : (double?)null;
        if(normalized is {} n)
        {
            if(horizontalEdge){maxHeight=2*Math.Min(rect.Y+rect.Height/2,1-rect.Y-rect.Height/2);height=width/n;}
            else if(verticalEdge){maxWidth=2*Math.Min(rect.X+rect.Width/2,1-rect.X-rect.Width/2);width=height*n;}
            else if(Math.Abs(dx)*canvasWidth>=Math.Abs(dy)*canvasHeight)height=width/n;
            else width=height*n;
            var maximum=Math.Min(maxWidth,maxHeight*n);width=Math.Clamp(width,Math.Min(maximum,Math.Max(.0001,.0001*n)),maximum);height=width/n;
        }
        else
        {
            width=verticalEdge ? rect.Width : Math.Clamp(width,Math.Min(.0001,maxWidth),maxWidth);
            height=horizontalEdge ? rect.Height : Math.Clamp(height,Math.Min(.0001,maxHeight),maxHeight);
        }
        return new(verticalEdge ? rect.X+(rect.Width-width)/2 : left ? anchorX-width : anchorX,
            horizontalEdge ? rect.Y+(rect.Height-height)/2 : top ? anchorY-height : anchorY,width,height);
    }
}
