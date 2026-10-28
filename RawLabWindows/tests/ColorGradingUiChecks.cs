using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Input;
using RawLab.Windows;

internal static class ColorGradingUiChecks
{
    internal static void Run(string output, Action<bool,string> check)
    {
        var panel = new ColorGradingPanel();
        var host = new Window { Content = panel, Width = 720, Height = 400 };
        var state = new ColorGradingSettings { Shadows = new(231.25,0), Midtones = new(110.125,32.375) };
        var writes = 0;
        panel.Changed += (next, _) => { state = next; writes++; panel.Refresh(state,"photo-a"); };
        panel.Refresh(state,"photo-a"); host.Show(); host.UpdateLayout();
        try {
            panel.SelectZone(ColorGradingZone.Midtones); panel.SelectZone(ColorGradingZone.Shadows);
            check(writes==0 && state.Shadows.Hue==231.25,"Grading zone selection preserves pending hue without an edit");
            var rows = PhotoFeatureChecks.Descendants<ParameterRow>(panel).ToArray();
            var hue = rows.Single(row => AutomationProperties.GetAutomationId(row.Number)=="grading.value.hue");
            hue.Number.Focus(); hue.Number.Text="361"; Press(hue.Number,Key.Enter);
            check(hue.HasInvalidInput && writes==0,"Out-of-range grading hue stays an invalid text draft");
            hue.Number.Text="360"; Press(hue.Number,Key.Enter);
            check(state.Shadows.Hue==0 && writes==1 && state.Midtones.Hue==110.125,"Only the valid 360 endpoint normalizes to zero");
            hue.Number.Text="25"; panel.SelectZone(ColorGradingZone.Highlights);
            check(writes==1 && state.Highlights.IsDefault,"Zone change cancels the old precise input");
            var wheel=PhotoFeatureChecks.Descendants<ColorGradingWheelControl>(panel).Single();
            var peer=(IRangeValueProvider)UIElementAutomationPeer.CreatePeerForElement(wheel)!.GetPattern(PatternInterface.RangeValue)!;
            peer.SetValue(peer.Value);check(writes==1,"Unchanged wheel accessibility value creates no edit");
            peer.SetValue(20);check(writes==2 && state.Highlights.Saturation==20 && state.Midtones.Saturation==32.375,
                "Wheel accessibility updates only the current grading zone");
            foreach(var font in new[]{13.0,26.0}) {
                host.FontSize=font;host.Width=font==13 ? 720 : 380;host.UpdateLayout();
                var bounds=rows[1].TransformToAncestor(panel).TransformBounds(new Rect(rows[1].RenderSize));
                check(bounds.Bottom<=panel.ActualHeight+1 && bounds.Left>=-1 && bounds.Right<=panel.ActualWidth+1,
                    "Both grading values fit the narrow and large-type panel: "+font);
                ParameterInputUiChecks.Snapshot(host,panel,Path.Combine(output,$"grading-panel-{font}.png"));
            }
        } finally { host.Close(); }
    }
    private static void Press(TextBox field,Key key) => field.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice,
        PresentationSource.FromVisual(field),Environment.TickCount,key){RoutedEvent=Keyboard.PreviewKeyDownEvent});
}
