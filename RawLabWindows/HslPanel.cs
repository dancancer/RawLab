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
    private readonly Button resetColor=new(),resetAll=new();
    private static readonly string[] colorKeys=["红","橙","黄","绿","青","蓝","紫","洋红"];
    private static readonly string[] axisKeys=["色相","饱和度","明度"];
    public event Action<HslSettings,bool>? Changed;
    public HslPanel()
    {
        MaxWidth=720;Margin=new Thickness(4);
        var selector=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Center};
        var colors=new[]{Colors.Red,Colors.Orange,Colors.Yellow,Colors.LimeGreen,Colors.Cyan,Colors.DodgerBlue,Colors.Purple,Colors.Magenta};
        for(var i=0;i<8;++i)
        {
            var index=i;
            var button=new Button{Width=40,Height=40,Margin=new Thickness(2),Content=new Ellipse{Width=20,Height=20,Fill=new SolidColorBrush(colors[i])}};
            button.Click+=(_,_)=>{channel=index;foreach(var row in rows)row.RestoreText();Refresh(settings);};
            swatches[i]=button;selector.Children.Add(button);
        }
        Children.Add(selector);
        for(var i=0;i<3;++i)
        {
            var axis=i;Children.Add(rows[i]);rows[i].Changed+=(value,dragging)=>{
                if(syncing || !IsEnabled)return;
                settings=settings.WithValue(axis,channel,value);Refresh(settings);Changed?.Invoke(settings,dragging);
            };
        }
        var resets=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right};
        resetColor.Click+=(_,_)=>{for(var axis=0;axis<3;++axis)settings=settings.WithValue(axis,channel,0);Refresh(settings);Changed?.Invoke(settings,false);};
        resetAll.Click+=(_,_)=>{settings=new();Refresh(settings);Changed?.Invoke(settings,false);};
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
            AutomationProperties.SetItemStatus(swatches[i],i==channel ? Loc.Text("当前颜色") : "");
        }
        syncing=false;
    }
}
