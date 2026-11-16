using RawLab.Windows;

if (args.Length == 3 && args[0] == "--crash-recovery") { UpdateStoreChecks.Crash(args[1], args[2]); return; }

static void Check(bool condition, string label)
{
    if (!condition) throw new Exception(label);
}

InstallStateChecks.Run(Check);
UpdateStoreChecks.Run(Check);
Console.WriteLine("PASS: persisted update state, stale callbacks, cancellation and installation gate");
