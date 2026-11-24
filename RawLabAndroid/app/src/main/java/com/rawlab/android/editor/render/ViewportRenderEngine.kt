package com.rawlab.android.editor.render

import android.content.ComponentCallbacks2
import com.rawlab.android.editor.AdjustmentGroup
import com.rawlab.android.editor.EditorDocumentSession
import com.rawlab.android.editor.EditorSessionEvent
import com.rawlab.android.editor.Operation
import com.rawlab.android.editor.canvas.DetailTileKey
import com.rawlab.android.editor.canvas.DetailTileSpec
import com.rawlab.android.editor.canvas.ViewportRoiRequest
import com.rawlab.android.editor.canvas.ViewportTilePlanner
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal class ViewportRenderEngine(
    private val session: EditorDocumentSession,
    private val tilePlanner: ViewportTilePlanner = session.dependencies.viewportTilePlanner,
    private val detailDebounceDelayMs: Long = session.dependencies.detailDebounceDelayMs,
    private val detailOverscanRing: Int = session.dependencies.detailOverscanRing,
    val tileCache: ViewportTileCache = ViewportTileCache(),
    private val onPreviewAccepted: (Result<WorkResult>) -> Unit = {},
    private val onLateExportCompleted: (WorkResult) -> Unit = {},
    private val onRenderSubmittedHook: (Work) -> Unit = {},
) {
    private data class DetailTilePlan(
        val visible: List<DetailTileSpec>,
        val desired: List<DetailTileSpec>,
    )

    var currentRevision: Long = 0L
        private set(value) {
            field = value
            session.updateCurrentRevision(value)
        }
    var latestRender: Work? = null
        private set
    var progressivePreviewFloor: Long = 0L
        private set
    var detailActive: Boolean = false
        private set
    var lastDetailRequest: ViewportRoiRequest? = null
        private set
    var detailNeedsBefore: Boolean = false
        private set
    var inFlightDetailTileKey: DetailTileKey? = null
        private set
    var scheduledDetailTileKey: DetailTileKey? = null
        private set

    private val detailRevisions = HashSet<Long>()
    private var detailDebounceJob: Job? = null
    private var lastNativeSize: Pair<Int, Int>? = null

    private val queue = RenderQueue<Work, WorkResult>(
        session.dependencies.renderGateway::perform,
        { revision, result ->
            // 结果持有临时输入；即使 ViewModel scope 已取消，也要在主线程完成移交或释放。
            session.dependencies.mainDelivery {
                session.emit(EditorSessionEvent.RenderResultReceived(revision, result))
                val isDetail = detailRevisions.remove(revision)
                if (isDetail) {
                    if (revision == currentRevision) {
                        inFlightDetailTileKey = null
                        if (!session.disposed && result.isSuccess) {
                            onPreviewAccepted(result)
                        }
                    }
                    return@mainDelivery
                }
                val preview = result.getOrNull() as? WorkResult.Preview
                if (!session.disposed && revision == currentRevision) {
                    onPreviewAccepted(result)
                } else if (!session.disposed && revision >= progressivePreviewFloor && preview != null &&
                    latestRender?.let(preview.request::canFinishPreviewBefore) == true
                ) {
                    session.mutable.value = session.mutable.value.copy(preview = preview.pair, exact = false)
                } else {
                    result.fold({ onLateExportCompleted(it) }, { error ->
                        if (!session.disposed && !isExportCancellation(error)) {
                            session.mutable.value = session.mutable.value.copy(error = session.failure(error))
                        }
                    })
                }
            }
        },
        {
            session.dependencies.renderGateway.close()
            session.storageRelease.release("renderQueue")
        },
        { onLateExportCompleted(it) },
        { work -> work.discardPendingWork(session.dependencies.exportCleanup) },
        canFinishInFlight = Work::canFinishPreviewBefore,
    )

    fun submitPreview(work: Work): Long {
        if (work !is Work.DetailPreview && work !is Work.HslProbe && work !is Work.WbProbe) {
            clearDetailState(keepRequest = work is Work.Preview && !work.importing)
        }
        if (work !is Work.DetailPreview) {
            onRenderSubmittedHook(work)
        }
        val continuesInteraction = latestRender?.canFinishPreviewBefore(work) == true
        if (work !is Work.DetailPreview && work !is Work.HslProbe && work !is Work.WbProbe) {
            latestRender = work
        }
        val submitted = queue.submit(work)
        if (work is Work.DetailPreview) {
            inFlightDetailTileKey = work.tileKey
            detailRevisions.add(submitted)
            detailRevisions.removeAll { it < submitted - 32 }
        } else {
            inFlightDetailTileKey = null
        }
        if (!continuesInteraction && work !is Work.DetailPreview) {
            progressivePreviewFloor = submitted
        }
        currentRevision = submitted
        session.emit(EditorSessionEvent.RenderSubmitted(submitted, work))
        return submitted
    }

    fun invalidate(): Long {
        clearDetailState(keepRequest = false)
        latestRender = null
        val invalidated = queue.invalidate()
        progressivePreviewFloor = invalidated
        currentRevision = invalidated
        return invalidated
    }

    fun performAfterPending(work: () -> Unit) = queue.performAfterPending(work)

    fun setCompareBefore(needed: Boolean) {
        if (session.disposed || detailNeedsBefore == needed) return
        detailNeedsBefore = needed
        if (needed && lastDetailRequest != null) {
            updateViewport(lastDetailRequest)
        }
    }

    fun updateViewport(request: ViewportRoiRequest?) {
        if (session.disposed) return
        if (request == null) {
            detailActive = false
            cancelPendingDetailDebounce()
            lastDetailRequest = null
            clearOverlayStateIfPresent()
            return
        }
        val current = session.mutable.value
        val preview = current.preview
        val nativeSize = preview?.let { it.nativeWidth to it.nativeHeight }
        if (nativeSize != null && lastNativeSize != null && nativeSize != lastNativeSize) {
            detailActive = false
        }
        lastNativeSize = nativeSize

        val effectiveZoom = minOf(1f, request.zoomScale)
        val threshold = if (detailActive) request.baseScale * 0.85f else request.baseScale * 1.05f
        if (!request.zoomScale.isFinite() || !request.baseScale.isFinite() ||
            request.baseScale <= 0f || effectiveZoom <= threshold
        ) {
            detailActive = false
            cancelPendingDetailDebounce()
            lastDetailRequest = null
            clearOverlayStateIfPresent()
            return
        }
        detailActive = true
        lastDetailRequest = request

        if (preview != null && preview.hdr == null) {
            tileCache.syncRevision(session.sourceRevision, session.editRevision)
            if (tilePlanner.pyramidLevel(request.zoomScale, request.baseScale) == null) {
                cancelPendingDetailDebounce()
                return
            }
            val plan = planDetailTiles(request, preview)
            if (plan.desired.isNotEmpty()) {
                tileCache.touch(plan.desired)
                val cached = tileCache.sortedCachedTiles()
                if (cached.isNotEmpty() && !detailTilesMatch(current.detailTiles, cached)) {
                    session.mutable.value = current.copy(detailTiles = cached, detail = cached.last())
                }
                val missing = plan.desired.filter { tileNeedsRender(it.key) }
                if (missing.isEmpty()) {
                    cancelPendingDetailDebounce()
                    return
                }
                val missingKeys = missing.mapTo(HashSet()) { it.key }
                if (inFlightDetailTileKey != null && inFlightDetailTileKey in missingKeys) {
                    return
                }
                val nextSpec = missing.first()
                if (detailDebounceJob?.isActive == true && scheduledDetailTileKey == nextSpec.key) {
                    return
                }
                scheduleDetailWork(request, nextSpec, detailDebounceDelayMs)
                return
            }
        }
        tileCache.syncRevision(session.sourceRevision, session.editRevision)
        val edgeLimit = if (preview?.hdr != null) minOf(1280, request.maxOutputLongEdge) else request.maxOutputLongEdge
        val hit = tileCache.findHdrHit(
            session.sourceRevision,
            session.editRevision,
            request.visibleRect,
            request.zoomScale,
            edgeLimit,
            tilePlanner,
        )
        if (hit != null) {
            cancelPendingDetailDebounce()
            if (current.detail !== hit || current.detailTiles.isNotEmpty()) {
                session.mutable.value = current.copy(detail = hit, detailTiles = emptyList())
            }
            return
        }
        scheduleDetailIfNeeded()
    }

    fun scheduleDetailIfNeeded() {
        val request = lastDetailRequest ?: return
        if (session.disposed) return
        val current = session.mutable.value
        val preview = current.preview
        if (preview != null && preview.hdr == null) {
            tileCache.syncRevision(session.sourceRevision, session.editRevision)
            val plan = planDetailTiles(request, preview)
            if (plan.desired.isNotEmpty()) {
                val firstMissing = plan.desired.firstOrNull { tileNeedsRender(it.key) } ?: return
                scheduleDetailWork(request, firstMissing, detailDebounceDelayMs)
                return
            }
        }
        scheduleDetailWork(request, tileSpec = null, delayMs = detailDebounceDelayMs)
    }

    fun handleDetailAccepted(value: WorkResult.DetailPreview) {
        inFlightDetailTileKey = null
        val overlay = value.overlay ?: return
        val req = value.request
        if (req.sourceRevision != session.sourceRevision || req.editRevision != session.editRevision) return
        session.emit(EditorSessionEvent.DetailAccepted(value))
        if (overlay.tileKey != null) {
            val activeRequest = lastDetailRequest
            val preview = session.mutable.value.preview
            val plan = if (activeRequest != null && preview != null) {
                planDetailTiles(activeRequest, preview)
            } else {
                DetailTilePlan(emptyList(), emptyList())
            }
            val visibleKeys = plan.visible.mapTo(HashSet(plan.visible.size)) { it.key }
            val desiredKeys = plan.desired.mapTo(HashSet(plan.desired.size)) { it.key }
            tileCache.store(overlay, visibleKeys, desiredKeys)
            if (activeRequest != null) {
                val active = tileCache.sortedCachedTiles()
                if (!detailTilesMatch(session.mutable.value.detailTiles, active) ||
                    session.mutable.value.detail !== overlay
                ) {
                    session.mutable.value = session.mutable.value.copy(detailTiles = active, detail = overlay)
                }
                val remaining = if (preview != null && preview.hdr == null) {
                    plan.desired.firstOrNull { tileNeedsRender(it.key) }
                } else null
                if (remaining != null) {
                    scheduleDetailWork(activeRequest, remaining, delayMs = 0L)
                }
            }
            return
        }
        if (overlay.hdrResult != null) {
            tileCache.storeHdr(overlay)
        }
        if (lastDetailRequest != null) {
            session.mutable.value = session.mutable.value.copy(detail = overlay, detailTiles = emptyList())
        }
    }

    @Suppress("DEPRECATION")
    fun reclaimMemory(level: Int = ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW, keepLastRequest: Boolean = true) {
        if (level >= ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW) {
            clearDetailState(keepRequest = keepLastRequest)
        }
        if (level >= ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN && !session.disposed) {
            val current = session.mutable.value
            if (!current.rendering && current.operation == Operation.NONE && !current.committingAdjustments) {
                queue.performAfterPending { session.dependencies.renderGateway.releaseDecodedRaster() }
            }
        }
    }

    fun close() {
        cancelPendingDetailDebounce()
        queue.close()
    }

    private fun clearDetailState(keepRequest: Boolean = false) {
        cancelPendingDetailDebounce()
        inFlightDetailTileKey = null
        if (!keepRequest) {
            lastDetailRequest = null
            detailActive = false
            lastNativeSize = null
        }
        tileCache.reclaimMemory()
        clearOverlayStateIfPresent()
    }

    private fun clearOverlayStateIfPresent() {
        val current = session.mutable.value
        if (current.detail != null || current.detailTiles.isNotEmpty()) {
            session.mutable.value = current.copy(detail = null, detailTiles = emptyList())
        }
    }

    private fun cancelPendingDetailDebounce() {
        detailDebounceJob?.cancel()
        detailDebounceJob = null
        scheduledDetailTileKey = null
    }

    private fun planDetailTiles(request: ViewportRoiRequest, preview: PreviewPair): DetailTilePlan {
        val visible = tilePlanner.pyramidTiles(
            request.visibleRect,
            preview.nativeWidth,
            preview.nativeHeight,
            request.zoomScale,
            request.baseScale,
            overscanRing = 0,
        )
        if (visible.isEmpty()) return DetailTilePlan(emptyList(), emptyList())
        if (detailOverscanRing <= 0) return DetailTilePlan(visible, visible)
        val all = tilePlanner.pyramidTiles(
            request.visibleRect,
            preview.nativeWidth,
            preview.nativeHeight,
            request.zoomScale,
            request.baseScale,
            overscanRing = detailOverscanRing,
        )
        val visibleKeys = visible.mapTo(HashSet(visible.size)) { it.key }
        fun plannedTileBytes(spec: DetailTileSpec): Long {
            val estimated = ViewportTileCache.estimatedTileBytes(spec, detailNeedsBefore)
            val cached = tileCache.peek(spec.key)?.let(ViewportTileCache::tileBytes) ?: 0L
            return maxOf(estimated, cached)
        }
        val desired = ArrayList<DetailTileSpec>(all.size)
        var plannedBytes = 0L
        for (spec in visible) {
            desired += spec
            plannedBytes += plannedTileBytes(spec)
        }
        for (spec in all) {
            if (spec.key in visibleKeys) continue
            val tileBytes = plannedTileBytes(spec)
            if (desired.size + 1 > tileCache.maxCount || plannedBytes + tileBytes > tileCache.byteBudget) {
                break
            }
            desired += spec
            plannedBytes += tileBytes
        }
        return DetailTilePlan(visible, desired)
    }

    private fun tileNeedsRender(key: DetailTileKey): Boolean {
        val cached = tileCache.peek(key) ?: return true
        return detailNeedsBefore && cached.neutral == null
    }

    private fun detailTilesMatch(lhs: List<PreviewDetailOverlay>, rhs: List<PreviewDetailOverlay>): Boolean {
        if (lhs.size != rhs.size) return false
        for (i in lhs.indices) {
            if (lhs[i].tileKey != rhs[i].tileKey ||
                lhs[i].sourceRevision != rhs[i].sourceRevision ||
                lhs[i].editRevision != rhs[i].editRevision ||
                lhs[i].result !== rhs[i].result ||
                lhs[i].neutral !== rhs[i].neutral
            ) {
                return false
            }
        }
        return true
    }

    private fun scheduleDetailWork(
        request: ViewportRoiRequest,
        tileSpec: DetailTileSpec?,
        delayMs: Long,
    ) {
        if (session.disposed) return
        detailDebounceJob?.cancel()
        scheduledDetailTileKey = tileSpec?.key
        detailDebounceJob = session.scope.launch {
            if (delayMs > 0L) delay(delayMs)
            detailDebounceJob = null
            scheduledDetailTileKey = null
            if (session.disposed) return@launch
            val current = session.mutable.value
            val photo = current.photo ?: return@launch
            val preview = current.preview ?: return@launch
            if (!current.controlsEnabled || !current.exact || current.rendering ||
                current.previewResizePending || current.operation != Operation.NONE ||
                current.draft?.group == AdjustmentGroup.GEOMETRY ||
                session.actions.isEyedropperWaiting()
            ) {
                return@launch
            }
            val effectiveRoi = if (tileSpec != null) {
                request.copy(
                    visibleRect = tileSpec.rect,
                    overscanRect = tileSpec.rect,
                    maxOutputLongEdge = tileSpec.maxOutputLongEdge,
                )
            } else {
                val edgeLimit = if (preview.hdr != null) minOf(1280, request.maxOutputLongEdge) else request.maxOutputLongEdge
                if (tileCache.hasHdrCoverage(
                        session.sourceRevision,
                        session.editRevision,
                        request.visibleRect,
                        request.zoomScale,
                        edgeLimit,
                        tilePlanner,
                    )
                ) {
                    return@launch
                }
                request
            }
            val baseResultHeadroom = preview.hdr?.result?.statistics?.headroom ?: 0f
            val baseNeutralHeadroom = preview.hdr?.neutral?.statistics?.headroom ?: 0f
            submitPreview(
                Work.DetailPreview(
                    photo = photo,
                    edits = current.visibleEdits,
                    roi = effectiveRoi,
                    gpuMode = session.gpuMode(),
                    sourceRevision = session.sourceRevision,
                    editRevision = session.editRevision,
                    baseResultHeadroom = baseResultHeadroom,
                    baseNeutralHeadroom = baseNeutralHeadroom,
                    includeNeutral = detailNeedsBefore,
                    tileKey = tileSpec?.key,
                ),
            )
        }
    }
}
