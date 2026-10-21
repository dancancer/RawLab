using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace RawLab.Windows;

public sealed class HslPanel : StackPanel
{
    private HslSettings settings=new();
    private int channel;
    private bool syncing;
    private readonly ParameterRow[] rows=[new(),new(),new()];
    private readonly Button[] swatches=new Button[8];
    private readonly Border[] markers=new Border[8];
    private readonly Button resetColor=new(),resetAll=new();
    private static readonly string[] colorKeys=["红","橙","黄","绿","青","蓝","紫","洋红"];
    private static readonly string[] axisKeys=["色相","饱和度","明度"];
    public event Action<HslSettings,bool>? Changed;
    public event Action<EditorResetScope>? ResetRequested;
    public int SelectedChannel => channel;
    public string SelectedChannelName => Loc.Text(colorKeys[channel]);
    public void SelectChannel(int value) {
        if(value is <0 or >7)throw new ArgumentOutOfRangeException(nameof(value));
        channel=value;foreach(var row in rows)row.RestoreText();Refresh(settings);
    }
    public HslPanel()
    {
        MaxWidth=720;Margin=new Thickness(4);
        var selector=new StackPanel{Orientation=Orientation.Horizontal,HorizontalAlignment=HorizontalAlignment.Center};
        var colors=new[]{Colors.Red,Colors.Orange,Colors.Yellow,Colors.LimeGreen,Colors.Cyan,Colors.DodgerBlue,Colors.Purple,Colors.Magenta};
        for(var i=0;i<8;++i)
        {
            var index=i;
            // 默认按钮内边距 12 会把 20 的色块裁成半圆：色块按钮不留内边距
            var content=new StackPanel{HorizontalAlignment=HorizontalAlignment.Center};
            content.Children.Add(new Ellipse{Width=20,Height=20,Fill=new SolidColorBrush(colors[i])});
            var marker=new Border{Width=4,Height=4,CornerRadius=new CornerRadius(2),Margin=new Thickness(0,3,0,0),Visibility=Visibility.Hidden};
            marker.SetResourceReference(Border.BackgroundProperty,"Indicator");markers[i]=marker;content.Children.Add(marker);
            var button=new Button{Width=40,Height=44,Margin=new Thickness(2),Padding=new Thickness(0),Content=content};
            button.Click+=(_,_)=>{SelectChannel(index);};
            swatches[i]=button;selector.Children.Add(button);
        }
        Children.Add(new ScrollViewer { Content=selector,HorizontalScrollBarVisibility=ScrollBarVisibility.Auto,VerticalScrollBarVisibility=ScrollBarVisibility.Disabled });
        for(var i=0;i<3;++i)
        {
            var axis=i;Children.Add(rows[i]);rows[i].Changed+=(value,dragging)=>{
                if(syncing || !IsEnabled)return;
                settings=settings.WithValue(axis,channel,value);Refresh(settings);Changed?.Invoke(settings,dragging);
            };
        }
        var resets=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right};
        resetColor.Click+=(_,_)=>ResetRequested?.Invoke(new(EditorResetKind.HslChannel,Channel:channel));
        resetAll.Click+=(_,_)=>ResetRequested?.Invoke(new(EditorResetKind.AllHsl));
        resets.Children.Add(resetColor);resets.Children.Add(resetAll);Children.Add(resets);
        RefreshLanguage();
    }
    public void RefreshLanguage()
    {
        for(var i=0;i<8;++i){swatches[i].ToolTip=Loc.Text(colorKeys[i]);AutomationProperties.SetName(swatches[i],Loc.Text(colorKeys[i]));}
        resetColor.Content=Loc.Text("重置当前颜色");resetAll.Content=Loc.Text("重置 HSL");
        Refresh(settings);
    }
    public void Refresh(HslSettings value)
    {
        syncing=true;settings=value;
        for(var axis=0;axis<3;++axis)rows[axis].Refresh(Loc.Text(axisKeys[axis]),new(-100,100),value.Value(axis,channel),0,"%");
        for(var i=0;i<8;++i){
            if(i==channel)swatches[i].SetResourceReference(Button.BorderBrushProperty,"Indicator");else swatches[i].ClearValue(Button.BorderBrushProperty);
            var modified=Enumerable.Range(0,3).Any(axis=>value.Value(axis,i)!=0);
            markers[i].Visibility=modified ? Visibility.Visible : Visibility.Hidden;
            AutomationProperties.SetHelpText(swatches[i],modified ? Loc.Text("已调整") : "");
            AutomationProperties.SetItemStatus(swatches[i],string.Join(" · ",new[]{i==channel ? Loc.Text("当前颜色") : "",modified ? Loc.Text("已调整") : ""}.Where(text=>text.Length>0)));
        }
        resetColor.Content=Loc.Format("重置当前颜色（{0}）",SelectedChannelName);
        AutomationProperties.SetName(resetColor,resetColor.Content.ToString());
        resetColor.IsEnabled=Enumerable.Range(0,3).Any(axis=>value.Value(axis,channel)!=0);
        resetAll.IsEnabled=!value.IsIdentity;
        syncing=false;
    }
}
