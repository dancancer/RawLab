using System.Windows;
using System.Windows.Controls;

namespace RawLab.Windows;

public partial class DenoisePanel : UserControl
{
    private DenoiseSettings value=new();
    private bool syncing=true;
    private readonly ParameterRow[] rows=[new(),new(),new()];
    private static readonly string[] titles=["亮度降噪","色彩降噪","粗色斑抑制"];
    public event Action<DenoiseSettings,bool>? Changed;
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
        if(syncing || !IsEnabled)return;
        Refresh(next);Changed?.Invoke(value,interactive);
    }
    private void EnabledChanged(object sender,RoutedEventArgs e)=>Publish(value with {Enabled=EnabledBox.IsChecked==true});
    private void PresetChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!syncing && PresetBox.SelectedIndex is 0 or 1)Publish((PresetBox.SelectedIndex==0 ? DenoiseSettings.Detail : DenoiseSettings.Clean) with {Enabled=value.Enabled});
    }
    private void ResetClicked(object sender,RoutedEventArgs e)=>Publish(new());
    private void Set(int axis,double number,bool interactive)=>Publish(axis switch {
        0=>value with {Luma=number},1=>value with {Chroma=number},_=>value with {Coarse=number}},interactive);
}
