using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace RawLab.Windows;

public sealed class TemporaryUpdateTrustException(string message) : IOException(message);

public static class AuthenticodeTrust
{
    private static readonly Guid VerifyAction = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
    public static void Verify(string path, string publisherKeySha256)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
        var file = new FileInfoData { Size = (uint)Marshal.SizeOf<FileInfoData>(), FilePath = path };
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<FileInfoData>());
        try
        {
            Marshal.StructureToPtr(file, pointer, false);
            var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UiChoice = 2, RevocationChecks = 1,
                UnionChoice = 1, File = pointer, StateAction = 1, ProviderFlags = 0x80 };
            var action = VerifyAction;
            try
            {
                var status = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                if (unchecked((uint)status) is 0x80092013 or 0x800B010E)
                    throw new TemporaryUpdateTrustException("Certificate revocation status is temporarily unavailable");
                if (status != 0) throw new CryptographicException("Authenticode validation failed");
            }
            finally { data.StateAction = 2; _ = WinVerifyTrust(new IntPtr(-1), ref action, ref data); }
        }
        finally { Marshal.DestroyStructure<FileInfoData>(pointer); Marshal.FreeHGlobal(pointer); }
        using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
        var hash = SHA256.HashData(certificate.PublicKey.ExportSubjectPublicKeyInfo());
        if (!CryptographicOperations.FixedTimeEquals(hash, Convert.FromHexString(publisherKeySha256)))
            throw new CryptographicException("Unexpected update publisher");
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct FileInfoData
    {
        public uint Size;
        [MarshalAs(UnmanagedType.LPWStr)] public string FilePath;
        public IntPtr FileHandle;
        public IntPtr KnownSubject;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct TrustData
    {
        public uint Size;
        public IntPtr PolicyCallbackData, SipClientData;
        public uint UiChoice, RevocationChecks, UnionChoice;
        public IntPtr File;
        public uint StateAction;
        public IntPtr StateData, UrlReference;
        public uint ProviderFlags, UiContext;
        public IntPtr SignatureSettings;
    }
    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
}
