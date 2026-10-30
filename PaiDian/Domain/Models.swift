import Foundation

enum MusicPlatform: String, Codable, CaseIterable, Sendable, Identifiable {
    case kw, kg, tx, wy, mg
    var id: String { rawValue }
    var name: String { switch self { case .kw: "酷我"; case .kg: "酷狗"; case .tx: "QQ 音乐"; case .wy: "网易云"; case .mg: "咪咕" } }
}
struct TrackKey: Codable, Hashable, Sendable {
    var platform: MusicPlatform
    var providerID: String
    var encoded: String { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return (try? encoder.encode(self).base64EncodedString()) ?? "" }
    init(platform: MusicPlatform, providerID: String) { self.platform = platform; self.providerID = providerID }
    init(encoded: String) throws { self = try JSONDecoder().decode(Self.self, from: Data(base64Encoded: encoded) ?? Data()) }
}
enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
    var string: String? { switch self { case .string(let v): v; case .number(let v): String(format: "%.0f", v); default: nil } }
    var object: [String: JSONValue] { if case .object(let v) = self { v } else { [:] } }
}
enum AudioQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case q128 = "128k", q320 = "320k", flac, flac24bit
    var id: String { rawValue }
    var name: String { switch self { case .q128: "标准"; case .q320: "高品质"; case .flac: "无损"; case .flac24bit: "Hi-Res" } }
}
/// Inclusive request bounds; the source decides whether a particular recording has that quality.
struct QualityRange: Codable, Hashable, Sendable {
    var minimum: AudioQuality
    var maximum: AudioQuality
    init(minimum: AudioQuality = .q128, maximum: AudioQuality = .flac24bit) {
        self.minimum = minimum.rank <= maximum.rank ? minimum : maximum
        self.maximum = minimum.rank <= maximum.rank ? maximum : minimum
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minimum: (try? c.decode(AudioQuality.self,forKey:.minimum)) ?? .q128,
                  maximum: (try? c.decode(AudioQuality.self,forKey:.maximum)) ?? .flac24bit)
    }
    var descending: [AudioQuality] { AudioQuality.allCases.reversed().filter { $0.rank >= minimum.rank && $0.rank <= maximum.rank } }
    private enum CodingKeys: String,CodingKey { case minimum,maximum }
}
extension AudioQuality { var rank: Int { Self.allCases.firstIndex(of:self)! } }
struct SourceQualityKey: Codable, Hashable, Sendable { var scriptID: UUID; var quality: AudioQuality }
struct SourceResolutionRequest: Sendable {
    var range: QualityRange
    var excluding: Set<SourceQualityKey> = []
    var retrying: SourceQualityKey? = nil
}
struct PlatformMetadata: Codable, Hashable, Sendable { var schemaVersion = 1; var payload: [String: JSONValue] = [:] }
struct Track: Codable, Hashable, Sendable, Identifiable {
    var key: TrackKey
    var title: String
    var artists: [String]
    var albumTitle: String = ""
    var durationMS: Int64?
    var artworkURL: URL?
    var qualities: Set<AudioQuality> = []
    var metadata = PlatformMetadata()
    var id: TrackKey { key }
    var artistText: String { artists.joined(separator: " / ") }
}
struct SearchPage: Sendable { var tracks: [Track]; var page: Int; var hasMore: Bool; var total: Int? }
enum SearchSelection: Hashable, Sendable { case all, platform(MusicPlatform) }
struct PlatformSearchState: Sendable, Identifiable {
    var platform: MusicPlatform; var tracks: [Track] = []; var nextPage = 1; var hasMore = true; var isLoading = false; var failure: AppFailure?
    var id: MusicPlatform { platform }
}
struct SearchSnapshot: Sendable { var revision = UUID(); var query = ""; var selection: SearchSelection = .all; var groups: [PlatformSearchState] = [] }
struct SourceCapability: Codable, Hashable, Sendable { var actions: Set<String>; var qualities: Set<AudioQuality> }
struct SourceCapabilities: Codable, Hashable, Sendable { var apiVersion = "2.0.0"; var platforms: [MusicPlatform: SourceCapability] = [:] }
struct SourceScript: Codable, Hashable, Sendable, Identifiable {
    var id = UUID(); var name: String; var version: String?; var author: String?; var description: String?; var homepage: String?; var originURL: URL?; var fileKey: String; var digest: String
    var lastValidatedCapabilities: SourceCapabilities?; var lastValidatedAt: Date?
    var ecbPKCS7Compatibility: Bool? = nil
    var initializationError: String? = nil
}
struct SourceUpdateNotice: Sendable { var message: String; var url: URL? }
struct SourceSnapshot: Sendable {
    var revision = UUID(); var scripts: [SourceScript] = []; var activeScriptID: UUID?; var generation = UUID(); var capabilities = SourceCapabilities(); var failure: AppFailure?; var updateNotice: SourceUpdateNotice?
    var resolvingSourceName:String?
    var resolvingQuality:AudioQuality?
    var playbackCapabilities:SourceCapabilities {
        var result=capabilities
        for script in scripts {
            for (platform,capability) in script.lastValidatedCapabilities?.platforms ?? [:] {
                var merged=result.platforms[platform] ?? SourceCapability(actions:[],qualities:[])
                merged.actions.formUnion(capability.actions);merged.qualities.formUnion(capability.qualities);result.platforms[platform]=merged
            }
        }
        return result
    }
}
struct SourceImport: Sendable { var url: URL; var replacementID: UUID?; var retainOnInitializationFailure = false }
struct ResolvedStream: Sendable { var url: URL; var requestedQuality: AudioQuality; var scriptID: UUID; var sourceGeneration: UUID; var sourceName:String? = nil;var failedAttempts:Set<SourceQualityKey> = []
    var attempt:SourceQualityKey { SourceQualityKey(scriptID:scriptID,quality:requestedQuality) }
    var failedScriptIDs:Set<UUID> { Set(failedAttempts.map(\.scriptID)) }
}
enum PlaylistKind: String, Codable, Sendable { case favorites, user }
struct Playlist: Codable, Hashable, Sendable, Identifiable {
    static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    var id = UUID(); var name: String; var kind: PlaylistKind = .user; var coverFileKey: String?; var createdAt = Date(); var updatedAt = Date(); var count = 0; var artworkURL: URL?
}
struct PlaylistItem: Codable, Hashable, Sendable, Identifiable { var id = UUID(); var track: Track; var position: Int; var addedAt = Date() }
struct PlaylistDraft: Sendable { var name: String; var coverFileKey: String? }
struct LibrarySnapshot: Sendable { var revision = UUID(); var playlists: [Playlist] = []; var favoriteKeys: Set<TrackKey> = []; var trackCount = 0 }
enum LibraryCommand: Sendable {
    case create(PlaylistDraft), update(UUID, PlaylistDraft), delete(UUID), addTracks(UUID, [Track]), removeItems(UUID, Set<UUID>), reorder(UUID, [UUID]), setFavorite(Track, Bool)
}
struct LibraryResult: Sendable { var playlistID: UUID?; var added = 0; var duplicates = 0 }
struct HistoryEntry: Codable, Sendable, Identifiable { var track: Track; var lastPlayedAt: Date; var playCount: Int; var id: TrackKey { track.key } }
struct QueueEntry: Codable, Hashable, Sendable, Identifiable { var id = UUID(); var track: Track }
enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    case sequential, listRepeat, singleRepeat, shuffle
    var name: String { switch self { case .sequential: "顺序播放"; case .listRepeat: "列表循环"; case .singleRepeat: "单曲循环"; case .shuffle: "随机播放" } }
    var symbol: String { switch self { case .sequential: "arrow.right"; case .listRepeat: "repeat"; case .singleRepeat: "repeat.1"; case .shuffle: "shuffle" } }
    var next: Self { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}
struct QueueState: Codable, Hashable, Sendable {
    var entries: [QueueEntry] = []; var currentEntryID: UUID?; var mode: PlaybackMode = .sequential
    var priorityIDs: [UUID] = []; var shuffleRemaining: [UUID] = []; var historyIDs: [UUID] = []; var historyCursor = -1
    var current: QueueEntry? { entries.first { $0.id == currentEntryID } }
}
enum AdvanceDirection: Sendable { case next, previous }
enum AdvanceReason: Sendable { case natural, manual, failure }
enum QueueCommand: Sendable {
    case replace([QueueEntry], UUID?), select(UUID), commitStarted(UUID), setMode(PlaybackMode), insertNext([Track]), move([UUID]), remove(Set<UUID>), clear
    case advance(AdvanceDirection, AdvanceReason, Set<UUID>)
}
enum QueueSelection: Equatable, Sendable { case stay, select(UUID), end }
struct QueueTransition: Sendable { var state: QueueState; var selection: QueueSelection = .stay }
enum PlaybackStatus: String, Sendable { case idle, resolving, buffering, playing, paused, ended, failed }
struct PlaybackViewState: Sendable {
    var revision = UUID(); var status: PlaybackStatus = .idle; var queue = QueueState(); var positionMS: Int64 = 0; var durationMS: Int64 = 0; var canSeek = false; var requestedQuality: AudioQuality = .q128; var desiredPlaying = false; var failure: AppFailure?
    var bufferedRanges:[PlaybackTimeRange]=[]
    var confirmedPositionMS:Int64=0
    var isLocallyCached=false
    var cacheWarning:String?
    var resolvedSourceName:String?
    var qualityRange=QualityRange()
    var attemptedQuality:AudioQuality?
    var resolvedQuality:AudioQuality?
    var displayedQuality:AudioQuality? { resolvedQuality ?? attemptedQuality }
}
struct PlaybackTimeRange:Equatable,Sendable { var startMS:Int64;var endMS:Int64 }
struct PlaybackClockSample: Sendable {
    var mediaID:UUID
    var trackKey:TrackKey
    var positionMS:Int64
    var rate:Double
    var advancing:Bool
}
struct PlaybackSnapshot: Codable, Sendable { var schemaVersion = 1; var queue: QueueState; var positionMS: Int64; var requestedQuality: AudioQuality }
enum LyricFormat:String,Codable,Sendable { case lrc,yrc,krc,lyricx,qrc,mrc }
struct RawLyrics: Codable, Sendable { var original: String?; var translation: String?;var format:LyricFormat = .lrc }
struct LyricOrigin: Codable,Sendable,Equatable { var requestedKey:TrackKey;var sourceKey:TrackKey;var format:LyricFormat }
struct LyricLine: Codable, Sendable, Identifiable, Equatable { var startMS: Int64; var text: String; var translation: String?; var id: Int64 { startMS } }
struct LyricDocument: Codable, Sendable { var timedLines: [LyricLine] = []; var plainText: String?;var origin:LyricOrigin? }
enum Appearance: String, Codable, CaseIterable, Sendable { case system, light, dark; var name: String { switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" } } }
struct AppSettings: Codable, Sendable, Equatable {
    var appearance: Appearance = .system
    var qualityRange=QualityRange()
    var audioCacheGB:Int=2
    var lyricFontSize: Double = 17
    var lyricLineSpacing: Double = 14
    var lyricCurrentLineScale: Double = 1.08
    var preferredSearchPlatform: MusicPlatform?
    init() {}
    private enum CodingKeys: String, CodingKey { case appearance, qualityRange, audioCacheGB, lyricFontSize, lyricLineSpacing, lyricCurrentLineScale, preferredSearchPlatform }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try values.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .system
        qualityRange = (try? values.decode(QualityRange.self,forKey:.qualityRange)) ?? QualityRange()
        let storedGB=(try? values.decode(Int.self,forKey:.audioCacheGB)) ?? 2
        audioCacheGB=[1,2,5].contains(storedGB) ? storedGB : 2
        lyricFontSize = min(24,max(14,try values.decodeIfPresent(Double.self, forKey: .lyricFontSize) ?? 17))
        lyricLineSpacing = min(28,max(6,try values.decodeIfPresent(Double.self, forKey: .lyricLineSpacing) ?? 14))
        lyricCurrentLineScale = min(1.25,max(1,try values.decodeIfPresent(Double.self, forKey: .lyricCurrentLineScale) ?? 1.08))
        preferredSearchPlatform = try values.decodeIfPresent(MusicPlatform.self, forKey: .preferredSearchPlatform)
    }
    func searchSelection(explicit: SearchSelection?, available: Set<MusicPlatform>) -> SearchSelection {
        let requested = explicit ?? preferredSearchPlatform.map { .platform($0) } ?? .all
        if case .platform(let platform) = requested, !available.contains(platform) { return .all }
        return requested
    }
}
enum CacheKind: String, Sendable { case artwork, lyrics }
struct HTTPPayload: Sendable { var url: URL; var method = "GET"; var headers: [String: String] = [:]; var body: Data?; var timeoutMS = 15_000; var maximumBytes = 8 * 1024 * 1024 }
struct HTTPResult: Sendable { var status: Int; var headers: [String: String]; var body: Data; var finalURL: URL }
struct AppFailure: Error, LocalizedError, Codable, Sendable, Equatable {
    var code: String; var module: String; var platform: MusicPlatform?; var requestID: UUID?; var userMessage: String; var retryable: Bool = false
    var errorDescription: String? { userMessage }
    static func make(_ message: String, code: String = "invalidInput", module: String = "app", retryable: Bool = false) -> Self { .init(code: code, module: module, userMessage: message, retryable: retryable) }
    static func wrap(_ error: Error, module: String) -> Self { (error as? Self) ?? .make(error is URLError ? "网络请求失败，请检查网络后重试" : "操作失败：\(error.localizedDescription)", code: "operationFailed", module: module, retryable: true) }
}
