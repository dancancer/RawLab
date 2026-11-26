namespace RawLab.Windows;

public enum EditorToolMode
{
    Parameter,
    Film,
    MasterRecipe,
    ColorGrading,
    Hsl,
    PointColor,
    SelectiveColor,
    BwMixer,
    CameraCalibration,
    WhiteBalance,
    Denoise,
    PhotoEffects,
    Geometry,
    Lens
}

public readonly record struct EditorToolSelection(
    EditorToolMode Mode,
    Parameter SelectedParameter,
    ToneControlParameter? SelectedToneParameter,
    AtmosphereParameter? SelectedAtmosphereParameter,
    HDRRenditionParameter? SelectedHdrRenditionParameter,
    EditorAdjustmentTool SelectedEffectTool);

public static class EditorToolModeRules
{
    public static EditorToolMode ModeFor(EditorAdjustmentTool tool)
    {
        if (!Enum.IsDefined(tool)) throw new ArgumentOutOfRangeException(nameof(tool));
        return tool switch
        {
            EditorAdjustmentTool.Film => EditorToolMode.Film,
            EditorAdjustmentTool.MasterRecipe => EditorToolMode.MasterRecipe,
            EditorAdjustmentTool.ColorGrading => EditorToolMode.ColorGrading,
            EditorAdjustmentTool.Hsl => EditorToolMode.Hsl,
            EditorAdjustmentTool.PointColor => EditorToolMode.PointColor,
            EditorAdjustmentTool.SelectiveColor => EditorToolMode.SelectiveColor,
            EditorAdjustmentTool.BwMixer => EditorToolMode.BwMixer,
            EditorAdjustmentTool.CameraCalibration => EditorToolMode.CameraCalibration,
            EditorAdjustmentTool.WhiteBalance => EditorToolMode.WhiteBalance,
            EditorAdjustmentTool.Denoise => EditorToolMode.Denoise,
            EditorAdjustmentTool.Vignette or EditorAdjustmentTool.Grain => EditorToolMode.PhotoEffects,
            EditorAdjustmentTool.Geometry => EditorToolMode.Geometry,
            EditorAdjustmentTool.Lens => EditorToolMode.Lens,
            _ => EditorToolMode.Parameter
        };
    }

    public static EditorToolMode ModeFor(TransformTool tool) => tool switch
    {
        TransformTool.Geometry => EditorToolMode.Geometry,
        TransformTool.Lens => EditorToolMode.Lens,
        _ => throw new ArgumentOutOfRangeException(nameof(tool))
    };

    public static EditorToolSelection SelectTool(
        EditorToolSelection current,
        EditorAdjustmentTool tool)
    {
        var mode = ModeFor(tool);
        var hdrRendition = EditorAdjustmentRules.HdrRenditionParameterFor(tool);
        var tone = EditorAdjustmentRules.ToneParameterFor(tool);
        var atmosphere = EditorAdjustmentRules.AtmosphereParameterFor(tool);
        var effectTool = current.SelectedEffectTool;
        var parameter = current.SelectedParameter;

        if (mode == EditorToolMode.PhotoEffects)
            effectTool = tool;
        else if (mode == EditorToolMode.Parameter && hdrRendition == null && tone == null && atmosphere == null)
            parameter = EditorAdjustmentRules.ParameterFor(tool);

        return new EditorToolSelection(mode, parameter, tone, atmosphere, hdrRendition, effectTool);
    }

    public static EditorToolSelection BeginTransform(EditorToolSelection current, TransformTool tool) =>
        new(
            ModeFor(tool),
            current.SelectedParameter,
            current.SelectedToneParameter,
            current.SelectedAtmosphereParameter,
            current.SelectedHdrRenditionParameter,
            current.SelectedEffectTool);

    public static EditorToolSelection EndTransform(EditorToolSelection current) =>
        new(
            EditorToolMode.Parameter,
            Parameter.Exposure,
            null,
            null,
            null,
            current.SelectedEffectTool);

    public static EditorAdjustmentTool ResolveTool(
        EditorToolMode mode,
        Parameter selectedParameter,
        ToneControlParameter? selectedToneParameter,
        AtmosphereParameter? selectedAtmosphereParameter,
        HDRRenditionParameter? selectedHdrRenditionParameter,
        EditorAdjustmentTool selectedEffectTool) => mode switch
    {
        EditorToolMode.Film => EditorAdjustmentTool.Film,
        EditorToolMode.MasterRecipe => EditorAdjustmentTool.MasterRecipe,
        EditorToolMode.ColorGrading => EditorAdjustmentTool.ColorGrading,
        EditorToolMode.Hsl => EditorAdjustmentTool.Hsl,
        EditorToolMode.PointColor => EditorAdjustmentTool.PointColor,
        EditorToolMode.SelectiveColor => EditorAdjustmentTool.SelectiveColor,
        EditorToolMode.BwMixer => EditorAdjustmentTool.BwMixer,
        EditorToolMode.CameraCalibration => EditorAdjustmentTool.CameraCalibration,
        EditorToolMode.WhiteBalance => EditorAdjustmentTool.WhiteBalance,
        EditorToolMode.Denoise => EditorAdjustmentTool.Denoise,
        EditorToolMode.Geometry => EditorAdjustmentTool.Geometry,
        EditorToolMode.Lens => EditorAdjustmentTool.Lens,
        EditorToolMode.PhotoEffects => selectedEffectTool is EditorAdjustmentTool.Vignette or EditorAdjustmentTool.Grain
            ? selectedEffectTool
            : throw new ArgumentOutOfRangeException(nameof(selectedEffectTool)),
        EditorToolMode.Parameter => selectedHdrRenditionParameter is { } hdrRendition
            ? EditorAdjustmentRules.ToolFor(hdrRendition)
            : selectedAtmosphereParameter is { } atmosphere
                ? EditorAdjustmentRules.ToolFor(atmosphere)
                : selectedToneParameter is { } tone
                    ? EditorAdjustmentRules.ToolFor(tone)
                    : ToolFor(selectedParameter),
        _ => throw new ArgumentOutOfRangeException(nameof(mode))
    };

    public static EditorAdjustmentTool ResolveTool(EditorToolSelection selection) =>
        ResolveTool(
            selection.Mode,
            selection.SelectedParameter,
            selection.SelectedToneParameter,
            selection.SelectedAtmosphereParameter,
            selection.SelectedHdrRenditionParameter,
            selection.SelectedEffectTool);

    public static EditorAdjustmentTool ToolFor(Parameter parameter) => parameter switch
    {
        Parameter.Temperature or Parameter.Tint => EditorAdjustmentTool.WhiteBalance,
        Parameter.Strength => EditorAdjustmentTool.Strength,
        Parameter.Exposure => EditorAdjustmentTool.Exposure,
        Parameter.Highlights => EditorAdjustmentTool.Highlights,
        Parameter.Shadows => EditorAdjustmentTool.Shadows,
        Parameter.Contrast => EditorAdjustmentTool.Contrast,
        Parameter.ToneCurve => EditorAdjustmentTool.ToneCurve,
        Parameter.Saturation => EditorAdjustmentTool.Saturation,
        Parameter.Sharpening => EditorAdjustmentTool.Sharpening,
        _ => throw new ArgumentOutOfRangeException(nameof(parameter))
    };
}
