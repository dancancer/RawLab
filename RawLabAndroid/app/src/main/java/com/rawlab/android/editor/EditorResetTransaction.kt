package com.rawlab.android.editor

import com.rawlab.android.geometry.GeometryRatio
import com.rawlab.android.settings.EditSettings
import com.rawlab.android.settings.PhotoIdentity

/** 绑定源、请求和快照的收据；调用方区分已落盘提交与纯导航预览。WB 元数据不匹配时仍需保存。 */
internal data class EditorDurablePreview(
    val identity: PhotoIdentity,
    val sourcePath: String,
    val sourceRevision: Long,
    val requestRevision: Long,
    val settings: EditSettings,
) {
    fun matches(identity: PhotoIdentity, sourcePath: String, sourceRevision: Long,
        requestRevision: Long, resolved: EditSettings): Boolean =
        this.identity == identity && this.sourcePath == sourcePath && this.sourceRevision == sourceRevision &&
            this.requestRevision == requestRevision && settings == resolved
}

/** 预备操作绑定编辑事实；这些版本与渲染队列的 request revision 分开。 */
data class EditorResetSession(
    val identity: PhotoIdentity,
    val sourcePath: String,
    val sourceRevision: Long,
    val editRevision: Long,
    val edits: EditSettings,
    val draft: AdjustmentDraft?,
    val draftRevision: Long,
    val context: EditorResetContext,
)

class PreparedEditorReset internal constructor(
    val scope: EditorResetScope,
    val session: EditorResetSession,
    val result: EditorResetResult.Ready,
    val draftCandidate: AdjustmentDraft?,
) {
    fun matches(current: EditorResetSession): Boolean = session == current
}

data class EditorResetPreparation(val result: EditorResetResult, val prepared: PreparedEditorReset? = null)

object EditorResetTransaction {
    fun prepare(scope: EditorResetScope, session: EditorResetSession): EditorResetPreparation {
        val draft = session.draft
        val pair = scope == EditorResetScope.Group(EditorAdjustmentGroup.GEOMETRY)
        val tool = (scope as? EditorResetScope.Tool)?.id
        val geometry = pair || tool == 16 || tool == 17
        val draftTool = when (draft?.group) {
            AdjustmentGroup.GEOMETRY -> 17
            AdjustmentGroup.LENS -> 16
            null -> null
        }
        val allowedDraftScope = pair || tool == draftTool
        if ((draft == null && geometry) || (draft != null && !allowedDraftScope)) {
            return EditorResetPreparation(EditorResetResult.Blocked("Resolve the current adjustment draft first"))
        }
        val snapshot = draft?.project(session.edits) ?: session.edits
        val result = EditorAdjustmentRules.prepareReset(scope, snapshot, session.context)
        val frozen = session.copy(context = session.context.copy(knownRecipeIds = session.context.knownRecipeIds.toSet()))
        return EditorResetPreparation(result, (result as? EditorResetResult.Ready)?.let {
            val next = draft?.let { current ->
                if (pair) current.resetPair(it.candidate)
                else current.update(it.candidate).let { updated ->
                    if (current.group == AdjustmentGroup.GEOMETRY) updated.copy(geometryRatio = GeometryRatio.FREE)
                    else updated
                }
            }
            PreparedEditorReset(scope, frozen, it, next)
        })
    }
}
