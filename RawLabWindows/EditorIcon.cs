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
        ["Sharpening"]=Geometry.Parse("M12,3 L22,21 H2 Z M12,8 V17 M9,17 H15"),
        ["Neutral"]=Geometry.Parse("M12,3 A9,9 0 1 1 11.99,3 M12,3 V21"),
        ["Add"]=Geometry.Parse("M12,4 V20 M4,12 H20"),
        ["Reset"]=Geometry.Parse("M4,10 A8,8 0 1 1 5,18 M4,4 V10 H10"),
        ["Histogram"]=Geometry.Parse("M3,21 V14 H7 V8 H11 V3 H15 V10 H19 V16 H22 V21 Z"),
        ["ChevronDown"]=Geometry.Parse("M5,9 L12,16 19,9"),
        ["Photo"]=Geometry.Parse("M3,4 H21 V20 H3 Z M3,17 L9,11 14,16 17,13 21,17 M15,7 A1.5,1.5 0 1 1 14.99,7")
        ,["Folder"]=Geometry.Parse("M3,6 H10 L12,8 H21 V20 H3 Z M3,6 V4 H9 L11,6")
        ,["Library"]=Geometry.Parse("M3,4 H21 V20 H3 Z M9,4 V20 M5,8 H7 M5,12 H7")
        ,["Compare"]=Geometry.Parse("M12,2 V22 M9,5 H3 V19 H9 M15,5 H21 V19 H15 M5,12 H8 M16,12 H19")
        ,["Zoom"]=Geometry.Parse("M10,3 A7,7 0 1 1 9.99,3 M15,15 L21,21 M7,10 H13 M10,7 V13")
        ,["Clipping"]=Geometry.Parse("M12,3 L22,21 H2 Z M12,9 V14 M12,17 V18")
        ,["Adjust"]=Geometry.Parse("M3,6 H8 M12,6 H21 M3,12 H14 M18,12 H21 M3,18 H6 M10,18 H21 M8,3 V9 H12 V3 Z M14,9 V15 H18 V9 Z M6,15 V21 H10 V15 Z")
        ,["Export"]=Geometry.Parse("M12,3 V16 M7,11 L12,16 17,11 M3,16 V21 H21 V16")
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
