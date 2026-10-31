import Foundation

// This is the only application composition root that creates concrete business services.
@MainActor struct AppServices {
    var library: any LibraryServing
    var history: any HistoryRepository
    var queries: any SearchHistoryRepository
    var sources: any SourceManaging
    var search: any SearchServing
    var playback: any PlaybackControlling
    var lyricAdjustments: any LyricAdjustmentRepository
    var lyrics: any LyricsServing
    var files: any ManagedFileStore
    var cache: DiskResourceCache
    var audioCache:AudioCacheStore
    var artwork: ArtworkLoader
    var settings: any SettingsStore
    var media: SystemMediaController?
    var sourceBridge: Task<Void,Never>?
    var bundledSources: BundledSourceInstaller? = nil
}
@MainActor enum AppContainer {
    static func make(inMemory: Bool = false) async throws -> AppServices {
        let container = try MusicStore.container(inMemory:inMemory), store = MusicStore(modelContainer:container)
        try await store.prepare()
        // Keep legacy storage paths so rebranding does not orphan imported scripts, covers or caches.
        let support = URL.applicationSupportDirectory.appendingPathComponent("AnyListen",isDirectory:true)
        let files = try DiskFileStore(root:support), cache = try DiskResourceCache(root:URL.cachesDirectory.appendingPathComponent("AnyListen",isDirectory:true)), http = URLSessionHTTPClient()
        let audioCache=AudioCacheStore(root:URL.cachesDirectory.appendingPathComponent("AnyListenAudio",isDirectory:true))
        let sources = SourceManager(repository:store,files:files,http:http)
        let providers = Dictionary(uniqueKeysWithValues:MusicPlatform.allCases.map { ($0,PlatformCatalog(platform:$0,http:http) as any CatalogProvider) })
        let search = SearchService(providers:providers,history:store), playback = PlaybackCoordinator(source:sources,snapshots:store,history:store,engine:AVAudioEngineAdapter(audioCache:audioCache),audioCache:audioCache)
        let artwork = ArtworkLoader(cache:cache,http:http,providers:providers), media = SystemMediaController(playback:playback,artwork:artwork)
        playback.onStateChange = { [weak media] state in media?.update(state) }
        let bridge = Task {
            var generation: UUID?
            for await value in await sources.snapshots() {
                guard !Task.isCancelled else { return }
                playback.updateCapabilities(value.playbackCapabilities)
                playback.updateResolutionProgress(value.resolvingQuality)
                await search.updateAvailablePlatforms(Set(value.playbackCapabilities.platforms.keys))
                if generation != value.generation { generation = value.generation; await playback.sourceDidChange(generation:value.generation) }
            }
        }
        let bundledSources = !inMemory ? Bundle.main.url(forResource:"BundledSources",withExtension:nil).map {
            BundledSourceInstaller(directory:$0,repository:store,manager:sources,defaults:.standard)
        } : nil
        return AppServices(library:store,history:store,queries:store,sources:sources,search:search,playback:playback,lyricAdjustments:store,lyrics:LyricsService(providers:providers,cache:cache),files:files,cache:cache,audioCache:audioCache,artwork:artwork,settings:DefaultsSettingsStore(),media:media,sourceBridge:bridge,bundledSources:bundledSources)
    }
}
