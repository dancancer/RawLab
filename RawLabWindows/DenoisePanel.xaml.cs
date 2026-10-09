using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;

namespace RawLab.Windows;

public partial class DenoisePanel : UserControl
{
    private DenoiseSettings value=new();
    private bool syncing=true,dragging;
    public event Action<DenoiseSettings,bool>? Changed;
    public DenoisePanel()
    {
        InitializeComponent();
        foreach(var slider in new[]{LumaSlider,ChromaSlider,CoarseSlider})
        {
            slider.AddHandler(Thumb.DragStartedEvent,new DragStartedEventHandler((_,_)=>dragging=true));
            slider.AddHandler(Thumb.DragCompletedEvent,new DragCompletedEventHandler((_,_)=>{dragging=false;Changed?.Invoke(value,false);}));
        }
        Refresh(value);
    }
    public void Refresh(DenoiseSettings settings)
    {
        syncing=true;value=settings;
        EnabledBox.IsChecked=value.Enabled;PresetBox.SelectedIndex=value.Preset;
        LumaSlider.Value=value.Luma;ChromaSlider.Value=value.Chroma;CoarseSlider.Value=value.Coarse;
        LumaText.Text=value.Luma.ToString("F0");ChromaText.Text=value.Chroma.ToString("F0");CoarseText.Text=value.Coarse.ToString("F0");
        Parameters.IsEnabled=value.Enabled;syncing=false;
    }
    private void Publish(DenoiseSettings next,bool interactive=false)
    {
        if(syncing || !IsEnabled)return;
        Refresh(next);Changed?.Invoke(value,interactive);
    }
    private void EnabledChanged(object sender,RoutedEventArgs e)=>Publish(value with {Enabled=EnabledBox.IsChecked==true});
    private void PresetChanged(object sender,SelectionChangedEventArgs e)
    {
        if(!syncing && PresetBox.SelectedIndex<2)Publish(PresetBox.SelectedIndex==0 ? DenoiseSettings.Detail : DenoiseSettings.Clean);
    }
    private void ResetClicked(object sender,RoutedEventArgs e)=>Publish(new());
    private void Set(string name,double number,bool interactive=false)
    {
        number=Math.Clamp(Math.Round(number),0,100);
        Publish(name switch {"Luma"=>value with {Luma=number},"Chroma"=>value with {Chroma=number},_=>value with {Coarse=number}},interactive);
    }
    private void SliderChanged(object sender,RoutedPropertyChangedEventArgs<double> e)
    { if(!syncing && sender is Slider slider)Set((string)slider.Tag,e.NewValue,dragging); }
    private void Commit(TextBox box)
    {
        if(double.TryParse(box.Text,NumberStyles.Float,CultureInfo.CurrentCulture,out var number) && double.IsFinite(number))
            Set((string)box.Tag,number);
        else Refresh(value);
    }
    private void ValueCommitted(object sender,KeyboardFocusChangedEventArgs e) { if(!syncing)Commit((TextBox)sender); }
    private void ValueKeyDown(object sender,KeyEventArgs e)
    {
        if(e.Key==Key.Enter){Commit((TextBox)sender);e.Handled=true;}
        if(e.Key==Key.Escape){Refresh(value);e.Handled=true;}
    }
    private void ResetValue(object sender,RoutedEventArgs e)
    { var name=(string)((Button)sender).Tag;Set(name,name=="Luma" ? 0 : name=="Chroma" ? 46 : 50); }
}
