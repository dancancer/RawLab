package com.rawlab.android.batch

import com.rawlab.android.adjustments.*
import com.rawlab.android.batch.journal.BatchJournal
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.settings.*
import java.io.File
import java.util.UUID
import java.util.concurrent.CancellationException

/** HDR 统一批量只读目标记录，转换结果归任务所有，不改变来源或目标的编辑模式。 */
internal class BatchHDRPreparation(
    private val source: BatchSourceSnapshot,
    private val readRecord: (PhotoIdentity) -> VersionedPhotoEdit,
    private val resolveLook: (EditSettings) -> File?,
    private val probeSource: (File) -> Boolean,
) {
    private data class Candidate(val record: VersionedPhotoEdit,val frozen: BatchFrozenSettings)

    private fun candidate(target: BatchTarget, ordinal: Int, format: ExportFormat, longEdge: Int?): Candidate {
        val hash=BatchFrozenSettings.checksum(target.sourceFile)
        val isHDR=probeSource(target.sourceFile)
        val record=readRecord(target.identity)
        val previous=record.settings ?: sourceDefaultSettings(isHDR)
        if(previous.isHDREditing && !isHDR) throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.source")
        val payload=AdjustmentTransfer.captureHDRBatch(source.settings,
            AdjustmentTransferContext(source.identity.value,source.inputKind==PhotoInputKind.RAW),previous.isHDREditing)
        val settings=AdjustmentTransfer.prepare(payload,previous,
            AdjustmentTransferContext(target.id,target.inputKind==PhotoInputKind.RAW))
        if(format==ExportFormat.HDR_JPEG && !settings.isHDREditing)
            throw AdjustmentTransferException(AdjustmentFailure.INCOMPATIBLE,"hdr.output")
        val look=if(settings.isHDREditing) null else resolveLook(settings)
        if((settings.film!="neutral" || settings.recipeID!=null) && !settings.isHDREditing && look==null)
            throw AdjustmentTransferException(AdjustmentFailure.MISSING_LOOK)
        val frozen=BatchFrozenSettings(ordinal=ordinal,settings=settings,inputSHA256=hash,lookFile=look,
            lookSHA256=look?.let(BatchFrozenSettings::checksum),outputFormat=format,longEdge=longEdge)
        frozen.validate();frozen.verifyFiles(target.sourceFile)
        return Candidate(record,frozen)
    }

    fun prepare(target: BatchTarget,ordinal: Int,format: ExportFormat,longEdge: Int?) =
        candidate(target,ordinal,format,longEdge).frozen

    fun freeze(job: BatchJob,directory: File,cancelled: () -> Boolean): BatchJob {
        if(job.settingsMode!=BatchSettingsMode.UNIFORM_FROZEN || !job.source.settings.isHDREditing)return job
        val candidates=job.rows.mapIndexed { index,row ->
            if(cancelled())throw CancellationException()
            candidate(row.target,index,job.outputFormat,job.outputLongEdge)
        }
        fun validate() {
            candidates.forEachIndexed { index,value ->
                if(cancelled())throw CancellationException()
                val target=job.rows[index].target
                if(readRecord(target.identity)!=value.record)throw EditPersistenceConflict()
                value.frozen.verifyFiles(target.sourceFile)
            }
        }
        validate()
        val folder=File(directory,job.id);val created=!folder.exists()
        check(folder.isDirectory || folder.mkdirs()) { "Cannot create frozen batch directory" }
        val owned=mutableListOf<File>()
        try {
            val rows=job.rows.mapIndexed { index,row ->
                val value=candidates[index].frozen
                val copy=value.lookFile?.let { original ->
                    File(folder,"hdr-look-${UUID.randomUUID()}.${original.extension}").also { file -> owned+=file;original.copyTo(file) }
                }
                val frozen=value.copy(lookFile=copy)
                frozen.verifyFiles(row.target.sourceFile)
                row.copy(target=row.target.copy(frozen=frozen))
            }
            validate()
            val frozen=job.copy(settingsMode=BatchSettingsMode.PER_TARGET_FROZEN,targets=rows.map { it.target },rows=rows)
            frozen.validate();BatchJournal(directory).save(frozen)
            return frozen
        } catch(error: Throwable) {
            owned.forEach { it.delete() }
            if(created && folder.listFiles()?.isEmpty()==true)folder.delete()
            throw error
        }
    }
}
