import Foundation
import SwiftData

enum MusicSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [TrackRecord.self, PlaylistRecord.self, PlaylistItemRecord.self, SourceRecord.self, ValueRecord.self, HistoryRecord.self] }
    @Model final class TrackRecord { @Attribute(.unique) var key: String; var payload: Data; init(key: String, payload: Data) { self.key = key; self.payload = payload } }
    @Model final class PlaylistRecord { @Attribute(.unique) var id: UUID; var payload: Data; init(id: UUID, payload: Data) { self.id = id; self.payload = payload } }
    @Model final class PlaylistItemRecord { @Attribute(.unique) var id: UUID; var playlistID: UUID; var trackKey: String; var position: Int; var addedAt: Date; init(id: UUID = UUID(), playlistID: UUID, trackKey: String, position: Int, addedAt: Date = Date()) { self.id = id; self.playlistID = playlistID; self.trackKey = trackKey; self.position = position; self.addedAt = addedAt } }
    @Model final class SourceRecord { @Attribute(.unique) var id: UUID; var payload: Data; init(id: UUID, payload: Data) { self.id = id; self.payload = payload } }
    @Model final class ValueRecord { @Attribute(.unique) var key: String; var payload: Data; init(key: String, payload: Data) { self.key = key; self.payload = payload } }
    @Model final class HistoryRecord { @Attribute(.unique) var key: String; var payload: Data; init(key: String, payload: Data) { self.key = key; self.payload = payload } }
}
enum MusicMigrationPlan: SchemaMigrationPlan { static var schemas: [any VersionedSchema.Type] { [MusicSchemaV1.self] }; static var stages: [MigrationStage] { [] } }
typealias TrackRecord = MusicSchemaV1.TrackRecord
typealias PlaylistRecord = MusicSchemaV1.PlaylistRecord
typealias PlaylistItemRecord = MusicSchemaV1.PlaylistItemRecord
typealias SourceRecord = MusicSchemaV1.SourceRecord
typealias ValueRecord = MusicSchemaV1.ValueRecord
typealias HistoryRecord = MusicSchemaV1.HistoryRecord

@ModelActor actor MusicStore: LibraryServing, SourceRepository, SearchHistoryRepository, PlaybackSnapshotRepository, HistoryRepository, LyricAdjustmentRepository {
    private var subscribers: [UUID: AsyncStream<LibrarySnapshot>.Continuation] = [:]
    private var latest = LibrarySnapshot()
    static func container(inMemory: Bool = false, url: URL? = nil) throws -> ModelContainer {
        let schema = Schema(versionedSchema: MusicSchemaV1.self)
        let configuration = url.map { ModelConfiguration(schema:schema,url:$0,cloudKitDatabase:.none) } ?? ModelConfiguration(schema:schema,isStoredInMemoryOnly:inMemory,cloudKitDatabase:.none)
        return try ModelContainer(for: schema, migrationPlan: MusicMigrationPlan.self, configurations: configuration)
    }
    func prepare() throws {
        modelContext.autosaveEnabled = false
        if try playlists().allSatisfy({ $0.id != Playlist.favoritesID }) {
            let playlist = Playlist(id: Playlist.favoritesID, name: "我喜欢的音乐", kind: .favorites)
            modelContext.insert(PlaylistRecord(id: playlist.id, payload: try encode(playlist))); try modelContext.save()
        }
        latest = try currentSnapshot()
    }
    private func encode<T: Encodable>(_ v: T) throws -> Data { try JSONEncoder().encode(v) }
    private func decode<T: Decodable>(_ t: T.Type, _ data: Data) throws -> T { try JSONDecoder().decode(t, from: data) }
    private func playlists() throws -> [PlaylistRecord] { try modelContext.fetch(FetchDescriptor<PlaylistRecord>()) }
    private func allItems() throws -> [PlaylistItemRecord] { try modelContext.fetch(FetchDescriptor<PlaylistItemRecord>()) }
    private func value(_ key: String) throws -> ValueRecord? { try modelContext.fetch(FetchDescriptor<ValueRecord>()).first { $0.key == key } }
    private func setValue<T: Encodable>(_ key: String, _ object: T) throws { let data = try encode(object); if let record = try value(key) { record.payload = data } else { modelContext.insert(ValueRecord(key: key, payload: data)) } }
    private func transact<T>(_ action: () throws -> T) throws -> T {
        do { let result = try action(); try modelContext.save(); return result } catch { modelContext.rollback(); throw error }
    }
    private func currentSnapshot() throws -> LibrarySnapshot {
        let records = try allItems()
        let tracks = try modelContext.fetch(FetchDescriptor<TrackRecord>())
        let byKey = Dictionary(uniqueKeysWithValues: try tracks.map { ($0.key, try decode(Track.self, $0.payload)) })
        var lists = try playlists().map { try decode(Playlist.self, $0.payload) }
        for i in lists.indices { let items = records.filter { $0.playlistID == lists[i].id }.sorted { $0.position < $1.position }; lists[i].count = items.count; lists[i].artworkURL = items.first.flatMap { byKey[$0.trackKey]?.artworkURL } }
        lists.sort { if $0.kind != $1.kind { return $0.kind == .favorites }; return $0.createdAt > $1.createdAt }
        let favoriteKeys = Set(records.filter { $0.playlistID == Playlist.favoritesID }.compactMap { byKey[$0.trackKey]?.key })
        return LibrarySnapshot(playlists: lists, favoriteKeys: favoriteKeys, trackCount: byKey.count)
    }
    func snapshots() -> AsyncStream<LibrarySnapshot> {
        let snapshot = latest, id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in subscribers[id] = c; c.yield(snapshot); c.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } } }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    func items(playlistID: UUID) throws -> [PlaylistItem] {
        let tracks = Dictionary(uniqueKeysWithValues: try modelContext.fetch(FetchDescriptor<TrackRecord>()).map { ($0.key, try decode(Track.self, $0.payload)) })
        return try allItems().filter { $0.playlistID == playlistID }.sorted { $0.position < $1.position }.compactMap { item in tracks[item.trackKey].map { PlaylistItem(id: item.id, track: $0, position: item.position, addedAt: item.addedAt) } }
    }
    func perform(_ command: LibraryCommand) throws -> LibraryResult {
        let result = try transact {
            var result = LibraryResult()
            func name(_ value: String) throws -> String { let v = value.trimmingCharacters(in: .whitespacesAndNewlines); guard (1...40).contains(v.count) else { throw AppFailure.make("歌单名称需要 1–40 个字符", module: "library") }; return v }
            func record(_ id: UUID) throws -> PlaylistRecord { guard let row = try playlists().first(where: { $0.id == id }) else { throw AppFailure.make("歌单不存在", code: "notFound", module: "library") }; return row }
            func add(_ id: UUID, _ tracks: [Track]) throws {
                let row = try record(id); var playlist = try decode(Playlist.self, row.payload)
                let existing = try allItems().filter { $0.playlistID == id }; var keys = Set(existing.map(\.trackKey)); var pos = existing.count
                let trackRecords = try modelContext.fetch(FetchDescriptor<TrackRecord>())
                var byKey = Dictionary(uniqueKeysWithValues: trackRecords.map { ($0.key, $0) })
                for track in tracks {
                    let key = track.key.encoded
                    if let stored = byKey[key] { stored.payload = try encode(track) } else { let stored = TrackRecord(key: key, payload: try encode(track)); modelContext.insert(stored); byKey[key] = stored }
                    guard keys.insert(key).inserted else { result.duplicates += 1; continue }
                    modelContext.insert(PlaylistItemRecord(playlistID: id, trackKey: key, position: pos)); pos += 1; result.added += 1
                }
                playlist.updatedAt = Date(); row.payload = try encode(playlist)
            }
            switch command {
            case .create(let draft):
                let p = Playlist(name: try name(draft.name), coverFileKey: draft.coverFileKey); modelContext.insert(PlaylistRecord(id: p.id, payload: try encode(p))); result.playlistID = p.id
            case .update(let id, let draft):
                let row = try record(id); var p = try decode(Playlist.self, row.payload); guard p.kind == .user else { throw AppFailure.make("内置歌单不可修改名称", module: "library") }; p.name = try name(draft.name); p.coverFileKey = draft.coverFileKey; p.updatedAt = Date(); row.payload = try encode(p)
            case .delete(let id):
                guard id != Playlist.favoritesID else { throw AppFailure.make("不能删除我喜欢的音乐", module: "library") }; let row = try record(id); for item in try allItems() where item.playlistID == id { modelContext.delete(item) }; modelContext.delete(row)
            case .addTracks(let id, let tracks): try add(id, tracks)
            case .setFavorite(let track, let flag):
                if flag { try add(Playlist.favoritesID, [track]) } else { for item in try allItems() where item.playlistID == Playlist.favoritesID && item.trackKey == track.key.encoded { modelContext.delete(item) } }
            case .removeItems(let id, let ids):
                _ = try record(id); let rows = try allItems().filter { $0.playlistID == id }.sorted { $0.position < $1.position }; for row in rows where ids.contains(row.id) { modelContext.delete(row) }; for (i, row) in rows.filter({ !ids.contains($0.id) }).enumerated() { row.position = i }
            case .reorder(let id, let ids):
                _ = try record(id); let rows = try allItems().filter { $0.playlistID == id }; guard ids.count == rows.count, Set(ids) == Set(rows.map(\.id)) else { throw AppFailure.make("歌单已变化，请刷新后重试", module: "library") }; let positions = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }); for row in rows { row.position = positions[row.id]! }
            }
            return result
        }
        let snapshot = try currentSnapshot(); latest = snapshot; for c in subscribers.values { c.yield(snapshot) }; return result
    }
    func scripts() throws -> [SourceScript] {
        let order=try sourceOrderIDs(),rank=Dictionary(uniqueKeysWithValues:order.enumerated().map{($0.element,$0.offset)})
        return try modelContext.fetch(FetchDescriptor<SourceRecord>()).map { try decode(SourceScript.self,$0.payload) }.sorted { a,b in
            let x=rank[a.id] ?? Int.max,y=rank[b.id] ?? Int.max;return x == y ? a.name < b.name : x < y
        }
    }
    func activeScriptID() throws -> UUID? { try value("activeSource").flatMap { try decode(UUID?.self, $0.payload) } }
    func sourceOrderIDs() throws -> [UUID] {
        if let row=try value("sourceOrder") { return try decode([UUID].self,row.payload) }
        let legacy=try value("fallbackSources").map { try decode([UUID].self,$0.payload) } ?? []
        var seen=Set<UUID>();return ([try activeScriptID()].compactMap{$0}+legacy).filter{seen.insert($0).inserted}
    }
    func setSourceOrderIDs(_ ids:[UUID]) throws { try transact { try setValue("sourceOrder",ids) } }
    func save(_ script: SourceScript) throws { try transact { if let r = try modelContext.fetch(FetchDescriptor<SourceRecord>()).first(where: { $0.id == script.id }) { r.payload = try encode(script) } else { modelContext.insert(SourceRecord(id: script.id, payload: try encode(script)));var order=try sourceOrderIDs();if !order.contains(script.id) { order.append(script.id) };try setValue("sourceOrder",order) } } }
    func setActive(_ scriptID: UUID?) throws { try transact { if let id = scriptID, try scripts().allSatisfy({ $0.id != id }) { throw AppFailure.make("音源不存在", module: "storage") }; try setValue("activeSource", scriptID) } }
    func delete(_ scriptID: UUID) throws { try transact { for r in try modelContext.fetch(FetchDescriptor<SourceRecord>()) where r.id == scriptID { modelContext.delete(r) }; if try activeScriptID() == scriptID { try setValue("activeSource", Optional<UUID>.none) };try setValue("sourceOrder",sourceOrderIDs().filter{$0 != scriptID}) } }
    func lyricOffset(for key: TrackKey) throws -> Int64 {
        try value("lyricOffset.v1." + key.encoded).map { try decode(Int64.self, $0.payload) } ?? 0
    }
    func saveLyricOffset(_ milliseconds: Int64, for key: TrackKey) throws {
        try transact { try setValue("lyricOffset.v1." + key.encoded, milliseconds) }
    }
    func resetLyricOffset(for key: TrackKey) throws {
        try transact { if let row = try value("lyricOffset.v1." + key.encoded) { modelContext.delete(row) } }
    }
    func recentQueries() throws -> [String] { try value("searchHistory").map { try decode([String].self, $0.payload) } ?? [] }
    func recordQuery(_ query: String) throws { let q = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !q.isEmpty else { return }; var rows = try recentQueries().filter { $0 != q }; rows.insert(q, at: 0); try transact { try setValue("searchHistory", Array(rows.prefix(20))) } }
    func removeQuery(_ query: String) throws { try transact { try setValue("searchHistory", recentQueries().filter { $0 != query }) } }
    func clearQueries() throws { try transact { try setValue("searchHistory", [String]()) } }
    func loadPlayback() throws -> PlaybackSnapshot? { guard let r = try value("playback") else { return nil }; return try? decode(PlaybackSnapshot.self, r.payload) }
    func savePlayback(_ snapshot: PlaybackSnapshot) throws { try transact { try setValue("playback", snapshot) } }
    func recentTracks(limit: Int) throws -> [HistoryEntry] { Array(try modelContext.fetch(FetchDescriptor<HistoryRecord>()).map { try decode(HistoryEntry.self, $0.payload) }.sorted { $0.lastPlayedAt > $1.lastPlayedAt }.prefix(max(0, limit))) }
    func recordStarted(_ track: Track, at: Date) throws {
        try transact {
            let rows = try modelContext.fetch(FetchDescriptor<HistoryRecord>())
            if let row = rows.first(where: { $0.key == track.key.encoded }) { var entry = try decode(HistoryEntry.self, row.payload); entry.track = track; entry.lastPlayedAt = at; entry.playCount += 1; row.payload = try encode(entry) }
            else { modelContext.insert(HistoryRecord(key: track.key.encoded, payload: try encode(HistoryEntry(track: track, lastPlayedAt: at, playCount: 1)))) }
            let sorted = try modelContext.fetch(FetchDescriptor<HistoryRecord>()).sorted { ((try? decode(HistoryEntry.self, $0.payload).lastPlayedAt) ?? .distantPast) > ((try? decode(HistoryEntry.self, $1.payload).lastPlayedAt) ?? .distantPast) }
            for row in sorted.dropFirst(500) { modelContext.delete(row) }
        }
    }
}
