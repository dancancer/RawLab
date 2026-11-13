using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace RawLab.Windows;

internal static class EditDurabilityChecks
{
    private static void Check([System.Diagnostics.CodeAnalysis.DoesNotReturnIf(false)] bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    internal static void Run()
    {
        UnknownProRAWDecodeVersionRemainsDormantInSdrAndRejectedInHdr();
        UnknownProcessingVersionIsolatesEntryAndRecoversOnResetToUnmodified();
        MalformedSubSettingsAndEmptyArraysIsolateEntriesAndPreserveTableValidation();
        CorruptReceiptDoesNotBreakStoreAndActsAsAbsent();
        ResetTransactionClearsReceiptAndUndoRestoresValuesWithoutRestoringReceipt();
        Console.WriteLine("PASS: ProRAW dormant version, per-entry store isolation, manual reset recovery and reset receipt clearing");
    }

    private static void UnknownProRAWDecodeVersionRemainsDormantInSdrAndRejectedInHdr()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-proraw-dormant-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var photo = Path.Combine(root, "proraw.dng");
            File.WriteAllText(photo, "proraw-fixture");
            var storeDirectory = Path.Combine(root, "edits");
            var store = new EditStore(storeDirectory);

            var initial = new Adjustments {
                HDR = new HDRSettings { Mode = HDRMode.Sdr, Exposure = -0.5 }
            };
            initial.Set(Parameter.Exposure, 0.5);
            store.Save(photo, initial.Capture(), null);

            var editsPath = Path.Combine(storeDirectory, "edits.json");
            var registryNode = JsonNode.Parse(File.ReadAllText(editsPath))!;
            var settingsNode = registryNode["Records"]![Path.GetFullPath(photo)]!["Settings"]!.AsObject();
            settingsNode["ProRAWDecodeVersion"] = 99;
            File.WriteAllText(editsPath, registryNode.ToJsonString());

            // new EditStore 不抛；SDR 可读可写；未知 ProRAWDecodeVersion 原样保留。
            var reopened = new EditStore(storeDirectory);
            var state = reopened.ReadState(photo);
            Check(state.Edit != null && state.Edit.Settings.ProRAWDecodeVersion == 99,
                "Store preserves unknown ProRAWDecodeVersion on read");
            var restored = state.Edit!.Settings.Restore();
            Check(!restored.IsHDREditing && restored.ProRAWDecodeVersion == 99 && restored[Parameter.Exposure] == 0.5,
                "SDR snapshot with unknown ProRAWDecodeVersion restores without throwing");

            restored.Set(Parameter.Exposure, 1.25);
            var session = new AdjustmentTransferSession(reopened);
            var edited = new SavedEdit(state.Identity, restored.Capture(), null);
            var outcome = session.CommitEdit(state, edited);
            Check(outcome.Status == AdjustmentStatus.Applied, "SDR edit commits when dormant ProRAWDecodeVersion is unknown");

            var afterWrite = new EditStore(storeDirectory).ReadState(photo);
            Check(afterWrite.Edit?.Settings.ProRAWDecodeVersion == 99 &&
                  afterWrite.Edit.Settings.Restore()[Parameter.Exposure] == 1.25,
                "Saving SDR edits preserves unknown ProRAWDecodeVersion verbatim");

            // 局部与全部 SDR 重置都保留休眠 ProRAWDecodeVersion 与 HDR 快照（对齐 Mac/iOS/Android 的新规则）。
            var toolReset = EditorAdjustmentRules.PrepareReset(
                new EditorResetScope(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Exposure), afterWrite.Edit!);
            Check(toolReset.Status == EditorResetStatus.Ready &&
                  toolReset.Candidate!.Settings.ProRAWDecodeVersion == 99 &&
                  toolReset.Candidate.Settings.HDR?.Mode == HDRMode.Sdr,
                "Partial SDR tool reset preserves dormant ProRAWDecodeVersion and dormant HDR snapshot");
            var fullSdrReset = EditorResetTransaction.Prepare(
                new EditorResetScope(EditorResetKind.All), photo, openRevision: 1, editRevision: 1,
                afterWrite.Edit!, new EditorResetContext(null, TransformGeneration: 0));
            Check(fullSdrReset.Status == EditorResetStatus.Ready &&
                  fullSdrReset.Candidate!.Settings.ProRAWDecodeVersion == 99 &&
                  fullSdrReset.Candidate.Settings.HDR?.Mode == HDRMode.Sdr,
                "Real SDR all-reset transaction preserves dormant ProRAWDecodeVersion and HDR snapshot");

            // SDR 导出校验放行休眠字段。
            var sdrBatch = BatchJob.Create(photo, afterWrite.Edit!.Settings, null, "SDR");
            sdrBatch.SourceIsProRAW = true;
            sdrBatch.Validate();

            // 进入或使用 ProRAW HDR 的入口仍拒绝。
            try
            {
                var candidate = afterWrite.Edit.Settings.Restore();
                candidate.SetHDRMode(true, sourceIsHDR: true, cameraRaw: true, proRAW: true);
                throw new Exception("SetHDRMode accepted unknown ProRAWDecodeVersion");
            }
            catch (HDRModeException error)
            {
                Check(error.Failure == HDRModeFailure.InvalidSettings,
                    "Entering ProRAW HDR rejects unknown ProRAWDecodeVersion");
            }

            try
            {
                var candidate = afterWrite.Edit.Settings.Restore();
                candidate.RequireHDRDecodeVersion(proRAW: true);
                throw new Exception("RequireHDRDecodeVersion accepted unknown ProRAWDecodeVersion");
            }
            catch (HDRModeException error)
            {
                Check(error.Failure == HDRModeFailure.InvalidSettings,
                    "ProRAW HDR validation rejects unknown ProRAWDecodeVersion");
            }

            var hdrSnapshot = afterWrite.Edit.Settings with {
                HDR = new HDRSettings { Mode = HDRMode.Hdr }
            };
            try
            {
                hdrSnapshot.Restore().RequireActiveHDRDecodeVersion();
                throw new Exception("Active HDR render gate accepted unknown ProRAWDecodeVersion");
            }
            catch (HDRModeException error)
            {
                Check(error.Failure == HDRModeFailure.InvalidSettings,
                    "Direct active HDR render gate rejects unknown ProRAWDecodeVersion");
            }

            var hdrBatch = BatchJob.Create(photo, hdrSnapshot, null, "HDR");
            hdrBatch.SourceIsProRAW = true;
            try
            {
                hdrBatch.Validate();
                throw new Exception("HDR BatchJob.Validate accepted unknown ProRAWDecodeVersion");
            }
            catch (InvalidDataException) { }

            try
            {
                var hdrEdit = new SavedEdit(state.Identity, hdrSnapshot, null);
                _ = AdjustmentTransfer.Capture(AdjustmentScope.All, hdrEdit,
                    new AdjustmentTransferContext("source", true, IsProRAW: true));
                throw new Exception("HDR AdjustmentTransfer accepted unknown ProRAWDecodeVersion");
            }
            catch (AdjustmentTransferException error)
            {
                Check(error.Detail == "hdr.proraw_version",
                    "HDR transfer rejects unknown ProRAWDecodeVersion");
            }
        }
        finally { Directory.Delete(root, true); }
    }

    private static void UnknownProcessingVersionIsolatesEntryAndRecoversOnResetToUnmodified()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-entry-isolation-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var badPhoto = Path.Combine(root, "bad.ARW");
            var badJsonPhoto = Path.Combine(root, "bad-json.X3F");
            var goodPhoto = Path.Combine(root, "good.ARW");
            var untouchedPhoto = Path.Combine(root, "untouched.ARW");
            foreach (var path in new[] { badPhoto, badJsonPhoto, goodPhoto, untouchedPhoto })
                File.WriteAllText(path, "raw-" + Path.GetFileName(path));

            var storeDirectory = Path.Combine(root, "edits");
            var store = new EditStore(storeDirectory);
            foreach (var path in new[] { badPhoto, badJsonPhoto, goodPhoto, untouchedPhoto })
            {
                var initial = new Adjustments { Processing = ProcessingIdentity.C5 };
                initial.Set(Parameter.Exposure, 0.6);
                var id = OriginalIdentity.Read(path);
                var before = new SavedEdit(id, initial.Capture(), null);
                store.SaveState(id, before);
                if (path == badPhoto || path == untouchedPhoto)
                {
                    Check(ProcessingMigration.TryBuildCandidate(before, SampleMigrationResult(), out var migrated), "seed migration");
                    store.CommitProcessingMigration(id, before, migrated!, ProcessingMigrationReceipt.Migrated);
                }
            }

            var editsPath = Path.Combine(storeDirectory, "edits.json");
            var registryNode = JsonNode.Parse(File.ReadAllText(editsPath))!;
            registryNode["Records"]![Path.GetFullPath(badPhoto)]!["Settings"]!["Processing"]!["version"] = 99;
            registryNode["Records"]![Path.GetFullPath(badJsonPhoto)]!["Settings"]!["X3fMode"] = "future-x3f-v9";
            File.WriteAllText(editsPath, registryNode.ToJsonString());

            using var beforeDoc = JsonDocument.Parse(File.ReadAllText(editsPath));
            var badRawBefore = beforeDoc.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(badPhoto)).GetRawText();
            var badJsonRawBefore = beforeDoc.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(badJsonPhoto)).GetRawText();
            var untouchedRecordBefore = beforeDoc.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(untouchedPhoto)).GetRawText();
            var untouchedReceiptBefore = beforeDoc.RootElement.GetProperty("MigrationReceipts").GetProperty(Path.GetFullPath(untouchedPhoto)).GetRawText();

            // 构造不抛；其它照片可读写；坏条目原样保留。
            var reopened = new EditStore(storeDirectory);
            var session = new AdjustmentTransferSession(reopened);
            var goodState = reopened.ReadState(goodPhoto);
            Check(goodState.Edit != null, "Other photo remains readable when sibling entries are invalid");
            var updatedGood = goodState.Edit!.Settings.Restore();
            updatedGood.Set(Parameter.Exposure, 1.4);
            var goodSaved = session.CommitEdit(goodState, new SavedEdit(goodState.Identity, updatedGood.Capture(), null));
            Check(goodSaved.Status == AdjustmentStatus.Applied &&
                  reopened.Find(goodPhoto)?.Settings.Restore()[Parameter.Exposure] == 1.4,
                "Other photo remains writable when sibling entries are invalid");

            using (var afterGoodWrite = JsonDocument.Parse(File.ReadAllText(editsPath)))
            {
                Check(afterGoodWrite.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(badPhoto)).GetRawText() == badRawBefore &&
                      afterGoodWrite.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(badJsonPhoto)).GetRawText() == badJsonRawBefore &&
                      afterGoodWrite.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(untouchedPhoto)).GetRawText() == untouchedRecordBefore &&
                      afterGoodWrite.RootElement.GetProperty("MigrationReceipts").GetProperty(Path.GetFullPath(untouchedPhoto)).GetRawText() == untouchedReceiptBefore,
                    "Saving another photo preserves bad and untouched entries verbatim on disk");
            }

            // 打开坏记录照片报错。
            foreach (var broken in new[] { badPhoto, badJsonPhoto })
            {
                try
                {
                    _ = reopened.ReadState(broken);
                    throw new Exception("Reading a photo with an unusable record must fail");
                }
                catch (UnusableEditRecordException error)
                {
                    Check(!string.IsNullOrWhiteSpace(error.Message), "Unusable photo record reports a readable error");
                }
            }

            // 「重置为未修改」只删该照片的编辑记录与迁移回执，恢复后可正常打开，其它照片逐字未变。
            var cleared = session.ResetToUnmodified(badPhoto);
            Check(cleared.Edit == null && reopened.ReadState(badPhoto).Edit == null &&
                  reopened.ReadProcessingMigration(badPhoto) == null,
                "ResetToUnmodified deletes both the record and migration receipt for the target photo");
            var defaultSettings = PhotoInput.PrepareDefaultSettings(badPhoto);
            Check(defaultSettings[Parameter.Exposure] == 0, "Recovered photo prepares unmodified default settings normally");

            using (var afterResetDoc = JsonDocument.Parse(File.ReadAllText(editsPath)))
            {
                var records = afterResetDoc.RootElement.GetProperty("Records");
                var receipts = afterResetDoc.RootElement.GetProperty("MigrationReceipts");
                Check(!records.TryGetProperty(Path.GetFullPath(badPhoto), out _) &&
                      !receipts.TryGetProperty(Path.GetFullPath(badPhoto), out _),
                    "ResetToUnmodified removes only the recovered photo from Records and MigrationReceipts");
                Check(records.GetProperty(Path.GetFullPath(badJsonPhoto)).GetRawText() == badJsonRawBefore &&
                      records.GetProperty(Path.GetFullPath(untouchedPhoto)).GetRawText() == untouchedRecordBefore &&
                      receipts.GetProperty(Path.GetFullPath(untouchedPhoto)).GetRawText() == untouchedReceiptBefore &&
                      reopened.Find(goodPhoto)?.Settings.Restore()[Parameter.Exposure] == 1.4,
                    "ResetToUnmodified leaves all other photos' records and receipts verbatim unchanged");
            }

            // 整表损坏（JSON 损坏或顶层 Version != 1）仍整库拒绝。
            var brokenEnvelope = Path.Combine(root, "broken-envelope");
            Directory.CreateDirectory(brokenEnvelope);
            File.WriteAllText(Path.Combine(brokenEnvelope, "edits.json"), "{\"Version\":2,\"Records\":{}}");
            try { _ = new EditStore(brokenEnvelope); throw new Exception("Unsupported registry version was accepted"); }
            catch (InvalidDataException) { }

            File.WriteAllText(Path.Combine(brokenEnvelope, "edits.json"), "{corrupt-json");
            try { _ = new EditStore(brokenEnvelope); throw new Exception("Malformed JSON envelope was accepted"); }
            catch (JsonException) { }
        }
        finally { Directory.Delete(root, true); }
    }

    private static void MalformedSubSettingsAndEmptyArraysIsolateEntriesAndPreserveTableValidation()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-malformed-subsettings-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var outOfRangePhoto = Path.Combine(root, "out-of-range-atmosphere.ARW");
            var emptyHslPhoto = Path.Combine(root, "empty-hsl-array.ARW");
            var emptyValuesPhoto = Path.Combine(root, "empty-values-array.ARW");
            var nullValuesPhoto = Path.Combine(root, "null-values-array.ARW");
            var receiptPhoto = Path.Combine(root, "bad-receipt-subsettings.ARW");
            var healthyPhoto = Path.Combine(root, "healthy-sibling.ARW");
            var allPhotos = new[] { outOfRangePhoto, emptyHslPhoto, emptyValuesPhoto, nullValuesPhoto, receiptPhoto, healthyPhoto };
            foreach (var path in allPhotos) File.WriteAllText(path, "raw-" + Path.GetFileName(path));

            var storeDirectory = Path.Combine(root, "edits");
            var store = new EditStore(storeDirectory);
            foreach (var path in allPhotos)
            {
                var id = OriginalIdentity.Read(path);
                var before = LegacyEdit(id);
                store.SaveState(id, before);
                Check(ProcessingMigration.TryBuildCandidate(before, SampleMigrationResult(), out var migrated), "seed migration");
                store.CommitProcessingMigration(id, before, migrated!, ProcessingMigrationReceipt.Migrated);
            }

            var editsPath = Path.Combine(storeDirectory, "edits.json");
            var registryNode = JsonNode.Parse(File.ReadAllText(editsPath))!;
            var recordsNode = registryNode["Records"]!.AsObject();
            // 1) 越界子设置：反序列化通过，Restore() 内 AtmosphereSettings.NativeConfig() 抛 ArgumentOutOfRangeException。
            recordsNode[Path.GetFullPath(outOfRangePhoto)]!["Settings"]!["Atmosphere"] =
                JsonNode.Parse("{\"Clarity\":500,\"Dehaze\":0}");
            // 2) 子设置空数组：Deserialize<SavedEdit>() 调用 [JsonConstructor] HslSettings(double[]) 直接抛 ArgumentException。
            recordsNode[Path.GetFullPath(emptyHslPhoto)]!["Settings"]!["Hsl"] =
                JsonNode.Parse("{\"Values\":[]}");
            // 3) 主参数空数组与空引用：Restore() 分别抛 InvalidDataException 与 NullReferenceException。
            recordsNode[Path.GetFullPath(emptyValuesPhoto)]!["Settings"]!["Values"] = new JsonArray();
            recordsNode[Path.GetFullPath(nullValuesPhoto)]!["Settings"]!["Values"] = null;
            File.WriteAllText(editsPath, registryNode.ToJsonString());

            // 整库打开不因单条越界子设置或空数组崩掉；正常条目仍可读写。
            var reopened = new EditStore(storeDirectory);
            var session = new AdjustmentTransferSession(reopened);
            var healthyState = reopened.ReadState(healthyPhoto);
            Check(healthyState.Edit != null, "Healthy sibling remains readable when other entries have out-of-range sub-settings or empty arrays");
            var updatedHealthy = healthyState.Edit!.Settings.Restore();
            updatedHealthy.Set(Parameter.Exposure, 1.5);
            var savedHealthy = session.CommitEdit(healthyState, new SavedEdit(healthyState.Identity, updatedHealthy.Capture(), null));
            Check(savedHealthy.Status == AdjustmentStatus.Applied &&
                  reopened.Find(healthyPhoto)?.Settings.Restore()[Parameter.Exposure] == 1.5,
                "Healthy sibling remains writable when other entries have out-of-range sub-settings or empty arrays");

            // 每条坏记录统一转成 UnusableEditRecordException（使 RestoreEdits 能走 D3 手动重置弹窗），且普通覆盖被拒、手动 ResetToUnmodified 可恢复。
            foreach (var (brokenPath, expectedInner) in new (string Path, Type Inner)[] {
                (outOfRangePhoto, typeof(ArgumentOutOfRangeException)),
                (emptyHslPhoto, typeof(ArgumentException)),
                (emptyValuesPhoto, typeof(InvalidDataException)),
                (nullValuesPhoto, typeof(NullReferenceException))
            })
            {
                using var beforeDoc = JsonDocument.Parse(File.ReadAllText(editsPath));
                var rawBefore = beforeDoc.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(brokenPath)).GetRawText();

                try
                {
                    _ = reopened.ReadState(brokenPath);
                    throw new Exception("Expected UnusableEditRecordException for " + Path.GetFileName(brokenPath));
                }
                catch (UnusableEditRecordException error)
                {
                    Check(error.InnerException != null && expectedInner.IsAssignableFrom(error.InnerException.GetType()),
                        "ParseSavedEdit wraps " + expectedInner.Name + " into UnusableEditRecordException");
                }

                try
                {
                    reopened.Save(brokenPath, new Adjustments().Capture(), null);
                    throw new Exception("Ordinary Save overwrote unusable record " + Path.GetFileName(brokenPath));
                }
                catch (UnusableEditRecordException) { }

                using (var afterFailedSave = JsonDocument.Parse(File.ReadAllText(editsPath)))
                {
                    Check(afterFailedSave.RootElement.GetProperty("Records").GetProperty(Path.GetFullPath(brokenPath)).GetRawText() == rawBefore,
                        "Failed Save leaves unusable entry byte-identical on disk: " + Path.GetFileName(brokenPath));
                }

                var recovered = session.ResetToUnmodified(brokenPath);
                Check(recovered.Edit == null && reopened.ReadState(brokenPath).Edit == null &&
                      reopened.ReadProcessingMigration(brokenPath) == null,
                    "ResetToUnmodified recovers malformed entry and removes its receipt: " + Path.GetFileName(brokenPath));
            }

            // TryParseReceipt 同样兜住越界子设置与空数组，按无回执处理且不牵连邻近照片。
            foreach (var mutateReceiptSettings in new Action<JsonObject>[] {
                s => s["Atmosphere"] = JsonNode.Parse("{\"Clarity\":500,\"Dehaze\":0}"),
                s => s["Hsl"] = JsonNode.Parse("{\"Values\":[]}"),
                s => s["Values"] = new JsonArray(),
                s => s["Values"] = null
            })
            {
                var doc = JsonNode.Parse(File.ReadAllText(editsPath))!;
                var healthyReceiptClone = doc["MigrationReceipts"]![Path.GetFullPath(healthyPhoto)]!.DeepClone();
                var brokenReceiptClone = healthyReceiptClone.DeepClone().AsObject();
                var receiptIdJson = JsonSerializer.SerializeToNode(OriginalIdentity.Read(receiptPhoto))!;
                brokenReceiptClone["Identity"] = receiptIdJson.DeepClone();
                brokenReceiptClone["Before"]!["Identity"] = receiptIdJson.DeepClone();
                brokenReceiptClone["After"]!["Identity"] = receiptIdJson.DeepClone();
                mutateReceiptSettings(brokenReceiptClone["After"]!["Settings"]!.AsObject());
                doc["MigrationReceipts"]![Path.GetFullPath(receiptPhoto)] = brokenReceiptClone;
                File.WriteAllText(editsPath, doc.ToJsonString());

                var receiptStore = new EditStore(storeDirectory);
                Check(receiptStore.ReadProcessingMigration(receiptPhoto) == null,
                    "TryParseReceipt treats out-of-range sub-setting or empty-array receipt as absent");
                Check(receiptStore.ReadProcessingMigration(healthyPhoto)?.Status == ProcessingMigrationReceipt.Migrated,
                    "Healthy sibling receipt remains readable alongside malformed receipt");
            }

            // 整表结构损坏（含大小写不同的重复键）仍由 ReadRegistry 整库拒绝，绝不被单条 catch 吸收。
            var brokenTableDir = Path.Combine(root, "broken-table");
            Directory.CreateDirectory(brokenTableDir);
            foreach (var badEnvelope in new[] {
                "{\"Version\":2,\"Records\":{}}",
                "{\"Version\":1,\"Records\":[]}",
                "{\"Version\":1,\"Records\":{},\"MigrationReceipts\":[]}",
                "{\"Version\":1,\"Records\":{\"C:\\\\dup\\\\photo.ARW\":{},\"c:\\\\dup\\\\photo.arw\":{}}}",
                "{\"Version\":1,\"Records\":{},\"MigrationReceipts\":{\"C:\\\\dup\\\\photo.ARW\":{},\"c:\\\\dup\\\\photo.arw\":{}}}"
            })
            {
                File.WriteAllText(Path.Combine(brokenTableDir, "edits.json"), badEnvelope);
                try { _ = new EditStore(brokenTableDir); throw new Exception("Broken table structure was accepted: " + badEnvelope); }
                catch (UnusableEditRecordException)
                {
                    throw new Exception("Whole-table structural failure was misclassified as per-entry UnusableEditRecordException: " + badEnvelope);
                }
                catch (InvalidDataException) { }
            }
            File.WriteAllText(Path.Combine(brokenTableDir, "edits.json"), "{corrupt-root-json");
            try { _ = new EditStore(brokenTableDir); throw new Exception("Malformed root JSON was accepted"); }
            catch (JsonException) { }
        }
        finally { Directory.Delete(root, true); }
    }

    private static void CorruptReceiptDoesNotBreakStoreAndActsAsAbsent()
    {
        var root = Path.Combine(Path.GetTempPath(), "rawlab-corrupt-receipt-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            var brokenReceiptPhoto = Path.Combine(root, "broken-receipt.ARW");
            var healthyPhoto = Path.Combine(root, "healthy.ARW");
            File.WriteAllText(brokenReceiptPhoto, "raw-1");
            File.WriteAllText(healthyPhoto, "raw-2");

            var storeDirectory = Path.Combine(root, "edits");
            var store = new EditStore(storeDirectory);
            var brokenId = OriginalIdentity.Read(brokenReceiptPhoto);
            var healthyId = OriginalIdentity.Read(healthyPhoto);

            var brokenBefore = LegacyEdit(brokenId);
            var healthyBefore = LegacyEdit(healthyId);
            store.SaveState(brokenId, brokenBefore);
            store.SaveState(healthyId, healthyBefore);
            Check(ProcessingMigration.TryBuildCandidate(healthyBefore, SampleMigrationResult(), out var healthyMigrated), "healthy candidate");
            store.CommitProcessingMigration(healthyId, healthyBefore, healthyMigrated!, ProcessingMigrationReceipt.Migrated);
            store.CommitProcessingMigration(brokenId, brokenBefore, brokenBefore, ProcessingMigrationReceipt.Kept);

            var editsPath = Path.Combine(storeDirectory, "edits.json");
            foreach (var corruptJson in new[] {
                "\"corrupt-string-receipt\"",
                "{\"Status\":\"unknownStatus\"}",
                "{\"Identity\":null,\"Before\":null,\"After\":null,\"Status\":\"migrated\"}"
            })
            {
                var node = JsonNode.Parse(File.ReadAllText(editsPath))!;
                node["MigrationReceipts"]![brokenId.Path] = JsonNode.Parse(corruptJson);
                File.WriteAllText(editsPath, node.ToJsonString());

                var reopened = new EditStore(storeDirectory);
                Check(reopened.ReadProcessingMigration(brokenReceiptPhoto) == null,
                    "Corrupt receipt is treated as no receipt for that photo");
                Check(ProcessingMigration.ShouldAttempt(brokenBefore, reopened.ReadProcessingMigration(brokenReceiptPhoto)),
                    "Absent receipt semantics allow normal ShouldAttempt evaluation without modifying ShouldAttempt");
                Check(reopened.ReadProcessingMigration(healthyPhoto)?.Status == ProcessingMigrationReceipt.Migrated,
                    "Healthy sibling receipt remains readable");
                try
                {
                    reopened.RollbackProcessingMigration(brokenId, reopened.ReadState(brokenReceiptPhoto));
                    throw new Exception("Corrupt receipt permitted rollback");
                }
                catch (AdjustmentOperationExpiredException) { }
            }
        }
        finally { Directory.Delete(root, true); }
    }

    private static void ResetTransactionClearsReceiptAndUndoRestoresValuesWithoutRestoringReceipt()
    {
        foreach (var initialStatus in new[] {
            ProcessingMigrationReceipt.Migrated,
            ProcessingMigrationReceipt.Kept,
            ProcessingMigrationReceipt.RolledBack
        })
        {
            var root = Path.Combine(Path.GetTempPath(), "rawlab-reset-receipt-" + Guid.NewGuid());
            Directory.CreateDirectory(root);
            try
            {
                var photo = Path.Combine(root, "photo.ARW");
                var sibling = Path.Combine(root, "sibling.ARW");
                File.WriteAllText(photo, "raw-photo");
                File.WriteAllText(sibling, "raw-sibling");

                var storeDirectory = Path.Combine(root, "edits");
                var store = new EditStore(storeDirectory);
                var session = new AdjustmentTransferSession(store);
                var identity = OriginalIdentity.Read(photo);
                var siblingId = OriginalIdentity.Read(sibling);

                var before = LegacyEdit(identity);
                var siblingBefore = LegacyEdit(siblingId);
                store.SaveState(identity, before);
                store.SaveState(siblingId, siblingBefore);

                Check(ProcessingMigration.TryBuildCandidate(siblingBefore, SampleMigrationResult(), out var siblingMigrated), "sibling migration");
                store.CommitProcessingMigration(siblingId, siblingBefore, siblingMigrated!, ProcessingMigrationReceipt.Migrated);

                Check(ProcessingMigration.TryBuildCandidate(before, SampleMigrationResult(), out var migrated), "target migration");
                PhotoEditState committed;
                if (initialStatus == ProcessingMigrationReceipt.Kept)
                    committed = store.CommitProcessingMigration(identity, before, before, ProcessingMigrationReceipt.Kept);
                else
                {
                    committed = store.CommitProcessingMigration(identity, before, migrated!, ProcessingMigrationReceipt.Migrated);
                    if (initialStatus == ProcessingMigrationReceipt.RolledBack)
                        committed = store.RollbackProcessingMigration(identity, committed);
                }
                session.AdoptExternalProcessingMigration(committed);
                Check(store.ReadProcessingMigration(photo)?.Status == initialStatus, "Precondition receipt status matches " + initialStatus);

                // 局部工具重置不应清除迁移回执。
                var toolScope = new EditorResetScope(EditorResetKind.Tool, Tool: EditorAdjustmentTool.Exposure);
                Check(!EditorAdjustmentRules.ClearsMigrationReceipt(toolScope), "Partial tool reset does not flag receipt clearing");

                // 会话层重置事务提交路径（真实 MainWindow 入口链路由 EditDurabilityWindowChecks 覆盖）。
                var allScope = new EditorResetScope(EditorResetKind.All);
                Check(EditorAdjustmentRules.ClearsMigrationReceipt(allScope), "All-reset explicitly flags receipt clearing");
                var context = new EditorResetContext(committed.Edit!.Look, TransformGeneration: 0);
                var prepared = EditorResetTransaction.Prepare(allScope, photo, openRevision: 1, editRevision: 1, committed.Edit, context);
                Check(prepared.Status == EditorResetStatus.Ready && prepared.Candidate != null,
                    "All-reset prepares a non-null neutral SavedEdit");
                Check(prepared.Candidate!.Settings.Processing == committed.Edit.Settings.Processing,
                    "All-reset retains Processing identity on non-null SavedEdit");

                AdjustmentOutcome? resetOutcome = null;
                var ran = prepared.TryCommit(photo, 1, 1, committed.Edit, context, candidate =>
                {
                    resetOutcome = session.CommitEdit(committed, candidate, defaultEdit: null,
                        clearMigrationReceipt: EditorAdjustmentRules.ClearsMigrationReceipt(prepared.Scope));
                });
                Check(ran && resetOutcome is { Status: AdjustmentStatus.Applied, Saved: { Edit: not null } },
                    "Reset commit writes the neutral SavedEdit");

                // 迁移回执已清除（内存与重启后均不存在），回滚抛 AdjustmentOperationExpiredException。
                Check(store.ReadProcessingMigration(photo) == null &&
                      new EditStore(storeDirectory).ReadProcessingMigration(photo) == null,
                    "Reset clears migration receipt for status " + initialStatus);
                Check(store.ReadProcessingMigration(sibling)?.Status == ProcessingMigrationReceipt.Migrated,
                    "Resetting one photo preserves sibling migration receipts");

                try
                {
                    store.RollbackProcessingMigration(identity, resetOutcome!.Saved!);
                    throw new Exception("Rollback succeeded after reset cleared receipt");
                }
                catch (AdjustmentOperationExpiredException) { }

                // 既定语义（方案 b）：reset 是带确认的破坏性操作，undo 只恢复调整数值，不恢复迁移回执。
                var undone = session.UndoPhoto(photo).Single();
                Check(undone.Status == AdjustmentStatus.Applied &&
                      undone.Saved?.Edit != null &&
                      undone.Saved.Edit.SameAs(committed.Edit) &&
                      store.ReadState(photo).SameAs(committed),
                    "Undo after all-reset restores pre-reset adjustment values for status " + initialStatus);
                Check(store.ReadProcessingMigration(photo) == null &&
                      new EditStore(storeDirectory).ReadProcessingMigration(photo) == null,
                    "Undo after all-reset leaves migration receipt absent (nil) for status " + initialStatus);
                try
                {
                    store.RollbackProcessingMigration(identity, undone.Saved!);
                    throw new Exception("Rollback succeeded after undoing all-reset");
                }
                catch (AdjustmentOperationExpiredException) { }
            }
            finally { Directory.Delete(root, true); }
        }
    }

    private static SavedEdit LegacyEdit(OriginalIdentity identity)
    {
        var settings = new Adjustments { Processing = ProcessingIdentity.C5 };
        settings.Set(Parameter.Exposure, 0.7);
        settings.Set(Parameter.Contrast, 18);
        return new(identity, settings.Capture(), "film.cube");
    }

    private static Native.ProcessingMigrationResult SampleMigrationResult() => new() {
        Version = 1, StructSize = 80, SourceVersion = 2, TargetVersion = 3,
        Disposition = 1, EvaluationCount = 8,
        ExposureEv = 1.1f, Contrast = 1.18f, Highlights = 0f, Shadows = 0f,
        Saturation = 1f, BlackPoint = 0f, WhitePoint = 0f, Vibrance = 0f,
        Clarity = 0f, Dehaze = 0f, RgbRmse = .002f, P99Error = .01f,
        WorstTileRmse = .004f, DetailRmse = .003f
    };
}
