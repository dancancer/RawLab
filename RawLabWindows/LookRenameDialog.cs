using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;

namespace RawLab.Windows;

internal sealed class LookRenameDialog : Window
{
    private readonly TextBox name;
    internal string LookName => name.Text.Trim();
    internal LookRenameDialog(Window owner, string current)
    {
        var root=AdjustmentDialogLayout.Configure(this,owner,"重命名外观","look.rename");
        Width=440;MinWidth=360;Height=220;MinHeight=220;
        root.Children.Add(AdjustmentDialogLayout.Text(Loc.Text("外观名称")));
        name=new TextBox{Text=current,MinHeight=32,VerticalAlignment=VerticalAlignment.Top};
        AutomationProperties.SetName(name,Loc.Text("外观名称"));AutomationProperties.SetAutomationId(name,"look.rename.name");
        Grid.SetRow(name,1);root.Children.Add(name);
        var actions=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right};
        var cancel=AdjustmentDialogLayout.Button("取消","look.rename.cancel",Close);cancel.IsCancel=true;actions.Children.Add(cancel);
        var save=AdjustmentDialogLayout.Button("保存","look.rename.save",()=>DialogResult=true);save.IsDefault=true;actions.Children.Add(save);
        Grid.SetRow(actions,2);root.Children.Add(actions);
        void Update()=>save.IsEnabled=LookName.Length>0 && !LookName.Any(char.IsControl);
        name.TextChanged+=(_,_)=>Update();Loaded+=(_,_)=>{name.Focus();name.SelectAll();};Update();
    }
}
