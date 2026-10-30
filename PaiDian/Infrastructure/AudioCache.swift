import Foundation

struct AudioByteRange:Codable,Equatable,Sendable {
    var start:Int64;var end:Int64 // half-open
    static func merged(_ input:[Self]) -> [Self] {
        var result:[Self]=[]
        for range in input.filter({$0.start >= 0 && $0.end > $0.start}).sorted(by:{$0.start < $1.start}) {
            if let last=result.last,last.end >= range.start { result[result.count-1].end=max(last.end,range.end) }
            else { result.append(range) }
        }
        return result
    }
}
struct AudioCacheRecord:Codable,Sendable,Identifiable {
    var id:UUID;var trackKey:TrackKey;var scriptID:UUID;var quality:AudioQuality;var sourceName:String?
    var urlDigest:String;var length:Int64=0;var mimeType:String="";var validator:String?;var ranges:[AudioByteRange]=[]
    var complete=false;var lastUsed=Date();var version=UUID()
    var storedBytes:Int64 { ranges.reduce(0){$0+$1.end-$1.start} }
    var fileExtension:String { switch mimeType.lowercased() { case "audio/flac","audio/x-flac": "flac";case "audio/mp4","audio/x-m4a": "m4a";case "audio/aac": "aac";case "audio/wav","audio/x-wav": "wav";default: "mp3" } }
}
struct CachedAudio:Sendable { var record:AudioCacheRecord;var url:URL }
protocol AudioCacheServing:Sendable {
    func complete(for key:TrackKey,range:QualityRange) async throws -> CachedAudio?
    func size() async throws -> Int64
    func setBudget(_ bytes:Int64) async throws
    func clear() async throws
}
/// Disk ownership stays in this actor. Index commits follow successful data writes.
actor AudioCacheStore:AudioCacheServing {
    private let root:URL
    private var records:[UUID:AudioCacheRecord]=[:]
    private var leases:[UUID:UUID]=[:]
    private var purgeOnRelease=Set<UUID>()
    private var budget:Int64=2*1024*1024*1024
    private var loaded=false
    init(root:URL) { self.root=root }
    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if let data=try? Data(contentsOf:root.appendingPathComponent("index.json")),let values=try? JSONDecoder().decode([AudioCacheRecord].self,from:data) {
            for record in values where record.length >= 0 && record.length <= 5*1024*1024*1024 {
                let ranges=AudioByteRange.merged(record.ranges)
                let size=(try? FileManager.default.attributesOfItem(atPath:file(record).path)[.size] as? NSNumber)?.int64Value ?? 0
                guard ranges.allSatisfy({$0.end <= record.length && $0.end <= size}) else { continue }
                var item=record;item.ranges=ranges;item.complete=record.length > 0 && ranges == [AudioByteRange(start:0,end:record.length)] && size == record.length
                records[item.id]=item
            }
        }
        // Files without an index entry are interrupted/stale writes, never valid cache hits.
        let valid=Set(records.values.map{file($0).lastPathComponent})
        for url in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) where url.lastPathComponent != "index.json" && !valid.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at:url) }
        loaded=true
    }
    private func file(_ record:AudioCacheRecord) -> URL { root.appendingPathComponent(record.id.uuidString+"."+record.fileExtension) }
    private func persist() throws { try JSONEncoder().encode(Array(records.values)).write(to:root.appendingPathComponent("index.json"),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication]) }
    func complete(for key:TrackKey,range:QualityRange) throws -> CachedAudio? {
        try load()
        for var record in records.values.filter({$0.trackKey == key && $0.complete && !purgeOnRelease.contains($0.id) && range.descending.contains($0.quality)}).sorted(by:{$0.quality.rank == $1.quality.rank ? $0.lastUsed > $1.lastUsed : $0.quality.rank > $1.quality.rank}) {
            let size=(try? FileManager.default.attributesOfItem(atPath:file(record).path)[.size] as? NSNumber)?.int64Value ?? -1
            guard size == record.length else { try? invalidate(record.id);continue }
            record.lastUsed=Date();records[record.id]=record;try? persist();return CachedAudio(record:record,url:file(record))
        }
        return nil
    }
    func open(track:Track,stream:ResolvedStream) throws -> AudioCacheRecord {
        try load();let digest=DataDigest.sha256(Data(stream.url.absoluteString.utf8))
        if let record=records.values.first(where:{$0.trackKey == track.key && !purgeOnRelease.contains($0.id) && $0.scriptID == stream.scriptID && $0.quality == stream.requestedQuality && $0.urlDigest == digest}) { return record }
        let record=AudioCacheRecord(id:UUID(),trackKey:track.key,scriptID:stream.scriptID,quality:stream.requestedQuality,sourceName:stream.sourceName,urlDigest:digest)
        records[record.id]=record;return record
    }
    func pin(_ id:UUID,lease:UUID) throws { try load();leases[lease]=id }
    func release(_ lease:UUID) {
        if let id=leases.removeValue(forKey:lease),purgeOnRelease.contains(id),!leases.values.contains(id) { purgeOnRelease.remove(id);try? invalidate(id) }
        try? trim()
    }
    func record(_ id:UUID) throws -> AudioCacheRecord { try load();guard let value=records[id] else { throw CacheTransferFailure.stale };return value }
    func configure(_ id:UUID,length:Int64,mime:String,validator:String?,reset:Bool) throws -> AudioCacheRecord {
        try load();guard var value=records[id],length > 0,length <= budget else { throw CacheTransferFailure.unsupported }
        if reset || value.length != length || value.mimeType != mime {
            try? FileManager.default.removeItem(at:file(value));value.version=UUID();value.ranges=[];value.complete=false
        }
        value.length=length;value.mimeType=mime;value.validator=validator
        records[id]=value;try persist();return value
    }
    func write(_ data:Data,id:UUID,version:UUID,offset:Int64) throws {
        guard var value=records[id],value.version == version,offset >= 0,offset <= value.length,Int64(data.count) <= value.length-offset else { throw CacheTransferFailure.stale }
        let url=file(value)
        if !FileManager.default.fileExists(atPath:url.path) { guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication]) else { throw CacheTransferFailure.disk } }
        let handle=try FileHandle(forWritingTo:url);defer { try? handle.close() }
        try handle.seek(toOffset:UInt64(offset));try handle.write(contentsOf:data);try handle.synchronize()
        value.ranges=AudioByteRange.merged(value.ranges+[AudioByteRange(start:offset,end:offset+Int64(data.count))]);value.lastUsed=Date()
        value.complete=value.ranges == [AudioByteRange(start:0,end:value.length)]
        records[id]=value;try persist();try trim()
    }
    func read(_ id:UUID,offset:Int64,count:Int) throws -> Data {
        let value=try record(id)
        guard let span=value.ranges.first(where:{$0.start <= offset && $0.end > offset}),count > 0 else { return Data() }
        let handle=try FileHandle(forReadingFrom:file(value));defer { try? handle.close() };try handle.seek(toOffset:UInt64(offset))
        return try handle.read(upToCount:min(count,Int(min(Int64(Int.max),span.end-offset)))) ?? Data()
    }
    func invalidate(_ id:UUID) throws { try load();if let value=records.removeValue(forKey:id) { try? FileManager.default.removeItem(at:file(value));try persist() } }
    func size() throws -> Int64 { try load();return records.values.reduce(0){$0+$1.storedBytes} }
    func setBudget(_ bytes:Int64) throws { try load();budget=max(1,bytes);try trim() }
    private func trim() throws {
        var total=records.values.reduce(0){$0+$1.storedBytes};let protected=Set(leases.values)
        for value in records.values.sorted(by:{$0.lastUsed < $1.lastUsed}) where total > budget && !protected.contains(value.id) {
            records.removeValue(forKey:value.id);try? FileManager.default.removeItem(at:file(value));total-=value.storedBytes
        }
        try persist()
    }
    func clear() throws {
        try load();let protected=Set(leases.values);purgeOnRelease.formUnion(protected)
        for value in Array(records.values) where !protected.contains(value.id) { records.removeValue(forKey:value.id);try? FileManager.default.removeItem(at:file(value)) }
        try persist()
    }
}
enum CacheTransferFailure:Error { case stale,disk,unsupported,invalidResponse,http(Int) }

/// Response bytes are consumed with back pressure; no whole-song Data allocation.
protocol AudioDownloading:Sendable {
    func transfer(_ request:URLRequest,response:@escaping @Sendable (HTTPURLResponse) async throws -> Void,data:@escaping @Sendable (Data) async throws -> Void) async throws
}
struct AudioHTTPDownloader:AudioDownloading {
    private let session:URLSession
    init() { let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=30;config.requestCachePolicy = .reloadIgnoringLocalCacheData;session=URLSession(configuration:config) }
    func transfer(_ request:URLRequest,response:@escaping @Sendable (HTTPURLResponse) async throws -> Void,data:@escaping @Sendable (Data) async throws -> Void) async throws {
        let (bytes,raw)=try await session.bytes(for:request)
        guard let header=raw as? HTTPURLResponse else { throw CacheTransferFailure.invalidResponse }
        try await response(header)
        var chunk=Data();chunk.reserveCapacity(65536)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 65536 { try Task.checkCancellation();try await data(chunk);chunk.removeAll(keepingCapacity:true) }
        }
        try Task.checkCancellation();if !chunk.isEmpty { try await data(chunk) }
    }
}
