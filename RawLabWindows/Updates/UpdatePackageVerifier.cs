using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection.PortableExecutable;
using System.Security.Cryptography;

namespace RawLab.Windows;

public static class UpdatePackageVerifier
{
    public static void Verify(string path, SignedUpdatePayload manifest, string publisherKeySha256)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (input.Length != manifest.Size || !CryptographicOperations.FixedTimeEquals(SHA256.HashData(input), Convert.FromHexString(manifest.Sha256)))
            throw new CryptographicException("Cached package no longer matches signed descriptor");
        input.Position = 0;
        using var zip = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: true);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in zip.Entries)
        {
            var name = entry.FullName.Replace('\\', '/');
            var parts = name.TrimEnd('/').Split('/');
            if (parts.Any(part => part.Length == 0 || part is "." or ".." || part.Contains(':')) || !names.Add(name.TrimEnd('/')) ||
                ((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000)
                throw new InvalidDataException("Unsafe package entry");
        }
        var executables = zip.Entries.Where(entry => entry.FullName.StartsWith("lib/", StringComparison.Ordinal) &&
            entry.FullName.EndsWith("/RawLab.exe", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (executables.Length != 1) throw new InvalidDataException("Package has no unique RawLab executable");
        var executable = executables[0];
        var assembly = zip.GetEntry(executable.FullName[..^3] + "dll") ?? throw new InvalidDataException("Package has no RawLab assembly");
        var temporary = Path.Combine(Path.GetTempPath(), "rawlab-update-verify-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(temporary);
        try
        {
            foreach (var entry in new[] { executable, assembly })
            {
                if (entry.Length > 256L * 1024 * 1024) throw new InvalidDataException("Unexpected executable size");
                var extracted = Path.Combine(temporary, Path.GetFileName(entry.FullName));
                entry.ExtractToFile(extracted);
                AuthenticodeTrust.Verify(extracted, publisherKeySha256);
                var version = FileVersionInfo.GetVersionInfo(extracted);
                if ($"{version.FileMajorPart}.{version.FileMinorPart}.{version.FileBuildPart}" != manifest.Version || version.FilePrivatePart.ToString() != manifest.Build)
                    throw new InvalidDataException("Package version differs from signed descriptor");
                using var file = File.OpenRead(extracted); using var pe = new PEReader(file);
                if (pe.PEHeaders.CoffHeader.Machine != Machine.Amd64) throw new InvalidDataException("Package architecture differs from signed descriptor");
            }
        }
        finally { Directory.Delete(temporary, recursive: true); }
    }
}
