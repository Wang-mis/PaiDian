import SwiftUI
import Observation

@MainActor @Observable final class AppModel {
    var library = LibrarySnapshot()
    var source = SourceSnapshot()
    var search = SearchSnapshot()
    var playback = PlaybackViewState()
    var settings = AppSettings()
    var history: [HistoryEntry] = []
    var queries: [String] = []
    var error: String?
    var startupError: String?
    var isStarting = true
    var busy = false
    var showPlayer = false
    var alternativeSearchQuery: String?
    var alternativeSearchPlatform:MusicPlatform?
    var showQueue = false
    var addTracks: [Track] = []
    private var services: AppServices?
    private let factory: @MainActor () async throws -> AppServices
    private(set) var fileStore: (any ManagedFileStore)?
    private(set) var cache: DiskResourceCache?
    private(set) var audioCache:AudioCacheStore?
    private(set) var artworkLoader: ArtworkLoader?
    private(set) var sourceManager: (any SourceManaging)?
    private(set) var searchService: (any SearchServing)?
    private(set) var player: (any PlaybackControlling)?
    private(set) var lyricAdjustments: (any LyricAdjustmentRepository)?
    private(set) var lyricService: (any LyricsServing)?
    private var subscriptions: [Task<Void, Never>] = []
    private var lyricWrite: Task<Void,Never>?
    private var started = false
    init(factory: @escaping @MainActor () async throws -> AppServices = { try await AppContainer.make(inMemory:ProcessInfo.processInfo.arguments.contains("--ui-testing")) }) { self.factory = factory }
    var colorScheme: ColorScheme? { settings.appearance == .system ? nil : (settings.appearance == .dark ? .dark : .light) }
    func start() async {
        guard !started else { return }; started = true; isStarting = true; startupError = nil
        do {
            let services = try await factory(); self.services = services
            let source = services.sources, player = services.playback, search = services.search, library = services.library
            fileStore = services.files; cache = services.cache;audioCache=services.audioCache; artworkLoader = services.artwork
            sourceManager = source; searchService = search; self.player = player; lyricService = services.lyrics; lyricAdjustments = services.lyricAdjustments
            settings = await services.settings.load()
            try? await audioCache?.setBudget(Int64(settings.audioCacheGB)*1024*1024*1024)
            player.setQualityRange(settings.qualityRange)
            subscriptions.append(Task { [weak self] in for await value in await library.snapshots() { self?.library = value } })
            subscriptions.append(Task { [weak self] in for await value in player.states() { self?.playback = value } })
            subscriptions.append(Task { [weak self] in for await value in search.snapshots() { self?.search = value } })
            subscriptions.append(Task { [weak self] in
                for await value in await source.snapshots() {
                    guard let self else { return }; self.source = value
                }
            })
            await source.restoreActive(); await player.restore(); await reloadHistory()
            isStarting = false
            if let installer = services.bundledSources {
                subscriptions.append(Task { [weak self] in
                    do { try await installer.installIfNeeded() } catch { self?.report(error) }
                })
            }
        } catch { startupError = error.localizedDescription; isStarting = false; started = false }
    }
    func perform(_ command: LibraryCommand) async -> LibraryResult? {
        do { return try await services?.library.perform(command) } catch { report(error); return nil }
    }
    func report(_ failure: Error) { if !(failure is CancellationError) { error = failure.localizedDescription } }
    func toggleFavorite(_ track: Track) async { _ = await perform(.setFavorite(track, !library.favoriteKeys.contains(track.key))) }
    func play(_ tracks: [Track], at key: TrackKey? = nil, shuffle: Bool = false) async {
        let entries = tracks.map { QueueEntry(track: $0) }; guard let entry = entries.first(where: { $0.track.key == key }) ?? entries.first else { return }
        player?.setQualityRange(settings.qualityRange)
        if shuffle { await player?.editQueue(.setMode(.shuffle)) }
        await player?.play(entries: entries, startEntryID: entry.id)
    }
    func togglePlay() async { if playback.desiredPlaying { player?.pause() } else { await player?.resume() } }
    func reloadHistory() async { guard let services else { return }; do { history = try await services.history.recentTracks(limit: 50); queries = try await services.queries.recentQueries() } catch { report(error) } }
    func clearQueries() async { do { try await services?.queries.clearQueries(); await reloadHistory() } catch { report(error) } }
    func saveSettings() async { player?.setQualityRange(settings.qualityRange);do { try await audioCache?.setBudget(Int64(settings.audioCacheGB)*1024*1024*1024);try await services?.settings.save(settings) } catch { report(error) } }
    func loadLyricOffset(for key: TrackKey) async throws -> Int64 {
        await lyricWrite?.value
        return try await lyricAdjustments?.lyricOffset(for:key) ?? 0
    }
    func saveLyricOffset(_ offset: Int64, for key: TrackKey) {
        let previous = lyricWrite, repository = lyricAdjustments
        lyricWrite = Task { [weak self] in
            await previous?.value
            do {
                if offset == 0 { try await repository?.resetLyricOffset(for:key) }
                else { try await repository?.saveLyricOffset(offset,for:key) }
            } catch { self?.report(error) }
        }
    }
    func importSource(_ url: URL, replacing id: UUID? = nil) async {
        busy = true; defer { busy = false }
        do { _ = try await sourceManager?.importScript(SourceImport(url: url, replacementID: id)) } catch { report(error) }
    }
    func activateSource(_ id: UUID) async { busy = true; defer { busy = false }; do { try await sourceManager?.activate(scriptID: id) } catch { report(error) } }
    func deleteSource(_ id: UUID) async { do { try await sourceManager?.delete(scriptID: id) } catch { report(error) } }
    func setSourceOrder(_ ids:[UUID]) async -> Bool {
        guard let sourceManager else { error="音源管理尚未就绪，请稍后重试";return false }
        busy=true;defer { busy=false }
        do { try await sourceManager.setSourceOrder(scriptIDs:ids);return true }
        catch { report(error);return false }
    }
    func playlistItems(_ id: UUID) async -> [PlaylistItem] { do { return try await services?.library.items(playlistID: id) ?? [] } catch { report(error); return [] } }
    func coverData(_ key: String?) async -> Data? { guard let key else { return nil }; return try? await fileStore?.read(key) }
    func pauseAndSave() { (player as? PlaybackCoordinator)?.persist() }
    isolated deinit { subscriptions.forEach { $0.cancel() }; services?.sourceBridge?.cancel() }
}
