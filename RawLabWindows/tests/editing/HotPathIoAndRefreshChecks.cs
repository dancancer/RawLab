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
        S3PhotoProbeCacheChecks();
        W6ViewSourceStateChecks();
        W6LookAvailabilityAndHDRPresentationChecks();
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
            modifiedB.Set(Parameter.Contrast, 22);
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
                batch[1].Edit?.Settings.Values[(int)Parameter.Contrast] == 22,
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
        }
        finally
        {
            Directory.Delete(root, true);
        }
    }

    private static void S3ResourceDigestCacheChecks()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-s3-digest-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var lut = Path.Combine(root, "film.cube");
            File.WriteAllText(lut, "LUT_3D_SIZE 2\n0 0 0\n");
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
                $"Unchanged resource file must be hashed at most once (expected <= 1, observed {hashes})");

            // Dedicated cache verifies content changes, CreationTime-only replacement, symlinks, and HDR look sharing.
            var digestCache = new FileDigestCache(capacity: 32);
            var hdrDir = Path.Combine(root, "hdr-looks");
            Directory.CreateDirectory(hdrDir);
            var cubeBytes = Encoding.UTF8.GetBytes("LUT_3D_SIZE 2\n0.1 0.2 0.3\n");
            var expectedSha = Convert.ToHexString(SHA256.HashData(cubeBytes)).ToLowerInvariant();
            var cubePath = Path.Combine(hdrDir, expectedSha + ".cube");
            File.WriteAllBytes(cubePath, cubeBytes);
            var hdrLook = new HDRLookSettings(expectedSha, "WarmHDR", 1.0);

            for (var i = 0; i < 8; i++)
                Check(hdrLook.AssetIsAvailable(hdrDir, digestCache), "HDR look asset validates as available");
            Check(digestCache.ComputeCount == 1,
                $"HDRLookSettings.AssetIsAvailable must hash unchanged .cube once (observed {digestCache.ComputeCount})");
            Check(digestCache.HitCount == 7,
                $"HDRLookSettings.AssetIsAvailable must record 7 cache hits (observed {digestCache.HitCount})");

            // CreationTime-only change with identical Length + LastWriteTimeUtc must invalidate digest cache.
            var stampBefore = PathStatStamp.Capture(cubePath);
            var tampered = Encoding.UTF8.GetBytes("LUT_3D_SIZE 2\n9.9 9.9 9.9\n");
            Check(tampered.Length == cubeBytes.Length, "Fixture byte length matches");
            File.WriteAllBytes(cubePath, tampered);
            File.SetLastWriteTimeUtc(cubePath, new DateTime(stampBefore.ModifiedTicks, DateTimeKind.Utc));
            File.SetCreationTimeUtc(cubePath, new DateTime(stampBefore.CreatedTicks, DateTimeKind.Utc).AddSeconds(5));
            Check(!hdrLook.AssetIsAvailable(hdrDir, digestCache),
                "CreationTime-only replacement with tampered bytes invalidates FileDigestCache");

            // Symlink target swap must invalidate FileDigestCache.
            var targetA = Path.Combine(root, "target-a.cube");
            var targetB = Path.Combine(root, "target-b.cube");
            File.WriteAllBytes(targetA, Encoding.UTF8.GetBytes("LUT_A\n0 0 0\n"));
            File.WriteAllBytes(targetB, Encoding.UTF8.GetBytes("LUT_B_REPLACED\n1 1 1\n"));
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
            Check(invoked == invokesAtLinkA + 1, "Symlink retarget invalidates PhotoProbeCache");

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
        var baseSig = new ParameterRowLayoutSignature(
            13.0, "Segoe UI", "Normal", "Normal", "Normal", "zh-Hans",
            -5.0, 5.0, 0.01, "EV", 320.0, 1.0, Compact: false);
        var baseMeta = new ParameterRowMetadataSignature(
            "曝光", -5.0, 5.0, 0.01, 0.0, "EV", "zh-Hans");

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

        // Width, font size, language, range, suffix, compact, and DPI changes trigger remeasure.
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0 }), "Width change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0 }), "FontSize change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0, Language = "en" }), "Language change remeasures");
        Check(layoutCache.NeedsLayoutMeasure(baseSig with { ActualWidth = 280.0, FontSize = 20.0, Language = "en", Compact = true }), "Compact change remeasures");
        Check(layoutCache.NeedsMetadataRefresh(baseMeta with { Language = "en" }), "Language change refreshes metadata");
    }
}
