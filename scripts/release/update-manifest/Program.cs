using System.Security.Cryptography;
using System.Text.Json;
using RawLab.Windows;

try {
    if (args.Length < 2) throw new ArgumentException("Usage: config trust.json | sign trust.json private.pem package version build minimum-version expires-at notes.txt output.json | verify trust.json manifest.json package current-version");
    var trust = UpdateTrustConfiguration.Parse(File.ReadAllText(args[1])) ?? throw new InvalidDataException("Invalid public update trust configuration");
    var feed = new Uri(trust.FeedUrl);
    if (feed.Host != "github.com" || !feed.AbsolutePath.StartsWith("/dancancer/RawLab/releases/", StringComparison.Ordinal) || feed.Port != 443)
        throw new InvalidDataException("Release feed must use the RawLab GitHub Release source");
    if (args[0] == "config" && args.Length == 2) { Console.WriteLine("PASS: public update trust configuration"); return 0; }
    string Hash(string path, HashAlgorithm algorithm) { using (algorithm) using (var stream = File.OpenRead(path)) return Convert.ToHexString(algorithm.ComputeHash(stream)); }
    if (args[0] == "sign" && args.Length == 10) {
        var package = Path.GetFullPath(args[3]); var name = Path.GetFileName(package); var now = DateTimeOffset.UtcNow;
        var payload = new SignedUpdatePayload(1, "RawLab.Desktop", "windows", "x64", "stable", args[4], args[5], args[6],
            now, DateTimeOffset.Parse(args[7]), $"https://github.com/dancancer/RawLab/releases/download/v{args[4]}/{name}", name,
            new FileInfo(package).Length, Hash(package, SHA256.Create()), Hash(package, SHA1.Create()), File.ReadAllText(args[8]));
        var bytes = JsonSerializer.SerializeToUtf8Bytes(payload);
        using var key = ECDsa.Create(); key.ImportFromPem(File.ReadAllText(args[2]));
        if (Convert.ToBase64String(key.ExportSubjectPublicKeyInfo()) != trust.PublicKey) throw new CryptographicException("Private key does not match configured public key");
        var envelope = JsonSerializer.SerializeToUtf8Bytes(new { Format = 1, Payload = Convert.ToBase64String(bytes),
            Signature = Convert.ToBase64String(key.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.Rfc3279DerSequence)) });
        _ = SignedUpdateManifest.Verify(envelope, trust, args[6], now);
        UpdatePackageVerifier.Verify(package, payload, trust.PublisherKeySha256);
        using var output = new FileStream(args[9], FileMode.CreateNew); output.Write(envelope);
        Console.WriteLine("PASS: signed descriptor and package verified with configured public key"); return 0;
    }
    if (args[0] == "verify" && args.Length == 5) {
        var manifest = SignedUpdateManifest.Verify(File.ReadAllBytes(args[2]), trust, args[4], DateTimeOffset.UtcNow);
        UpdatePackageVerifier.Verify(args[3], manifest, trust.PublisherKeySha256);
        Console.WriteLine("PASS: descriptor signature and package verified"); return 0;
    }
    throw new ArgumentException("Invalid command arguments; sign also requires a UTF-8 release-notes file before output.json");
} catch (Exception error) { Console.Error.WriteLine(error.Message); return 1; }
