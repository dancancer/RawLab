using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Documents;

namespace RawLab.Windows;

public sealed class ParameterRow : Grid
{
    public ParameterSlider Slider { get; } = new() { Minimum = 0, Maximum = 1, MinWidth = 140 };
    public TextBox Number { get; } = new() { Width = 72, MinHeight = 26, Padding = new Thickness(5,2,5,2),
        VerticalContentAlignment = VerticalAlignment.Center };
    public Button ResetButton { get; } = new() { Width = 28, Height = 28, MinHeight = 28, Padding = new Thickness(3), Margin = new Thickness(0),
        Content = new EditorIcon { Kind = "Reset", Width = 16, Height = 16 } };
    private readonly TextBlock label = new() { TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock unit = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ParameterWheel wheel = new();
    private NumericRange range = new(0,100);
    private double value, defaultValue;
    private bool syncing, dragging, dirty;
    public bool KeepInvalidInput { get; set; }
    public bool HasInvalidInput => dirty && range.Parse(Number.Text) == null;
    public event Action<double,bool>? Changed;
    public event Action? InvalidInput;

    public ParameterRow()
    {
        MaxWidth = 720; HorizontalAlignment = HorizontalAlignment.Stretch; MinHeight = 32;
        Margin = new Thickness(0,2,0,2);
        foreach (var width in new[] { new GridLength(120), new GridLength(1,GridUnitType.Star), new GridLength(72), new GridLength(22), new GridLength(28) })
            ColumnDefinitions.Add(new() { Width = width });
        var children = new UIElement[] { label, Slider, Number, unit, ResetButton };
        for (var i=0; i<children.Length; ++i) { SetColumn(children[i],i); Children.Add(children[i]); if(i<4)((FrameworkElement)children[i]).Margin=new Thickness(0,0,10,0); }
        ColumnDefinitions[0].Width=new GridLength(130); ColumnDefinitions[2].Width=new GridLength(82); ColumnDefinitions[3].Width=new GridLength(32);
        Typography.SetNumeralAlignment(Number,FontNumeralAlignment.Tabular);
        Slider.ValueChanged+=(_,e)=>{if(!syncing)Publish(range.Value(e.NewValue),dragging);};
        Slider.AddHandler(Thumb.DragStartedEvent,new DragStartedEventHandler((_,_)=>dragging=true));
        Slider.AddHandler(Thumb.DragCompletedEvent,new DragCompletedEventHandler((_,_)=>{dragging=false;Changed?.Invoke(value,false);}));
        Number.TextChanged+=(_,_)=>{if(!syncing)dirty=true;};
        Number.LostKeyboardFocus+=(_,_)=>Commit();
        Number.PreviewKeyDown+=(_,e)=>{
            if(e.Key==Key.Enter){Commit();e.Handled=true;}
            else if(e.Key==Key.Escape){RestoreText();e.Handled=true;}
        };
        Number.PreviewMouseWheel+=(_,e)=>{
            // Windows 垂直 wheel 的 120 delta 对应 80 逻辑像素；WM_MOUSEHWHEEL 不进入此事件。
            var editable=IsEnabled && Number.IsEnabled && !Number.IsReadOnly && range.Parse(Number.Text)!=null;
            var fine=(Keyboard.Modifiers&ModifierKeys.Shift)!=0;
            var motion=wheel.Feed(e.Delta*80.0/120,0,fine,Stopwatch.GetTimestamp()*1000/Stopwatch.Frequency,editable);
            e.Handled=motion.Consumed;
            if(motion.Steps!=0)Publish(range.Clamp(range.Parse(Number.Text)!.Value+motion.Steps*(fine ? range.FineWheel : range.Wheel)),false);
        };
        ResetButton.Click+=(_,_)=>Publish(defaultValue,false);
        SizeChanged+=(_,_)=>{
            ColumnDefinitions[0].Width=new GridLength(ActualWidth<600 ? 120 : 130);
            var scale=Math.Max(1,TextElement.GetFontSize(this)/13);
            Number.Width=72*scale;ColumnDefinitions[2].Width=new GridLength(Number.Width+10);ColumnDefinitions[3].Width=new GridLength(22*scale+10);
        };
    }

    public void Refresh(string title, NumericRange limits, double current, double reset, string suffix = "", bool enabled = true)
    {
        var changedRange=range!=limits;
        range=limits; value=current; defaultValue=reset;
        label.Text=title;unit.Text=suffix;IsEnabled=enabled;
        Slider.NumericRange=limits;Slider.SmallChange=limits.Grid/(limits.Max-limits.Min);Slider.LargeChange=limits.Wheel/(limits.Max-limits.Min);
        AutomationProperties.SetName(Slider,title);AutomationProperties.SetName(Number,title);
        AutomationProperties.SetHelpText(Number,$"{limits.Min} - {limits.Max} {suffix}");
        AutomationProperties.SetName(ResetButton,Loc.Format("重置{0}",title));ResetButton.ToolTip=Loc.Format("重置{0}",title);
        syncing=true;Slider.Value=range.Position(value);syncing=false;
        if(changedRange || !dirty || (!Number.IsKeyboardFocusWithin && !(KeepInvalidInput && HasInvalidInput)))RestoreText();
    }
    public void RestoreText()
    {
        syncing=true;Number.Text=range.Format(value);Number.ClearValue(ToolTipProperty);syncing=false;dirty=false;
    }
    public bool Commit()
    {
        if(!dirty || !IsEnabled || Number.IsReadOnly)return !HasInvalidInput;
        if(range.Parse(Number.Text) is { } next){Publish(next,false);return true;}
        Number.ToolTip=Loc.Text("请输入有限数值。");InvalidInput?.Invoke();
        if(!KeepInvalidInput)RestoreText();
        return false;
    }
    private void Publish(double next,bool interactive)
    {
        var changed=value!=next;value=next;RestoreText();syncing=true;Slider.Value=range.Position(value);syncing=false;
        if(changed)Changed?.Invoke(value,interactive);
    }
}
