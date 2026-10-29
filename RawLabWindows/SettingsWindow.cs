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
    private readonly ComboBox aiGpu=new(){MinWidth=220,DisplayMemberPath="Label",SelectedValuePath="DeviceID"};
    private sealed record GPUChoice(string DeviceID,string DeviceName,string Label,bool Available=true)
    {
        public override string ToString()=>Label;
    }
    internal AIGpuPreference AIPreference=>aiGpu.SelectedItem is GPUChoice choice ? new(choice.DeviceID,choice.DeviceName) : new();
    public int Backend=>backend.SelectedIndex;
    public SettingsWindow(int currentBackend,Action? openSoftwareUpdates=null)
        : this(currentBackend,new AIGpuPreferenceStore(AIGpuPreferenceStore.DefaultPath).Read(),RenderEngine.GetAIDevices(),false,null,false,openSoftwareUpdates) { }
    internal SettingsWindow(int currentBackend,AIGpuPreference preference,AIDeviceInventory inventory,bool aiBusy,
        Func<Window,Task<bool>>? exportDiagnostics,bool hasReport,Action? openSoftwareUpdates=null)
    {
        Style=(Style)FindResource(typeof(Window));
        Title=Loc.Text("设置");Width=560;MinWidth=420;SizeToContent=SizeToContent.Height;
        WindowStartupLocation=WindowStartupLocation.CenterOwner;ShowInTaskbar=false;ResizeMode=ResizeMode.NoResize;
        KeyboardNavigation.SetTabNavigation(this,KeyboardNavigationMode.Cycle);
        var panel=new StackPanel{Margin=new Thickness(24)};
        language.ItemsSource=Loc.Choices.Select(c=>c.Code=="system" ? c with{NativeName=Loc.Text("跟随系统")} : c).ToArray();
        language.SelectedValue=Loc.Preference;
        backend.ItemsSource=new[]{Loc.Text("GPU 自动"),Loc.Text("仅 CPU"),Loc.Text("强制 GPU")};backend.SelectedIndex=currentBackend;
        void Row(string name,ComboBox control){panel.Children.Add(new TextBlock{Text=Loc.Text(name),Margin=new Thickness(0,8,0,6)});AutomationProperties.SetName(control,Loc.Text(name));panel.Children.Add(control);}
        Row("语言",language);Row("渲染加速",backend);
        var choices=new List<GPUChoice>{new("","",Loc.Text("自动（优先独显）"))};
        foreach(var device in inventory.Devices.GroupBy(device=>device.ID).Select(group=>group.First())) {
            var available=inventory.IsAvailable(device.ID);
            var label=device.Name+(device.DedicatedMemory>0 ? $" · {device.DedicatedMemory/(1024.0*1024*1024):0.#} GB" : "");
            if(!available)label=Loc.Format("{0}（不可用）",label);
            choices.Add(new(device.ID,device.Name,label,available));
        }
        if(!choices.Any(choice=>choice.DeviceID==preference.DeviceID))
            choices.Add(new(preference.DeviceID,preference.DeviceName,Loc.Format("{0}（不可用）",preference.DeviceName),false));
        aiGpu.ItemsSource=choices;aiGpu.SelectedValue=preference.DeviceID;aiGpu.IsEnabled=!aiBusy;
        aiGpu.ItemContainerStyle=new Style(typeof(ComboBoxItem),(Style)FindResource(typeof(ComboBoxItem)));
        aiGpu.ItemContainerStyle.Setters.Add(new Setter(IsEnabledProperty,new System.Windows.Data.Binding("Available")));
        AutomationProperties.SetAutomationId(aiGpu,"settings.aiGpu");Row("AI 降噪显卡",aiGpu);
        var hint=new TextBlock{TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,6,0,0)};
        hint.SetResourceReference(TextBlock.ForegroundProperty,"Muted");panel.Children.Add(hint);
        void RefreshHint() {
            var selected=inventory.Selected(AIPreference.DeviceID);
            hint.Text=aiBusy ? Loc.Text("AI 任务正在运行，完成后可更换显卡。") :
                !inventory.IsAvailable(AIPreference.DeviceID) ? Loc.Text("所选 AI 显卡不可用，请在设置中重新选择。") :
                Loc.Format("AI 降噪将使用：{0}",selected?.Name ?? "");
        }
        aiGpu.SelectionChanged+=(_,_)=>RefreshHint();RefreshHint();
        var export=new Button{Content=Loc.Text("导出 AI 诊断包…"),Margin=new Thickness(0,16,0,0),HorizontalAlignment=HorizontalAlignment.Left,
            IsEnabled=hasReport && exportDiagnostics!=null};
        AutomationProperties.SetAutomationId(export,"settings.exportAiDiagnostics");
        var exportStatus=new TextBlock{TextWrapping=TextWrapping.Wrap,Visibility=Visibility.Collapsed,Margin=new Thickness(0,6,0,0)};
        AutomationProperties.SetLiveSetting(exportStatus,AutomationLiveSetting.Polite);
        export.Click+=async(_,_)=>{
            export.IsEnabled=false;
            try{if(exportDiagnostics!=null && await exportDiagnostics(this)) {
                exportStatus.Text=Loc.Text("AI 诊断包已导出，可手动发送给开发者。");exportStatus.Visibility=Visibility.Visible;
            }}finally{export.IsEnabled=true;}
        };panel.Children.Add(export);panel.Children.Add(exportStatus);
        var privacy=new TextBlock{Text=Loc.Text("失败时自动保存本地诊断；导出后可手动发送，不包含照片内容。"),TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,6,0,0)};
        privacy.SetResourceReference(TextBlock.ForegroundProperty,"Muted");panel.Children.Add(privacy);
        if(openSoftwareUpdates!=null) {
            var updateButton=new Button{Content=Loc.Text("软件更新…"),Margin=new Thickness(0,16,0,0),HorizontalAlignment=HorizontalAlignment.Left};
            AutomationProperties.SetAutomationId(updateButton,"settings.softwareUpdates");
            updateButton.Click+=(_,_)=>{DialogResult=false;openSoftwareUpdates();};panel.Children.Add(updateButton);
        }
        var actions=new WrapPanel{HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,20,0,0)};
        var cancel=new Button{Content=Loc.Text("取消"),IsCancel=true};cancel.Click+=(_,_)=>DialogResult=false;
        var apply=new Button{Content=Loc.Text("应用"),IsDefault=true};
        AutomationProperties.SetAutomationId(cancel,"settings.cancel");AutomationProperties.SetAutomationId(apply,"settings.apply");
        apply.Click+=(_,_)=>{
            try{if(language.SelectedValue is string code && code!=Loc.Preference)Loc.SetPreference(code);DialogResult=true;}
            catch(Exception ex) when(ex is IOException or UnauthorizedAccessException){MessageBox.Show(this,Loc.Text("无法保存语言设置。")+"\n"+ex.Message,Title);}
        };
        actions.Children.Add(cancel);actions.Children.Add(apply);panel.Children.Add(actions);Content=panel;
        Loaded+=(_,_)=>language.Focus();
    }
}
