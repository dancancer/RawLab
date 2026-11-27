#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import RawLabKit

final class AIModelPackageStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawLabAIModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Catalog Tests

    func testShippedCatalogLoadsAndValidatesBothPlatforms() throws {
        let catalogURL = RawLabKitTestSupport.repoRoot.appendingPathComponent("Shared/ai-models/catalog.json")
        let catalog = try AIModelCatalog.load(from: catalogURL)
        XCTAssertEqual(catalog.schemaVersion, 1)

        let mac = try catalog.descriptor(for: AIModelCatalog.macOSArm64Platform)
        XCTAssertEqual(mac.archiveName, "rawlab-ai-macos-arm64-049e6acf5d19.tar.gz")
        XCTAssertEqual(mac.url, "https://github.com/dancancer/RawLab/releases/download/assets-v1/rawlab-ai-macos-arm64-049e6acf5d19.tar.gz")
        XCTAssertEqual(mac.archiveBytes, 588_218_971)
        XCTAssertEqual(mac.unpackedBytes, 652_138_326)
        XCTAssertEqual(mac.archiveSha256, "049e6acf5d19ec6959052fa24870eb7fdc87d8e406298c24555d001933160c56")
        XCTAssertEqual(mac.manifestSha256, "38cbd6884bb181db859ffc668cf754a55331be732592e0d4cdf9a2d41a19486a")
        XCTAssertEqual(mac.entries.count, 28)

        let win = try catalog.descriptor(for: AIModelCatalog.windowsX64Platform)
        XCTAssertEqual(win.archiveName, "rawlab-ai-windows-x64-86fb75845dc5.tar.gz")
        XCTAssertEqual(win.url, "https://github.com/dancancer/RawLab/releases/download/assets-v1/rawlab-ai-windows-x64-86fb75845dc5.tar.gz")
        XCTAssertEqual(win.archiveBytes, 294_125_075)
        XCTAssertEqual(win.unpackedBytes, 333_603_381)
        XCTAssertEqual(win.entries.count, 7)
    }

    func testHTTPSOnlyEnforcement() throws {
        let fixture = try makeSyntheticArchive(label: "https-check")
        let loopbackDesc = fixture.descriptor(url: "http://127.0.0.1:8080/model.tar.gz")
        XCTAssertThrowsError(try loopbackDesc.validatedDownloadURL(allowLoopbackHTTP: false)) { error in
            XCTAssertEqual(error as? AIModelPackageError, .insecureURL)
        }
        XCTAssertNoThrow(try loopbackDesc.validatedDownloadURL(allowLoopbackHTTP: true))

        let remoteHTTP = fixture.descriptor(url: "http://example.com/model.tar.gz")
        XCTAssertThrowsError(try remoteHTTP.validatedDownloadURL(allowLoopbackHTTP: true)) { error in
            XCTAssertEqual(error as? AIModelPackageError, .insecureURL)
        }

        let fileURL = fixture.descriptor(url: "file:///tmp/model.tar.gz")
        XCTAssertThrowsError(try fileURL.validatedDownloadURL(allowLoopbackHTTP: true)) { error in
            XCTAssertEqual(error as? AIModelPackageError, .insecureURL)
        }
    }

    // MARK: - Download, Install, Restart, Replace, Remove

    func testDownloadInstallRestartAndRemove() async throws {
        let fixture = try makeSyntheticArchive(label: "valid-v1")
        let server = try LoopbackHTTPServer(mode: .file(fixture.archiveURL))
        defer { server.stop() }

        let storage = tempRoot.appendingPathComponent("store", isDirectory: true)
        let desc = fixture.descriptor(url: server.url(path: "/\(fixture.archiveName)"))
        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: desc,
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )
        XCTAssertNil(store.installedPackageURL())

        final class PhaseRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []
            func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
            var snapshot: [String] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let phases = PhaseRecorder()
        let installed = try await store.downloadAndInstall { phase in
            switch phase {
            case .downloading: phases.append("downloading")
            case .verifying: phases.append("verifying")
            case .installing: phases.append("installing")
            }
        }

        XCTAssertEqual(installed.standardizedFileURL, storage.appendingPathComponent(desc.manifestSha256, isDirectory: true).standardizedFileURL)
        XCTAssertTrue(phases.snapshot.contains("downloading"))
        XCTAssertTrue(phases.snapshot.contains("verifying"))
        XCTAssertTrue(phases.snapshot.contains("installing"))
        XCTAssertEqual(store.installedPackageURL()?.standardizedFileURL, installed.standardizedFileURL)
        try assertNoStrayTempFiles(in: storage)

        // Permissions normalized to app-owned 0o644 (files) / 0o755 (directories)
        var fileStat = stat()
        XCTAssertEqual(Darwin.lstat(installed.appendingPathComponent("manifest.json").path, &fileStat), 0)
        XCTAssertEqual(fileStat.st_mode & 0o777, 0o644)
        var dirStat = stat()
        XCTAssertEqual(Darwin.lstat(installed.appendingPathComponent("raw.mlmodelc").path, &dirStat), 0)
        XCTAssertEqual(dirStat.st_mode & 0o777, 0o755)

        // App restart: fresh store instance finds existing install without network
        let restartedStore = AIModelPackageStore(
            storageRoot: storage,
            descriptor: desc,
            allowLoopbackHTTP: false
        )
        XCTAssertEqual(restartedStore.installedPackageURL()?.standardizedFileURL, installed.standardizedFileURL)

        // Remove installed package
        try restartedStore.removeInstalledPackages()
        XCTAssertNil(restartedStore.installedPackageURL())
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
    }

    func testSecondDigestCountsAsNotInstalledAndRemovesOlderAfterInstall() async throws {
        let first = try makeSyntheticArchive(label: "v1", manifestExtra: "v1")
        let second = try makeSyntheticArchive(label: "v2", manifestExtra: "v2")
        XCTAssertNotEqual(first.manifestSha256, second.manifestSha256)

        let storage = tempRoot.appendingPathComponent("store-upgrade", isDirectory: true)
        let server1 = try LoopbackHTTPServer(mode: .file(first.archiveURL))
        defer { server1.stop() }
        let store1 = AIModelPackageStore(
            storageRoot: storage,
            descriptor: first.descriptor(url: server1.url(path: "/v1.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )
        let dir1 = try await store1.downloadAndInstall()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir1.path))

        // Different digest in catalog counts as not installed
        let server2 = try LoopbackHTTPServer(mode: .file(second.archiveURL))
        defer { server2.stop() }
        let store2 = AIModelPackageStore(
            storageRoot: storage,
            descriptor: second.descriptor(url: server2.url(path: "/v2.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )
        XCTAssertNil(store2.installedPackageURL())

        // Installing the new digest removes the older digest directory
        let dir2 = try await store2.downloadAndInstall()
        XCTAssertEqual(store2.installedPackageURL()?.standardizedFileURL, dir2.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir2.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir1.path))
        try assertNoStrayTempFiles(in: storage)
    }

    func testResolutionOrderOverrideThenDownloadedThenBundled() async throws {
        let fixture = try makeSyntheticArchive(label: "order")
        let server = try LoopbackHTTPServer(mode: .file(fixture.archiveURL))
        defer { server.stop() }

        let storage = tempRoot.appendingPathComponent("store-order", isDirectory: true)
        let overrideDir = tempRoot.appendingPathComponent("override", isDirectory: true)
        let bundledDir = tempRoot.appendingPathComponent("bundled", isDirectory: true)
        try FileManager.default.createDirectory(at: overrideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundledDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundledDir.appendingPathComponent("manifest.json"))

        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: fixture.descriptor(url: server.url(path: "/m.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )

        // Before download: override > bundled > nil
        XCTAssertEqual(store.resolveModelDirectory(override: overrideDir, bundled: bundledDir), .override(overrideDir))
        XCTAssertEqual(store.resolveModelDirectory(override: nil, bundled: bundledDir), .bundled(bundledDir))
        XCTAssertNil(store.resolveModelDirectory(override: nil, bundled: nil))

        // After download: override > downloaded > bundled
        let downloadedDir = try await store.downloadAndInstall()
        XCTAssertEqual(store.resolveModelDirectory(override: overrideDir, bundled: bundledDir), .override(overrideDir))
        XCTAssertEqual(store.resolveModelDirectory(override: nil, bundled: bundledDir), .downloaded(downloadedDir))

        // After remove: falls back to bundled
        try store.removeInstalledPackages()
        XCTAssertEqual(store.resolveModelDirectory(override: nil, bundled: bundledDir), .bundled(bundledDir))
    }

    // MARK: - Archive Size & Digest Rejection (Before Any Decompression/Parsing)

    func testWrongArchiveSizeRejectedWithoutParsing() async throws {
        let fixture = try makeSyntheticArchive(label: "wrong-size")
        let truncated = tempRoot.appendingPathComponent("truncated.bin")
        let original = try Data(contentsOf: fixture.archiveURL)
        try original.prefix(max(1, original.count - 5)).write(to: truncated)

        let server = try LoopbackHTTPServer(mode: .file(truncated))
        defer { server.stop() }

        let storage = tempRoot.appendingPathComponent("store-size", isDirectory: true)
        var unpackCalled = false
        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: fixture.descriptor(url: server.url(path: "/m.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024,
            onBeforeUnpack: { unpackCalled = true }
        )

        do {
            _ = try await store.downloadAndInstall()
            XCTFail("Expected archiveSizeMismatch")
        } catch let error as AIModelPackageError {
            if case .archiveSizeMismatch = error {
                // expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(unpackCalled, "Must not decompress or parse when archive size is wrong")
        XCTAssertNil(store.installedPackageURL())
        try assertNoStrayTempFiles(in: storage)
    }

    func testWrongArchiveDigestRejectedWithoutParsing() async throws {
        let fixture = try makeSyntheticArchive(label: "wrong-digest")
        // Non-tar random/garbage bytes with the exact same byte length as the archive
        let garbage = tempRoot.appendingPathComponent("garbage.bin")
        try Data(repeating: 0x5A, count: Int(fixture.archiveBytes)).write(to: garbage)

        let server = try LoopbackHTTPServer(mode: .file(garbage))
        defer { server.stop() }

        let storage = tempRoot.appendingPathComponent("store-digest", isDirectory: true)
        var unpackCalled = false
        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: fixture.descriptor(url: server.url(path: "/m.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024,
            onBeforeUnpack: { unpackCalled = true }
        )

        do {
            _ = try await store.downloadAndInstall()
            XCTFail("Expected archiveDigestMismatch")
        } catch let error as AIModelPackageError {
            if case .archiveDigestMismatch = error {
                // expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(unpackCalled, "Must not decompress or parse when archive SHA-256 is wrong")
        XCTAssertNil(store.installedPackageURL())
        try assertNoStrayTempFiles(in: storage)
    }

    // MARK: - Hostile Archives (Catalog Digest Matches the Hostile Archive)

    func testHostileArchivePathTraversalBlocked() async throws {
        let escapeTarget = tempRoot.appendingPathComponent("escaped-traversal.txt")
        let hostile = try makeHostileArchive(kind: .pathTraversal("../escaped-traversal.txt"))
        try await assertHostileArchiveRejected(hostile, expectedKind: .unsafe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget.path))
    }

    func testHostileArchiveAbsolutePathBlocked() async throws {
        let absTarget = tempRoot.appendingPathComponent("escaped-absolute.txt")
        let hostile = try makeHostileArchive(kind: .absolutePath(absTarget.path))
        try await assertHostileArchiveRejected(hostile, expectedKind: .unsafe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absTarget.path))
    }

    func testHostileArchiveSymlinkBlocked() async throws {
        let hostile = try makeHostileArchive(kind: .symlink)
        try await assertHostileArchiveRejected(hostile, expectedKind: .unsafe)
    }

    func testHostileArchiveHardLinkBlocked() async throws {
        let hostile = try makeHostileArchive(kind: .hardLink)
        try await assertHostileArchiveRejected(hostile, expectedKind: .unsafe)
    }

    func testHostileArchiveExtraMemberBlocked() async throws {
        let hostile = try makeHostileArchive(kind: .extraMember)
        try await assertHostileArchiveRejected(hostile, expectedKind: .unsafe)
    }

    func testHostileArchiveWrongMemberSizeBlocked() async throws {
        let hostile = try makeHostileArchive(kind: .wrongMemberSize)
        try await assertHostileArchiveRejected(hostile, expectedKind: .memberVerification)
    }

    func testStagingTreeVerificationDefenseInDepth() throws {
        let fixture = try makeSyntheticArchive(label: "defense")
        let desc = fixture.descriptor(url: "https://example.com/m.tar.gz")
        let store = AIModelPackageStore(storageRoot: tempRoot.appendingPathComponent("s"), descriptor: desc)

        func makeCleanStaging() throws -> URL {
            let dir = tempRoot.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("raw.mlmodelc/weights"), withIntermediateDirectories: true)
            for (rel, content) in fixture.fileContents {
                try content.write(to: dir.appendingPathComponent(rel))
            }
            return dir
        }

        // Clean staging succeeds
        let clean = try makeCleanStaging()
        XCTAssertNoThrow(try store.verifyAndNormalizeStagingTree(at: clean, descriptor: desc, cancellation: AIModelInstallCancellation()))

        // Extra file rejected
        let extra = try makeCleanStaging()
        try Data("surprise".utf8).write(to: extra.appendingPathComponent("extra.txt"))
        XCTAssertThrowsError(try store.verifyAndNormalizeStagingTree(at: extra, descriptor: desc, cancellation: AIModelInstallCancellation()))

        // Symlink rejected
        let symlinked = try makeCleanStaging()
        let lic = symlinked.appendingPathComponent("DualDn-LICENSE.txt")
        try FileManager.default.removeItem(at: lic)
        try FileManager.default.createSymbolicLink(at: lic, withDestinationURL: symlinked.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try store.verifyAndNormalizeStagingTree(at: symlinked, descriptor: desc, cancellation: AIModelInstallCancellation()))

        // Hard link rejected
        let hardlinked = try makeCleanStaging()
        let target = hardlinked.appendingPathComponent("DualDn-LICENSE.txt")
        let externalLink = tempRoot.appendingPathComponent("external-hardlink-\(UUID().uuidString)")
        try FileManager.default.linkItem(at: target, to: externalLink)
        XCTAssertThrowsError(try store.verifyAndNormalizeStagingTree(at: hardlinked, descriptor: desc, cancellation: AIModelInstallCancellation()))

        // Wrong member content (same size, wrong SHA-256) rejected
        let tampered = try makeCleanStaging()
        let manifestURL = tampered.appendingPathComponent("manifest.json")
        var bytes = try Data(contentsOf: manifestURL)
        bytes[0] ^= 0xFF
        try bytes.write(to: manifestURL)
        XCTAssertThrowsError(try store.verifyAndNormalizeStagingTree(at: tampered, descriptor: desc, cancellation: AIModelInstallCancellation()))
    }

    // MARK: - Cancel, Disk Space, HTTP 404, Redirect Downgrade

    func testCancelMidDownloadLeavesNoPartialOrTempFiles() async throws {
        let fixture = try makeSyntheticArchive(label: "cancel")
        let firstChunkSent = DispatchSemaphore(value: 0)
        let server = try LoopbackHTTPServer(mode: .stalledFile(fixture.archiveURL, onFirstChunkSent: {
            firstChunkSent.signal()
        }))
        defer { server.stop() }

        let storage = tempRoot.appendingPathComponent("store-cancel", isDirectory: true)
        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: fixture.descriptor(url: server.url(path: "/m.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )

        let cancellation = AIModelInstallCancellation()
        let task = Task {
            try await store.downloadAndInstall(cancellation: cancellation)
        }

        XCTAssertEqual(firstChunkSent.wait(timeout: .now() + 5), .success, "Server should send first chunk")
        cancellation.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancelled")
        } catch let error as AIModelPackageError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertNil(store.installedPackageURL())
        try assertNoStrayTempFiles(in: storage)
    }

    func testDiskSpaceRefusalStopsBeforeNetworkRequest() async throws {
        let fixture = try makeSyntheticArchive(label: "disk-full")
        let server = try LoopbackHTTPServer(mode: .file(fixture.archiveURL))
        defer { server.stop() }

        let storage = tempRoot.appendingPathComponent("store-disk", isDirectory: true)
        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: fixture.descriptor(url: server.url(path: "/m.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024,
            availableSpaceProvider: { _ in 100 } // Far smaller than required
        )

        do {
            _ = try await store.downloadAndInstall()
            XCTFail("Expected insufficientDiskSpace")
        } catch let error as AIModelPackageError {
            if case .insufficientDiskSpace = error {
                // expected
            } else {
                XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(server.requestCount, 0, "Disk space refusal must occur before any network request")
        XCTAssertNil(store.installedPackageURL())
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
    }

    func testHTTP404AndInsecureRedirectHandledCleanly() async throws {
        let fixture = try makeSyntheticArchive(label: "http-errors")

        // 404
        let server404 = try LoopbackHTTPServer(mode: .status(404))
        defer { server404.stop() }
        let storage = tempRoot.appendingPathComponent("store-404", isDirectory: true)
        let store404 = AIModelPackageStore(
            storageRoot: storage,
            descriptor: fixture.descriptor(url: server404.url(path: "/missing.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )
        do {
            _ = try await store404.downloadAndInstall()
            XCTFail("Expected httpNotFound")
        } catch let error as AIModelPackageError {
            XCTAssertEqual(error, .httpNotFound)
            XCTAssertTrue(error.localizedDescription.contains("404"))
        }
        try assertNoStrayTempFiles(in: storage)

        // Redirect downgrade to non-loopback HTTP
        let serverRedirect = try LoopbackHTTPServer(mode: .redirect("http://example.com/downgrade.tar.gz"))
        defer { serverRedirect.stop() }
        let storeRedirect = AIModelPackageStore(
            storageRoot: storage,
            descriptor: fixture.descriptor(url: serverRedirect.url(path: "/redirect.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )
        do {
            _ = try await storeRedirect.downloadAndInstall()
            XCTFail("Expected insecureURL on non-loopback HTTP redirect")
        } catch let error as AIModelPackageError {
            XCTAssertEqual(error, .insecureURL)
        }
        try assertNoStrayTempFiles(in: storage)
    }

    func testManagerStateMachineDoesNotAutoDownloadAndSupportsRetryAndRemove() throws {
        let fixture = try makeSyntheticArchive(label: "manager")
        let server = try LoopbackHTTPServer(mode: .file(fixture.archiveURL))
        defer { server.stop() }

        let storage = tempRoot.appendingPathComponent("store-manager", isDirectory: true)
        let desc = fixture.descriptor(url: server.url(path: "/m.tar.gz"))
        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: desc,
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )

        let manager = AIModelPackageManager(store: store, isRuntimeSupported: { true })
        XCTAssertEqual(manager.state, .notInstalled(downloadBytes: desc.archiveBytes, unpackedBytes: desc.unpackedBytes))
        XCTAssertEqual(server.requestCount, 0, "Manager init must never start a network request")

        var changeCallbacks = 0
        manager.onInstallStateChanged = { changeCallbacks += 1 }
        manager.startDownload()

        let installedDeadline = Date().addingTimeInterval(10)
        while !manager.state.isInstalled && Date() < installedDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(manager.state.isDownloadedInstalled, "Expected downloaded installed state, got \(manager.state)")
        XCTAssertEqual(changeCallbacks, 1)

        manager.removeDownloadedModel()
        XCTAssertEqual(manager.state, .notInstalled(downloadBytes: desc.archiveBytes, unpackedBytes: desc.unpackedBytes))
        XCTAssertEqual(changeCallbacks, 2)

        // Unsupported runtime (Intel / non-AI build) stays .unavailable
        let unsupported = AIModelPackageManager(store: store, isRuntimeSupported: { false })
        XCTAssertEqual(unsupported.state, .unavailable)
    }

    // MARK: - Helpers

    private enum ExpectedHostileError {
        case unsafe
        case memberVerification
    }

    private func assertHostileArchiveRejected(
        _ hostile: SyntheticArchive,
        expectedKind: ExpectedHostileError
    ) async throws {
        let server = try LoopbackHTTPServer(mode: .file(hostile.archiveURL))
        defer { server.stop() }
        let storage = tempRoot.appendingPathComponent("store-hostile-\(UUID().uuidString)", isDirectory: true)
        let store = AIModelPackageStore(
            storageRoot: storage,
            descriptor: hostile.descriptor(url: server.url(path: "/hostile.tar.gz")),
            allowLoopbackHTTP: true,
            diskSpaceMarginBytes: 1024
        )
        do {
            _ = try await store.downloadAndInstall()
            XCTFail("Hostile archive unexpectedly succeeded")
        } catch let error as AIModelPackageError {
            switch (expectedKind, error) {
            case (.unsafe, .unsafeArchive):
                break
            case (.memberVerification, .memberVerificationFailed):
                break
            default:
                XCTFail("Unexpected error for hostile archive: \(error)")
            }
        }
        XCTAssertNil(store.installedPackageURL())
        try assertNoStrayTempFiles(in: storage)
    }

    private func assertNoStrayTempFiles(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for item in items {
            let name = item.lastPathComponent
            XCTAssertFalse(name.hasPrefix(".download-"), "Stray .part file left behind: \(name)")
            XCTAssertFalse(name.hasPrefix(".staging-"), "Stray staging dir left behind: \(name)")
            XCTAssertFalse(name.hasPrefix(".replacing-"), "Stray backup dir left behind: \(name)")
        }
    }

    private struct SyntheticArchive {
        let archiveURL: URL
        let archiveName: String
        let archiveBytes: UInt64
        let archiveSha256: String
        let manifestSha256: String
        let unpackedBytes: UInt64
        let entries: [AIModelArchiveEntry]
        let fileContents: [String: Data]

        func descriptor(url: String) -> AIModelPackageDescriptor {
            AIModelPackageDescriptor(
                platform: AIModelCatalog.macOSArm64Platform,
                url: url,
                archiveName: archiveName,
                archiveSha256: archiveSha256,
                archiveBytes: archiveBytes,
                manifestSha256: manifestSha256,
                unpackedBytes: unpackedBytes,
                entries: entries
            )
        }
    }

    private enum HostileKind {
        case pathTraversal(String)
        case absolutePath(String)
        case symlink
        case hardLink
        case extraMember
        case wrongMemberSize
    }

    private func makeSyntheticArchive(label: String, manifestExtra: String = "v1") throws -> SyntheticArchive {
        let files: [String: Data] = [
            "DualDn-LICENSE.txt": Data("CC BY-NC 4.0 license text\n".utf8),
            "Restormer-LICENSE.txt": Data("Academic Public License text\n".utf8),
            "manifest.json": Data("{\"version\":1,\"tag\":\"\(manifestExtra)\"}\n".utf8),
            "raw.mlmodelc/weights/weight.bin": Data(repeating: 0x2A, count: 4096),
        ]
        let dirs = ["raw.mlmodelc", "raw.mlmodelc/weights"]
        let archiveName = "synthetic-\(label).tar.gz"
        let archiveURL = tempRoot.appendingPathComponent(archiveName)

        let entries = buildEntries(files: files, dirs: dirs)
        try writeTarGz(to: archiveURL, files: files, dirs: dirs, hostile: nil)
        let archiveData = try Data(contentsOf: archiveURL)
        return SyntheticArchive(
            archiveURL: archiveURL,
            archiveName: archiveName,
            archiveBytes: UInt64(archiveData.count),
            archiveSha256: sha256Hex(archiveData),
            manifestSha256: sha256Hex(files["manifest.json"]!),
            unpackedBytes: entries.reduce(0) { $0 + $1.bytes },
            entries: entries,
            fileContents: files
        )
    }

    private func makeHostileArchive(kind: HostileKind) throws -> SyntheticArchive {
        let files: [String: Data] = [
            "DualDn-LICENSE.txt": Data("CC BY-NC 4.0 license text\n".utf8),
            "Restormer-LICENSE.txt": Data("Academic Public License text\n".utf8),
            "manifest.json": Data("{\"version\":1,\"hostile\":true}\n".utf8),
            "raw.mlmodelc/weights/weight.bin": Data(repeating: 0x3B, count: 512),
        ]
        let dirs = ["raw.mlmodelc", "raw.mlmodelc/weights"]
        let archiveName = "hostile-\(UUID().uuidString).tar.gz"
        let archiveURL = tempRoot.appendingPathComponent(archiveName)

        let entries = buildEntries(files: files, dirs: dirs)
        try writeTarGz(to: archiveURL, files: files, dirs: dirs, hostile: kind)
        let archiveData = try Data(contentsOf: archiveURL)
        // Test catalog intentionally pins the hostile archive's exact size & SHA-256
        return SyntheticArchive(
            archiveURL: archiveURL,
            archiveName: archiveName,
            archiveBytes: UInt64(archiveData.count),
            archiveSha256: sha256Hex(archiveData),
            manifestSha256: sha256Hex(files["manifest.json"]!),
            unpackedBytes: entries.reduce(0) { $0 + $1.bytes },
            entries: entries,
            fileContents: files
        )
    }

    private func buildEntries(files: [String: Data], dirs: [String]) -> [AIModelArchiveEntry] {
        var result: [AIModelArchiveEntry] = []
        for dir in dirs {
            result.append(AIModelArchiveEntry(path: dir, kind: .directory, bytes: 0, sha256: nil))
        }
        for (path, data) in files {
            result.append(AIModelArchiveEntry(path: path, kind: .file, bytes: UInt64(data.count), sha256: sha256Hex(data)))
        }
        return result.sorted { $0.path < $1.path }
    }

    private func writeTarGz(to url: URL, files: [String: Data], dirs: [String], hostile: HostileKind?) throws {
        var spec: [String: Any] = [
            "output": url.path,
            "dirs": dirs.sorted(),
            "files": files.mapValues { $0.base64EncodedString() },
        ]
        if let hostile {
            switch hostile {
            case .pathTraversal(let path):
                spec["hostile"] = ["kind": "extra_path", "path": path]
            case .absolutePath(let path):
                spec["hostile"] = ["kind": "extra_path", "path": path]
            case .symlink:
                spec["hostile"] = ["kind": "symlink", "path": "evil-link", "target": "/etc/hosts"]
            case .hardLink:
                spec["hostile"] = ["kind": "hardlink", "path": "evil-hardlink", "target": "manifest.json"]
            case .extraMember:
                spec["hostile"] = ["kind": "extra_path", "path": "extra.txt"]
            case .wrongMemberSize:
                spec["hostile"] = ["kind": "wrong_size", "path": "raw.mlmodelc/weights/weight.bin"]
            }
        }
        let specData = try JSONSerialization.data(withJSONObject: spec)
        let script = """
        import base64, io, json, sys, tarfile
        spec = json.loads(sys.stdin.read())
        files = {k: base64.b64decode(v) for k, v in spec["files"].items()}
        dirs = list(spec["dirs"])
        hostile = spec.get("hostile")
        if hostile and hostile["kind"] == "wrong_size":
            files[hostile["path"]] = files[hostile["path"]] + b"EXTRA_BYTES"
        with tarfile.open(spec["output"], "w:gz") as tf:
            for d in sorted(dirs):
                ti = tarfile.TarInfo(d)
                ti.type = tarfile.DIRTYPE
                ti.mode = 0o755
                ti.mtime = 0
                tf.addfile(ti)
            for p in sorted(files):
                data = files[p]
                ti = tarfile.TarInfo(p)
                ti.type = tarfile.REGTYPE
                ti.size = len(data)
                ti.mode = 0o644
                ti.mtime = 0
                tf.addfile(ti, io.BytesIO(data))
            if hostile:
                kind = hostile["kind"]
                if kind == "extra_path":
                    payload = b"hostile"
                    ti = tarfile.TarInfo(hostile["path"])
                    ti.type = tarfile.REGTYPE
                    ti.size = len(payload)
                    ti.mode = 0o644
                    ti.mtime = 0
                    tf.addfile(ti, io.BytesIO(payload))
                elif kind == "symlink":
                    ti = tarfile.TarInfo(hostile["path"])
                    ti.type = tarfile.SYMTYPE
                    ti.linkname = hostile["target"]
                    ti.mtime = 0
                    tf.addfile(ti)
                elif kind == "hardlink":
                    ti = tarfile.TarInfo(hostile["path"])
                    ti.type = tarfile.LNKTYPE
                    ti.linkname = hostile["target"]
                    ti.mtime = 0
                    tf.addfile(ti)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        try process.run()
        stdinPipe.fileHandleForWriting.write(specData)
        try stdinPipe.fileHandleForWriting.close()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "AIModelPackageStoreTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Minimal POSIX Loopback HTTP Server for Tests

private final class LoopbackHTTPServer: @unchecked Sendable {
    enum Mode {
        case file(URL)
        case stalledFile(URL, onFirstChunkSent: () -> Void)
        case status(Int)
        case redirect(String)
    }

    private let listenFD: Int32
    let port: UInt16
    private let mode: Mode
    private let lock = NSLock()
    private var stopped = false
    private var _requestCount = 0
    private var thread: Thread?

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    init(mode: Mode) throws {
        self.mode = mode
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 8) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        let serverThread = Thread { [weak self] in
            self?.serveLoop()
        }
        self.thread = serverThread
        serverThread.start()
    }

    func url(path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    private func isStopped() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func serveLoop() {
        while !isStopped() {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &clientLen)
                }
            }
            if clientFD < 0 { break }
            lock.lock()
            _requestCount += 1
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = Darwin.read(fd, &buffer, buffer.count)

        switch mode {
        case .status(let code):
            let response = "HTTP/1.1 \(code) Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendAll(fd, Data(response.utf8))
        case .redirect(let location):
            let response = "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendAll(fd, Data(response.utf8))
        case .file(let url):
            guard let data = try? Data(contentsOf: url) else { return }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/gzip\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            sendAll(fd, Data(header.utf8))
            sendAll(fd, data)
        case .stalledFile(let url, let onFirstChunkSent):
            guard let data = try? Data(contentsOf: url) else { return }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/gzip\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
            sendAll(fd, Data(header.utf8))
            let firstLen = max(1, min(64, data.count / 2))
            sendAll(fd, data.prefix(firstLen))
            onFirstChunkSent()
            let deadline = Date().addingTimeInterval(5)
            while !isStopped() && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written <= 0 { break }
                offset += written
            }
        }
    }
}
#endif
