import XCTest

final class CameraImportFaultToleranceXCTests: XCTestCase {
    @MainActor
    func testP119_IN4_PersistentSkipSetAcrossRestart() async throws {
        try await CameraSkipAndLimitTests.testIN4SkippedFailedItemsPersistAcrossRestart()
    }

    @MainActor
    func testP119_IN5_TypedTransientAndBusyClassification() async throws {
        try await CameraSkipAndLimitTests.testIN5TransientTransferAndBusyErrorsDoNotMarkItemFailed()
    }

    @MainActor
    func testP119_IN6_TetheringPhotoLimitKeepAliveAndRecovery() async throws {
        try await CameraSkipAndLimitTests.testIN6TetheringPhotoLimitExceededKeepsSessionAliveAndRecovers()
    }

    @MainActor
    func testP222_CoalescedBatchManifestWrites() async throws {
        try await CameraSkipAndLimitTests.testP222ManifestWritesCoalescedToOneBatchWrite()
    }

    @MainActor
    func testExistingCameraSkipLimitAndSamplingSuite() async throws {
        UserDefaults.standard.set("zh-Hans", forKey: L10n.preferenceKey)
        defer { UserDefaults.standard.removeObject(forKey: CameraSkipAndLimitTests.fakeCameraPrefsKey) }
        try await CameraSkipAndLimitTests.testI13BadHeaderContinuesAndSkipsWithoutAdvancingCheckpointPastBadItem()
        try await CameraSkipAndLimitTests.testI13PerObjectPTPErrorContinuesWhileConnectionErrorsAbort()
        try await CameraSkipAndLimitTests.testI15PhotoLimitExceededOnMobileAndLegacyKeepsConnectionUsable()
        try await CameraSkipAndLimitTests.testI14ReconnectDefaultCutoffAndOneTapSamplingSkipsFullDownload()
        try await CameraSkipAndLimitTests.testI14SamplingNegativeSafetyMiddleAndTailSingleByteTamperFallsBack()
        try await CameraSkipAndLimitTests.testI14SamplingFallbackWhenMissingChangedAdjustedJPEGOrLegacy()
        try await CameraSkipAndLimitTests.testI14SameSessionRAWToRAWIncrementalBehaviorUnchanged()
    }
}
