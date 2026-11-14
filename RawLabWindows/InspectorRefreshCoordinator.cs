using System.IO;

namespace RawLab.Windows;

internal enum InspectorRefreshScope
{
    Full,
    DragFastPath
}

internal readonly record struct ParameterRowLayoutSignature(
    double FontSize,
    string FontFamilyName,
    string FontStyle,
    string FontWeight,
    string FontStretch,
    string Language,
    double RangeMin,
    double RangeMax,
    double RangeGrid,
    string Suffix,
    double ActualWidth,
    double PixelsPerDip,
    bool Compact);

internal readonly record struct ParameterRowMetadataSignature(
    string Title,
    double RangeMin,
    double RangeMax,
    double RangeGrid,
    double DefaultValue,
    string Suffix,
    string Language);

internal sealed class ParameterRowLayoutCache
{
    private ParameterRowLayoutSignature? lastLayout;
    private ParameterRowMetadataSignature? lastMetadata;
    private long measureCount;
    private long measureSkippedCount;

    internal long MeasureCount => Interlocked.Read(ref measureCount);
    internal long MeasureSkippedCount => Interlocked.Read(ref measureSkippedCount);

    internal bool NeedsLayoutMeasure(ParameterRowLayoutSignature signature)
    {
        if (lastLayout is { } previous && previous == signature)
        {
            Interlocked.Increment(ref measureSkippedCount);
            return false;
        }

        lastLayout = signature;
        Interlocked.Increment(ref measureCount);
        return true;
    }

    internal bool NeedsMetadataRefresh(ParameterRowMetadataSignature signature)
    {
        if (lastMetadata is { } previous && previous == signature)
            return false;

        lastMetadata = signature;
        return true;
    }

    internal void Invalidate()
    {
        lastLayout = null;
        lastMetadata = null;
    }
}

internal sealed class InspectorModificationCache
{
    private static readonly EditorAdjustmentGroup[] AllGroups = Enum.GetValues<EditorAdjustmentGroup>();
    private static readonly EditorAdjustmentTool[] AllTools = Enum.GetValues<EditorAdjustmentTool>();

    private readonly Dictionary<EditorAdjustmentGroup, bool> groupStates = new();
    private readonly Dictionary<EditorAdjustmentTool, bool> toolStates = new();
    private SavedEdit? cachedEdit;
    private bool cachedHdrEditing;
    private bool populated;
    private long fullComputeCount;
    private long dragPartialComputeCount;
    private long cacheHitCount;

    internal long FullComputeCount => Interlocked.Read(ref fullComputeCount);
    internal long DragPartialComputeCount => Interlocked.Read(ref dragPartialComputeCount);
    internal long CacheHitCount => Interlocked.Read(ref cacheHitCount);

    internal InspectorRefreshScope Update(
        SavedEdit? edit,
        bool isHdrEditing,
        bool interacting,
        EditorAdjustmentGroup activeGroup,
        EditorAdjustmentTool activeTool,
        out IReadOnlyDictionary<EditorAdjustmentGroup, bool> groups,
        out IReadOnlyDictionary<EditorAdjustmentTool, bool> tools,
        Func<EditorResetScope, SavedEdit, bool>? evaluate = null)
    {
        evaluate ??= SafeIsModified;
        if (edit == null)
        {
            foreach (var group in AllGroups) groupStates[group] = false;
            foreach (var tool in AllTools) toolStates[tool] = false;
            cachedEdit = null;
            cachedHdrEditing = isHdrEditing;
            populated = true;
            groups = groupStates;
            tools = toolStates;
            return interacting ? InspectorRefreshScope.DragFastPath : InspectorRefreshScope.Full;
        }

        if (interacting)
        {
            if (!populated)
            {
                PopulateAll(edit, isHdrEditing, evaluate);
                Interlocked.Increment(ref fullComputeCount);
            }
            else
            {
                groupStates[activeGroup] = evaluate(new(EditorResetKind.Group, Group: activeGroup), edit);
                toolStates[activeTool] = evaluate(new(EditorResetKind.Tool, Tool: activeTool), edit);
                cachedEdit = null;
                Interlocked.Increment(ref dragPartialComputeCount);
            }

            groups = groupStates;
            tools = toolStates;
            return InspectorRefreshScope.DragFastPath;
        }

        if (populated && cachedEdit != null && cachedHdrEditing == isHdrEditing && SavedEdit.Same(cachedEdit, edit))
        {
            Interlocked.Increment(ref cacheHitCount);
            groups = groupStates;
            tools = toolStates;
            return InspectorRefreshScope.Full;
        }

        PopulateAll(edit, isHdrEditing, evaluate);
        Interlocked.Increment(ref fullComputeCount);
        groups = groupStates;
        tools = toolStates;
        return InspectorRefreshScope.Full;
    }

    internal static bool ShouldRefreshSubEditor(bool panelVisible) => panelVisible;

    internal void Invalidate()
    {
        populated = false;
        cachedEdit = null;
    }

    private void PopulateAll(SavedEdit edit, bool isHdrEditing, Func<EditorResetScope, SavedEdit, bool> evaluate)
    {
        foreach (var group in AllGroups)
            groupStates[group] = evaluate(new(EditorResetKind.Group, Group: group), edit);
        foreach (var tool in AllTools)
            toolStates[tool] = evaluate(new(EditorResetKind.Tool, Tool: tool), edit);
        cachedEdit = edit.Copy();
        cachedHdrEditing = isHdrEditing;
        populated = true;
    }

    private static bool SafeIsModified(EditorResetScope scope, SavedEdit edit)
    {
        try { return EditorAdjustmentRules.IsModified(scope, edit); }
        catch (ArgumentException) { return false; }
        catch (InvalidDataException) { return false; }
    }
}
