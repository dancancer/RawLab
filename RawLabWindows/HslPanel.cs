using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;

namespace RawLab.Windows;

public sealed class HslPanel : StackPanel
{
    private HslSettings settings = new();
    private int channel;
    private bool syncing, dragging;
    private readonly Slider[] sliders = new Slider[3];
    private readonly TextBox[] numbers = new TextBox[3];
    private readonly Button[] swatches = new Button[8];
    private readonly TextBlock[] labels = new TextBlock[3];
    private readonly Button reset = new();
    private static readonly string[] colorKeys = ["红", "橙", "黄", "绿", "青", "蓝", "紫", "洋红"];
    private static readonly string[] axisKeys = ["色相", "饱和度", "明度"];
    private static readonly string[] valueKeys = ["色相数值", "饱和度数值", "明度数值"];
    public event Action<HslSettings, bool>? Changed;

    public HslPanel()
    {
        MaxWidth = 500; Margin = new Thickness(12,4,12,4);
        var selector = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Center };
        var colors = new[] { Colors.Red, Colors.Orange, Colors.Yellow, Colors.LimeGreen, Colors.Cyan, Colors.DodgerBlue, Colors.Purple, Colors.Magenta };
        var names = new[] { Loc.Text("红"), Loc.Text("橙"), Loc.Text("黄"), Loc.Text("绿"), Loc.Text("青"), Loc.Text("蓝"), Loc.Text("紫"), Loc.Text("洋红") };
        for (var index=0; index<8; ++index)
        {
            var selected=index;
            var button=new Button { Width=40, Height=40, Margin=new Thickness(2), ToolTip=names[index],
                Content=new Ellipse { Width=20, Height=20, Fill=new SolidColorBrush(colors[index]) } };
            AutomationProperties.SetName(button,names[index]);
            button.Click+=(_,_)=>{channel=selected;Refresh(settings);};
            swatches[index]=button;selector.Children.Add(button);
        }
        Children.Add(selector);
        var axes=new[] { Loc.Text("色相"), Loc.Text("饱和度"), Loc.Text("明度") };
        for(var axis=0; axis<3; ++axis)
        {
            var selected=axis;
            var row=new DockPanel { Margin=new Thickness(0,5,0,5) };
            var label=new TextBlock { Text=axes[axis], Width=85, VerticalAlignment=VerticalAlignment.Center };
            labels[axis]=label;
            DockPanel.SetDock(label,Dock.Left);row.Children.Add(label);
            var number=new TextBox { Width=62, Margin=new Thickness(10,0,0,0), VerticalContentAlignment=VerticalAlignment.Center };
            AutomationProperties.SetName(number,Loc.Text(valueKeys[axis]));
            DockPanel.SetDock(number,Dock.Right);row.Children.Add(number);
            var slider=new Slider { Minimum=-100, Maximum=100, TickFrequency=1, IsSnapToTickEnabled=true, VerticalAlignment=VerticalAlignment.Center };
            AutomationProperties.SetName(slider,axes[axis]);
            slider.AddHandler(Thumb.DragStartedEvent,new DragStartedEventHandler((_,_)=>dragging=true));
            slider.AddHandler(Thumb.DragCompletedEvent,new DragCompletedEventHandler((_,_)=>{dragging=false;Changed?.Invoke(settings,false);}));
            slider.ValueChanged+=(_,e)=>{if(!syncing)Commit(selected,e.NewValue,dragging);};
            number.LostKeyboardFocus+=(_,_)=>{
                if(double.TryParse(number.Text,NumberStyles.Float,CultureInfo.CurrentCulture,out var value) && double.IsFinite(value))Commit(selected,value);
                else Refresh(settings);
            };
            row.Children.Add(slider);sliders[axis]=slider;numbers[axis]=number;Children.Add(row);
        }
        reset.Content=new EditorIcon { Kind="Reset", Width=18, Height=18 };
        reset.HorizontalAlignment=HorizontalAlignment.Right;
        AutomationProperties.SetName(reset,Loc.Text("重置 HSL"));
        reset.Click+=(_,_)=>{settings=new();Refresh(settings);Changed?.Invoke(settings,false);};
        Children.Add(reset);
        RefreshLanguage();
    }

    public void RefreshLanguage()
    {
        for (var index=0; index<8; ++index)
        {
            swatches[index].ToolTip=Loc.Text(colorKeys[index]);
            AutomationProperties.SetName(swatches[index],Loc.Text(colorKeys[index]));
        }
        for (var axis=0; axis<3; ++axis)
        {
            labels[axis].Text=Loc.Text(axisKeys[axis]);
            AutomationProperties.SetName(sliders[axis],Loc.Text(axisKeys[axis]));
            AutomationProperties.SetName(numbers[axis],Loc.Text(valueKeys[axis]));
        }
        reset.ToolTip=Loc.Text("重置 HSL");
        AutomationProperties.SetName(reset,Loc.Text("重置 HSL"));
    }

    private void Commit(int axis,double value,bool interactive=false) { settings=settings.WithValue(axis,channel,value);Refresh(settings);Changed?.Invoke(settings,interactive); }
    public void Refresh(HslSettings value)
    {
        settings=value;syncing=true;
        for(var axis=0; axis<3; ++axis) {sliders[axis].Value=value.Value(axis,channel);numbers[axis].Text=value.Value(axis,channel).ToString("+0;-0;0");}
        for(var index=0; index<8; ++index)swatches[index].BorderBrush=index==channel ? Brushes.Yellow : Brushes.Transparent;
        syncing=false;
    }
}
