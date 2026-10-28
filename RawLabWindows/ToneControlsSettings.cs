using System.Text.Json.Serialization;

namespace RawLab.Windows;

// 独立扩展对象不改变十项 Parameter/Values 的既有索引。
public enum ToneControlParameter { BlackPoint, WhitePoint, Vibrance }
public sealed record ToneControlSpec(ToneControlParameter Id, string Title, string Group)
{
    public static readonly ToneControlSpec[] All = [
        new(ToneControlParameter.BlackPoint, "黑场", "明暗"),
        new(ToneControlParameter.WhitePoint, "白场", "明暗"),
        new(ToneControlParameter.Vibrance, "鲜艳度", "色彩")
    ];
    public static ToneControlSpec For(ToneControlParameter id) => All[(int)id];
}

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record ToneControlsSettings(double BlackPoint = 0, double WhitePoint = 0, double Vibrance = 0)
{
    [JsonIgnore] public bool IsIdentity => BlackPoint == 0 && WhitePoint == 0 && Vibrance == 0;
    public ToneControlsSettings Scaled(double strength) => new(Math.Clamp(BlackPoint * strength, -100, 100),
        Math.Clamp(WhitePoint * strength, -100, 100), Math.Clamp(Vibrance * strength, -100, 100));
    public double this[ToneControlParameter id] => id switch {
        ToneControlParameter.BlackPoint => BlackPoint, ToneControlParameter.WhitePoint => WhitePoint,
        ToneControlParameter.Vibrance => Vibrance, _ => throw new ArgumentOutOfRangeException(nameof(id))
    };
    public ToneControlsSettings With(ToneControlParameter id, double value) => id switch {
        ToneControlParameter.BlackPoint => this with { BlackPoint = value },
        ToneControlParameter.WhitePoint => this with { WhitePoint = value },
        ToneControlParameter.Vibrance => this with { Vibrance = value },
        _ => throw new ArgumentOutOfRangeException(nameof(id))
    };
    internal Native.ToneControlsConfig NativeConfig()
    {
        foreach (var value in new[] { BlackPoint, WhitePoint, Vibrance })
            if (!double.IsFinite(value) || value is < -100 or > 100)
                throw new ArgumentOutOfRangeException(nameof(value), Loc.Text("无效的黑白场或鲜艳度参数"));
        return new() { Version = 1, StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.ToneControlsConfig>(),
            BlackPoint = (float)(BlackPoint / 100), WhitePoint = (float)(WhitePoint / 100), Vibrance = (float)(Vibrance / 100) };
    }
}
