using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using RawLab.Windows;

internal static class TransformUiChecks
{
    private const BindingFlags Private=BindingFlags.NonPublic|BindingFlags.Instance;
    internal static void Run(string repo,string raw,Action<bool,string> check)
    {
        if(File.Exists(Path.Combine(BatchJournal.DefaultDirectory,"job.json")))throw new InvalidOperationException("Preserve existing batch job; use an isolated test account.");
        var output=Path.Combine(repo,"build","windows-v08-ui");Directory.CreateDirectory(output);
        var directory=Path.Combine(output,Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        var photo=Path.Combine(directory,"photo"+Path.GetExtension(raw));var other=Path.Combine(directory,"other"+Path.GetExtension(raw));
        File.Copy(raw,photo);File.Copy(raw,other);
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        SynchronizationContext.SetSynchronizationContext(new DispatcherSynchronizationContext());
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        Loc.Initialize("zh-Hans");foreach(var pair in Loc.Strings)app.Resources[pair.Key]=pair.Value;
        var window=new MainWindow();var store=new EditStore(Path.Combine(directory,"edits"));Set(window,"editStore",store);
        try
        {
            window.GpuMode.SelectedIndex=1;window.Show();window.OpenFile(photo);
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            Click(window.AutoExposureButton);InteractionChecks.PumpUntil(()=>!Get<bool>(window,"autoExposing") && window.ExportPng.IsEnabled);
            var measured=Get<Adjustments>(window,"settings")[Parameter.Exposure];
            check(Math.Abs(measured*100-Math.Round(measured*100))<1e-6,"Native auto exposure commits to the visible 0.01 EV grid");
            Commit(window.ValueText,"0.13");InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            var invalidLook=Path.Combine(directory,"invalid.cube");File.WriteAllText(invalidLook,"not a CUBE");
            var goodLook=Path.Combine(repo,"lutools","flog-2-new","FLog2_to_PROVIA_65grid_V.1.00.cube");
            var import=window.ImportLookFiles([invalidLook,goodLook]);InteractionChecks.PumpUntil(()=>import.IsCompleted);
            check(import.GetAwaiter().GetResult().Count==1 && Get<string>(window,"lut")==goodLook,"Partial look import retains validated success and reports the invalid file");
            InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            // 用不同校准值证明草稿显影回调不会回写 committed WB。
            Get<Adjustments>(window,"settings").ResolveWhiteBalance((9000,-30));Invoke(window,"MarkEdited");
            Invoke(window,"SaveEdits");var original=Get<Adjustments>(window,"settings").Capture();
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            var draft=Get<TransformDraft>(window,"transform");
            check(draft.Active && !window.ExportPng.IsEnabled,"Real WPF geometry workspace gates export");
            check(Get<Adjustments>(window,"settings").Capture().SameAs(original),"Draft native WB result cannot overwrite deliberately different committed calibration");
            var previousLook=Get<string>(window,"lut");Set(window,"lut",Path.Combine(directory,"missing.cube"));
            typeof(MainWindow).GetMethod("Schedule",Private)!.Invoke(window,[false]);
            check(!window.ApplyDraftButton.IsEnabled && draft.Active,"Failed draft preview invalidates a previously ready Apply gate");
            Set(window,"lut",previousLook);typeof(MainWindow).GetMethod("Schedule",Private)!.Invoke(window,[false]);InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            var width=(TextBox)window.GeometryEditor.FindName("CropWidth");Commit(width,"60");
            check(draft.Geometry.CropWidth==.6 && Get<Adjustments>(window,"settings").Capture().SameAs(original) && store.Find(photo)!.Settings.SameAs(original),
                "Crop preview changes neither committed settings nor saved record");
            width.Text="bad";width.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,PresentationSource.FromVisual(window),Environment.TickCount,Key.Escape){RoutedEvent=Keyboard.PreviewKeyDownEvent});
            check(draft.Active && width.Text=="60","Escape restores only the current numeric input, not the geometry draft");
            Commit(width,"bad");Click(window.ApplyDraftButton);
            check(draft.Active && width.Text=="bad","Invalid geometry stays available for correction and cannot apply");
            Click((Button)window.GeometryEditor.FindName("ResetGeometry"));InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            check(!window.GeometryEditor.HasInvalidInput && draft.Geometry.IsIdentity,"Geometry reset clears invalid fields and resets the draft");
            Commit(width,"62");Click(window.ApplyDraftButton);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(!draft.Active && store.Find(photo)!.Settings.Geometry?.CropWidth==.62,"Apply writes the draft once to photo memory");
            Click(window.GeometryCategory);InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            Commit((TextBox)window.GeometryEditor.FindName("CropWidth"),"bad");
            Invoke(window,"CancelTransformDraft");InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(Get<Adjustments>(window,"settings").Geometry.CropWidth==.62 && !window.GeometryEditor.HasInvalidInput,"Cancel restores committed crop and clears invalid geometry input");
            Click(window.LensCategory);InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            ((CheckBox)window.LensEditor.FindName("Distortion")).IsChecked=true;
            InteractionChecks.PumpUntil(()=>window.ApplyDraftButton.IsEnabled);
            check(draft.Active && draft.Lens.Distortion && !Get<Adjustments>(window,"settings").Lens.Distortion,"Lens switches remain draft-only until apply");
            Click(window.ApplyDraftButton);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(store.Find(photo)!.Settings.Lens?.Distortion==true,"Lens Apply persists the real correction request");
            var blocked=Path.Combine(directory,"blocked");File.WriteAllText(blocked,"not a directory");Set(window,"editStore",new EditStore(blocked));
            Commit(window.ValueText,"0.27");Invoke(window,"SaveEdits");window.OpenFile(other);
            check(Get<string>(window,"file")==photo && window.RetrySave.Visibility==Visibility.Visible,"Persistent save failure blocks switching photos");
            Set(window,"editStore",store);Invoke(window,"SaveEdits");window.OpenFile(other);InteractionChecks.PumpUntil(()=>window.ExportPng.IsEnabled);
            check(Get<string>(window,"file")==other,"Retry releases the photo-switch guard after durable save");
            foreach(var size in new[]{new Size(1000,680),new Size(1440,920)})
            {
                var surface=EditorShellChecks.ArrangeLayout(window,size);
                check(window.ResultCanvas.ActualHeight>=160,"Real RAW layout retains 160 DIP canvas");
                var bitmap=new RenderTargetBitmap((int)surface.ActualWidth,(int)surface.ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(surface);
                var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using var stream=File.Create(Path.Combine(output,$"raw-{size.Width}.png"));encoder.Save(stream);
            }
        }
        finally{if(Get<TransformDraft>(window,"transform").Active)Invoke(window,"CancelTransformDraft");Set(window,"editStore",store);window.Close();InteractionChecks.PumpUntil(()=>!window.IsVisible);app.Shutdown();}
    }
    private static T Get<T>(object owner,string name)=>(T)owner.GetType().GetField(name,Private)!.GetValue(owner)!;
    private static void Set(object owner,string name,object value)=>owner.GetType().GetField(name,Private)!.SetValue(owner,value);
    private static object? Invoke(object owner,string name)=>owner.GetType().GetMethod(name,Private)!.Invoke(owner,null);
    private static void Click(Button button)=>button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Commit(TextBox field,string text){field.Text=text;field.RaiseEvent(new KeyboardFocusChangedEventArgs(Keyboard.PrimaryDevice,Environment.TickCount,field,field){RoutedEvent=UIElement.LostKeyboardFocusEvent});}
}
