using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Automation;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Microsoft.Win32;

namespace RawLab.Windows;
public partial class MainWindow
{
    private Button? importLookButton;
    private Button? presetLibraryButton;
    private readonly Dictionary<ToneControlParameter,(Button Button,AdjustmentRing Ring)> toneToolButtons = [];
    private readonly Dictionary<AtmosphereParameter,(Button Button,AdjustmentRing Ring)> atmosphereToolButtons = [];
    private readonly Dictionary<HDRRenditionParameter,(Button Button,AdjustmentRing Ring)> hdrRenditionToolButtons = [];
    private readonly InspectorModificationCache inspectorModificationCache = new();
    private (string?, long)? parameterRowSourceIdentity;
    private string? lastNavigationLanguage;

    private void AboutClicked(object sender, RoutedEventArgs e)
    {
        if (aboutWindow == null)
        {
            aboutWindow = new AboutWindow(updates, usageAnalytics) { Owner = this };
            aboutWindow.Closed += (_, _) => aboutWindow = null;
            aboutWindow.Show();
        }
        else aboutWindow.Activate();
    }
    private void BuildTools()
    {
        Tools.Children.Clear();toolButtons.Clear();effectToolButtons.Clear();toneToolButtons.Clear();atmosphereToolButtons.Clear();hdrRenditionToolButtons.Clear();
        Tools.Children.Add(FilmCategory);Tools.Children.Add(MasterRecipeCategory);
        foreach(var id in new[]{Parameter.Strength,Parameter.Exposure,Parameter.Highlights,Parameter.Shadows,Parameter.Contrast,
            Parameter.ToneCurve,Parameter.Saturation,Parameter.Sharpening})
        {
            if(id==Parameter.Sharpening)
            {
                Tools.Children.Add(HslCategory);
                Tools.Children.Add(WhiteBalanceCategory);
                Tools.Children.Add(DenoiseCategory);
            }
            var spec=ParameterSpec.All[(int)id];
            var ring=new AdjustmentRing{Width=18,Height=18,Compact=true};
            var grid=new Grid(); grid.Children.Add(ring); grid.Children.Add(new EditorIcon{Kind=spec.Id.ToString(),Width=16,Height=16});
            var caption=new TextBlock{Text=Loc.Text(id==Parameter.ToneCurve ? "曲线" : spec.Title),TextWrapping=TextWrapping.NoWrap,TextAlignment=TextAlignment.Center,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(6,0,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            var stack=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};stack.Children.Add(grid);stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=Loc.Text(id==Parameter.ToneCurve ? "曲线" : spec.Title)};
            AutomationProperties.SetName(button,Loc.Text(id==Parameter.ToneCurve ? "曲线" : spec.Title));
            button.Click+=(_,_)=>SelectTool(ToolFor(spec.Id));
            Tools.Children.Add(button); toolButtons[spec.Id]=(button,ring);
        }
        foreach(var (tool,title,icon) in new[] {
            (PhotoEffectTool.Vignette,Loc.Text("暗角"),"Vignette"), (PhotoEffectTool.Grain,Loc.Text("颗粒"),"Grain")
        })
        {
            var ring=new AdjustmentRing{Width=18,Height=18,Compact=true};
            var grid=new Grid(); grid.Children.Add(ring); grid.Children.Add(new EditorIcon{Kind=icon,Width=16,Height=16});
            var caption=new TextBlock{Text=title,TextWrapping=TextWrapping.NoWrap,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(6,0,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            var stack=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};stack.Children.Add(grid);stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=title};
            AutomationProperties.SetName(button,title);
            AutomationProperties.SetAutomationId(button,tool.ToString());
            button.Click+=(_,_)=>SelectTool(tool==PhotoEffectTool.Vignette ? EditorAdjustmentTool.Vignette : EditorAdjustmentTool.Grain);
            Tools.Children.Add(button); effectToolButtons[tool]=(button,ring);
        }
        foreach(var spec in ToneControlSpec.All) {
            var ring=new AdjustmentRing{Width=18,Height=18,Compact=true};
            var grid=new Grid();grid.Children.Add(ring);grid.Children.Add(new EditorIcon{Kind=spec.Id.ToString(),Width=16,Height=16});
            var caption=new TextBlock{Text=Loc.Text(spec.Title),TextWrapping=TextWrapping.NoWrap,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(6,0,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            var stack=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};stack.Children.Add(grid);stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=Loc.Text(spec.Title)};
            AutomationProperties.SetName(button,Loc.Text(spec.Title));
            button.Click+=(_,_)=>SelectTool(EditorAdjustmentRules.ToolFor(spec.Id));
            toneToolButtons[spec.Id]=(button,ring);
        }
        foreach(var spec in AtmosphereSpec.All) {
            var ring=new AdjustmentRing{Width=18,Height=18,Compact=true};
            var grid=new Grid();grid.Children.Add(ring);grid.Children.Add(new EditorIcon{Kind=spec.Id.ToString(),Width=16,Height=16});
            var caption=new TextBlock{Text=Loc.Text(spec.Title),TextWrapping=TextWrapping.NoWrap,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(6,0,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            var stack=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};stack.Children.Add(grid);stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=Loc.Text(spec.Title)};
            AutomationProperties.SetName(button,Loc.Text(spec.Title));
            button.Click+=(_,_)=>SelectTool(EditorAdjustmentRules.ToolFor(spec.Id));
            atmosphereToolButtons[spec.Id]=(button,ring);
        }
        foreach(var spec in HDRRenditionSpec.All) {
            var ring=new AdjustmentRing{Width=18,Height=18,Compact=true};
            var grid=new Grid();grid.Children.Add(ring);grid.Children.Add(new EditorIcon{Kind=EditorAdjustmentRules.ToolFor(spec.Id).ToString(),Width=16,Height=16});
            var caption=new TextBlock{Text=Loc.Text(spec.Title),TextWrapping=TextWrapping.NoWrap,VerticalAlignment=VerticalAlignment.Center,Margin=new Thickness(6,0,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            var stack=new StackPanel{Orientation=Orientation.Horizontal,VerticalAlignment=VerticalAlignment.Center};stack.Children.Add(grid);stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("ToolButton"),ToolTip=Loc.Text(spec.Title)};
            AutomationProperties.SetName(button,Loc.Text(spec.Title));
            button.Click+=(_,_)=>SelectTool(EditorAdjustmentRules.ToolFor(spec.Id));
            hdrRenditionToolButtons[spec.Id]=(button,ring);
        }
        Tools.Children.Add(GeometryCategory);Tools.Children.Add(LensCategory);BuildWorkspaceNavigation();
    }
    private void FilmCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Film);
    private void DenoiseCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Denoise);
    private void GradingCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.ColorGrading);
    private void HslCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Hsl);
    private void WhiteBalanceCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.WhiteBalance);
    private void LensCategoryClicked(object sender,RoutedEventArgs e) => SelectTool(EditorAdjustmentTool.Lens);
    private void GeometryCategoryClicked(object sender,RoutedEventArgs e) {SelectTool(EditorAdjustmentTool.Geometry);if(choosingGeometry){GeometryEditor.ShowPerspective=false;RefreshControls();}}
    private void PerspectiveCategoryClicked(object sender,RoutedEventArgs e) {SelectTool(EditorAdjustmentTool.Geometry);if(choosingGeometry){GeometryEditor.ShowPerspective=true;RefreshControls();}}
    private void ProcessingSettingsClicked(object sender,RoutedEventArgs e)=>ProcessingPopup.IsOpen=!ProcessingPopup.IsOpen;

    private EditorAdjustmentGroup? expandedGroup = EditorAdjustmentGroup.Light;
    private readonly Dictionary<EditorAdjustmentGroup,Button> groupButtons = [];
    private readonly Dictionary<EditorAdjustmentTool,(Button Button,AdjustmentRing Ring)> workspaceTools = [];
    private EditorAdjustmentTool CurrentTool => choosingFilm ? EditorAdjustmentTool.Film : choosingRecipes ? EditorAdjustmentTool.MasterRecipe :
        choosingGrading ? EditorAdjustmentTool.ColorGrading : choosingHsl ? EditorAdjustmentTool.Hsl : choosingWhiteBalance ? EditorAdjustmentTool.WhiteBalance : choosingDenoise ? EditorAdjustmentTool.Denoise :
        choosingGeometry ? EditorAdjustmentTool.Geometry : choosingLens ? EditorAdjustmentTool.Lens :
        choosingPhotoEffects ? selectedEffect==PhotoEffectTool.Vignette ? EditorAdjustmentTool.Vignette : EditorAdjustmentTool.Grain : selectedHdrRenditionParameter is {} hdrRendition ? EditorAdjustmentRules.ToolFor(hdrRendition) : selectedAtmosphereParameter is {} atmosphere ? EditorAdjustmentRules.ToolFor(atmosphere) : selectedToneParameter is {} tone ? EditorAdjustmentRules.ToolFor(tone) : ToolFor(selectedParameter);
    private static EditorAdjustmentTool ToolFor(Parameter parameter) => parameter switch {
        Parameter.Temperature or Parameter.Tint => EditorAdjustmentTool.WhiteBalance,
        _ => Enum.GetValues<EditorAdjustmentTool>().First(tool => (tool is EditorAdjustmentTool.Strength or EditorAdjustmentTool.Exposure or
            EditorAdjustmentTool.Highlights or EditorAdjustmentTool.Shadows or EditorAdjustmentTool.Contrast or EditorAdjustmentTool.ToneCurve or
            EditorAdjustmentTool.Saturation or EditorAdjustmentTool.Sharpening) && EditorAdjustmentRules.ParameterFor(tool)==parameter)
    };
    private void BuildWorkspaceNavigation()
    {
        Groups.Children.Clear();groupButtons.Clear();workspaceTools.Clear();
        foreach(var group in Enum.GetValues<EditorAdjustmentGroup>()) {
            var button = new Button { Style = (Style)FindResource("ToolButton"), MinHeight = 30, MaxWidth = 248 };
            button.Content = new TextBlock { TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetAutomationId(button,"editor.group."+EditorAdjustmentRules.Id(group));
            button.Click+=(_,_)=>SelectGroup(group);groupButtons[group]=button;Groups.Children.Add(button);
        }
        workspaceTools[EditorAdjustmentTool.Film]=(FilmCategory,FilmCategoryRing);
        workspaceTools[EditorAdjustmentTool.MasterRecipe]=(MasterRecipeCategory,MasterRecipeCategoryRing);
        workspaceTools[EditorAdjustmentTool.WhiteBalance]=(WhiteBalanceCategory,WhiteBalanceCategoryRing);
        workspaceTools[EditorAdjustmentTool.ColorGrading]=(GradingCategory,GradingCategoryRing);
        workspaceTools[EditorAdjustmentTool.Hsl]=(HslCategory,HslCategoryRing);
        workspaceTools[EditorAdjustmentTool.Denoise]=(DenoiseCategory,DenoiseCategoryRing);
        workspaceTools[EditorAdjustmentTool.Geometry]=(GeometryCategory,GeometryCategoryRing);
        workspaceTools[EditorAdjustmentTool.Lens]=(LensCategory,LensCategoryRing);
        foreach(var (parameter,controls) in toolButtons)workspaceTools[ToolFor(parameter)]=controls;
        foreach(var (parameter,controls) in toneToolButtons)workspaceTools[EditorAdjustmentRules.ToolFor(parameter)]=controls;
        foreach(var (parameter,controls) in atmosphereToolButtons)workspaceTools[EditorAdjustmentRules.ToolFor(parameter)]=controls;
        foreach(var (parameter,controls) in hdrRenditionToolButtons)workspaceTools[EditorAdjustmentRules.ToolFor(parameter)]=controls;
        foreach(var (tool,controls) in effectToolButtons)workspaceTools[tool==PhotoEffectTool.Vignette ? EditorAdjustmentTool.Vignette : EditorAdjustmentTool.Grain]=controls;
        foreach (var (tool, controls) in workspaceTools)
        {
            AutomationProperties.SetAutomationId(controls.Button, tool.ToString());
            StyleInspectorTool(controls.Button);
        }
        StyleInspectorTool(PerspectiveCategory);
        // 同一描述表决定工具顺序、默认工具与重置范围。
        Tools.Children.Clear();foreach(var group in Enum.GetValues<EditorAdjustmentGroup>())foreach(var tool in EditorAdjustmentRules.Tools(group)) {
            Tools.Children.Add(workspaceTools[tool].Button);
            if(tool==EditorAdjustmentTool.Geometry)Tools.Children.Add(PerspectiveCategory);
        }
        presetLibraryButton = new Button { Content = new TextBlock { Text = Loc.Text("我的预设"), TextWrapping = TextWrapping.Wrap },
            Style = (Style)FindResource("ToolButton"), MinHeight = 32, HorizontalContentAlignment = HorizontalAlignment.Left };
        AutomationProperties.SetName(presetLibraryButton, Loc.Text("我的预设"));
        AutomationProperties.SetAutomationId(presetLibraryButton, "preset.quick.open");
        presetLibraryButton.PreviewMouseDown += (_, _) => PreserveQuickPresetInputs();
        presetLibraryButton.PreviewGotKeyboardFocus += (_, _) => PreserveQuickPresetInputs();
        presetLibraryButton.Click += (_, _) => { if (quickPresetsVisible) CloseQuickPresets(); else ShowQuickPresets(); };
        Tools.Children.Add(presetLibraryButton);
        if (quickPresetsVisible) RefreshQuickPresets(true);
    }
    private void StyleInspectorTool(Button button)
    {
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        if (button.Content is not StackPanel stack || stack.Children.Count != 2 ||
            stack.Children[1] is not TextBlock title) return;
        var icon = stack.Children[0];
        stack.Children.Clear();
        var row = new DockPanel { IsHitTestVisible = false };
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        title.TextWrapping = TextWrapping.Wrap;
        title.TextAlignment = TextAlignment.Left;
        row.Children.Add(title);
        button.Content = row;
    }

    private void SelectGroup(EditorAdjustmentGroup group)
    {
        if(file==null || exporting || pendingAllReset!=null || !EditorAdjustmentRules.IsGroupVisible(group, settings.IsHDREditing))return;
        var wasQuick = quickPresetsVisible;
        if (group == EditorAdjustmentGroup.Looks && settings.IsHDREditing && !wasQuick) { ShowQuickPresets(); return; }
        if (wasQuick) CloseQuickPresets();
        if(expandedGroup==group && !wasQuick || wasQuick && group==EditorAdjustmentGroup.Looks) {
            SetHslTargetMode(false,hslTargetAxis);CancelParameterInputs();if(!ResolveTransformDraft())return;
            expandedGroup=null;RefreshWorkspaceNavigation();
            return;
        }
        SelectTool(EditorAdjustmentRules.DefaultTool(group));
    }
    private void SelectTool(EditorAdjustmentTool tool)
    {
        if(file==null || exporting || pendingAllReset!=null)return;
        tool = EditorAdjustmentRules.NormalizeTool(tool, settings.IsHDREditing);
        if (quickPresetsVisible) CloseQuickPresets();
        if(tool!=EditorAdjustmentTool.Hsl)SetHslTargetMode(false,hslTargetAxis);
        CancelParameterInputs();
        if(tool is EditorAdjustmentTool.Geometry or EditorAdjustmentTool.Lens) {
            BeginTransform(tool==EditorAdjustmentTool.Geometry ? TransformTool.Geometry : TransformTool.Lens);
            if(!transform.Active || (transform.Tool==TransformTool.Geometry)!=(tool==EditorAdjustmentTool.Geometry))return;
        } else {
            if(!ResolveTransformDraft())return;
            choosingFilm=tool==EditorAdjustmentTool.Film;choosingRecipes=tool==EditorAdjustmentTool.MasterRecipe;
            choosingGrading=tool==EditorAdjustmentTool.ColorGrading;
            choosingHsl=tool==EditorAdjustmentTool.Hsl;choosingWhiteBalance=tool==EditorAdjustmentTool.WhiteBalance;
            choosingDenoise=tool==EditorAdjustmentTool.Denoise;choosingPhotoEffects=tool is EditorAdjustmentTool.Vignette or EditorAdjustmentTool.Grain;
            choosingGeometry=choosingLens=false;
            selectedHdrRenditionParameter=EditorAdjustmentRules.HdrRenditionParameterFor(tool);
            selectedToneParameter=EditorAdjustmentRules.ToneParameterFor(tool);
            selectedAtmosphereParameter=EditorAdjustmentRules.AtmosphereParameterFor(tool);
            if(choosingPhotoEffects)selectedEffect=tool==EditorAdjustmentTool.Vignette ? PhotoEffectTool.Vignette : PhotoEffectTool.Grain;
            else if(selectedHdrRenditionParameter==null && selectedToneParameter==null && selectedAtmosphereParameter==null && !choosingFilm && !choosingRecipes && !choosingHsl && !choosingGrading && !choosingWhiteBalance && !choosingDenoise)selectedParameter=EditorAdjustmentRules.ParameterFor(tool);
        }
        expandedGroup=EditorAdjustmentRules.GroupFor(tool);
        suspendedTransform = null;
        RefreshControls();
    }
    private static IEnumerable<ParameterRow> ParameterRows(DependencyObject root)
    {
        if(root is ParameterRow row){yield return row;yield break;}
        foreach(var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach(var nested in ParameterRows(child))yield return nested;
    }
    private void CancelParameterInputs()
    {
        CancelHslTarget();GradingEditor.CancelInputs();CurveEditor.CancelInputs();
        var draftRows=transform.Active && transform.Tool==TransformTool.Geometry ? ParameterRows(GeometryEditor).ToHashSet() : [];
        foreach(var row in ParameterRows(AdjustmentPanel))if(!draftRows.Contains(row))row.CancelInput();
    }
    private void ParameterNavigationPressed(object sender,MouseButtonEventArgs e)
    {
        if (ReferenceEquals(sender, Tools))
        {
            var header = FindParent<Button>(e.OriginalSource as DependencyObject);
            if (header?.Parent != Tools || header == presetLibraryButton) return;
        }
        if(ReferenceEquals(sender,MainMenu) && IsUpdateMenuNavigation(e.OriginalSource as DependencyObject)){PreserveUpdateNavigation();return;}
        CancelParameterInputs();
    }
    private SavedEdit? WorkspaceEdit()
    {
        if (file == null || CurrentViewSource is not { } identity) return null;
        var edit = new SavedEdit(identity, settings.Capture(), CurrentLookIdentity());
        if (!transform.Active) return edit;
        var settingsSnapshot = edit.Settings.Copy();
        settingsSnapshot = settingsSnapshot.HDR is { Mode: HDRMode.Hdr } hdr
            ? settingsSnapshot with { HDR = hdr with { Geometry = transform.Geometry }, Lens = transform.Lens }
            : settingsSnapshot with { Geometry = transform.Geometry, Lens = transform.Lens };
        return edit with { Settings = settingsSnapshot };
    }
    private void RefreshWorkspaceNavigation(bool dragFastPath = false)
    {
        var edit = WorkspaceEdit();
        if (!settings.IsHDREditing && expandedGroup == EditorAdjustmentGroup.HdrRendition)
            expandedGroup = EditorAdjustmentGroup.Light;
        var activeTool = CurrentTool;
        var activeGroup = expandedGroup ?? EditorAdjustmentRules.GroupFor(activeTool);
        if (!string.Equals(lastNavigationLanguage, Loc.Language, StringComparison.Ordinal))
        {
            lastNavigationLanguage = Loc.Language;
            inspectorModificationCache.Invalidate();
        }
        var scope = inspectorModificationCache.Update(
            edit,
            settings.IsHDREditing,
            dragFastPath,
            activeGroup,
            activeTool,
            out var modifiedGroups,
            out var modifiedTools);
        bool ModifiedGroup(EditorAdjustmentGroup group) => modifiedGroups.TryGetValue(group, out var value) && value;
        bool ModifiedTool(EditorAdjustmentTool tool) => modifiedTools.TryGetValue(tool, out var value) && value;

        void UpdateGroupButton(EditorAdjustmentGroup group, Button button)
        {
            button.Visibility = EditorAdjustmentRules.IsGroupVisible(group, settings.IsHDREditing) ? Visibility.Visible : Visibility.Collapsed;
            var modified = ModifiedGroup(group); var selected = expandedGroup == group;
            ((TextBlock)button.Content).Text = Loc.Text(EditorAdjustmentRules.Title(group)) + (modified ? " •" : ""); button.Tag = selected ? "selected" : null;
            AutomationProperties.SetName(button, Loc.Text(EditorAdjustmentRules.Title(group)));
            AutomationProperties.SetItemStatus(button, string.Join(" · ", new[] { selected ? Loc.Format("收起{0}组", Loc.Text(EditorAdjustmentRules.Title(group))) : Loc.Format("展开{0}组", Loc.Text(EditorAdjustmentRules.Title(group))), modified ? Loc.Text("已调整") : "" }.Where(value => value.Length > 0)));
            button.IsEnabled = file != null && !exporting && pendingAllReset == null;
        }

        void UpdateWorkspaceTool(EditorAdjustmentTool tool, (Button Button, AdjustmentRing Ring) controls)
        {
            controls.Button.Visibility = tool != EditorAdjustmentTool.Strength && expandedGroup == EditorAdjustmentRules.GroupFor(tool) ? Visibility.Visible : Visibility.Collapsed;
            // 导航刷新沿用镜头面板的输入约束，避免重新启用普通图片的 RAW 工具。
            controls.Button.IsEnabled = file != null && !exporting && (tool != EditorAdjustmentTool.Lens || LensEditor.IsEnabled) &&
                (!settings.IsHDREditing || EditorAdjustmentRules.HdrRenditionParameterFor(tool) != null || tool is EditorAdjustmentTool.Exposure or EditorAdjustmentTool.Highlights or EditorAdjustmentTool.Shadows or
                    EditorAdjustmentTool.Contrast or EditorAdjustmentTool.BlackPoint or EditorAdjustmentTool.WhitePoint or EditorAdjustmentTool.ToneCurve or
                    EditorAdjustmentTool.Saturation or EditorAdjustmentTool.WhiteBalance or EditorAdjustmentTool.Geometry or
                    EditorAdjustmentTool.Vibrance or EditorAdjustmentTool.Hsl or EditorAdjustmentTool.ColorGrading or
                    EditorAdjustmentTool.Vignette or EditorAdjustmentTool.Grain or EditorAdjustmentTool.Clarity or
                    EditorAdjustmentTool.Dehaze or EditorAdjustmentTool.Sharpening or EditorAdjustmentTool.Denoise);
            var modified = ModifiedTool(tool);
            controls.Ring.Progress = modified ? (controls.Ring.Progress == 0 ? 1 : controls.Ring.Progress) : 0; controls.Ring.InvalidateVisual();
            AutomationProperties.SetItemStatus(controls.Button, string.Join(" · ", new[] { activeTool == tool ? Loc.Text("当前工具") : "", modified ? Loc.Text("已调整") : "" }.Where(value => value.Length > 0)));
        }

        if (scope == InspectorRefreshScope.DragFastPath)
        {
            if (groupButtons.TryGetValue(activeGroup, out var activeGroupButton))
                UpdateGroupButton(activeGroup, activeGroupButton);
            if (workspaceTools.TryGetValue(activeTool, out var activeControls))
                UpdateWorkspaceTool(activeTool, activeControls);
            if (LookStrengthRow.Visibility == Visibility.Visible && groupButtons.TryGetValue(EditorAdjustmentGroup.Looks, out var looksButton))
                UpdateGroupButton(EditorAdjustmentGroup.Looks, looksButton);
            return;
        }

        foreach (var (group, button) in groupButtons) UpdateGroupButton(group, button);
        foreach (var (tool, controls) in workspaceTools) UpdateWorkspaceTool(tool, controls);
        if (presetLibraryButton != null) {
            presetLibraryButton.Visibility = expandedGroup == EditorAdjustmentGroup.Looks ? Visibility.Visible : Visibility.Collapsed;
            presetLibraryButton.IsEnabled = file != null && !exporting;
            presetLibraryButton.Tag = quickPresetsVisible ? "selected" : null;
        }
        var expanded=expandedGroup!=null;
        QuickPresetSurface.Visibility = expanded && quickPresetsVisible ? Visibility.Visible : Visibility.Collapsed;
        QuickPresetSurface.IsEnabled = file != null && !exporting && !closing && !aiJob.State.IsRunning;
        if (expanded && quickPresetsVisible) {
            foreach (var panel in new FrameworkElement[]{ParameterPanel,FilmPanel,MasterRecipePanel,DenoiseSurface,LensSurface,GeometrySurface,HslSurface,GradingSurface,CurveSurface,WhiteBalanceSurface,PhotoEffectsSurface,DraftActions}) panel.Visibility=Visibility.Collapsed;
            foreach (var controls in workspaceTools.Values) { controls.Button.Tag=null; controls.Ring.Selected=false; controls.Ring.InvalidateVisual(); }
        }
        var showStrength = expandedGroup == EditorAdjustmentGroup.Looks && !settings.IsHDREditing && !quickPresetsVisible;
        LookStrengthRow.Visibility = showStrength ? Visibility.Visible : Visibility.Collapsed;
        ToolsScroller.Visibility=expanded ? Visibility.Visible : Visibility.Collapsed;
        PositionInspectorContent();
        PerspectiveCategory.Visibility=expandedGroup==EditorAdjustmentGroup.Geometry ? Visibility.Visible : Visibility.Collapsed;
        if(!expanded)foreach(var panel in new FrameworkElement[]{ParameterPanel,FilmPanel,MasterRecipePanel,DenoiseSurface,LensSurface,GeometrySurface,HslSurface,GradingSurface,CurveSurface,WhiteBalanceSurface,PhotoEffectsSurface,DraftActions})panel.Visibility=Visibility.Collapsed;
    }
    private EditorAdjustmentGroup? scrolledGroup;

    private void PositionInspectorContent()
    {
        var index = Tools.Children.IndexOf(ToolBody);
        if (expandedGroup != null)
        {
            var anchor = quickPresetsVisible ? presetLibraryButton :
                expandedGroup == EditorAdjustmentGroup.Geometry ? LensCategory :
                CurrentTool == EditorAdjustmentTool.Strength ? FilmCategory :
                workspaceTools.GetValueOrDefault(CurrentTool).Button;
            var after = anchor == null ? -1 : Tools.Children.IndexOf(anchor);
            if (index != after + 1 || index < 0)
            {
                if (index >= 0) Tools.Children.RemoveAt(index);
                after = anchor == null ? -1 : Tools.Children.IndexOf(anchor);
                Tools.Children.Insert(after + 1, ToolBody);
            }
        }
        if (scrolledGroup != expandedGroup)
        {
            scrolledGroup = expandedGroup;
            ToolsScroller.ScrollToTop();
        }
    }

    private void BuildFilms()
    {
        FilmStrip.Children.Clear(); filmButtons.Clear(); importLookButton=LookImport;
        var visible=VisibleBrowserFilms();
        LookEmptyAction.Content=Loc.Text(string.IsNullOrWhiteSpace(lookQuery) ? "全部外观" : "清除搜索");
        LookSearchClear.Visibility=string.IsNullOrWhiteSpace(lookQuery) ? Visibility.Collapsed : Visibility.Visible;
        var ordered = lookCategory == LookBrowserCategory.Recent ? visible :
            FilmGrouping.Arrange(visible, film => film.Path == null, film => film.Group).Select(item => item.Value);
        foreach(var film in ordered)
        {
            var stack=new StackPanel();
            var artwork=new Grid{Width=46,Height=46};
            if(film.Artwork!=null && File.Exists(film.Artwork))artwork.Children.Add(new Image{Source=new BitmapImage(new Uri(film.Artwork)),Width=46,Height=46});
            else artwork.Children.Add(new EditorIcon{Kind=film.Path==null ? "Neutral" : "Film",Width=28,Height=46});
            if(film.CompatibilityMode!=0) {
                var badge=new EditorIcon{Kind="Clipping",Width=18,Height=18};
                badge.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty,"Accent");
                var backing=new Border{Child=badge,Padding=new Thickness(3),CornerRadius=new CornerRadius(3),HorizontalAlignment=HorizontalAlignment.Right,VerticalAlignment=VerticalAlignment.Top};
                backing.SetResourceReference(Border.BackgroundProperty,"Surface");
                AutomationProperties.SetName(backing,Loc.Text("兼容导入"));artwork.Children.Add(backing);
            }
            stack.Children.Add(artwork);
            var displayName=film.Path==null ? Loc.Text("中性") : film.Name;
            if(film.CompatibilityMode!=0)displayName += " · " + Loc.Text(film.CompatibilityMode==8 ? "近似基础 · 未验证" : "兼容导入 · 未验证");
            else if(film.AppearanceUnverified)displayName += " · " + Loc.Text("效果未验证");
            var caption=new TextBlock{Text=displayName,MinHeight=29,TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,Margin=new Thickness(0,5,0,0)};
            caption.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");stack.Children.Add(caption);
            var button=new Button{Content=stack,Style=(Style)FindResource("QuietButton"),Padding=new Thickness(3,5,3,5),HorizontalContentAlignment=HorizontalAlignment.Stretch,ToolTip=displayName};
            AutomationProperties.SetName(button,displayName);
            if(film.Path!=null && !IsBuiltInLook(film.Path)) {
                var menu=new ContextMenu();
                var rename=new MenuItem{Header=Loc.Text("重命名外观")};
                AutomationProperties.SetAutomationId(rename,"look.rename.open");
                rename.Click+=(_,_)=>RenameImportedLook(film.Path);menu.Items.Add(rename);button.ContextMenu=menu;
            }
            button.Click+=(_,_)=>{
                if(exporting || !ResolveTransformDraft() || (settings.MasterRecipeID == null && lut == film.Path))return;
                try { settings.ClearMasterRecipe(file == null || PhotoInput.IsRaw(file)); }
                catch (Exception error) { Report(error); return; }
                lut=film.Path;
                usageAnalytics.Record(new FilmSelectedEvent(film.Path == null ? FilmKind.None : IsBuiltInLook(film.Path) ? FilmKind.BuiltIn : FilmKind.Custom));
                MarkEdited();RefreshControls();Schedule();
            };
            FilmStrip.Children.Add(button); filmButtons[film.Path ?? ""]=button;
        }
        BuildUnreadableLooks();
        LookEmpty.Visibility=visible.Count==0 && UnreadableLooksPanel.Visibility!=Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BuildUnreadableLooks()
    {
        UnreadableLooksPanel.Children.Clear();
        var unreadable=lookLibrary?.ListUnreadable() ?? Array.Empty<UnreadableLook>();
        var show=unreadable.Count>0 && (lookCategory is LookBrowserCategory.All or LookBrowserCategory.Custom) && string.IsNullOrWhiteSpace(lookQuery);
        UnreadableLooksPanel.Visibility=show ? Visibility.Visible : Visibility.Collapsed;
        if(!show) return;
        var index=0;
        var rowIds=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach(var bad in unreadable)
        {
            index++;
            var rowId=bad.Id is { Length: > 0 } badId && Guid.TryParseExact(badId,"D",out _) && rowIds.Add(badId) ? badId : "unreadable."+index;
            var displayName=!string.IsNullOrWhiteSpace(bad.Name) ? Loc.Format("{0}（损坏）",bad.Name) : Loc.Text("损坏的预设");
            var row=new Border{Padding=new Thickness(0,6,0,6),Opacity=0.75};
            AutomationProperties.SetAutomationId(row,"looks.unreadable.row."+rowId);
            var dock=new DockPanel();
            var delete=new Button{
                Content=Loc.Text("删除"),
                Style=(Style)FindResource("ToolButton"),
                VerticalAlignment=VerticalAlignment.Center,
                Margin=new Thickness(8,0,0,0),
                IsEnabled=!exporting && !transform.Active
            };
            AutomationProperties.SetAutomationId(delete,"looks.unreadable.delete."+rowId);
            AutomationProperties.SetName(delete,Loc.Text("删除"));
            delete.Click+=(_,_)=>RemoveUnreadableLook(bad);
            DockPanel.SetDock(delete,Dock.Right);
            dock.Children.Add(delete);
            var labels=new StackPanel{VerticalAlignment=VerticalAlignment.Center};
            var title=new TextBlock{Text=displayName,FontWeight=FontWeights.SemiBold,TextWrapping=TextWrapping.Wrap};
            title.SetResourceReference(TextBlock.ForegroundProperty,"Muted");
            labels.Children.Add(title);
            var warning=new TextBlock{Text=Loc.Text("本地记录损坏。"),TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,2,0,0)};
            warning.SetResourceReference(TextBlock.ForegroundProperty,"Muted");
            warning.SetResourceReference(TextBlock.FontSizeProperty,"EditorCaptionSize");
            labels.Children.Add(warning);
            dock.Children.Add(labels);
            var stack=new StackPanel();
            stack.Children.Add(new Separator{Margin=new Thickness(0,0,0,6)});
            stack.Children.Add(dock);
            row.Child=stack;
            UnreadableLooksPanel.Children.Add(row);
        }
    }
    private void UpdateParameterToolRing(Parameter id, (Button Button, AdjustmentRing Ring) controls, bool hdrEditing)
    {
        controls.Button.IsEnabled=file!=null && !exporting && (!hdrEditing || HDRSettings.Supports(id));
        var selected=!choosingRecipes && !choosingHsl && !choosingGrading && !choosingFilm && !choosingDenoise && !choosingPhotoEffects && !choosingWhiteBalance && !choosingLens && !choosingGeometry && selectedHdrRenditionParameter==null && selectedToneParameter==null && selectedAtmosphereParameter==null && id==selectedParameter;
        controls.Button.Tag=selected ? "selected" : null;
        controls.Ring.Selected=selected;
        var p=ParameterSpec.All[(int)id]; var origin=p.Position(settings.Default(id)); var offset=p.Position(settings[id])-origin;
        controls.Ring.Progress=id==Parameter.ToneCurve && !settings.EditingCurve.IsDefault ? settings.EditingCurve.Progress : offset==0 ? 0 : offset/(offset<0 ? origin : 1-origin); controls.Ring.InvalidateVisual();
    }
    private void UpdateToneToolRing(ToneControlParameter id, (Button Button, AdjustmentRing Ring) controls, bool hdrEditing)
    {
        var selected=CurrentTool==EditorAdjustmentRules.ToolFor(id);
        controls.Button.IsEnabled=file!=null && !exporting && (!hdrEditing || HDRSettings.Supports(id));
        controls.Button.Tag=selected ? "selected" : null;controls.Ring.Selected=selected;
        controls.Ring.Progress=settings.EditingToneValue(id)/100;controls.Ring.InvalidateVisual();
    }
    private void UpdateAtmosphereToolRing(AtmosphereParameter id, (Button Button, AdjustmentRing Ring) controls)
    {
        var selected=CurrentTool==EditorAdjustmentRules.ToolFor(id);
        controls.Button.IsEnabled=file!=null && !exporting;
        controls.Button.Tag=selected ? "selected" : null;controls.Ring.Selected=selected;
        controls.Ring.Progress=settings.EditingAtmosphereValue(id)/100;controls.Ring.InvalidateVisual();
    }
    private void UpdateHdrRenditionToolRing(HDRRenditionParameter id, (Button Button, AdjustmentRing Ring) controls, bool hdrEditing)
    {
        var selected=CurrentTool==EditorAdjustmentRules.ToolFor(id);
        var renditionSpec=HDRRenditionSpec.For(id);
        controls.Button.IsEnabled=file!=null && !exporting && hdrEditing;
        controls.Button.Tag=selected ? "selected" : null;controls.Ring.Selected=selected;
        var val=settings.EditingHDRRenditionValue(id);
        controls.Ring.Progress=val/renditionSpec.Max;controls.Ring.InvalidateVisual();
    }
    private void RefreshControls()
    {
        RefreshHDRControls();
        if(!ready)return;
        syncing=true;
        try
        {
            var dragFastPath = interacting;
            var rowSource = (file, openRevision);
            if (parameterRowSourceIdentity != rowSource)
            {
                parameterRowSourceIdentity = rowSource;
                foreach(var row in ParameterRows(AdjustmentPanel)) row.SourceIdentity = rowSource;
            }
            var raster=file!=null && LibraryEntry.IsRaster(file);
            var hdrEditing=settings.IsHDREditing;
            if (!dragFastPath)
            {
                if (!hdrEditing) {
                    if (expandedGroup == EditorAdjustmentGroup.HdrRendition) expandedGroup = EditorAdjustmentGroup.Light;
                    if (selectedHdrRenditionParameter != null) {
                        selectedHdrRenditionParameter = null;
                        selectedParameter = Parameter.Exposure;
                    }
                }
                if(raster)settings=RenderEngine.PrepareInputSettings(file!,settings);
                if(raster)
                {
                    rasterPreviousGpuMode ??= GpuMode.SelectedIndex;
                    GpuMode.SelectedIndex=1;
                }
                else if(rasterPreviousGpuMode is {} previousMode)
                {rasterPreviousGpuMode=null;GpuMode.SelectedIndex=previousMode;}
            }
            var spec=ParameterSpec.All[(int)selectedParameter];
            var hdrRenditionSpec=selectedHdrRenditionParameter is {} renditionParameter ? HDRRenditionSpec.For(renditionParameter) : null;
            var toneSpec=selectedToneParameter is {} toneParameter ? ToneControlSpec.For(toneParameter) : null;
            var atmosphereSpec=selectedAtmosphereParameter is {} atmosphereParameter ? AtmosphereSpec.For(atmosphereParameter) : null;
            var extensionControl=toneSpec!=null || atmosphereSpec!=null;
            var hdrParameter=hdrRenditionSpec!=null || atmosphereSpec!=null || (toneSpec!=null ? HDRSettings.Supports(toneSpec.Id) : HDRSettings.Supports(selectedParameter));
            var title=atmosphereSpec?.Title ?? toneSpec?.Title ?? spec.Title;var unit=extensionControl ? "%" : spec.Unit;
            var value=atmosphereSpec!=null ? settings.EditingAtmosphereValue(atmosphereSpec.Id) : toneSpec!=null ? settings.EditingToneValue(toneSpec.Id) : settings[selectedParameter];
            var inputRange=extensionControl ? new NumericRange(-100,100) : NumericRange.For(spec);
            if(settings.IsHDREditing && selectedParameter==Parameter.Exposure)
                inputRange=inputRange with { Min=-4, Max=4 };
            if(hdrRenditionSpec!=null) {
                title=hdrRenditionSpec.Title;unit=hdrRenditionSpec.Unit;
                value=settings.EditingHDRRenditionValue(hdrRenditionSpec.Id);
                inputRange=new NumericRange(hdrRenditionSpec.Min,hdrRenditionSpec.Max,hdrRenditionSpec.Grid);
            }
            if (!dragFastPath || ParameterPanel.Visibility == Visibility.Visible)
            {
                OrdinaryParameter.Refresh(Loc.Text(title),inputRange,
                    value,hdrRenditionSpec!=null ? 0 : extensionControl ? 0 : settings.Default(selectedParameter),unit,
                    inputScope:(object?)selectedHdrRenditionParameter ?? (object?)selectedAtmosphereParameter ?? (object?)selectedToneParameter ?? selectedParameter);
                AutomationProperties.SetName(ValueSlider,Loc.Text(title));
                AutomationProperties.SetName(ValueText,Loc.Format("{0}数值（{1}）",Loc.Text(title),unit));
            }
            var canAdjust=file!=null && !exporting && !choosingFilm && !choosingPhotoEffects && (!hdrEditing || hdrParameter) &&
                (hdrRenditionSpec!=null || extensionControl || (selectedParameter!=Parameter.Strength || lut!=null) && (selectedParameter is not(Parameter.Temperature or Parameter.Tint) || settings.AsShot!=null));
            ValueSlider.IsEnabled=ValueText.IsEnabled=canAdjust;
            if (!dragFastPath)
            {
                FilmPanel.Visibility=choosingFilm ? Visibility.Visible : Visibility.Collapsed;
                MasterRecipePanel.Visibility=choosingRecipes ? Visibility.Visible : Visibility.Collapsed;
                MasterRecipeCategory.Tag=choosingRecipes ? "selected" : null;MasterRecipeCategoryRing.Selected=choosingRecipes;MasterRecipeCategoryRing.Progress=settings.MasterRecipeID==null ? 0 : 1;MasterRecipeCategoryRing.InvalidateVisual();
                foreach(var pair in recipeButtons) {
                    var selected=pair.Key==(settings.MasterRecipeID ?? "");pair.Value.Tag=selected ? "selected" : null;
                    recipeSelectionMarkers[pair.Key].Visibility=selected ? Visibility.Visible : Visibility.Hidden;
                    AutomationProperties.SetItemStatus(pair.Value,selected ? Loc.Text("已应用") : "");
                }
                ParameterPanel.Visibility=CurrentTool is EditorAdjustmentTool.Strength or EditorAdjustmentTool.ToneCurve || choosingRecipes || choosingFilm || choosingDenoise || choosingPhotoEffects || choosingHsl || choosingGrading || choosingWhiteBalance || choosingLens || choosingGeometry ? Visibility.Collapsed : Visibility.Visible;
                LensEditor.Visibility=choosingLens ? Visibility.Visible : Visibility.Collapsed;
                LensSurface.Visibility=LensEditor.Visibility;
                LensEditor.IsEnabled=file!=null && !raster && !hdrEditing && !exporting && !PhotoInput.IsNormalX3f(file,settings);
                LensCategory.IsEnabled=LensEditor.IsEnabled;
                LensCategory.Tag=choosingLens ? "selected" : null;
                LensCategoryRing.Selected=choosingLens;LensCategoryRing.Progress=settings.Lens.Enabled ? 1 : 0;LensCategoryRing.InvalidateVisual();
                GeometrySurface.Visibility=choosingGeometry ? Visibility.Visible : Visibility.Collapsed;
                GeometryEditor.IsEnabled=file!=null && !exporting;
                GeometryCategory.IsEnabled=PerspectiveCategory.IsEnabled=file!=null && !exporting;
                GeometryCategory.Tag=choosingGeometry && !GeometryEditor.ShowPerspective ? "selected" : null;
                PerspectiveCategory.Tag=choosingGeometry && GeometryEditor.ShowPerspective ? "selected" : null;
                GradingSurface.Visibility=choosingGrading ? Visibility.Visible : Visibility.Collapsed;
                CurveSurface.Visibility=CurrentTool==EditorAdjustmentTool.ToneCurve ? Visibility.Visible : Visibility.Collapsed;
                CurveEditor.IsEnabled=file!=null && !exporting;
                GradingEditor.IsEnabled=file!=null && !exporting;
                GradingCategory.IsEnabled=HslCategory.IsEnabled=file!=null && !exporting;
                DenoiseCategory.IsEnabled=file!=null && !exporting;
                GradingCategory.Tag=choosingGrading ? "selected" : null;
                HslSurface.Visibility=choosingHsl ? Visibility.Visible : Visibility.Collapsed;
                HslEditor.IsEnabled=file!=null && !exporting;
                HslCategory.Tag=choosingHsl ? "selected" : null;
                WhiteBalanceSurface.Visibility=choosingWhiteBalance ? Visibility.Visible : Visibility.Collapsed;
                WhiteBalanceEditor.IsEnabled=file!=null && (!raster || hdrEditing) && !exporting;
                WhiteBalanceCategory.IsEnabled=file!=null && (!raster || hdrEditing) && !exporting;
                WhiteBalanceCategory.Tag=choosingWhiteBalance ? "selected" : null;
                AutoExposureButton.Visibility=selectedHdrRenditionParameter==null && selectedToneParameter==null && selectedAtmosphereParameter==null && selectedParameter==Parameter.Exposure ? Visibility.Visible : Visibility.Collapsed;
                AutoExposureButton.IsEnabled=CanAutoExpose;
                DenoiseEditor.Visibility=choosingDenoise ? Visibility.Visible : Visibility.Collapsed;
                DenoiseSurface.Visibility=DenoiseEditor.Visibility;
                DenoiseEditor.IsEnabled=file!=null && !exporting;
                PhotoEffectsSurface.Visibility=choosingPhotoEffects ? Visibility.Visible : Visibility.Collapsed;
                PhotoEffectsEditor.IsEnabled=file!=null && !exporting;
                DenoiseCategory.Tag=choosingDenoise ? "selected" : null;
                FilmCategory.Tag=choosingFilm ? "selected" : null;
                FilmCategory.IsEnabled=!hdrEditing && !exporting;
                FilmCategoryRing.Selected=choosingFilm;FilmCategoryRing.InvalidateVisual();
                if(importLookButton!=null)importLookButton.IsEnabled=!exporting;
                UnreadableLooksPanel.IsEnabled=!exporting && !transform.Active;
                if(presetLibraryButton!=null)presetLibraryButton.IsEnabled=!exporting && !transferPreparing;
                ExposureMode.SelectedIndex=settings.ExposureMode;
                ProcessingVersion.SelectedIndex=settings.Processing.Version-1;
                ProcessingVersion.IsEnabled=file!=null && !exporting && !transform.Active && pendingAllReset==null;
                RefreshProcessingMigrationControls();
                ExposureMode.IsEnabled=ResetAllButton.IsEnabled=file!=null && !exporting;
                ExposureMode.IsEnabled=ExposureMode.IsEnabled && !raster && !hdrEditing && !transform.Active && !PhotoInput.IsNormalX3f(file,settings);
                X3fSettingsPanel.Visibility=PhotoInput.IsX3f(file) ? Visibility.Visible : Visibility.Collapsed;
                X3fRendering.SelectedIndex=(int)settings.X3fMode;
                X3fRendering.IsEnabled=file!=null && !exporting && !transform.Active;
                X3fNormalOption.IsEnabled=RenderEngine.X3fAvailable;
                X3fDescription.Text=Loc.Text(settings.X3fMode==X3fMode.Normal ? "以文件保存的显影为基准，白平衡作相对调整。" : "保留旧版的特殊色彩。");
                AsShotButton.IsEnabled=file!=null && !exporting && settings.AsShot!=null && !transform.Active;
                DraftActions.Visibility=transform.Active ? Visibility.Visible : Visibility.Collapsed;
            }
            void UpdateCategoryRings()
            {
                if (choosingGeometry || !dragFastPath)
                {
                    GeometryCategoryRing.Selected=choosingGeometry && !GeometryEditor.ShowPerspective;
                    GeometryCategoryRing.Progress=settings.Geometry.IsIdentity ? 0 : 1;
                    GeometryCategoryRing.InvalidateVisual();
                }
                if (choosingGrading || !dragFastPath)
                {
                    GradingCategoryRing.Selected=choosingGrading;
                    GradingCategoryRing.Progress=settings.EditingGrading.IsDefault ? 0 : 1;
                    GradingCategoryRing.InvalidateVisual();
                }
                if (choosingHsl || !dragFastPath)
                {
                    HslCategoryRing.Selected=choosingHsl;
                    HslCategoryRing.Progress=settings.EditingHsl.IsIdentity ? 0 : 1;
                    HslCategoryRing.InvalidateVisual();
                }
                if (choosingWhiteBalance || !dragFastPath)
                {
                    WhiteBalanceCategoryRing.Selected=choosingWhiteBalance;
                    var temperatureSpec=ParameterSpec.All[(int)Parameter.Temperature];
                    var temperatureOrigin=temperatureSpec.Position(settings.Default(Parameter.Temperature));
                    var temperatureOffset=temperatureSpec.Position(settings[Parameter.Temperature])-temperatureOrigin;
                    var temperatureProgress=temperatureOffset==0 ? 0 : temperatureOffset/(temperatureOffset<0 ? temperatureOrigin : 1-temperatureOrigin);
                    var tintSpec=ParameterSpec.All[(int)Parameter.Tint];
                    var tintOrigin=tintSpec.Position(settings.Default(Parameter.Tint));
                    var tintOffset=tintSpec.Position(settings[Parameter.Tint])-tintOrigin;
                    var tintProgress=tintOffset==0 ? 0 : tintOffset/(tintOffset<0 ? tintOrigin : 1-tintOrigin);
                    WhiteBalanceCategoryRing.Progress=Math.Abs(temperatureProgress)>=Math.Abs(tintProgress) ? temperatureProgress : tintProgress;
                    WhiteBalanceCategoryRing.InvalidateVisual();
                }
                if (choosingDenoise || !dragFastPath)
                {
                    DenoiseCategoryRing.Selected=choosingDenoise;
                    DenoiseCategoryRing.Progress=hdrEditing ? settings.HDR!.DetailSettings.Denoise : settings.Denoise.Enabled ? 1 : 0;
                    DenoiseCategoryRing.InvalidateVisual();
                }
            }
            if (InspectorModificationCache.ShouldRefreshSubEditor(choosingLens))
                LensEditor.Refresh(PreviewLens,result?.Lens);
            if (InspectorModificationCache.ShouldRefreshSubEditor(choosingGeometry))
                GeometryEditor.Refresh(transform.Active ? transform.Geometry : settings.Geometry);
            if (InspectorModificationCache.ShouldRefreshSubEditor(CurrentTool==EditorAdjustmentTool.ToneCurve))
                CurveEditor.Refresh(settings.EditingCurve,settings[Parameter.ToneCurve],(file,openRevision,hdrEditing),hdrEditing);
            if (InspectorModificationCache.ShouldRefreshSubEditor(choosingGrading))
                GradingEditor.Refresh(settings.EditingGrading,(file,openRevision,hdrEditing));
            if (InspectorModificationCache.ShouldRefreshSubEditor(choosingHsl))
            {
                HslEditor.Refresh(settings.EditingHsl);
                RefreshHslTarget();
            }
            if (InspectorModificationCache.ShouldRefreshSubEditor(choosingWhiteBalance))
                WhiteBalanceEditor.Refresh(settings,WhiteBalanceEditor.IsEnabled && (hdrEditing || settings.AsShot!=null));
            if (InspectorModificationCache.ShouldRefreshSubEditor(choosingDenoise))
            {
                DenoiseEditor.Refresh(settings.Denoise,hdrEditing ? settings.HDR!.DetailSettings.Denoise : null);
                RefreshAIControls();
            }
            if (InspectorModificationCache.ShouldRefreshSubEditor(choosingPhotoEffects))
                PhotoEffectsEditor.Refresh(settings.EditingEffects,selectedEffect);
            UpdateCategoryRings();
            if (!dragFastPath)
            {
                foreach(var (tool,controls) in effectToolButtons)
                {
                    var selected=choosingPhotoEffects && selectedEffect==tool;
                    controls.Button.Tag=selected ? "selected" : null;
                    controls.Ring.Selected=selected;
                    controls.Ring.Progress=settings.IsEffectDefault(tool==PhotoEffectTool.Vignette) ? 0 : 1;
                    controls.Ring.InvalidateVisual();
                }
                foreach(var (id,controls) in toolButtons) UpdateParameterToolRing(id,controls,hdrEditing);
                foreach(var (id,controls) in toneToolButtons) UpdateToneToolRing(id,controls,hdrEditing);
                foreach(var (id,controls) in atmosphereToolButtons) UpdateAtmosphereToolRing(id,controls);
                foreach(var (id,controls) in hdrRenditionToolButtons) UpdateHdrRenditionToolRing(id,controls,hdrEditing);
                foreach(var pair in filmButtons) {
                    var selected=pair.Key==(lut ?? "");pair.Value.Tag=selected ? "selected" : null;
                    AutomationProperties.SetItemStatus(pair.Value,selected ? Loc.Text("已应用") : "");
                }
                var lookTitle=LookTitle;
                ActiveFilm.Text=InspectorLook.Text=lookTitle;FilmLabelText.Text=Loc.Text("调整后");ActiveFilm.ToolTip=InspectorLook.ToolTip=lookTitle;
                NeutralLabel.Visibility=FilmLabel.Visibility=compare && result!=null ? Visibility.Visible : Visibility.Collapsed;
                ClippingButton.Tag=clipping ? "selected" : null;
                InfoButton.Tag=photoInfoMode == PhotoInfoMode.Hidden ? null : "selected";
            }
            else
            {
                if (choosingPhotoEffects && effectToolButtons.TryGetValue(selectedEffect, out var effectControls))
                {
                    effectControls.Button.Tag="selected";
                    effectControls.Ring.Selected=true;
                    effectControls.Ring.Progress=settings.IsEffectDefault(selectedEffect==PhotoEffectTool.Vignette) ? 0 : 1;
                    effectControls.Ring.InvalidateVisual();
                }
                else if (selectedHdrRenditionParameter is {} hdrId && hdrRenditionToolButtons.TryGetValue(hdrId, out var hdrControls))
                    UpdateHdrRenditionToolRing(hdrId, hdrControls, hdrEditing);
                else if (selectedAtmosphereParameter is {} atmoId && atmosphereToolButtons.TryGetValue(atmoId, out var atmoControls))
                    UpdateAtmosphereToolRing(atmoId, atmoControls);
                else if (selectedToneParameter is {} toneId && toneToolButtons.TryGetValue(toneId, out var toneControls))
                    UpdateToneToolRing(toneId, toneControls, hdrEditing);
                else if (toolButtons.TryGetValue(selectedParameter, out var toolControls))
                    UpdateParameterToolRing(selectedParameter, toolControls, hdrEditing);
            }
            ResetParameterButton.IsEnabled=ResetGroupButton.IsEnabled=canAdjust;
            ApplyDraftButton.IsEnabled=CanApplyTransform;
            if (!dragFastPath || LookStrengthRow.Visibility == Visibility.Visible)
            {
                var strength = ParameterSpec.All[(int)Parameter.Strength];
                LookStrengthRow.Refresh(Loc.Text("外观强度"), NumericRange.For(strength), settings[Parameter.Strength],
                    settings.Default(Parameter.Strength), strength.Unit,
                    enabled: file != null && lut != null && !exporting && !transform.Active, inputScope: Parameter.Strength);
            }
            if (!dragFastPath)
            {
                RefreshComparisonLayout();
                RefreshViewingFrames();
                RefreshComparisonSelection();
            }
            UpdateBusy();
            if (!dragFastPath) RefreshExportSizeMenu();
            RefreshWorkspaceNavigation(dragFastPath);
            if (!dragFastPath) RefreshUnavailableToolReasons();
        }
        finally { syncing=false; }
    }
    private void UpdateBusy()
    {
        photoPreviews?.SetPaused(scheduler.Busy || exporting || aiJob.State.IsRunning);
        MenuCollection.IsEnabled=CollectionReturn.IsEnabled=!CollectionBusy;
        CollectionReturn.Visibility=Collection.CurrentID!=null ? Visibility.Visible : Visibility.Collapsed;
        var exportReady=ShowsPhotoWorkspace && pendingAllReset==null && !AIBlocksOutput && exactReady && !scheduler.Busy && !previewResize.IsEnabled && !exporting && result!=null && LookAvailable && !transform.Active;
        ExportJpeg.IsEnabled=ExportSdrJpeg.IsEnabled=ExportPng.IsEnabled=ExportDng.IsEnabled=BatchExportMenu.IsEnabled=exportReady;
        ExportHdrJpeg.IsEnabled=exportReady && settings.IsHDREditing;
        ViewBatchMenu.IsEnabled=CurrentBatch!=null;
        MenuViewBatch.IsEnabled=ViewBatchMenu.IsEnabled;
        AutoExposureButton.IsEnabled=MenuAutoExposure.IsEnabled=CanAutoExpose;
        MenuAsShot.IsEnabled=AsShotButton.IsEnabled;
        ExportButton.IsEnabled=ExportJpeg.IsEnabled || ExportHdrJpeg.IsEnabled || ExportSdrJpeg.IsEnabled || ExportPng.IsEnabled || ExportDng.IsEnabled || ViewBatchMenu.IsEnabled;
        MenuExport.IsEnabled=ExportJpeg.IsEnabled;MenuBatch.IsEnabled=BatchExportMenu.IsEnabled;
        ApplyDraftButton.IsEnabled=CanApplyTransform;
        QueuePendingReset();
        MenuImportLook.IsEnabled=!exporting;
        RefreshWorkspaceAvailability();
        RefreshHistogramWorkspace();
        ClippingButton.IsEnabled=InfoButton.IsEnabled=file!=null && !exporting && ShowsPhotoWorkspace;
        ZoomButton.IsEnabled=file!=null && !exporting && ShowsPhotoWorkspace && !transform.Active;
        CompareButton.IsEnabled=CompareModeButton.IsEnabled=file!=null && !exporting && !transform.Active && ShowsPhotoWorkspace;
        InfoEntryButton.Visibility=file==null ? Visibility.Collapsed : Visibility.Visible;
        InfoEntryButton.IsEnabled=file!=null && !exporting;
        AdjustmentPanel.IsEnabled=!exporting;GpuMode.IsEnabled=!exporting && (file==null || !LibraryEntry.IsRaster(file));
        var busy=(scheduler.Busy && scheduler.Revision!=quietViewportRevision) || previewResize.IsEnabled || aiJob.State.IsRunning || processingMigrationBusy;
        BusyIndicator.Visibility=busy ? Visibility.Visible : Visibility.Collapsed;
        BusyAnimation.Visibility=SystemParameters.ClientAreaAnimation ? Visibility.Visible : Visibility.Collapsed;
        BusyStill.Visibility=SystemParameters.ClientAreaAnimation ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetItemStatus(BusyIndicator,Loc.Text(busy ? "正在显影…" : renderFailed ? "预览未更新" : "预览已更新"));
        RetryButton.Visibility=renderFailed && !scheduler.Busy && !exporting ? Visibility.Visible : Visibility.Collapsed;
        ExportButton.ToolTip=file==null ? Loc.Text("载入照片后可用") : transform.Active ? Loc.Text("草稿未应用，无法导出或复制设置。") :
            renderFailed ? Status.Text :
            !exactReady || scheduler.Busy || previewResize.IsEnabled ? Loc.Text("请等待预览完成后导出。") : Loc.Text("导出");
        ToolTipService.SetShowOnDisabled(ExportButton,true);
        ToolTipService.SetShowOnDisabled(ExportJpeg,true);ToolTipService.SetShowOnDisabled(ExportHdrJpeg,true);ToolTipService.SetShowOnDisabled(ExportSdrJpeg,true);ToolTipService.SetShowOnDisabled(ExportPng,true);ToolTipService.SetShowOnDisabled(ExportDng,true);
    }
    private void SetStatus(string text,bool error=false) { localizedStatus=null; Status.Text=text; Status.ToolTip=text; Status.SetResourceReference(TextBlock.ForegroundProperty,error ? "ErrorForeground" : "StatusForeground"); }
    private void SetStatus(Func<string> text,bool error=false) { SetStatus(text(),error); localizedStatus=text; }
    private void RefreshRenderLabels()
    {
        RefreshViewingFrames();
        // 没有显影结果：正在打开时说明在显影；空闲或失败时只留平台与色彩空间，不沿用过时的进度
        if (result == null) { BackendLabel.Text=file != null && !renderFailed ? Loc.Text("相机预览 · 正在显影") : "Windows · sRGB"; return; }
        BackendLabel.Text=result.HDR != null ? Loc.Text("HDR 显示不可用，当前显示 SDR。") :
            $"{(result.Backend==3 ? "Direct3D 11 · GPU" : renderedGpuMode==0 || (file!=null && LibraryEntry.IsRaster(file)) ? "CPU" : Loc.Text("CPU · GPU 已回退"))} · sRGB";
        var raster=file!=null && LibraryEntry.IsRaster(file);
        BaselineLabel.Text=result.HDR != null ? Loc.Text("SDR 兼容预览") : raster ? Loc.Text("显示图像") : Loc.Format("基础偏移 {0:+0.00;-0.00;0.00} EV", result.Baseline);
        AsShotButton.ToolTip=raster ? Loc.Text("不适用") : result.WhiteBalance==null ? Loc.Text("此 RAW 缺少有效校准，使用相机原始白平衡") : Loc.Format("拍摄时：{0} K / {1}", result.WhiteBalance.Value.Temperature.ToString("0.##", System.Globalization.CultureInfo.GetCultureInfo(Loc.Language)), result.WhiteBalance.Value.Tint.ToString("0.##", System.Globalization.CultureInfo.GetCultureInfo(Loc.Language)));
    }
    private void RetryClicked(object sender,RoutedEventArgs e)=>Schedule();
    private void Report(Exception error)=>SetStatus(error is DllNotFoundException or BadImageFormatException or EntryPointNotFoundException
        ? Loc.Text("无法加载显影组件。请通过 build.ps1 构建，并保留程序目录内的 DLL。") : error.Message,true);
}
