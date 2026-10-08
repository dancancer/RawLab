using System.Text.Json;
using RawLab.Windows;

static void Check(bool condition, string label)
{
    if (!condition) throw new Exception(label);
}
static string Payload(string tag, bool draft = false, bool preview = false, string asset = "RawLab-Windows-0.5.0-win-x64.zip") =>
    JsonSerializer.Serialize(new { tag_name = tag, draft, prerelease = preview, body = "Notes", assets = new[] { new { name = asset } } });
static UpdateRelease? Release(string tag) => UpdateRelease.Parse(Payload(tag), "0.4.0");
Check(Release("v0.10.0")?.Version == "0.10.0", "numeric comparison");
Check(Release("v0.4") == null, "historical two-part tag");
Check(Release("v0.3.9") == null, "never downgrade");
Check(Release("v0.4.1")?.Url == "https://github.com/dancancer/RawLab/releases/tag/v0.4.1", "release URL");
foreach (var tag in new[] { "v0.5.0-beta", "v0.5.0/evil", "bad", "0.-1.0" })
{
    var rejected = false;
    try { Release(tag); } catch (FormatException) { rejected = true; }
    Check(rejected, "invalid tag: " + tag);
}
Check(UpdateRelease.Parse(Payload("v0.5.0", draft: true), "0.4.0") == null, "draft");
Check(UpdateRelease.Parse(Payload("v0.5.0", preview: true), "0.4.0") == null, "preview");
Check(UpdateRelease.Parse(Payload("v0.5.0", asset: "RawLab-Android.apk"), "0.4.0") == null, "platform asset");
Check(UpdateRelease.ShouldCheck(true, false, 100, 101), "manual check bypasses opt-out");
Check(!UpdateRelease.ShouldCheck(false, false, 0, 100000), "automatic opt-out");
Check(!UpdateRelease.ShouldCheck(false, true, 100, 101), "daily interval");
Check(UpdateRelease.ShouldCheck(false, true, 100, 86500), "next day");
Check(UpdateRelease.ShouldCheck(false, true, 200, 100), "clock rollback");
Console.WriteLine("PASS: release validation, numeric versions, platform assets, manual and daily checks");

var directory = Path.Combine(Path.GetTempPath(), "RawLabUpdateTests-" + Guid.NewGuid());
Directory.CreateDirectory(directory);
try
{
    var calls = 0;
    var fail = false;
    using var client = new HttpClient(new Handler(_ => {
        calls++;
        return Task.FromResult(new HttpResponseMessage(fail ? System.Net.HttpStatusCode.TooManyRequests : System.Net.HttpStatusCode.OK)
            { Content = new StringContent(Payload("v0.5.0")) });
    }));
    var path = Path.Combine(directory, "updates.json");
    var checker = new UpdateChecker("0.4.0", path, client);
    Check(checker.Automatic, "default automatic checks");
    checker.Automatic = false;
    await checker.CheckAsync(false);
    Check(calls == 0, "opt-out does not request");
    await checker.CheckAsync(true);
    Check(calls == 1 && checker.Available?.Version == "0.5.0" && !checker.Checking, "manual result");
    Check(!new UpdateChecker("0.4.0", path, client).Automatic, "opt-out persists");
    checker.Automatic = true;
    await checker.CheckAsync(false);
    Check(calls == 1, "interval persisted");
    Check(new UpdateChecker("0.4.0", path, client).Available?.Version == "0.5.0", "cache survives restart");
    Check(new UpdateChecker("0.5.0", path, client).Available == null, "cache after upgrade");
    fail = true;
    await checker.CheckAsync(true);
    Check(calls == 2 && !checker.Checking && checker.Status.Contains("失败") && checker.Available != null, "HTTP failure retains known update");
    File.WriteAllText(path, "not JSON");
    Check(new UpdateChecker("0.4.0", path, client).Available == null, "corrupt preferences recover");
    var delayed = new TaskCompletionSource<HttpResponseMessage>();
    var delayedCalls = 0;
    using var delayedClient = new HttpClient(new Handler(_ => { delayedCalls++; return delayed.Task; }));
    var coalesced = new UpdateChecker("0.4.0", path, delayedClient);
    var task = coalesced.CheckAsync(true);
    await coalesced.CheckAsync(true);
    Check(delayedCalls == 1 && coalesced.Checking, "concurrent checks coalesce");
    delayed.SetResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(Payload("v0.5.0")) });
    await task;
    Check(!coalesced.Checking && coalesced.Available != null, "delayed result");
    var unwritable = new UpdateChecker("0.4.0", directory, client);
    unwritable.Automatic = false;
    Check(unwritable.Automatic && unwritable.StorageWarning.Length > 0, "failed preference write is visible and reverts");
    var callsBeforeUnwritableCheck = calls;
    await unwritable.CheckAsync(false);
    Check(calls == callsBeforeUnwritableCheck && !unwritable.Checking, "automatic check requires persisted throttle");
    Console.WriteLine("PASS: opt-out, persistence, cache, HTTP failure, corruption and concurrent checks");
}
finally { Directory.Delete(directory, true); }

sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
}
