package com.rawlab.android.editor

import android.net.TestUri
import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentScope
import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.editor.canvas.DetailTileKey
import com.rawlab.android.editor.canvas.NormalizedRect
import com.rawlab.android.editor.canvas.ViewportRoiRequest
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

    @Test fun curveTargetEyedropperAdjustsCurveUndoablyAndCancelsOnDemand() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uriA) = harness.createTempPhoto("curve_a.raw")
            val model = harness.createViewModel(
                renderHandler = { work, _ ->
                    if (work is Work.HslProbe) {
                        WorkResult.HslProbe(
                            work,
                            HslTargetSample(
                                work.revision,
                                HslTargetAvailability.NEAR_GRAY,
                                listOf(0.4f, 0.4f, 0.4f),
                                emptyList(),
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
                    model.beginDraft(AdjustmentGroup.CURVE)
                    model.setHslTargetEnabled(true)
                }
                harness.awaitState(model) { it.draftReady }
                assertTrue(model.hslTarget.value.curveMode)
                harness.onMain {
                    model.beginHslTarget(0.5f, 0.5f)
                    model.moveHslTarget(40f)
                    model.endHslTarget()
                }
                harness.awaitState(model) { it.visibleEdits.curve.mode == com.rawlab.android.settings.ToneCurveMode.CUSTOM }
                assertEquals(3, model.state.value.visibleEdits.curve.points.size)
                assertEquals(0.6, model.state.value.visibleEdits.curve.points[1].y, 1e-6)
                assertTrue(model.state.value.draft!!.canUndo)
                harness.onMain { model.undoDraft() }
                assertEquals(com.rawlab.android.settings.ToneCurveMode.LEGACY, model.state.value.visibleEdits.curve.mode)
            } finally {
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

    @Test fun detailOverlayLifecycleSkipsOverscanHitsResharpensAfterEditAndDegradesSilently() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("detail-roi.raw")
            val detailCalls = AtomicInteger()
            val failDetail = AtomicBoolean(false)
            val failedDetailRan = CountDownLatch(1)
            val model = harness.createViewModel(
                detailDebounceDelayMs = 20L,
                renderHandler = { work, _ ->
                    when (work) {
                        is Work.Import -> {
                            val imported = harness.defaultRender(work) as WorkResult.Preview
                            WorkResult.Preview(imported.request, TestBitmaps.pair(4000, 3000))
                        }
                        is Work.Preview -> WorkResult.Preview(work, TestBitmaps.pair(4000, 3000))
                        is Work.DetailPreview -> {
                            detailCalls.incrementAndGet()
                            if (failDetail.get()) {
                                failedDetailRan.countDown()
                                throw RuntimeException("simulated detail OOM")
                            }
                            harness.defaultRender(work)
                        }
                        else -> harness.defaultRender(work)
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                val regionA = ViewportRoiRequest(
                    visibleRect = NormalizedRect(0.05f, 0.05f, 0.20f, 0.25f),
                    overscanRect = NormalizedRect(0.03f, 0.03f, 0.22f, 0.27f),
                    zoomScale = 1f,
                    baseScale = 1600f / 4000f,
                    maxOutputLongEdge = 2048,
                )
                harness.onMain { model.updateDetailRequest(regionA) }
                harness.awaitState(model) { it.detail != null && it.detailTiles.size == 1 }
                assertEquals(1, detailCalls.get())
                assertTrue(model.state.value.canExport)
                assertTrue(model.state.value.exact)
                assertFalse(model.state.value.rendering)

                // Small pan inside the same tile hits without re-rendering.
                val insideTileA = regionA.copy(visibleRect = NormalizedRect(0.08f, 0.08f, 0.22f, 0.28f))
                harness.onMain { model.updateDetailRequest(insideTileA) }
                Thread.sleep(50)
                harness.drainMain()
                assertEquals(1, detailCalls.get())

                // Panning to a disjoint tile (col=2, row=1) renders that tile and keeps Region A cached.
                val regionB = regionA.copy(visibleRect = NormalizedRect(0.55f, 0.40f, 0.70f, 0.60f))
                harness.onMain { model.updateDetailRequest(regionB) }
                harness.awaitState(model) { it.detailTiles.size == 2 }
                assertEquals(2, detailCalls.get())

                // Panning back to Region A hits cache immediately with zero re-render.
                harness.onMain { model.updateDetailRequest(regionA) }
                Thread.sleep(50)
                harness.drainMain()
                assertEquals(2, detailCalls.get())

                // Zooming out to Fit clears visible tiles, and zooming back into A restores from cache with zero re-render.
                harness.onMain { model.updateDetailRequest(null) }
                assertNull(model.state.value.detail)
                assertTrue(model.state.value.detailTiles.isEmpty())
                harness.onMain { model.updateDetailRequest(regionA) }
                assertTrue(model.state.value.detailTiles.size == 2)
                Thread.sleep(50)
                harness.drainMain()
                assertEquals(2, detailCalls.get())

                // Editing invalidates cached tiles immediately and automatically re-sharpens after exact preview.
                val firstEditRev = model.state.value.detail!!.editRevision
                harness.onMain {
                    model.edit(model.state.value.edits.copy(exposure = 0.5f))
                    assertNull(model.state.value.detail)
                    assertTrue(model.state.value.detailTiles.isEmpty())
                }
                harness.awaitState(model) { it.canExport && it.detail != null && it.detail!!.editRevision > firstEditRev }
                assertEquals(3, detailCalls.get())

                // ROI failure degrades silently without setting state.error or breaking canExport.
                failDetail.set(true)
                val regionC = regionA.copy(visibleRect = NormalizedRect(0.80f, 0.75f, 0.95f, 0.95f))
                harness.onMain { model.updateDetailRequest(regionC) }
                assertTrue(failedDetailRan.await(5, TimeUnit.SECONDS))
                Thread.sleep(30)
                harness.drainMain()
                assertNull(model.state.value.error)
                assertTrue(model.state.value.canExport)

                // Zooming back out (null request) clears active detail tiles.
                harness.onMain { model.updateDetailRequest(null) }
                assertNull(model.state.value.detail)
                assertTrue(model.state.value.detailTiles.isEmpty())
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun detailWorkerDoesNotCancelInFlightTileOnSubTilePanPrefetchesOverscanAndSupportsLazyNeutral() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("lazy-neutral-tile.raw")
            val firstTileEntered = CountDownLatch(1)
            val releaseFirstTile = CountDownLatch(1)
            val seenIncludesNeutral = CopyOnWriteArrayList<Boolean>()
            val seenKeys = CopyOnWriteArrayList<DetailTileKey?>()
            val model = harness.createViewModel(
                detailDebounceDelayMs = 0L,
                detailOverscanRing = 1,
                renderHandler = { work, cancellation ->
                    when (work) {
                        is Work.Import -> {
                            val imported = harness.defaultRender(work) as WorkResult.Preview
                            WorkResult.Preview(imported.request, TestBitmaps.pair(4000, 3000))
                        }
                        is Work.Preview -> WorkResult.Preview(work, TestBitmaps.pair(4000, 3000))
                        is Work.DetailPreview -> {
                            seenIncludesNeutral.add(work.includeNeutral)
                            seenKeys.add(work.tileKey)
                            if (work.tileKey == DetailTileKey(0, 0, 0) && firstTileEntered.count > 0) {
                                firstTileEntered.countDown()
                                assertTrue(releaseFirstTile.await(5, TimeUnit.SECONDS))
                                assertFalse("sub-tile pan must not cancel in-flight tile", cancellation.isCancelled)
                            }
                            harness.defaultRender(work)
                        }
                        else -> harness.defaultRender(work)
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                val regionA = ViewportRoiRequest(
                    visibleRect = NormalizedRect(0.05f, 0.05f, 0.20f, 0.25f),
                    overscanRect = NormalizedRect(0.03f, 0.03f, 0.22f, 0.27f),
                    zoomScale = 1f,
                    baseScale = 1600f / 4000f,
                    maxOutputLongEdge = 2048,
                )
                harness.onMain { model.updateDetailRequest(regionA) }
                assertTrue(firstTileEntered.await(5, TimeUnit.SECONDS))

                // Sub-tile pan inside (0, 0) while (0, 0) is in flight must not cancel it.
                val shiftedInSameTile = regionA.copy(visibleRect = NormalizedRect(0.07f, 0.07f, 0.22f, 0.27f))
                harness.onMain { model.updateDetailRequest(shiftedInSameTile) }
                releaseFirstTile.countDown()

                // Visible (0, 0) plus overscan ring (1, 0), (0, 1), (1, 1) -> 4 cached tiles with lazy neutral == null.
                harness.awaitState(model) { it.detailTiles.size == 4 }
                assertTrue(seenIncludesNeutral.all { !it })
                assertTrue(model.state.value.detailTiles.all { it.neutral == null })

                // Enabling before comparison triggers re-render with includeNeutral == true.
                seenIncludesNeutral.clear()
                harness.onMain { model.setDetailNeedsBefore(true) }
                harness.awaitState(model) { state -> state.detailTiles.size == 4 && state.detailTiles.all { it.neutral != null } }
                assertTrue(seenIncludesNeutral.isNotEmpty() && seenIncludesNeutral.all { it })
            } finally {
                releaseFirstTile.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun detailTileOverscanRespectsCacheBudgetWithoutEvictingVisibleTilesOrThrashing() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("overscan-budget.raw")
            val detailCalls = AtomicInteger()
            val model = harness.createViewModel(
                detailDebounceDelayMs = 0L,
                detailOverscanRing = 1,
                renderHandler = { work, _ ->
                    when (work) {
                        is Work.Import -> {
                            val imported = harness.defaultRender(work) as WorkResult.Preview
                            WorkResult.Preview(imported.request, TestBitmaps.pair(6000, 4000))
                        }
                        is Work.Preview -> WorkResult.Preview(work, TestBitmaps.pair(6000, 4000))
                        is Work.DetailPreview -> {
                            detailCalls.incrementAndGet()
                            harness.defaultRender(work)
                        }
                        else -> harness.defaultRender(work)
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                val visible = NormalizedRect(0.20f, 0.10f, 0.55f, 0.65f)
                val baseScale = 1600f / 6000f
                val visibleKeys = harness.tilePlanner.pyramidTiles(visible, 6000, 4000, 1.0f, baseScale, overscanRing = 0)
                    .mapTo(HashSet()) { it.key }
                assertTrue("Test scenario must span at least 9 visible tiles", visibleKeys.size >= 9)

                val request = ViewportRoiRequest(
                    visibleRect = visible,
                    overscanRect = NormalizedRect(0.165f, 0.045f, 0.585f, 0.705f),
                    zoomScale = 1.0f,
                    baseScale = baseScale,
                    maxOutputLongEdge = 2048,
                )
                harness.onMain { model.updateDetailRequest(request) }
                harness.awaitState(model) { state ->
                    val cachedKeys = state.detailTiles.mapTo(HashSet()) { it.tileKey }
                    visibleKeys.all { it in cachedKeys }
                }
                Thread.sleep(200)
                harness.drainMain()
                val callsAfterNormal = detailCalls.get()
                assertTrue("Normal mode must stop bounded without thrashing (calls=$callsAfterNormal)", callsAfterNormal in visibleKeys.size..24)
                Thread.sleep(100)
                harness.drainMain()
                assertEquals("Detail calls must remain quiescent after normal mode settles", callsAfterNormal, detailCalls.get())
                val cachedNormalKeys = model.state.value.detailTiles.mapTo(HashSet()) { it.tileKey }
                assertTrue("All visible tiles must remain cached", visibleKeys.all { it in cachedNormalKeys })

                // Compare mode doubles tile byte cost; visible tiles must still never evict one another or thrash.
                harness.onMain { model.setDetailNeedsBefore(true) }
                harness.awaitState(model) { state ->
                    visibleKeys.all { k -> state.detailTiles.any { it.tileKey == k && it.neutral != null } }
                }
                Thread.sleep(200)
                harness.drainMain()
                val compareDelta = detailCalls.get() - callsAfterNormal
                assertTrue("Compare mode must stop bounded without thrashing (delta=$compareDelta)", compareDelta in visibleKeys.size..16)
                val callsAfterCompare = detailCalls.get()
                Thread.sleep(100)
                harness.drainMain()
                assertEquals("Detail calls must remain quiescent after compare mode settles", callsAfterCompare, detailCalls.get())
                assertTrue(
                    "All visible tiles must keep neutral bitmaps without eviction",
                    visibleKeys.all { k -> model.state.value.detailTiles.any { it.tileKey == k && it.neutral != null } },
                )
            } finally {
                harness.onMain { model.clearForTest() }
            }
        }
    }

    @Test fun staleDetailCompletionDoesNotClearNewerInFlightDetailTileKey() {
        EditorViewModelTestHarness().use { harness ->
            val (_, uri) = harness.createTempPhoto("stale-inflight.raw")
            val tileAKey = DetailTileKey(0, 0, 0)
            val tileBKey = DetailTileKey(0, 5, 3)
            val tileAEntered = CountDownLatch(1)
            val releaseTileA = CountDownLatch(1)
            val tileBEntered = CountDownLatch(1)
            val releaseTileB = CountDownLatch(1)
            val tileBCount = AtomicInteger()
            val tileBCancelled = AtomicBoolean(false)
            val model = harness.createViewModel(
                detailDebounceDelayMs = 0L,
                detailOverscanRing = 0,
                renderHandler = { work, cancellation ->
                    when (work) {
                        is Work.Import -> {
                            val imported = harness.defaultRender(work) as WorkResult.Preview
                            WorkResult.Preview(imported.request, TestBitmaps.pair(6000, 4000))
                        }
                        is Work.Preview -> WorkResult.Preview(work, TestBitmaps.pair(6000, 4000))
                        is Work.DetailPreview -> {
                            if (work.tileKey == tileAKey) {
                                tileAEntered.countDown()
                                assertTrue(releaseTileA.await(5, TimeUnit.SECONDS))
                            } else if (work.tileKey == tileBKey) {
                                tileBCount.incrementAndGet()
                                tileBEntered.countDown()
                                assertTrue(releaseTileB.await(5, TimeUnit.SECONDS))
                                if (cancellation.isCancelled) tileBCancelled.set(true)
                            }
                            harness.defaultRender(work)
                        }
                        else -> harness.defaultRender(work)
                    }
                },
            )
            try {
                harness.onMain { model.importPhoto(uri) }
                harness.awaitState(model) { it.canExport }

                val baseScale = 1600f / 6000f
                val regionA = ViewportRoiRequest(
                    visibleRect = NormalizedRect(0.02f, 0.02f, 0.12f, 0.18f),
                    overscanRect = NormalizedRect(0.01f, 0.01f, 0.13f, 0.19f),
                    zoomScale = 1.0f,
                    baseScale = baseScale,
                    maxOutputLongEdge = 2048,
                )
                harness.onMain { model.updateDetailRequest(regionA) }
                assertTrue(tileAEntered.await(5, TimeUnit.SECONDS))

                val regionB = regionA.copy(visibleRect = NormalizedRect(0.90f, 0.85f, 0.98f, 0.98f))
                harness.onMain { model.updateDetailRequest(regionB) }

                releaseTileA.countDown()
                assertTrue(tileBEntered.await(5, TimeUnit.SECONDS))
                // Drain main thread so stale tileA completion runs while tileB is still in flight.
                harness.drainMain()

                val regionBShifted = regionB.copy(visibleRect = NormalizedRect(0.91f, 0.86f, 0.99f, 0.99f))
                harness.onMain { model.updateDetailRequest(regionBShifted) }
                harness.drainMain()

                releaseTileB.countDown()
                harness.awaitState(model) { state -> state.detailTiles.any { it.tileKey == tileBKey } }
                assertFalse("Stale tile A completion must not cause tile B cancellation", tileBCancelled.get())
                assertEquals("Sub-tile pan while tile B is in flight must not re-submit tile B", 1, tileBCount.get())
            } finally {
                releaseTileA.countDown()
                releaseTileB.countDown()
                harness.onMain { model.clearForTest() }
            }
        }
    }
}
