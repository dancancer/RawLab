package com.rawlab.android

import androidx.compose.runtime.saveable.SaverScope
import com.rawlab.android.editor.ui.AdjustmentSheet
import com.rawlab.android.editor.ui.AdjustmentSheetSaver
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Activity 重建时复制与历史面板回到原处；粘贴面板的载荷与预检无法还原，不保存。 */
class AdjustmentSheetSaverTest {
    private val scope = SaverScope { true }

    private fun roundTrip(sheet: AdjustmentSheet?): AdjustmentSheet? =
        with(AdjustmentSheetSaver) { scope.save(sheet) }?.let(AdjustmentSheetSaver::restore)

    @Test fun copyAndHistorySheetsAreRestored() {
        assertEquals(AdjustmentSheet.COPY, roundTrip(AdjustmentSheet.COPY))
        assertEquals(AdjustmentSheet.HISTORY, roundTrip(AdjustmentSheet.HISTORY))
    }

    @Test fun pasteSheetIsNotSaved() {
        assertNull(with(AdjustmentSheetSaver) { scope.save(AdjustmentSheet.PASTE) })
        assertNull(roundTrip(null))
    }
}
