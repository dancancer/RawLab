using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

public sealed class SelectiveColorPanel : StackPanel
{
    private static readonly (string Key, string Id)[] BandDescriptors = [
        ("红色", "reds"), ("黄色", "yellows"), ("绿色", "greens"),
        ("青色", "cyans"), ("蓝色", "blues"), ("洋红色", "magentas"),
        ("白色", "whites"), ("中性色", "neutrals"), ("黑色", "blacks")
    ];
    private static readonly (string Key, string Id)[] ComponentDescriptors = [
        ("青色 (C)", "cyan"), ("洋红 (M)", "magenta"), ("黄色 (Y)", "yellow"), ("黑色 (K)", "black")
    ];

    private SelectiveColorSettings settings = new();
    private int selectedBand;
    private object? source;
    private bool syncing;

    private readonly Button relativeButton = new() { MinHeight = 30, Margin = new Thickness(2) };
    private readonly Button absoluteButton = new() { MinHeight = 30, Margin = new Thickness(2) };
    private readonly Button[] bandButtons = Enumerable.Range(0, 9).Select(_ => new Button { MinHeight = 28, Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(2) }).ToArray();
    private readonly ParameterRow[] rows = Enumerable.Range(0, 4).Select(_ => new ParameterRow()).ToArray();
    private readonly Button reset = new();

    public event Action<SelectiveColorSettings, bool>? Changed;
    public event Action? ResetRequested;

    public SelectiveColorPanel()
    {
        MaxWidth = 720;
        Margin = new Thickness(4);

        var methods = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        AutomationProperties.SetAutomationId(relativeButton, "selectiveColor.method.relative");
        AutomationProperties.SetAutomationId(absoluteButton, "selectiveColor.method.absolute");
        relativeButton.Click += (_, _) => SetMethod(SelectiveColorMethod.Relative);
        absoluteButton.Click += (_, _) => SetMethod(SelectiveColorMethod.Absolute);
        methods.Children.Add(relativeButton);
        methods.Children.Add(absoluteButton);
        Children.Add(methods);

        var bands = new WrapPanel { Margin = new Thickness(0, 0, 0, 6) };
        bands.PreviewMouseDown += (_, _) => CancelInputs();
        for (var i = 0; i < BandDescriptors.Length; i++)
        {
            var idx = i;
            var btn = bandButtons[idx];
            AutomationProperties.SetAutomationId(btn, $"selectiveColor.band.{BandDescriptors[idx].Id}");
            btn.Click += (_, _) =>
            {
                if (syncing || selectedBand == idx) return;
                CancelInputs();
                selectedBand = idx;
                Refresh(settings, source);
            };
            bands.Children.Add(btn);
        }
        Children.Add(bands);

        for (var i = 0; i < ComponentDescriptors.Length; i++)
        {
            var comp = i;
            Children.Add(rows[comp]);
            AutomationProperties.SetAutomationId(rows[comp].Number, $"selectiveColor.value.{ComponentDescriptors[comp].Id}");
            rows[comp].Changed += (value, dragging) =>
            {
                if (syncing || !IsEnabled) return;
                var band = GetBand(settings.Bands, selectedBand);
                var updatedBand = WithComponent(band, comp, value);
                settings = settings with { Bands = WithBand(settings.Bands, selectedBand, updatedBand) };
                Refresh(settings, source);
                Changed?.Invoke(settings, dragging);
            };
        }

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 0, 0) };
        AutomationProperties.SetAutomationId(reset, "selectiveColor.reset");
        reset.Click += (_, _) => { if (!syncing && IsEnabled) ResetRequested?.Invoke(); };
        actions.Children.Add(reset);
        Children.Add(actions);

        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelInputs(); };
        RefreshLanguage();
    }

    private void SetMethod(SelectiveColorMethod method)
    {
        if (syncing || !IsEnabled || settings.Method == method) return;
        CancelInputs();
        settings = settings with { Method = method };
        Refresh(settings, source);
        Changed?.Invoke(settings, false);
    }

    private static SelectiveColorBand GetBand(SelectiveColorBands bands, int index) => index switch
    {
        0 => bands.Reds,
        1 => bands.Yellows,
        2 => bands.Greens,
        3 => bands.Cyans,
        4 => bands.Blues,
        5 => bands.Magentas,
        6 => bands.Whites,
        7 => bands.Neutrals,
        _ => bands.Blacks
    };

    private static SelectiveColorBands WithBand(SelectiveColorBands bands, int index, SelectiveColorBand band) => index switch
    {
        0 => bands with { Reds = band },
        1 => bands with { Yellows = band },
        2 => bands with { Greens = band },
        3 => bands with { Cyans = band },
        4 => bands with { Blues = band },
        5 => bands with { Magentas = band },
        6 => bands with { Whites = band },
        7 => bands with { Neutrals = band },
        _ => bands with { Blacks = band }
    };

    private static double GetComponent(SelectiveColorBand band, int comp) => comp switch
    {
        0 => band.Cyan,
        1 => band.Magenta,
        2 => band.Yellow,
        _ => band.Black
    };

    private static SelectiveColorBand WithComponent(SelectiveColorBand band, int comp, double value) => comp switch
    {
        0 => band with { Cyan = value },
        1 => band with { Magenta = value },
        2 => band with { Yellow = value },
        _ => band with { Black = value }
    };

    public void CancelInputs()
    {
        foreach (var row in rows) row.CancelInput();
    }

    public void RefreshLanguage()
    {
        relativeButton.Content = Loc.Text("相对");
        absoluteButton.Content = Loc.Text("绝对");
        AutomationProperties.SetName(relativeButton, Loc.Text("相对"));
        AutomationProperties.SetName(absoluteButton, Loc.Text("绝对"));
        reset.Content = Loc.Text("重置");
        AutomationProperties.SetName(reset, Loc.Format("重置{0}", Loc.Text("可选颜色")));
        Refresh(settings, source);
    }

    public void Refresh(SelectiveColorSettings next, object? identity)
    {
        syncing = true;
        try
        {
            if (!Equals(source, identity)) { CancelInputs(); selectedBand = 0; }
            source = identity;
            settings = next;

            relativeButton.Tag = next.Method == SelectiveColorMethod.Relative ? "selected" : null;
            absoluteButton.Tag = next.Method == SelectiveColorMethod.Absolute ? "selected" : null;

            for (var i = 0; i < BandDescriptors.Length; i++)
            {
                var band = GetBand(next.Bands, i);
                var title = Loc.Text(BandDescriptors[i].Key);
                bandButtons[i].Content = title + (band.IsDefault ? "" : " •");
                bandButtons[i].Tag = i == selectedBand ? "selected" : null;
                AutomationProperties.SetName(bandButtons[i], title);
                AutomationProperties.SetItemStatus(bandButtons[i], Loc.Text(band.IsDefault ? "未调整" : "已调整"));
            }

            var currentBand = GetBand(next.Bands, selectedBand);
            var range = new NumericRange(-100, 100);
            for (var i = 0; i < ComponentDescriptors.Length; i++)
            {
                rows[i].SourceIdentity = identity;
                rows[i].Refresh(Loc.Text(ComponentDescriptors[i].Key), range, GetComponent(currentBand, i), 0, inputScope: selectedBand);
            }
            reset.IsEnabled = !next.IsDefault;
        }
        finally
        {
            syncing = false;
        }
    }
}
