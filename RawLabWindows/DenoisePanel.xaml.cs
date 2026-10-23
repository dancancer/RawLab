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
    public event Action<bool>? AIChanged;
    public event Action? AICancelRequested,AIRetryRequested;
    public DenoisePanel()
    {
        InitializeComponent();
        for(var i=0;i<rows.Length;++i){var axis=i;Parameters.Children.Add(rows[i]);rows[i].Changed+=(number,dragging)=>Set(axis,number,dragging);}
        Refresh(value);
    }
    public void Refresh(DenoiseSettings settings)
    {
        syncing=true;value=settings;
        EnabledBox.IsChecked=value.Enabled;PresetBox.SelectedIndex=value.Preset;
        Summary.Text=$"{Loc.Text(titles[0])} {value.Luma:0.#} / {Loc.Text(titles[1])} {value.Chroma:0.#} / {Loc.Text(titles[2])} {value.Coarse:0.#}";
        var numbers=new[]{value.Luma,value.Chroma,value.Coarse};var defaults=new[]{0.0,46,50};
        for(var i=0;i<rows.Length;++i)rows[i].Refresh(Loc.Text(titles[i]),new(0,100),numbers[i],defaults[i],"%",value.Enabled);
        syncing=false;
    }
    private void Publish(DenoiseSettings next,bool interactive=false)
    {
        if(syncing || !IsEnabled || !OrdinaryDenoise.IsEnabled)return;
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
    internal void RefreshAI(bool visible,bool enabled,bool canStart,AIDenoiseState state)
    {
        syncing=true;
        AISurface.Visibility=visible ? Visibility.Visible : Visibility.Collapsed;
        AIEnabledBox.IsChecked=enabled || state.IsRunning;AIEnabledBox.IsEnabled=enabled || state.IsRunning || canStart;
        AICancel.Visibility=state.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        AIRetry.Visibility=state.Status is AIDenoiseStatus.Failed or AIDenoiseStatus.Cancelled ? Visibility.Visible : Visibility.Collapsed;
        AIRetry.IsEnabled=canStart;
        AIProgress.Visibility=state.IsRunning ? Visibility.Visible : Visibility.Collapsed;
        AIProgress.IsIndeterminate=state.Total==0;AIProgress.Value=state.Total==0 ? 0 : Math.Clamp((double)state.Done/state.Total,0,1);
        OrdinaryDenoise.IsEnabled=!enabled && !state.IsRunning;
        AIStatus.SetResourceReference(TextBlock.ForegroundProperty,state.Status==AIDenoiseStatus.Failed ? "ErrorForeground" : "Muted");
        AIStatus.Text=state.Status switch {
            AIDenoiseStatus.Running=>Loc.Format("{0} · {1}/{2}",Loc.Text(state.Phase switch {
                2=>"正在处理 RAW 噪声",3=>"正在处理颜色噪声",4=>"正在保存 AI 结果",_=>"正在准备 AI 降噪"}),state.Done,state.Total),
            AIDenoiseStatus.Ready when enabled=>Loc.Text("已应用 AI 降噪；曝光和外观调整复用结果。"),
            AIDenoiseStatus.Cancelled=>Loc.Text("AI 降噪已取消。"),
            AIDenoiseStatus.Failed=>state.Error ?? Loc.Text("AI 降噪失败"),
            _=>Loc.Text(canStart ? "支持多种 RAW 格式。首次处理时间取决于设备，完成后可复用结果。" : "此照片或构建尚不能使用 AI 降噪。")
        };
        if(enabled)AIStatus.Text+="\n"+Loc.Text("普通降噪参数已保留，关闭 AI 降噪即可恢复。");
        syncing=false;
    }
    private void AIEnabledChanged(object sender,RoutedEventArgs e) { if(!syncing)AIChanged?.Invoke(AIEnabledBox.IsChecked==true); }
    private void AICancelClicked(object sender,RoutedEventArgs e)=>AICancelRequested?.Invoke();
    private void AIRetryClicked(object sender,RoutedEventArgs e)=>AIRetryRequested?.Invoke();
}
