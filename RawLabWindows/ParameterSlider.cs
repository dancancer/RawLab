using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows;
using System.Windows.Media;

namespace RawLab.Windows;
public sealed class ParameterSlider : Slider
{
    public ParameterSlider()=>SetResourceReference(StyleProperty,typeof(ParameterSlider));
    public NumericRange NumericRange { get; set; }=new(0,100);
    public static readonly DependencyProperty ActualValueProperty=DependencyProperty.Register(nameof(ActualValue),typeof(double),typeof(ParameterSlider),new PropertyMetadata(0.0,TrackChanged));
    public static readonly DependencyProperty DefaultValueProperty=DependencyProperty.Register(nameof(DefaultValue),typeof(double),typeof(ParameterSlider),new PropertyMetadata(0.0,TrackChanged));
    public static readonly DependencyProperty DirectionBrushProperty=DependencyProperty.Register(nameof(DirectionBrush),typeof(Brush),typeof(ParameterSlider),new PropertyMetadata(null,TrackChanged));
    public double ActualValue {get=>(double)GetValue(ActualValueProperty);set=>SetValue(ActualValueProperty,value);}
    public double DefaultValue {get=>(double)GetValue(DefaultValueProperty);set=>SetValue(DefaultValueProperty,value);}
    public Brush? DirectionBrush {get=>(Brush?)GetValue(DirectionBrushProperty);set=>SetValue(DirectionBrushProperty,value);}
    private static void TrackChanged(DependencyObject sender,DependencyPropertyChangedEventArgs args)
    {var owner=(ParameterSlider)sender;(owner.GetTemplateChild("ValueTrack") as UIElement)?.InvalidateVisual();}
    internal void DrawTrack(DrawingContext drawing,Size size)
    {
        var left=7.0;var width=Math.Max(0,size.Width-14);var y=size.Height/2;
        drawing.DrawLine(new Pen(DirectionBrush ?? (Brush)FindResource("Track"),3),new(left,y),new(left+width,y));
        var fill=NumericRange.Fill(DefaultValue,ActualValue);
        if(fill.Start!=fill.End)drawing.DrawLine(new Pen((Brush)FindResource("Indicator"),3),new(left+width*fill.Start,y),new(left+width*fill.End,y));
        var origin=left+width*NumericRange.Position(DefaultValue);
        drawing.DrawLine(new Pen((Brush)FindResource("Muted"),1),new(origin,y-5),new(origin,y+5));
    }
    protected override AutomationPeer OnCreateAutomationPeer()=>new NumericPeer(this);
    private sealed class NumericPeer(ParameterSlider owner) : FrameworkElementAutomationPeer(owner),IRangeValueProvider
    {
        protected override string GetClassNameCore()=>nameof(Slider);
        protected override AutomationControlType GetAutomationControlTypeCore()=>AutomationControlType.Slider;
        public override object? GetPattern(PatternInterface pattern)=>pattern==PatternInterface.RangeValue ? this : base.GetPattern(pattern);
        public bool IsReadOnly=>!owner.IsEnabled;
        public double Minimum=>owner.NumericRange.Min;
        public double Maximum=>owner.NumericRange.Max;
        public double SmallChange=>owner.NumericRange.Grid;
        public double LargeChange=>owner.NumericRange.Wheel;
        public double Value=>owner.ActualValue;
        public void SetValue(double value)
        {
            if(!owner.IsEnabled)throw new ElementNotEnabledException();
            if(!double.IsFinite(value) || value<Minimum || value>Maximum)throw new ArgumentOutOfRangeException(nameof(value));
            if(value==owner.ActualValue)return;
            owner.Value=owner.NumericRange.Position(owner.NumericRange.Clamp(value));
        }
    }
}

public sealed class ParameterTrackView : FrameworkElement
{
    public static readonly DependencyProperty SliderProperty=DependencyProperty.Register(nameof(Slider),typeof(ParameterSlider),typeof(ParameterTrackView),new FrameworkPropertyMetadata(null,FrameworkPropertyMetadataOptions.AffectsRender,Changed));
    public ParameterSlider? Slider {get=>(ParameterSlider?)GetValue(SliderProperty);set=>SetValue(SliderProperty,value);}
    private static void Changed(DependencyObject sender,DependencyPropertyChangedEventArgs args)
    {
        var view=(ParameterTrackView)sender;
        if(args.OldValue is ParameterSlider old)old.ValueChanged-=view.ValueChanged;
        if(args.NewValue is ParameterSlider slider)slider.ValueChanged+=view.ValueChanged;
    }
    private void ValueChanged(object sender,RoutedPropertyChangedEventArgs<double> args)=>InvalidateVisual();
    protected override void OnRender(DrawingContext drawing){base.OnRender(drawing);Slider?.DrawTrack(drawing,RenderSize);}
}
