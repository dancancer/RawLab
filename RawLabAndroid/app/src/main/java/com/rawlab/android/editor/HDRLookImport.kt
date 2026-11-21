package com.rawlab.android.editor

import com.rawlab.android.settings.AdjustmentOperationExpiredException
import kotlinx.coroutines.CancellationException

// HDR 外观导入：无论成功、修订号过期、读取失败还是取消，settle 都恰好调用一次，由它交还 operation。
internal suspend fun <T> runHDRLookImport(prepare: suspend () -> T, isCurrent: () -> Boolean,
    settle: (Result<T>) -> Unit) {
    var outcome: Result<T> = Result.failure(CancellationException())
    try {
        val value = prepare()
        outcome = if (isCurrent()) Result.success(value) else Result.failure(AdjustmentOperationExpiredException())
    } catch (error: CancellationException) {
        outcome = Result.failure(error)
        throw error
    } catch (error: Exception) {
        outcome = Result.failure(error)
    } finally {
        settle(outcome)
    }
}
