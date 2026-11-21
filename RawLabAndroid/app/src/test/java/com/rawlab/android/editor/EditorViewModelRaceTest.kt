package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.editor.render.LookResult
import com.rawlab.android.editor.render.LookWork
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.runLookWork
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.looks.LookLibrary
import com.rawlab.android.settings.DenoisePreset
import com.rawlab.android.settings.DenoiseSettings
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.HDRMode
import com.rawlab.android.settings.HDRSettings
import com.rawlab.android.settings.HslTargetAvailability
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.ProcessingIdentity
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class EditorViewModelRaceTest {
    @Test fun denoiseResizeWaitsForQuietAndKeepsLatestEditsAndExportCancelRestoresViewport() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("resize.raw")
            val model = harness.createViewModel(previewResizeDelayMs = 80L)
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                harness.onMain {
                    model.edit(model.state.value.edits.copy(denoise = DenoiseSettings().withPreset(DenoisePreset.CLEAN)))
                }
                harness.awaitState(model) { it.canExport }

                harness.onMain {
                    model.updatePreviewSize(768)
                    model.updatePreviewSize(512)
                    assertTrue(model.state.value.previewResizePending)
                    assertFalse(model.state.value.canExport)
                    model.edit(model.state.value.edits.copy(exposure = .5f))
                }
                harness.awaitState(model) { it.canExport && it.preview?.nativeWidth == 512 }
                assertEquals(.5f, model.state.value.edits.exposure, 0f)

                harness.onMain {
                    model.updatePreviewSize(640)
                    model.updatePreviewSize(512)
                    assertFalse(model.state.value.previewResizePending)
                }
                assertTrue(model.state.value.canExport)

                harness.onMain {
                    model.updatePreviewSize(768)
                    model.edit(model.state.value.edits.copy(denoise = model.state.value.edits.denoise.copy(enabled = false)))
                    assertFalse(model.state.value.previewResizePending)
                }
                harness.awaitState(model) { it.canExport && it.preview?.nativeWidth == 768 }

                harness.onMain {
                    model.updatePreviewSize(1216)
                    model.edit(model.state.value.edits.copy(exposure = .75f), interactive = true)
                }
                harness.awaitState(model) { !it.rendering && it.preview?.nativeWidth == 1000 }
                assertFalse(model.state.value.exact)

                harness.onMain { model.edit(model.state.value.edits) }
                harness.awaitState(model) { it.canExport }

                harness.onMain { model.beginExport { assertTrue(it) } }
                harness.awaitState(model) { it.operation == Operation.PICK_EXPORT }
                harness.onMain {
                    model.updatePreviewSize(896)
                    model.cancelExport()
                }
                harness.awaitState(model) { it.canExport && it.preview?.nativeWidth == 896 }
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun sourceSwitchRejectsPendingOldPixels() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uriA) = harness.createTempPhoto("a.raw")
            val (_, uriB) = harness.createTempPhoto("b.raw")
            val enteredInteractiveA = CountDownLatch(1)
            val releaseInteractiveA = CountDownLatch(1)
            val model = harness.createViewModel(
                renderHandler = { work, cancellation ->
                    if (work is Work.Preview && work.interactive && work.photo.uri == uriA) {
                        enteredInteractiveA.countDown()
                        check(releaseInteractiveA.await(5, TimeUnit.SECONDS))
                    }
                    harness.defaultRender(work)
                },
            )
            try {
                harness.onMain { model.importPhoto(uriA) }
                harness.awaitState(model) { it.canExport }

                harness.onMain {
                    model.edit(model.state.value.edits.copy(exposure = 1f), interactive = true)
                    assertTrue(model.state.value.rendering)
                }
                assertTrue(enteredInteractiveA.await(5, TimeUnit.SECONDS))

                harness.onMain { model.importPhoto(uriB) }
                releaseInteractiveA.countDown()
                harness.awaitState(model) { it.photo?.uri == uriB && it.canExport }
                assertEquals(0f, model.state.value.edits.exposure, 0f)
            } finally {
                releaseInteractiveA.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun startupLookLoadSurvivesImmediatePhotoImport() {
        EditorViewModelTestHarness().use { harness ->
            val source = harness.syntheticCube("startup.cube")
            val managed = LookLibrary(File(harness.app.filesDirectory, "looks"), harness.testLookValidator, harness.testDcpCompiler)
                .importLook(source)
            val (_, uri) = harness.createTempPhoto("startup.raw")
            val enteredLoad = CountDownLatch(1)
            val releaseLoad = CountDownLatch(1)
            val storage = harness.createStorage()
            val model = harness.createViewModel(
                storage = storage,
                lookWorkRunner = { work ->
                    if (work is LookWork.Load) {
                        enteredLoad.countDown()
                        check(releaseLoad.await(5, TimeUnit.SECONDS))
                    }
                    runLookWork(storage, work)
                },
            )
            try {
                assertTrue(enteredLoad.await(5, TimeUnit.SECONDS))
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.photo?.uri == uri && it.canExport }
                releaseLoad.countDown()
                harness.awaitState(model) { it.looks.any { look -> look.id == managed.id } }
            } finally {
                releaseLoad.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun importedLookDuringExactPreviewIsSelectedAndRerenderedAndBatchPartialSuccessSurvives() {
        EditorViewModelTestHarness().use { harness ->
            val first = harness.syntheticCube("first.cube")
            val last = harness.syntheticCube("last.cube")
            val bad = File(harness.root, "bad.cube").apply { writeText("invalid") }
            val (_, uri) = harness.createTempPhoto("looks.raw")
            val model = harness.createViewModel()
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                harness.onMain {
                    model.edit(model.state.value.edits.copy(exposure = .25f))
                    model.importLook(TestUri.of("/${first.absolutePath.trimStart('/')}", scheme = "file", authority = ""))
                }
                harness.awaitState(model) { it.canExport && it.looks.any { look -> look.managed && look.name == first.name } }
                val firstId = model.state.value.edits.film
                assertNotEquals("neutral", firstId)

                harness.onMain { model.deleteLook(firstId) }
                harness.awaitState(model) { it.canExport && it.edits.film == "neutral" && it.looks.none { l -> l.id == firstId } }

                harness.onMain {
                    model.importLooks(
                        listOf(first, bad, last).map { TestUri.of("/${it.absolutePath.trimStart('/')}", scheme = "file", authority = "") },
                    )
                    assertEquals(Operation.IMPORT_LOOK, model.state.value.operation)
                }
                harness.awaitState(model) { it.canExport && it.looks.count { l -> l.managed } == 2 }
                assertEquals(last.name, model.state.value.looks.single { it.id == model.state.value.edits.film }.name)
                assertTrue(model.state.value.lookImportReport != null)

                harness.onMain { model.dismissLookImportReport() }
                assertNull(model.state.value.lookImportReport)
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun restoredViewportAndFailedSavePreviewRetryPerformZeroRecordWrites() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("retry.raw")
            val writes = AtomicInteger()
            val failWrites = AtomicBoolean(false)
            val model = harness.createViewModel(
                editStoreFactory = { dir ->
                    EditStore(dir) { from, to ->
                        if (failWrites.get()) error("injected write failure")
                        writes.incrementAndGet()
                        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }
                harness.onMain { model.edit(model.state.value.edits.copy(exposure = .5f, customWb = true, temperature = 4000f, tint = 5f)) }
                harness.awaitState(model) { it.canExport }

                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }
                assertEquals(EditSaveState.RESTORED, model.state.value.saveState)

                val writesBeforeViewport = writes.get()
                harness.onMain { model.updatePreviewSize(320) }
                harness.awaitState(model) { it.canExport && it.preview?.nativeWidth == 320 }
                assertEquals("Viewport resize on restored photo must write zero records", writesBeforeViewport, writes.get())

                // Inject save failure, then trigger preview error and retry preview.
                failWrites.set(true)
                harness.onMain { model.edit(model.state.value.edits.copy(exposure = 1f)) }
                harness.awaitState(model) { it.exact && !it.rendering && !it.committingAdjustments }
                assertEquals(EditSaveState.FAILED, model.state.value.saveState)

                val writesBeforeRetry = writes.get()
                harness.onMain { model.retry() }
                harness.awaitState(model) { it.exact && !it.rendering && !it.committingAdjustments }
                assertEquals("Preview retry must not turn failed save into success", EditSaveState.FAILED, model.state.value.saveState)
                assertEquals(writesBeforeRetry, writes.get())
                assertFalse(model.state.value.canExport)
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun resetCommitRejectsStaleEditsAndGeometryDraftResetStaysInDraft() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("reset.raw")
            val writes = AtomicInteger()
            val model = harness.createViewModel(
                editStoreFactory = { dir ->
                    EditStore(dir) { from, to ->
                        writes.incrementAndGet()
                        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }
                harness.onMain {
                    model.edit(
                        model.state.value.edits.copy(
                            processing = ProcessingIdentity.LEGACY,
                            exposure = .5f,
                            customWb = true,
                            temperature = 4000f,
                            lens = LensSettings(autoCrop = false),
                        ),
                    )
                }
                harness.awaitState(model) { it.canExport }

                lateinit var stale: PreparedEditorReset
                harness.onMain {
                    stale = model.prepareReset(EditorResetScope.Tool(2)).prepared!!
                    model.edit(model.state.value.edits.copy(exposure = 1f))
                }
                harness.awaitState(model) { it.canExport }

                val writesBeforeStale = writes.get()
                harness.onMain { assertFalse(model.commitReset(stale)) }
                assertEquals(writesBeforeStale, writes.get())
                assertEquals(1f, model.state.value.edits.exposure, 0f)

                // Geometry group reset inside LENS draft stays in draft until applyDraft.
                harness.onMain { model.beginDraft(AdjustmentGroup.LENS) }
                harness.awaitState(model) { it.draftReady }
                harness.onMain {
                    val prepared = model.prepareReset(EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY)).prepared!!
                    assertTrue(model.commitReset(prepared))
                    assertFalse(model.state.value.visibleEdits.lens.autoCrop == false)
                    assertEquals(false, model.state.value.edits.lens.autoCrop)
                }
                harness.awaitState(model) { it.canApplyDraft }
                harness.onMain { model.applyDraft { assertTrue(it) } }
                harness.awaitState(model) { it.canExport }
                assertTrue(model.state.value.edits.lens.autoCrop)
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun hslEyedropperRejectsStaleProbeAfterPhotoSwitchAndCancelUndoesInteraction() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uriA) = harness.createTempPhoto("hsl_a.raw")
            val (_, uriB) = harness.createTempPhoto("hsl_b.raw")
            val probeEntered = CountDownLatch(1)
            val releaseProbe = CountDownLatch(1)
            val model = harness.createViewModel(
                renderHandler = { work, _ ->
                    if (work is Work.HslProbe) {
                        probeEntered.countDown()
                        check(releaseProbe.await(5, TimeUnit.SECONDS))
                        WorkResult.HslProbe(
                            work,
                            HslTargetSample(
                                work.revision,
                                HslTargetAvailability.AVAILABLE,
                                listOf(1f, 0.2f, 0.1f),
                                listOf(1f, 0f, 0f, 0f, 0f, 0f, 0f, 0f),
                                preview = true,
                            ),
                        )
                    } else harness.defaultRender(work)
                },
            )
            try {
                harness.onMain { model.importPhoto(uriA) }
                harness.awaitState(model) { it.canExport }
                harness.onMain {
                    model.beginDraft(AdjustmentGroup.HSL)
                    model.setHslTargetEnabled(true)
                }
                harness.awaitState(model) { it.draftReady }
                harness.onMain { model.beginHslTarget(0.5f, 0.5f) }
                assertTrue(probeEntered.await(5, TimeUnit.SECONDS))
                assertTrue(model.hslTarget.value.waiting)

                // Cancel draft and switch to photo B while probe is in flight.
                harness.onMain {
                    model.discardDraft()
                    model.importPhoto(uriB)
                }
                releaseProbe.countDown()
                harness.awaitState(model) { it.photo?.uri == uriB && it.canExport }
                assertFalse(model.hslTarget.value.waiting)
                assertFalse(model.hslTarget.value.enabled)
            } finally {
                releaseProbe.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun exportStateHolderSupportsQ12LateCompletionAndRejectsInvalidSizeWithCleanup() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("export.raw")
            val exportEntered = CountDownLatch(1)
            val releaseExport = CountDownLatch(1)
            val model = harness.createViewModel(
                renderHandler = { work, _ ->
                    if (work is Work.Export) {
                        exportEntered.countDown()
                        check(releaseExport.await(5, TimeUnit.SECONDS))
                        WorkResult.Export
                    } else harness.defaultRender(work)
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                // Invalid size schedules cleanup of pre-created document destination.
                harness.onMain { model.beginExport { assertTrue(it) } }
                harness.awaitState(model) { it.operation == Operation.PICK_EXPORT }
                val badDest = TestUri.of("/exports/bad.jpg")
                harness.onMain { model.export(badDest, ExportFormat.JPEG, longEdge = 0) }
                harness.awaitState(model) { it.operation == Operation.NONE && it.error != null }
                harness.drainMain()
                assertTrue(harness.deletedIncompleteExports.any { it.first == badDest })

                // Valid export, cancelled right after native commit point -> Q12 reports Export complete.
                harness.onMain { model.beginExport { assertTrue(it) } }
                harness.awaitState(model) { it.operation == Operation.PICK_EXPORT }
                harness.onMain { model.export(TestUri.of("/exports/ok.jpg"), ExportFormat.JPEG, longEdge = 1000) }
                assertTrue(exportEntered.await(5, TimeUnit.SECONDS))
                harness.onMain { model.cancelExport() }
                assertEquals(Operation.NONE, model.state.value.operation)
                releaseExport.countDown()
                harness.awaitState(model) { it.message == "Export complete" }
            } finally {
                releaseExport.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun hdrStateHolderCancelsInFlightLookImportWithoutHangingOperation() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("hdr.jpg")
            val lookEntered = CountDownLatch(1)
            val releaseLook = CountDownLatch(1)
            val hdrPhoto = com.rawlab.android.photo.ImportedPhoto(
                uri,
                "hdr.jpg",
                File(uri.path!!),
                com.rawlab.android.settings.PhotoIdentity(uri.toString()),
                com.rawlab.android.format.PhotoInputKind.RASTER,
                hdrSource = com.rawlab.android.photo.HDRSourceInfo(
                    1600, 1200, 1, 1, 1, 1, 2f, 1, ByteArray(32),
                ),
                validateOriginal = { check(File(uri.path!!).isFile) },
            )
            val model = harness.createViewModel(
                renderHandler = { work, _ ->
                    when (work) {
                        is Work.Import -> WorkResult.Preview(
                            Work.Preview(hdrPhoto, EditSettings(hdr = HDRSettings(mode = HDRMode.HDR)), false, work.gpuMode, importing = true),
                            TestBitmaps.pair(1600, 1200),
                        )
                        is Work.Preview -> WorkResult.Preview(work, TestBitmaps.pair(work.edge, (work.edge * 3) / 4))
                        else -> harness.defaultRender(work)
                    }
                },
                hdrLookImporter = {
                    lookEntered.countDown()
                    check(releaseLook.await(5, TimeUnit.SECONDS))
                    com.rawlab.android.settings.HDRLookSettings("a".repeat(64), "hdr-look.cube", 1f)
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport && it.edits.isHDREditing }

                harness.onMain {
                    assertTrue(model.beginHDRLookImport())
                    model.finishHDRLookImport(TestUri.of("/looks/custom.cube"))
                }
                assertTrue(lookEntered.await(5, TimeUnit.SECONDS))
                assertEquals(Operation.IMPORT_LOOK, model.state.value.operation)
                assertTrue(model.state.value.importingHDRLook)

                harness.onMain { model.cancelHDRLookImport() }
                assertEquals(Operation.NONE, model.state.value.operation)
                assertFalse(model.state.value.importingHDRLook)
                assertEquals("Cancelled", model.state.value.message)
                releaseLook.countDown()
                harness.drainMain()
                assertNull(model.state.value.edits.hdr?.lookSettings?.sha256)
            } finally {
                releaseLook.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun busyAdjustmentCommitRejectsConcurrentPasteAndClosedOperationReleasesOwnedCopy() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uriA) = harness.createTempPhoto("paste_a.raw")
            val ownedCopy = File(harness.root, "owned-copy.raw").apply { writeText("copy") }
            val commitEntered = CountDownLatch(1)
            val releaseCommit = CountDownLatch(1)
            val holdCommit = AtomicBoolean(false)
            val model = harness.createViewModel(
                editStoreFactory = { dir ->
                    EditStore(dir) { from, to ->
                        if (holdCommit.get()) {
                            commitEntered.countDown()
                            check(releaseCommit.await(5, TimeUnit.SECONDS))
                        }
                        Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uriA) }
                harness.awaitState(model) { it.canExport }

                harness.onMain {
                    model.prepareAdjustmentOperation = { work, _ ->
                        val target = com.rawlab.android.adjustments.PreparedAdjustmentTransfer.Target(
                            id = "target",
                            displayName = "target",
                            original = com.rawlab.android.settings.PhotoEditState(
                                com.rawlab.android.settings.PhotoIdentity("target"),
                                EditSettings(),
                            ),
                            candidate = EditSettings(exposure = .5f),
                            unchanged = false,
                            isCurrent = { true },
                            validateSource = null,
                            error = null,
                        )
                        val op = com.rawlab.android.adjustments.PreparedAdjustmentTransfer(
                            java.util.UUID.randomUUID(),
                            work.payload,
                            listOf(target),
                            work.action,
                        )
                        AdjustmentPreparationResult(work.generation, op, mapOf("target" to ownedCopy))
                    }
                    val payload = model.copyAdjustments(AdjustmentScope.All)!!
                    model.prepareAdjustmentPaste(payload, listOf(TestUri.of("/target.raw")))
                }
                harness.awaitState(model) { model.adjustmentTransfer.value.prepared != null }
                val prepared = model.adjustmentTransfer.value.prepared!!

                holdCommit.set(true)
                var busyPasteCalls = 0
                harness.onMain {
                    model.edit(model.state.value.edits.copy(exposure = .8f))
                }
                assertTrue(commitEntered.await(5, TimeUnit.SECONDS))
                harness.onMain {
                    model.applyAdjustmentPaste(prepared) { outcomes ->
                        busyPasteCalls++
                        assertEquals(AdjustmentStatus.FAILED, outcomes.single().status)
                        assertEquals(AdjustmentFailure.DRAFT, (outcomes.single().error as AdjustmentTransferException).reason)
                    }
                    model.closeAdjustmentOperation()
                }
                assertEquals(1, busyPasteCalls)
                assertTrue("Owned copy stays alive until commit finishes", ownedCopy.exists())
                releaseCommit.countDown()
                harness.awaitState(model) { !it.committingAdjustments }
                assertFalse("Owned copy is deleted once commit releases", ownedCopy.exists())
            } finally {
                releaseCommit.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun beginExportTracksPrepareStepAndSurvivesCollectorRecreationAndDestinationPick() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("export-step-recreate.raw")
            val holdPersist = AtomicBoolean(false)
            val persistEntered = CountDownLatch(1)
            val releasePersist = CountDownLatch(1)
            val model = harness.createViewModel(
                sourceValidator = { photo ->
                    {
                        check(photo.file.isFile)
                        if (holdPersist.get()) {
                            persistEntered.countDown()
                            check(releasePersist.await(5, TimeUnit.SECONDS))
                        }
                    }
                },
            )
            var collectorJob: kotlinx.coroutines.Job? = null
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                holdPersist.set(true)
                val completedLatch = CountDownLatch(1)
                val completedResult = AtomicBoolean(false)
                harness.onMain {
                    model.beginExport {
                        completedResult.set(it)
                        completedLatch.countDown()
                    }
                    val preparing = model.state.value
                    assertEquals(Operation.PREPARE_EXPORT, preparing.operation)
                    assertEquals(SingleExportStep.PREPARING, preparing.exportStep)
                    assertFalse(preparing.exportOptionsVisible)
                    assertFalse(preparing.canExport)
                }
                assertTrue(persistEntered.await(5, TimeUnit.SECONDS))

                // Simulate recreated UI subscribing after beginExport() started but before onPersist finishes.
                val freshObserved = CopyOnWriteArrayList<EditorState>()
                val sawPreparing = CountDownLatch(1)
                val sawOptions = CountDownLatch(1)
                harness.onMain {
                    collectorJob = harness.scope.launch {
                        model.state.collect { snapshot ->
                            freshObserved += snapshot
                            if (snapshot.operation == Operation.PREPARE_EXPORT &&
                                snapshot.exportStep == SingleExportStep.PREPARING &&
                                !snapshot.exportOptionsVisible
                            ) {
                                sawPreparing.countDown()
                            }
                            if (snapshot.operation == Operation.PICK_EXPORT &&
                                snapshot.exportStep == SingleExportStep.OPTIONS &&
                                snapshot.exportOptionsVisible
                            ) {
                                sawOptions.countDown()
                            }
                        }
                    }
                }
                assertTrue(sawPreparing.await(5, TimeUnit.SECONDS))

                releasePersist.countDown()
                assertTrue(completedLatch.await(5, TimeUnit.SECONDS))
                assertTrue(completedResult.get())
                assertTrue(sawOptions.await(5, TimeUnit.SECONDS))
                assertTrue(freshObserved.last().exportOptionsVisible)

                harness.onMain {
                    model.beginExportDestinationPick()
                    val picking = model.state.value
                    assertEquals(Operation.PICK_EXPORT, picking.operation)
                    assertEquals(SingleExportStep.PICKING_DESTINATION, picking.exportStep)
                    assertFalse(picking.exportOptionsVisible)
                }

                harness.onMain {
                    model.returnToExportOptions()
                    val restored = model.state.value
                    assertEquals(Operation.PICK_EXPORT, restored.operation)
                    assertEquals(SingleExportStep.OPTIONS, restored.exportStep)
                    assertTrue(restored.exportOptionsVisible)
                }

                harness.onMain {
                    model.cancelExport()
                    val cancelled = model.state.value
                    assertEquals(Operation.NONE, cancelled.operation)
                    assertEquals(SingleExportStep.NONE, cancelled.exportStep)
                    assertFalse(cancelled.exportOptionsVisible)
                }
            } finally {
                collectorJob?.cancel()
                releasePersist.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun cancelDuringPrepareExportInvalidatesInFlightPersistAndFailureResetsStep() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("export-prepare-cancel.raw")
            val holdPersist = AtomicBoolean(false)
            val failPersist = AtomicBoolean(false)
            val persistEntered = CountDownLatch(1)
            val releasePersist = CountDownLatch(1)
            val model = harness.createViewModel(
                sourceValidator = { photo ->
                    {
                        check(photo.file.isFile)
                        if (holdPersist.get()) {
                            persistEntered.countDown()
                            check(releasePersist.await(5, TimeUnit.SECONDS))
                        }
                        if (failPersist.get()) throw IOException("disk full")
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                holdPersist.set(true)
                val cancelledLatch = CountDownLatch(1)
                val cancelledResult = AtomicBoolean(true)
                harness.onMain {
                    model.beginExport {
                        cancelledResult.set(it)
                        cancelledLatch.countDown()
                    }
                    assertEquals(Operation.PREPARE_EXPORT, model.state.value.operation)
                    assertEquals(SingleExportStep.PREPARING, model.state.value.exportStep)
                }
                assertTrue(persistEntered.await(5, TimeUnit.SECONDS))

                harness.onMain {
                    model.cancelExport()
                    assertEquals(Operation.NONE, model.state.value.operation)
                    assertEquals(SingleExportStep.NONE, model.state.value.exportStep)
                    assertFalse(model.state.value.exportOptionsVisible)
                }

                releasePersist.countDown()
                assertTrue(cancelledLatch.await(5, TimeUnit.SECONDS))
                assertFalse(cancelledResult.get())
                harness.awaitState(model) { !it.committingAdjustments }
                harness.drainMain()
                assertEquals(Operation.NONE, model.state.value.operation)
                assertEquals(SingleExportStep.NONE, model.state.value.exportStep)
                assertFalse(model.state.value.exportOptionsVisible)
                assertTrue(model.state.value.canExport)

                // A persist failure during PREPARE_EXPORT resets operation & exportStep and surfaces saveError.
                holdPersist.set(false)
                failPersist.set(true)
                val failedLatch = CountDownLatch(1)
                val failedResult = AtomicBoolean(true)
                harness.onMain {
                    model.beginExport {
                        failedResult.set(it)
                        failedLatch.countDown()
                    }
                }
                assertTrue(failedLatch.await(5, TimeUnit.SECONDS))
                assertFalse(failedResult.get())
                val failedState = model.state.value
                assertEquals(Operation.NONE, failedState.operation)
                assertEquals(SingleExportStep.NONE, failedState.exportStep)
                assertFalse(failedState.exportOptionsVisible)
                assertEquals(EditSaveState.FAILED, failedState.saveState)
                assertNotNull(failedState.saveError)
                assertFalse(failedState.canExport)
            } finally {
                releasePersist.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }
}
