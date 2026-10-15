using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace RawLab.Windows;

public sealed class SettingsWindow : Window
{
    private readonly ComboBox language=new(){MinWidth=220,DisplayMemberPath="NativeName",SelectedValuePath="Code"};
    private readonly ComboBox backend=new(){MinWidth=220};
    public int Backend=>backend.SelectedIndex;
    public SettingsWindow(int currentBackend)
    {
        Title=Loc.Text("设置");Width=520;MinWidth=420;SizeToContent=SizeToContent.Height;
        WindowStartupLocation=WindowStartupLocation.CenterOwner;ShowInTaskbar=false;ResizeMode=ResizeMode.NoResize;
        KeyboardNavigation.SetTabNavigation(this,KeyboardNavigationMode.Cycle);
        var panel=new StackPanel{Margin=new Thickness(24)};
        language.ItemsSource=Loc.Choices.Select(c=>c.Code=="system" ? c with{NativeName=Loc.Text("跟随系统")} : c).ToArray();
        language.SelectedValue=Loc.Preference;
        backend.ItemsSource=new[]{Loc.Text("GPU 自动"),Loc.Text("仅 CPU"),Loc.Text("强制 GPU")};backend.SelectedIndex=currentBackend;
        void Row(string name,ComboBox control){panel.Children.Add(new TextBlock{Text=Loc.Text(name),Margin=new Thickness(0,8,0,6)});AutomationProperties.SetName(control,Loc.Text(name));panel.Children.Add(control);}
        Row("语言",language);Row("渲染加速",backend);
        var actions=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,20,0,0)};
        var cancel=new Button{Content=Loc.Text("取消"),IsCancel=true};cancel.Click+=(_,_)=>DialogResult=false;
        var apply=new Button{Content=Loc.Text("应用"),IsDefault=true};
        apply.Click+=(_,_)=>{
            try{if(language.SelectedValue is string code && code!=Loc.Preference)Loc.SetPreference(code);DialogResult=true;}
            catch(Exception ex) when(ex is IOException or UnauthorizedAccessException){MessageBox.Show(this,Loc.Text("无法保存语言设置。")+"\n"+ex.Message,Title);}
        };
        actions.Children.Add(cancel);actions.Children.Add(apply);panel.Children.Add(actions);Content=panel;
        Loaded+=(_,_)=>language.Focus();
    }
}
