namespace RawLab.Windows;

internal sealed class WorkspaceLayout
{
    private double? manualHeight;
    private bool? filesChoice;
    internal bool IsAutomatic=>manualHeight==null;
    internal double PanelHeight(bool complex,double available)=>Math.Min(manualHeight ?? (complex ? 344 : 220),Maximum(available));
    internal void Resize(double height,double available)=>manualHeight=Math.Clamp(height,216,Maximum(available));
    internal void RestoreAutomatic()=>manualHeight=null;
    internal bool ShowsFiles(double width,bool hasFolders)=>filesChoice ?? (hasFolders || width>=1100);
    internal void ToggleFiles(double width,bool hasFolders)=>filesChoice=!ShowsFiles(width,hasFolders);
    internal static bool CompactHistogram(double width,double height)=>width<760 || height<400;
    private static double Maximum(double available)=>Math.Max(216,available-166);
}
