namespace RawLab.Windows;

public enum CropAspectPreset { Free, Original, Square, ThreeTwo, FourThree, SixteenNine }
public enum CropHandle { TopLeft, TopRight, BottomLeft, BottomRight, Move }
public readonly record struct CropRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
}

// UI-only normalized selection math; native geometry still uses the existing ABI.
public static class CropInteraction
{
    public static CropRect FromGeometry(GeometrySettings value) => new(value.CropX, value.CropY, value.CropWidth, value.CropHeight);
    public static GeometrySettings Applying(CropRect rect, GeometrySettings value) => value with {
        CropX = rect.X, CropY = rect.Y, CropWidth = rect.Width, CropHeight = rect.Height
    };
    public static double? Ratio(CropAspectPreset preset, double canvasWidth, double canvasHeight, bool swapped = false)
    {
        if (canvasWidth <= 0 || canvasHeight <= 0) return null;
        double? ratio = preset switch {
            CropAspectPreset.Original => canvasWidth / canvasHeight,
            CropAspectPreset.Square => 1, CropAspectPreset.ThreeTwo => 3.0 / 2,
            CropAspectPreset.FourThree => 4.0 / 3, CropAspectPreset.SixteenNine => 16.0 / 9, _ => null
        };
        return swapped && ratio.HasValue ? 1 / ratio : ratio;
    }
    public static CropRect Fitting(double? ratio, double canvasWidth, double canvasHeight, CropRect rect)
    {
        if (ratio is not {} aspect || !double.IsFinite(aspect) || aspect <= 0 || canvasWidth <= 0 || canvasHeight <= 0) return rect;
        var normalized = aspect * canvasHeight / canvasWidth;
        var cx = Math.Clamp(rect.X + rect.Width / 2, .01, .99);
        var cy = Math.Clamp(rect.Y + rect.Height / 2, .01, .99);
        var width = Math.Min(2 * Math.Min(cx, 1 - cx), 2 * Math.Min(cy, 1 - cy) * normalized);
        var height = width / normalized;
        return new(cx - width / 2, cy - height / 2, width, height);
    }
    // A transform may change the canvas aspect. Keep the resized selection's
    // center and area where possible, rather than maximizing it like a new preset.
    public static CropRect MaintainingRatio(double? ratio, double canvasWidth, double canvasHeight, CropRect rect)
    {
        if (ratio is not {} aspect || !double.IsFinite(aspect) || aspect <= 0 || canvasWidth <= 0 || canvasHeight <= 0) return rect;
        var normalized = aspect * canvasHeight / canvasWidth;
        var cx = rect.X + rect.Width / 2; var cy = rect.Y + rect.Height / 2;
        var width = Math.Min(Math.Sqrt(rect.Width * rect.Height * normalized),
            Math.Min(2 * Math.Min(cx, 1 - cx), 2 * Math.Min(cy, 1 - cy) * normalized));
        var height = width / normalized;
        return new(cx - width / 2, cy - height / 2, width, height);
    }
    public static CropRect Dragging(CropRect rect, CropHandle handle, double dx, double dy,
        double canvasWidth, double canvasHeight, double? ratio)
    {
        if (handle == CropHandle.Move)
            return rect with { X = Math.Clamp(rect.X + dx, 0, 1 - rect.Width), Y = Math.Clamp(rect.Y + dy, 0, 1 - rect.Height) };
        var left = handle is CropHandle.TopLeft or CropHandle.BottomLeft;
        var top = handle is CropHandle.TopLeft or CropHandle.TopRight;
        var anchorX = left ? rect.Right : rect.X; var anchorY = top ? rect.Bottom : rect.Y;
        var maxWidth = left ? anchorX : 1 - anchorX; var maxHeight = top ? anchorY : 1 - anchorY;
        var width = rect.Width + (left ? -dx : dx); var height = rect.Height + (top ? -dy : dy);
        if (ratio is {} aspect && double.IsFinite(aspect) && aspect > 0 && canvasWidth > 0 && canvasHeight > 0) {
            var normalized = aspect * canvasHeight / canvasWidth;
            if (Math.Abs(dx) * canvasWidth >= Math.Abs(dy) * canvasHeight) height = width / normalized;
            else width = height * normalized;
            var maximum = Math.Min(maxWidth, maxHeight * normalized);
            width = Math.Clamp(width, Math.Min(maximum, Math.Max(.01, .01 * normalized)), maximum);
            height = width / normalized;
        } else {
            width = Math.Clamp(width, Math.Min(.01, maxWidth), maxWidth);
            height = Math.Clamp(height, Math.Min(.01, maxHeight), maxHeight);
        }
        return new(left ? anchorX - width : anchorX, top ? anchorY - height : anchorY, width, height);
    }
}
