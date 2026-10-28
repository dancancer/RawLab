namespace RawLab.Windows;

public sealed record UpdateSessionStatus(bool Draft = false, bool Unsaved = false, bool SaveFailed = false,
    bool TasksRunning = false, bool JournalFailed = false);

public sealed class UpdateInstallGate
{
    private sealed record Entry(WeakReference<object> Owner, Func<UpdateSessionStatus> Status, Func<bool> Save);
    private readonly List<Entry> entries = [];
    public void Register(object owner, Func<UpdateSessionStatus> status, Func<bool> save)
    {
        Unregister(owner); entries.Add(new(new(owner), status, save));
    }
    public void Unregister(object owner) => entries.RemoveAll(entry => !entry.Owner.TryGetTarget(out var target) || ReferenceEquals(target, owner));
    private Entry[] Active()
    {
        entries.RemoveAll(entry => !entry.Owner.TryGetTarget(out _)); return entries.ToArray();
    }
    public string[] Blockers() => Active().SelectMany(entry => {
        var value = entry.Status();
        return new[] { (value.Draft, "draft"), (value.Unsaved, "unsaved"), (value.SaveFailed, "save"),
            (value.TasksRunning, "tasks"), (value.JournalFailed, "journal") }.Where(pair => pair.Item1).Select(pair => pair.Item2);
    }).Distinct().Order().ToArray();
    public string[] Prepare()
    {
        var before = Blockers();
        if (before.Intersect(["draft", "tasks"]).Any()) return before;
        var failed = false;
        foreach (var entry in Active())
        {
            if (!entry.Save()) failed = true;
        }
        return Blockers().Concat(failed ? ["save"] : Array.Empty<string>()).Distinct().Order().ToArray();
    }
}
