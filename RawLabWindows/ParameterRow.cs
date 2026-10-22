using System.Diagnostics;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Documents;
using System.Windows.Media;

namespace RawLab.Windows;

public sealed class ParameterRow : Grid
{
    public ParameterSlider Slider { get; } = new() { Minimum=0,Maximum=1,MinWidth=140 };
    public TextBox Number { get; } = new() { MinHeight=26,Padding=new Thickness(5,2,5,2),VerticalContentAlignment=VerticalAlignment.Center };
    // 保留对象供旧调用方设置可访问名称；实际入口由语义菜单和名称/轨道双击提供。
    public Button ResetButton { get; } = new() { Visibility=Visibility.Collapsed };
    private readonly TextBlock label=new(){TextWrapping=TextWrapping.Wrap,VerticalAlignment=VerticalAlignment.Center};
    private readonly TextBlock unit=new(){VerticalAlignment=VerticalAlignment.Center};
    private readonly TextBlock error=new(){TextWrapping=TextWrapping.Wrap,Visibility=Visibility.Collapsed};
    private readonly ParameterWheel wheel=new();
    private readonly NumericInputSession input=new();
    private NumericRange range=new(0,100);
    private object? source,scope;
    private double value,defaultValue;
    private bool syncing,dragging,dragChanged;
    private string title="",suffix="",help="";
    public bool KeepInvalidInput { get; set; }
    public bool HasInvalidInput => input.Dirty && range.Parse(Number.Text,input.Original)==null;
    public object? SourceIdentity { get=>source; set {if(Equals(source,value))return;source=value;input.Bind(source,scope,range,this.value);RestoreText();} }
    public event Action<double,bool>? Changed;
    public event Action? InvalidInput;

    public ParameterRow()
    {
        MaxWidth=720;HorizontalAlignment=HorizontalAlignment.Stretch;MinHeight=32;Margin=new Thickness(0,2,0,2);
        for(var i=0;i<4;i++)ColumnDefinitions.Add(new());
        RowDefinitions.Add(new(){Height=GridLength.Auto});RowDefinitions.Add(new(){Height=GridLength.Auto});RowDefinitions.Add(new(){Height=GridLength.Auto});
        foreach(var child in new UIElement[]{label,Slider,Number,unit,ResetButton,error})Children.Add(child);
        SetRow(error,2);SetColumnSpan(error,4);error.SetResourceReference(TextBlock.ForegroundProperty,"ErrorForeground");
        Typography.SetNumeralAlignment(Number,FontNumeralAlignment.Tabular);
        Slider.ValueChanged+=(_,e)=>{if(!syncing)Publish(range.Value(e.NewValue),dragging);};
        Slider.AddHandler(Thumb.DragStartedEvent,new DragStartedEventHandler((_,_)=>{dragging=true;dragChanged=false;}));
        Slider.AddHandler(Thumb.DragCompletedEvent,new DragCompletedEventHandler((_,_)=>{dragging=false;if(dragChanged)Changed?.Invoke(value,false);dragChanged=false;}));
        Number.TextChanged+=(_,_)=>{if(!syncing)input.Edit(Number.Text);};
        Number.LostKeyboardFocus+=(_,_)=>Commit();
        Number.PreviewKeyDown+=(_,e)=>{if(e.Key==Key.Enter){Commit();e.Handled=true;}else if(e.Key==Key.Escape){CancelInput();e.Handled=true;}};
        Number.PreviewMouseWheel+=(_,e)=>{
            var number=range.Parse(Number.Text,input.Original);
            var editable=IsEnabled && Number.IsEnabled && !Number.IsReadOnly && number!=null;
            var fine=(Keyboard.Modifiers&ModifierKeys.Shift)!=0;
            var motion=wheel.Feed(e.Delta*80.0/120,0,fine,Stopwatch.GetTimestamp()*1000/Stopwatch.Frequency,editable);
            e.Handled=motion.Consumed;
            if(motion.Steps!=0)Publish(range.Clamp(number!.Value+motion.Steps*(fine ? range.FineWheel : range.Wheel)),false);
        };
        ResetButton.Click+=(_,_)=>ResetValue();
        label.MouseLeftButtonDown+=(_,e)=>{if(e.ClickCount==2){ResetValue();e.Handled=true;}};
        Slider.PreviewMouseLeftButtonDown+=(_,e)=>{if(e.ClickCount==2){ResetValue();e.Handled=true;}};
        var menu=new ContextMenu();var reset=new MenuItem();menu.Items.Add(reset);
        reset.Click+=(_,_)=>ResetValue();ContextMenu=menu;
        menu.Opened+=(_,_)=>{reset.Header=Loc.Format("重置{0}",title);reset.IsEnabled=IsEnabled && value!=defaultValue;};
        IsVisibleChanged+=(_,_)=>{if(!IsVisible)CancelInput();};
        SizeChanged+=(_,_)=>LayoutRow();
        LayoutRow();
    }
    private void LayoutRow()
    {
        var scale=Math.Max(1,TextElement.GetFontSize(this)/13);
        var large=TextElement.GetFontSize(this)>=20;
        var typeface=new Typeface(Number.FontFamily,Number.FontStyle,Number.FontWeight,Number.FontStretch);
        var width=new FormattedText(range.Format(value),System.Globalization.CultureInfo.GetCultureInfo(Loc.Language),FlowDirection.LeftToRight,typeface,Number.FontSize,Brushes.Black,1).WidthIncludingTrailingWhitespace+18;
        Number.Width=Math.Max(72*scale,width);
        ColumnDefinitions[0].Width=large ? new(1,GridUnitType.Star) : new(ActualWidth<600 ? 120 : 130);
        ColumnDefinitions[1].Width=large ? GridLength.Auto : new(1,GridUnitType.Star);
        ColumnDefinitions[2].Width=GridLength.Auto;ColumnDefinitions[3].Width=large ? new(0) : GridLength.Auto;
        SetRow(label,0);SetColumn(label,0);label.Margin=new(0,0,10,0);
        SetRow(Number,0);SetColumn(Number,large ? 1 : 2);Number.Margin=new(0,0,10,0);
        SetRow(unit,0);SetColumn(unit,large ? 2 : 3);unit.MinWidth=22*scale;
        SetRow(Slider,large ? 1 : 0);SetColumn(Slider,large ? 0 : 1);SetColumnSpan(Slider,large ? 3 : 1);Slider.Margin=new(0,0,10,0);
    }
    public void Refresh(string title,NumericRange limits,double current,double reset,string suffix="",bool enabled=true,object? inputScope=null)
    {
        this.title=title;this.suffix=suffix;range=limits;value=current;defaultValue=reset;scope=inputScope??title;
        var rebound=input.Bind(source,scope,limits,current);
        label.Text=title;unit.Text=suffix;IsEnabled=enabled;
        help=Loc.Format("默认值：{0}；范围：{1} 至 {2}；步进：{3}。",limits.Format(reset)+suffix,limits.Format(limits.Min)+suffix,limits.Format(limits.Max)+suffix,limits.Format(limits.Grid)+suffix);
        AutomationProperties.SetName(Slider,title);AutomationProperties.SetName(Number,title);
        AutomationProperties.SetHelpText(Number,help);AutomationProperties.SetHelpText(Slider,help);
        AutomationProperties.SetName(ResetButton,Loc.Format("重置{0}",title));ResetButton.ToolTip=Loc.Format("重置{0}",title);
        label.ToolTip=help+"\n"+Loc.Text("双击名称或轨道恢复默认值。");Slider.ToolTip=label.ToolTip;
        Slider.NumericRange=limits;Slider.ActualValue=current;Slider.DefaultValue=reset;
        Slider.SmallChange=limits.Grid/(limits.Max-limits.Min);Slider.LargeChange=limits.Wheel/(limits.Max-limits.Min);
        syncing=true;Slider.Value=range.Position(value);syncing=false;
        if(rebound || !input.Dirty)RestoreText();
        UpdateModified();LayoutRow();
    }
    public void CancelInput(){input.Cancel();RestoreText();wheel.Reset();}
    public void RestoreText()
    {
        input.Cancel();syncing=true;Number.Text=input.Text;syncing=false;
        Number.ClearValue(ToolTipProperty);AutomationProperties.SetHelpText(Number,help);error.Text="";error.Visibility=Visibility.Collapsed;
    }
    public bool Commit()
    {
        if(!IsEnabled || Number.IsReadOnly)return !HasInvalidInput;
        if(input.Commit() is {} next){Publish(next,false);return true;}
        if(input.Error==NumericInputError.None){RestoreText();return true;}
        var message=input.Error==NumericInputError.Grid ? Loc.Format("请使用 {0} 的步进。",range.Format(range.Grid)) : Loc.Text("请输入有效数字");
        error.Text=message+" "+help;error.Visibility=Visibility.Visible;Number.ToolTip=error.Text;
        AutomationProperties.SetHelpText(Number,error.Text);InvalidInput?.Invoke();return false;
    }
    private void ResetValue(){if(IsEnabled){CancelInput();Publish(defaultValue,false);}}
    private void UpdateModified()
    {
        var modified=value!=defaultValue;Number.SetResourceReference(TextBox.ForegroundProperty,modified ? "Indicator" : "Foreground");
        label.Text=title+(modified ? " •" : "");
        AutomationProperties.SetItemStatus(Number,Loc.Text(modified ? "已调整" : "未调整"));
        AutomationProperties.SetItemStatus(Slider,Loc.Text(modified ? "已调整" : "未调整"));
    }
    private void Publish(double next,bool interactive)
    {
        var changed=value!=next;if(interactive && changed)dragChanged=true;value=next;input.Bind(source,scope,range,value);RestoreText();
        Slider.ActualValue=value;Slider.DefaultValue=defaultValue;syncing=true;Slider.Value=range.Position(value);syncing=false;
        UpdateModified();if(changed)Changed?.Invoke(value,interactive);
    }
}
