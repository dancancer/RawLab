package com.rawlab.android.engine

import android.net.TestUri
import android.net.Uri
import com.rawlab.android.R
import com.rawlab.android.batch.BatchJob
import com.rawlab.android.batch.BatchRowStatus
import com.rawlab.android.batch.BatchRunner
import com.rawlab.android.batch.BatchSourceSnapshot
import com.rawlab.android.batch.BatchTarget
import com.rawlab.android.batch.asBatchOutputFailure
import com.rawlab.android.editor.EditorState
import com.rawlab.android.editor.EditorStateReducer
import com.rawlab.android.editor.ExportSubmission
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.prepareExportSubmission
import com.rawlab.android.editor.render.ExportDestinationCleanup
import com.rawlab.android.editor.render.ExportDestinationDeleter
import com.rawlab.android.editor.render.RenderQueue
import com.rawlab.android.editor.render.Work
import com.rawlab.android.editor.render.WorkResult
import com.rawlab.android.editor.render.discardPendingWork
import com.rawlab.android.editor.render.isExportCancellation
import com.rawlab.android.editor.render.runGuardedExportWork
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ExportCancellationTest {
    @Test fun cancelledBeforeNativeRenderSkipsWorkAndDeletesEmptyPlaceholder() {
        val root = Files.createTempDirectory("rawlab-export-pre-cancel").toFile()
        try {
            val placeholder = File.createTempFile("export-", ".jpg", root)
            assertTrue(placeholder.exists() && placeholder.length() == 0L)
            var rendered = false
            var metadataPreserved = false
            val error = assertThrows(NativeProcessingException::class.java) {
                executeExport(
                    output = placeholder,
                    suffix = ".jpg",
                    isCancelled = { true },
                    renderToStaging = { rendered = true; 0 },
                    preserveMetadata = { metadataPreserved = true },
                )
            }
            assertEquals(NativeProcessingException.CANCELLED, error.status)
            assertFalse(rendered)
            assertFalse(metadataPreserved)
            assertFalse("Empty temp placeholder must be cleaned up on cancel", placeholder.exists())
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun cancelledMidRenderDeletesHalfWrittenStagingAndAllowsRetry() {
        val root = Files.createTempDirectory("rawlab-export-mid-cancel").toFile()
        try {
            val freshOutput = File(root, "fresh.jpg")
            val cancelled = AtomicBoolean(false)
            var metadataCalls = 0

            val error = assertThrows(NativeProcessingException::class.java) {
                executeExport(
                    output = freshOutput,
                    suffix = ".jpg",
                    isCancelled = cancelled::get,
                    renderToStaging = { staging ->
                        staging.writeBytes(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0x00))
                        cancelled.set(true)
                        throw NativeProcessingException(NativeProcessingException.CANCELLED, "aborted in native")
                    },
                    preserveMetadata = { metadataCalls++ },
                )
            }
            assertEquals(NativeProcessingException.CANCELLED, error.status)
            assertEquals(0, metadataCalls)
            assertFalse("Cancelled export must not create partial output", freshOutput.exists())
            assertTrue("Staging file must be deleted", root.listFiles().orEmpty().isEmpty())

            // Post-native race: native finishes writing bytes right as cancellation flips true.
            cancelled.set(false)
            val existing = File(root, "existing.jpg").apply { writeText("committed-v1") }
            val raced = assertThrows(NativeProcessingException::class.java) {
                executeExport(
                    output = existing,
                    suffix = ".jpg",
                    isCancelled = cancelled::get,
                    renderToStaging = { staging ->
                        staging.writeText("partial-or-unverified-bytes")
                        cancelled.set(true)
                        2
                    },
                    preserveMetadata = { metadataCalls++ },
                )
            }
            assertEquals(NativeProcessingException.CANCELLED, raced.status)
            assertEquals(0, metadataCalls)
            assertEquals("Existing non-empty destination must not be clobbered", "committed-v1", existing.readText())
            assertEquals(listOf(existing), root.listFiles()!!.toList())

            // Subsequent uncancelled retry publishes atomically and preserves metadata.
            cancelled.set(false)
            val backend = executeExport(
                output = freshOutput,
                suffix = ".jpg",
                isCancelled = cancelled::get,
                renderToStaging = { staging ->
                    staging.writeText("rendered-pixels")
                    2
                },
                preserveMetadata = { staging ->
                    metadataCalls++
                    staging.appendText("+exif")
                },
            )
            assertEquals(2, backend)
            assertEquals(1, metadataCalls)
            assertEquals("rendered-pixels+exif", freshOutput.readText())
            assertEquals(setOf(existing, freshOutput), root.listFiles()!!.toSet())
        } finally { root.deleteRecursively() }
    }

    @Test fun cancelledDuringMetadataPreservationDeletesStagingWithoutPublishing() {
        val root = Files.createTempDirectory("rawlab-export-exif-cancel").toFile()
        try {
            val output = File(root, "out.jpg")
            val cancelled = AtomicBoolean(false)
            val error = assertThrows(NativeProcessingException::class.java) {
                executeExport(
                    output = output,
                    suffix = ".jpg",
                    isCancelled = cancelled::get,
                    renderToStaging = { staging ->
                        staging.writeText("encoded-jpeg")
                        0
                    },
                    preserveMetadata = { staging ->
                        staging.appendText("-partial-exif")
                        cancelled.set(true)
                    },
                )
            }
            assertEquals(NativeProcessingException.CANCELLED, error.status)
            assertFalse(output.exists())
            assertTrue(root.listFiles().orEmpty().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun renderQueueInvalidationPropagatesToExportCleansTempAndRestoresEditorState() {
        val root = Files.createTempDirectory("rawlab-editor-export-cancel").toFile()
        val started = CountDownLatch(1)
        val signalReceived = CountDownLatch(1)
        val drained = CountDownLatch(1)
        val nextPublished = CountDownLatch(1)
        val publishedErrors = java.util.Collections.synchronizedList(mutableListOf<Throwable>())
        try {
            val tempOutput = File.createTempFile("export-", ".png", root)
            val queue = RenderQueue<Int, String>({ taskId, cancellation ->
                if (taskId == 1) {
                    val nativeCancelled = AtomicBoolean(false)
                    cancellation.onCancel {
                        nativeCancelled.set(true)
                        signalReceived.countDown()
                    }
                    try {
                        executeExport(
                            output = tempOutput,
                            suffix = ".png",
                            isCancelled = nativeCancelled::get,
                            renderToStaging = { staging ->
                                staging.writeBytes(byteArrayOf(1, 2, 3, 4))
                                started.countDown()
                                assertTrue(signalReceived.await(5, TimeUnit.SECONDS))
                                0
                            },
                        )
                        "exported"
                    } finally {
                        cancellation.onCancel(null)
                        tempOutput.delete()
                    }
                } else {
                    "recovered-$taskId"
                }
            }, { _, result ->
                result.onFailure { publishedErrors += it }
                if (result.getOrNull() == "recovered-2") nextPublished.countDown()
            }, {})
            try {
                var state = EditorState(operation = Operation.EXPORT)
                assertFalse(state.controlsEnabled)

                queue.submit(1)
                assertTrue(started.await(5, TimeUnit.SECONDS))

                // User taps Cancel in UI -> EditorViewModel.cancelExport() invalidates queue & finishes operation.
                queue.invalidate()
                state = EditorStateReducer.renderFinished(state)
                assertEquals(Operation.NONE, state.operation)
                assertNull(state.error)

                assertTrue(signalReceived.await(5, TimeUnit.SECONDS))
                queue.performAfterPending { drained.countDown() }
                assertTrue(drained.await(5, TimeUnit.SECONDS))

                assertFalse("Temporary export file must be deleted", tempOutput.exists())
                assertTrue("No partial files may remain in output directory", root.listFiles().orEmpty().isEmpty())
                assertTrue("Invalidated export must not publish an error", publishedErrors.isEmpty())
                assertTrue(isExportCancellation(NativeProcessingException(NativeProcessingException.CANCELLED, "cancelled")))

                queue.submit(2)
                assertTrue(nextPublished.await(5, TimeUnit.SECONDS))
            } finally { queue.close() }
        } finally { root.deleteRecursively() }
    }

    @Test fun batchRunnerTreatsNativeExportCancellationAsCancelledAndCleansTemporaryOutput() {
        val root = Files.createTempDirectory("rawlab-batch-export-cancel").toFile()
        try {
            val sourceFile = File(root, "source.arw").apply { writeText("raw") }
            val t1 = File(root, "1.arw").apply { writeText("raw1") }
            val t2 = File(root, "2.arw").apply { writeText("raw2") }
            val t3 = File(root, "3.arw").apply { writeText("raw3") }
            val outputDir = File(root, "out").apply { mkdirs() }
            val tempDir = File(root, "tmp").apply { mkdirs() }
            val cancelRequested = AtomicBoolean(false)

            val job = BatchJob(
                source = BatchSourceSnapshot(PhotoIdentity("s"), sourceFile, EditSettings()),
                targets = listOf(
                    BatchTarget(PhotoIdentity("1"), t1, "1.arw"),
                    BatchTarget(PhotoIdentity("2"), t2, "2.arw"),
                    BatchTarget(PhotoIdentity("3"), t3, "3.arw"),
                ),
            )
            val finished = BatchRunner.run(
                job = job,
                render = { target, _ ->
                    val temporary = File.createTempFile("render-", ".jpg", tempDir)
                    try {
                        executeExport(
                            output = temporary,
                            suffix = ".jpg",
                            isCancelled = cancelRequested::get,
                            renderToStaging = { staging ->
                                staging.writeText("pixels-${target.id}")
                                if (target.id == "2") cancelRequested.set(true)
                                0
                            },
                        )
                        temporary
                    } catch (error: Throwable) {
                        temporary.delete()
                        throw asBatchOutputFailure(error)
                    }
                },
                write = { rendered, name, _ ->
                    rendered.copyTo(File(outputDir, name), overwrite = true)
                },
                shouldCancel = cancelRequested::get,
                dispose = File::delete,
            )

            assertEquals(
                listOf(BatchRowStatus.SUCCESS, BatchRowStatus.CANCELLED, BatchRowStatus.CANCELLED),
                finished.rows.map { it.status },
            )
            assertNull(finished.rows[1].error)
            assertNull(finished.rows[2].error)
            assertEquals(listOf("1.jpg"), outputDir.listFiles()!!.map { it.name })
            assertTrue("All temporary and partial batch files must be deleted", tempDir.listFiles().orEmpty().isEmpty())
        } finally { root.deleteRecursively() }
    }

    @Test fun discardPendingDeletesSafDestinationEvenAfterViewModelScopeCancelled() {
        val root = Files.createTempDirectory("rawlab-saf-discard-on-clear").toFile()
        val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val viewModelScope = CoroutineScope(Job())
        val firstRunning = CountDownLatch(1)
        val unblockFirst = CountDownLatch(1)
        val deletedLatch = CountDownLatch(1)
        val deletedPairs = java.util.Collections.synchronizedList(mutableListOf<Pair<Uri, Uri?>>())
        try {
            val sourceUri = TestUri.of("/source-photo.arw")
            val safDestination = TestUri.of("/Downloads/export-empty.jpg")
            val photo = ImportedPhoto(sourceUri, "source-photo.arw", File(root, "source.arw").apply { writeText("raw") })
            val cleanup = ExportDestinationCleanup(appScope) { destination, original ->
                deletedPairs += destination to original
                deletedLatch.countDown()
            }
            val queue = RenderQueue<Work, WorkResult>(
                render = { work, _ ->
                    if (work is Work.AutoExposure) {
                        firstRunning.countDown()
                        unblockFirst.await(5, TimeUnit.SECONDS)
                        WorkResult.AutoExposure(work, 0f)
                    } else {
                        WorkResult.Export
                    }
                },
                publish = { _, _ -> },
                release = {},
                discardPending = { work -> work.discardPendingWork(cleanup) },
            )
            try {
                queue.submit(Work.AutoExposure(photo, EditSettings(), 0))
                assertTrue(firstRunning.await(5, TimeUnit.SECONDS))
                queue.submit(Work.Export(photo, EditSettings(), safDestination, ExportFormat.JPEG, null, 0))

                // AndroidX ViewModel.clear() cancels viewModelScope BEFORE calling onCleared() -> queue.close().
                viewModelScope.cancel()
                queue.close()
                unblockFirst.countDown()

                assertTrue("Pending SAF export destination must still be deleted after viewModelScope cancellation",
                    deletedLatch.await(5, TimeUnit.SECONDS))
                assertEquals(listOf(safDestination to sourceUri), deletedPairs.toList())
            } finally {
                unblockFirst.countDown()
                queue.close()
            }
        } finally {
            appScope.cancel()
            root.deleteRecursively()
        }
    }

    @Test fun earlyValidationFailuresDeleteSafDestinationWithoutTouchingSourcePhoto() {
        val root = Files.createTempDirectory("rawlab-saf-early-return").toFile()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined)
        val deleted = mutableListOf<Pair<Uri, Uri?>>()
        try {
            val sourceUri = TestUri.of("/photos/original.arw")
            val photo = ImportedPhoto(sourceUri, "original.arw", File(root, "original.arw").apply { writeText("raw") })
            val cleanup = ExportDestinationCleanup(scope) { destination, original ->
                deleted += destination to original
            }

            // 1. State left PICK_EXPORT while SAF picker was open.
            val staleDest = TestUri.of("/Downloads/stale.jpg")
            val staleResult = prepareExportSubmission(
                EditorState(photo = photo, operation = Operation.NONE),
                staleDest, ExportFormat.JPEG, null, 0, cleanup,
            )
            assertTrue(staleResult is ExportSubmission.Rejected)
            assertEquals(listOf(staleDest to sourceUri), deleted)
            deleted.clear()

            // 2. Photo became null while SAF picker was open.
            val noPhotoDest = TestUri.of("/Downloads/no-photo.jpg")
            val noPhotoResult = prepareExportSubmission(
                EditorState(photo = null, operation = Operation.PICK_EXPORT),
                noPhotoDest, ExportFormat.JPEG, null, 0, cleanup,
            )
            assertTrue(noPhotoResult is ExportSubmission.Rejected)
            assertEquals(listOf(noPhotoDest to (null as Uri?)), deleted)
            deleted.clear()

            // 3. ViewModel already disposed before CreateDocument callback arrived.
            val disposedDest = TestUri.of("/Downloads/disposed.jpg")
            val disposedResult = prepareExportSubmission(
                EditorState(photo = photo, operation = Operation.PICK_EXPORT),
                disposedDest, ExportFormat.JPEG, null, 0, cleanup, disposed = true,
            )
            assertTrue(disposedResult is ExportSubmission.Rejected)
            assertEquals(listOf(disposedDest to sourceUri), deleted)
            deleted.clear()

            // 4. Invalid output long edge rejects and cleans up SAF destination.
            val invalidSizeDest = TestUri.of("/Downloads/bad-size.png")
            val invalidSizeResult = prepareExportSubmission(
                EditorState(photo = photo, operation = Operation.PICK_EXPORT),
                invalidSizeDest, ExportFormat.PNG, 0, 0, cleanup,
            ) as ExportSubmission.Rejected
            assertEquals(Operation.NONE, invalidSizeResult.state.operation)
            assertEquals(R.string.output_size_error, invalidSizeResult.errorKey)
            assertTrue(invalidSizeResult.refreshPreviewSize)
            assertEquals(listOf(invalidSizeDest to sourceUri), deleted)
            deleted.clear()

            // 5. Source URI passed as destination must never be deleted even on validation failure.
            val rejectedSameSource = prepareExportSubmission(
                EditorState(photo = photo, operation = Operation.PICK_EXPORT),
                sourceUri, ExportFormat.PNG, 70000, 0, cleanup,
            )
            assertTrue(rejectedSameSource is ExportSubmission.Rejected)
            assertTrue("Source URI must never be deleted", deleted.isEmpty())

            // 6. Valid submission transitions to EXPORT without deleting destination.
            val validDest = TestUri.of("/Downloads/valid.dng")
            val ready = prepareExportSubmission(
                EditorState(photo = photo, operation = Operation.PICK_EXPORT),
                validDest, ExportFormat.DNG, 1024, 0, cleanup,
            ) as ExportSubmission.Ready
            assertEquals(Operation.EXPORT, ready.state.operation)
            assertEquals(validDest, ready.work.destination)
            assertTrue(deleted.isEmpty())
        } finally {
            scope.cancel()
            root.deleteRecursively()
        }
    }

    @Test fun rendererGuardDeletesSafDestinationOnBothCancellationAndNonCancellationFailures() {
        val root = Files.createTempDirectory("rawlab-saf-renderer-guard").toFile()
        val deleted = mutableListOf<Pair<Uri, Uri?>>()
        val deleter = ExportDestinationDeleter { destination, original ->
            deleted += destination to original
        }
        try {
            val sourceUri = TestUri.of("/photos/source.arw")
            val destination = TestUri.of("/Downloads/render-target.jpg")
            val photo = ImportedPhoto(sourceUri, "source.arw", File(root, "source.arw").apply { writeText("raw") })
            val exportWork = Work.Export(photo, EditSettings(), destination, ExportFormat.JPEG, null, 0)

            // 1. Cancellation cleans up SAF destination.
            assertThrows(NativeProcessingException::class.java) {
                runGuardedExportWork(exportWork, deleter) {
                    throw NativeProcessingException(NativeProcessingException.CANCELLED, "cancelled")
                }
            }
            assertEquals(listOf(destination to sourceUri), deleted)
            deleted.clear()

            // 2. Non-cancellation IOException / runtime failure BEFORE saveDocument also cleans up 0-byte SAF destination.
            assertThrows(IOException::class.java) {
                runGuardedExportWork(exportWork, deleter) {
                    throw IOException("FORCE GPU rejected perspective")
                }
            }
            assertEquals(listOf(destination to sourceUri), deleted)
            deleted.clear()

            // 3. Source URI is protected even if caller mistakenly passed destination == photo.uri.
            val sameUriWork = exportWork.copy(destination = sourceUri)
            assertThrows(IllegalArgumentException::class.java) {
                runGuardedExportWork(sameUriWork, deleter) {
                    throw IllegalArgumentException("Cannot overwrite source photo")
                }
            }
            assertTrue(deleted.isEmpty())

            // 4. Successful export keeps published SAF destination untouched.
            val ok = runGuardedExportWork(exportWork, deleter) { WorkResult.Export }
            assertSame(WorkResult.Export, ok)
            assertTrue(deleted.isEmpty())
        } finally { root.deleteRecursively() }
    }
}
