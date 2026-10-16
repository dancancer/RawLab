using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace RawLab.Windows;

internal sealed class LongEdgeDialog : Window
{
    private readonly TextBox valueBox;
    private readonly TextBlock errorText;
    private int? result;

    private LongEdgeDialog(int? current, Window owner)
    {
        Style=(Style)FindResource(typeof(Window));
        Owner=owner; WindowStartupLocation=WindowStartupLocation.CenterOwner;
        Title=Loc.Text("自定义导出尺寸"); SizeToContent=SizeToContent.WidthAndHeight; MinWidth=320; ResizeMode=ResizeMode.NoResize;
        valueBox=new TextBox { Width=120, Text= current?.ToString() ?? "", Margin=new Thickness(0,0,8,0) };
        AutomationProperties.SetName(valueBox,Loc.Text("长边像素"));
        errorText=new TextBlock { Margin=new Thickness(0,8,0,0), TextWrapping=TextWrapping.Wrap };
        errorText.SetResourceReference(TextBlock.ForegroundProperty,"ErrorForeground");
        var accept=new Button { Content=Loc.Text("确定"), IsDefault=true, MinWidth=72 };
        var cancel=new Button { Content=Loc.Text("取消"), IsCancel=true, MinWidth=72, Margin=new Thickness(8,0,0,0) };
        accept.Click+=(_,_)=>Accept(); valueBox.KeyDown+=(_,args)=>{if(args.Key==Key.Enter){Accept();args.Handled=true;}};
        var buttons=new StackPanel { Orientation=Orientation.Horizontal, HorizontalAlignment=HorizontalAlignment.Right };
        buttons.Children.Add(accept); buttons.Children.Add(cancel);
        var panel=new StackPanel { Margin=new Thickness(20) };
        panel.Children.Add(new TextBlock { Text=Loc.Text("长边（1–65535 像素）") });
        var input=new StackPanel { Orientation=Orientation.Horizontal, Margin=new Thickness(0,12,0,0) };
        input.Children.Add(valueBox); input.Children.Add(new TextBlock { Text="px", VerticalAlignment=VerticalAlignment.Center });
        panel.Children.Add(input); panel.Children.Add(errorText); panel.Children.Add(buttons);
        Content=panel;
    }

    private void Accept()
    {
        if (ExportSize.Parse(valueBox.Text) is not { } edge)
        {
            errorText.Text=Loc.Text("请输入 1 到 65535 之间的整数。"); valueBox.Focus(); valueBox.SelectAll(); return;
        }
        result=edge; DialogResult=true;
    }

    internal static int? Show(Window owner, int? current)
    {
        var dialog=new LongEdgeDialog(current,owner);
        return dialog.ShowDialog() == true ? dialog.result : null;
    }
}
