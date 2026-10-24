using System.Globalization;
namespace RawLab.Windows;

internal static class BatchSettingsText
{
    internal static string Describe(AdjustmentSnapshot snapshot,string lookName,string path)
    {
        var state=PhotoInput.PrepareInputSettings(path,snapshot.Restore());
        var raster=PhotoInput.IsRaster(path);
        var text = Loc.Text("外观")+"  "+lookName+"\n"+string.Join("\n", ParameterSpec.All.Select(spec => $"{Loc.Text(spec.Title)}  {(spec.Id is Parameter.Temperature or Parameter.Tint && raster ? Loc.Text("不适用") : spec.Id is Parameter.Temperature or Parameter.Tint && state.CameraWhiteBalance ? Loc.Text("按每张照片") : state[spec.Id].ToString("F" + spec.Decimals) + spec.Unit)}"));
        text += "\n" + string.Join("\n", ToneControlSpec.All.Select(spec =>
            Row(spec.Title, state.ToneControls[spec.Id].ToString("+0.#;-0.#;0", CultureInfo.GetCultureInfo(Loc.Language)) + "%")));
        text += "\n" + string.Join("\n", Enum.GetValues<ColorGradingZone>().Select(zone =>
            Loc.Text("颜色分级") + " · " + Loc.Text(ColorGradingPanel.ZoneKeys[(int)zone]) + "  " +
            state.ColorGrading[zone].Hue.ToString("0.0", CultureInfo.GetCultureInfo(Loc.Language)) + "° · " +
            state.ColorGrading[zone].Saturation.ToString("0.0", CultureInfo.GetCultureInfo(Loc.Language)) + "%"));
        var channels=new[]{"红","橙","黄","绿","青","蓝","紫","洋红"};
        var axes=new[]{"色相","饱和度","明度"};
        for(var channel=0;channel<8;channel++)text+="\nHSL · "+Loc.Text(channels[channel])+"  "+
            string.Join(" · ",Enumerable.Range(0,3).Select(axis=>Loc.Text(axes[axis])+" "+Number(state.Hsl.Value(axis,channel))));
        // 降噪与镜头逐行沿用编辑器里的名称；关着的开关写"停用"
        text += "\n" + string.Join("\n", new[] {
            Row("降噪", OnOff(state.Denoise.Enabled)),
            Row("亮度降噪", Number(state.Denoise.Luma)),
            Row("色彩降噪", Number(state.Denoise.Chroma)),
            Row("粗色斑抑制", Number(state.Denoise.Coarse)),
            Row("镜头匹配", Loc.Text(state.Lens.Manual ? "手动" : "自动")),
            Row("畸变矫正", OnOff(state.Lens.Distortion)),
            Row("横向色差", OnOff(state.Lens.Tca)),
            Row("自动裁边", OnOff(state.Lens.AutoCrop))
        });
        var geometry = state.Geometry;
        text += "\n" + Loc.Format("几何：左边 {0:0.##}% · 顶边 {1:0.##}% · 宽度 {2:0.##}% · 高度 {3:0.##}% · 旋转 {4}° · 拉直 {5:0.##}°",
            geometry.CropX * 100, geometry.CropY * 100, geometry.CropWidth * 100, geometry.CropHeight * 100,
            geometry.QuarterTurns * 90, geometry.StraightenDegrees);
        text += "\n"+Loc.Format("透视：水平 {0:0.###} · 垂直 {1:0.###}",geometry.PerspectiveHorizontal,geometry.PerspectiveVertical);
        text += $"\n{Loc.Text("水平翻转")}  {OnOff(geometry.FlipHorizontal)} · {Loc.Text("垂直翻转")}  {OnOff(geometry.FlipVertical)}";
        var effects = state.Effects;
        var chroma = state.DisplayChromaDenoise switch { 1 => Loc.Text("细节优先"), 2 => Loc.Text("去噪优先"), _ => Loc.Text("停用") };
        text += Loc.Format("\n显示色彩降噪  {0}\n暗角  强度 {1:+0.#;-0.#;0} · 中点 {2:0.#} · 圆度 {3:+0.#;-0.#;0} · 羽化 {4:0.#} · 高光保护 {5:0.#}\n颗粒  强度 {6:0.#} · 大小 {7:0.#} · 粗糙度 {8:0.#}", chroma, effects.VignetteAmount, effects.VignetteMidpoint, effects.VignetteRoundness, effects.VignetteFeather, effects.VignetteHighlights, effects.GrainAmount, effects.GrainSize, effects.GrainRoughness);
        return text;
    }
    private static string Row(string title,string value)=>$"{Loc.Text(title)}  {value}";
    private static string OnOff(bool on)=>Loc.Text(on ? "开启" : "停用");
    private static string Number(double value)=>value.ToString("0.#",CultureInfo.GetCultureInfo(Loc.Language));
}
