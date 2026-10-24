using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;

namespace RawLab.Windows;

public sealed partial class HslPanel
{
    private readonly ToggleButton targetToggle=new();
    private readonly ComboBox targetAxisPicker=new(){MinWidth=100,Margin=new(8,0,0,0)};
    private readonly TextBlock targetStatus=new(){TextWrapping=TextWrapping.Wrap,Margin=new(0,6,0,10)};
    private bool targetSyncing,targetWaiting;
    private HslTargetSample? targetSample;
    private HslTargetAvailability? targetNotice;
    internal bool TargetEnabled { get; private set; }
    internal int TargetAxis { get; private set; }
    internal event Action? TargetInputCancelled;
    internal event Action<bool,int>? TargetChanged;
    private void InitializeTargetControls()
    {
        var bar=new StackPanel{Orientation=Orientation.Horizontal};
        bar.Children.Add(targetToggle);bar.Children.Add(targetAxisPicker);Children.Add(bar);Children.Add(targetStatus);
        targetStatus.SetResourceReference(TextBlock.ForegroundProperty,"Muted");
        AutomationProperties.SetAutomationId(targetToggle,"hsl.target");
        AutomationProperties.SetAutomationId(targetAxisPicker,"hsl.target.axis");
        AutomationProperties.SetAutomationId(targetStatus,"hsl.target.status");
        targetToggle.Click+=(_,_)=>{if(!targetSyncing)TargetChanged?.Invoke(targetToggle.IsChecked==true,TargetAxis);};
        targetAxisPicker.SelectionChanged+=(_,_)=>{if(!targetSyncing && targetAxisPicker.SelectedIndex>=0)TargetChanged?.Invoke(TargetEnabled,targetAxisPicker.SelectedIndex);};
    }
    internal void SetTarget(bool enabled,int axis,bool waiting,HslTargetSample? sample,HslTargetAvailability? notice)
    {
        TargetEnabled=enabled;TargetAxis=axis;targetWaiting=waiting;targetSample=sample;targetNotice=notice;RefreshTargetControls();
    }
    private void RefreshTargetControls()
    {
        targetSyncing=true;
        targetToggle.Content=Loc.Text("目标调整");targetToggle.IsChecked=TargetEnabled;
        AutomationProperties.SetName(targetToggle,Loc.Text("目标调整"));
        AutomationProperties.SetName(targetAxisPicker,Loc.Text("调整轴"));
        targetAxisPicker.ItemsSource=axisKeys.Select(Loc.Text).ToArray();targetAxisPicker.SelectedIndex=TargetAxis;
        targetAxisPicker.Visibility=targetStatus.Visibility=TargetEnabled ? Visibility.Visible : Visibility.Collapsed;
        var key=(targetNotice ?? targetSample?.Availability) switch {
            HslTargetAvailability.NearGray=>"颜色接近灰色，无法选择色域。",
            HslTargetAvailability.Outside=>"请在调整后的照片区域取色。",
            HslTargetAvailability.Stale=>"预览已变化，请重新取色。",
            HslTargetAvailability.Nonfinite=>"此像素不可取样。",
            HslTargetAvailability.Failed=>"取色失败，请重试。",
            _=>"上下拖动调整，方向键微调，Esc 取消"
        };
        targetStatus.Text=targetWaiting ? Loc.Text("正在取色…") : targetNotice==null && targetSample?.Usable==true
            ? Loc.Format("受影响色域：{0}",string.Join(" · ",targetSample.Channels.Select(i=>Loc.Text(colorKeys[i])))) : Loc.Text(key);
        targetSyncing=false;
    }
}
