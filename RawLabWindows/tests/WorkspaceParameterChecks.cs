using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using RawLab.Windows;

internal static class WorkspaceParameterChecks
{
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
    internal static void Run(MainWindow window,string output,Action<bool,string> check)
    {
        window.Width=1024;window.Height=720;window.FontSize=13;window.UpdateLayout();window.Activate();
        window.SelectToolForTests(EditorAdjustmentTool.Exposure);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
        var state=window.Settings;var original=state.Capture();var revision=window.EditRevision;
        if(Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_POINTER")=="1") {
        window.ValueText.Focus();window.ValueText.Text="0.37";
        var target=window.Groups.Children.OfType<Button>().ElementAt(2);target.BringIntoView();window.UpdateLayout();
        ParameterInputUiChecks.Snapshot(window,window.AdjustmentPanel,Path.Combine(output,"navigation-before-native-click.png"));
        NativeClick(target);
        InteractionChecks.PumpUntil(()=>window.WhiteBalanceSurface.IsVisible);
        check(window.EditRevision==revision && window.Settings.Capture().SameAs(original),
            "Native mouse navigation cancels numeric text at Preview before focus loss and Click");
        } else Console.WriteLine("NOT REACHED: native navigation click checks require the interactive pointer flag");
        window.SelectToolForTests(EditorAdjustmentTool.Exposure);
        window.ValueText.Focus();window.ValueText.Text="0.39";
        var source=Path.Combine(output,"same-value-source"+Path.GetExtension(window.CurrentFile));
        File.Copy(window.CurrentFile!,source,true);
        var store=window.EditStoreInstance!;store.Save(source,original,window.CurrentLookIdentity());
        window.OpenFile(source);window.AutoExposureButton.Focus();InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
        check(window.Settings.Capture().SameAs(original),"Actual same-value photo replacement cancels old numeric text before later blur");
        window.SelectToolForTests(EditorAdjustmentTool.Hsl);window.HslEditor.SelectChannel(0);window.UpdateLayout();
        var rows=PhotoFeatureChecks.Descendants<ParameterRow>(window.HslEditor).ToArray();
        var beforeHsl=window.Settings.Capture();var beforeHslRevision=window.EditRevision;
        if(Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_POINTER")=="1") {
        rows[0].Number.Focus();rows[0].Number.Text="0.7";
        var swatches=PhotoFeatureChecks.Descendants<Button>(window.HslEditor).Where(button=>button.Content is StackPanel).ToArray();
        swatches[1].BringIntoView();window.UpdateLayout();NativeClick(swatches[1]);
        InteractionChecks.PumpUntil(()=>window.HslEditor.SelectedChannel==1);
        check(window.EditRevision==beforeHslRevision && window.Settings.Capture().SameAs(beforeHsl),
            "Native HSL swatch mouse navigation cancels axis text before blur without touching either channel");
        }
        check(rows.All(row=>!PhotoFeatureChecks.Descendants<TextBlock>(row).Any(text=>text.Text is "%" or "°")),"HSL axes display no percentage or angle units");
        foreach(var (tool,name) in new[]{(EditorAdjustmentTool.Exposure,"exposure"),(EditorAdjustmentTool.WhiteBalance,"white-balance"),(EditorAdjustmentTool.Grain,"grain")}) {
            window.SelectToolForTests(tool);window.UpdateLayout();
            ParameterInputUiChecks.Snapshot(window,window.AdjustmentPanel,Path.Combine(output,"representative-"+name+".png"));
        }
    }
    internal static void NativeClick(FrameworkElement control,Point? location=null)
    {
        var point=control.PointToScreen(location ?? new Point(control.ActualWidth/2,control.ActualHeight/2));
        Console.WriteLine($"Native pointer target={control.GetType().Name}, screen={point}, bounds={control.RenderSize}");
        if(!SetCursorPos((int)point.X,(int)point.Y))throw new InvalidOperationException("Native test could not position the pointer");
        mouse_event(0x0002,0,0,0,UIntPtr.Zero);mouse_event(0x0004,0,0,0,UIntPtr.Zero);
        var clock=System.Diagnostics.Stopwatch.StartNew();
        InteractionChecks.PumpUntil(()=>clock.ElapsedMilliseconds>=40);
    }
}
