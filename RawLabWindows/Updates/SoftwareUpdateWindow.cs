using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

public sealed class SoftwareUpdateWindow : Window
{
    private readonly DesktopUpdateController updates;
    private readonly UpdateChecker legacy;
    private readonly bool settings;
    private readonly StackPanel panel = new() { Margin = new Thickness(24) };
    private bool refreshing;

    public SoftwareUpdateWindow(DesktopUpdateController updates, UpdateChecker legacy, bool settings = true)
    {
        this.updates=updates;this.legacy=legacy;this.settings=settings;
        Style=(Style)FindResource(typeof(Window));Width=600;Height=640;MinWidth=420;MinHeight=320;
        WindowStartupLocation=WindowStartupLocation.CenterOwner;
        Content=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
        AutomationProperties.SetAutomationId(this,settings ? "updates.settings" : "updates.prompt");
        updates.PropertyChanged+=Changed;legacy.PropertyChanged+=Changed;Loc.Changed+=Refresh;
        Closed+=(_,_)=>{updates.PropertyChanged-=Changed;legacy.PropertyChanged-=Changed;Loc.Changed-=Refresh;};
        Closing+=(_,args)=>{if(updates.Recovering)args.Cancel=true;};
        Refresh();
    }
    private void Changed(object? sender,PropertyChangedEventArgs args) => Refresh();
    private void Refresh()
    {
        if(refreshing)return;refreshing=true;
        try {
            Title=Loc.Text(settings ? "软件更新" : "RawLab 更新");panel.Children.Clear();
            AddText(Title,true);AddText(Loc.Format("版本 {0}",updates.CurrentVersion),localized:true);
            if(settings) {
                Toggle("自动检查更新",updates.Preferences.AutomaticCheck,updates.StorageError==null && !updates.RequiresRecovery && !updates.RequiresStartupHealthCheck,value=>{
                    updates.SetAutomaticCheck(value);legacy.Automatic=updates.Preferences.AutomaticCheck;
                },"updates.automaticCheck");
                Toggle("自动下载并在退出时安装",updates.Preferences.AutomaticInstall,updates.UnavailableReason==null && !updates.RequiresRecovery && !updates.RequiresStartupHealthCheck,updates.SetAutomaticInstall,"updates.automaticInstall");
                AddText("自动安装默认关闭。安装前会保存已提交的编辑，并等待草稿和任务处理完成。");
                panel.Children.Add(new Separator{Margin=new Thickness(0,10,0,10)});
            }
            if(updates.UnavailableReason!=null){AddText("此安装暂不支持自动安装更新",true);AddText(legacy.Status,localized:true);}
            else AddText(UpdatePresentation.Phase(updates.State.Phase),true);
            var version=updates.State.Release?.Version ?? (updates.UnavailableReason!=null ? legacy.Available?.Version : null);
            if(version!=null)AddText(Loc.Format("发现新版本 {0}",version),true,true);
            var notes=updates.State.Release?.Notes ?? (updates.UnavailableReason!=null ? legacy.Available?.Notes : null);
            if(!string.IsNullOrEmpty(notes))AddText(notes,localized:true);
            if(updates.State.Phase is UpdatePhase.Checking or UpdatePhase.Downloading or UpdatePhase.Verifying || updates.PreparingInstallation) {
                var progress=new ProgressBar{Minimum=0,Maximum=100,Value=updates.State.Progress*100,Height=10,Margin=new Thickness(0,12,0,8),IsIndeterminate=updates.State.Phase!=UpdatePhase.Downloading};
                AutomationProperties.SetName(progress,Loc.Text(UpdatePresentation.Phase(updates.State.Phase)));panel.Children.Add(progress);
                if(updates.State.Phase==UpdatePhase.Downloading)AddText($"{updates.State.Progress:P0}",localized:true);
            }
            if(updates.State.Failure is {} failure) {
                AddText("更新未完成，请查看恢复说明",true);AddText(UpdatePresentation.Phase(failure.Stage));
                panel.Children.Add(Disclosure("错误详情",Text(failure.Code+"\n"+failure.Detail)));
            }
            if(updates.StorageError!=null) {
                AddText(updates.StorageError,localized:true);
                AddText(updates.CanRepairState ? "保留损坏文件并重建更新设置。重启后会检查数据，自动更新保持关闭。" : "无法确认更新或恢复状态，请保留全部文件并联系支持。");
                if(updates.CanRepairState) {
                    var repairActions=new WrapPanel();panel.Children.Add(repairActions);
                    ActionButton(repairActions,"重建更新设置",()=>{updates.RepairState();return Task.CompletedTask;},"updates.repairState");
                }
            }
            if(updates.Preferences.StateRepairReceipt!=null) {
                AddText(updates.RecoveryNeedsRestart ? "更新设置已重建，请退出并重新打开应用" : "数据检查未通过，编辑暂未开放。请保留文件并联系支持。");
                if(updates.RecoveryError!=null)AddText(updates.RecoveryError,localized:true);
            } else if(updates.RequiresRecovery) {
                AddText(updates.RecoveryNeedsRestart ? "数据已恢复，请退出并重新打开应用" : "请先安装更新前的同一可信版本，再恢复数据。当前数据会另存保留；恢复后需退出并重新打开应用。");
                if(updates.Recovering)AddText("正在恢复更新前的数据…");
                if(updates.RecoveryError!=null)AddText(updates.RecoveryError,localized:true);
                if(updates.CanRestorePreviousData) {
                    var recoveryActions=new WrapPanel();panel.Children.Add(recoveryActions);
                    ActionButton(recoveryActions,"恢复更新前的数据",updates.RestorePreviousDataAsync,"updates.restore");
                }
            }
            foreach(var reason in updates.State.Blockers)AddText(UpdatePresentation.Blocker(reason));
            if(updates.State.Choice is UpdateInstallChoice.OnQuit or UpdateInstallChoice.AutomaticOnQuit)AddText("将在下次正常退出时重新检查并安装");
            var actions=new WrapPanel{Margin=new Thickness(0,12,0,12)};panel.Children.Add(actions);
            ActionButton(actions,"检查更新",async()=>{if(updates.UnavailableReason!=null)await legacy.CheckAsync(true);else await updates.CheckAsync(true);},"updates.check",!updates.RequiresRecovery && legacy.CanCheck && (updates.UnavailableReason!=null || updates.CanCheck));
            if(updates.CanDownload) {
                ActionButton(actions,"安装更新",()=>updates.DownloadAsync(),"updates.download");
                ActionButton(actions,"跳过此版本",()=>{updates.Skip();if(updates.StorageError==null)Close();return Task.CompletedTask;});
                ActionButton(actions,"稍后提醒",()=>{updates.RemindLater();if(updates.StorageError==null)Close();return Task.CompletedTask;});
            }
            if(updates.CanChooseInstall) {
                ActionButton(actions,"立即重启安装",()=>updates.ChooseAsync(UpdateInstallChoice.RestartNow),"updates.restart");
                ActionButton(actions,"任务结束后安装",()=>updates.ChooseAsync(UpdateInstallChoice.AfterTasks),"updates.afterTasks");
                ActionButton(actions,"下次退出时安装",()=>updates.ChooseAsync(UpdateInstallChoice.OnQuit),"updates.onQuit");
            }
            if(updates.CanCancel)ActionButton(actions,"取消更新",()=>{updates.Cancel();return Task.CompletedTask;},"updates.cancel");
            if(updates.State.Phase==UpdatePhase.Failed && updates.CanCheck)ActionButton(actions,"重试",updates.RetryAsync,"updates.retry");
            var support=new StackPanel();
            support.Children.Add(Text(Loc.Text("Mac 需要同架构、已签名并公证的应用。Windows 需要 x64 当前用户 Setup 安装版。旧 ZIP 请先从官方发布页迁移到支持更新的版本。")));
            support.Children.Add(Text(Loc.Text("查看此说明不会启用自动安装。失败后请保留现有应用和数据，使用官方可信安装包恢复；不要用旧版覆盖新版编辑记录。")));
            var disclosure=Disclosure("安装支持与恢复说明",support);disclosure.Margin=new Thickness(0,8,0,12);panel.Children.Add(disclosure);
            var links=new WrapPanel();panel.Children.Add(links);
            ActionButton(links,"官方手动下载",()=>{Open(new(UpdateRelease.Repository+"/releases"){UseShellExecute=true});return Task.CompletedTask;});
            if(updates.State.BackupPath is {} path && Directory.Exists(path))ActionButton(links,"查看更新前的数据备份",()=>{
                var start=new ProcessStartInfo("explorer.exe");start.ArgumentList.Add(path);Open(start);return Task.CompletedTask;
            });
            if(updates.Preferences.RecoveryReceipt is {} receipt && Directory.Exists(receipt))ActionButton(links,"查看恢复时保留的数据",()=>{
                var start=new ProcessStartInfo("explorer.exe");start.ArgumentList.Add(receipt);Open(start);return Task.CompletedTask;
            });
            if(updates.StateArchive is {} archive)ActionButton(links,"查看保留的更新状态文件",()=>{
                var start=new ProcessStartInfo("explorer.exe");start.ArgumentList.Add(Path.GetDirectoryName(archive)!);Open(start);return Task.CompletedTask;
            });
        } finally {refreshing=false;}
    }
    private static TextBlock Text(string value)=>new(){Text=value,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,4,0,6)};
    private static Expander Disclosure(string title,object content)
    {
        var header=Text(Loc.Text(title));var expander=new Expander{Header=header,Content=content};
        // 默认 Expander 按单行测量 Header；约束可用宽度，避免大字号下长译文被截断。
        expander.SizeChanged+=(_,_)=>header.MaxWidth=Math.Max(100,expander.ActualWidth-32);
        return expander;
    }
    private void AddText(string value,bool heading=false,bool localized=false)
    {
        var text=Text(localized ? value : Loc.Text(value));if(heading)text.FontWeight=FontWeights.SemiBold;panel.Children.Add(text);
    }
    private void Toggle(string title,bool value,bool enabled,Action<bool> changed,string identifier)
    {
        var toggle=new CheckBox{Content=Text(Loc.Text(title)),IsChecked=value,IsEnabled=enabled,Margin=new Thickness(0,6,0,6)};
        AutomationProperties.SetAutomationId(toggle,identifier);AutomationProperties.SetName(toggle,Loc.Text(title));
        toggle.Checked+=(_,_)=>{if(!refreshing)changed(true);};toggle.Unchecked+=(_,_)=>{if(!refreshing)changed(false);};panel.Children.Add(toggle);
    }
    private static void ActionButton(Panel panel,string title,Func<Task> action,string? identifier=null,bool enabled=true)
    {
        var button=new Button{Content=Text(Loc.Text(title)),IsEnabled=enabled,Margin=new Thickness(0,3,8,3),MaxWidth=480};
        AutomationProperties.SetName(button,Loc.Text(title));if(identifier!=null)AutomationProperties.SetAutomationId(button,identifier);
        button.Click+=async(_,_)=>await action();panel.Children.Add(button);
    }
    private void Open(ProcessStartInfo start)
    {
        try{Process.Start(start);}catch(Win32Exception){MessageBox.Show(this,Loc.Text("无法打开链接，请检查默认浏览器设置。"),Title);}
    }
}

internal static class UpdatePresentation
{
    public static string Phase(UpdatePhase phase)=>phase switch {
        UpdatePhase.Idle=>"尚未发现可安装的更新",UpdatePhase.Checking=>"正在检查更新…",UpdatePhase.Available=>"有可用更新",
        UpdatePhase.Downloading=>"正在下载更新…",UpdatePhase.Verifying=>"正在校验并准备更新…",UpdatePhase.PackageReady=>"更新已校验，请选择安装时间",
        UpdatePhase.WaitingForTasks=>"正在等待编辑和任务处理完成",UpdatePhase.ReadyToInstall=>"已具备安装条件",UpdatePhase.Installing=>"正在安装更新…",
        UpdatePhase.PendingRestart=>"等待重新启动",UpdatePhase.Complete=>"更新已完成",_=>"更新失败"};
    public static string Blocker(string value)=>value switch {
        "draft"=>"请返回编辑器应用或放弃草稿和未提交输入","unsaved"=>"照片编辑尚未保存","save"=>"照片编辑保存失败，请先重试保存",
        "journal"=>"批量任务记录尚未安全保存",_=>"正在等待预览、导出或批量任务结束"};
}
