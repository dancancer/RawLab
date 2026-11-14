package com.rawlab.android.editor.storage

import com.rawlab.android.editor.EditSaveState
import com.rawlab.android.settings.EditStore
import com.rawlab.android.settings.PhotoIdentity
import java.io.File
import java.lang.reflect.Modifier
import java.nio.file.Files
import java.util.Collections
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.*
import org.junit.Test

/**
 * P1-14（A-N1，复审 finding 2）：`store` 与 `adjustmentSession` 必须装进同一个不可变快照整体原子替换。
 * 可见性合同：唯一的 AtomicReference 携带 (store, adjustmentSession) 配对，由 reopen/save/reset 成对重建；
 * 任何单次观测要么旧配对要么新配对，不允许出现 (新 store, 旧 session) 或 available 而 session 为 null 的撕裂。
 * JMM 可见性无法靠调度确定性复现，故用引用形状反射锁合同，再加跨线程读写序语义与并发配对断言。
 */
class EditorEditStoreVisibilityTest {

    private val handlesField = EditorEditStore::class.java.getDeclaredField("handles").apply { isAccessible = true }

    private fun snapshotMember(snapshot: Any, name: String): Any? =
        snapshot.javaClass.getDeclaredField(name).apply { isAccessible = true }.get(snapshot)

    /** 反射读出 AdjustmentTransferSession 包装的 EditStore，用于校验成对重建。 */
    private fun innerStore(session: Any): EditStore =
        session.javaClass.getDeclaredField("store").apply { isAccessible = true }.get(session) as EditStore

    /** 单次原子读快照；一次读里比对配对，跨两次 getter 的观测本身允许跨越一次重建。 */
    private fun snapshot(store: EditorEditStore): Any {
        val reference = handlesField.get(store)
        assertTrue("handles must be an AtomicReference", reference is AtomicReference<*>)
        return (reference as AtomicReference<*>).get() ?: error("snapshot reference must never be null")
    }

    @Test fun bothReopenedReferencesTravelOnOneAtomicSnapshot() {
        // 合同取证（票面原案：两个引用合并进一个 AtomicReference 快照）：
        val field = EditorEditStore::class.java.getDeclaredField("handles")
        assertEquals(AtomicReference::class.java, field.type)
        assertTrue("the snapshot holder must be final", Modifier.isFinal(field.modifiers))
        // 两引用不得再是各自独立的后备字段，否则跨字段配对撕裂窗口仍在。
        assertThrows(NoSuchFieldException::class.java) { EditorEditStore::class.java.getDeclaredField("store") }
        assertThrows(NoSuchFieldException::class.java) { EditorEditStore::class.java.getDeclaredField("adjustmentSession") }
    }

    @Test fun reopenOnAnotherThreadPublishesTheRebuiltPairAfterJoin() {
        val root = Files.createTempDirectory("rawlab-edit-visibility").toFile()
        try {
            val created = Collections.synchronizedList(mutableListOf<EditStore>())
            val store = EditorEditStore(File(root, "edits")) { EditStore(it).also(created::add) }
            assertEquals(EditSaveState.NONE, store.initialResult.state)
            val sessionBefore = requireNotNull(store.adjustmentSession)
            val storeBefore = snapshotMember(snapshot(store), "store")

            thread { store.reopen() }.join()

            // 线程 start/join 提供 happens-before：reopen 之后其它线程必须看到两个新引用。
            val storeAfter = snapshotMember(snapshot(store), "store")
            assertNotSame(storeBefore, storeAfter)
            assertSame(created[1], storeAfter)
            val sessionAfter = requireNotNull(store.adjustmentSession)
            assertNotSame(sessionBefore, sessionAfter)
            // 成对重建合同：新 session 包装的必须正是已发布的新 store。
            assertSame(storeAfter, innerStore(sessionAfter))
        } finally { root.deleteRecursively() }
    }

    @Test fun repeatedReopenConcurrentWithReadsNeverBreaksThePair() {
        val root = Files.createTempDirectory("rawlab-edit-reopen").toFile()
        try {
            val store = EditorEditStore(File(root, "edits"))
            val identity = PhotoIdentity("visibility-probe")
            val stop = AtomicBoolean(false)
            val failures = CopyOnWriteArrayList<Throwable>()
            val reads = AtomicInteger()
            val reader = thread(isDaemon = true) {
                try {
                    while (!stop.get()) {
                        // 读取路径不得抛出；session 引用一旦发布就不允许退回 null。
                        requireNotNull(store.adjustmentSession) { "adjustmentSession regressed to null" }
                        // 配对断言在单次原子快照读内完成：store 与 session 必须同源。
                        val current = snapshot(store)
                        val pairedStore = snapshotMember(current, "store")
                        val pairedSession = snapshotMember(current, "adjustmentSession")
                        if (pairedStore != null) {
                            requireNotNull(pairedSession) { "store available while session missing: torn pair" }
                            assertSame(innerStore(requireNotNull(pairedSession)), pairedStore)
                        }
                        store.load(identity)
                        reads.incrementAndGet()
                    }
                } catch (error: Throwable) { failures.add(error) }
            }
            repeat(300) { attempt ->
                assertEquals("reopen attempt $attempt failed", EditSaveState.NONE, store.reopen().state)
                assertTrue("store must stay available across reopen", store.available)
            }
            stop.set(true)
            reader.join(30_000)
            assertFalse(reader.isAlive)
            assertEquals("concurrent reads must not observe a torn pair: $failures", emptyList<Throwable>(), failures.toList())
            assertTrue("reader must actually run concurrently", reads.get() > 0)
        } finally { root.deleteRecursively() }
    }
}
