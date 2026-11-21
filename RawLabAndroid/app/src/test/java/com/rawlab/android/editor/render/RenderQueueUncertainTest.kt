package com.rawlab.android.editor.render

import com.rawlab.android.engine.NativeProcessingException
import com.rawlab.android.photo.BatchPublicationUncertain
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class RenderQueueUncertainTest {
    // Q12/D-07 残留（#309 再次复核第 4 条）：单张导出已过提交点、核心返回发布不确定
    // （文件可能已落盘）时，cancelExport() 令代次失效不得把它按取消吞掉——消费方必须收到并上屏，
    // 用户才知道需要去导出目标核对并保留清理入口（不确定 ≠ 取消）。
    @Test fun invalidatedPublicationUncertainFailureIsPublishedNotSwallowed() {
        val started = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val drained = CountDownLatch(1)
        val publishedRevisions = java.util.Collections.synchronizedList(mutableListOf<Long>())
        val publishedResults = java.util.Collections.synchronizedList(mutableListOf<Result<Int>>())
        val queue = RenderQueue<Int, Int>(
            { _, _ ->
                started.countDown()
                resume.await(5, TimeUnit.SECONDS)
                throw BatchPublicationUncertain("publication uncertain")
            },
            { revision, result -> publishedRevisions += revision; publishedResults += result },
            {},
        )
        try {
            queue.submit(1)
            assertTrue(started.await(5, TimeUnit.SECONDS))
            queue.invalidate() // cancelExport() 使代次失效
            resume.countDown()
            queue.performAfterPending { drained.countDown() }
            assertTrue(drained.await(5, TimeUnit.SECONDS))
            val result = publishedResults.single()
            val error = assertThrows(BatchPublicationUncertain::class.java) { result.getOrThrow() }
            assertEquals("publication uncertain", error.message)
            assertEquals(listOf(1L), publishedRevisions.toList()) // 以失效的旧代次上抛，由消费方决定上屏
        } finally { resume.countDown(); queue.close() }
    }

    // 反向保险：代次失效只吞「取消类」结果；取消类不得因上面的修复而开始上抛。
    @Test fun invalidatedCancellationFailuresRemainSwallowed() {
        val startedFirst = CountDownLatch(1); val resumeFirst = CountDownLatch(1)
        val startedSecond = CountDownLatch(1); val resumeSecond = CountDownLatch(1)
        val drainedFirst = CountDownLatch(1); val drainedSecond = CountDownLatch(1)
        val publishedResults = java.util.Collections.synchronizedList(mutableListOf<Result<Int>>())
        val queue = RenderQueue<Int, Int>(
            { value, _ ->
                if (value == 1) {
                    startedFirst.countDown(); resumeFirst.await(5, TimeUnit.SECONDS)
                    throw CancellationException("token cancelled")
                }
                startedSecond.countDown(); resumeSecond.await(5, TimeUnit.SECONDS)
                throw NativeProcessingException(NativeProcessingException.CANCELLED, "native cancelled")
            },
            { _, result -> publishedResults += result },
            {},
        )
        try {
            queue.submit(1)
            assertTrue(startedFirst.await(5, TimeUnit.SECONDS))
            queue.invalidate()
            resumeFirst.countDown()
            queue.performAfterPending { drainedFirst.countDown() }
            assertTrue(drainedFirst.await(5, TimeUnit.SECONDS))
            assertTrue("Stale CancellationException must not publish", publishedResults.isEmpty())

            queue.submit(2)
            assertTrue(startedSecond.await(5, TimeUnit.SECONDS))
            queue.invalidate()
            resumeSecond.countDown()
            queue.performAfterPending { drainedSecond.countDown() }
            assertTrue(drainedSecond.await(5, TimeUnit.SECONDS))
            assertTrue("Stale native CANCELLED must not publish", publishedResults.isEmpty())
        } finally { resumeFirst.countDown(); resumeSecond.countDown(); queue.close() }
    }
}
