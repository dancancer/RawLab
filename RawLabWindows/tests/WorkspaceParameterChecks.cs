using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using RawLab.Windows;

internal static class WorkspaceParameterChecks
{
    private const BindingFlags Private=BindingFlags.Instance|BindingFlags.NonPublic;
    private static T Get<T>(MainWindow window,string name)=>(T)typeof(MainWindow).GetField(name,Private)!.GetValue(window)!;
    private static object? Invoke(MainWindow window,string name,params object[] args)=>typeof(MainWindow).GetMethod(name,Private)!.Invoke(window,args);
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x,int y);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
    internal static void Run(MainWindow window,string output,Action<bool,string> check)
    {
        window.Width=1024;window.Height=720;window.FontSize=13;window.UpdateLayout();window.Activate();
        Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
        var state=Get<Adjustments>(window,"settings");var original=state.Capture();var revision=Get<long>(window,"editRevision");
        if(Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_POINTER")=="1") {
        window.ValueText.Focus();window.ValueText.Text="0.37";
        var target=window.Groups.Children.OfType<Button>().ElementAt(2);target.BringIntoView();window.UpdateLayout();
        ParameterInputUiChecks.Snapshot(window,window.AdjustmentPanel,Path.Combine(output,"navigation-before-native-click.png"));
        NativeClick(target);
        InteractionChecks.PumpUntil(()=>window.WhiteBalanceSurface.IsVisible);
        check(Get<long>(window,"editRevision")==revision && Get<Adjustments>(window,"settings").Capture().SameAs(original),
            "Native mouse navigation cancels numeric text at Preview before focus loss and Click");
        } else Console.WriteLine("NOT REACHED: native navigation click checks require the interactive pointer flag");
        Invoke(window,"SelectTool",EditorAdjustmentTool.Exposure);
        window.ValueText.Focus();window.ValueText.Text="0.39";
        var source=Path.Combine(output,"same-value-source"+Path.GetExtension(Get<string>(window,"file")));
        File.Copy(Get<string>(window,"file"),source,true);
        var store=Get<EditStore>(window,"editStore");store.Save(source,original,window.CurrentLookIdentity());
        window.OpenFile(source);window.AutoExposureButton.Focus();InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
        check(Get<Adjustments>(window,"settings").Capture().SameAs(original),"Actual same-value photo replacement cancels old numeric text before later blur");
        Invoke(window,"SelectTool",EditorAdjustmentTool.Hsl);window.HslEditor.SelectChannel(0);window.UpdateLayout();
        var rows=PhotoFeatureChecks.Descendants<ParameterRow>(window.HslEditor).ToArray();
        var beforeHsl=Get<Adjustments>(window,"settings").Capture();var beforeHslRevision=Get<long>(window,"editRevision");
        if(Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_POINTER")=="1") {
        rows[0].Number.Focus();rows[0].Number.Text="0.7";
        var swatches=PhotoFeatureChecks.Descendants<Button>(window.HslEditor).Where(button=>button.Content is StackPanel).ToArray();
        swatches[1].BringIntoView();window.UpdateLayout();NativeClick(swatches[1]);
        InteractionChecks.PumpUntil(()=>window.HslEditor.SelectedChannel==1);
        check(Get<long>(window,"editRevision")==beforeHslRevision && Get<Adjustments>(window,"settings").Capture().SameAs(beforeHsl),
            "Native HSL swatch mouse navigation cancels axis text before blur without touching either channel");
        }
        check(rows.All(row=>!PhotoFeatureChecks.Descendants<TextBlock>(row).Any(text=>text.Text is "%" or "°")),"HSL axes display no percentage or angle units");
        foreach(var (tool,name) in new[]{(EditorAdjustmentTool.Exposure,"exposure"),(EditorAdjustmentTool.WhiteBalance,"white-balance"),(EditorAdjustmentTool.Grain,"grain")}) {
            Invoke(window,"SelectTool",tool);window.UpdateLayout();
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
