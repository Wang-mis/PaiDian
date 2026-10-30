import Foundation

// Compile this harness with the old and new module names in separate processes.
// All samples use an isolated directory and preferences suite, never the user's library.
@main enum BrandUpgradeValidation {
    struct Manifest: Codable { var playlistID: UUID; var sourceID: UUID }
    struct Failure: Error { var message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw Failure(message: "Usage: seed|verify fixture-directory") }
        let mode = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MusicStore(modelContainer: try MusicStore.container(url: root.appendingPathComponent("library.store")))
        let manifestURL = root.appendingPathComponent("manifest.json")
        // Legacy directory names are part of the upgrade compatibility contract.
        let files = try DiskFileStore(root: root.appendingPathComponent("AnyListen"))
        let suite = "org.anylisten.rebrand-validation." + root.lastPathComponent
        let defaults = UserDefaults(suiteName: suite)!
        let settingsStore = DefaultsSettingsStore(defaults: defaults)
        let track = Track(key: TrackKey(platform: .kw, providerID: "brand-upgrade"), title: "改名前的歌曲", artists: ["本地样本"], durationMS: 120_000)
        var settings = AppSettings()
        settings.appearance = .dark; settings.audioCacheGB = 5; settings.lyricFontSize = 21
        settings.preferredSearchPlatform = .wy
        switch mode {
        case "seed":
            try require(!FileManager.default.fileExists(atPath: manifestURL.path), "Refusing to overwrite an existing fixture")
            try await store.prepare()
            let cover = try await files.stage(Data("cover-before-rename".utf8), namespace: "covers")
            let created = try await store.perform(.create(PlaylistDraft(name: "改名前的歌单", coverFileKey: cover)))
            let playlistID = created.playlistID!
            _ = try await store.perform(.addTracks(playlistID, [track]))
            _ = try await store.perform(.setFavorite(track, true))
            let fileKey = try await files.stage(Data("// source-before-rename".utf8), namespace: "scripts")
            let source = SourceScript(name: "改名前的音源", fileKey: fileKey, digest: "upgrade-fixture")
            try await store.save(source); try await store.setActive(source.id)
            try await store.recordQuery("改名前的搜索")
            try await store.recordStarted(track, at: Date(timeIntervalSince1970: 1_700_000_000))
            try await store.saveLyricOffset(1500, for: track.key)
            let entry = QueueEntry(track: track)
            let queue = QueueState(entries: [entry], currentEntryID: entry.id, mode: .singleRepeat)
            try await store.savePlayback(PlaybackSnapshot(queue: queue, positionMS: 42_000, requestedQuality: .flac))
            try await settingsStore.save(settings); defaults.synchronize()
            try JSONEncoder().encode(Manifest(playlistID: playlistID, sourceID: source.id)).write(to: manifestURL)
            print("PASS old module seeded playlists, favorites, sources, files, history, settings and playback")
        case "verify":
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            try await store.prepare()
            let items = try await store.items(playlistID: manifest.playlistID)
            try require(items.map(\.track.key) == [track.key], "Playlist lost after module rename")
            let favorites = try await store.items(playlistID: Playlist.favoritesID)
            try require(favorites.map(\.track.key) == [track.key], "Favorites lost")
            let sources = try await store.scripts()
            try require(sources.map(\.id) == [manifest.sourceID], "Source identity lost")
            let active = try await store.activeScriptID()
            let order = try await store.sourceOrderIDs()
            try require(active == manifest.sourceID && order == [manifest.sourceID], "Source selection/order lost")
            let scriptData = try await files.read(sources[0].fileKey)
            try require(scriptData == Data("// source-before-rename".utf8), "Source file lost")
            var iterator = await store.snapshots().makeAsyncIterator()
            let snapshot = await iterator.next()
            guard let playlist = snapshot?.playlists.first(where: { $0.id == manifest.playlistID }), let coverKey = playlist.coverFileKey else { throw Failure(message: "Playlist metadata lost") }
            let coverData = try await files.read(coverKey)
            try require(playlist.name == "改名前的歌单" && coverData == Data("cover-before-rename".utf8), "Cover/name lost")
            let playback = try await store.loadPlayback()
            try require(playback?.positionMS == 42_000 && playback?.requestedQuality == .flac && playback?.queue.mode == .singleRepeat && playback?.queue.current?.track.key == track.key, "Playback snapshot lost")
            let history = try await store.recentTracks(limit: 10)
            let queries = try await store.recentQueries()
            let offset = try await store.lyricOffset(for: track.key)
            try require(history.first?.track.key == track.key && queries == ["改名前的搜索"] && offset == 1500, "History/lyric adjustment lost")
            let loadedSettings = await settingsStore.load()
            try require(loadedSettings == settings, "Settings lost")
            defaults.removePersistentDomain(forName: suite); defaults.synchronize()
            print("PASS new module reopened every old-module sample without migration or data loss")
        default: throw Failure(message: "Unknown mode: \(mode)")
        }
    }
}
