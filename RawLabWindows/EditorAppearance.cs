using Microsoft.Win32;
using System.Windows;
using System.Windows.Media;

namespace RawLab.Windows;

internal static class EditorAppearance
{
    internal sealed record ContrastPalette(Brush Surface,Brush Foreground,Brush Selection,Brush SelectionText);
    internal static double TextScale
    {
        get
        {
            try{using var key=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Accessibility");return Math.Clamp(Convert.ToDouble(key?.GetValue("TextScaleFactor",100) ?? 100)/100,1,2.25);}
            catch(Exception ex) when(ex is System.Security.SecurityException or UnauthorizedAccessException or FormatException or InvalidCastException){return 1;}
        }
    }
    internal static void Apply(ResourceDictionary resources)=>Apply(resources,SystemParameters.HighContrast,
        new(SystemColors.WindowBrush,SystemColors.WindowTextBrush,SystemColors.HighlightBrush,SystemColors.HighlightTextBrush),TextScale);
    internal static void Apply(ResourceDictionary resources,bool high,ContrastPalette palette,double scale)
    {
        void Set(string key,string normal,Brush contrast)=>resources[key]=high ? contrast : (Brush)new BrushConverter().ConvertFromString(normal)!;
        Set("Accent","#F2CE48",palette.Selection);Set("AccentText","#252110",palette.SelectionText);
        Set("Surface","#272729",palette.Surface);Set("RaisedSurface","#303033",palette.Surface);
        Set("CanvasSurface","#1C1C1E",palette.Surface);Set("TreeSurface","#232326",palette.Surface);
        Set("WindowSurface","#181A1E",palette.Surface);Set("InputSurface","#212124",palette.Surface);
        Set("PopupSurface","#292C32",palette.Surface);Set("OverlaySurface","#D923252A",palette.Surface);
        Set("OverlayInk","#FFFFFF",palette.Foreground);Set("OverlayPaper","#24272D",palette.Surface);Set("OverlayAccent","#F2D259",palette.Foreground);
        Set("HistogramOutline","#00000000",palette.Foreground);
        resources["OverlayGridWidth"]=high ? 1.5 : .6;
        Set("Foreground","#EEEEF2",palette.Foreground);Set("Muted","#B1B1BC",palette.Foreground);
        Set("Outline","#444449",palette.Foreground);Set("Indicator","#F2CE48",palette.Foreground);
        Set("HoverSurface","#41454D",palette.Selection);Set("PressedSurface","#515662",palette.Selection);
        Set("HoverForeground","#EEEEF2",palette.SelectionText);
        Set("SelectedSurface","#34332D",palette.Selection);Set("SelectedForeground","#F2CE48",palette.SelectionText);
        Set("SelectionSurface","#756738",palette.Selection);Set("SelectionForeground","#FFFFFF",palette.SelectionText);
        Set("ErrorForeground","#FFAB92",palette.Foreground);Set("StatusForeground","#B5B8C0",palette.Foreground);
        Set("Track","#626771",palette.Foreground);Set("Thumb","#D8DBE1",palette.Surface);Set("ThumbOutline","#16181D",palette.Foreground);
        Set("ProgressSurface","#474B53",palette.Surface);
        Set("ScrollThumb","#555860",palette.Foreground);Set("ScrollHover","#858993",palette.Foreground);Set("ScrollPressed","#B3B7C0",palette.Foreground);
        resources["EditorBodySize"]=13*scale;resources["EditorCaptionSize"]=11*scale;resources["EditorEmptySize"]=24*scale;
    }
}
