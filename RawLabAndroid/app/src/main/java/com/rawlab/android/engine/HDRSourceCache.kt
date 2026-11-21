package com.rawlab.android.engine

import com.rawlab.android.photo.HDRSourceInfo
import com.rawlab.android.settings.HDRCameraDevelopmentSettings
import java.io.File
import java.util.LinkedList
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

internal class HDRSourceLease(val image: NativeHDRImage, private val release: () -> Unit) : AutoCloseable {
    private val closed=AtomicBoolean()
    override fun close() {if(closed.compareAndSet(false,true))release()}
}

/** 一个进程共享 source-only 预算；lease 保护正在渲染的不可变双图。 */
internal object HDRSourceCache {
    private const val BUDGET=128L*1024*1024
    private class Entry(val path: String, val fingerprint: ByteArray, val cameraStamp: HDRSourceInfo.CameraStamp?,
        val edge: Int, val camera: HDRCameraDevelopmentSettings?, val lensDatabase: File?, val image: NativeHDRImage) {
        val bytes=image.width.toLong()*image.height*24
        var users=0
        var retained=false
    }
    private val entries=LinkedList<Entry>()
    private var bytes=0L
    private val cleanup=CoroutineScope(SupervisorJob()+Dispatchers.Default)
    @Synchronized fun acquire(file: File, info: HDRSourceInfo, edge: Int,
        camera: HDRCameraDevelopmentSettings? = null, lensDatabase: File? = null,
        decoder: (() -> NativeHDRImage)? = null): HDRSourceLease {
        require(edge>0)
        info.cameraStamp?.let { expected ->
            require(expected == HDRSourceInfo.CameraStamp(file.length(), file.lastModified())) { "HDR source changed" }
        }
        val path=file.canonicalPath
        val iterator=entries.iterator()
        while(iterator.hasNext()) {
            val entry=iterator.next()
            if(entry.path!=path)continue
            val sameSource = if (info.isCameraRaw && info.cameraStamp != null)
                entry.cameraStamp == info.cameraStamp else entry.fingerprint.contentEquals(info.fingerprint)
            if(!sameSource) {iterator.remove();detach(entry);continue}
            if(entry.edge<edge || entry.camera!=camera || entry.lensDatabase!=lensDatabase ||
                entry.image.sourceInfo.cameraProcessingVersion!=info.cameraProcessingVersion)continue
            iterator.remove();entries.addFirst(entry);return lease(entry)
        }
        val entry=Entry(path, info.fingerprint.copyOf(), info.cameraStamp, edge, camera, lensDatabase,
            decoder?.invoke() ?: NativeHDRBridge.decode(file,info,edge))
        if(entry.bytes<=BUDGET) {
            while(bytes+entry.bytes>BUDGET && entries.isNotEmpty())detach(entries.removeLast())
            entries.addFirst(entry);entry.retained=true;bytes+=entry.bytes
        }
        return lease(entry)
    }
    private fun lease(entry: Entry): HDRSourceLease {
        entry.users++
        return HDRSourceLease(entry.image) {synchronized(this){
            entry.users--;if(!entry.retained && entry.users==0)entry.image.close()
        }}
    }
    private fun detach(entry: Entry) {
        bytes-=entry.bytes;entry.retained=false
        if(entry.users==0)entry.image.close()
    }
    @Synchronized fun clear() {while(entries.isNotEmpty())detach(entries.removeLast())}
    fun clearAsync() {cleanup.launch {clear()}}
    @Synchronized fun cachedBytes()=bytes
}
