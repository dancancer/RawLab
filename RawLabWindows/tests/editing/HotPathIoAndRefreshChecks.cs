using System.ComponentModel;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using RawLab.Windows;

internal static class HotPathIoAndRefreshChecks
{
    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    public static void Run()
    {
        S3EditStoreRegistryCacheChecks();
        S3ResourceDigestCacheChecks();
        WindowsDigestChangeMarkerChecks();
        S3PhotoProbeCacheChecks();
        W6ViewSourceStateChecks();
        W6LookAvailabilityAndHDRPresentationChecks();
        M4AIDenoiseCachedIdentityChecks();
        W16InspectorModificationAndSubEditorChecks();
        W16ParameterRowLayoutCacheChecks();
        Console.WriteLine("PASS: P2-19/P2-21/S3 Windows UI hot-path sync I/O elimination and caching checks");
    }

    private static void S3EditStoreRegistryCacheChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-s3-editstore-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var editsDir = Path.Combine(root, "edits");
            var photoA = Path.Combine(root, "photo-a.arw");
            var photoB = Path.Combine(root, "photo-b.arw");
            File.WriteAllBytes(photoA, [1, 2, 3, 4]);
            File.WriteAllBytes(photoB, [5, 6, 7, 8, 9]);

            var storeA = new EditStore(editsDir);
            var storeB = new EditStore(editsDir);
            var initialA = storeA.ReadState(photoA);
            var initialB = storeA.ReadState(photoB);

            var modifiedA = new Adjustments();
            modifiedA.Set(Parameter.Exposure, 0.75);
            storeA.SaveState(initialA.Identity, new SavedEdit(initialA.Identity, modifiedA.Capture(), null));

            var modifiedB = new Adjustments();
            modifiedB.Set(Parameter.Contrast, 1.22);
            storeA.SaveState(initialB.Identity, new SavedEdit(initialB.Identity, modifiedB.Capture(), null));

            // Hot ReadState hits in-process RegistryCache without re-reading edits.json.
            var readsBefore = storeA.DiskReadCount;
            for (var i = 0; i < 25; i++)
            {
                var read = storeA.ReadState(photoA);
                Check(read.Edit?.Settings.Values[(int)Parameter.Exposure] == 0.75,
                    "Cached ReadState preserves latest edit payload");
            }
            var readsAfter = storeA.DiskReadCount - readsBefore;
            Check(readsAfter <= 1,
                $"Unchanged edits.json must not re-read on every ReadState (expected <= 1 disk read, observed {readsAfter})");

            // Batch ReadStates reads all entries in at most one disk pass.
            var batchBefore = storeA.DiskReadCount;
            var batch = storeA.ReadStates([photoA, photoB]);
            var batchReads = storeA.DiskReadCount - batchBefore;
            Check(batchReads <= 1,
                $"Batch ReadStates must reuse or read once (expected <= 1, observed {batchReads})");
            Check(batch.Count == 2 &&
                batch[0].Edit?.Settings.Values[(int)Parameter.Exposure] == 0.75 &&
                batch[1].Edit?.Settings.Values[(int)Parameter.Contrast] == 1.22,
                "Batch ReadStates returns accurate states for every requested photo");

            // Cross-instance SaveState invalidates sibling EditStore cache via shared path epoch.
            var primeB = storeB.ReadState(photoA);
            Check(primeB.Edit?.Settings.Values[(int)Parameter.Exposure] == 0.75,
                "Sibling EditStore observes prior commit");
            var updatedA = new Adjustments();
            updatedA.Set(Parameter.Exposure, -1.25);
            storeA.SaveState(primeB.Identity, new SavedEdit(primeB.Identity, updatedA.Capture(), null));
            var observedByB = storeB.ReadState(photoA);
            Check(observedByB.Edit?.Settings.Values[(int)Parameter.Exposure] == -1.25,
                "Cross-instance SaveState invalidates sibling EditStore cache");

            // External file modification on disk invalidates RegistryCache.
            var registryPath = Path.Combine(editsDir, "edits.json");
            var rawJson = File.ReadAllText(registryPath);
            var previousStamp = PathStatStamp.Capture(registryPath);
            File.WriteAllText(registryPath, rawJson.Replace("-1.25", "1.5"));
            File.SetLastWriteTimeUtc(registryPath,
                new DateTime(previousStamp.ModifiedTicks, DateTimeKind.Utc).AddSeconds(3));
            var afterExternal = storeB.ReadState(photoA);
            Check(afterExternal.Edit?.Settings.Values[(int)Parameter.Exposure] == 1.5,
                "External modification of edits.json invalidates cached registry");

            // External deletion invalidates RegistryCache cleanly.
            File.Delete(registryPath);
            var afterDelete = storeB.ReadState(photoA);
            Check(afterDelete.Edit == null,
                "Deleting edits.json invalidates cached registry and returns unmodified state");

            // External same-length rename-onto with spoofed identical timestamps invalidates RegistryCache on Windows (FileID/USN).
            var modifiedAgain = new Adjustments();
            modifiedAgain.Set(Parameter.Exposure, 0.5);
            storeA.SaveState(initialA.Identity, new SavedEdit(initialA.Identity, modifiedAgain.Capture(), null));
            Check(storeB.ReadState(photoA).Edit?.Settings.Values[(int)Parameter.Exposure] == 0.5,
                "Warm sibling RegistryCache before same-length rename-onto check");
            var stampBeforeRename = PathStatStamp.Capture(registryPath);
            var jsonBeforeRename = File.ReadAllText(registryPath);
            var jsonAfterRename = jsonBeforeRename.Replace("0.5", "0.6");
            Check(jsonAfterRename.Length == jsonBeforeRename.Length && jsonAfterRename != jsonBeforeRename,
                "External registry fixture preserves byte length");
            var stagedRegistry = registryPath + ".staged";
            File.WriteAllText(stagedRegistry, jsonAfterRename);
            if (OperatingSystem.IsWindows())
            {
                File.SetCreationTimeUtc(stagedRegistry, new DateTime(stampBeforeRename.CreatedTicks, DateTimeKind.Utc));
                File.SetLastWriteTimeUtc(stagedRegistry, new DateTime(stampBeforeRename.ModifiedTicks, DateTimeKind.Utc));
            }
            File.Move(stagedRegistry, registryPath, overwrite: true);
            Check(storeB.ReadState(photoA).Edit?.Settings.Values[(int)Parameter.Exposure] == 0.6,
                "Same-length rename-onto invalidates RegistryCache");

            // NTFS 15s tunneling / FileID change with identical timestamps & length must invalidate RegistryCache.
            var tunneledDir = Path.Combine(root, "tunneled-edits");
            var tunneledPhoto = Path.Combine(root, "photo-tunneled.arw");
            File.WriteAllBytes(tunneledPhoto, [11, 22, 33, 44]);
            var seedStore = new EditStore(tunneledDir);
            var tunneledState = seedStore.ReadState(tunneledPhoto);
            var tunneledEdit1 = new Adjustments();
            tunneledEdit1.Set(Parameter.Exposure, 0.25);
            seedStore.SaveState(tunneledState.Identity, new SavedEdit(tunneledState.Identity, tunneledEdit1.Capture(), null));
            var tunneledRegistryPath = Path.Combine(tunneledDir, "edits.json");
            var currentFileId = "abcd-0001-0001";
            OriginalIdentity ReadTunneledId(string p)
            {
                var info = new FileInfo(p);
                return new OriginalIdentity(info.FullName, info.Length, 1000, 1000) { FileID = currentFileId };
            }
            var idStore = new EditStore(tunneledDir, null, ReadTunneledId);
            Check(idStore.ReadState(tunneledPhoto).Edit?.Settings.Values[(int)Parameter.Exposure] == 0.25,
                "EditStore reads initial identity-tracked registry");
            var tunneledStamp = PathStatStamp.Capture(tunneledRegistryPath);
            var rawTunneledJson = File.ReadAllText(tunneledRegistryPath);
            var swappedJson = rawTunneledJson.Replace("0.25", "0.75");
            Check(swappedJson.Length == rawTunneledJson.Length, "Tunneled edits.json preserves length");
            File.WriteAllText(tunneledRegistryPath, swappedJson);
            File.SetCreationTimeUtc(tunneledRegistryPath, new DateTime(tunneledStamp.CreatedTicks, DateTimeKind.Utc));
            File.SetLastWriteTimeUtc(tunneledRegistryPath, new DateTime(tunneledStamp.ModifiedTicks, DateTimeKind.Utc));
            currentFileId = "abcd-0001-0002";
            Check(idStore.ReadState(tunneledPhoto).Edit?.Settings.Values[(int)Parameter.Exposure] == 0.75,
                "WindowsFileId change with identical length/timestamps invalidates EditStore.RegistryCache");

            // Transient stat probe failure must never spoof Exists=false (must not return null ReadState or wipe edits.json on Save).
            var transientDir = Path.Combine(root, "transient-edits");
            var tPhotoA = Path.Combine(root, "transient-a.arw");
            var tPhotoB = Path.Combine(root, "transient-b.arw");
            File.WriteAllBytes(tPhotoA, [1, 2, 3, 4]);
            File.WriteAllBytes(tPhotoB, [5, 6, 7, 8]);
            var failTransientStat = false;
            OriginalIdentity ReadTransientId(string p)
            {
                if (failTransientStat)
                    throw new UnauthorizedAccessException("Simulated transient stat sharing/ACL failure");
                var info = new FileInfo(p);
                return new OriginalIdentity(info.FullName, info.Length, info.LastWriteTimeUtc.Ticks, info.CreationTimeUtc.Ticks);
            }
            var transientStore = new EditStore(transientDir, null, ReadTransientId);
            var idAState = transientStore.ReadState(tPhotoA).Identity;
            var idBState = transientStore.ReadState(tPhotoB).Identity;
            var settingsA = new Adjustments();
            settingsA.Set(Parameter.Exposure, 1.25);
            transientStore.SaveState(idAState, new SavedEdit(idAState, settingsA.Capture(), null));
            failTransientStat = true;
            var transientRead = transientStore.ReadState(tPhotoA);
            Check(transientRead.Edit?.Settings.Values[(int)Parameter.Exposure] == 1.25,
                "Transient stat probe error on existing edits.json must not spoof empty ReadState");
            var settingsB = new Adjustments();
            settingsB.Set(Parameter.Contrast, 1.15);
            transientStore.SaveState(idBState, new SavedEdit(idBState, settingsB.Capture(), null));
            failTransientStat = false;
            var persistedA = transientStore.ReadState(tPhotoA);
            var persistedB = transientStore.ReadState(tPhotoB);
            Check(persistedA.Edit?.Settings.Values[(int)Parameter.Exposure] == 1.25 &&
                  persistedB.Edit?.Settings.Values[(int)Parameter.Contrast] == 1.15,
                "Transient stat probe error during SaveState must never wipe existing photo records in edits.json");

            // Explicit StatReliable=false (e.g. Windows GetFileInformationByHandle returning false on sharing violation)
            // must read from disk without writing cachedRegistry and must preserve existing edits on SaveState.
            var unreliableMode = 0; // 0=reliable, 1=(Exists=false,StatReliable=false), 2=(Exists=true,StatReliable=false)
            PathStatStamp CaptureWithUnreliableMode(string p) => unreliableMode switch
            {
                1 => new(false, p, p, null, -1, 0, 0, StatReliable: false),
                2 => new(true, p, p, null, new FileInfo(p).Length, 1000, 1000, StatReliable: false),
                _ => PathStatStamp.Capture(p)
            };
            var reliableDir = Path.Combine(root, "unreliable-stat-edits");
            var reliableStore = new EditStore(reliableDir, null, null, CaptureWithUnreliableMode);
            var uIdA = reliableStore.ReadState(tPhotoA).Identity;
            var uIdB = reliableStore.ReadState(tPhotoB).Identity;
            reliableStore.SaveState(uIdA, new SavedEdit(uIdA, settingsA.Capture(), null));
            // Populate reliable cache first.
            _ = reliableStore.ReadState(tPhotoA);

            foreach (var mode in new[] { 1, 2 })
            {
                unreliableMode = mode;
                var diskBefore = reliableStore.DiskReadCount;
                var firstRead = reliableStore.ReadState(tPhotoA);
                var secondRead = reliableStore.ReadState(tPhotoA);
                Check(firstRead.Edit?.Settings.Values[(int)Parameter.Exposure] == 1.25 &&
                      secondRead.Edit?.Settings.Values[(int)Parameter.Exposure] == 1.25 &&
                      reliableStore.DiskReadCount == diskBefore + 2,
                    $"Unreliable stat mode {mode} reads edits.json from disk without serving/populating cachedRegistry");
            }

            unreliableMode = 1;
            reliableStore.SaveState(uIdB, new SavedEdit(uIdB, settingsB.Capture(), null));
            unreliableMode = 0;
            Check(reliableStore.ReadState(tPhotoA).Edit?.Settings.Values[(int)Parameter.Exposure] == 1.25 &&
                  reliableStore.ReadState(tPhotoB).Edit?.Settings.Values[(int)Parameter.Contrast] == 1.15,
                "SaveState while StatReliable=false preserves all existing photo records");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static string BuildLargeCube(string seedLine, int minBytes = 68 * 1024)
    {
        var sb = new StringBuilder(minBytes + 128);
        sb.AppendLine("LUT_3D_SIZE 2");
        sb.AppendLine(seedLine);
        while (sb.Length < minBytes)
            sb.AppendLine("# padding comment line to model production 3D LUT asset size");
        return sb.ToString();
    }

    private static void S3ResourceDigestCacheChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-s3-digest-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var lut = Path.Combine(root, "film.cube");
            File.WriteAllText(lut, BuildLargeCube("0 0 0"));
            var snapshot = new Adjustments().Capture();

            var hashesBefore = EditedPhotoPreviewKey.ResourceHashCount;
            var first = EditedPhotoPreviewKey.ResourceFingerprint(snapshot, lut);
            for (var i = 0; i < 10; i++)
            {
                var next = EditedPhotoPreviewKey.ResourceFingerprint(snapshot, lut);
                Check(next == first, "Cached ResourceFingerprint remains identical");
            }
            var hashes = EditedPhotoPreviewKey.ResourceHashCount - hashesBefore;
            Check(hashes <= 1,
                $"Unchanged large LUT resource file must be hashed at most once (expected <= 1, observed {hashes})");

            // Dedicated cache verifies content changes, CreationTime-only replacement, symlinks, rename-onto, and HDR look sharing.
            var digestCache = new FileDigestCache(capacity: 32);
            var hdrDir = Path.Combine(root, "hdr-looks");
            Directory.CreateDirectory(hdrDir);
            var cubeBytes = Encoding.UTF8.GetBytes(BuildLargeCube("0.1 0.2 0.3"));
            var expectedSha = Convert.ToHexString(SHA256.HashData(cubeBytes)).ToLowerInvariant();
            var cubePath = Path.Combine(hdrDir, expectedSha + ".cube");
            File.WriteAllBytes(cubePath, cubeBytes);
            var hdrLook = new HDRLookSettings(expectedSha, "WarmHDR", 1.0);

            for (var i = 0; i < 8; i++)
                Check(hdrLook.AssetIsAvailable(hdrDir, digestCache), "HDR look asset validates as available");
            Check(digestCache.ComputeCount == 1,
                $"HDRLookSettings.AssetIsAvailable must hash unchanged large .cube once (observed {digestCache.ComputeCount})");
            Check(digestCache.HitCount == 7,
                $"HDRLookSettings.AssetIsAvailable must record 7 cache hits (observed {digestCache.HitCount})");

            // CreationTime-only change with identical Length + LastWriteTimeUtc must invalidate digest cache.
            var stampBefore = PathStatStamp.Capture(cubePath);
            var tampered = Encoding.UTF8.GetBytes(BuildLargeCube("9.9 9.9 9.9"));
            Check(tampered.Length == cubeBytes.Length, "Fixture byte length matches");
            File.WriteAllBytes(cubePath, tampered);
            File.SetLastWriteTimeUtc(cubePath, new DateTime(stampBefore.ModifiedTicks, DateTimeKind.Utc));
            File.SetCreationTimeUtc(cubePath, new DateTime(stampBefore.CreatedTicks, DateTimeKind.Utc).AddSeconds(5));
            Check(!hdrLook.AssetIsAvailable(hdrDir, digestCache),
                "CreationTime-only replacement with tampered bytes invalidates FileDigestCache");

            // Symlink target swap must invalidate FileDigestCache.
            var targetA = Path.Combine(root, "target-a.cube");
            var targetB = Path.Combine(root, "target-b.cube");
            File.WriteAllBytes(targetA, Encoding.UTF8.GetBytes(BuildLargeCube("0 0 0")));
            File.WriteAllBytes(targetB, Encoding.UTF8.GetBytes(BuildLargeCube("1 1 1", minBytes: 70 * 1024)));
            var linkPath = Path.Combine(root, "active-link.cube");
            File.CreateSymbolicLink(linkPath, targetA);
            var fpA = digestCache.GetDigest(linkPath);
            var fpA2 = digestCache.GetDigest(linkPath);
            Check(fpA.Sha256Hex == fpA2.Sha256Hex, "Symlink to unchanged target hits digest cache");

            File.Delete(linkPath);
            File.CreateSymbolicLink(linkPath, targetB);
            var fpB = digestCache.GetDigest(linkPath);
            Check(fpB.Sha256Hex != fpA.Sha256Hex,
                "Retargeting a symlink invalidates FileDigestCache");

            // Small-file same-length in-place overwrite with identical Length/LastWrite/Creation ticks
            // (reproducing NTFS same-tick overwrite in EditedPhotoPreviewChecks.cs:41) must never stale-hit.
            var smallLut = Path.Combine(root, "small-overwrite.cube");
            File.WriteAllText(smallLut, "first");
            var firstStamp = PathStatStamp.Capture(smallLut);
            var firstSmallDigest = digestCache.GetDigest(smallLut);
            File.WriteAllText(smallLut, "other");
            File.SetCreationTimeUtc(smallLut, new DateTime(firstStamp.CreatedTicks, DateTimeKind.Utc));
            File.SetLastWriteTimeUtc(smallLut, new DateTime(firstStamp.ModifiedTicks, DateTimeKind.Utc));
            var secondSmallDigest = digestCache.GetDigest(smallLut);
            Check(secondSmallDigest.Sha256Hex != firstSmallDigest.Sha256Hex,
                "Small-file same-length same-tick overwrite invalidates FileDigestCache");

            // Large-file rename-onto and WindowsFileId change with spoofed timestamps invalidate FileDigestCache.
            var fileIdForLarge = "large-id-1";
            OriginalIdentity ReadLargeId(string p)
            {
                var info = new FileInfo(p);
                return new OriginalIdentity(info.FullName, info.Length, 2000, 2000) { FileID = fileIdForLarge };
            }
            var idDigestCache = new FileDigestCache(capacity: 32, readIdentity: ReadLargeId);
            var largeTarget = Path.Combine(root, "large-rename.cube");
            File.WriteAllText(largeTarget, BuildLargeCube("0.2 0.2 0.2"));
            var largeDigest1 = idDigestCache.GetDigest(largeTarget);
            var largeDigest1Hit = idDigestCache.GetDigest(largeTarget);
            Check(largeDigest1.Sha256Hex == largeDigest1Hit.Sha256Hex && idDigestCache.HitCount == 1,
                "Unchanged FileID-tracked large LUT hits FileDigestCache");
            var largeStampBefore = PathStatStamp.Capture(largeTarget);
            var stagedLarge = largeTarget + ".tmp";
            File.WriteAllText(stagedLarge, BuildLargeCube("0.8 0.8 0.8"));
            File.SetCreationTimeUtc(stagedLarge, new DateTime(largeStampBefore.CreatedTicks, DateTimeKind.Utc));
            File.SetLastWriteTimeUtc(stagedLarge, new DateTime(largeStampBefore.ModifiedTicks, DateTimeKind.Utc));
            File.Move(stagedLarge, largeTarget, overwrite: true);
            fileIdForLarge = "large-id-2";
            var largeDigest2 = idDigestCache.GetDigest(largeTarget);
            Check(largeDigest2.Sha256Hex != largeDigest1.Sha256Hex,
                "WindowsFileId / rename-onto invalidates large FileDigestCache even with identical timestamps");

            // Transient stat probe error on MatchesSha256 must fall back conservatively instead of returning fake false.
            var remainingStatFaults = 0;
            OriginalIdentity ReadMatchId(string p)
            {
                if (remainingStatFaults > 0)
                {
                    remainingStatFaults--;
                    throw new UnauthorizedAccessException("Simulated transient stat error");
                }
                var info = new FileInfo(p);
                return new OriginalIdentity(info.FullName, info.Length, 2000, 2000);
            }
            var matchDigestCache = new FileDigestCache(capacity: 32, readIdentity: ReadMatchId);
            var matchTarget = Path.Combine(root, "match-transient.cube");
            File.WriteAllText(matchTarget, BuildLargeCube("0.4 0.4 0.4"));
            var expectedMatchHex = matchDigestCache.GetDigest(matchTarget).Sha256Hex;
            remainingStatFaults = 1;
            Check(matchDigestCache.MatchesSha256(matchTarget, expectedMatchHex, 256 * 1024),
                "Transient stat probe error in MatchesSha256 must not spoof false negative");

            // Persistent StatReliable=false must hash directly (no fake FileNotFoundException, no stale cache, respects maximumBytes).
            var unreliableDigestMode = 0; // 0=reliable, 1=(Exists=false,StatReliable=false), 2=(Exists=true,StatReliable=false)
            PathStatStamp CaptureDigestUnreliable(string p) => unreliableDigestMode switch
            {
                1 => new(false, p, p, null, -1, 0, 0, StatReliable: false),
                2 => new(true, p, p, null, new FileInfo(p).Length, 1000, 1000, StatReliable: false),
                _ => PathStatStamp.Capture(p)
            };
            var uDigestCache = new FileDigestCache(capacity: 32, captureStamp: CaptureDigestUnreliable);
            var uLarge = Path.Combine(root, "unreliable-large.cube");
            File.WriteAllText(uLarge, BuildLargeCube("0.1 0.1 0.1"));
            var reliableDigest = uDigestCache.GetDigest(uLarge);
            _ = uDigestCache.GetDigest(uLarge);
            Check(uDigestCache.HitCount == 1, "Baseline reliable digest cache hits");

            unreliableDigestMode = 1;
            var computesBeforeUnreliable = uDigestCache.ComputeCount;
            var hitsBeforeUnreliable = uDigestCache.HitCount;
            var uDigest1 = uDigestCache.GetDigest(uLarge);
            Check(uDigest1.Sha256Hex == reliableDigest.Sha256Hex &&
                  uDigestCache.ComputeCount == computesBeforeUnreliable + 1 &&
                  uDigestCache.HitCount == hitsBeforeUnreliable,
                "StatReliable=false GetDigest hashes directly without false FileNotFoundException or cache hit");
            Check(uDigestCache.MatchesSha256(uLarge, reliableDigest.Sha256Hex, 256 * 1024),
                "StatReliable=false MatchesSha256 validates real file content when within size limit");
            Check(!uDigestCache.MatchesSha256(uLarge, reliableDigest.Sha256Hex, 64),
                "StatReliable=false MatchesSha256 still enforces real identity.Length <= maximumBytes");

            // Same-length in-place overwrite while StatReliable=false must compute new hash (not serve stale cache).
            unreliableDigestMode = 2;
            File.WriteAllText(uLarge, BuildLargeCube("0.9 0.9 0.9"));
            var uDigest2 = uDigestCache.GetDigest(uLarge);
            Check(uDigest2.Sha256Hex != reliableDigest.Sha256Hex,
                "StatReliable=false overwrite yields updated hash without serving stale cache");
            Check(!uDigestCache.MatchesSha256(uLarge, reliableDigest.Sha256Hex, 256 * 1024) &&
                  uDigestCache.MatchesSha256(uLarge, uDigest2.Sha256Hex, 256 * 1024),
                "StatReliable=false MatchesSha256 tracks updated file digest conservatively");

            // Confirmed missing file (StatReliable=true, Exists=false) still throws FileNotFoundException & returns false.
            unreliableDigestMode = 0;
            var missingDigestPath = Path.Combine(root, "definitely-missing.cube");
            var missingThrew = false;
            try { _ = uDigestCache.GetDigest(missingDigestPath); }
            catch (FileNotFoundException) { missingThrew = true; }
            Check(missingThrew && !uDigestCache.MatchesSha256(missingDigestPath, reliableDigest.Sha256Hex, 256 * 1024),
                "Confirmed missing file still throws FileNotFoundException and returns false");

            // BatchFrozenSettings.Checksum wires to FileDigestCache.Shared, returning lowercase hex, hitting on repeat, and detecting overwrites.
            var batchCube = Path.Combine(root, "batch-shared.cube");
            File.WriteAllText(batchCube, BuildLargeCube("0.25 0.5 0.75"));
            FileDigestCache.Shared.Invalidate(batchCube);
            var sharedComputeBefore = FileDigestCache.Shared.ComputeCount;
            var sharedHitBefore = FileDigestCache.Shared.HitCount;
            var c1 = BatchFrozenSettings.Checksum(batchCube);
            var c2 = BatchFrozenSettings.Checksum(batchCube);
            Check(c1 == c2 && c1.Length == 64 && c1.All(ch => "0123456789abcdef".Contains(ch)) &&
                  FileDigestCache.Shared.ComputeCount == sharedComputeBefore + 1 &&
                  FileDigestCache.Shared.HitCount >= sharedHitBefore + 1,
                "BatchFrozenSettings.Checksum hits FileDigestCache.Shared and returns lowercase SHA-256 hex");
            File.WriteAllText(batchCube, BuildLargeCube("0.35 0.6 0.85"));
            var c3 = BatchFrozenSettings.Checksum(batchCube);
            Check(c3 != c1 && FileDigestCache.Shared.ComputeCount == sharedComputeBefore + 2,
                "BatchFrozenSettings.Checksum detects replaced look via FileDigestCache.Shared");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static void WindowsDigestChangeMarkerChecks()
    {
        if (!OperatingSystem.IsWindows())
        {
            Console.WriteLine("SKIP: Windows native file identity change-marker checks require Windows");
            return;
        }

        var root = Path.Combine(Path.GetTempPath(), "rawlab-digest-markers-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var markers = new (string Name, long ChangeTicks, long Usn)[]
            {
                ("change-time", DateTime.UtcNow.Ticks, 0),
                ("usn", 0, 123),
                ("unavailable", 0, 0)
            };
            foreach (var marker in markers)
            {
                var path = Path.Combine(root, marker.Name + ".cube");
                File.WriteAllText(path, BuildLargeCube("0.1 0.2 0.3"));
                var identity = OriginalIdentity.Read(path);
                Check(identity.Length > FileDigestCache.SmallFileDirectHashBytes,
                    "Change-marker regression must exercise the large-file cache path");

                PathStatStamp Capture(string p)
                {
                    // 只替换卷提供的变化标记；文件身份和摘要仍读取真实文件。
                    var reliable = WindowsFileIdentity.TryReadStat(p, out var stat,
                        _ => (marker.ChangeTicks, marker.Usn));
                    return new(true, p, p, null, stat.Length, stat.ModifiedTicks, stat.CreatedTicks,
                        stat.ChangeTicks, stat.Usn, stat.FileId, StatReliable: reliable);
                }
                var cache = new FileDigestCache(captureStamp: Capture);
                var first = cache.GetDigest(path);
                var repeated = cache.GetDigest(path);
                Check(repeated.Sha256Hex == first.Sha256Hex, "Unchanged LUT preserves its digest");
                if (marker.Name != "unavailable")
                {
                    Check(cache.ComputeCount == 1 && cache.HitCount == 1,
                        $"{marker.Name} alone preserves the large-file digest cache fast path");
                    continue;
                }

                var replacement = Encoding.UTF8.GetBytes(BuildLargeCube("0.9 0.8 0.7"));
                Check(replacement.LongLength == identity.Length, "Overwrite fixture preserves byte length");
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite))
                    stream.Write(replacement);
                File.SetLastWriteTimeUtc(path, new DateTime(identity.Modified, DateTimeKind.Utc));
                Check(identity.SameFile(OriginalIdentity.Read(path)),
                    "In-place overwrite preserves path, length, timestamps and Windows FileID");

                var changed = cache.GetDigest(path);
                var expected = Convert.ToHexString(SHA256.HashData(replacement));
                Check(changed.Sha256Hex == expected && changed.Sha256Hex != first.Sha256Hex,
                    "Large LUT without change markers must rehash a same-size same-mtime in-place overwrite");
                Check(cache.ComputeCount == 3 && cache.HitCount == 0,
                    "Missing change markers force direct hashing only for the affected file");
            }
            Console.WriteLine("PASS: Windows large-file digests require ChangeTime or USN and preserve either fast path");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static void S3PhotoProbeCacheChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-s3-probe-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var rawPath = Path.Combine(root, "sample.arw");
            File.WriteAllBytes(rawPath, new byte[64]);
            var probeCache = new PhotoProbeCache(capacity: 32);
            var invoked = 0;

            HDRProbeState FakeProbe(string path, out HDRSourceInfo? info, int pv)
            {
                Interlocked.Increment(ref invoked);
                info = new HDRSourceInfo(HDRProbeState.Supported, 4000, 3000, 1, 1, 1, 1, 2.0f, 1, [])
                {
                    CameraProcessingVersion = pv
                };
                return HDRProbeState.Supported;
            }

            for (var i = 0; i < 10; i++)
            {
                var state = probeCache.GetOrProbe(rawPath, cameraRaw: true, processingVersion: 3, FakeProbe, out var info);
                Check(state == HDRProbeState.Supported && info?.Width == 4000,
                    "PhotoProbeCache returns cached HDRSourceInfo");
            }
            Check(invoked == 1 && probeCache.MissCount == 1 && probeCache.HitCount == 9,
                $"Unchanged RAW probe must execute once across Open/Render passes (invoked={invoked}, hits={probeCache.HitCount})");

            // Processing version change misses cleanly into separate key.
            var pv2 = probeCache.GetOrProbe(rawPath, cameraRaw: true, processingVersion: 2, FakeProbe, out var infoV2);
            Check(pv2 == HDRProbeState.Supported && infoV2?.CameraProcessingVersion == 2 && invoked == 2,
                "Different processing version probes separately");

            // CreationTime-only replacement invalidates probe cache.
            var stamp = PathStatStamp.Capture(rawPath);
            File.SetCreationTimeUtc(rawPath, new DateTime(stamp.CreatedTicks, DateTimeKind.Utc).AddSeconds(4));
            probeCache.GetOrProbe(rawPath, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            Check(invoked == 3, "CreationTime change invalidates PhotoProbeCache");

            // Delete + recreate invalidates PhotoProbeCache; FileID mismatch (NTFS tunneling) invalidates even with identical timestamps.
            File.Delete(rawPath);
            File.WriteAllBytes(rawPath, new byte[64]);
            File.SetLastWriteTimeUtc(rawPath, new DateTime(stamp.ModifiedTicks, DateTimeKind.Utc).AddSeconds(7));
            probeCache.GetOrProbe(rawPath, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            Check(invoked == 4, "Delete + recreate invalidates PhotoProbeCache");

            var tunneledRaw = Path.Combine(root, "tunneled.arw");
            File.WriteAllBytes(tunneledRaw, new byte[64]);
            var rawFileId = "vol-0001-0001";
            OriginalIdentity ReadRawId(string p)
            {
                var info = new FileInfo(p);
                return new OriginalIdentity(info.FullName, info.Length, 3000, 3000) { FileID = rawFileId };
            }
            var idProbeCache = new PhotoProbeCache(capacity: 32, readIdentity: ReadRawId);
            idProbeCache.GetOrProbe(tunneledRaw, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            var invokedBeforeIdHit = invoked;
            idProbeCache.GetOrProbe(tunneledRaw, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            Check(invoked == invokedBeforeIdHit, "Unchanged FileID hits PhotoProbeCache");
            var tunneledStampBefore = PathStatStamp.Capture(tunneledRaw);
            var stagedRaw = tunneledRaw + ".tmp";
            File.WriteAllBytes(stagedRaw, new byte[64]);
            File.SetCreationTimeUtc(stagedRaw, new DateTime(tunneledStampBefore.CreatedTicks, DateTimeKind.Utc));
            File.SetLastWriteTimeUtc(stagedRaw, new DateTime(tunneledStampBefore.ModifiedTicks, DateTimeKind.Utc));
            File.Move(stagedRaw, tunneledRaw, overwrite: true);
            rawFileId = "vol-0001-0002";
            idProbeCache.GetOrProbe(tunneledRaw, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            Check(invoked == invokedBeforeIdHit + 1,
                "WindowsFileId / rename-onto change with identical timestamps invalidates PhotoProbeCache");
            var baseInvokesAfterTunneling = invoked;

            // Symlink target swap invalidates probe cache.
            var rawAlt = Path.Combine(root, "sample-alt.arw");
            File.WriteAllBytes(rawAlt, new byte[128]);
            var linkRaw = Path.Combine(root, "active.arw");
            File.CreateSymbolicLink(linkRaw, rawPath);
            probeCache.GetOrProbe(linkRaw, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            var invokesAtLinkA = invoked;
            File.Delete(linkRaw);
            File.CreateSymbolicLink(linkRaw, rawAlt);
            probeCache.GetOrProbe(linkRaw, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            Check(invoked == invokesAtLinkA + 1 && invokesAtLinkA > baseInvokesAfterTunneling,
                "Symlink retarget invalidates PhotoProbeCache");

            // Probe exception must never be cached.
            var badPath = Path.Combine(root, "corrupt.jpg");
            File.WriteAllBytes(badPath, [0xFF, 0xD8, 0x00]);
            var failCount = 0;
            for (var attempt = 0; attempt < 2; attempt++)
            {
                var threw = false;
                try
                {
                    probeCache.GetOrProbe(badPath, cameraRaw: false, processingVersion: 0, (string p, out HDRSourceInfo? info, int _) =>
                    {
                        failCount++;
                        info = null;
                        throw new InvalidDataException("corrupt hdr metadata");
                    }, out _);
                }
                catch (InvalidDataException) { threw = true; }
                Check(threw, "Probe exception propagates cleanly");
            }
            Check(failCount == 2, "Failed probes are never cached");

            // Unreliable stat skips cache lookup and cache store in PhotoProbeCache.
            var probeUnreliable = new PhotoProbeCache(
                capacity: 32,
                captureStamp: p => new(false, p, p, null, -1, 0, 0, StatReliable: false));
            var unreliableMissesBefore = invoked;
            for (var i = 0; i < 2; i++)
            {
                probeUnreliable.GetOrProbe(rawPath, cameraRaw: true, processingVersion: 3, FakeProbe, out _);
            }
            Check(invoked == unreliableMissesBefore + 2 && probeUnreliable.HitCount == 0 && probeUnreliable.MissCount == 2,
                "StatReliable=false skips PhotoProbeCache lookup and store");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static void W6ViewSourceStateChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-w6-viewsource-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var photoA = Path.Combine(root, "a.arw");
            File.WriteAllBytes(photoA, [10, 20, 30, 40]);
            var idA = OriginalIdentity.Read(photoA);
            var state = new ViewSourceState();

            state.SetOpenPhoto(photoA, revision: 7, idA);
            for (var i = 0; i < 1000; i++)
            {
                var cur = state.Current(photoA, revision: 7);
                Check(cur != null && cur.SameFile(idA),
                    "CurrentViewSource hot read returns cached OriginalIdentity without disk I/O");
            }
            Check(state.Current(photoA, revision: 8) == null,
                "Stale openRevision never leaks cached identity");
            Check(state.Current(Path.Combine(root, "other.arw"), revision: 7) == null,
                "Different file path returns null");

            // Stale worker probe from an older openRevision must be ignored.
            Check(state.ApplyProbeResult(photoA, revision: 6, idA) == ViewSourceProbeOutcome.Stale,
                "Older revision probe outcome is ignored");

            // MarkDirty triggers background probe flag; external vanish reports BecameUnavailable.
            state.MarkDirty(photoA, revision: 7);
            Check(state.NeedsBackgroundProbe(photoA, revision: 7),
                "External watch invalidation marks background probe needed");
            Check(state.ApplyProbeResult(photoA, revision: 7, null) == ViewSourceProbeOutcome.BecameUnavailable,
                "Missing worker probe transitions to BecameUnavailable");
            Check(state.Current(photoA, revision: 7) == null,
                "Current becomes null after BecameUnavailable");

            // Recovery after vanish -> Initialized, then replacement -> Replaced.
            Check(state.ApplyProbeResult(photoA, revision: 7, idA) == ViewSourceProbeOutcome.Initialized,
                "Restoring file transitions to Initialized");
            File.WriteAllBytes(photoA, [99, 98, 97, 96, 95, 94]);
            var idReplaced = OriginalIdentity.Read(photoA);
            Check(state.ApplyProbeResult(photoA, revision: 7, idReplaced) == ViewSourceProbeOutcome.Replaced,
                "Modified source transitions to Replaced");
            Check(state.Current(photoA, revision: 7)?.SameFile(idReplaced) == true,
                "Replaced source updates cached CurrentViewSource");

            // Missing file in TryReadIdentity returns null without throwing.
            Check(ViewSourceState.TryReadIdentity(Path.Combine(root, "missing.arw")) == null,
                "TryReadIdentity swallows file identity failures gracefully");

            // Queued source replacement (V1 -> V2) must fail ResolveWorkerFrameSource (DegradeSourceUnavailable).
            Check(ViewSourceState.ResolveWorkerFrameSource(idA, idReplaced, idReplaced, idReplaced, sameOpenFile: true) == null,
                "Queued file replacement (work.Source != afterRender) must not publish V2 under V1");
            // Recovery after vanish (work.Source == null) publishes consistent restored source.
            Check(ViewSourceState.ResolveWorkerFrameSource(null, idReplaced, idReplaced, idReplaced, sameOpenFile: true)?.SameFile(idReplaced) == true,
                "Retry after vanish (work.Source == null) publishes restored source");
            // Out-of-order watcher probes and stale worker snapshots cannot overwrite newer generation.
            state.SetOpenPhoto(photoA, revision: 9, idA);
            var workerGen = state.Generation;
            var watchSeq1 = state.BeginWatcherProbe(photoA, revision: 9);
            var watchSeq2 = state.BeginWatcherProbe(photoA, revision: 9);
            Check(watchSeq1 != null && watchSeq2 != null && watchSeq2 > watchSeq1,
                "Concurrent watcher probes get strictly increasing sequence numbers");
            Check(state.ApplyProbeResult(photoA, revision: 9, idReplaced, watchSeq2) == ViewSourceProbeOutcome.Replaced,
                "Newer watcher probe applies normally");
            Check(state.ApplyProbeResult(photoA, revision: 9, idA, watchSeq1) == ViewSourceProbeOutcome.Stale,
                "Older out-of-order watcher probe is rejected as Stale");
            Check(state.ApplyProbeResult(photoA, revision: 9, idA, workerGen) == ViewSourceProbeOutcome.Stale,
                "Stale worker probe cannot revert newer ViewSourceState");
            Check(state.Current(photoA, revision: 9)?.SameFile(idReplaced) == true && !state.NeedsBackgroundProbe(photoA, revision: 9),
                "ViewSourceState preserves newest identity and clean probe state");

            // UnchangedUnavailable must not increment generation so a concurrent Retry worker is not marked Stale.
            state.SetOpenPhoto(photoA, revision: 10, null);
            var genBeforeUnavailable = state.Generation;
            Check(state.ApplyProbeResult(photoA, revision: 10, null, genBeforeUnavailable) == ViewSourceProbeOutcome.UnchangedUnavailable,
                "Null probe on already unavailable source reports UnchangedUnavailable");
            Check(state.Generation == genBeforeUnavailable,
                "UnchangedUnavailable must not advance ViewSourceState generation");
            Check(state.ApplyProbeResult(photoA, revision: 10, idA, genBeforeUnavailable) == ViewSourceProbeOutcome.Initialized,
                "Concurrent Retry worker with pre-UnchangedUnavailable generation recovers to Initialized");
            Check(ViewSourceState.ResolveWorkerFrameSource(idA, state.Current(photoA, 10), state.Current(photoA, 10), idA, sameOpenFile: true)?.SameFile(idA) == true,
                "Recovered ViewSourceState publishes worker frame cleanly without false Stale degrade");
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static void W6LookAvailabilityAndHDRPresentationChecks()
    {
        var tracker = new LookAvailabilityTracker();
        var probeCalls = 0;
        bool Probe(string p)
        {
            Interlocked.Increment(ref probeCalls);
            return p.EndsWith("present.cube", StringComparison.OrdinalIgnoreCase);
        }

        // HDR editing never probes SDR look paths.
        Check(tracker.IsAvailable(isHdrEditing: true, "/tmp/present.cube", Probe) && probeCalls == 0,
            "HDR editing skips SDR look File.Exists probe");

        // SDR look probes once for 100 hot ticks.
        for (var i = 0; i < 100; i++)
            Check(tracker.IsAvailable(isHdrEditing: false, "/tmp/present.cube", Probe),
                "Cached LookAvailable returns true");
        Check(probeCalls == 1 && tracker.ProbeCount == 1,
            $"LookAvailabilityTracker probes unchanged look once (observed {probeCalls})");

        // Invalidate causes single re-probe; ApplyWorkerCheck refreshes without UI probe.
        tracker.Invalidate("/tmp/present.cube");
        Check(tracker.IsAvailable(isHdrEditing: false, "/tmp/present.cube", Probe) && probeCalls == 2,
            "Invalidate refreshes on next read");
        tracker.ApplyWorkerCheck("/tmp/missing.cube", false);
        Check(!tracker.IsAvailable(isHdrEditing: false, "/tmp/missing.cube", Probe) && probeCalls == 2,
            "ApplyWorkerCheck updates availability with zero UI probe");

        // Pre-render LookGeneration cannot overwrite an Invalidate that fired mid-render.
        tracker.Invalidate();
        Check(tracker.IsAvailable(isHdrEditing: false, "/tmp/present.cube", Probe) && probeCalls == 3,
            "Re-arm cached look before render-race check");
        var renderLookGen = tracker.Generation;
        tracker.Invalidate("/tmp/present.cube");
        Check(!tracker.ApplyWorkerCheck("/tmp/present.cube", true, renderLookGen),
            "Stale ApplyWorkerCheck cannot overwrite mid-render watcher Invalidate");
        Check(tracker.IsAvailable(isHdrEditing: false, "/tmp/present.cube", Probe) && probeCalls == 4,
            "Next read re-probes because watcher Invalidate was preserved");

        // RetryButton parent-dir watch recovery: missing directory -> not watching -> created -> Watch attaches.
        var missingWatchRoot = Path.Combine(Path.GetTempPath(), "rawlab-look-watch-" + Guid.NewGuid());
        try
        {
            var missingLookFile = Path.Combine(missingWatchRoot, "sub", "look.cube");
            using var lookWatch = new PhotoPreviewResourceWatch(() => { });
            lookWatch.Watch([missingLookFile]);
            Check(!lookWatch.IsWatchingDirectory(missingLookFile),
                "Missing parent directory initially leaves watch unattached");
            Directory.CreateDirectory(Path.GetDirectoryName(missingLookFile)!);
            lookWatch.Watch([missingLookFile]);
            Check(lookWatch.IsWatchingDirectory(missingLookFile),
                "Retrying Watch after parent directory appears attaches FileSystemWatcher");
        }
        finally
        {
            if (Directory.Exists(missingWatchRoot)) Directory.Delete(missingWatchRoot, true);
        }

        // HDRPresentationCoordinator skips idle SDR LayoutUpdated floods.
        var coordinator = new HDRPresentationCoordinator();
        for (var i = 0; i < 200; i++)
        {
            if (coordinator.ShouldRunOnLayoutUpdated(
                isLoaded: true, hdrEditing: false, hasHdrResult: false, sdrPreview: false,
                resultSurfaceAvailable: true, neutralSurfaceAvailable: false, geometryEditing: false, clipping: false))
            {
                coordinator.RecordPresentation(true, false, false, false, true, false, false, false, false);
            }
        }
        Check(coordinator.PresentationExecutedCount == 0 && coordinator.LayoutSkippedCount == 200,
            $"Inactive HDR must skip all 200 idle LayoutUpdated ticks (skipped={coordinator.LayoutSkippedCount}, executed={coordinator.PresentationExecutedCount})");

        // Entering active HDR runs presentation and keeps sync active while active.
        Check(coordinator.ShouldRunOnLayoutUpdated(true, true, true, false, true, false, false, false),
            "Active HDR layout tick executes presentation");
        coordinator.RecordPresentation(true, true, true, false, true, false, false, false, true);

        // Exiting HDR runs one hide sync tick, then subsequent 100 SDR layout ticks skip cleanly.
        Check(coordinator.ShouldRunOnLayoutUpdated(true, false, false, false, true, false, false, false),
            "Transitioning out of HDR executes one hide sync pass");
        coordinator.RecordPresentation(true, false, false, false, true, false, false, false, false);
        var skipsBefore = coordinator.LayoutSkippedCount;
        var runsBefore = coordinator.PresentationExecutedCount;
        for (var i = 0; i < 100; i++)
        {
            if (coordinator.ShouldRunOnLayoutUpdated(true, false, false, false, true, false, false, false))
                coordinator.RecordPresentation(true, false, false, false, true, false, false, false, false);
        }
        Check(coordinator.PresentationExecutedCount == runsBefore &&
              coordinator.LayoutSkippedCount - skipsBefore == 100,
            "After hiding HDR surfaces, subsequent LayoutUpdated ticks are skipped");
    }

    private static void M4AIDenoiseCachedIdentityChecks()
    {
        var cachedSource = new OriginalIdentity(Path.Combine(Path.GetTempPath(), "nonexistent-cached.arw"), 1234, 5678, 5678)
        {
            FileID = "0001-0002-0003"
        };
        var settings = new Adjustments { AIDenoiseEnabled = true };
        var id = AIDenoiseIdentity.Read(cachedSource.Path, settings, backend: 3, deviceID: "gpu-0", sourceIdentity: cachedSource);
        Check(id.Source == cachedSource && id.Backend == 3 && id.DeviceID == "gpu-0",
            "AIDenoiseIdentity.Read uses cached OriginalIdentity with zero disk I/O");
        Check(PreviewFallback.IsFileIdentityFailure(new Win32Exception(5)),
            "Win32Exception is treated as a file identity failure in AI/view guards");
    }

    private static void W16InspectorModificationAndSubEditorChecks()
    {
        var identity = new OriginalIdentity("photo.arw", 100, 1, 1);
        var cache = new InspectorModificationCache();
        var evalCalls = 0;

        bool Evaluate(EditorResetScope scope, SavedEdit edit)
        {
            Interlocked.Increment(ref evalCalls);
            return EditorAdjustmentRules.IsModified(scope, edit);
        }

        var settings = new Adjustments();
        var initialEdit = new SavedEdit(identity, settings.Capture(), null);

        // First Full pass populates all groups & tools.
        var scope1 = cache.Update(initialEdit, isHdrEditing: false, interacting: false,
            EditorAdjustmentGroup.Light, EditorAdjustmentTool.Exposure, out _, out _, Evaluate);
        var fullEvalCount = evalCalls;
        Check(scope1 == InspectorRefreshScope.Full && cache.FullComputeCount == 1 && fullEvalCount > 10,
            "Initial Full refresh evaluates all groups and tools");

        // Second unmodified Full pass hits cache with 0 evaluator calls.
        evalCalls = 0;
        var scopeIdle = cache.Update(initialEdit, isHdrEditing: false, interacting: false,
            EditorAdjustmentGroup.Light, EditorAdjustmentTool.Exposure, out _, out _, Evaluate);
        Check(scopeIdle == InspectorRefreshScope.Full && cache.CacheHitCount == 1 && evalCalls == 0,
            $"Unmodified Full refresh hits cache with 0 evaluator calls (observed {evalCalls})");

        // 50 slider drag ticks evaluate only activeGroup + activeTool (<= 2 per tick).
        evalCalls = 0;
        IReadOnlyDictionary<EditorAdjustmentGroup, bool> groups = null!;
        IReadOnlyDictionary<EditorAdjustmentTool, bool> tools = null!;
        for (var i = 1; i <= 50; i++)
        {
            settings.Set(Parameter.Exposure, i * 0.02);
            var dragEdit = new SavedEdit(identity, settings.Capture(), null);
            var dragScope = cache.Update(dragEdit, isHdrEditing: false, interacting: true,
                EditorAdjustmentGroup.Light, EditorAdjustmentTool.Exposure, out groups, out tools, Evaluate);
            Check(dragScope == InspectorRefreshScope.DragFastPath, "Dragging uses DragFastPath");
        }
        Check(evalCalls <= 100 && cache.DragPartialComputeCount == 50 && cache.FullComputeCount == 1,
            $"50 drag ticks must compute at most 2 scopes/tick (evalCalls={evalCalls}, dragTicks={cache.DragPartialComputeCount})");
        Check(groups[EditorAdjustmentGroup.Light] && tools[EditorAdjustmentTool.Exposure],
            "DragFastPath keeps active group and tool modified indicators accurate");

        // Drag release reconciles Full once, then next unmodified Full hits cache again.
        evalCalls = 0;
        var releasedEdit = new SavedEdit(identity, settings.Capture(), null);
        var releaseScope = cache.Update(releasedEdit, isHdrEditing: false, interacting: false,
            EditorAdjustmentGroup.Light, EditorAdjustmentTool.Exposure, out groups, out tools, Evaluate);
        Check(releaseScope == InspectorRefreshScope.Full && cache.FullComputeCount == 2 && evalCalls == fullEvalCount,
            "Drag release performs one full reconciliation");

        evalCalls = 0;
        cache.Update(releasedEdit, isHdrEditing: false, interacting: false,
            EditorAdjustmentGroup.Light, EditorAdjustmentTool.Exposure, out _, out _, Evaluate);
        Check(evalCalls == 0 && cache.CacheHitCount == 2,
            "Post-release unmodified Full refresh hits cache cleanly");

        // Sub-editor visibility gating.
        Check(!InspectorModificationCache.ShouldRefreshSubEditor(panelVisible: false) &&
              InspectorModificationCache.ShouldRefreshSubEditor(panelVisible: true),
            "Collapsed sub-editors must skip per-tick Refresh calls");
    }

    private static void W16ParameterRowLayoutCacheChecks()
    {
        var layoutCache = new ParameterRowLayoutCache();
        var range = new NumericRange(-5.0, 5.0, 0.01, Wheel: 0.1, FineWheel: 0.01, FixedDecimals: 2);
        var baseSig = new ParameterRowLayoutSignature(
            13.0, 13.0, "Segoe UI", "Normal", "Normal", "Normal", "zh-Hans",
            range, "EV", 320.0, 1.0, Compact: false);
        var baseMeta = new ParameterRowMetadataSignature(
            "曝光", range, 0.0, "EV", "zh-Hans");

        Check(layoutCache.NeedsLayoutMeasure(baseSig) && layoutCache.NeedsMetadataRefresh(baseMeta),
            "Initial ParameterRow bind requires measure and metadata refresh");

        // 100 simulated slider drag ticks with unchanged geometry/language/range.
        var remeasuresDuringDrag = 0;
        var metaRefreshesDuringDrag = 0;
        for (var i = 0; i < 100; i++)
        {
            if (layoutCache.NeedsLayoutMeasure(baseSig)) remeasuresDuringDrag++;
            if (layoutCache.NeedsMetadataRefresh(baseMeta)) metaRefreshesDuringDrag++;
        }
        Check(remeasuresDuringDrag == 0 && metaRefreshesDuringDrag == 0 &&
              layoutCache.MeasureCount == 1 && layoutCache.MeasureSkippedCount == 100,
            $"Unchanged ParameterRow drag ticks must perform 0 layout remeasures (measured={remeasuresDuringDrag}, skipped={layoutCache.MeasureSkippedCount})");

        // Width, font size, Number.FontSize, full NumericRange fields, language, compact changes trigger remeasure/refresh.
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0 }), "Width change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0 }), "FontSize change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0, NumberFontSize = 15.0 }), "Number.FontSize change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0, NumberFontSize = 15.0, Range = range with { FixedDecimals = 0 } }),
            "NumericRange.FixedDecimals change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0, NumberFontSize = 15.0, Range = range with { FixedDecimals = 0 }, Language = "en" }), "Language change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0, NumberFontSize = 15.0, Range = range with { FixedDecimals = 0 }, Language = "en", Compact = true }), "Compact change remeasures");
        Check(layoutCache.NeedsMetadataRefresh(baseMeta with { Language = "en" }), "Language change refreshes metadata");
        Check(layoutCache.NeedsMetadataRefresh(baseMeta with { Language = "en", Range = range with { CompactPercent = true } }), "CompactPercent change refreshes metadata");
        Check(layoutCache.NeedsMetadataRefresh(baseMeta with { Language = "en", Range = range with { CompactPercent = true, Wheel = 1.0 } }), "Wheel change refreshes metadata");
    }
}
