package com.rawlab.android.photo

import java.io.File
import java.io.InputStream

internal data class MediaPhoto(val uri: String, val displayName: String, val relativePath: String, val pending: Boolean)

/** 低代价 stat 指纹（大小＋修改时间），来自媒体库元数据列，不读文件内容；读不出时为 null。 */
internal data class MediaPhotoStat(val size: Long, val modifiedAt: Long) {
    /** 与日志中持久化指纹的等值比对串；仅 publish（IS_PENDING=0）后的元数据可定稿采集。 */
    fun fingerprint(): String = "$size:$modifiedAt"
}

/** 相机任务只依赖发布事务；Android adapter 负责系统权限、媒体索引和 URI。 */
internal interface MediaPhotoAccess {
    fun createPending(name: String, relativePath: String, mime: String, token: String): MediaPhoto
    fun write(uri: String, source: File)
    fun publish(uri: String): MediaPhoto
    fun inspect(uri: String): MediaPhoto?
    fun open(uri: String): InputStream
    /** 内容校验的快捷路径：指纹（size＋mtime）未变可跳过整文件摘要；拿不到元数据时返回 null 回落内容哈希。 */
    fun stat(uri: String): MediaPhotoStat?
    fun remember(uri: String, size: Long, digest: String)
    fun deletePending(uri: String)
    fun cleanupOrphans(referenced: Set<String>)
}
