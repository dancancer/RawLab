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
    private static readonly string[] titles=["强度","中点","圆度","羽化","高光保护","强度","大小","粗糙度"];
    public event Action<PhotoEffectsSettings,bool>? Changed;
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
        Title.Text=Loc.Text(selected==PhotoEffectTool.Vignette ? "暗角" : "颗粒");
        VignetteParameters.Visibility=VignetteDetails.Visibility=selected==PhotoEffectTool.Vignette ? Visibility.Visible : Visibility.Collapsed;
        GrainParameters.Visibility=selected==PhotoEffectTool.Grain ? Visibility.Visible : Visibility.Collapsed;
        RefreshResetVisibility();
        foreach(var spec in PhotoEffectSpec.All)
        {
            var enabled=spec.Id switch {
                PhotoEffectParameter.VignetteHighlights=>value.VignetteAmount<0,
                PhotoEffectParameter.VignetteMidpoint or PhotoEffectParameter.VignetteRoundness or PhotoEffectParameter.VignetteFeather=>value.VignetteAmount!=0,
                PhotoEffectParameter.GrainSize or PhotoEffectParameter.GrainRoughness=>value.GrainAmount!=0,_=>true};
            rows[spec.Id].Refresh(Loc.Text(titles[(int)spec.Id]),new(spec.Min,spec.Max),value[spec.Id],spec.DefaultValue,"%",enabled);
            var fullName=Loc.Text((spec.IsVignette ? "暗角" : "颗粒")+titles[(int)spec.Id]);
            AutomationProperties.SetName(rows[spec.Id].Slider,fullName);
            AutomationProperties.SetName(rows[spec.Id].ResetButton,Loc.Text("重置"+(spec.IsVignette ? "暗角" : "颗粒")+titles[(int)spec.Id]));
            AutomationProperties.SetName(rows[spec.Id].Number,Loc.Text((spec.IsVignette ? "暗角" : "颗粒")+titles[(int)spec.Id]+"数值"));
        }
        syncing=false;
    }
    private void Publish(PhotoEffectsSettings next,bool dragging=false){Refresh(next,tool);Changed?.Invoke(value,dragging);}
    private void RefreshResetVisibility()
    {
        var showVignetteResets=tool==PhotoEffectTool.Grain || VignetteDetails.IsExpanded;
        ResetGroupButton.Visibility=showVignetteResets ? Visibility.Visible : Visibility.Collapsed;
        rows[PhotoEffectParameter.VignetteAmount].ResetButton.Visibility=showVignetteResets ? Visibility.Visible : Visibility.Collapsed;
    }
    private void ResetGroupClicked(object sender,RoutedEventArgs e)
    {
        var next=new Adjustments{Effects=value};next.ResetEffects(tool==PhotoEffectTool.Vignette);Publish(next.Effects);
    }
}
