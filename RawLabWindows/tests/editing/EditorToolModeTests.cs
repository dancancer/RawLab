using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class EditorToolModeTests
{
    private static EditorToolSelection InitialSelection =>
        new(EditorToolMode.Parameter, Parameter.Exposure, null, null, null, EditorAdjustmentTool.Vignette);

    [Fact]
    [Trait("Category", "Model")]
    public void EveryEditorAdjustmentToolMapsToAnExplicitMode()
    {
        var expectedNonParameterModes = new Dictionary<EditorAdjustmentTool, EditorToolMode>
        {
            [EditorAdjustmentTool.Film] = EditorToolMode.Film,
            [EditorAdjustmentTool.MasterRecipe] = EditorToolMode.MasterRecipe,
            [EditorAdjustmentTool.ColorGrading] = EditorToolMode.ColorGrading,
            [EditorAdjustmentTool.Hsl] = EditorToolMode.Hsl,
            [EditorAdjustmentTool.WhiteBalance] = EditorToolMode.WhiteBalance,
            [EditorAdjustmentTool.Denoise] = EditorToolMode.Denoise,
            [EditorAdjustmentTool.Vignette] = EditorToolMode.PhotoEffects,
            [EditorAdjustmentTool.Grain] = EditorToolMode.PhotoEffects,
            [EditorAdjustmentTool.Geometry] = EditorToolMode.Geometry,
            [EditorAdjustmentTool.Lens] = EditorToolMode.Lens,
        };

        foreach (var tool in Enum.GetValues<EditorAdjustmentTool>())
        {
            var mode = EditorToolModeRules.ModeFor(tool);
            var expected = expectedNonParameterModes.GetValueOrDefault(tool, EditorToolMode.Parameter);
            Assert.Equal(expected, mode);
        }

        Assert.Throws<ArgumentOutOfRangeException>(() => EditorToolModeRules.ModeFor((EditorAdjustmentTool)999));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void SelectToolTransitionsAreMutuallyExclusiveAndPreserveParameterFallback()
    {
        var state = InitialSelection;
        Assert.Equal(EditorAdjustmentTool.Exposure, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.Contrast);
        Assert.Equal(EditorToolMode.Parameter, state.Mode);
        Assert.Equal(Parameter.Contrast, state.SelectedParameter);
        Assert.Equal(EditorAdjustmentTool.Contrast, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.BlackPoint);
        Assert.Equal(EditorToolMode.Parameter, state.Mode);
        Assert.Equal(ToneControlParameter.BlackPoint, state.SelectedToneParameter);
        Assert.Null(state.SelectedAtmosphereParameter);
        Assert.Null(state.SelectedHdrRenditionParameter);
        Assert.Equal(Parameter.Contrast, state.SelectedParameter);
        Assert.Equal(EditorAdjustmentTool.BlackPoint, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.Clarity);
        Assert.Equal(EditorToolMode.Parameter, state.Mode);
        Assert.Null(state.SelectedToneParameter);
        Assert.Equal(AtmosphereParameter.Clarity, state.SelectedAtmosphereParameter);
        Assert.Equal(EditorAdjustmentTool.Clarity, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.Texture);
        Assert.Equal(EditorToolMode.Parameter, state.Mode);
        Assert.Null(state.SelectedToneParameter);
        Assert.Equal(AtmosphereParameter.Texture, state.SelectedAtmosphereParameter);
        Assert.Equal(EditorAdjustmentTool.Texture, EditorToolModeRules.ResolveTool(state));

        foreach (var spec in AtmosphereSpec.All)
        {
            var tool = EditorAdjustmentRules.ToolFor(spec.Id);
            Assert.Equal(spec.Id, EditorAdjustmentRules.AtmosphereParameterFor(tool));
            Assert.Equal(EditorAdjustmentGroup.Effects, EditorAdjustmentRules.GroupFor(tool));
            Assert.False(string.IsNullOrWhiteSpace(Loc.Text(EditorAdjustmentRules.Title(tool))));
        }

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.HdrPeakLimit);
        Assert.Equal(EditorToolMode.Parameter, state.Mode);
        Assert.Null(state.SelectedAtmosphereParameter);
        Assert.Equal(HDRRenditionParameter.PeakLimitEV, state.SelectedHdrRenditionParameter);
        Assert.Equal(EditorAdjustmentTool.HdrPeakLimit, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.WhiteBalance);
        Assert.Equal(EditorToolMode.WhiteBalance, state.Mode);
        Assert.Null(state.SelectedHdrRenditionParameter);
        Assert.Equal(EditorAdjustmentTool.WhiteBalance, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.Grain);
        Assert.Equal(EditorToolMode.PhotoEffects, state.Mode);
        Assert.Equal(EditorAdjustmentTool.Grain, state.SelectedEffectTool);
        Assert.Equal(EditorAdjustmentTool.Grain, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.Vignette);
        Assert.Equal(EditorToolMode.PhotoEffects, state.Mode);
        Assert.Equal(EditorAdjustmentTool.Vignette, state.SelectedEffectTool);
        Assert.Equal(EditorAdjustmentTool.Vignette, EditorToolModeRules.ResolveTool(state));

        foreach (var (tool, expectedMode) in new[]
        {
            (EditorAdjustmentTool.Film, EditorToolMode.Film),
            (EditorAdjustmentTool.MasterRecipe, EditorToolMode.MasterRecipe),
            (EditorAdjustmentTool.ColorGrading, EditorToolMode.ColorGrading),
            (EditorAdjustmentTool.Hsl, EditorToolMode.Hsl),
            (EditorAdjustmentTool.Denoise, EditorToolMode.Denoise),
        })
        {
            state = EditorToolModeRules.SelectTool(state, tool);
            Assert.Equal(expectedMode, state.Mode);
            Assert.Equal(tool, EditorToolModeRules.ResolveTool(state));
        }

        state = EditorToolModeRules.SelectTool(state, EditorAdjustmentTool.Saturation);
        Assert.Equal(EditorToolMode.Parameter, state.Mode);
        Assert.Equal(Parameter.Saturation, state.SelectedParameter);
        Assert.Equal(EditorAdjustmentTool.Saturation, EditorToolModeRules.ResolveTool(state));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void TransformTransitionsClearStaleNonTransformModesAndRestoreExposureOnEnd()
    {
        var state = EditorToolModeRules.SelectTool(InitialSelection, EditorAdjustmentTool.WhiteBalance);
        Assert.Equal(EditorToolMode.WhiteBalance, state.Mode);

        state = EditorToolModeRules.BeginTransform(state, TransformTool.Geometry);
        Assert.Equal(EditorToolMode.Geometry, state.Mode);
        Assert.Equal(EditorAdjustmentTool.Geometry, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.BeginTransform(state, TransformTool.Lens);
        Assert.Equal(EditorToolMode.Lens, state.Mode);
        Assert.Equal(EditorAdjustmentTool.Lens, EditorToolModeRules.ResolveTool(state));

        state = EditorToolModeRules.EndTransform(state);
        Assert.Equal(EditorToolMode.Parameter, state.Mode);
        Assert.Equal(Parameter.Exposure, state.SelectedParameter);
        Assert.Null(state.SelectedToneParameter);
        Assert.Null(state.SelectedAtmosphereParameter);
        Assert.Null(state.SelectedHdrRenditionParameter);
        Assert.Equal(EditorAdjustmentTool.Exposure, EditorToolModeRules.ResolveTool(state));
    }

    [Fact]
    [Trait("Category", "Model")]
    public void GrainFormatPresetsAndFilmOpticsResetWorkCleanly()
    {
        var adj = new Adjustments();
        adj.EditingEffects = adj.EditingEffects.ApplyGrainFormatPreset(GrainFormatPreset.Film135);
        Assert.Equal(GrainFormatPreset.Film135, adj.EditingEffects.GrainFormatPreset);
        Assert.Equal(18, adj.EditingEffects.GrainSize);
        Assert.Equal(65, adj.EditingEffects.GrainRoughness);

        adj.SetGrainEffect(PhotoEffectParameter.GrainSize, 32);
        Assert.Equal(GrainFormatPreset.Custom, adj.EditingEffects.GrainFormatPreset);
        Assert.Equal(32, adj.EditingEffects.GrainSize);

        var optics = new FilmOpticsSettings(HalationAmount: 55, BloomAmount: 40);
        Assert.False(optics.IsHalationDefault);
        Assert.False(optics.IsBloomDefault);
        optics = optics.ResetHalation();
        Assert.True(optics.IsHalationDefault);
        Assert.False(optics.IsBloomDefault);
    }
}