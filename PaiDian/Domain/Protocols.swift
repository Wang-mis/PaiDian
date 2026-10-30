import Foundation

protocol HTTPClient: Sendable { func execute(_ request: HTTPPayload) async throws -> HTTPResult }
protocol ManagedFileStore: Sendable {
    func stage(_ data: Data, namespace: String) async throws -> String
    func read(_ fileKey: String) async throws -> Data
    func remove(_ fileKey: String) async throws
}
protocol ResourceCache: Sendable {
    func epoch() async -> UUID
    func read(key: String, kind: CacheKind) async throws -> Data?
    func write(_ data: Data, key: String, kind: CacheKind) async throws
    func write(_ data: Data, key: String, kind: CacheKind, epoch: UUID) async throws
    func clear() async throws
}
protocol CredentialStore: Sendable { func read(key: String) async throws -> Data?; func write(_ data: Data?, key: String) async throws }
protocol SettingsStore: Sendable { func load() async -> AppSettings; func save(_ settings: AppSettings) async throws }
protocol DiagnosticLogging: Sendable { func record(_ failure: AppFailure) async }
protocol CatalogProvider: Sendable {
    var platform: MusicPlatform { get }
    func search(query: String, page: Int, pageSize: Int) async throws -> SearchPage
    func fetchTrackDetail(_ track: Track) async throws -> Track
    func fetchLyrics(_ track: Track) async throws -> RawLyrics
}
protocol SourceManaging: Sendable {
    func snapshots() async -> AsyncStream<SourceSnapshot>
    func importScript(_ input: SourceImport) async throws -> SourceScript
    func activate(scriptID: UUID) async throws
    func delete(scriptID: UUID) async throws
    func setSourceOrder(scriptIDs:[UUID]) async throws
    func restoreActive() async
}
protocol SourceResolving: Sendable {
    func resolve(_ track: Track, request: SourceResolutionRequest) async throws -> ResolvedStream
}
extension SourceResolving {
    func resolve(_ track:Track,quality:AudioQuality) async throws -> ResolvedStream {
        try await resolve(track,request:SourceResolutionRequest(range:QualityRange(minimum:quality,maximum:quality)))
    }
    func resolve(_ track:Track,quality:AudioQuality,excluding scriptIDs:Set<UUID>) async throws -> ResolvedStream {
        try await resolve(track,request:SourceResolutionRequest(range:QualityRange(minimum:quality,maximum:quality),excluding:Set(scriptIDs.map{SourceQualityKey(scriptID:$0,quality:quality)})))
    }
}
@MainActor protocol SearchServing: AnyObject {
    var snapshot: SearchSnapshot { get }
    func snapshots() -> AsyncStream<SearchSnapshot>
    func submit(query: String, selection: SearchSelection) async
    func loadMore() async
    func retry(platform: MusicPlatform) async
    func updateAvailablePlatforms(_ platforms: Set<MusicPlatform>) async
    func cancel()
}
protocol LibraryServing: Sendable {
    func snapshots() async -> AsyncStream<LibrarySnapshot>
    func items(playlistID: UUID) async throws -> [PlaylistItem]
    func perform(_ command: LibraryCommand) async throws -> LibraryResult
}
protocol SourceRepository: Sendable {
    func scripts() async throws -> [SourceScript]
    func activeScriptID() async throws -> UUID?
    func save(_ script: SourceScript) async throws
    func setActive(_ scriptID: UUID?) async throws
    func delete(_ scriptID: UUID) async throws
    func sourceOrderIDs() async throws -> [UUID]
    func setSourceOrderIDs(_ ids:[UUID]) async throws
}
protocol SearchHistoryRepository: Sendable {
    func recentQueries() async throws -> [String]
    func recordQuery(_ query: String) async throws
    func removeQuery(_ query: String) async throws
    func clearQueries() async throws
}
protocol PlaybackSnapshotRepository: Sendable {
    func loadPlayback() async throws -> PlaybackSnapshot?
    func savePlayback(_ snapshot: PlaybackSnapshot) async throws
}
protocol HistoryRepository: Sendable { func recentTracks(limit: Int) async throws -> [HistoryEntry]; func recordStarted(_ track: Track, at: Date) async throws }
protocol QueueReducing: Sendable { func reduce(_ state: QueueState, command: QueueCommand, random: inout any RandomNumberGenerator) throws -> QueueTransition }
@MainActor protocol PlaybackControlling: AnyObject, Sendable {
    var state: PlaybackViewState { get }
    func states() -> AsyncStream<PlaybackViewState>
    func play(entries: [QueueEntry], startEntryID: UUID) async
    func resume() async
    func pause()
    func seek(toMS: Int64) async
    func seekAndPlay(toMS: Int64) async
    func next() async
    func previous() async
    func editQueue(_ command: QueueCommand) async
    func setQualityRange(_ range: QualityRange)
    func playbackClock() -> PlaybackClockSample?
    func sourceDidChange(generation: UUID) async
    func restore() async
}
protocol LyricsParsing: Sendable { func parse(_ raw: RawLyrics) throws -> LyricDocument; func lineIndex(in document: LyricDocument, positionMS: Int64) -> Int? }
protocol LyricAdjustmentRepository: Sendable {
    func lyricOffset(for key: TrackKey) async throws -> Int64
    func saveLyricOffset(_ milliseconds: Int64, for key: TrackKey) async throws
    func resetLyricOffset(for key: TrackKey) async throws
}
protocol LyricsServing: Sendable { func load(_ track: Track) async throws -> LyricDocument }

// Each subscriber receives the latest complete value; events requiring delivery use explicit calls.
@MainActor final class StateBroadcast<Value: Sendable> {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    func stream(initial: Value) -> AsyncStream<Value> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation; continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.continuations.removeValue(forKey: id) } }
        }
    }
    func send(_ value: Value) { for continuation in continuations.values { continuation.yield(value) } }
}
