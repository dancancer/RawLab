namespace RawLab.Windows;

internal static class NeutralReference
{
    internal static bool Matches(NeutralReferenceKey? reference,OriginalIdentity? source,ProcessingIdentity processing,GeometrySettings geometry,LensSettings lens,int edge=640,bool hdr=false)=>
        reference!=null && source!=null && reference.Source.SameFile(source) && reference.Processing==processing && reference.Geometry==geometry && reference.Lens==lens && reference.Edge==edge && reference.HDR==hdr;
    internal static Adjustments Settings(string path,Adjustments committed)
    {
        var result = PhotoInput.PrepareInputSettings(path, new Adjustments { Lens = committed.Lens, Processing = committed.Processing });
        if (committed.HDR is { } hdr) result.HDR = hdr.Reset() with { Mode = hdr.Mode };
        result.Geometry = committed.Geometry;
        return result;
    }
}

internal enum ComparisonMode { SideBySide,Wipe }

internal sealed class EditorViewState
{
    internal bool Enabled { get; private set; }
    internal ComparisonMode PreferredMode { get; private set; }=ComparisonMode.SideBySide;
    internal bool HoldingBefore { get; private set; }
    internal bool PhotoMargin { get; set; }=true;
    internal bool NeedsReference=>Enabled || HoldingBefore;
    internal void Toggle(){Enabled=!Enabled;HoldingBefore=false;}
    internal void Select(ComparisonMode mode){PreferredMode=mode;Enabled=true;HoldingBefore=false;}
    internal void SetEnabled(bool value){Enabled=value;HoldingBefore=false;}
    internal bool BeginHold(bool draft){if(Enabled || draft)return false;HoldingBefore=true;return true;}
    internal void EndHold()=>HoldingBefore=false;
    internal void SourceChanged(){Enabled=false;HoldingBefore=false;}
}

internal readonly record struct ViewRectangle(double X,double Y,double Width,double Height);
internal static class PhotoViewProjection
{
    internal static ViewRectangle Project(double areaWidth,double areaHeight,double sourceWidth,double sourceHeight,
        double zoom,double focusX,double focusY,double margin=0,double pixelScaleX=0,double pixelScaleY=0)
    {
        if(sourceWidth<=0 || sourceHeight<=0 || areaWidth<=0 || areaHeight<=0)return default;
        margin=Math.Min(margin,Math.Max(0,Math.Min(areaWidth,areaHeight)/2-1));
        var fit=Math.Min((areaWidth-2*margin)/sourceWidth,(areaHeight-2*margin)/sourceHeight);
        var width=sourceWidth*(pixelScaleX>0 ? pixelScaleX : fit)*zoom;
        var height=sourceHeight*(pixelScaleY>0 ? pixelScaleY : fit)*zoom;
        return new(areaWidth/2-focusX*width,areaHeight/2-focusY*height,width,height);
    }
}

internal sealed record NeutralReferenceKey(OriginalIdentity Source,bool Raster,ProcessingIdentity Processing,
    GeometrySettings Geometry,LensSettings Lens,int Edge,bool HDR=false);
