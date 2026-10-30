import Foundation
import AVFoundation
import UniformTypeIdentifiers

struct AudioCacheContext:Sendable { var track:Track;var stream:ResolvedStream }
/// One resource, one bounded HTTP transfer at a time. Player reads share the download file.
@MainActor final class AudioResourceLoader:NSObject,AVAssetResourceLoaderDelegate {
    let store:AudioCacheStore
    let context:AudioCacheContext
    private let downloader:any AudioDownloading
    private let lease=UUID()
    private var record:AudioCacheRecord?
    private var task:Task<Void,Never>?
    private var startup:CheckedContinuation<AVURLAsset,Error>?
    private var pending:[AVAssetResourceLoadingRequest]=[]
    private var stopped=false,validated=false,pumping=false,exposed=false
    private var responseOffset:Int64=0,responseEnd:Int64=0
    private var declaredMime:String?
    var onComplete:((UUID)->Void)?
    private var announcedComplete=false
    var onFailure:((Bool)->Void)?
    var onCacheUnavailable:(()->Void)?
    init(store:AudioCacheStore,context:AudioCacheContext,downloader:any AudioDownloading=AudioHTTPDownloader()) { self.store=store;self.context=context;self.downloader=downloader }
    func prepare() async throws -> AVURLAsset {
        record=try await store.open(track:context.track,stream:context.stream)
        guard !stopped,let record else { throw CancellationError() }
        try await store.pin(record.id,lease:lease)
        return try await withCheckedThrowingContinuation { continuation in startup=continuation;task=Task { [weak self] in await self?.download() } }
    }
    private func expose() {
        guard let startup else { return };self.startup=nil;exposed=true
        let asset=PlaybackAsset.make(url:URL(string:"paidian-cache://audio/"+lease.uuidString)!)
        asset.resourceLoader.setDelegate(self,queue:.main);startup.resume(returning:asset)
    }
    nonisolated func resourceLoader(_ resourceLoader:AVAssetResourceLoader,shouldWaitForLoadingOfRequestedResource request:AVAssetResourceLoadingRequest) -> Bool {
        MainActor.assumeIsolated { guard !stopped else { return };pending.append(request);Task { await self.pump() } };return true
    }
    nonisolated func resourceLoader(_ resourceLoader:AVAssetResourceLoader,didCancel request:AVAssetResourceLoadingRequest) {
        MainActor.assumeIsolated { pending.removeAll{$0 === request} }
    }
    private func pump() async {
        guard !pumping,!stopped else { return };pumping=true;defer { pumping=false }
        guard let record else { return }
        for request in pending {
            if request.isCancelled || request.isFinished { continue }
            if let info=request.contentInformationRequest {
                info.contentLength=record.length;info.contentType=UTType(mimeType:record.mimeType)?.identifier ?? UTType.audio.identifier
                info.isByteRangeAccessSupported=true
            }
            guard let data=request.dataRequest else { request.finishLoading();continue }
            let end=data.requestsAllDataToEndOfResource ? record.length : min(record.length,data.requestedOffset+Int64(data.requestedLength))
            while data.currentOffset < end,!request.isCancelled,!request.isFinished,!stopped {
                let offset=data.currentOffset
                do {
                    let bytes=try await store.read(record.id,offset:offset,count:Int(min(65536,end-offset)))
                    guard !stopped,!request.isCancelled,!request.isFinished else { break }
                    if bytes.isEmpty { break };data.respond(with:bytes)
                } catch { request.finishLoading(with:error);break }
            }
            if !request.isCancelled,!request.isFinished,data.currentOffset >= end { request.finishLoading() }
        }
        pending.removeAll{$0.isCancelled || $0.isFinished}
    }
    private func missingOffset(_ value:AudioCacheRecord) -> Int64? {
        for request in pending where !request.isCancelled && !request.isFinished {
            guard let data=request.dataRequest else { continue }
            let current=data.currentOffset
            if current < value.length,!value.ranges.contains(where:{$0.start <= current && current < $0.end}) { return current }
        }
        var offset:Int64=0
        for span in value.ranges { if span.start > offset { break };offset=max(offset,span.end) }
        return offset < value.length ? offset : nil
    }
    private func download() async {
        do {
            while !stopped,let current=record {
                try Task.checkCancellation()
                if validated && current.complete { expose();announceCompletion(current);await pump();return }
                guard let offset=validated ? missingOffset(current) : 0 else { await pump();return }
                // Small initial probe gets the type/length quickly; subsequent blocks fill the whole song.
                let block:Int64=validated ? 4*1024*1024 : 65536
                let end=current.length > 0 ? min(current.length,offset+block) : offset+block
                var request=URLRequest(url:context.stream.url);request.timeoutInterval=30
                request.setValue("bytes=\(offset)-\(end-1)",forHTTPHeaderField:"Range")
                request.setValue("identity",forHTTPHeaderField:"Accept-Encoding")
                if validated || !current.ranges.isEmpty,let validator=current.validator { request.setValue(validator,forHTTPHeaderField:"If-Range") }
                try await downloader.transfer(request,response:{ [weak self] response in
                    guard let self else { throw CancellationError() };try await self.receive(response,offset:offset)
                },data:{ [weak self] bytes in
                    guard let self else { throw CancellationError() };try await self.receive(bytes)
                })
                guard responseOffset == responseEnd else { throw CacheTransferFailure.invalidResponse }
            }
        } catch {
            guard !stopped,!Task.isCancelled else { return }
            let isCache:Bool
            switch error {
            case CacheTransferFailure.http(let status): isCache=false;onFailure?([401,403,410].contains(status))
            case is URLError:isCache=false;onFailure?(false)
            default:isCache=true
            }
            if let startup { self.startup=nil;startup.resume(throwing:error) }
            else if isCache { onCacheUnavailable?() }
            else { for request in pending where !request.isFinished && !request.isCancelled { request.finishLoading(with:error) } }
            if isCache { for request in pending where !request.isFinished && !request.isCancelled { request.finishLoading(with:error) } }
        }
    }
    private func receive(_ response:HTTPURLResponse,offset:Int64) async throws {
        guard !stopped,let old=record else { throw CancellationError() }
        guard response.statusCode == 200 || response.statusCode == 206 else { throw CacheTransferFailure.http(response.statusCode) }
        let mime=(response.mimeType ?? "application/octet-stream").lowercased()
        guard !mime.contains("mpegurl"),!mime.contains("text"),!mime.contains("json"),!mime.contains("html") else { throw CacheTransferFailure.unsupported }
        let inferred:String
        if mime == "application/octet-stream" {
            switch context.stream.url.pathExtension.lowercased() { case "flac":inferred="audio/flac";case "m4a","mp4":inferred="audio/mp4";case "aac":inferred="audio/aac";case "wav":inferred="audio/wav";default:inferred=mime }
        } else { inferred=mime }
        let length:Int64,start:Int64,end:Int64
        if response.statusCode == 206 {
            let raw=response.value(forHTTPHeaderField:"Content-Range") ?? ""
            let parts=raw.replacingOccurrences(of:"bytes ",with:"").split(separator:"/")
            guard parts.count == 2,let total=Int64(parts[1]) else { throw CacheTransferFailure.invalidResponse }
            let bounds=parts[0].split(separator:"-")
            guard bounds.count == 2,let a=Int64(bounds[0]),let b=Int64(bounds[1]),a == offset,b >= a,b < total else { throw CacheTransferFailure.invalidResponse }
            length=total;start=a;end=b+1
        } else {
            length=response.expectedContentLength;start=0;end=length
        }
        guard length > 0,end <= length else { throw CacheTransferFailure.unsupported }
        let etag=response.value(forHTTPHeaderField:"ETag")
        let validator=(etag?.hasPrefix("W/") == false ? etag : nil) ?? response.value(forHTTPHeaderField:"Last-Modified")
        let same=old.length == length && old.validator != nil && old.validator == validator
        // Validate persisted bytes before exposing them. A later representation change needs a new AVPlayerItem.
        if validated,old.length != length || declaredMime != inferred || (old.validator != nil && old.validator != validator) { throw CacheTransferFailure.stale }
        record=try await store.configure(old.id,length:length,mime:same ? old.mimeType : inferred,validator:validator,reset:!validated && !same)
        declaredMime=inferred
        guard !stopped else { throw CancellationError() };responseOffset=start;responseEnd=end;validated=true;await pump()
    }
    private func receive(_ bytes:Data) async throws {
        guard !stopped,var current=record,responseOffset <= responseEnd,Int64(bytes.count) <= responseEnd-responseOffset else { throw CacheTransferFailure.invalidResponse }
        if !exposed,bytes.starts(with:Data("#EXTM3U".utf8)) { throw CacheTransferFailure.unsupported }
        // Several sources label FLAC as audio/mpeg. Supply the decoder with the actual container type.
        if responseOffset == 0,!exposed,let detected=Self.detectMime(bytes),detected != current.mimeType {
            current=try await store.configure(current.id,length:current.length,mime:detected,validator:current.validator,reset:true);record=current
        }
        do { try await store.write(bytes,id:current.id,version:current.version,offset:responseOffset) }
        catch { throw CacheTransferFailure.disk }
        guard !stopped else { throw CancellationError() }
        responseOffset+=Int64(bytes.count);record=try await store.record(current.id);expose();if let record,record.complete { announceCompletion(record) };await pump()
    }
    private func announceCompletion(_ record:AudioCacheRecord) {
        guard !announcedComplete else { return };announcedComplete=true;onComplete?(record.id)
    }
    static func detectMime(_ data:Data) -> String? {
        let bytes=Array(data.prefix(16))
        if bytes.starts(with:Array("fLaC".utf8)) { return "audio/flac" }
        if bytes.starts(with:Array("RIFF".utf8)),bytes.count >= 12,Array(bytes[8..<12]) == Array("WAVE".utf8) { return "audio/wav" }
        if bytes.count >= 8,Array(bytes[4..<8]) == Array("ftyp".utf8) { return "audio/mp4" }
        if bytes.starts(with:Array("ID3".utf8)) { return "audio/mpeg" }
        if bytes.count >= 2,bytes[0] == 255,bytes[1]&0xf6 == 0xf0 { return "audio/aac" }
        if bytes.count >= 2,bytes[0] == 255,bytes[1]&0xe0 == 0xe0 { return "audio/mpeg" }
        return nil
    }
    func stop() {
        guard !stopped else { return };stopped=true;task?.cancel();task=nil
        if let startup { self.startup=nil;startup.resume(throwing:CancellationError()) }
        for request in pending where !request.isCancelled && !request.isFinished { request.finishLoading(with:CancellationError()) };pending=[]
        Task { [store,lease] in await store.release(lease) }
    }
    isolated deinit { task?.cancel();let store=store,lease=lease;Task { await store.release(lease) } }
}
