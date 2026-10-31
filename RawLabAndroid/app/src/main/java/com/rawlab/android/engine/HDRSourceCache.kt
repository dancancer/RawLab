package com.rawlab.android.engine

import com.rawlab.android.photo.HDRSourceInfo
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
    private class Entry(val path: String,val fingerprint: ByteArray,val edge: Int,val image: NativeHDRImage) {
        val bytes=image.width.toLong()*image.height*24
        var users=0
        var retained=false
    }
    private val entries=LinkedList<Entry>()
    private var bytes=0L
    private val cleanup=CoroutineScope(SupervisorJob()+Dispatchers.Default)
    @Synchronized fun acquire(file: File,info: HDRSourceInfo,edge: Int): HDRSourceLease {
        require(edge>0)
        val path=file.canonicalPath
        val iterator=entries.iterator()
        while(iterator.hasNext()) {
            val entry=iterator.next()
            if(entry.path!=path)continue
            if(!entry.fingerprint.contentEquals(info.fingerprint)) {iterator.remove();detach(entry);continue}
            if(entry.edge<edge)continue
            iterator.remove();entries.addFirst(entry);return lease(entry)
        }
        val entry=Entry(path,info.fingerprint.copyOf(),edge,NativeHDRBridge.decode(file,info,edge))
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
