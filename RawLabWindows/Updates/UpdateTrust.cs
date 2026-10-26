using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace RawLab.Windows;

public sealed record UpdateTrustConfiguration(string FeedUrl, string PublicKey, string PublisherKeySha256)
{
    public static UpdateTrustConfiguration? Load()
    {
        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream("RawLab.UpdateTrust.json");
        if (source == null) return null;
        using var reader = new StreamReader(source); return Parse(reader.ReadToEnd());
    }
    public static UpdateTrustConfiguration? Parse(string json)
    {
        try { var value = JsonSerializer.Deserialize<UpdateTrustConfiguration>(json); return value?.IsValid == true ? value : null; }
        catch (JsonException) { return null; }
    }
    public bool IsValid
    {
        get
        {
            try
            {
                if (!Uri.TryCreate(FeedUrl, UriKind.Absolute, out var url) || url.Scheme != "https" || url.Host.Length == 0 || url.UserInfo.Length != 0 ||
                    string.IsNullOrWhiteSpace(PublicKey) || PublisherKeySha256 == null ||
                    (PublisherKeySha256.Length != 0 && !Regex.IsMatch(PublisherKeySha256, "\\A[a-fA-F0-9]{64}\\z"))) return false;
                using var key = ECDsa.Create(); var bytes = Convert.FromBase64String(PublicKey);
                key.ImportSubjectPublicKeyInfo(bytes, out var consumed);
                return consumed == bytes.Length && key.ExportParameters(false).Curve.Oid.Value == "1.2.840.10045.3.1.7";
            }
            catch (Exception error) when (error is FormatException or CryptographicException or ArgumentException) { return false; }
        }
    }
}

public sealed record SignedUpdatePayload(int Format, string PackageId, string Platform, string Architecture, string Channel,
    string Version, string Build, string MinimumVersion, DateTimeOffset IssuedAt, DateTimeOffset ExpiresAt,
    string AssetUrl, string FileName, long Size, string Sha256, string Sha1, string Notes)
{
    public UpdateDescriptor Descriptor => new(Version, Build, Platform, Architecture, Channel, AssetUrl, Size, Sha256, Notes);
}

public static class SignedUpdateManifest
{
    private sealed record Envelope(int Format, string Payload, string Signature);
    public static SignedUpdatePayload Verify(ReadOnlySpan<byte> data, UpdateTrustConfiguration trust, string currentVersion, DateTimeOffset now)
    {
        if (data.Length > 1024 * 1024 || !trust.IsValid) throw new InvalidDataException("Invalid update configuration or descriptor size");
        var envelope = JsonSerializer.Deserialize<Envelope>(data) ?? throw new InvalidDataException("Missing envelope");
        if (envelope.Format != 1) throw new InvalidDataException("Unsupported envelope");
        var bytes = Convert.FromBase64String(envelope.Payload);
        using var key = ECDsa.Create();
        key.ImportSubjectPublicKeyInfo(Convert.FromBase64String(trust.PublicKey), out var consumed);
        if (consumed != Convert.FromBase64String(trust.PublicKey).Length || key.KeySize != 256 ||
            !key.VerifyData(bytes, Convert.FromBase64String(envelope.Signature), HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence))
            throw new CryptographicException("Untrusted update descriptor");
        var value = JsonSerializer.Deserialize<SignedUpdatePayload>(bytes) ?? throw new InvalidDataException("Missing signed payload");
        if (value.Format != 1 || value.PackageId != "RawLab.Desktop" || value.Platform != "windows" || value.Architecture != "x64" || value.Channel != "stable" ||
            value.IssuedAt > now.AddMinutes(5) || value.ExpiresAt <= now || value.ExpiresAt <= value.IssuedAt ||
            value.Size <= 0 || value.Size > 4L * 1024 * 1024 * 1024 ||
            !Regex.IsMatch(value.Version, "\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z") || !Version.TryParse(value.Version, out var nextVersion) ||
            !Version.TryParse(value.MinimumVersion, out var minimum) || !Version.TryParse(currentVersion, out var current) || current < minimum || current > nextVersion ||
            !int.TryParse(value.Build, out var build) || build < 1 ||
            !Regex.IsMatch(value.FileName, "\\A[A-Za-z0-9][A-Za-z0-9._-]*-full\\.nupkg\\z") ||
            !Regex.IsMatch(value.Sha256, "\\A[a-fA-F0-9]{64}\\z") || !Regex.IsMatch(value.Sha1, "\\A[a-fA-F0-9]{40}\\z"))
            throw new InvalidDataException("Unsupported or expired update descriptor");
        var feed = new Uri(trust.FeedUrl);
        if (!Uri.TryCreate(value.AssetUrl, UriKind.Absolute, out var asset) || asset.Scheme != "https" || asset.UserInfo.Length != 0 ||
            asset.Host != feed.Host || asset.Port != feed.Port || Uri.UnescapeDataString(Path.GetFileName(asset.AbsolutePath)) != value.FileName)
            throw new InvalidDataException("Update asset is outside the configured source");
        return value;
    }
}
