import XCTest
@testable import PaiDian

@MainActor final class ModuleTests: XCTestCase {
    func testBundledSourceInstallation() async throws { try await BundledSourceValidation.run() }
    func testSeekActualLanding() async throws { try await PlaybackValidation.seekActualLanding() }
    func testAudioCacheDisk() async throws { try await AudioCacheValidation.disk() }
    func testAudioCacheCapacity() async throws { try await AudioCacheValidation.capacity() }
    func testAudioCacheTransfer() async throws { try await AudioCacheValidation.transfer() }
    func testAudioCacheFailures() async throws { try await AudioCacheValidation.failures() }
    func testAudioCachePlayback() async throws { try await AudioCacheValidation.playback() }
    func testQualityRangeSettings() async throws { try await QualityLyricsValidation.settings() }
    func testQualityRangeOrder() async throws { try await QualityLyricsValidation.order() }
    func testQualityRangeMediaFailure() async throws { try await QualityLyricsValidation.mediaRange() }
    func testPlatformLyricRequests() async throws { try await QualityLyricsValidation.platformFixtures() }
    func testPlatformLyricCodecs() async throws { try await QualityLyricsValidation.codecs() }
    func testLyricSourceFallback() async throws { try await QualityLyricsValidation.fallback() }
    func testLyricClockScheduling() async throws { try await QualityLyricsValidation.timing() }
    func testSeekWithoutReload() async throws { try await PlaybackValidation.seekWithoutReload() }
    func testSeekAcrossFallback() async throws { try await PlaybackValidation.seekAcrossFallback() }
    func testSeekRefreshAndFailure() async throws { try await PlaybackValidation.seekRefreshAndFailure() }
    func testSeekRaces() async throws { try await PlaybackValidation.seekRaces() }
    func testSourceOrderingPersistence() async throws { try await CoreValidation.sourceOrderingPersistence() }
    func testDomain() async throws { try await CoreValidation.domain() }
    func testModes() async throws { try await CoreValidation.modes() }
    func testShuffle() async throws { try await CoreValidation.shuffle() }
    func testPriority() async throws { try await CoreValidation.priorities() }
    func testLyricPresentation() async throws { try await CoreValidation.lyricPresentation() }
    func testLyrics() async throws { try await CoreValidation.lyrics() }
    func testCrypto() async throws { try await CoreValidation.crypto() }
    func testCatalog() async throws { try await CoreValidation.catalog() }
    func testFiles() async throws { try await CoreValidation.files() }
    func testStorage() async throws { try await CoreValidation.storage() }
    func testPersistence() async throws { try await CoreValidation.persistence() }
    func testDiskReopen() async throws { try await CoreValidation.diskReopen() }
    func testRuntime() async throws { try await CoreValidation.runtime() }
    func testCompatibilityIsolation() async throws { try await CoreValidation.compatibility() }
    func testScriptHTTP() async throws { try await CoreValidation.scriptHTTP() }
    func testUpstreamFailure() async throws { try await CoreValidation.upstreamFailure() }
    func testScriptErrors() async throws { try await CoreValidation.scriptErrors() }
    func testSourceLifecycle() async throws { try await CoreValidation.sourceLifecycle() }
    func testSourceFallbacks() async throws { try await CoreValidation.sourceFallbacks() }
    func testRetainedSourceFailure() async throws { try await CoreValidation.retainedSourceFailure() }
    func testMediaFallback() async throws { try await PlaybackValidation.mediaFallback() }
    func testMismatchedAudio() async throws { try await PlaybackValidation.mismatchedAudio() }
    func testSearch() async throws { try await CoreValidation.search() }
    func testPlaybackRaces() async throws { try await PlaybackValidation.staleResponse() }
    func testPauseDuringResolve() async throws { try await PlaybackValidation.pauseDuringResolve() }
    func testExpiredRefresh() async throws { try await PlaybackValidation.expiredOnce() }
    func testAutomaticFailureLimit() async throws { try await PlaybackValidation.failureBound() }
    func testRestoreAndHistory() async throws { try await PlaybackValidation.historyAndRestore() }
}
