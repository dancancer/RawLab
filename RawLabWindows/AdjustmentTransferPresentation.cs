using F = RawLab.Windows.AdjustmentField;
namespace RawLab.Windows;
internal static class AdjustmentTransferPresentation
{
    private static readonly Dictionary<F,string> labels=new() {
        [F.Look]="外观",
        [F.Strength]="强度",
        [F.Exposure]="曝光",
        [F.ExposureMode]="曝光模式",
        [F.Contrast]="对比度",
        [F.Highlights]="高光",
        [F.Shadows]="阴影",
        [F.SCurve]="S 曲线",
        [F.WhiteBalanceMode]="白平衡模式",
        [F.Temperature]="色温",
        [F.Tint]="色调",
        [F.Saturation]="饱和度",
        [F.BlackPoint]="黑场", [F.WhitePoint]="白场", [F.Vibrance]="鲜艳度",
        [F.VignetteAmount]="暗角",
        [F.VignetteMidpoint]="中点",
        [F.VignetteRoundness]="圆度",
        [F.VignetteFeather]="羽化",
        [F.VignetteHighlights]="高光保护",
        [F.GrainAmount]="颗粒",
        [F.GrainSize]="大小",
        [F.GrainRoughness]="粗糙度",
        [F.Sharpening]="锐化",
        [F.RawDenoise]="RAW 降噪",
        [F.PostRGBDenoise]="旧版降噪",
        [F.ChromaDenoise]="色度降噪",
        [F.WaveletDenoise]="降噪参数",
        [F.CropX]="水平位置",
        [F.CropY]="垂直位置",
        [F.CropWidth]="宽度",
        [F.CropHeight]="高度",
        [F.QuarterTurns]="旋转",
        [F.FlipHorizontal]="水平翻转",
        [F.FlipVertical]="垂直翻转",
        [F.Straighten]="拉直",
        [F.PerspectiveHorizontal]="水平透视",
        [F.PerspectiveVertical]="垂直透视",
        [F.LensDistortion]="畸变校正",
        [F.LensTCA]="横向色差",
        [F.LensAutoCrop]="自动裁切",
        [F.LensProfile]="镜头配置"
    };
    internal static string Title(F field)
    {
        if(field.GradingZone() is {} zone)return Loc.Text("颜色分级")+" · "+Loc.Text(new[]{"阴影","中间调","高光"}[(int)zone]);
        if(field.HslIndex() is {} index)return Loc.Text(new[]{"红","橙","黄","绿","青","蓝","紫","洋红"}[index%8])+" · "+Loc.Text(new[]{"色相","饱和度","明度"}[index/8]);
        return Loc.Text(labels[field]);
    }
    internal static string Group(string group)
    {
        var key=group switch {"looks"=>"外观","light"=>"光线","color"=>"颜色","effects"=>"效果","detail"=>"细节",_=>"几何与镜头"};
        return Loc.Text(key);
    }
    internal static string Status(AdjustmentStatus status)=>Loc.Text(status switch {
        AdjustmentStatus.Applied=>"已保存",AdjustmentStatus.Unchanged=>"未变化",AdjustmentStatus.Skipped=>"已跳过",
        AdjustmentStatus.Conflict=>"调整已变化",AdjustmentStatus.Failed=>"保存失败",_=>"待处理"
    });
    internal static string Error(Exception? error)=>Loc.Text(error switch {
        EditPersistenceConflict=>"照片或调整已变化，请重新打开后重试。",
        AdjustmentTransferException {Failure:AdjustmentFailure.EmptyScope}=>"请选择至少一项调整。",
        AdjustmentTransferException {Failure:AdjustmentFailure.Draft}=>"请先应用或放弃当前草稿。",
        AdjustmentTransferException {Failure:AdjustmentFailure.MissingLook}=>"目标缺少所选外观，请先导入外观。",
        AdjustmentTransferException {Failure:AdjustmentFailure.Incompatible or AdjustmentFailure.Unrepresentable}=>"所选调整与目标不兼容，请调整范围或跳过目标。",
        AdjustmentTransferException=>"无法读取这份调整，请重新复制。",
        _=>"保存失败，请检查文件和存储位置后重试。"
    });
}
