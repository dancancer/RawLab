using System.Windows.Automation;

internal static partial class Program
{
    private sealed partial class DriverContext
    {
        private void X3fFlow()
        {
            OpenPhoto(raw);
            OpenX3fSettings();
            var expected=phase=="restart" ? "伪红外（旧版）" : "正常显影";
            Check(X3fSelection()==expected,"Native processing popup restores X3F mode: "+expected);
            if(phase=="restart") {
                Check(Math.Abs(GetRangeValue("ParameterValueSlider")-.75)<.02,"Restarted native editor restores exposure with legacy mode");
                SelectX3f("正常显影");
            } else {
                var exposure=root.FindFirst(TreeScope.Descendants,new AndCondition(
                    new PropertyCondition(AutomationElement.ProcessIdProperty,hostPid),
                    new PropertyCondition(AutomationElement.ControlTypeProperty,ControlType.ComboBox),
                    new PropertyCondition(AutomationElement.NameProperty,"曝光基准")));
                Check(exposure!=null && !exposure.Current.IsEnabled,"Normal mode disables the RAW exposure baseline control");
                SelectX3f("伪红外（旧版）");
                SetPresetExposure(.75);
            }
            WaitReady();
            Thread.Sleep(250);
            Trace("x3f-native-flow-complete");
            CloseMainWindow();
        }
        private AutomationElement OpenX3fSettings()
        {
            Invoke(FindById(main,"processing.settings")!);
            return Wait(()=>FindById(root,"x3f.mode")) ?? throw new InvalidOperationException("X3F selector is missing");
        }
        private string X3fSelection()
        {
            var control=FindById(root,"x3f.mode")!;
            var selected=((SelectionPattern)control.GetCurrentPattern(SelectionPattern.Pattern)).Current.GetSelection();
            return selected.Single().Current.Name;
        }
        private void SelectX3f(string name)
        {
            var control=FindById(root,"x3f.mode")!;
            ((ExpandCollapsePattern)control.GetCurrentPattern(ExpandCollapsePattern.Pattern)).Expand();
            var option=Wait(()=>root.FindFirst(TreeScope.Descendants,new AndCondition(
                new PropertyCondition(AutomationElement.ProcessIdProperty,hostPid),
                new PropertyCondition(AutomationElement.NameProperty,name),
                new PropertyCondition(AutomationElement.IsSelectionItemPatternAvailableProperty,true))))
                ?? throw new InvalidOperationException("X3F option is missing: "+name);
            Check(option.Current.IsEnabled,"X3F option is available through native UIA");
            ((SelectionItemPattern)option.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
            Keys(0x1b);Keys(0x1b);WaitReady();
            Trace("x3f-mode-"+name);
        }
    }
}
