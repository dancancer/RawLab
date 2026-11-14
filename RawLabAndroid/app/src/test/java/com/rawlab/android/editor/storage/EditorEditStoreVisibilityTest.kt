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
import kotlin.concurrent.thread
import org.junit.Assert.*
import org.junit.Test

/**
 * P1-14（A-N1）：`store` 与 `adjustmentSession` 由 reopen/save/reset 成对重建，并被其它线程读取。
 * 可见性合同：两个字段都是 @Volatile；reopen 内先写 `store` 再写 `adjustmentSession`，
 * 因此 reopen 返回后，任何经 start/join 交接到其它线程的读取必须看到重建后的这一对引用，
 * 不会永久停留旧引用，也不会看到「store 已换新而 session 缺失」。
 * JMM 可见性无法靠调度确定性地复现，故用字段修饰符反射锁合同，再加跨线程读写序语义测试。
 */
class EditorEditStoreVisibilityTest {

    private fun field(name: String) =
        EditorEditStore::class.java.getDeclaredField(name).apply { isAccessible = true }

    /** 反射读出 AdjustmentTransferSession 包装的 EditStore，用于校验成对重建。 */
    private fun adjustmentTransferSessionInnerStore(session: Any): EditStore =
        session.javaClass.getDeclaredField("store").apply { isAccessible = true }.get(session) as EditStore

    @Test fun bothReopenedReferencesAreDeclaredVolatile() {
        // 合同取证：字段跨线程读写（票面 A-N1），@Volatile 是发布合同本身。
        assertTrue("store must be @Volatile for cross-thread publication",
            Modifier.isVolatile(field("store").modifiers))
        assertTrue("adjustmentSession must be @Volatile for cross-thread publication",
            Modifier.isVolatile(field("adjustmentSession").modifiers))
    }

    @Test fun reopenOnAnotherThreadPublishesTheRebuiltPairAfterJoin() {
        val root = Files.createTempDirectory("rawlab-edit-visibility").toFile()
        try {
            val created = Collections.synchronizedList(mutableListOf<EditStore>())
            val directory = File(root, "edits")
            val store = EditorEditStore(directory) { EditStore(it).also(created::add) }
            assertEquals(EditSaveState.NONE, store.initialResult.state)
            val sessionBefore = requireNotNull(store.adjustmentSession)
            val storeField = field("store")
            val storeBefore = storeField.get(store)

            thread { store.reopen() }.join()

            // 线程 start/join 提供 happens-before：reopen 之后其它线程必须看到两个新引用。
            val storeAfter = storeField.get(store)
            assertNotSame(storeBefore, storeAfter)
            assertSame(created[1], storeAfter)
            val sessionAfter = requireNotNull(store.adjustmentSession)
            assertNotSame(sessionBefore, sessionAfter)
            // 成对重建合同：新 session 包装的必须正是当前已发布的 store。
            assertSame(storeAfter, adjustmentTransferSessionInnerStore(sessionAfter))
        } finally { root.deleteRecursively() }
    }

    @Test fun repeatedReopenConcurrentWithReadsNeverBreaksThePair() {
        val root = Files.createTempDirectory("rawlab-edit-reopen").toFile()
        try {
            val directory = File(root, "edits")
            val store = EditorEditStore(directory)
            val identity = PhotoIdentity("visibility-probe")
            val stop = AtomicBoolean(false)
            val failures = CopyOnWriteArrayList<Throwable>()
            val reads = AtomicInteger()
            val reader = thread(isDaemon = true) {
                try {
                    while (!stop.get()) {
                        // 读取路径不得抛出；session 引用一旦发布就不允许退回 null。
                        requireNotNull(store.adjustmentSession) { "adjustmentSession regressed to null" }
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
            assertEquals("concurrent reads must not observe a broken pair: $failures", emptyList<Throwable>(), failures.toList())
            assertTrue("reader must actually run concurrently", reads.get() > 0)
        } finally { root.deleteRecursively() }
    }
}
