package com.rawlab.android.photo

import java.io.IOException

// ============================================================================
//  导出发布失败：存储层与批量导出共用
//  BatchGlobalFailure 让整批停止；BatchPublicationUncertain 表示无法确认是否已写入
// ============================================================================

class BatchGlobalFailure(message: String, cause: Throwable? = null) : IOException(message, cause)
class BatchPublicationUncertain(message: String, cause: Throwable? = null) : IOException(message, cause)
