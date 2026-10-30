import Foundation
#if !HOST_TESTS
@testable import PaiDian
#endif

func testTrack(_ id: String, platform: MusicPlatform = .kw) -> Track {
    Track(key: TrackKey(platform: platform, providerID: id), title: "测试曲目 " + id, artists: ["测试作者"], durationMS: 120_000, qualities: [.q128], metadata: PlatformMetadata(payload: ["songmid":.string(id), "source":.string(platform.rawValue), "name":.string("测试曲目 " + id)]))
}
struct ValidationFailure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
func expect(_ condition: Bool, _ message: String) throws { if !condition { throw ValidationFailure(message: message) } }
func expectFailure(_ action: () throws -> Void) throws { do { try action() } catch { return }; throw ValidationFailure(message: "预期失败但操作成功") }
actor MemoryRepository: SourceRepository, SearchHistoryRepository, PlaybackSnapshotRepository, HistoryRepository {
    var sourceRows: [SourceScript] = []; var activeID: UUID?; var queries: [String] = []; var snapshot: PlaybackSnapshot?; var played: [HistoryEntry] = []; var rejectSave = false
    var sourceOrder:[UUID] = []
    func sourceOrderIDs()->[UUID] { sourceOrder }
    func setSourceOrderIDs(_ ids:[UUID]) throws { if rejectSave { throw ValidationFailure(message:"注入保存失败") };sourceOrder=ids }
    func scripts() -> [SourceScript] { sourceRows.sorted{(sourceOrder.firstIndex(of:$0.id) ?? Int.max) < (sourceOrder.firstIndex(of:$1.id) ?? Int.max)} }
    func activeScriptID() -> UUID? { activeID }
    func save(_ script: SourceScript) throws { if rejectSave { throw ValidationFailure(message: "注入保存失败") }; sourceRows.removeAll { $0.id == script.id }; sourceRows.append(script);if !sourceOrder.contains(script.id) { sourceOrder.append(script.id) } }
    func setActive(_ scriptID: UUID?) throws { if rejectSave { throw ValidationFailure(message: "注入保存失败") }; activeID = scriptID }
    func delete(_ scriptID: UUID) { sourceRows.removeAll { $0.id == scriptID }; if activeID == scriptID { activeID = nil } }
    func setRejectSave(_ flag: Bool) { rejectSave = flag }
    func recentQueries() -> [String] { queries }
    func recordQuery(_ query: String) { queries.removeAll { $0 == query }; queries.insert(query, at: 0) }
    func removeQuery(_ query: String) { queries.removeAll { $0 == query } }
    func clearQueries() { queries = [] }
    func loadPlayback() -> PlaybackSnapshot? { snapshot }
    func savePlayback(_ value: PlaybackSnapshot) { snapshot = value }
    func recentTracks(limit: Int) -> [HistoryEntry] { Array(played.prefix(limit)) }
    func recordStarted(_ track: Track, at: Date) { played.append(HistoryEntry(track: track, lastPlayedAt: at, playCount: 1)) }
}
struct FixedHTTP: HTTPClient {
    var body = Data("{\"url\":\"https://example.test/audio.mp3\"}".utf8)
    var status = 200
    func execute(_ request: HTTPPayload) async throws -> HTTPResult { HTTPResult(status: status, headers: ["content-type":"application/json"], body: body, finalURL: request.url) }
}
struct FixedCatalog: CatalogProvider {
    let platform: MusicPlatform
    var fail = false
    func search(query: String, page: Int, pageSize: Int) async throws -> SearchPage {
        if query == "旧请求" { try? await Task.sleep(for: .milliseconds(60)) }
        if fail { throw ValidationFailure(message: "注入平台失败") }
        return SearchPage(tracks: [testTrack(query, platform: platform),testTrack("page-\(page)", platform: platform)], page: page, hasMore: page < 2, total: 3)
    }
    func fetchTrackDetail(_ track: Track) async throws -> Track { track }
    func fetchLyrics(_ track: Track) async throws -> RawLyrics { RawLyrics(original: "[00:01]本地测试歌词", translation: nil) }
}
struct SeededRandom: RandomNumberGenerator {
    var value: UInt64 = 42
    mutating func next() -> UInt64 { value = value &* 6364136223846793005 &+ 1442695040888963407; return value }
}
let validScript = """
/**
 * @name 本地协议测试
 * @version 1.0
 */
lx.on(lx.EVENT_NAMES.request, ({info}) => Promise.resolve('https://example.test/' + info.musicInfo.songmid + '.mp3'));
lx.send(lx.EVENT_NAMES.inited, {sources:{kw:{name:'酷我',type:'music',actions:['musicUrl'],qualitys:['128k']}}});
"""
