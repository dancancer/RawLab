using Microsoft.Win32;
using System.Windows;
using System.Windows.Media;

namespace RawLab.Windows;

internal static class EditorAppearance
{
    internal static double TextScale
    {
        get
        {
            try{using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Accessibility");return Math.Clamp(Convert.ToDouble(key?.GetValue("TextScaleFactor",100) ?? 100)/100,1,2.25);}
            catch(Exception ex) when(ex is System.Security.SecurityException or UnauthorizedAccessException or FormatException or InvalidCastException){return 1;}
        }
    }
    internal static void Apply(ResourceDictionary resources)
    {
        var high=SystemParameters.HighContrast;
        Brush Color(string hex)=>(Brush)new BrushConverter().ConvertFromString(hex)!;
        resources["Accent"]=high ? SystemColors.HighlightBrush : Color("#F2CE48");
        resources["Surface"]=high ? SystemColors.WindowBrush : Color("#272729");
        resources["RaisedSurface"]=high ? SystemColors.ControlBrush : Color("#303033");
        resources["CanvasSurface"]=high ? SystemColors.WindowBrush : Color("#1C1C1E");
        resources["TreeSurface"]=high ? SystemColors.WindowBrush : Color("#232326");
        resources["Foreground"]=high ? SystemColors.WindowTextBrush : Color("#EEEEF2");
        resources["Muted"]=high ? SystemColors.WindowTextBrush : Color("#B1B1BC");
        resources["Outline"]=high ? SystemColors.WindowTextBrush : Color("#444449");
        resources["EditorBodySize"]=13*TextScale;resources["EditorCaptionSize"]=11*TextScale;resources["EditorEmptySize"]=24*TextScale;
    }
}
