namespace RawLab.Windows;

public enum TransformTool { Geometry, Lens }
public sealed class TransformDraft
{
    public bool Active { get; private set; }
    public TransformTool Tool { get; private set; }
    public GeometrySettings Geometry { get; private set; }=new();
    public LensSettings Lens { get; private set; }=new();
    private GeometrySettings originalGeometry=new();
    private LensSettings originalLens=new();
    public bool Dirty=>Active && (Geometry!=originalGeometry || Lens!=originalLens);
    public GeometrySettings PreviewGeometry=>Active && Tool==TransformTool.Geometry
        ? Geometry with{CropX=0,CropY=0,CropWidth=1,CropHeight=1} : Geometry;
    public void Begin(GeometrySettings geometry,LensSettings lens,TransformTool tool)
    {
        originalGeometry=Geometry=geometry;originalLens=Lens=lens;Tool=tool;Active=true;
    }
    public void Update(GeometrySettings geometry){if(!Active)throw new InvalidOperationException();_=geometry.NativeConfig();Geometry=geometry;}
    public void Update(LensSettings lens){if(!Active)throw new InvalidOperationException();Lens=lens;}
    public void Reset(){if(Tool==TransformTool.Geometry)Update(new GeometrySettings());else Update(new LensSettings());}
    public (GeometrySettings Geometry,LensSettings Lens) Apply()
    {
        if(!Active)throw new InvalidOperationException();Active=false;return(Geometry,Lens);
    }
    public void Cancel(){Active=false;Geometry=originalGeometry;Lens=originalLens;}
}
