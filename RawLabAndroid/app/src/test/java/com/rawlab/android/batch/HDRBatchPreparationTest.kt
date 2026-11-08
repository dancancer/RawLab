package com.rawlab.android.batch

import com.rawlab.android.adjustments.*
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.settings.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files

class HDRBatchPreparationTest {
    private class Fixture {
        val root=Files.createTempDirectory("hdr-batch-prepare").toFile()
        val directory=File(root,"jobs")
        val store=EditStore(File(root,"edits"))
        val look=File(root,"look.cube").apply { writeText("original look") }
        val sourceSettings=sourceDefaultSettings(true).copy(exposure=.5f,contrast=.25f,
            geometry=GeometrySettings(quarterTurns=1)).synchronizeHDR()
        val source=BatchSourceSnapshot(PhotoIdentity("source"),File(root,"source.jpg").apply { writeText("source") },sourceSettings,inputKind=PhotoInputKind.RASTER)
        val targets=listOf("hdr.jpg","sdr.jpg","raw.dng","hdr-old.jpg").map { name ->
            BatchTarget(PhotoIdentity(name),File(root,name).apply { writeText(name) },name,
                inputKind=if(name.endsWith(".dng"))PhotoInputKind.RAW else PhotoInputKind.RASTER)
        }
        init {store.save(targets.last().identity,EditSettings(exposure=-1f,film="custom"))}
        fun preparation(settings: EditSettings=sourceSettings)=BatchHDRPreparation(source.copy(settings=settings),store::versionedState,
            { if(it.film=="custom")look else null },{ file, _ ->
                if(file == source.sourceFile || file.name.startsWith("hdr")) hdrInfo(1) else null
            })
        fun job(settings: EditSettings=sourceSettings,format: ExportFormat=ExportFormat.JPEG)=BatchJob(source.copy(settings=settings),targets,outputFormat=format,outputLongEdge=128)
    }
    private fun test(action: (Fixture)->Unit) {val fixture=Fixture();try {action(fixture)}finally {fixture.root.deleteRecursively()}}

    @Test fun mixedTargetsKeepTheirModesAndOwnFrozenSettingsWithoutEditingRecords() = test { f ->
        val before=f.targets.associateWith { f.store.versionedState(it.identity) }
        val bytes=f.targets.associateWith { it.sourceFile.readBytes().toList() }
        val draft=f.job();val frozen=f.preparation().freeze(draft,f.directory){false}
        assertEquals(BatchSettingsMode.UNIFORM_FROZEN,draft.settingsMode)
        assertEquals(BatchSettingsMode.PER_TARGET_FROZEN,frozen.settingsMode)
        assertEquals(listOf(true,false,false,false),frozen.rows.map { it.target.frozen!!.settings.isHDREditing })
        frozen.rows.forEachIndexed { index,row ->
            val settings=frozen.settingsFor(row.target)
            assertEquals(.5f,settings.exposure);assertEquals(.25f,settings.contrast)
            assertEquals(1,settings.geometry.quarterTurns);assertEquals(index,row.target.frozen!!.ordinal)
            row.target.frozen!!.verifyFiles(row.target.sourceFile)
        }
        assertEquals(f.sourceSettings,frozen.source.settings)
        f.targets.forEach {assertEquals(before[it],f.store.versionedState(it.identity));assertEquals(bytes[it],it.sourceFile.readBytes().toList())}
        val frozenLook=frozen.rows.last().target.frozen!!.lookFile!!
        assertNotEquals(f.look.canonicalFile,frozenLook.canonicalFile)
        f.look.writeText("new look");f.store.save(f.targets.last().identity,EditSettings(exposure=4f))
        val restored=BatchJournal(f.directory).load(frozen.id)!!
        assertEquals(.5f,restored.settingsFor(restored.rows.last().target).exposure)
        assertEquals("original look",restored.rows.last().target.frozen!!.lookFile!!.readText())
    }

    @Test fun previewPreparationUsesTheSameCandidateWithoutSavingAJournal() = test { f ->
        val before=f.store.versionedState(f.targets.last().identity)
        val value=f.preparation().prepare(f.targets.last(),0,ExportFormat.JPEG,128)
        assertFalse(value.settings.isHDREditing);assertEquals(.5f,value.settings.exposure)
        assertEquals(f.look,value.lookFile);assertFalse(f.directory.exists())
        assertEquals(before,f.store.versionedState(f.targets.last().identity))
    }

    @Test fun capableCameraRawKeepsDefaultSdrAndRestoresItsHdrRecord() = test { f ->
        val target = f.targets[2]
        for (proRAW in listOf(false, true)) {
            val preparation = BatchHDRPreparation(f.source, f.store::versionedState, { null }, { file, raw ->
                when {
                    file == f.source.sourceFile -> hdrInfo(1)
                    file == target.sourceFile && raw -> hdrInfo(if (proRAW) HDRSourceInfo.CONTAINER_PRORAW else HDRSourceInfo.CONTAINER_CAMERA_RAW)
                    else -> null
                }
            })
            f.store.save(target.identity, EditSettings())
            assertFalse(preparation.prepare(target, 0, ExportFormat.JPEG, 128).settings.isHDREditing)
            val edits = EditSettings(exposure = -2f).withHDRMode(true, false, cameraRaw = true, proRAW = proRAW)
            f.store.save(target.identity, edits)
            val result = preparation.prepare(target, 0, ExportFormat.HDR_JPEG, 128).settings
            assertTrue(result.isHDREditing)
            assertEquals(if (proRAW) HDRSourceInfo.PRORAW_DECODE_VERSION else null, result.proRAWDecodeVersion)
            assertEquals(.5f, result.exposure)
            assertEquals(-2f, result.sdrSnapshotSettings()!!.exposure)
            assertEquals(edits, f.store.versionedState(target.identity).settings)
        }
    }

    @Test fun nonneutralRelativeWhiteBalanceRejectsTheWholeMixedBatch() = test { f ->
        val settings=f.sourceSettings.copy(temperature=7300f).synchronizeHDR()
        val error=assertThrows(AdjustmentTransferException::class.java) { f.preparation(settings).freeze(f.job(settings),f.directory){false} }
        assertEquals(AdjustmentFailure.INCOMPATIBLE,error.reason);assertEquals("hdr.relative_white_balance",error.field)
        assertFalse(f.directory.exists())
    }

    @Test fun hdrJpegCannotFreezeASdrTargetAndAGrayStoredHdrRecordCannotBypassProbe() = test { f ->
        val error=assertThrows(AdjustmentTransferException::class.java) {f.preparation().freeze(f.job(format=ExportFormat.HDR_JPEG),f.directory){false}}
        assertEquals("hdr.output",error.field);assertFalse(f.directory.exists())
        f.store.save(f.targets[1].identity,sourceDefaultSettings(true))
        assertEquals("hdr.source",assertThrows(AdjustmentTransferException::class.java) {
            f.preparation().prepare(f.targets[1],0,ExportFormat.JPEG,128)
        }.field)
    }

    @Test fun failedJournalCommitCleansOnlyLookCopiesCreatedByThisAttempt() = test { f ->
        val draft=f.job();BatchJournal(f.directory).save(draft)
        val properties=java.util.Properties();val file=File(f.directory,"${draft.id}.properties")
        file.inputStream().use(properties::load);properties.setProperty("journal.version","999")
        file.outputStream().use {properties.store(it,null)}
        val folder=File(f.directory,draft.id).apply {mkdirs()};val sentinel=File(folder,"input.raw").apply {writeText("keep")}
        assertThrows(java.io.IOException::class.java) {f.preparation().freeze(draft,f.directory){false}}
        assertEquals(listOf(sentinel),folder.listFiles()!!.toList())
        assertEquals("original look",f.look.readText())
    }

    private companion object {
        fun hdrInfo(container: Int) = HDRSourceInfo(128, 96, 1, container, 1, 1, 0f, 0, ByteArray(32))
    }
}
