using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using RawLab.Windows;
using Velopack.Logging;

static void Check(bool value, string message) { if (!value) throw new Exception(message); Console.WriteLine("PASS " + message); }
static bool Reject(Action work) { try { work(); return false; } catch { return true; } }
using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
using var wrong = ECDsa.Create(ECCurve.NamedCurves.nistP256);
var trust = new UpdateTrustConfiguration("https://updates.example.invalid/stable.json", Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()), new string('a', 64));
Check(trust.IsValid && !((trust with { PublicKey = "invalid" }).IsValid) && UpdateTrustConfiguration.Parse("broken") == null,
    "Malformed release configuration is unavailable without throwing");
Check((trust with { PublisherKeySha256 = "" }).IsValid &&
    !(trust with { PublisherKeySha256 = "invalid" }).IsValid && !(trust with { FeedUrl = "" }).IsValid,
    "Manifest-only mode permits an empty publisher pin and still requires a valid feed and metadata key");
using var wrongCurve = ECDsa.Create(ECCurve.NamedCurves.nistP384);
Check(!(trust with { PublicKey = Convert.ToBase64String(wrongCurve.ExportSubjectPublicKeyInfo()) }).IsValid, "Only the pinned P-256 metadata key format is supported");
var bytes = new byte[] { 1, 2, 3, 4, 5, 6 };
var now = new DateTimeOffset(2026, 10, 25, 0, 0, 0, TimeSpan.Zero);
var payload = new SignedUpdatePayload(1, "RawLab.Desktop", "windows", "x64", "stable", "0.9.1", "19", "0.8.2", now.AddMinutes(-1), now.AddDays(7),
    "https://updates.example.invalid/RawLab.Desktop-0.9.1-full.nupkg", "RawLab.Desktop-0.9.1-full.nupkg", bytes.Length,
    Convert.ToHexString(SHA256.HashData(bytes)), Convert.ToHexString(SHA1.HashData(bytes)), "Signed release notes");
byte[] Signed(SignedUpdatePayload value, ECDsa? signingKey = null)
{
    var data = JsonSerializer.SerializeToUtf8Bytes(value);
    return JsonSerializer.SerializeToUtf8Bytes(new { Format = 1, Payload = Convert.ToBase64String(data), Signature = Convert.ToBase64String(
        (signingKey ?? key).SignData(data, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)) });
}
Check(SignedUpdateManifest.Verify(Signed(payload), trust, "0.8.2", now) == payload, "Pinned key validates exact descriptor bytes");
Check(Reject(() => SignedUpdateManifest.Verify(Signed(payload, wrong), trust, "0.8.2", now)), "Wrong signing key is rejected");
var signed = Signed(payload); signed[^8] ^= 1;
Check(Reject(() => SignedUpdateManifest.Verify(signed, trust, "0.8.2", now)), "Altered signature is rejected");
foreach (var invalid in new[] { payload with { Architecture = "arm64" }, payload with { Channel = "beta" }, payload with { PackageId = "Other" },
    payload with { ExpiresAt = now.AddSeconds(-1) }, payload with { IssuedAt = now.AddDays(1) }, payload with { MinimumVersion = "0.9.0" },
    payload with { AssetUrl = "https://attacker.invalid/RawLab.Desktop-0.9.1-full.nupkg" }, payload with { FileName = "../RawLab-full.nupkg" },
    payload with { Version = "0.8.1" }, payload with { Sha256 = "not-a-hash" }, payload with { Size = -1 } })
    Check(Reject(() => SignedUpdateManifest.Verify(Signed(invalid), trust, "0.8.2", now)), "Signed but incompatible descriptor is rejected");
var handler = new FixtureHandler(() => Signed(payload), () => bytes);
var source = new SignedUpdateSource(trust, "0.8.2", new HttpClient(handler), () => now);
var logger = new NullLogger();
var feed = await source.GetReleaseFeed(logger, "RawLab.Desktop", "stable");
Check(feed.Assets.Length == 1 && feed.Assets[0].SHA256 == payload.Sha256, "Velopack source only exposes the verified asset");
var path = Path.Combine(Path.GetTempPath(), "rawlab-update-source-" + Guid.NewGuid().ToString("N") + ".nupkg");
try
{
    var progress = 0;
    await source.DownloadReleaseEntry(logger, feed.Assets[0], path, value => progress = value);
    Check(File.ReadAllBytes(path).SequenceEqual(bytes) && progress == 100, "Source downloads and verifies signed hash and size");
    handler.CorruptPackage = true; var rejected = false;
    try { await source.DownloadReleaseEntry(logger, feed.Assets[0], path, _ => { }); } catch (CryptographicException) { rejected = true; }
    Check(rejected && !File.Exists(path), "Corrupt package is rejected and partial data removed");
    handler.CorruptPackage = false;
    using var cancel = new CancellationTokenSource(); cancel.Cancel(); rejected = false;
    try { await source.DownloadReleaseEntry(logger, feed.Assets[0], path, _ => { }, cancel.Token); } catch (OperationCanceledException) { rejected = true; }
    Check(rejected, "Cancellation reaches the actual update source");
}
finally { if (File.Exists(path)) File.Delete(path); }
await RedirectChecks.Run(trust, payload, now, value => Signed(value), bytes, Check);
await ControllerChecks.Run(Check);
Check(Reject(() => AuthenticodeTrust.Verify(Environment.ProcessPath!, trust.PublisherKeySha256)), "Unsigned test executable cannot pass production Authenticode admission");
if(args is ["--offline",var directory])await OfflineManagerChecks.Run(directory,Check);

sealed class FixtureHandler(Func<byte[]> manifest, Func<byte[]> package) : HttpMessageHandler
{
    public bool CorruptPackage { get; set; }
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var bytes = request.RequestUri!.AbsolutePath.EndsWith(".json") ? manifest() : package();
        if (CorruptPackage && !request.RequestUri.AbsolutePath.EndsWith(".json")) { bytes = (byte[])bytes.Clone(); bytes[0] ^= 1; }
        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });
    }
}

sealed class NullLogger : IVelopackLogger
{
    public void Log(VelopackLogLevel logLevel, string? message, Exception? exception) { }
}
