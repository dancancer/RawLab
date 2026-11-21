package com.rawlab.android

import com.rawlab.android.adjustments.AdjustmentFailure
import com.rawlab.android.adjustments.AdjustmentOutcome
import com.rawlab.android.adjustments.AdjustmentStatus
import com.rawlab.android.adjustments.AdjustmentTransferException
import com.rawlab.android.editor.ui.AdjustmentSheet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * k161 遗留：undo/redo 遇单槽门控忙（DRAFT 拒收）被当成历史失败，平白弹出历史面板。
 * 判据函数区分失败来源：DRAFT 拒收不切面板；真实失败与用户主动请求仍开 HISTORY。
 */
class AdjustmentHistorySheetDecisionTest {
    private val draftRejection = listOf(
        AdjustmentOutcome("photo-1", AdjustmentStatus.FAILED, error = AdjustmentTransferException(AdjustmentFailure.DRAFT)))

    @Test
    fun `undo rejected by the busy single-slot gate keeps the current sheet`() {
        assertNull(adjustmentHistorySheetFor(userRequested = false, draftRejection))
    }

    @Test
    fun `user requested history still opens it`() {
        assertEquals(AdjustmentSheet.HISTORY, adjustmentHistorySheetFor(userRequested = true, emptyList()))
        assertEquals(AdjustmentSheet.HISTORY, adjustmentHistorySheetFor(userRequested = true, draftRejection))
    }

    @Test
    fun `real undo failures still open history`() {
        listOf(
            listOf(AdjustmentOutcome("photo-1", AdjustmentStatus.BLOCKED)),
            listOf(AdjustmentOutcome("photo-1", AdjustmentStatus.CONFLICT)),
            listOf(AdjustmentOutcome("photo-1", AdjustmentStatus.FAILED, error = IllegalStateException("render failed"))),
            // 混合结果：DRAFT 拒收 alongside 真实失败仍须开面板
            draftRejection + listOf(AdjustmentOutcome("photo-2", AdjustmentStatus.FAILED, error = IllegalStateException())),
        ).forEach { assertEquals(AdjustmentSheet.HISTORY, adjustmentHistorySheetFor(userRequested = false, it)) }
    }

    @Test
    fun `successful undo keeps the sheet closed`() {
        assertNull(adjustmentHistorySheetFor(userRequested = false,
            listOf(AdjustmentOutcome("photo-1", AdjustmentStatus.APPLIED))))
    }
}
