using System.Windows;

namespace RawLab.Windows;
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        Loc.Initialize();
        void ApplyLanguage() { foreach (var pair in Loc.Strings) Resources[pair.Key] = pair.Value; }
        ApplyLanguage();
        Loc.Changed += ApplyLanguage;
        base.OnStartup(e);
    }
}
