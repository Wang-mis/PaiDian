import Foundation
import AVFoundation

/// All paths, including file-cache hits and cache bypass, need the same time mapping.
enum PlaybackAsset {
    static func make(url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }
}

enum AudioSeekResult: Equatable, Sendable {
    case completed(positionMS: Int64)
    case failed
}

enum EngineEvent: Sendable {
    case buffered(UUID,[PlaybackTimeRange]), cacheUnavailable(UUID), cacheCompleted(UUID,UUID)
    case ready(UUID, Int64, Bool), position(UUID, Int64), playing(UUID), buffering(UUID), ended(UUID), failed(UUID, Bool)
}
@MainActor protocol AudioEngine: AnyObject {
    func clock() -> (positionMS:Int64,rate:Double)?
    func events() -> AsyncStream<EngineEvent>
    func load(_ url: URL, id: UUID)
    func load(_ url:URL,id:UUID,context:AudioCacheContext?,cachedID:UUID?)
    func play(); func pause(); func seek(toMS: Int64) async -> AudioSeekResult; func clear()
}
extension AudioEngine {
    func load(_ url:URL,id:UUID,context:AudioCacheContext?,cachedID:UUID?) { load(url,id:id) }
    func clock() -> (positionMS:Int64,rate:Double)? { nil } }
@MainActor final class AVAudioEngineAdapter: AudioEngine {
    private let player = AVPlayer()
    private let audioCache:AudioCacheStore?
    private var resource:AudioResourceLoader?
    private var loadTask:Task<Void,Never>?
    private var cacheLease:UUID?
    private var bufferObserver:NSKeyValueObservation?
    init(muted:Bool = false,audioCache:AudioCacheStore? = nil) { player.isMuted=muted;self.audioCache=audioCache }
    private var continuation: AsyncStream<EngineEvent>.Continuation?
    private var observer: NSKeyValueObservation?; private var timeControl: NSKeyValueObservation?; private var timeObserver: Any?; private var notifications: [NSObjectProtocol] = []
    private var itemID: UUID?
    private var seekID: UUID?
    func clock() -> (positionMS:Int64,rate:Double)? {
        guard itemID != nil,seekID == nil else { return nil }
        let seconds=player.currentTime().seconds
        guard seconds.isFinite else { return nil }
        return (Int64(max(0,seconds)*1000),Double(player.rate))
    }
    func events() -> AsyncStream<EngineEvent> { AsyncStream { continuation = $0 } }
    func load(_ url:URL,id:UUID) { load(url,id:id,context:nil,cachedID:nil) }
    func load(_ url:URL,id:UUID,context:AudioCacheContext?,cachedID:UUID?) {
        clear();itemID=id
        loadTask=Task { [weak self] in
            guard let self else { return }
            if let audioCache=self.audioCache,let cachedID {
                let lease=UUID();self.cacheLease=lease;try? await audioCache.pin(cachedID,lease:lease)
                guard self.itemID == id,!Task.isCancelled else { await audioCache.release(lease);return }
            }
            if let audioCache=self.audioCache,let context,!url.isFileURL,url.pathExtension.lowercased() != "m3u8" {
                let loader=AudioResourceLoader(store:audioCache,context:context);self.resource=loader
                loader.onFailure={ [weak self] expired in guard self?.itemID == id else { return };self?.continuation?.yield(.failed(id,expired)) }
                loader.onComplete={ [weak self] recordID in guard self?.itemID == id else { return };self?.continuation?.yield(.cacheCompleted(id,recordID)) }
                loader.onCacheUnavailable={ [weak self] in guard self?.itemID == id else { return };self?.continuation?.yield(.cacheUnavailable(id)) }
                do {
                    let asset=try await loader.prepare();guard self.itemID == id,!Task.isCancelled else { loader.stop();return }
                    self.install(AVPlayerItem(asset:asset),id:id)
                } catch {
                    guard self.itemID == id,!Task.isCancelled else { loader.stop();return }
                    loader.stop();self.resource=nil
                    // Cache/type/storage failure must leave ordinary online playback available.
                    if case CacheTransferFailure.http = error { return }
                    if error is URLError { return }
                    self.continuation?.yield(.cacheUnavailable(id))
                }
            } else { self.install(AVPlayerItem(asset:PlaybackAsset.make(url:url)),id:id) }
        }
    }
    private func install(_ item:AVPlayerItem,id:UUID) {
        guard itemID == id else { return }
        player.replaceCurrentItem(with:item)
        bufferObserver=item.observe(\.loadedTimeRanges,options:[.initial,.new]) { [weak self] item,_ in Task { @MainActor in
            guard let self,self.itemID == id else { return }
            let ranges=item.loadedTimeRanges.compactMap { value -> PlaybackTimeRange? in
                let range=value.timeRangeValue,start=range.start.seconds,end=CMTimeRangeGetEnd(range).seconds
                guard start.isFinite,end.isFinite,end > start else { return nil }
                return PlaybackTimeRange(startMS:Int64(max(0,start)*1000),endMS:Int64(max(0,end)*1000))
            }
            self.continuation?.yield(.buffered(id,ranges))
        } }
        observer = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in Task { @MainActor in
            guard let self, self.itemID == id else { return }
            switch item.status {
            case .readyToPlay:
                let duration = item.duration.seconds
                if duration.isFinite,duration > 0 { item.forwardPlaybackEndTime=item.duration }
                self.continuation?.yield(.ready(id, duration.isFinite ? Int64(max(0, duration) * 1000) : 0, !item.seekableTimeRanges.isEmpty || duration.isFinite))
            case .failed: self.continuation?.yield(.failed(id, Self.expired(item)))
            default: break
            }
        } }
        timeControl = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in Task { @MainActor in
            guard let self, self.itemID == id else { return }
            if player.timeControlStatus == .playing { self.continuation?.yield(.playing(id)) }
            else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { self.continuation?.yield(.buffering(id)) }
        } }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds:0.25,preferredTimescale:600),queue:.main) { [weak self] _ in
            Task { @MainActor in
                guard let self,self.itemID == id,self.seekID == nil else { return }
                // Read now, rather than publishing a time captured before an intervening seek.
                let seconds=self.player.currentTime().seconds
                if seconds.isFinite { self.continuation?.yield(.position(id,Int64(max(0,seconds)*1000))) }
            }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in self?.continuation?.yield(.ended(id)) } })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in Task { @MainActor in self?.continuation?.yield(.failed(id, Self.expired(item))) } })
    }
    private static func expired(_ item: AVPlayerItem) -> Bool { guard let status = item.errorLog()?.events.last?.errorStatusCode else { return false }; return [401,403,410].contains(status) }
    func play() { player.play() }
    func pause() { player.pause() }
    func seek(toMS: Int64) async -> AudioSeekResult {
        guard let item=player.currentItem, let mediaID=itemID else { return .failed }
        let token=UUID();seekID=token;item.cancelPendingSeeks()
        let finished = await withCheckedContinuation { continuation in
            player.seek(to:CMTime(value:max(0,toMS),timescale:1000),toleranceBefore:.zero,toleranceAfter:.zero) { finished in continuation.resume(returning:finished) }
        }
        guard itemID == mediaID,player.currentItem === item,seekID == token else { return .failed }
        seekID=nil
        let seconds=player.currentTime().seconds
        guard finished,seconds.isFinite,seconds >= 0,seconds < Double(Int64.max)/1000 else { return .failed }
        return .completed(positionMS:Int64(seconds*1000))
    }
    // Read-only diagnostics used by opt-in real-device validation.
    func isBuffered(atMS position: Int64) -> Bool {
        let time=CMTime(value:position,timescale:1000)
        return player.currentItem?.loadedTimeRanges.contains { CMTimeRangeContainsTime($0.timeRangeValue,time:time) } ?? false
    }
    func clear() {
        loadTask?.cancel();loadTask=nil;resource?.stop();resource=nil;bufferObserver=nil
        if let cacheLease,let audioCache { Task { await audioCache.release(cacheLease) } };cacheLease=nil
        player.pause(); player.currentItem?.cancelPendingSeeks(); seekID=nil; observer = nil; timeControl = nil; itemID = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll(); player.replaceCurrentItem(with: nil)
    }
}
