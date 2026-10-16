using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;

namespace RawLab.Windows;
public sealed class ParameterSlider : Slider
{
    public ParameterSlider()=>SetResourceReference(StyleProperty,typeof(Slider));
    public NumericRange NumericRange { get; set; }=new(0,100);
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
        public double Value=>owner.NumericRange.Value(owner.Value);
        public void SetValue(double value)
        {
            if(!owner.IsEnabled)throw new ElementNotEnabledException();
            if(!double.IsFinite(value) || value<Minimum || value>Maximum)throw new ArgumentOutOfRangeException(nameof(value));
            owner.Value=owner.NumericRange.Position(owner.NumericRange.Clamp(value));
        }
    }
}
