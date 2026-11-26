using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace RawLab.Windows;

public sealed class BwMixerPanel : StackPanel
{
    private static readonly (string Key, string Id)[] Channels = [
        ("红", "red"), ("橙", "orange"), ("黄", "yellow"), ("绿", "green"),
        ("青", "aqua"), ("蓝", "blue"), ("紫", "purple"), ("洋红", "magenta")
    ];

    private BwMixerSettings settings = new();
    private object? source;
    private bool syncing;

    private readonly CheckBox enabledToggle = new() { Margin = new Thickness(0, 2, 0, 6) };
    private readonly ParameterRow[] rows = Enumerable.Range(0, 8).Select(_ => new ParameterRow()).ToArray();
    private readonly Button reset = new();

    public event Action<BwMixerSettings, bool>? Changed;
    public event Action? ResetRequested;

    public BwMixerPanel()
    {
        MaxWidth = 720;
        Margin = new Thickness(4);

        AutomationProperties.SetAutomationId(enabledToggle, "bwMixer.enabled");
        enabledToggle.Click += (_, _) =>
        {
            if (syncing || !IsEnabled) return;
            settings = settings with { Enabled = enabledToggle.IsChecked == true };
            Refresh(settings, source);
            Changed?.Invoke(settings, false);
        };
        Children.Add(enabledToggle);

        for (var i = 0; i < Channels.Length; i++)
        {
            var idx = i;
            Children.Add(rows[idx]);
            AutomationProperties.SetAutomationId(rows[idx].Number, $"bwMixer.value.{Channels[idx].Id}");
            rows[idx].Changed += (value, dragging) =>
            {
                if (syncing || !IsEnabled) return;
                settings = settings with { Mixer = WithChannel(settings.Mixer, idx, value) };
                Refresh(settings, source);
                Changed?.Invoke(settings, dragging);
            };
        }

        var actions = new WrapPanel { HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 4, 0, 0) };
        AutomationProperties.SetAutomationId(reset, "bwMixer.reset");
        reset.Click += (_, _) => { if (!syncing && IsEnabled) ResetRequested?.Invoke(); };
        actions.Children.Add(reset);
        Children.Add(actions);

        IsVisibleChanged += (_, _) => { if (!IsVisible) CancelInputs(); };
        RefreshLanguage();
    }

    private static double ChannelValue(BwMixerWeights mixer, int index) => index switch
    {
        0 => mixer.Red,
        1 => mixer.Orange,
        2 => mixer.Yellow,
        3 => mixer.Green,
        4 => mixer.Aqua,
        5 => mixer.Blue,
        6 => mixer.Purple,
        _ => mixer.Magenta
    };

    private static BwMixerWeights WithChannel(BwMixerWeights mixer, int index, double value) => index switch
    {
        0 => mixer with { Red = value },
        1 => mixer with { Orange = value },
        2 => mixer with { Yellow = value },
        3 => mixer with { Green = value },
        4 => mixer with { Aqua = value },
        5 => mixer with { Blue = value },
        6 => mixer with { Purple = value },
        _ => mixer with { Magenta = value }
    };

    public void CancelInputs()
    {
        foreach (var row in rows) row.CancelInput();
    }

    public void RefreshLanguage()
    {
        var title = Loc.Text("启用黑白");
        enabledToggle.Content = title;
        AutomationProperties.SetName(enabledToggle, title);
        reset.Content = Loc.Text("重置");
        AutomationProperties.SetName(reset, Loc.Format("重置{0}", Loc.Text("黑白")));
        Refresh(settings, source);
    }

    public void Refresh(BwMixerSettings next, object? identity)
    {
        syncing = true;
        try
        {
            if (!Equals(source, identity)) CancelInputs();
            source = identity;
            settings = next;
            enabledToggle.IsChecked = next.Enabled;
            AutomationProperties.SetItemStatus(enabledToggle, Loc.Text(next.Enabled ? "开启" : "关闭"));
            var range = new NumericRange(-100, 100);
            for (var i = 0; i < Channels.Length; i++)
            {
                rows[i].SourceIdentity = identity;
                rows[i].Refresh(Loc.Text(Channels[i].Key), range, ChannelValue(next.Mixer, i), 0, inputScope: "bwMixer");
            }
            reset.IsEnabled = !next.IsDefault;
        }
        finally
        {
            syncing = false;
        }
    }
}
