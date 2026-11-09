package com.rawlab.android.photo

import java.io.File
import java.io.InputStream

internal data class MediaPhoto(val uri: String, val displayName: String, val relativePath: String, val pending: Boolean)

/** 相机任务只依赖发布事务；Android adapter 负责系统权限、媒体索引和 URI。 */
internal interface MediaPhotoAccess {
    fun createPending(name: String, relativePath: String, mime: String, token: String): MediaPhoto
    fun write(uri: String, source: File)
    fun publish(uri: String): MediaPhoto
    fun inspect(uri: String): MediaPhoto?
    fun open(uri: String): InputStream
    fun remember(uri: String, size: Long, digest: String)
    fun deletePending(uri: String)
    fun cleanupOrphans(referenced: Set<String>)
}
