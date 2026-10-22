namespace RawLab.Windows;

public sealed record EditorTransformContext(TransformTool Tool, GeometrySettings Geometry, LensSettings Lens);
public sealed record EditorResetContext(string? Lut, long TransformGeneration, EditorTransformContext? Draft = null,
    bool InvalidGeometryInput = false);

// 同步提交也固定源身份和完整元数据，不能仅依赖显影或编辑版本。
public sealed class EditorEditSource
{
    private readonly string file;
    private readonly long openRevision, editRevision;
    private readonly SavedEdit original;
    private readonly string? lut;

    public EditorEditSource(string file, long openRevision, long editRevision, SavedEdit original, string? lut)
    {
        this.file=file;this.openRevision=openRevision;this.editRevision=editRevision;
        this.original=original with{Settings=original.Settings.Copy()};this.lut=lut;
    }

    public bool Matches(string file, long openRevision, long editRevision, SavedEdit current, string? lut) =>
        StringComparer.OrdinalIgnoreCase.Equals(this.file,file) && this.openRevision==openRevision && this.editRevision==editRevision &&
        original.Identity.SameFile(current.Identity) && original.Look==current.Look && original.Settings.SameAs(current.Settings) && this.lut==lut;
}

public sealed class EditorResetTransaction
{
    private readonly EditorEditSource source;
    private readonly EditorResetContext context;
    private readonly SavedEdit? candidate;
    private bool consumed;
    public EditorResetStatus Status { get; }
    public bool RequiresConfirmation { get; }
    public string? Reason { get; }
    public IReadOnlyList<string> MaterializedFields { get; }
    public bool TargetsDraft => context.Draft!=null;
    public SavedEdit? Candidate => candidate is {} value ? value with{Settings=value.Settings.Copy()} : null;

    private EditorResetTransaction(EditorEditSource source, EditorResetContext context, EditorResetCandidate prepared)
    {
        this.source=source;this.context=context;Status=prepared.Status;RequiresConfirmation=prepared.RequiresConfirmation;Reason=prepared.Reason;MaterializedFields=prepared.MaterializedFields ?? Array.Empty<string>();
        candidate=prepared.Candidate is {} value ? value with{Settings=value.Settings.Copy()} : null;
    }

    public static EditorResetTransaction Prepare(EditorResetScope scope, string file, long openRevision, long editRevision,
        SavedEdit committed, EditorResetContext context)
    {
        var source=new EditorEditSource(file,openRevision,editRevision,committed,context.Lut);
        var geometry=scope.Kind==EditorResetKind.Group && scope.Group==EditorAdjustmentGroup.Geometry ||
            scope.Kind==EditorResetKind.Tool && scope.Tool is EditorAdjustmentTool.Geometry or EditorAdjustmentTool.Lens;
        if (scope.Kind==EditorResetKind.Tool && geometry && context.Draft is {} currentDraft &&
            (scope.Tool==EditorAdjustmentTool.Geometry) != (currentDraft.Tool==TransformTool.Geometry))
            return new(source,context,new(EditorResetStatus.Blocked,Reason:"Geometry reset requires a matching active draft."));
        if(context.Draft!=null && !geometry)
            return new(source,context,new(EditorResetStatus.Blocked,Reason:"Resolve the active draft before preparing this reset."));
        if(geometry && context.Draft==null)
            return new(source,context,new(EditorResetStatus.Blocked,Reason:"Geometry reset requires an active draft."));
        var projected=context.Draft is {} draft ? committed with{Settings=committed.Settings.Copy() with{Geometry=draft.Geometry,Lens=draft.Lens}} : committed;
        return new(source,context,EditorAdjustmentRules.PrepareReset(scope,projected));
    }

    public bool Matches(string file, long openRevision, long editRevision, SavedEdit current, EditorResetContext context) =>
        !consumed && Status==EditorResetStatus.Ready && this.context==context && source.Matches(file,openRevision,editRevision,current,context.Lut);

    public bool TryCommit(string file, long openRevision, long editRevision, SavedEdit current, EditorResetContext context, Action<SavedEdit> commit)
    {
        if(!Matches(file,openRevision,editRevision,current,context) || Candidate is not {} value)return false;
        consumed=true;commit(value);return true;
    }
}
