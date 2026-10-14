namespace RawLab.Windows;

public sealed class GeometryEditSession
{
    public bool IsActive { get; private set; }
    public GeometrySettings Draft { get; private set; } = new();
    public void Begin(GeometrySettings committed) { Draft = committed; IsActive = true; }
    public void Update(GeometrySettings value) { if (IsActive) Draft = value; }
    public GeometrySettings PreviewGeometry => Draft with { CropX = 0, CropY = 0, CropWidth = 1, CropHeight = 1 };
    public GeometrySettings Apply() { if (!IsActive) throw new InvalidOperationException(); IsActive = false; return Draft; }
    public void Cancel() => IsActive = false;
}
