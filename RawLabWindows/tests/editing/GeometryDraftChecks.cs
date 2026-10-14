using RawLab.Windows;

internal static class GeometryDraftChecks
{
    internal static void Run(Action<bool, string> check)
    {
        static bool Near(double a, double b) => Math.Abs(a - b) < 1e-10;
        var source = new GeometrySettings(.12, .17, .72, .65, 1, true, false, 4, .3, -.2);
        var committed = new Adjustments { Geometry = source };
        var frozen = BatchJob.Create("source.ARW", committed.Capture(), null, "Neutral");
        var edit = new GeometryEditSession(); edit.Begin(source);
        check(edit.Draft == source && edit.IsActive, "Opening geometry copies the committed selection");
        check(edit.PreviewGeometry is { CropX: 0, CropY: 0, CropWidth: 1, CropHeight: 1, QuarterTurns: 1,
            FlipHorizontal: true, StraightenDegrees: 4, PerspectiveHorizontal: .3, PerspectiveVertical: -.2 },
            "Draft preview keeps every transform and displays the full canvas");
        edit.Update(source with { CropX = .2, CropWidth = .6, StraightenDegrees = -8 });
        check(committed.Geometry == source && frozen.Settings.Restore().Geometry == source,
            "Pending draft cannot mutate persisted settings or an existing frozen batch");
        edit.Cancel(); check(!edit.IsActive && committed.Geometry == source, "Cancel leaves committed geometry untouched");
        edit.Begin(source); var changed = source with { PerspectiveVertical = .4 }; edit.Update(changed);
        committed.Geometry = edit.Apply();
        check(!edit.IsActive && committed.Geometry == changed && frozen.Settings.Restore().Geometry == source,
            "Apply returns the draft exactly once and preserves frozen batch settings");
        edit.Begin(new()); check(edit.Apply().IsIdentity, "An unchanged draft can be applied to request the committed crop render");
        var old = System.Text.Json.JsonSerializer.Deserialize<GeometrySettings>("{\"CropX\":0.1,\"CropWidth\":0.8}")!;
        edit.Begin(old); check(edit.Draft is { CropHeight: 1, PerspectiveHorizontal: 0, PerspectiveVertical: 0 }, "Old records still open with missing geometry defaults");

        var full = new CropRect(0, 0, 1, 1);
        foreach (var preset in new[] { CropAspectPreset.Original, CropAspectPreset.Square, CropAspectPreset.ThreeTwo, CropAspectPreset.FourThree, CropAspectPreset.SixteenNine }) {
            var ratio = CropInteraction.Ratio(preset, 6037, 4013)!.Value;
            var fitted = CropInteraction.Fitting(ratio, 6037, 4013, full);
            check(Near(fitted.Width * 6037 / (fitted.Height * 4013), ratio), "Preset uses full native dimensions, including odd source sizes: " + preset);
            var portrait = CropInteraction.Fitting(CropInteraction.Ratio(preset, 4013, 6037, true), 4013, 6037, full);
            check(Near(portrait.Width * 4013 / (portrait.Height * 6037), 1 / CropInteraction.Ratio(preset, 4013, 6037)!.Value), "Ratio swap uses the rotated full canvas: " + preset);
        }
        var square = CropInteraction.Fitting(1, 6037, 4013, full);
        var wide = CropInteraction.Fitting(16.0 / 9, 6037, 4013, square);
        var squareAgain = CropInteraction.Fitting(1, 6037, 4013, wide);
        check(squareAgain == square, "Cycling ratios fits the full canvas without successive shrinkage");
        var smallSquare = CropInteraction.Dragging(square, CropHandle.BottomRight, -.15, -.1, 6037, 4013, 1);
        var correctedSquare = CropInteraction.MaintainingRatio(1, 5001, 3601, smallSquare);
        check(Near(correctedSquare.Width * 5001 / (correctedSquare.Height * 3601), 1) &&
              Near(correctedSquare.Width * correctedSquare.Height, smallSquare.Width * smallSquare.Height),
            "A transformed canvas preserves a manually resized crop area while maintaining its ratio");
        var rect = new CropRect(.2, .25, .6, .5);
        foreach (var handle in new[] { CropHandle.TopLeft, CropHandle.TopRight, CropHandle.BottomLeft, CropHandle.BottomRight }) {
            var resized = CropInteraction.Dragging(rect, handle, .08, -.06, 6037, 4013, null);
            check(resized.X >= 0 && resized.Y >= 0 && resized.Right <= 1 && resized.Bottom <= 1 && resized.Width > 0 && resized.Height > 0,
                "Corner resize stays bounded: " + handle);
            check(Near(handle is CropHandle.TopLeft or CropHandle.BottomLeft ? resized.Right : resized.X,
                    handle is CropHandle.TopLeft or CropHandle.BottomLeft ? rect.Right : rect.X) &&
                  Near(handle is CropHandle.TopLeft or CropHandle.TopRight ? resized.Bottom : resized.Y,
                    handle is CropHandle.TopLeft or CropHandle.TopRight ? rect.Bottom : rect.Y), "Resize holds the opposite corner: " + handle);
            var locked = CropInteraction.Dragging(square, handle, -.3, .2, 6037, 4013, 1);
            check(Near(locked.Width * 6037 / (locked.Height * 4013), 1), "Corner resize keeps a pixel-space ratio: " + handle);
        }
        var moved = CropInteraction.Dragging(rect, CropHandle.Move, 5, -5, 6037, 4013, null);
        check(moved.Width == rect.Width && moved.Height == rect.Height && Near(moved.Right, 1) && moved.Y == 0, "Moving preserves size and clamps against full canvas");
        var first = CropInteraction.Dragging(rect, CropHandle.BottomRight, -.1, -.1, 6037, 4013, null);
        var second = CropInteraction.Dragging(first, CropHandle.BottomRight, -.1, -.1, 6037, 4013, null);
        check(Near(second.Width, .4) && Near(second.Height, .3), "A second gesture starts from the newly committed overlay baseline");
        check(CropInteraction.Fitting(null, 0, 0, rect) == rect && CropInteraction.Ratio(CropAspectPreset.Free, 6037, 4013) == null,
            "Free cropping and pending native dimensions do not invent an aspect ratio");
        Console.WriteLine("PASS: crop draft transactions, full-canvas ratios, anchors, move bounds and gesture baselines");
    }
}
