using System.Windows;
using System.Windows.Controls;

namespace RawLab.Windows;

public partial class DenoisePanel : UserControl
{
    private DenoiseSettings value=new();
    private bool syncing=true;
    private readonly ParameterRow[] rows=[new(),new(),new()];
    private static readonly string[] titles=["亮度降噪","色彩降噪","粗色斑抑制"];
    public event Action? ResetRequested;
    public event Action<DenoiseSettings,bool>? Changed;
    internal event Action<double,bool>? HDRChanged;
    public event Action<bool>? AIChanged;
    public event Action<double,bool>? AIStrengthChanged;
    public event Action? AICancelRequested,AIRetryRequested;
    public event Action? AIDiagnosticsRequested;
    public event Action? AIModelDownloadRequested,AIModelCancelRequested,AIModelLicenseRequested,AIModelRemoveRequested;
    public DenoisePanel()
    {
        InitializeComponent();
        System.Windows.Automation.AutomationProperties.SetAutomationId(HDRAmount.Number,"hdr.denoise.value");
        HDRAmount.Changed += (number, dragging) => {
            if (!syncing && IsEnabled && HDRAmount.IsVisible) HDRChanged?.Invoke(number / 100, dragging);
        };
        AIStrength.Changed += (number, dragging) => {
            if (!syncing && IsEnabled && AIStrength.IsVisible) AIStrengthChanged?.Invoke(number, dragging);
        };
        for (var i = 0; i < rows.Length; i++) {
            var axis = i;
            (i == 0 ? LumaParameter : Parameters).Children.Add(rows[i]);
            rows[i].Changed += (number, dragging) => Set(axis, number, dragging);
        }
        Refresh(value);
    }
    public void Refresh(DenoiseSettings settings, double? hdrStrength = null)
    {
        syncing=true;value=settings;
        HDRAmount.Visibility=hdrStrength.HasValue ? Visibility.Visible : Visibility.Collapsed;
        OrdinaryDenoise.Visibility=hdrStrength.HasValue ? Visibility.Collapsed : Visibility.Visible;
        if (hdrStrength is { } strength) {
            AISurface.Visibility=Visibility.Collapsed;
            HDRAmount.Refresh(Loc.Text("降噪"),new(0,100),strength*100,0,"%",true);
            syncing=false;
            return;
        }
        EnabledBox.IsChecked=value.Enabled;PresetBox.SelectedIndex=value.Preset;
        var numbers=new[]{value.Luma,value.Chroma,value.Coarse};var defaults=new[]{0.0,46,50};
        for(var i=0;i<rows.Length;++i)rows[i].Refresh(Loc.Text(titles[i]),new(0,100),numbers[i],defaults[i],"",value.Enabled);
        syncing=false;
    }
    private void Publish(DenoiseSettings next,bool interactive=false)
    {
        if(syncing || !IsEnabled || OrdinaryDenoise.Visibility!=Visibility.Visible || !OrdinaryDenoise.IsEnabled)return;
        Refresh(next);Changed?.Invoke(value,interactive);
    }
    private void EnabledChanged(object sender,RoutedEventArgs e)=>Publish(value with {Enabled=EnabledBox.IsChecked==true});
    private void PresetChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!syncing && PresetBox.SelectedIndex is 0 or 1)Publish((PresetBox.SelectedIndex==0 ? DenoiseSettings.Detail : DenoiseSettings.Clean) with {Enabled=value.Enabled});
    }
    private void ResetClicked(object sender,RoutedEventArgs e){if(!syncing && IsEnabled)ResetRequested?.Invoke();}
    private void Set(int axis,double number,bool interactive)=>Publish(axis switch {
        0=>value with {Luma=number},1=>value with {Chroma=number},_=>value with {Coarse=number}},interactive);
    internal void RefreshAI(bool visible,bool enabled,bool canStart,AIDenoiseState state,string? unavailableHint=null,bool cpuPreview=false,double aiStrength=100.0,
        AIModelPackageState? modelState=null,bool canDownloadModel=true,bool canRemoveModel=true)
    {
        syncing=true;
        AISurface.Visibility=visible ? Visibility.Visible : Visibility.Collapsed;
        var modelVisible=RefreshAIModel(modelState,canDownloadModel,canRemoveModel);
        var suppressIdleUnavailable=modelVisible && modelState is { IsInstalled: false };
        AIEnabledBox.IsChecked=enabled || state.IsRunning;AIEnabledBox.IsEnabled=enabled || state.IsRunning || canStart;
        AICancel.Visibility=state.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        AIRetry.Visibility=state.Status is AIDenoiseStatus.Failed or AIDenoiseStatus.Cancelled ? Visibility.Visible : Visibility.Collapsed;
        AIRetry.IsEnabled=canStart;
        AIExportDiagnostics.Visibility=state.Status==AIDenoiseStatus.Failed && state.DiagnosticPath!=null ? Visibility.Visible : Visibility.Collapsed;
        AIProgress.Visibility=state.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        AIProgress.IsIndeterminate=state.Total==0;AIProgress.Value=state.Total==0 ? 0 : Math.Clamp((double)state.Done/state.Total,0,1);
        AIStrength.Visibility=(visible && (enabled || state.IsRunning)) ? Visibility.Visible : Visibility.Collapsed;
        AIStrength.Refresh(Loc.Text("AI 降噪强度"),new(0,100),aiStrength,100,"%",IsEnabled);
        OrdinaryDenoise.IsEnabled=!enabled && !state.IsRunning;
        AIStatus.SetResourceReference(TextBlock.ForegroundProperty,state.Status==AIDenoiseStatus.Failed ? "ErrorForeground" : "Muted");
        AIStatus.Text=state.Status switch {
            AIDenoiseStatus.Running=>Loc.Format("{0} · {1}/{2}",Loc.Text(state.Phase switch {
                2=>"正在处理 RAW 噪声",3=>"正在处理颜色噪声",4=>"正在保存 AI 结果",_=>"正在准备 AI 降噪"}),state.Done,state.Total),
            AIDenoiseStatus.Ready when enabled=>Loc.Text("已应用 AI 降噪；曝光和外观调整复用结果。"),
            AIDenoiseStatus.Cancelled=>Loc.Text("AI 降噪已取消。"),
            AIDenoiseStatus.Failed=>state.Error ?? Loc.Text("AI 降噪失败"),
            _=>unavailableHint ?? (canStart ? Loc.Text("支持多种 RAW 格式。首次处理时间取决于设备，完成后可复用结果。") :
                suppressIdleUnavailable ? "" : Loc.Text("此照片或构建尚不能使用 AI 降噪。"))
        };
        if(cpuPreview)AIStatus.Text=(AIStatus.Text.Length>0 ? AIStatus.Text+"\n" : "")+Loc.Text("普通显影使用 CPU；AI 降噪仍使用硬件 GPU。");
        if(state.Status==AIDenoiseStatus.Failed && state.DiagnosticSaveFailed)AIStatus.Text+="\n"+Loc.Text("无法保存诊断包，请检查磁盘空间和写入权限。");
        if(enabled && OrdinaryDenoise.Visibility==Visibility.Visible)
            AIStatus.Text=(AIStatus.Text.Length>0 ? AIStatus.Text+"\n" : "")+Loc.Text("普通降噪参数已保留，关闭 AI 降噪即可恢复。");
        AIStatus.Visibility=AIStatus.Text.Length>0 ? Visibility.Visible : Visibility.Collapsed;
        syncing=false;
    }
    private bool RefreshAIModel(AIModelPackageState? modelState,bool canDownload,bool canRemove)
    {
        AIModelProgress.Visibility=Visibility.Collapsed;
        AIModelStatus.Visibility=Visibility.Collapsed;
        AIModelNotice.Visibility=Visibility.Collapsed;
        AIModelDownload.Visibility=Visibility.Collapsed;
        AIModelRetry.Visibility=Visibility.Collapsed;
        AIModelCancel.Visibility=Visibility.Collapsed;
        AIModelLicense.Visibility=Visibility.Collapsed;
        AIModelRemove.Visibility=Visibility.Collapsed;
        AIModelStatus.SetResourceReference(TextBlock.ForegroundProperty,"Muted");

        if(modelState==null || modelState.Status==AIModelPackageStatus.Unavailable ||
            (modelState.Status==AIModelPackageStatus.Installed && !modelState.IsDownloadedInstalled)) {
            AIModelSection.Visibility=Visibility.Collapsed;
            return false;
        }

        AIModelSection.Visibility=Visibility.Visible;
        switch(modelState.Status) {
            case AIModelPackageStatus.NotInstalled:
                AIModelStatus.Text=Loc.Format("尚未下载 AI 降噪模型（约 {0} MB）。",AIModelPackageException.FormatMegabytes(modelState.DownloadBytes));
                AIModelStatus.Visibility=Visibility.Visible;
                AIModelNotice.Visibility=Visibility.Visible;
                AIModelDownload.Visibility=Visibility.Visible;
                AIModelDownload.IsEnabled=canDownload;
                AIModelLicense.Visibility=Visibility.Visible;
                break;
            case AIModelPackageStatus.Downloading:
                AIModelProgress.Visibility=Visibility.Visible;
                AIModelProgress.IsIndeterminate=modelState.DownloadBytes==0;
                AIModelProgress.Value=modelState.DownloadBytes==0 ? 0 : Math.Clamp((double)modelState.CompletedBytes/modelState.DownloadBytes,0,1);
                AIModelStatus.Text=modelState.DownloadBytes>0
                    ? Loc.Format("正在下载 AI 降噪模型… {0} / {1} MB",
                        AIModelPackageException.FormatProgressMegabytes(modelState.CompletedBytes),
                        AIModelPackageException.FormatMegabytes(modelState.DownloadBytes))
                    : Loc.Text("正在下载 AI 降噪模型…");
                AIModelStatus.Visibility=Visibility.Visible;
                AIModelCancel.Visibility=Visibility.Visible;
                AIModelCancel.IsEnabled=true;
                break;
            case AIModelPackageStatus.Verifying:
                AIModelProgress.Visibility=Visibility.Visible;
                AIModelProgress.IsIndeterminate=true;
                AIModelStatus.Text=Loc.Text("正在校验 AI 降噪模型…");
                AIModelStatus.Visibility=Visibility.Visible;
                AIModelCancel.Visibility=Visibility.Visible;
                AIModelCancel.IsEnabled=true;
                break;
            case AIModelPackageStatus.Installing:
                AIModelProgress.Visibility=Visibility.Visible;
                AIModelProgress.IsIndeterminate=true;
                AIModelStatus.Text=Loc.Text("正在安装 AI 降噪模型…");
                AIModelStatus.Visibility=Visibility.Visible;
                AIModelCancel.Visibility=Visibility.Visible;
                AIModelCancel.IsEnabled=true;
                break;
            case AIModelPackageStatus.Cancelled:
                AIModelStatus.Text=Loc.Text("已取消下载 AI 降噪模型。")+"\n"+
                    Loc.Format("尚未下载 AI 降噪模型（约 {0} MB）。",AIModelPackageException.FormatMegabytes(modelState.DownloadBytes));
                AIModelStatus.Visibility=Visibility.Visible;
                AIModelNotice.Visibility=Visibility.Visible;
                AIModelDownload.Visibility=Visibility.Visible;
                AIModelDownload.IsEnabled=canDownload;
                AIModelLicense.Visibility=Visibility.Visible;
                break;
            case AIModelPackageStatus.Failed:
                AIModelStatus.SetResourceReference(TextBlock.ForegroundProperty,"ErrorForeground");
                AIModelStatus.Text=modelState.Error?.LocalizedMessage ?? Loc.Text("下载或安装模型失败，请重试。");
                AIModelStatus.Visibility=Visibility.Visible;
                AIModelNotice.Visibility=Visibility.Visible;
                AIModelRetry.Visibility=Visibility.Visible;
                AIModelRetry.IsEnabled=canDownload;
                AIModelLicense.Visibility=Visibility.Visible;
                break;
            case AIModelPackageStatus.Installed:
                if(modelState.Error!=null) {
                    AIModelStatus.SetResourceReference(TextBlock.ForegroundProperty,"ErrorForeground");
                    AIModelStatus.Text=modelState.Error.LocalizedMessage+"\n"+
                        Loc.Format("已下载 AI 降噪模型（约 {0} MB）。",AIModelPackageException.FormatMegabytes(modelState.UnpackedBytes));
                } else {
                    AIModelStatus.Text=Loc.Format("已下载 AI 降噪模型（约 {0} MB）。",AIModelPackageException.FormatMegabytes(modelState.UnpackedBytes));
                }
                AIModelStatus.Visibility=Visibility.Visible;
                AIModelLicense.Visibility=Visibility.Visible;
                AIModelRemove.Visibility=Visibility.Visible;
                AIModelRemove.IsEnabled=canRemove;
                break;
        }
        return true;
    }
    private void AIEnabledChanged(object sender,RoutedEventArgs e) { if(!syncing)AIChanged?.Invoke(AIEnabledBox.IsChecked==true); }
    private void AICancelClicked(object sender,RoutedEventArgs e)=>AICancelRequested?.Invoke();
    private void AIRetryClicked(object sender,RoutedEventArgs e)=>AIRetryRequested?.Invoke();
    private void AIExportDiagnosticsClicked(object sender,RoutedEventArgs e)=>AIDiagnosticsRequested?.Invoke();
    private void AIModelDownloadClicked(object sender,RoutedEventArgs e)=>AIModelDownloadRequested?.Invoke();
    private void AIModelCancelClicked(object sender,RoutedEventArgs e)=>AIModelCancelRequested?.Invoke();
    private void AIModelLicenseClicked(object sender,RoutedEventArgs e)=>AIModelLicenseRequested?.Invoke();
    private void AIModelRemoveClicked(object sender,RoutedEventArgs e)=>AIModelRemoveRequested?.Invoke();
}
