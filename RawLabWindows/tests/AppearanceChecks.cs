using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class AppearanceChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        Directory.CreateDirectory(output);
        var app=new Application{ShutdownMode=ShutdownMode.OnExplicitShutdown};
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/Controls.xaml",UriKind.Relative)});
        app.Resources.MergedDictionaries.Add(new(){Source=new Uri("/RawLab;component/FileTreeStyles.xaml",UriKind.Relative)});
        var editor=new MainWindow();TestWindowState.Isolate(editor,output);editor.Show();
        var updates=new UpdateChecker("0.8.0",Path.Combine(output,"updates.json")){Automatic=false};
        var about=new AboutWindow(updates);var settings=new SettingsWindow(0);
        var sizeDialog=(Window)Activator.CreateInstance(typeof(LongEdgeDialog),BindingFlags.Instance|BindingFlags.NonPublic,null,new object?[]{null,editor},null)!;
        typeof(LongEdgeDialog).GetMethod("Accept",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(sizeDialog,null);
        typeof(MainWindow).GetMethod("SetStatus",BindingFlags.Instance|BindingFlags.NonPublic,null,new[]{typeof(string),typeof(bool)},null)!.Invoke(editor,new object[]{"Error",true});
        typeof(MainWindow).GetMethod("SetSaveNotice",BindingFlags.Instance|BindingFlags.NonPublic)!.Invoke(editor,new object[]{"保存失败","Detail",true});
        var job=BatchJob.Create("missing.arw",new Adjustments().Capture(),null,"Neutral");
        job.Items.Add(new(Guid.NewGuid(),"missing.arw",new("missing.arw",0,0,0)){Status=BatchStatus.Failed,Error="Failure detail"});
        var batch=new BatchExportWindow(job,new BatchJournal(Path.Combine(output,"batch")));
        var input=new TextBox{Text="1.25"};var combo=new ComboBox{ItemsSource=new[]{"GPU Automatic","CPU"},SelectedIndex=0};
        var button=new Button{Content="Action"};var selected=new Button{Content="Selected",Tag="selected"};
        var accent=new Button{Content="Primary",Style=(Style)app.Resources["AccentButton"]};
        var focus=new Control{Width=80,Height=28,Style=(Style)app.Resources["FocusOutline"]};
        var item=new TreeViewItem{Header="Folder",IsSelected=true};var tree=new TreeView();tree.Items.Add(item);
        var menuItem=new MenuItem{Header="Command"};var menu=new ContextMenu();menu.Items.Add(menuItem);
        var tip=new ToolTip{Content="Detail"};var panel=new StackPanel();
        var lensEditor=new LensPanel();
        lensEditor.Refresh(new(Manual:true),new(0,"","",false,false,1,new[]{new LensCandidate("test","Maker","Lens",true,false,true)}));
        var gallery=new ContentControl{Content=new PhotoGroup(new[]{new LibraryEntry("",false){IsSelected=true}}),
            ContentTemplate=(DataTemplate)editor.Files.FindResource(new DataTemplateKey(typeof(PhotoGroup)))};
        panel.SetResourceReference(Panel.BackgroundProperty,"WindowSurface");
        foreach(var control in new UIElement[]{input,combo,button,accent,selected,tree,lensEditor,gallery,focus})panel.Children.Add(control);
        var host=new Window{Content=panel,Width=600,Height=600};host.Show();
        about.Show();settings.Show();batch.Show();sizeDialog.Show();
        var swipeCanvas=Canvas();swipeCanvas.SetComparison(Image(),null);swipeCanvas.ComparisonEnabled=true;
        var cropCanvas=Canvas();cropCanvas.GeometryEditing=true;cropCanvas.SetCropDraft(new(){CropX=.2,CropY=.2,CropWidth=.6,CropHeight=.6},null,true);
        var histogram=new HistogramView{Width=180,Height=180,Bins=Enumerable.Repeat(1u,768).ToArray()};histogram.Bins[0]=2;
        var graphs=new StackPanel{Orientation=Orientation.Horizontal};graphs.Children.Add(swipeCanvas);graphs.Children.Add(cropCanvas);graphs.Children.Add(histogram);panel.Children.Insert(0,graphs);
        try
        {
            foreach(var light in new[]{true,false,true})
            {
                Apply(light);host.UpdateLayout();editor.UpdateLayout();about.UpdateLayout();settings.UpdateLayout();batch.UpdateLayout();sizeDialog.UpdateLayout();
                Pair(input.Foreground,input.Background,"numeric input");Pair(combo.Foreground,combo.Background,"GPU selector");
                input.IsEnabled=false;Pair(input.Foreground,input.Background,"disabled numeric input");input.IsEnabled=true;
                Pair(input.CaretBrush,input.Background,"input caret");
                focus.ApplyTemplate();
                check(VisualDescendants(focus).OfType<System.Windows.Shapes.Rectangle>().Max(rectangle=>Contrast(rectangle.Stroke,(Brush)app.Resources["SelectedSurface"]))>=4.5,"Keyboard focus remains visible over the selected surface: "+light);
                Pair((Brush)app.Resources["ScrollHover"],(Brush)app.Resources["TreeSurface"],"hovered scroll thumb");
                Pair(editor.ValueText.Foreground,editor.ValueText.Background,"actual parameter row");Pair(editor.GpuMode.Foreground,editor.GpuMode.Background,"actual footer GPU selector");
                Pair(about.Foreground,about.Background,"About window");Pair(settings.Foreground,settings.Background,"settings window");
                Pair(((CheckBox)about.FindName("UsageConsent")).Foreground,about.Background,"About usage consent");
                foreach(var link in Descendants(about).OfType<Hyperlink>())Pair(link.Foreground,about.Background,"About hyperlink");
                Pair(batch.Foreground,batch.Background,"batch window");
                Pair(editor.Status.Foreground,((Grid)editor.Content).Background,"actual error status");
                Pair(editor.SaveState.Foreground,((Grid)editor.Content).Background,"actual save failure");
                foreach(var text in Descendants(sizeDialog).OfType<TextBlock>())Pair(text.Foreground,sizeDialog.Background,"export size "+text.Text);
                foreach(var text in Descendants(about).OfType<TextBlock>())Pair(text.Foreground,about.Background,"About content "+text.Text);
                Pair(((TextBlock)batch.FindName("Summary")).Foreground,batch.Background,"batch summary");
                Pair(((TextBlock)batch.FindName("ErrorText")).Foreground,batch.Background,"batch error");
                var targets=(ListBox)batch.FindName("Targets");targets.SelectedIndex=0;targets.UpdateLayout();
                var target=(ListBoxItem)targets.ItemContainerGenerator.ContainerFromIndex(0);target.ApplyTemplate();
                SetState(target,"IsMouseOver",true);
                check(((Border)target.Template.FindName("Row",target)).Background==Brushes.Transparent,"Batch checkboxes do not acquire an unrelated selection surface: "+light);
                foreach(var text in VisualDescendants(target).OfType<TextBlock>())Pair(text.Foreground,batch.Background,"batch row "+text.Text);
                SetState(target,"IsMouseOver",false);
                Pair(((TextBlock)editor.DenoiseEditor.FindName("Summary")).Foreground,(Brush)app.Resources["Surface"],"denoise summary");
                Pair(input.SelectionTextBrush,input.SelectionBrush,"input selection");
                Pair(editor.BusyAnimation.Foreground,editor.BusyAnimation.Background,"busy progress");
                var progress=(ProgressBar)batch.FindName("Progress");Pair(progress.Foreground,progress.Background,"batch progress");
                var slider=editor.ValueSlider;slider.ApplyTemplate();
                var sliderTrack=(Track)slider.Template.FindName("PART_Track",slider);sliderTrack.Thumb.ApplyTemplate();
                var knob=(Border)sliderTrack.Thumb.Template.FindName("Knob",sliderTrack.Thumb);
                Pair(knob.BorderBrush,(Brush)app.Resources["Surface"],"slider thumb boundary");
                Pair(knob.Background,(Brush)app.Resources["Track"],"slider thumb and track");
                menu.PlacementTarget=button;menu.IsOpen=true;menu.ApplyTemplate();menu.UpdateLayout();
                Pair(menu.Foreground,menu.Background,"context menu");
                tip.PlacementTarget=button;tip.IsOpen=true;tip.ApplyTemplate();tip.UpdateLayout();Pair(tip.Foreground,tip.Background,"tooltip");
                combo.IsDropDownOpen=true;combo.ApplyTemplate();combo.UpdateLayout();
                var popup=(Popup)combo.Template.FindName("PART_Popup",combo);
                Pair(combo.Foreground,((Border)popup.Child).Background,"GPU popup");
                var option=(ComboBoxItem)combo.ItemContainerGenerator.ContainerFromIndex(0);option.ApplyTemplate();
                Pair(option.Foreground,((Border)option.Template.FindName("Item",option)).Background,"selected GPU option");combo.IsDropDownOpen=false;
                SetState(combo,"IsMouseOver",true);Pair(combo.Foreground,combo.Background,"GPU hover");SetState(combo,"IsMouseOver",false);
                var lens=(Popup)lensEditor.FindName("Chooser");lens.IsOpen=true;((Border)lens.Child).UpdateLayout();
                Pair(TextElement.GetForeground((Border)lens.Child),((Border)lens.Child).Background,"lens popup");
                var profiles=(ListBox)lensEditor.FindName("Profiles");profiles.UpdateLayout();
                check(profiles.Background.ToString()==(light ? Brushes.White : Brushes.Black).ToString(),"Lens list uses the current paired surface: "+light);
                Pair(profiles.Foreground,profiles.Background,"lens list");
                var profile=(ListBoxItem)profiles.ItemContainerGenerator.ContainerFromIndex(0);profile.IsSelected=true;profile.ApplyTemplate();profile.UpdateLayout();
                var profileSurface=profile.Template.FindName("Item",profile) as Border ?? VisualDescendants(profile).OfType<Border>().First();
                foreach(var text in VisualDescendants(profile).OfType<TextBlock>())Pair(text.Foreground,profileSurface.Background,"selected lens "+text.Text);
                profile.IsSelected=false;SetState(profile,"IsMouseOver",true);profile.UpdateLayout();
                foreach(var text in VisualDescendants(profile).OfType<TextBlock>())Pair(text.Foreground,profileSurface.Background,"hovered lens "+text.Text);
                SetState(profile,"IsMouseOver",false);lens.IsOpen=false;
                var photo=VisualDescendants(gallery).OfType<Button>().First();photo.ApplyTemplate();
                Pair(photo.Foreground,((Border)photo.Template.FindName("Surface",photo)).Background,"actual selected photo");
                SetState(photo,"IsMouseOver",true);Pair(photo.Foreground,((Border)photo.Template.FindName("Surface",photo)).Background,"actual hovered photo");SetState(photo,"IsMouseOver",false);
                var heading=((StackPanel)editor.Welcome).Children.OfType<TextBlock>().First();
                Pair(heading.Foreground,((Grid)editor.Content).Background,"empty heading");
                var bitmap=new RenderTargetBitmap((int)editor.ResultCanvas.ActualWidth,(int)editor.ResultCanvas.ActualHeight,96,96,PixelFormats.Pbgra32);
                bitmap.Render(editor.ResultCanvas);var pixel=new byte[4];bitmap.CopyPixels(new Int32Rect(0,0,1,1),pixel,4,0);
                check(pixel[3]==255 && pixel[0]==(light ? 255 : 0) && pixel[1]==pixel[0] && pixel[2]==pixel[0],"Empty canvas redraws the current runtime palette: "+light);
                var dividerPixel=Pixel(swipeCanvas,90,10);
                check(light ? dividerPixel<128 : dividerPixel>128,"Existing swipe divider redraws the current contrast ink: "+light+"/"+dividerPixel);
                var handlePixel=Pixel(cropCanvas,36,90);check(handlePixel==(light ? 255 : 0),"Existing crop handle redraws the paired contrast surface: "+light+"/"+handlePixel);
                var gridPixel=Pixel(cropCanvas,72,100);
                check(light ? gridPixel<128 : gridPixel>128,"Existing crop grid redraws the current contrast ink: "+light+"/"+gridPixel);
                var histogramPixel=Pixel(histogram,90,90);
                check(light ? histogramPixel<128 : histogramPixel>190,"Histogram keeps a readable envelope without replacing RGB channel colors: "+light+"/"+histogramPixel);
                foreach(var state in new[]{"IsMouseOver","IsPressed"})
                {
                    SetState(button,state,true);button.ApplyTemplate();button.UpdateLayout();
                    Pair(button.Foreground,((Border)button.Template.FindName("Surface",button)).Background,"button "+state);
                    SetState(button,state,false);
                    SetState(accent,state,true);accent.ApplyTemplate();accent.UpdateLayout();
                    Pair(accent.Foreground,((Border)accent.Template.FindName("Surface",accent)).Background,"primary "+state);SetState(accent,state,false);
                }
                selected.ApplyTemplate();Pair(selected.Foreground,((Border)selected.Template.FindName("Surface",selected)).Background,"selected tool");
                SetState(menuItem,"IsHighlighted",true);menuItem.ApplyTemplate();menuItem.UpdateLayout();
                Pair(menuItem.Foreground,((Border)menuItem.Template.FindName("MenuSurface",menuItem)).Background,"highlighted menu");SetState(menuItem,"IsHighlighted",false);
                item.ApplyTemplate();Pair(item.Foreground,((Border)item.Template.FindName("HeaderSurface",item)).Background,"selected folder");
                tip.IsOpen=menu.IsOpen=false;
                panel.Width=584;panel.Height=561;panel.Measure(new Size(584,561));panel.Arrange(new Rect(0,0,584,561));panel.UpdateLayout();
                EditorShellChecks.CaptureLayout(host,panel,Path.Combine(output,light ? "contrast-light.png" : "contrast-dark.png"));
                void Pair(Brush foreground,Brush background,string name)=>check(Contrast(foreground,background)>=4.5,"Readable runtime palette: "+light+"/"+name+" "+foreground+"/"+background);
            }
            foreach(var scale in new[]{1.0,2.0,2.25,1.0})
            {
                EditorAppearance.Apply(app.Resources,true,new(Brushes.White,Brushes.Black,Brushes.Navy,Brushes.White),scale);
                editor.UpdateLayout();
                foreach(var strip in new[]{editor.Tools,editor.FilmStrip})
                {
                    var captions=Descendants(strip).OfType<TextBlock>().ToArray();
                    check(captions.Length>0 && captions.All(text=>Math.Abs(text.FontSize-11*scale)<.001),"Retained tool/film captions follow live text scale: "+strip.Name+"/"+scale);
                }
                foreach(var recipe in editor.RecipeStrip.Children.OfType<Button>())
                {
                    var labels=((StackPanel)recipe.Content).Children.OfType<TextBlock>().ToArray();
                    check(labels.Length==2 && Math.Abs(labels[0].FontSize-13*scale)<.001 && Math.Abs(labels[1].FontSize-11*scale)<.001,
                        "Retained recipe title and caption follow live text scale: "+scale+"/"+labels[0].Text);
                }
            }
            EditorAppearance.Apply(app.Resources,false,new(Brushes.White,Brushes.Black,Brushes.Navy,Brushes.White),1);
            check(Contrast(input.Foreground,input.Background)>=4.5 && input.Background.ToString()=="#FF212124","Retained input returns from high contrast to the normal palette");
            check((double)app.Resources["OverlayGridWidth"]==.6 && (Brush)app.Resources["HistogramOutline"] is SolidColorBrush{Color.A:0},"Normal palette restores overlay grid width and hides the histogram envelope");
        }
        finally{tip.IsOpen=menu.IsOpen=false;host.Close();sizeDialog.Close();about.Close();settings.Close();batch.Close();editor.Close();app.Shutdown();}
        void Apply(bool light)
        {
            EditorAppearance.Apply(app.Resources,true,new(light ? Brushes.White : Brushes.Black,light ? Brushes.Black : Brushes.White,
                light ? Brushes.Navy : Brushes.Yellow,light ? Brushes.White : Brushes.Black),1);
        }
        static BitmapSource Image()=>BitmapSource.Create(1,1,96,96,PixelFormats.Bgra32,null,new byte[]{128,128,128,255},4);
        static PhotoCanvas Canvas()
        {
            var canvas=new PhotoCanvas{Width=180,Height=180,Viewport=new Viewport()};canvas.Viewport.SetSourceSize(1,1);canvas.SetImage(Image(),null);
            canvas.Measure(new Size(180,180));canvas.Arrange(new Rect(0,0,180,180));canvas.UpdateLayout();return canvas;
        }
        byte Pixel(FrameworkElement canvas,int x,int y)
        {
            var drawing=new DrawingVisual();using(var context=drawing.RenderOpen()){
                context.DrawRectangle((Brush)app.Resources["CanvasSurface"],null,new Rect(0,0,180,180));
                context.DrawRectangle(new VisualBrush(canvas){Stretch=Stretch.Fill},null,new Rect(0,0,180,180));
            }
            var bitmap=new RenderTargetBitmap(180,180,96,96,PixelFormats.Pbgra32);bitmap.Render(drawing);
            var pixel=new byte[4];bitmap.CopyPixels(new Int32Rect(x,y,1,1),pixel,4,0);
            if(pixel[3]!=255 || pixel[0]!=pixel[1] || pixel[1]!=pixel[2])throw new InvalidOperationException($"Unexpected grayscale overlay raster: {canvas.GetType().Name}, pixel={x},{y}:{string.Join(',',pixel)}.");return pixel[0];
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        foreach(var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
        {yield return child;foreach(var nested in Descendants(child))yield return nested;}
    }
    private static IEnumerable<DependencyObject> VisualDescendants(DependencyObject root)
    {
        for(var i=0;i<VisualTreeHelper.GetChildrenCount(root);i++)
        {var child=VisualTreeHelper.GetChild(root,i);yield return child;foreach(var nested in VisualDescendants(child))yield return nested;}
    }
    private static void SetState(Control control,string name,bool value)
    {
        var owner=name=="IsMouseOver" ? typeof(UIElement) : name=="IsPressed" ? typeof(ButtonBase) : typeof(MenuItem);
        var key=(DependencyPropertyKey)owner.GetField(name+"PropertyKey",BindingFlags.Static|BindingFlags.NonPublic|BindingFlags.Public)!.GetValue(null)!;
        control.SetValue(key,value);
    }
    private static double Contrast(Brush foreground,Brush background)
    {
        double L(Brush brush){var c=((SolidColorBrush)brush).Color;double Channel(byte value){var n=value/255.0;return n<=.04045 ? n/12.92 : Math.Pow((n+.055)/1.055,2.4);}return .2126*Channel(c.R)+.7152*Channel(c.G)+.0722*Channel(c.B);}
        var a=L(foreground);var b=L(background);return (Math.Max(a,b)+.05)/(Math.Min(a,b)+.05);
    }
}
