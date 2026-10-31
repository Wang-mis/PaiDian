import Foundation
import ImageIO

actor ArtworkLoader {
    private let cache: any ResourceCache
    private let http: any HTTPClient
    private let providers: [MusicPlatform: any CatalogProvider]
    private var flights: [URL: (UUID, Task<Data, Error>)] = [:]
    private var trackFlights: [TrackKey: (UUID, Task<Data, Error>)] = [:]
    init(cache: any ResourceCache, http: any HTTPClient, providers: [MusicPlatform: any CatalogProvider] = [:]) { self.cache = cache; self.http = http; self.providers = providers }
    func load(_ track: Track) async throws -> Data {
        let id: UUID, task: Task<Data,Error>
        if let pending = trackFlights[track.key] { (id,task) = pending }
        else {
            id = UUID(); task = Task { try await self.loadTrack(track) }
            trackFlights[track.key] = (id,task)
        }
        do {
            let data = try await task.value
            if trackFlights[track.key]?.0 == id { trackFlights.removeValue(forKey:track.key) }
            try Task.checkCancellation(); return data
        } catch {
            if trackFlights[track.key]?.0 == id { trackFlights.removeValue(forKey:track.key) }
            throw error
        }
    }
    private func loadTrack(_ track: Track) async throws -> Data {
        do { return try await load(resolveURL(track, refresh:false)) }
        catch {
            try Task.checkCancellation()
            guard track.key.platform == .kw || track.key.platform == .kg else { throw error }
            // Retry metadata once if a persisted or cached cover address has expired.
            return try await load(resolveURL(track, refresh:true))
        }
    }
    private func resolveURL(_ track: Track, refresh: Bool) async throws -> URL {
        if !refresh, let url = track.artworkURL { return url }
        let key = "artwork-url-v1-" + track.key.encoded
        if !refresh, let data = try? await cache.read(key:key,kind:.artwork),
           let raw = String(data:data,encoding:.utf8), let url = URL(string:raw),
           ["http","https"].contains(url.scheme ?? ""), url.host != nil { return url }
        guard let provider = providers[track.key.platform] else { throw AppFailure.make("没有可用的封面详情服务",module:"artwork") }
        let epoch = await cache.epoch()
        var missing = track; missing.artworkURL = nil
        let detail = try await provider.fetchTrackDetail(missing)
        guard let url = detail.artworkURL, ["http","https"].contains(url.scheme ?? ""), url.host != nil else { throw AppFailure.make("歌曲暂无封面",module:"artwork") }
        try? await cache.write(Data(url.absoluteString.utf8),key:key,kind:.artwork,epoch:epoch)
        return url
    }
    private static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source,0,nil) != nil
    }
    func load(_ url: URL) async throws -> Data {
        if let data = try? await cache.read(key:url.absoluteString,kind:.artwork), Self.isImage(data) { return data }
        let id: UUID, task: Task<Data,Error>
        if let existing = flights[url] { (id,task) = existing }
        else {
            id = UUID(); let epoch = await cache.epoch()
            // Other subscribers may have installed a flight while reading the cache epoch.
            if let existing = flights[url] { return try await existing.1.value }
            task = Task { [http,cache] in
                let result = try await http.execute(HTTPPayload(url:url,maximumBytes:8*1024*1024))
                guard (200..<300).contains(result.status) else { throw AppFailure.make("封面加载失败",module:"artwork") }
                guard Self.isImage(result.body) else { throw AppFailure.make("封面接口返回的不是有效图片",module:"artwork") }
                try? await cache.write(result.body,key:url.absoluteString,kind:.artwork,epoch:epoch)
                return result.body
            }
            flights[url] = (id,task)
        }
        do { let data = try await task.value; if flights[url]?.0 == id { flights.removeValue(forKey:url) }; try Task.checkCancellation(); return data }
        catch { if flights[url]?.0 == id { flights.removeValue(forKey:url) }; throw error }
    }
}
