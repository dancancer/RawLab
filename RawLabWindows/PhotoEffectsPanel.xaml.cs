using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;

namespace RawLab.Windows;
public enum PhotoEffectTool { Vignette, Grain }
public partial class PhotoEffectsPanel : UserControl
{
    private PhotoEffectsSettings value=new();
    private FilmOpticsSettings filmOptics=new();
    private PhotoEffectTool tool;
    private bool hdrEditing;
    private bool syncing;
    private readonly Dictionary<PhotoEffectParameter,ParameterRow> rows=[];
    private readonly ParameterRow[] halationRows=[new(),new(),new(),new()];
    private readonly ParameterRow[] bloomRows=[new(),new(),new()];
    internal IReadOnlyDictionary<PhotoEffectParameter,ParameterRow> Rows => rows;
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
    private sealed record OpticsSpec(string Title,string Name,double Min,double Max,double DefaultValue,Func<FilmOpticsSettings,double> Get,Func<FilmOpticsSettings,double,FilmOpticsSettings> With);
    private static readonly OpticsSpec[] halationSpecs=[
        new("强度","光晕",0,100,0,s=>s.HalationAmount,(s,v)=>s with { HalationAmount=v }),
        new("阈值","光晕阈值",0,100,75,s=>s.HalationThreshold,(s,v)=>s with { HalationThreshold=v }),
        new("半径","光晕半径",0,100,35,s=>s.HalationRadius,(s,v)=>s with { HalationRadius=v }),
        new("色相","光晕色相",-100,100,0,s=>s.HalationHue,(s,v)=>s with { HalationHue=v })];
    private static readonly OpticsSpec[] bloomSpecs=[
        new("强度","柔光",0,100,0,s=>s.BloomAmount,(s,v)=>s with { BloomAmount=v }),
        new("阈值","柔光阈值",0,100,70,s=>s.BloomThreshold,(s,v)=>s with { BloomThreshold=v }),
        new("半径","柔光半径",0,100,40,s=>s.BloomRadius,(s,v)=>s with { BloomRadius=v })];
    public event Action<PhotoEffectsSettings,bool>? Changed;
    public event Action<FilmOpticsSettings,bool>? FilmOpticsChanged;
    public event Action? ResetRequested;
    public PhotoEffectsPanel()
    {
        InitializeComponent();
        foreach(var spec in PhotoEffectSpec.All)
        {
            var row=new ParameterRow();rows[spec.Id]=row;
            AutomationProperties.SetAutomationId(row.Slider,spec.Id.ToString());
            (spec.Id==PhotoEffectParameter.VignetteAmount ? VignetteParameters : spec.IsVignette ? VignetteFineParameters : GrainRows).Children.Add(row);
            row.Changed+=(number,dragging)=>{
                if(syncing || !IsEnabled)return;
                var next=new Adjustments{Effects=value};
                if(spec.IsVignette) next.SetEffect(spec.Id,number);
                else next.SetGrainEffect(spec.Id,number);
                Publish(next.Effects,dragging);
            };
        }
        for(var i=0;i<halationSpecs.Length;++i)
        {
            var idx=i;var row=halationRows[idx];
            HalationParameters.Children.Add(row);
            row.Changed+=(number,dragging)=>{
                if(syncing || !IsEnabled || hdrEditing)return;
                var spec=halationSpecs[idx];
                var q=Math.Clamp(Math.Round(number,1,MidpointRounding.AwayFromZero),spec.Min,spec.Max);
                PublishOptics(spec.With(filmOptics,q==0 ? 0 : q),dragging);
            };
        }
        for(var i=0;i<bloomSpecs.Length;++i)
        {
            var idx=i;var row=bloomRows[idx];
            BloomParameters.Children.Add(row);
            row.Changed+=(number,dragging)=>{
                if(syncing || !IsEnabled || hdrEditing)return;
                var spec=bloomSpecs[idx];
                var q=Math.Clamp(Math.Round(number,1,MidpointRounding.AwayFromZero),spec.Min,spec.Max);
                PublishOptics(spec.With(filmOptics,q==0 ? 0 : q),dragging);
            };
        }
        VignetteDetails.Expanded+=(_,_)=>RefreshResetVisibility();
        VignetteDetails.Collapsed+=(_,_)=>RefreshResetVisibility();
        HalationExpander.Expanded+=(_,_)=>RefreshResetVisibility();
        HalationExpander.Collapsed+=(_,_)=>RefreshResetVisibility();
        BloomExpander.Expanded+=(_,_)=>RefreshResetVisibility();
        BloomExpander.Collapsed+=(_,_)=>RefreshResetVisibility();
        Refresh(value,tool,filmOptics,hdrEditing);
    }
    public void Refresh(PhotoEffectsSettings settings,PhotoEffectTool selected,FilmOpticsSettings? optics=null,bool isHdrEditing=false)
    {
        syncing=true;value=settings;tool=selected;hdrEditing=isHdrEditing;
        if(optics!=null) filmOptics=optics;
        VignetteParameters.Visibility=VignetteDetails.Visibility=selected==PhotoEffectTool.Vignette ? Visibility.Visible : Visibility.Collapsed;
        GrainParameters.Visibility=selected==PhotoEffectTool.Grain ? Visibility.Visible : Visibility.Collapsed;
        GrainOptions.Visibility=FilmOpticsSurface.Visibility=(selected==PhotoEffectTool.Grain && !hdrEditing) ? Visibility.Visible : Visibility.Collapsed;
        GrainToneCurveBox.SelectedIndex=value.GrainToneCurve==GrainToneCurve.NegativeAsymmetric ? 1 : 0;
        GrainFormatPresetBox.SelectedIndex=(int)value.GrainFormatPreset;
        RefreshResetVisibility();
        foreach(var spec in PhotoEffectSpec.All)
        {
            var enabled=spec.Id switch {
                PhotoEffectParameter.VignetteHighlights=>value.VignetteAmount<0,
                PhotoEffectParameter.VignetteMidpoint or PhotoEffectParameter.VignetteRoundness or PhotoEffectParameter.VignetteFeather=>value.VignetteAmount!=0,
                PhotoEffectParameter.GrainSize or PhotoEffectParameter.GrainRoughness=>value.GrainAmount!=0,_=>true};
            var key=keys[(int)spec.Id];
            rows[spec.Id].Refresh(Loc.Text(key.Title),new(spec.Min,spec.Max),value[spec.Id],spec.DefaultValue,"",enabled);
            AutomationProperties.SetName(rows[spec.Id].Slider,Loc.Text(key.Name));
            AutomationProperties.SetName(rows[spec.Id].ResetButton,Loc.Text(key.Reset));
            AutomationProperties.SetName(rows[spec.Id].Number,Loc.Text(key.Number));
        }
        for(var i=0;i<halationSpecs.Length;++i)
        {
            var spec=halationSpecs[i];
            halationRows[i].Refresh(Loc.Text(spec.Title),new(spec.Min,spec.Max),spec.Get(filmOptics),spec.DefaultValue,"",i==0 || filmOptics.HalationAmount>0);
            AutomationProperties.SetName(halationRows[i].Slider,Loc.Text(spec.Name));
        }
        for(var i=0;i<bloomSpecs.Length;++i)
        {
            var spec=bloomSpecs[i];
            bloomRows[i].Refresh(Loc.Text(spec.Title),new(spec.Min,spec.Max),spec.Get(filmOptics),spec.DefaultValue,"",i==0 || filmOptics.BloomAmount>0);
            AutomationProperties.SetName(bloomRows[i].Slider,Loc.Text(spec.Name));
        }
        ResetHalationButton.IsEnabled=!filmOptics.IsHalationDefault;
        ResetBloomButton.IsEnabled=!filmOptics.IsBloomDefault;
        syncing=false;
    }
    // The row names come from Loc.Text inside Refresh and the panel refresh is gated on tool selection,
    // so a language switch alone leaves them stale; re-apply the current state like the sibling panels do.
    public void RefreshLanguage()=>Refresh(value,tool,filmOptics,hdrEditing);
    private void Publish(PhotoEffectsSettings next,bool dragging=false){Refresh(next,tool,filmOptics,hdrEditing);Changed?.Invoke(value,dragging);}
    private void PublishOptics(FilmOpticsSettings next,bool dragging=false){Refresh(value,tool,next,hdrEditing);FilmOpticsChanged?.Invoke(filmOptics,dragging);}
    private void GrainToneCurveChanged(object sender,SelectionChangedEventArgs e)
    {
        if(syncing || !IsEnabled || hdrEditing)return;
        var curve=GrainToneCurveBox.SelectedIndex==1 ? GrainToneCurve.NegativeAsymmetric : GrainToneCurve.Legacy;
        if(curve!=value.GrainToneCurve) Publish(value with { GrainToneCurve=curve });
    }
    private void GrainFormatPresetChanged(object sender,SelectionChangedEventArgs e)
    {
        if(syncing || !IsEnabled || hdrEditing || GrainFormatPresetBox.SelectedIndex is < 0 or > 2)return;
        var preset=(GrainFormatPreset)GrainFormatPresetBox.SelectedIndex;
        if(preset!=value.GrainFormatPreset) Publish(value.ApplyGrainFormatPreset(preset));
    }
    private void RefreshResetVisibility()
    {
        var showVignetteResets=tool==PhotoEffectTool.Grain || VignetteDetails.IsExpanded;
        ResetGroupButton.Visibility=showVignetteResets ? Visibility.Visible : Visibility.Collapsed;
        HalationParameters.Visibility=HalationExpander.IsExpanded ? Visibility.Visible : Visibility.Collapsed;
        BloomParameters.Visibility=BloomExpander.IsExpanded ? Visibility.Visible : Visibility.Collapsed;
        ResetHalationButton.Visibility=HalationExpander.IsExpanded ? Visibility.Visible : Visibility.Collapsed;
        ResetBloomButton.Visibility=BloomExpander.IsExpanded ? Visibility.Visible : Visibility.Collapsed;
    }
    private void ResetGroupClicked(object sender,RoutedEventArgs e)
    {
        if(!syncing && IsEnabled)ResetRequested?.Invoke();
    }
    private void ResetHalationClicked(object sender,RoutedEventArgs e)
    {
        if(!syncing && IsEnabled && !hdrEditing) PublishOptics(filmOptics.ResetHalation());
    }
    private void ResetBloomClicked(object sender,RoutedEventArgs e)
    {
        if(!syncing && IsEnabled && !hdrEditing) PublishOptics(filmOptics.ResetBloom());
    }
}
