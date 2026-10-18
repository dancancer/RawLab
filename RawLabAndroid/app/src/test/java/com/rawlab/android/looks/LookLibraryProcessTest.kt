package com.rawlab.android.looks

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import com.rawlab.android.engine.LookFormat
import com.rawlab.android.engine.LookValidation

class LookLibraryProcessTest {
    @Test fun anotherProcessCannotRecoverAnActiveImport() = exerciseOwner(kill = false)

    @Test fun killedImporterReleasesLockAndItsUncommittedFilesAreRecovered() = exerciseOwner(kill = true)

    private fun exerciseOwner(kill: Boolean) {
        val parent = Files.createTempDirectory("rawlab-look-process").toFile()
        val root = File(parent, "looks")
        val entered = File(parent, "entered")
        val release = File(parent, "release")
        val log = File(parent, "child.log")
        val classpath = listOf(LookImportChild::class.java, LookLibrary::class.java, Unit::class.java)
            .map { File(requireNotNull(it.protectionDomain?.codeSource?.location).toURI()).path }.distinct().joinToString(File.pathSeparator)
        val child = ProcessBuilder(File(System.getProperty("java.home"), "bin/java").path,
            "-cp", classpath, LookImportChild::class.java.name, root.path, entered.path, release.path)
            .redirectErrorStream(true).redirectOutput(log).start()
        val executor = Executors.newSingleThreadExecutor()
        try {
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            while (!entered.isFile && child.isAlive && System.nanoTime() < deadline) Thread.sleep(10)
            assertTrue("Child must enter a real import transaction: ${log.readText()}", entered.isFile)
            val stage = File(root, entered.readText())
            assertTrue(stage.isFile)
            if (kill) {
                child.destroyForcibly()
                assertTrue(child.waitFor(5, TimeUnit.SECONDS))
                assertTrue(LookLibrary(root, validator).list().isEmpty())
            } else {
                val waiting = executor.submit<ManagedLook> {
                    LookLibrary(root, validator).importLook("valid".byteInputStream(), "parent.cube")
                }
                assertThrows(TimeoutException::class.java) { waiting.get(200, TimeUnit.MILLISECONDS) }
                assertTrue("A live import's stage must not be deleted", stage.isFile)
                release.writeText("continue")
                assertTrue(child.waitFor(5, TimeUnit.SECONDS))
                assertEquals(log.readText(), 0, child.exitValue())
                val imported = waiting.get(5, TimeUnit.SECONDS)
                val looks = LookLibrary(root, validator).list()
                assertEquals(2, looks.size)
                assertTrue(looks.any { it.id == imported.id })
                assertTrue(looks.all { it.file(root).readText() == "valid" })
            }
            assertFalse(stage.exists())
            assertTrue(root.listFiles().orEmpty().none { it.name.startsWith(".import-") })
        } finally {
            release.writeText("continue")
            child.destroyForcibly()
            assertTrue(child.waitFor(5, TimeUnit.SECONDS))
            executor.shutdownNow()
            assertTrue(executor.awaitTermination(5, TimeUnit.SECONDS))
            parent.deleteRecursively()
        }
    }

    private val validator = LookValidator { file ->
        check(file.readText() == "valid")
        LookValidation(LookFormat.CUBE, 0)
    }
}

object LookImportChild {
    @JvmStatic fun main(args: Array<String>) {
        val root = File(args[0])
        val entered = File(args[1])
        val release = File(args[2])
        LookLibrary(root, LookValidator { staged ->
            val signal = File(entered.path + ".tmp")
            signal.writeText(staged.name)
            check(signal.renameTo(entered))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
            while (!release.isFile && System.nanoTime() < deadline) Thread.sleep(10)
            check(release.isFile && staged.readText() == "valid")
            LookValidation(LookFormat.CUBE, 0)
        }).importLook("valid".byteInputStream(), "child.cube")
    }
}
