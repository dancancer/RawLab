using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using Velopack;
using Velopack.Logging;
using Velopack.Sources;

namespace RawLab.Windows;

public sealed class SignedUpdateSource : IUpdateSource
{
    private readonly UpdateTrustConfiguration trust;
    private readonly string currentVersion;
    private readonly HttpClient client;
    private readonly Func<DateTimeOffset> now;
    public SignedUpdatePayload? Manifest { get; private set; }
    public CancellationToken CheckCancellation { get; set; }
    public SignedUpdateSource(UpdateTrustConfiguration trust, string currentVersion, HttpClient? client = null, Func<DateTimeOffset>? now = null)
    {
        this.trust = trust; this.currentVersion = currentVersion;
        this.client = client ?? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromMinutes(20) };
        this.now = now ?? (() => DateTimeOffset.UtcNow);
    }
    public async Task<VelopackAssetFeed> GetReleaseFeed(IVelopackLogger logger, string? appId, string channel, Guid? stagingId = null, VelopackAsset? latestLocalRelease = null)
    {
        if ((appId != null && appId != "RawLab.Desktop") || channel != "stable") throw new InvalidDataException("Unsupported application or channel");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(CheckCancellation); timeout.CancelAfter(TimeSpan.FromSeconds(30));
        using var response = await client.GetAsync(trust.FeedUrl, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
        response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
        using var memory = new MemoryStream();
        var buffer = new byte[16 * 1024]; int count;
        while ((count = await stream.ReadAsync(buffer, timeout.Token)) > 0)
        {
            if (memory.Length + count > 1024 * 1024) throw new InvalidDataException("Update descriptor is too large");
            memory.Write(buffer, 0, count);
        }
        Manifest = SignedUpdateManifest.Verify(memory.ToArray(), trust, currentVersion, now());
        return new VelopackAssetFeed { Assets = [Asset(Manifest)] };
    }
    public async Task DownloadReleaseEntry(IVelopackLogger logger, VelopackAsset releaseEntry, string localFile, Action<int> progress, CancellationToken cancelToken = default)
    {
        var manifest = Manifest ?? throw new InvalidOperationException("Check the signed feed first");
        if (releaseEntry != Asset(manifest) || manifest.ExpiresAt <= now()) throw new InvalidDataException("Package does not match the verified descriptor");
        using var response = await client.GetAsync(manifest.AssetUrl, HttpCompletionOption.ResponseHeadersRead, cancelToken);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is { } length && length != manifest.Size) throw new InvalidDataException("Unexpected package size");
        try
        {
            await using var input = await response.Content.ReadAsStreamAsync(cancelToken);
            await using var output = new FileStream(localFile, FileMode.Create, FileAccess.Write, FileShare.None, 1024 * 1024, FileOptions.Asynchronous | FileOptions.WriteThrough);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[1024 * 1024]; long received = 0; int count;
            while ((count = await input.ReadAsync(buffer, cancelToken)) > 0)
            {
                received += count;
                if (received > manifest.Size) throw new InvalidDataException("Package exceeds signed size");
                hash.AppendData(buffer, 0, count); await output.WriteAsync(buffer.AsMemory(0, count), cancelToken);
                progress((int)Math.Min(99, received * 100 / manifest.Size));
            }
            if (received != manifest.Size || !CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(manifest.Sha256)))
                throw new CryptographicException("Package checksum differs from signed descriptor");
            output.Flush(true); progress(100);
        }
        catch { try { File.Delete(localFile); } catch (IOException) { } throw; }
    }
    private static VelopackAsset Asset(SignedUpdatePayload value) => new() {
        PackageId = value.PackageId, Version = SemanticVersion.Parse(value.Version), Type = VelopackAssetType.Full,
        FileName = value.FileName, SHA1 = value.Sha1, SHA256 = value.Sha256, Size = value.Size, NotesMarkdown = value.Notes, NotesHTML = ""
    };
}
