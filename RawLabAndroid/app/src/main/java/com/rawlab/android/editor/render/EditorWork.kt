package com.rawlab.android.editor.render

import android.graphics.Bitmap
import android.net.Uri
import com.rawlab.android.engine.LensInfo
import com.rawlab.android.engine.RgbHistogram
import com.rawlab.android.format.ExportFormat
import com.rawlab.android.format.PhotoInputKind
import com.rawlab.android.geometry.GeometrySettings
import com.rawlab.android.looks.ManagedLook
import com.rawlab.android.looks.DcpCompilationException
import com.rawlab.android.looks.DcpFailureReason
import com.rawlab.android.looks.InvalidLookException
import com.rawlab.android.photo.ImportedPhoto
import com.rawlab.android.photo.PhotoStorage
import com.rawlab.android.settings.ProcessingIdentity
import com.rawlab.android.settings.PhotoIdentity
import com.rawlab.android.settings.HslTargetRevision
import com.rawlab.android.settings.HslTargetSample
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.VersionedPhotoEdit
import com.rawlab.android.settings.LensSettings
import com.rawlab.android.settings.LookChoice

// ============================================================================
//  编辑器提交给渲染队列与外观队列的工作，以及它们的结果
// ============================================================================

data class PreviewPair(val neutral: Bitmap, val result: Bitmap, val temperature: Float, val tint: Float,
    val lens: LensInfo? = null, val comparisonWidth: Float = neutral.width.toFloat(),
    val comparisonHeight: Float = neutral.height.toFloat(),
    val originalAspect: Float = neutral.width.toFloat() / neutral.height,
    val neutralHistogram: RgbHistogram? = null, val resultHistogram: RgbHistogram? = null)

/** A transformed comparison must never reuse the uncropped original or another viewport. */
internal data class ComparisonPreviewKey(val inputPath: String, val geometry: GeometrySettings,
    val lens: LensSettings, val edge: Int, val interactive: Boolean,
    val processing: ProcessingIdentity = ProcessingIdentity.CURRENT,
    val sourceIdentity: PhotoIdentity = PhotoIdentity(inputPath), val inputKind: PhotoInputKind = PhotoInputKind.RAW)

internal data class NeutralSourceKey(val sourceIdentity: PhotoIdentity, val inputPath: String,
    val inputKind: PhotoInputKind, val processing: ProcessingIdentity)

/** Mobile 100% remains the fixed comparison-preview pixels, independent of current render demand. */
internal fun comparisonDimensions(width: Int, height: Int): Pair<Float, Float> {
    require(width > 0 && height > 0)
    val scale = minOf(1f, 1600f / maxOf(width, height))
    return width * scale to height * scale
}


internal sealed interface Work {
    data class Import(val uri: Uri, val gpuMode: Int, val retained: ImportedPhoto? = null) : Work
    data class Preview(val photo: ImportedPhoto, val edits: EditSettings, val interactive: Boolean,
        val gpuMode: Int, val importing: Boolean = false, val restored: Boolean = false,
        val edge: Int = 1600, val draft: Boolean = false, val importedRecord: VersionedPhotoEdit? = null) : Work
    data class HslProbe(val preview: Preview, val before: EditSettings, val revision: HslTargetRevision,
        val token: Long, val axis: Int, val x: Float, val y: Float) : Work
    data class Export(val photo: ImportedPhoto, val edits: EditSettings, val destination: Uri?, val format: ExportFormat,
        val longEdge: Int?, val gpuMode: Int) : Work
    data class AutoExposure(val photo: ImportedPhoto, val edits: EditSettings) : Work
}
internal sealed interface WorkResult {
    data class Preview(val request: Work.Preview, val pair: PreviewPair) : WorkResult
    data class MissingLook(val photo: ImportedPhoto, val edits: EditSettings, val importedRecord: VersionedPhotoEdit?) : WorkResult
    data class HslProbe(val request: Work.HslProbe, val sample: HslTargetSample) : WorkResult
    data object Export : WorkResult
    data class AutoExposure(val request: Work.AutoExposure, val exposure: Float) : WorkResult
}
internal sealed interface LookWork {
    data object Load : LookWork
    data class Import(val uris: List<Uri>) : LookWork
    data class Rename(val id: String, val name: String) : LookWork
    data class Delete(val id: String) : LookWork
}
internal data class LookImportFailure(val message: String, val invalid: Boolean,
    val dcpReason: DcpFailureReason? = null)

internal sealed interface LookResult {
    data class Loaded(val looks: List<LookChoice>) : LookResult
    data class Imported(val imported: List<ManagedLook>, val failures: List<LookImportFailure>, val looks: List<LookChoice>) : LookResult
    data class Renamed(val look: ManagedLook, val looks: List<LookChoice>) : LookResult
    data class Deleted(val id: String, val looks: List<LookChoice>) : LookResult
    data class Failed(val error: Throwable, val reload: Boolean) : LookResult
}

/** 外观库操作在外观队列线程上执行；失败时只有用户发起的操作需要重新加载列表 */
internal fun runLookWork(storage: PhotoStorage, work: LookWork): LookResult = synchronized(storage) { try {
    when (work) {
        LookWork.Load -> LookResult.Loaded(storage.looks())
        is LookWork.Import -> {
            val imported = mutableListOf<ManagedLook>()
            val failures = mutableListOf<LookImportFailure>()
            for (uri in work.uris) {
                try { imported += storage.importLook(uri) }
                catch (error: Exception) {
                    val causes = generateSequence<Throwable>(error) { it.cause }.toList()
                    val dcpReason = causes.firstOrNull { it is DcpCompilationException }
                        ?.let { (it as DcpCompilationException).reason }
                    failures += LookImportFailure(
                        error.message?.takeIf(String::isNotBlank) ?: error.javaClass.simpleName,
                        causes.any { it is InvalidLookException }, dcpReason)
                }
            }
            LookResult.Imported(imported, failures, storage.looks())
        }
        is LookWork.Rename -> {
            val look = storage.renameLook(work.id, work.name)
            LookResult.Renamed(look, storage.looks())
        }
        is LookWork.Delete -> {
            storage.deleteLook(work.id)
            LookResult.Deleted(work.id, storage.looks())
        }
    }
} catch (error: Throwable) {
    LookResult.Failed(error, work != LookWork.Load)
} }
