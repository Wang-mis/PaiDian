import Foundation
#if !HOST_TESTS
@testable import PaiDian
#endif

@MainActor final class FakeAudioEngine: AudioEngine {
    var loaded: [(UUID, URL)] = []; var playCount = 0; var paused = false; var seeks: [Int64] = []
    var holdSeeks = false
    var seekLandingOffsetMS: Int64 = 0
    private var pendingSeeks: [Int:CheckedContinuation<AudioSeekResult,Never>] = [:]
    private var continuation: AsyncStream<EngineEvent>.Continuation?
    func events() -> AsyncStream<EngineEvent> { AsyncStream { continuation = $0 } }
    func emit(_ event: EngineEvent) { continuation?.yield(event) }
    func load(_ url: URL, id: UUID) { loaded.append((id,url)) }
    func play() { playCount += 1; paused = false }
    func pause() { paused = true }
    func seek(toMS: Int64) async -> AudioSeekResult {
        let index=seeks.count;seeks.append(toMS)
        if holdSeeks { return await withCheckedContinuation { pendingSeeks[index]=$0 } }
        return .completed(positionMS:toMS+seekLandingOffsetMS)
    }
    func completeSeek(_ index:Int,finished:Bool = true,positionMS:Int64? = nil) {
        pendingSeeks.removeValue(forKey:index)?.resume(returning:finished ? .completed(positionMS:positionMS ?? seeks[index]+seekLandingOffsetMS) : .failed)
    }
    func clear() { paused = true }
}
actor FakeResolver: SourceResolving {
    var requests: [String] = []; var failing: Set<String>; var delays: [String:Int]
    let generation = UUID(), scriptID = UUID()
    init(failing: Set<String> = [], delays: [String:Int] = [:]) { self.failing = failing; self.delays = delays }
    func resolve(_ track:Track,request:SourceResolutionRequest) async throws -> ResolvedStream {
        let quality=request.retrying?.quality ?? (request.range.descending.contains(.q128) ? .q128 : request.range.maximum)
        guard !request.excluding.contains(SourceQualityKey(scriptID:scriptID,quality:quality)) else { throw AppFailure.make("没有剩余音源",module:"source") }
        let id=track.key.providerID;requests.append(id)
        if let delay=delays[id] { try? await Task.sleep(for:.milliseconds(delay)) }
        if failing.contains(id) { throw AppFailure.make("测试解析失败",module:"source") }
        return ResolvedStream(url:URL(string:"https://example.test/\(id).mp3")!,requestedQuality:quality,scriptID:scriptID,sourceGeneration:generation)
    }
}
@MainActor enum PlaybackValidation {
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws { for _ in 0..<100 { if condition() { return }; try await Task.sleep(for:.milliseconds(5)) }; throw ValidationFailure(message:"等待播放器状态超时") }
    static func player(_ source: FakeResolver, _ engine: FakeAudioEngine, _ repository: MemoryRepository) -> PlaybackCoordinator { PlaybackCoordinator(source:source,snapshots:repository,history:repository,engine:engine) }
    static func run() async throws { try await seekActualLanding();print("PASS 跳转实际落点与快照"); try await staleResponse(); print("PASS 播放切歌竞态"); try await pauseDuringResolve(); print("PASS 解析期间暂停"); try await expiredOnce(); print("PASS 地址刷新上限"); try await failureBound(); print("PASS 自动播放失败上限"); try await historyAndRestore(); print("PASS 播放历史、快照与暂停恢复");try await mediaFallback();print("PASS 媒体失败回退与上限");try await mismatchedAudio();print("PASS 音频时长核对");try await seekWithoutReload();print("PASS 歌词跳转不重新解析");try await seekAcrossFallback();print("PASS 跳转目标跨音源回退");try await seekRefreshAndFailure();print("PASS 跳转刷新和失败重试");try await seekRaces();print("PASS 连续跳转、暂停与切歌隔离") }
    static func seekActualLanding() async throws {
        let source=FakeResolver(),engine=FakeAudioEngine(),repo=MemoryRepository(),player=player(source,engine,repo)
        let entry=QueueEntry(track:testTrack("landing"))
        await player.play(entries:[entry],startEntryID:entry.id)
        try await wait {engine.loaded.count == 1}
        let media=engine.loaded[0].0
        engine.emit(.ready(media,120_000,true));engine.emit(.playing(media))
        try await wait {player.state.status == .playing}
        engine.seekLandingOffsetMS = -37
        await player.seekAndPlay(toMS:90_000)
        try expect(player.state.positionMS == 89_963 && player.state.confirmedPositionMS == 89_963,"确认进度必须来自引擎实际落点，不可复制请求目标")
        player.pause();engine.seekLandingOffsetMS=22
        await player.seek(toMS:15_340)
        try expect(player.state.positionMS == 15_362 && player.state.confirmedPositionMS == 15_362 && !player.state.desiredPlaying,"暂停定位也必须采用实际落点并保持暂停")
        for _ in 0..<100 {
            if await repo.loadPlayback()?.positionMS == 15_362 {break}
            try await Task.sleep(for:.milliseconds(5))
        }
        let saved=await repo.loadPlayback()
        try expect(saved?.positionMS == 15_362,"快照必须保存实际落点")
        let requests=await source.requests
        try expect(requests.count == 1 && engine.loaded.count == 1,"位置校准不得重新解析或重载")
    }
    static func seekWithoutReload() async throws {
        let source=FakeResolver(),engine=FakeAudioEngine(),repo=MemoryRepository(),player=player(source,engine,repo)
        let entry=QueueEntry(track:testTrack("seek"));await player.play(entries:[entry],startEntryID:entry.id)
        try await wait { engine.loaded.count == 1 };let media=engine.loaded[0].0
        engine.emit(.ready(media,120_000,true));engine.emit(.playing(media));try await wait { player.state.status == .playing }
        await player.resume();try expect(engine.loaded.count == 1 && player.state.status == .playing,"正在播放时 resume 不得重新解析或重新加载")
        engine.holdSeeks=true;let initialPlays=engine.playCount
        let task=Task { await player.seekAndPlay(toMS:90_000) };try await wait { engine.seeks.count == 1 }
        engine.emit(.position(media,0));engine.emit(.buffering(media));try await Task.sleep(for:.milliseconds(10))
        await player.resume()
        try expect(player.state.positionMS == 90_000 && player.state.status == .buffering && engine.playCount == initialPlays,"未缓冲跳转应保持目标并等待，不能先从旧位置播放")
        let requests=await source.requests;try expect(requests.count == 1,"缓冲等待不得重新解析音源")
        engine.completeSeek(0);await task.value;engine.emit(.playing(media));engine.emit(.position(media,90_250));try await wait { player.state.positionMS == 90_250 }
        try expect(player.state.status == .playing && engine.loaded.count == 1,"跳转成功应复用媒体并从目标继续")
        player.pause();let pausedTask=Task { await player.seekAndPlay(toMS:30_000) };try await wait { engine.seeks.count == 2 }
        engine.completeSeek(1);await pausedTask.value;engine.emit(.playing(media));try await wait { player.state.status == .playing }
        try expect(player.state.desiredPlaying && engine.loaded.count == 1,"暂停时确认歌词应定位后播放，不重新取链")
        let history=await repo.recentTracks(limit:10);try expect(history.count == 1,"跳转和重复 resume 不能重复记录开始播放")
    }
    static func seekAcrossFallback() async throws {
        let source=MediaFallbackResolver(),engine=FakeAudioEngine(),repo=MemoryRepository()
        let player=PlaybackCoordinator(source:source,snapshots:repo,history:repo,engine:engine),entry=QueueEntry(track:testTrack("fallback-seek"))
        await player.play(entries:[entry],startEntryID:entry.id);try await wait { engine.loaded.count == 1 };let old=engine.loaded[0].0
        engine.emit(.ready(old,120_000,true));engine.emit(.playing(old));try await wait { player.state.status == .playing }
        engine.holdSeeks=true;let task=Task { await player.seekAndPlay(toMS:80_000) };try await wait { engine.seeks.count == 1 };let plays=engine.playCount
        engine.emit(.position(old,0));engine.emit(.failed(old,false));try await wait { engine.loaded.count == 2 }
        let fresh=engine.loaded[1].0;engine.completeSeek(0,finished:false);await task.value
        engine.emit(.position(fresh,0));engine.emit(.ready(fresh,120_000,true));engine.emit(.position(fresh,0));try await wait { engine.seeks.count == 2 }
        try expect(player.state.positionMS == 80_000 && engine.seeks == [80_000,80_000] && engine.playCount == plays,"回退后必须先定位，零回调和旧 seek 结果不能覆盖目标")
        engine.completeSeek(1);try await wait { engine.playCount == plays+1 };engine.emit(.playing(fresh));engine.emit(.position(fresh,80_250));try await wait { player.state.positionMS == 80_250 }
        try expect(player.state.queue.currentEntryID == entry.id && player.state.resolvedSourceName == "备用音源","回退应保留歌曲和队列身份")
    }
    static func seekRefreshAndFailure() async throws {
        let source=FakeResolver(),engine=FakeAudioEngine(),repo=MemoryRepository(),player=player(source,engine,repo),entry=QueueEntry(track:testTrack("refresh-seek"))
        await player.play(entries:[entry],startEntryID:entry.id);try await wait { engine.loaded.count == 1 };let old=engine.loaded[0].0
        engine.emit(.ready(old,120_000,true));engine.emit(.playing(old));try await wait { player.state.status == .playing }
        engine.holdSeeks=true;let task=Task { await player.seekAndPlay(toMS:75_000) };try await wait { engine.seeks.count == 1 }
        engine.emit(.failed(old,true));try await wait { engine.loaded.count == 2 };engine.completeSeek(0,finished:false);await task.value
        let fresh=engine.loaded[1].0;engine.emit(.position(fresh,0));engine.emit(.ready(fresh,120_000,true));try await wait { engine.seeks.count == 2 }
        try expect(engine.seeks.last == 75_000 && player.state.positionMS == 75_000,"地址刷新不得丢失跳转目标")
        engine.completeSeek(1,finished:false);try await wait { player.state.status == .failed }
        try expect(player.state.positionMS == 75_000 && player.state.failure?.userMessage.contains("目标位置") == true,"所有音源失败应保留目标并明确报错")
        await player.resume();try await wait { engine.loaded.count == 3 };let retry=engine.loaded[2].0
        engine.emit(.position(retry,0));engine.emit(.ready(retry,120_000,true));try await wait { engine.seeks.count == 3 }
        try expect(engine.seeks.last == 75_000 && player.state.positionMS == 75_000,"失败后重试应从目标继续")
        engine.completeSeek(2);try await wait { player.state.status == .buffering };player.pause()
    }
    static func seekRaces() async throws {
        let source=FakeResolver(),engine=FakeAudioEngine(),repo=MemoryRepository(),player=player(source,engine,repo)
        let entries=[QueueEntry(track:testTrack("a")),QueueEntry(track:testTrack("b"))]
        await player.play(entries:entries,startEntryID:entries[0].id);try await wait { engine.loaded.count == 1 };let old=engine.loaded[0].0
        engine.emit(.ready(old,120_000,true));engine.emit(.playing(old));try await wait { player.state.status == .playing };engine.holdSeeks=true
        let first=Task { await player.seekAndPlay(toMS:90_000) };try await wait { engine.seeks.count == 1 }
        let last=Task { await player.seekAndPlay(toMS:40_000) };try await wait { engine.seeks.count == 2 };let plays=engine.playCount
        engine.completeSeek(0);await first.value
        try expect(player.state.positionMS == 40_000 && engine.playCount == plays,"旧跳转完成不能覆盖最后一次请求")
        player.pause();engine.completeSeek(1);await last.value
        try expect(player.state.status == .paused && !player.state.desiredPlaying && player.state.positionMS == 40_000 && engine.playCount == plays,"等待时暂停不得被跳转完成恢复")
        let normal=Task { await player.seek(toMS:50_000) };try await wait { engine.seeks.count == 3 };engine.completeSeek(2);await normal.value
        try expect(!player.state.desiredPlaying && player.state.status == .paused,"普通进度条跳转必须保持暂停意图")
        let switching=Task { await player.seekAndPlay(toMS:60_000) };try await wait { engine.seeks.count == 4 };await player.next();try await wait { engine.loaded.count == 2 }
        engine.completeSeek(3);await switching.value;engine.emit(.position(old,60_000));engine.emit(.playing(old));try await Task.sleep(for:.milliseconds(10))
        try expect(player.state.queue.currentEntryID == entries[1].id && player.state.positionMS == 0,"切歌后旧跳转不能污染新歌")
        let fresh=engine.loaded[1].0;engine.emit(.ready(fresh,120_000,true));engine.emit(.playing(fresh));try await wait { player.state.status == .playing }
        let clearing=Task { await player.seekAndPlay(toMS:70_000) };try await wait { engine.seeks.count == 5 };await player.editQueue(.clear);engine.completeSeek(4);await clearing.value
        try expect(player.state.status == .idle && !player.state.desiredPlaying && player.state.positionMS == 0 && player.state.queue.current == nil,"清队列后旧跳转不得重新启动播放")
    }
    static func staleResponse() async throws {
        let source = FakeResolver(delays:["a":80]), engine = FakeAudioEngine(), repo = MemoryRepository(), player = player(source,engine,repo)
        let a = QueueEntry(track:testTrack("a")), b = QueueEntry(track:testTrack("b"))
        await player.play(entries:[a,b],startEntryID:a.id); try await Task.sleep(for:.milliseconds(10)); await player.next(); try await Task.sleep(for:.milliseconds(120))
        try expect(engine.loaded.count == 1 && engine.loaded.last?.1.lastPathComponent == "b.mp3","旧解析响应覆盖当前歌曲")
        engine.emit(.playing(UUID())); try await Task.sleep(for:.milliseconds(5)); try expect(player.state.status != .playing,"旧媒体回调未隔离")
    }
    static func pauseDuringResolve() async throws {
        let source = FakeResolver(delays:["a":30]), engine = FakeAudioEngine(), repo = MemoryRepository(), player = player(source,engine,repo), a = QueueEntry(track:testTrack("a"))
        await player.play(entries:[a],startEntryID:a.id); player.pause(); try await wait { !engine.loaded.isEmpty }
        engine.emit(.ready(engine.loaded.last!.0,120_000,true)); try await wait { player.state.status == .paused }; try expect(engine.playCount == 0,"解析结束后忽略了暂停意图")
    }
    static func expiredOnce() async throws {
        let source = FakeResolver(), engine = FakeAudioEngine(), repo = MemoryRepository(), player = player(source,engine,repo), a = QueueEntry(track:testTrack("a"))
        await player.play(entries:[a],startEntryID:a.id); try await wait { engine.loaded.count == 1 }; engine.emit(.failed(engine.loaded.last!.0,true)); try await wait { engine.loaded.count == 2 }; engine.emit(.failed(engine.loaded.last!.0,true)); try await wait { player.state.status == .failed }
        let requests = await source.requests; try expect(requests.count == 2 && !player.state.desiredPlaying,"过期地址刷新超过一次")
    }
    static func failureBound() async throws {
        let source = FakeResolver(failing:["b","c"]), engine = FakeAudioEngine(), repo = MemoryRepository(), player = player(source,engine,repo), entries = ["a","b","c"].map { QueueEntry(track:testTrack($0)) }
        await player.play(entries:entries,startEntryID:entries[0].id); try await wait { !engine.loaded.isEmpty }; let first = engine.loaded.last!.0
        engine.emit(.ready(first,120_000,true)); engine.emit(.playing(first)); try await wait { player.state.status == .playing }; engine.emit(.ended(first)); try await wait { !player.state.desiredPlaying }
        let requests = await source.requests; try expect(requests.count == 3,"失败跳过次数失控")
    }
    static func historyAndRestore() async throws {
        let source = FakeResolver(), engine = FakeAudioEngine(), repo = MemoryRepository(), player = player(source,engine,repo), a = QueueEntry(track:testTrack("a"))
        await player.play(entries:[a],startEntryID:a.id); try await wait { !engine.loaded.isEmpty }; let id = engine.loaded.last!.0
        engine.emit(.ready(id,120_000,true)); engine.emit(.playing(id)); engine.emit(.playing(id)); try await wait { player.state.status == .playing }; try await Task.sleep(for:.milliseconds(10))
        let rows = await repo.recentTracks(limit:10); try expect(rows.count == 1,"重复媒体回调导致历史重复")
        await player.seek(toMS:12_345); player.pause(); try await Task.sleep(for:.milliseconds(20))
        let restored = self.player(source,FakeAudioEngine(),repo); await restored.restore(); try expect(restored.state.positionMS == 12_345 && restored.state.status == .paused && !restored.state.desiredPlaying,"冷启动未恢复暂停进度")
    }
    static func mediaFallback() async throws {
        let resolver=MediaFallbackResolver(),engine=FakeAudioEngine(),repository=MemoryRepository()
        let player=PlaybackCoordinator(source:resolver,snapshots:repository,history:repository,engine:engine)
        let entry=QueueEntry(track:testTrack("same"));await player.play(entries:[entry],startEntryID:entry.id)
        try await wait { engine.loaded.count == 1 };engine.emit(.failed(engine.loaded.last!.0,false))
        try await wait { engine.loaded.count == 2 };engine.emit(.ready(engine.loaded.last!.0,120_000,true));engine.emit(.playing(engine.loaded.last!.0))
        try await wait { player.state.status == .playing }
        try expect(player.state.queue.current?.track.key == entry.track.key && player.state.resolvedSourceName == "备用音源","媒体失败回退应保留歌曲身份并标出实际音源")
        engine.emit(.failed(engine.loaded.last!.0,false));try await wait { player.state.status == .failed }
        let calls=await resolver.calls;try expect(calls == 2,"全部媒体失败后应停止，不得重复尝试同一音源")
    }
    static func mismatchedAudio() async throws {
        let resolver=MediaFallbackResolver(),engine=FakeAudioEngine(),repository=MemoryRepository()
        let player=PlaybackCoordinator(source:resolver,snapshots:repository,history:repository,engine:engine)
        var track=testTrack("same");track.durationMS=264_000;let entry=QueueEntry(track:track)
        await player.play(entries:[entry],startEntryID:entry.id);try await wait { engine.loaded.count == 1 }
        engine.emit(.ready(engine.loaded.last!.0,302_000,true));try await wait { engine.loaded.count == 2 }
        try expect(engine.playCount == 0,"时长明显不符的音频不应开始播放")
        engine.emit(.ready(engine.loaded.last!.0,263_366,true));engine.emit(.playing(engine.loaded.last!.0));try await wait { player.state.status == .playing }
        try expect(player.state.resolvedSourceName == "备用音源" && player.state.durationMS == 263_366,"时长不符应继续回退，保留歌曲身份")
    }
}
private actor MediaFallbackResolver:SourceResolving {
    let ids=[UUID(),UUID()];let generation=UUID();var calls=0
    func resolve(_ track:Track,request:SourceResolutionRequest) async throws -> ResolvedStream {
        let quality:AudioQuality = .q128
        guard let index=ids.firstIndex(where:{!request.excluding.contains(SourceQualityKey(scriptID:$0,quality:quality)) && (request.retrying == nil || request.retrying?.scriptID == $0)}) else { throw AppFailure.make("所有音源均失败",module:"source") }
        calls += 1;return ResolvedStream(url:URL(string:"https://example.test/\(index).mp3")!,requestedQuality:quality,scriptID:ids[index],sourceGeneration:generation,sourceName:index == 0 ? "主音源" : "备用音源")
    }
}
