using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace RawLab.Windows;

internal sealed class LUTCompatibility
{
    private readonly JsonObject info;
    private LUTCompatibility(JsonObject info) => this.info = info;
    internal string SnapshotJSON() => info.ToJsonString();
    internal JsonObject Contract => info["contract"]!.AsObject();
    internal string SourceHash => info["source_sha256"]!.GetValue<string>();
    internal bool FixedContract => info["fixed_contract"]!.GetValue<bool>();
    internal bool ExtremeValues => info["extreme_values"]!.GetValue<bool>();
    internal bool HasHints => info["hints"]!.AsArray().Count > 0;
    internal bool ConfirmedExtremeValues { get; set; }
    internal string PhotoStyle => info["photo_style"]!.GetValue<string>();
    internal string Base => Contract["base_rendering"]!.GetValue<string>();
    internal string Signal(string signal, string key) => Contract[signal]![key]!.GetValue<string>();
    internal bool CanImport => HasCompleteContract && (!ExtremeValues || ConfirmedExtremeValues);
    internal bool HasCompleteContract => Signal("input", "space").Length > 0 && Signal("output", "space").Length > 0 &&
        !(Signal("input", "reference") == "display" && Signal("output", "reference") == "scene") &&
        (PhotoStyle != "std" || Signal("input", "reference") == "display") &&
        (PhotoStyle != "vlog" || Signal("input", "space") == "vlog-vgamut");
    internal IReadOnlyList<LUTCompatibilityCandidate> Candidates => info["candidates"] is JsonArray values ?
        values.Select(value => new LUTCompatibilityCandidate(value!["id"]!.GetValue<string>(), value["basis"]!.GetValue<string>(),
            value["contract"]!.DeepClone().AsObject(), value["assumptions"]?.AsArray().Select(item => item!.GetValue<string>()).ToArray())).ToArray() : [];
    internal LUTCompatibility? Applying(LUTCompatibilityCandidate candidate, bool displayInput)
    {
        var copy = new LUTCompatibility(info.DeepClone().AsObject());
        copy.info["contract"] = candidate.Contract.DeepClone();
        if (displayInput) {
            if (copy.Signal("input", "reference") != "display" || (FixedContract && copy.Base != "source-display")) return null;
            copy.Contract["base_rendering"] = "source-display";
        } else if (copy.Base == "source-display") return null;
        return copy;
    }
    internal bool SupportsPreview(bool displayInput) => HasCompleteContract &&
        (displayInput ? Signal("input", "reference") == "display" && Base == "source-display" : Base != "source-display");
    internal string PreviewKey => string.Join("|", Signal("input","space"),Signal("input","reference"),Signal("input","range"),
        Signal("output","space"),Signal("output","reference"),Signal("output","range"),Contract["interpolation"]!.GetValue<string>(),Base);
    internal string PreviewRequest() => new JsonObject { ["source_sha256"] = SourceHash, ["contract"] = Contract.DeepClone() }.ToJsonString();
    internal static readonly string[] Spaces = ["srgb", "rec709-gamma24", "vlog-vgamut", "slog3-sgamut3", "slog3-sgamut3-cine", "linear-srgb"];
    internal static string SpaceName(string value) => value switch {
        "srgb" => "sRGB", "rec709-gamma24" => "Rec.709 Gamma 2.4", "vlog-vgamut" => "V-Log / V-Gamut",
        "slog3-sgamut3" => "S-Log3 / S-Gamut3", "slog3-sgamut3-cine" => "S-Log3 / S-Gamut3.Cine",
        "linear-srgb" => Loc.Text("线性 sRGB"), _ => Loc.Text("请选择") };
    internal void SelectSpace(string signal, string space)
    {
        Contract[signal]!["space"] = space;
        Contract[signal]!["reference"] = space is "srgb" or "rec709-gamma24" ? "display" : "scene";
        if (signal == "input") Contract["base_rendering"] = Signal(signal,"reference") == "scene" ? "none" : "rawlab-neutral-v1";
    }
    internal string Request()
    {
        if (!CanImport) throw new LookLibraryException(LookLibraryError.MissingColor);
        return new JsonObject { ["source_sha256"] = SourceHash, ["confirmed"] = true,
            ["confirmed_extreme_values"] = ConfirmedExtremeValues, ["contract"] = Contract.DeepClone() }.ToJsonString();
    }
    internal static LUTCompatibility? Parse(string text)
    {
        var info = JsonNode.Parse(text)!.AsObject();
        return info["eligible"]?.GetValue<bool>() == true ? new(info) : null;
    }
    internal static LUTCompatibility? Inspect(string path)
    {
        var blob = new PInvokeNative.DcpBlob();
        try {
            var status = PInvokeNative.InspectLutCompatibility(path, ref blob);
            if (status != PInvokeNative.StatusOk) return null;
            return Parse(Encoding.UTF8.GetString(Read(blob)));
        } finally { PInvokeNative.ReleaseBlob(ref blob); }
    }
    internal byte[] Prepare(string path)
    {
        var blob = new PInvokeNative.DcpBlob();
        try {
            if (PInvokeNative.PrepareLutCompatibility(path, Request(), ref blob) != PInvokeNative.StatusOk)
                throw new LookLibraryException(LookLibraryError.CompatibilityChanged);
            return Read(blob);
        } finally { PInvokeNative.ReleaseBlob(ref blob); }
    }
    private static byte[] Read(PInvokeNative.DcpBlob blob)
    {
        if (blob.Data == IntPtr.Zero || blob.SizeBytes > 256u * 1024u * 1024u)
            throw new LookLibraryException(LookLibraryError.InvalidLook);
        var bytes = new byte[checked((int)blob.SizeBytes)];
        Marshal.Copy(blob.Data, bytes, 0, bytes.Length);return bytes;
    }
}

internal sealed record LUTCompatibilityCandidate(string Id, string Basis, JsonObject Contract, IReadOnlyList<string>? Assumptions = null)
{
    internal string BasisName => Loc.Text(Basis == "file-parameters" ? "文件已有参数 · 效果未验证" :
        Basis == "partial-metadata" ? "依据部分文件线索 · 仍有假设" : "试用方案 · 无颜色依据");
    internal string AssumptionsName(string baseRendering) {
        var values = (Assumptions ?? []).Select(value => value switch {
            "input-space" => Loc.Text("输入颜色"), "output-space" => Loc.Text("输出颜色"),
            "ranges-and-interpolation" => Loc.Text("范围与插值"),
            "neutral-base" => baseRendering == "rawlab-neutral-v1" ? Loc.Text("RawLab 中性显影（近似）") : "", _ => ""
        }).Where(value => value.Length > 0).ToArray();
        return values.Length == 0 ? "" : Loc.Format("仍需假设：{0}", string.Join(" · ", values));
    }
}

internal sealed class LUTReferenceConditions
{
    internal bool SameSource, SameGeometry, SameProcessing, KnownSRGB;
    internal string ReferenceSource = "";
    internal bool CanCompare => SameSource && SameGeometry && SameProcessing && KnownSRGB &&
        !string.IsNullOrWhiteSpace(ReferenceSource) && Encoding.UTF8.GetByteCount(ReferenceSource) <= 2048;
    internal string Json() => new JsonObject { ["same_source"] = SameSource, ["same_geometry"] = SameGeometry,
        ["same_processing"] = SameProcessing, ["known_srgb"] = KnownSRGB, ["reference_source"] = ReferenceSource }.ToJsonString();
}
