using System.Windows;
using System.Windows.Media;

namespace RawLab.Windows;

// A single 24-unit, 1.6-unit stroke vocabulary for the editor's native controls.
public sealed class EditorIcon : FrameworkElement
{
    public static readonly DependencyProperty KindProperty=DependencyProperty.Register(nameof(Kind),typeof(string),typeof(EditorIcon),new FrameworkPropertyMetadata("Film",FrameworkPropertyMetadataOptions.AffectsRender));
    public string Kind { get=>(string)GetValue(KindProperty); set=>SetValue(KindProperty,value); }
    private static readonly Dictionary<string,Geometry> Shapes=new()
    {
        ["Info"]=Geometry.Parse("M12,2 A10,10 0 1 1 11.99,2 M12,11 V17 M12,7 V7.1"),
        ["Lens"]=Geometry.Parse("M9,3 H5 A2,2 0 0 0 3,5 V9 M15,3 H19 A2,2 0 0 1 21,5 V9 M21,15 V19 A2,2 0 0 1 19,21 H15 M9,21 H5 A2,2 0 0 1 3,19 V15 M12,8 A4,4 0 1 1 11.99,8"),
        ["Geometry"]=Geometry.Parse("M6,2 V18 H22 M2,6 H18 V22 M10,10 H14 V14 H10 Z"),
        ["Perspective"]=Geometry.Parse("M5,4 L19,7 V17 L5,20 Z M5,12 H19 M12,5.5 V18.5"),
        ["Processing"]=Geometry.Parse("M3,6 H21 M3,12 H21 M3,18 H21 M8,3 V9 M16,9 V15 M10,15 V21"),
        ["Lock"]=Geometry.Parse("M6,10 H18 V21 H6 Z M8,10 V6 A4,4 0 0 1 16,6 V10 M12,14 V17"),
        ["Unlock"]=Geometry.Parse("M6,10 H18 V21 H6 Z M8,10 V6 A4,4 0 0 1 16,6 M12,14 V17"),
        ["FlipHorizontal"]=Geometry.Parse("M12,2 V22 M3,5 L9,12 3,19 Z M21,5 L15,12 21,19 Z"),
        ["FlipVertical"]=Geometry.Parse("M2,12 H22 M5,3 L12,9 19,3 Z M5,21 L12,15 19,21 Z"),
        // Lucide Film, ISC license; converted from its SVG to WPF path geometry.
        ["Film"]=Geometry.Parse("M5,3 H19 A2,2 0 0 1 21,5 V19 A2,2 0 0 1 19,21 H5 A2,2 0 0 1 3,19 V5 A2,2 0 0 1 5,3 Z M7,3 V21 M3,7.5 H7 M3,12 H21 M3,16.5 H7 M17,3 V21 M17,7.5 H21 M17,16.5 H21"),
        ["Strength"]=Geometry.Parse("M12,3 A9,9 0 1 1 11.99,3 M12,7 A5,5 0 1 1 11.99,7"),
        ["Exposure"]=Geometry.Parse("M4,3 H20 V21 H4 Z M7,8 H13 M10,5 V11 M11,16 H17"),
        ["Temperature"]=Geometry.Parse("M9,14 V5 A3,3 0 0 1 15,5 V14 A5,5 0 1 1 9,14 M12,8 V17 M18,5 H21 M18,9 H20"),
        ["Tint"]=Geometry.Parse("M12,3 C8,9 5,12 5,15 A7,7 0 0 0 19,15 C19,12 16,9 12,3 M12,9 V20"),
        ["Contrast"]=Geometry.Parse("M12,3 A9,9 0 1 1 11.99,3 M12,3 V21 M15,5 V19 M18,8 V16"),
        ["Highlights"]=Geometry.Parse("M12,7 A5,5 0 1 1 11.99,7 M12,1 V4 M12,20 V23 M1,12 H4 M20,12 H23 M4,4 L6,6 M18,18 L20,20 M4,20 L6,18 M18,6 L20,4"),
        ["Shadows"]=Geometry.Parse("M15,3 A9,9 0 1 0 21,16 A9,9 0 0 1 15,3"),
        ["ToneCurve"]=Geometry.Parse("M3,3 V21 H21 M4,18 C17,18 7,6 20,6"),
        ["Saturation"]=Geometry.Parse("M12,3 A9,9 0 1 1 11.99,3 M3,12 H21 M5,16 H19 M8,19 H16"),
        // 锐化用空心三角（与 Mac 一致），不带内部竖线，免得和裁切提示的警告三角混淆
        ["Sharpening"]=Geometry.Parse("M12,3 L22,21 H2 Z"),
        ["Neutral"]=Geometry.Parse("M12,3 A9,9 0 1 1 11.99,3 M12,3 V21"),
        ["Add"]=Geometry.Parse("M12,4 V20 M4,12 H20"),
        ["Reset"]=Geometry.Parse("M4,10 A8,8 0 1 1 5,18 M4,4 V10 H10"),
        // 旋转画出被转动的方块，和只有一段回转箭头的“重置”区分开
        ["RotateLeft"]=Geometry.Parse("M4,11 H14 V21 H4 Z M19,14 A8,8 0 0 0 11,6 M14,3 L11,6 L14,9"),
        ["RotateRight"]=Geometry.Parse("M10,11 H20 V21 H10 Z M5,14 A8,8 0 0 1 13,6 M10,3 L13,6 L10,9"),
        ["Swap"]=Geometry.Parse("M4,8 H20 M16,4 L20,8 L16,12 M20,16 H4 M8,12 L4,16 L8,20"),
        ["Histogram"]=Geometry.Parse("M3,21 V14 H7 V8 H11 V3 H15 V10 H19 V16 H22 V21 Z"),
        ["ChevronDown"]=Geometry.Parse("M5,9 L12,16 19,9"),
        ["Photo"]=Geometry.Parse("M3,4 H21 V20 H3 Z M3,17 L9,11 14,16 17,13 21,17 M15,7 A1.5,1.5 0 1 1 14.99,7")
        ,["Folder"]=Geometry.Parse("M3,6 H10 L12,8 H21 V20 H3 Z M3,6 V4 H9 L11,6")
        ,["Library"]=Geometry.Parse("M3,4 H21 V20 H3 Z M9,4 V20 M5,8 H7 M5,12 H7")
        ,["Compare"]=Geometry.Parse("M3,4 H21 V20 H3 Z M12,4 V20")
        ,["Zoom"]=Geometry.Parse("M10,3 A7,7 0 1 1 9.99,3 M15,15 L21,21 M7,10 H13 M10,7 V13")
        ,["Clipping"]=Geometry.Parse("M12,3 L22,21 H2 Z M12,9 V14 M12,17 V18")
        ,["Adjust"]=Geometry.Parse("M3,6 H8 M12,6 H21 M3,12 H14 M18,12 H21 M3,18 H6 M10,18 H21 M8,3 V9 H12 V3 Z M14,9 V15 H18 V9 Z M6,15 V21 H10 V15 Z")
        ,["Export"]=Geometry.Parse("M12,3 V16 M7,11 L12,16 17,11 M3,16 V21 H21 V16")
        // ┌─ 以下各自对应一个功能，不与工具栏或工具条里的其他图标共用 ─────────────┐
        // │ 设置：齿轮；关于：问号；HSL：三色交叠；自动：魔杖；                    │
        // │ 降噪、颗粒：点状圆与点状方块（与 Mac 的 circle.dotted / square.dotted 对应）；│
        // │ 暗角：四角压暗的画框                                                    │
        // └────────────────────────────────────────────────────────────────────────┘
        ,["Settings"]=Geometry.Parse("M19.3,9.8 L21.9,10.3 L21.9,13.7 L19.3,14.3 L18.7,15.6 L20.2,17.8 L17.8,20.2 L15.6,18.7 L14.3,19.3 L13.7,21.9 L10.3,21.9 L9.8,19.3 L8.5,18.7 L6.2,20.2 L3.8,17.8 L5.3,15.6 L4.7,14.3 L2.1,13.7 L2.1,10.3 L4.7,9.8 L5.3,8.5 L3.8,6.2 L6.2,3.8 L8.5,5.3 L9.8,4.7 L10.3,2.1 L13.7,2.1 L14.3,4.7 L15.6,5.3 L17.8,3.8 L20.2,6.2 L18.7,8.5 Z M12,9 A3,3 0 1 1 11.99,9")
        ,["Help"]=Geometry.Parse("M12,2 A10,10 0 1 1 11.99,2 M9.5,9.5 A2.5,2.5 0 1 1 13.2,11.7 C12.4,12.2 12,12.8 12,13.8 M12,17 V17.1")
        ,["Hsl"]=Geometry.Parse("M12,3 A5,5 0 1 1 11.99,3 M8.5,9 A5,5 0 1 1 8.49,9 M15.5,9 A5,5 0 1 1 15.49,9")
        ,["Auto"]=Geometry.Parse("M4,20 L14,10 M12.5,8.5 L15.5,11.5 M18,3 V7 M16,5 H20 M20,11 V14 M18.5,12.5 H21.5 M8,3 V6 M6.5,4.5 H9.5")
        ,["Denoise"]=Geometry.Parse("M20.8,10.1 A9,9 0 0 1 20.8,13.9 M19.6,16.9 A9,9 0 0 1 16.9,19.6 M13.9,20.8 A9,9 0 0 1 10.1,20.8 M7.1,19.6 A9,9 0 0 1 4.4,16.9 M3.2,13.9 A9,9 0 0 1 3.2,10.1 M4.4,7.1 A9,9 0 0 1 7.1,4.4 M10.1,3.2 A9,9 0 0 1 13.9,3.2 M16.9,4.4 A9,9 0 0 1 19.6,7.1 M12,12 H12.01")
        ,["Grain"]=Geometry.Parse("M4,4 H7 M10.5,4 H13.5 M17,4 H20 V7 M20,10.5 V13.5 M20,17 V20 H17 M13.5,20 H10.5 M7,20 H4 V17 M4,13.5 V10.5 M4,7 V4 M9,9 H9.01 M15,9 H15.01 M12,12 H12.01 M9,15 H9.01 M15,15 H15.01")
        ,["Vignette"]=Geometry.Parse("M3,4 H21 V20 H3 Z M12,7.5 A5,4.5 0 1 1 11.99,7.5 M3,8 L7,4 M17,4 L21,8 M21,16 L17,20 M7,20 L3,16")
    };
    protected override void OnRender(DrawingContext dc)
    {
        var color=System.Windows.Documents.TextElement.GetForeground(this);
        var pen=new Pen(color,1.6){StartLineCap=PenLineCap.Round,EndLineCap=PenLineCap.Round,LineJoin=PenLineJoin.Round};
        var scale=Math.Min(ActualWidth,ActualHeight)/24;
        dc.PushTransform(new TranslateTransform((ActualWidth-24*scale)/2,(ActualHeight-24*scale)/2));
        dc.PushTransform(new ScaleTransform(scale,scale));
        dc.DrawGeometry(null,pen,Shapes.GetValueOrDefault(Kind,Shapes["Film"]));
        dc.Pop();dc.Pop();
    }
}
