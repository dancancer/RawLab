using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;

namespace RawLab.Windows;
public enum PhotoEffectTool { Vignette, Grain }
public partial class PhotoEffectsPanel : UserControl
{
    private PhotoEffectsSettings value=new();
    private PhotoEffectTool tool;
    private bool syncing;
    private readonly Dictionary<PhotoEffectParameter,ParameterRow> rows=[];
    // ┌─ 每个参数行的完整翻译键，按 PhotoEffectParameter 顺序：行标题、读屏名、重置按钮、数值框 ─┐
    // └─ 键全部是字面量，目录检查能逐个核对；不在运行时拼接 ──────────────────────────────────┘
    private sealed record RowKeys(string Title,string Name,string Reset,string Number);
    private static readonly RowKeys[] keys=[
        new("强度","暗角强度","重置暗角强度","暗角强度数值"),
        new("中点","暗角中点","重置暗角中点","暗角中点数值"),
        new("圆度","暗角圆度","重置暗角圆度","暗角圆度数值"),
        new("羽化","暗角羽化","重置暗角羽化","暗角羽化数值"),
        new("高光保护","暗角高光保护","重置暗角高光保护","暗角高光保护数值"),
        new("强度","颗粒强度","重置颗粒强度","颗粒强度数值"),
        new("大小","颗粒大小","重置颗粒大小","颗粒大小数值"),
        new("粗糙度","颗粒粗糙度","重置颗粒粗糙度","颗粒粗糙度数值")];
    public event Action<PhotoEffectsSettings,bool>? Changed;
    public event Action? ResetRequested;
    public PhotoEffectsPanel()
    {
        InitializeComponent();
        foreach(var spec in PhotoEffectSpec.All)
        {
            var row=new ParameterRow();rows[spec.Id]=row;
            AutomationProperties.SetAutomationId(row.Slider,spec.Id.ToString());
            (spec.Id==PhotoEffectParameter.VignetteAmount ? VignetteParameters : spec.IsVignette ? VignetteFineParameters : GrainParameters).Children.Add(row);
            row.Changed+=(number,dragging)=>{if(syncing || !IsEnabled)return;var next=new Adjustments{Effects=value};next.SetEffect(spec.Id,number);Publish(next.Effects,dragging);};
        }
        VignetteDetails.Expanded+=(_,_)=>RefreshResetVisibility();
        VignetteDetails.Collapsed+=(_,_)=>RefreshResetVisibility();
        Refresh(value,tool);
    }
    public void Refresh(PhotoEffectsSettings settings,PhotoEffectTool selected)
    {
        syncing=true;value=settings;tool=selected;
        VignetteParameters.Visibility=VignetteDetails.Visibility=selected==PhotoEffectTool.Vignette ? Visibility.Visible : Visibility.Collapsed;
        GrainParameters.Visibility=selected==PhotoEffectTool.Grain ? Visibility.Visible : Visibility.Collapsed;
        RefreshResetVisibility();
        foreach(var spec in PhotoEffectSpec.All)
        {
            var enabled=spec.Id switch {
                PhotoEffectParameter.VignetteHighlights=>value.VignetteAmount<0,
                PhotoEffectParameter.VignetteMidpoint or PhotoEffectParameter.VignetteRoundness or PhotoEffectParameter.VignetteFeather=>value.VignetteAmount!=0,
                PhotoEffectParameter.GrainSize or PhotoEffectParameter.GrainRoughness=>value.GrainAmount!=0,_=>true};
            var key=keys[(int)spec.Id];
            rows[spec.Id].Refresh(Loc.Text(key.Title),new(spec.Min,spec.Max),value[spec.Id],spec.DefaultValue,"%",enabled);
            AutomationProperties.SetName(rows[spec.Id].Slider,Loc.Text(key.Name));
            AutomationProperties.SetName(rows[spec.Id].ResetButton,Loc.Text(key.Reset));
            AutomationProperties.SetName(rows[spec.Id].Number,Loc.Text(key.Number));
        }
        syncing=false;
    }
    private void Publish(PhotoEffectsSettings next,bool dragging=false){Refresh(next,tool);Changed?.Invoke(value,dragging);}
    private void RefreshResetVisibility()
    {
        var showVignetteResets=tool==PhotoEffectTool.Grain || VignetteDetails.IsExpanded;
        ResetGroupButton.Visibility=showVignetteResets ? Visibility.Visible : Visibility.Collapsed;

    }
    private void ResetGroupClicked(object sender,RoutedEventArgs e)
    {
        if(!syncing && IsEnabled)ResetRequested?.Invoke();
    }
}
