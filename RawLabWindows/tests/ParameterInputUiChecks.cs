using System.IO;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using RawLab.Windows;

internal static class ParameterInputUiChecks
{
    internal static void Run(string output,Action<bool,string> check)
    {
        var row=new ParameterRow();var blur=new Button{Content="Focus target"};
        var content=new StackPanel{Margin=new Thickness(16)};content.Children.Add(row);content.Children.Add(blur);
        var host=new Window{Content=content,Width=760,Height=380};host.Show();
        try {
            row.Refresh("Crop X",new(0,0,.01,.1,.01,CompactPercent:true),0,0,"%");
            check(ReferenceEquals(row.Number.Background,Application.Current.Resources["InputSurface"]),
                "Native numeric subclass inherits the editor input background instead of system white");
            check(double.IsFinite(row.Slider.Value) && row.Slider.SmallChange==0 && row.Slider.LargeChange==0,
                "A full-width crop has a valid stationary native X control");
            var changes=new List<double>();row.Changed+=(value,_)=>changes.Add(value);
            row.SourceIdentity="source-a";row.Refresh("Exposure",new(-4,4,.01,.1,.01,false,2),.005,0,"EV",inputScope:"exposure");host.UpdateLayout();
            check(row.Number.Text=="0.01","Native input displays the original off-grid exposure with two decimals");
            row.Number.Focus();row.Number.Text="0.0050";PressKey(row.Number,Key.Enter);
            check(changes.Count==0 && row.Number.Text=="0.01","Formatting-only Enter preserves the original and makes no edit");
            row.Number.Text="0.01";PressKey(row.Number,Key.Enter);
            check(changes.Count==0 && row.Number.ActualValue==.005,"Confirming the rounded label preserves the full original precision");
            var peer=(IRangeValueProvider)UIElementAutomationPeer.CreatePeerForElement(row.Slider)!.GetPattern(PatternInterface.RangeValue)!;
            check(peer.Value==.005,"UIA exposes the complete original off-grid value");
            peer.SetValue(peer.Value);
            check(peer.Value==.005 && changes.Count==0,"UIA old-value read/write roundtrip is a zero-setter no-op");
            row.Number.Text="0.12";blur.Focus();host.UpdateLayout();
            check(changes.SequenceEqual(new[]{.12}),"Ordinary real keyboard-focus loss commits one legal changed value");
            row.Number.Focus();row.Number.Text="0.123";blur.Focus();host.UpdateLayout();
            check(row.Number.Text=="0.123" && row.HasInvalidInput && row.Number.ToolTip!=null && changes.Count==1,
                "Invalid grid text and its error survive native blur without a setter");
            PressKey(row.Number,Key.Escape);check(!row.HasInvalidInput && row.Number.Text=="0.12" && changes.Count==1,"Escape cancels only the invalid input draft");
            row.Number.Focus();row.Number.Text="0.23";
            row.SourceIdentity="source-b";row.Refresh("Exposure",new(-4,4,.01,.1,.01,false,2),.12,0,"EV",inputScope:"exposure");blur.Focus();
            check(changes.Count==1 && row.Number.Text=="0.12","Same-value source replacement invalidates text before the later blur");
            row.Number.Focus();row.Number.Text="0.24";row.CancelInput();blur.Focus();
            check(changes.Count==1,"Explicit navigation cancellation wins over subsequent native blur");
            foreach(var font in new[]{13.0,26.0}) {
                host.FontSize=font;row.Refresh("Exposure",new(-4,4,.01,.1,.01,false,2),-2,0,"EV",inputScope:"exposure");host.UpdateLayout();
                var number=row.Number.TransformToAncestor(row).TransformBounds(new Rect(row.Number.RenderSize));
                var track=row.Slider.TransformToAncestor(row).TransformBounds(new Rect(row.Slider.RenderSize));
                var file=Path.Combine(output,$"numeric-row-{font}.png");Snapshot(host,row,file);
                check(font==26 ? track.Top>=number.Bottom-.5 : Math.Abs(track.Top+track.Height/2-number.Top-number.Height/2)<12,
                    "Native parameter row uses a separate slider line only at large text: "+font);
            }
            var drawing=new DrawingGroup();using(var dc=drawing.Open())row.Slider.DrawTrack(dc,new Size(216,32));
            var fill=(LineGeometry)((GeometryDrawing)drawing.Children[1]).Geometry;
            check(fill.StartPoint.X==57.5 && fill.EndPoint.X==108,"Rendered negative fill runs from -2 to the actual zero default on the native track");
            if(Environment.GetEnvironmentVariable("RAWLAB_TEST_NATIVE_POINTER")=="1") {
            host.Activate();row.Number.Focus();row.Number.Select(0,0);
            var character=row.Number.GetRectFromCharacterIndex(1);
            var textPoint=new Point(character.X+2,character.Y+character.Height/2);
            Console.WriteLine($"Native number text={row.Number.Text}, character={character}, focused={row.Number.IsKeyboardFocused}");
            Snapshot(host,row,Path.Combine(output,"numeric-before-native-double-click.png"));
            WorkspaceParameterChecks.NativeClick(row.Number,textPoint);WorkspaceParameterChecks.NativeClick(row.Number,textPoint);
            Console.WriteLine($"Native number selection={row.Number.SelectionStart},{row.Number.SelectionLength}; focused={row.Number.IsKeyboardFocused}");
            Snapshot(host,row,Path.Combine(output,"numeric-after-native-double-click.png"));
            check(row.Number.SelectionLength>0,"Native double-click inside the numeric box retains text selection");
            var title=row.Children.OfType<TextBlock>().First();
            WorkspaceParameterChecks.NativeClick(title);WorkspaceParameterChecks.NativeClick(title);
            InteractionChecks.PumpUntil(()=>row.Number.Text=="0.00");
            check(changes.Last()==0,"Native double-click on the parameter name resets its effective default");
            row.Refresh("Exposure",new(-4,4,.01,.1,.01,false,2),-2,0,"EV",inputScope:"exposure");host.UpdateLayout();
            } else Console.WriteLine("NOT REACHED: native pointer checks require RAWLAB_TEST_NATIVE_POINTER=1 on an interactive input desktop");
            row.ContextMenu!.IsOpen=true;host.UpdateLayout();
            var reset=(MenuItem)row.ContextMenu.Items[0];
            check(UIElementAutomationPeer.CreatePeerForElement(reset)?.GetPattern(PatternInterface.Invoke)!=null,"Single-value reset has a native accessible menu action");
            reset.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));row.ContextMenu.IsOpen=false;
            check(changes.Last()==0,"Semantic reset uses the same effective default");
        } finally {host.Close();}
        var curveRow=new ParameterRow();var curveWindow=new Window {Content=curveRow,Width=600,Height=200};curveWindow.Show();
        try {
            const double precise=.25123456789;
            var changes=new List<double>();curveRow.Changed+=(value,_)=>changes.Add(value);
            curveRow.Refresh("Input",new(0,1,.001,.01,.001,AllowOffGrid:true),precise,0);
            curveWindow.UpdateLayout();
            check(curveRow.Number.Text=="0.25" && curveRow.Number.ActualValue==precise,"Curve input limits display decimals while retaining the Double value");
            check(System.Windows.Automation.AutomationProperties.GetHelpText(curveRow.Number).Contains("1/1000"),"Fine-step help never displays a nonzero step as zero");
            curveRow.Number.Focus();curveRow.Number.Text="0.25";PressKey(curveRow.Number,Key.Enter);
            check(changes.Count==0 && curveRow.Number.ActualValue==precise,"Unchanged rounded curve text makes no edit");
            curveRow.Number.Text="0.260000000000001";PressKey(curveRow.Number,Key.Enter);
            check(changes.SequenceEqual(new[]{.260000000000001}) && curveRow.Number.Text=="0.26","Precise curve input commits once then displays two decimals");
            Snapshot(curveWindow,curveRow,Path.Combine(output,"curve-numeric-display.png"));
        } finally {curveWindow.Close();}
        ColorGradingUiChecks.Run(output,check);
    }
    private static void PressKey(TextBox number,Key key)=>number.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,PresentationSource.FromVisual(number),Environment.TickCount,key){RoutedEvent=Keyboard.PreviewKeyDownEvent});
    internal static void Snapshot(Window window,FrameworkElement element,string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(Path.ChangeExtension(path,".bounds.txt"),$"window={window.ActualWidth}x{window.ActualHeight}; element={element.RenderSize}; desired={element.DesiredSize}\n");
        PhotoFeatureChecks.Screenshot(window,path);
    }
}
