import Foundation

actor ArtworkLoader {
    private let cache: any ResourceCache
    private let http: any HTTPClient
    private var flights: [URL: (UUID, Task<Data, Error>)] = [:]
    init(cache: any ResourceCache, http: any HTTPClient) { self.cache = cache; self.http = http }
    func load(_ url: URL) async throws -> Data {
        if let data = try? await cache.read(key:url.absoluteString,kind:.artwork) { return data }
        let id: UUID, task: Task<Data,Error>
        if let existing = flights[url] { (id,task) = existing }
        else {
            id = UUID(); let epoch = await cache.epoch()
            // Other subscribers may have installed a flight while reading the cache epoch.
            if let existing = flights[url] { return try await existing.1.value }
            task = Task { [http,cache] in
                let result = try await http.execute(HTTPPayload(url:url,maximumBytes:8*1024*1024))
                guard (200..<300).contains(result.status) else { throw AppFailure.make("封面加载失败",module:"artwork") }
                try? await cache.write(result.body,key:url.absoluteString,kind:.artwork,epoch:epoch)
                return result.body
            }
            flights[url] = (id,task)
        }
        do { let data = try await task.value; if flights[url]?.0 == id { flights.removeValue(forKey:url) }; try Task.checkCancellation(); return data }
        catch { if flights[url]?.0 == id { flights.removeValue(forKey:url) }; throw error }
    }
}
