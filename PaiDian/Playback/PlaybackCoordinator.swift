import Foundation
import AVFoundation

@MainActor final class PlaybackCoordinator: PlaybackControlling {
    private(set) var state = PlaybackViewState()
    private let source: any SourceResolving; private let snapshots: any PlaybackSnapshotRepository; private let history: any HistoryRepository; private let engine: any AudioEngine
    private let reducer: any QueueReducing; private let logger: any DiagnosticLogging
    private var random: any RandomNumberGenerator = SystemRandomNumberGenerator()
    private let broadcast = StateBroadcast<PlaybackViewState>()
    private var eventsTask: Task<Void, Never>?, resolveTask: Task<Void, Never>?, saveTask: Task<Void, Never>?, seekTask: Task<Void,Never>?
    private var requestID = UUID(), itemID: UUID?, seekID = UUID(), startedItemID: UUID?
    private var pendingTargetMS: Int64?
    private var readyItemID: UUID?
    private var failureIDs = Set<UUID>(), automaticallyAdvancing = false
    private var failedAttempts=Set<SourceQualityKey>(), refreshedAttempts=Set<SourceQualityKey>(), currentAttempt:SourceQualityKey?
    private var capabilities = SourceCapabilities(); private var sourceGeneration: UUID?
    private var lastSavedSecond: Int64 = -1
    private var defaultRange=QualityRange()
    private let audioCache:AudioCacheStore?
    private var currentCachedID:UUID?
    private var loadedFromCache=false
    private var currentStream:ResolvedStream?
    private(set) var intentRevision = UUID()
    var onStateChange: ((PlaybackViewState) -> Void)?
    init(source: any SourceResolving, snapshots: any PlaybackSnapshotRepository, history: any HistoryRepository, engine: any AudioEngine, reducer: any QueueReducing = QueueReducer(), logger: any DiagnosticLogging = DiagnosticLogger(),audioCache:AudioCacheStore? = nil) {
        self.audioCache=audioCache
        self.source = source; self.snapshots = snapshots; self.history = history; self.engine = engine; self.reducer = reducer; self.logger = logger
        let events = engine.events(); eventsTask = Task { [weak self] in for await event in events { guard !Task.isCancelled else { break }; await self?.handle(event) } }
    }
    func states() -> AsyncStream<PlaybackViewState> { broadcast.stream(initial: state) }
    func updateCapabilities(_ value: SourceCapabilities) { capabilities = value }
    func play(entries: [QueueEntry], startEntryID: UUID) async {
        intentRevision = UUID()
        state.desiredPlaying = true; failureIDs.removeAll(); automaticallyAdvancing = false
        await apply(.replace(entries, startEntryID))
    }
    func resume() async {
        intentRevision=UUID()
        guard state.queue.current != nil else { return }
        state.desiredPlaying=true
        if state.status == .resolving { publish();return }
        if let itemID {
            // A valid player item is reused, including while buffering or seeking.
            if readyItemID != itemID || pendingTargetMS != nil || state.status == .playing { publish();return }
            do { try configureSession();engine.play();state.status = .buffering;publish() } catch { await handleFailure(error) }
            return
        }
        failureIDs.removeAll();automaticallyAdvancing=false
        startCurrent(position:state.status == .ended ? 0 : resumePosition)
    }
    func pause() { intentRevision = UUID(); state.desiredPlaying = false; engine.pause(); if state.status != .resolving { state.status = state.queue.current == nil ? .idle : .paused }; publish(); persist() }
    func seek(toMS: Int64) async { await seek(toMS:toMS,playAfter:false) }
    func seekAndPlay(toMS: Int64) async { await seek(toMS:toMS,playAfter:true) }
    private var resumePosition: Int64 { pendingTargetMS ?? state.positionMS }
    private func seek(toMS: Int64,playAfter: Bool) async {
        guard state.canSeek,let item=itemID,readyItemID == item else { return }
        intentRevision=UUID();automaticallyAdvancing=false
        if playAfter { state.desiredPlaying=true }
        let position=min(max(0,toMS),max(0,state.durationMS))
        pendingTargetMS=position;state.positionMS=position;state.failure=nil
        let task=beginSeek(position:position,item:item)
        await task.value
    }
    @discardableResult private func beginSeek(position: Int64,item: UUID) -> Task<Void,Never> {
        seekTask?.cancel();let token=UUID();seekID=token
        pendingTargetMS=position;state.positionMS=position
        engine.pause();state.status=state.desiredPlaying ? .buffering : .paused
        publish();persist()
        let task=Task { [weak self,engine] in
            guard !Task.isCancelled else { return }
            let result=await engine.seek(toMS:position)
            guard !Task.isCancelled,let self,self.itemID == item,self.seekID == token else { return }
            guard case .completed(let actualPosition)=result,actualPosition >= 0 else {
                await self.recoverMedia(expired:false,seekFailure:true)
                return
            }
            self.pendingTargetMS=nil;self.seekTask=nil;self.state.positionMS=actualPosition;self.state.confirmedPositionMS=actualPosition
            if self.state.desiredPlaying {
                do { try self.configureSession();engine.play();self.state.status = .buffering }
                catch { await self.handleFailure(error);return }
            } else { self.state.status = .paused }
            self.publish();self.persist()
        }
        seekTask=task
        return task
    }
    func next() async { intentRevision = UUID(); failureIDs.removeAll(); automaticallyAdvancing = false; await apply(.advance(.next, .manual, [])) }
    func previous() async { intentRevision = UUID(); failureIDs.removeAll(); automaticallyAdvancing = false; await apply(.advance(.previous, .manual, [])) }
    func editQueue(_ command: QueueCommand) async {
        if case .select = command { intentRevision = UUID(); state.desiredPlaying = true; failureIDs.removeAll(); automaticallyAdvancing = false }
        if case .insertNext(let tracks) = command, state.queue.entries.isEmpty, !tracks.isEmpty { intentRevision = UUID(); state.desiredPlaying = true }
        if case .clear = command { intentRevision = UUID() }
        switch command { case .replace, .advance, .commitStarted: fail(AppFailure.make("不支持的队列操作", module: "playback")); return; default: break }
        await apply(command)
    }
    func setQualityRange(_ range:QualityRange) { defaultRange=QualityRange(minimum:range.minimum,maximum:range.maximum) }
    func updateResolutionProgress(_ quality:AudioQuality?) {
        guard state.status == .resolving,state.attemptedQuality != quality else { return }
        state.attemptedQuality=quality;publish()
    }
    func playbackClock() -> PlaybackClockSample? {
        guard let mediaID=itemID,readyItemID == mediaID,pendingTargetMS == nil,let key=state.queue.current?.track.key else { return nil }
        let sample=engine.clock()
        return PlaybackClockSample(mediaID:mediaID,trackKey:key,positionMS:sample?.positionMS ?? state.positionMS,rate:sample?.rate ?? 1,advancing:state.status == .playing && state.desiredPlaying)
    }
    func sourceDidChange(generation: UUID) async {
        guard sourceGeneration != generation else { return }; sourceGeneration = generation
        if state.status == .resolving { startCurrent(position: state.positionMS) }
    }
    func restore() async {
        do { guard let snapshot = try await snapshots.loadPlayback(), snapshot.schemaVersion == 1 else { return }; state.queue = QueueReducer().repaired(snapshot.queue); state.positionMS = max(0,snapshot.positionMS);state.confirmedPositionMS=state.positionMS; state.requestedQuality = defaultRange.maximum; state.qualityRange=defaultRange; state.durationMS = state.queue.current?.track.durationMS ?? 0; state.status = state.queue.current == nil ? .idle : .paused; state.desiredPlaying = false; publish() } catch { fail(error) }
    }
    private func apply(_ command: QueueCommand) async {
        do {
            let transition = try reducer.reduce(state.queue, command: command, random: &random); state.queue = transition.state
            switch transition.selection {
            case .stay: publish(); persist()
            case .select: startCurrent(position: 0)
            case .end:
                cancelLoad(); engine.clear(); itemID = nil; readyItemID=nil;pendingTargetMS=nil; state.canSeek = false; state.desiredPlaying = false; state.status = state.queue.entries.isEmpty ? .idle : .ended; state.positionMS = 0;state.confirmedPositionMS=0;state.bufferedRanges=[];state.isLocallyCached=false;currentCachedID=nil;currentStream=nil; publish(); persist()
            }
        } catch { fail(error) }
    }
    private func cancelLoad() { requestID = UUID(); seekID = UUID(); resolveTask?.cancel(); resolveTask = nil;seekTask?.cancel();seekTask=nil }
    private func startCurrent(position: Int64, refresh: Bool = false, sourceFallback:Bool = false) {
        guard let entry = state.queue.current else { return }; cancelLoad(); engine.clear(); itemID = nil; readyItemID=nil;startedItemID = nil
        pendingTargetMS=position > 0 ? position : nil
        let refreshAttempt=refresh ? currentAttempt : nil
        if !refresh && !sourceFallback { failedAttempts.removeAll();refreshedAttempts.removeAll();state.qualityRange=defaultRange }
        currentCachedID=nil;loadedFromCache=false;currentStream=nil;state.isLocallyCached=false;state.cacheWarning=nil;state.bufferedRanges=[]
        if position == 0 { state.confirmedPositionMS=0 }
        currentAttempt=nil;state.resolvedSourceName=nil;state.resolvedQuality=nil;state.attemptedQuality=nil
        state.status = .resolving; state.failure = nil; state.positionMS = position; state.durationMS = entry.track.durationMS ?? 0; state.canSeek = false
        state.requestedQuality=state.qualityRange.maximum
        let id=requestID,request=SourceResolutionRequest(range:state.qualityRange,excluding:failedAttempts,retrying:refreshAttempt)
        publish(); persist()
        resolveTask = Task { [weak self, source] in
            do {
                let cached=try? await self?.audioCache?.complete(for:entry.track.key,range:request.range)
                try Task.checkCancellation()
                let result:ResolvedStream
                if let cached {
                    result=ResolvedStream(url:cached.url,requestedQuality:cached.record.quality,scriptID:cached.record.scriptID,sourceGeneration:UUID(),sourceName:cached.record.sourceName)
                } else { result=try await source.resolve(entry.track,request:request) }
                try Task.checkCancellation()
                guard let self, self.requestID == id, self.state.queue.currentEntryID == entry.id else { return }
                self.failedAttempts.formUnion(result.failedAttempts)
                try self.configureSession()
                let mediaID = UUID(); self.itemID = mediaID;self.currentStream=result;self.currentCachedID=cached?.record.id;self.loadedFromCache=cached != nil;self.state.isLocallyCached=cached != nil; self.currentAttempt=result.attempt;self.state.resolvedSourceName=result.sourceName;self.state.resolvedQuality=result.requestedQuality;self.state.attemptedQuality=nil; self.state.status = .buffering; self.engine.load(result.url,id:mediaID,context:cached == nil ? AudioCacheContext(track:entry.track,stream:result) : nil,cachedID:cached?.record.id); self.publish()
            } catch {
                guard !Task.isCancelled,let self,self.requestID == id else { return }
                if let refreshAttempt { self.failedAttempts.insert(refreshAttempt);self.startCurrent(position:self.resumePosition,sourceFallback:true) }
                else { await self.handleFailure(error) }
            }
        }
    }
    private func handle(_ event: EngineEvent) async {
        switch event {
        case .cacheCompleted(let id,let recordID):
            guard itemID == id else { return };currentCachedID=recordID;state.isLocallyCached=true
            state.bufferedRanges=[PlaybackTimeRange(startMS:0,endMS:state.durationMS)];publish()
        case .buffered(let id,let ranges):
            guard itemID == id else { return }
            state.bufferedRanges=state.isLocallyCached ? [PlaybackTimeRange(startMS:0,endMS:state.durationMS)] : ranges;publish()
        case .cacheUnavailable(let id):
            guard itemID == id,let stream=currentStream else { return }
            let target=resumePosition;cancelLoad();engine.clear();readyItemID=nil
            let fresh=UUID();itemID=fresh;pendingTargetMS=target > 0 ? target : nil
            state.canSeek=false;state.bufferedRanges=[];state.isLocallyCached=false;loadedFromCache=false;state.cacheWarning="本次音频未能缓存，正在在线播放";state.status = .buffering
            engine.load(stream.url,id:fresh);publish()
        case .ready(let id, let duration, let seekable):
            guard itemID == id,readyItemID != id else { return }
            if let expected=state.queue.current?.track.durationMS,expected > 60_000,duration > 0,abs(duration-expected) > max(15_000,expected/10),let attempt=currentAttempt {
                if let currentCachedID { try? await audioCache?.invalidate(currentCachedID);guard itemID == id else { return } };if !loadedFromCache { failedAttempts.insert(attempt) };startCurrent(position:resumePosition,sourceFallback:true);return
            }
            readyItemID=id
            if duration > 0 { state.durationMS=duration };state.canSeek=seekable
            if state.isLocallyCached { state.bufferedRanges=[PlaybackTimeRange(startMS:0,endMS:state.durationMS)] }
            if let target=pendingTargetMS {
                guard seekable else { await recoverMedia(expired:false,seekFailure:true);return }
                beginSeek(position:min(max(0,target),max(0,state.durationMS)),item:id)
            } else {
                if state.desiredPlaying { engine.play() } else { state.status = .paused };publish()
            }
        case .position(let id, let position):
            guard itemID == id,readyItemID == id,pendingTargetMS == nil else { return }; state.positionMS = position;state.confirmedPositionMS=position; publish()
            let second = position / 5000; if second != lastSavedSecond { lastSavedSecond = second; persist() }
        case .playing(let id):
            guard itemID == id else { return }; guard state.desiredPlaying else { engine.pause(); return };guard readyItemID == id,pendingTargetMS == nil else { return }; state.status = .playing
            if startedItemID != id, let entry = state.queue.current {
                startedItemID = id; failureIDs.removeAll(); automaticallyAdvancing = false
                if let transition = try? reducer.reduce(state.queue, command: .commitStarted(entry.id), random: &random) { state.queue = transition.state }
                do { try await history.recordStarted(entry.track, at: Date()) } catch { await logger.record(AppFailure.wrap(error, module: "history")) }
            }; publish()
        case .buffering(let id): if itemID == id && state.desiredPlaying { state.status = .buffering; publish() }
        case .ended(let id):
            guard itemID == id,pendingTargetMS == nil,state.desiredPlaying else { return }
            if state.queue.mode == .singleRepeat,state.queue.priorityIDs.isEmpty {
                state.desiredPlaying=true;beginSeek(position:0,item:id);return
            }
            automaticallyAdvancing = true; state.desiredPlaying = true; await apply(.advance(.next, .natural, []))
        case .failed(let id, let expired):
            guard itemID == id else { return }
            await recoverMedia(expired:expired)
        }
    }
    private func recoverMedia(expired:Bool,seekFailure:Bool = false) async {
        let target=resumePosition
        if let currentCachedID {
            let expected=itemID;try? await audioCache?.invalidate(currentCachedID);guard itemID == expected else { return };self.currentCachedID=nil
            if loadedFromCache { startCurrent(position:target,sourceFallback:true);return }
        }
        if expired,let attempt=currentAttempt,!refreshedAttempts.contains(attempt) {
            refreshedAttempts.insert(attempt);startCurrent(position:target,refresh:true)
        } else if let attempt=currentAttempt,!failedAttempts.contains(attempt) {
            failedAttempts.insert(attempt);startCurrent(position:target,sourceFallback:true)
        } else {
            await handleFailure(AppFailure.make(seekFailure ? "音源无法跳转到目标位置，请重试或更换音源" : "当前歌曲无法播放",code:seekFailure ? "seekFailed" : "mediaUnavailable",module:"playback",retryable:true))
        }
    }
    private func handleFailure(_ error: Error) async {
        seekID=UUID();seekTask?.cancel();seekTask=nil;engine.clear(); itemID = nil;readyItemID=nil;state.canSeek=false
        if let target=pendingTargetMS { state.positionMS=target }
        if automaticallyAdvancing, let current = state.queue.currentEntryID {
            failureIDs.insert(current)
            if failureIDs.count < state.queue.entries.count { await apply(.advance(.next, .failure, failureIDs)); return }
        }
        state.desiredPlaying = false; state.status = .failed; state.failure = AppFailure.wrap(error, module: "playback")
        if pendingTargetMS != nil, var failure=state.failure { failure.userMessage="无法从目标位置继续播放：" + failure.userMessage;state.failure=failure }
        publish(); persist()
    }
    private func fail(_ error: Error) { state.failure = AppFailure.wrap(error, module: "playback"); publish() }
    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance(); try session.setCategory(.playback, mode: .default, options: []); try session.setActive(true)
        #endif
    }
    private func publish() { state.revision = UUID(); broadcast.send(state); onStateChange?(state) }
    func persist() {
        let snapshot = PlaybackSnapshot(queue: state.queue, positionMS: state.positionMS, requestedQuality: state.requestedQuality), previous = saveTask
        saveTask = Task { [snapshots, logger] in await previous?.value; do { try await snapshots.savePlayback(snapshot) } catch { await logger.record(AppFailure.wrap(error, module: "snapshot")) } }
    }
    deinit { eventsTask?.cancel(); resolveTask?.cancel();seekTask?.cancel() }
}
