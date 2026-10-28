package com.rawlab.android.photo

import android.content.ContentResolver
import android.net.Uri
import android.os.Build
import android.system.Os
import android.system.OsConstants
import com.rawlab.android.settings.EditPersistenceConflict
import java.io.IOException
import java.security.MessageDigest
import java.util.Base64

/** 身份属于原始 URI；私有预览副本不会随原文件替换而变化，不能独自证明目标仍是同一张照片。 */
internal object OriginalPhotoSource {
    private sealed interface Stamp {
        data class File(val device: Long, val inode: Long, val size: Long, val seconds: Long, val nanos: Long) : Stamp
        data class Content(val digest: String) : Stamp
    }
    fun capture(resolver: ContentResolver, uri: Uri): () -> Unit {
        val original = stamp(resolver, uri)
        return { if (stamp(resolver, uri) != original) throw EditPersistenceConflict() }
    }
    private fun stamp(resolver: ContentResolver, uri: Uri): Stamp {
        val descriptor = try { resolver.openAssetFileDescriptor(uri, "r") }
            catch (_: UnsupportedOperationException) { null } catch (_: IOException) { null }
        descriptor?.use {
            val stat = Os.fstat(it.parcelFileDescriptor.fileDescriptor)
            if (OsConstants.S_ISREG(stat.st_mode) && it.startOffset == 0L &&
                (it.declaredLength < 0 || it.declaredLength == stat.st_size)) return Stamp.File(stat.st_dev, stat.st_ino, stat.st_size,
                if (Build.VERSION.SDK_INT >= 27) stat.st_mtim.tv_sec else stat.st_mtime,
                if (Build.VERSION.SDK_INT >= 27) stat.st_mtim.tv_nsec else 0L)
        }
        // 分段文件与流式 provider 没有完整的稳定元数据，退回内容摘要；读取失败阻断保存。
        val digest = MessageDigest.getInstance("SHA-256")
        (resolver.openInputStream(uri) ?: throw IOException("Photo source is unavailable")).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        return Stamp.Content(Base64.getEncoder().encodeToString(digest.digest()))
    }
}
