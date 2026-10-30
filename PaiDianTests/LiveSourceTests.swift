import XCTest
import AVFoundation
import UIKit
@testable import PaiDian

// Network validation is opt-in. Regular tests remain deterministic and offline.
@MainActor final class LiveSourceTests: XCTestCase {
    func testQDYOnDevice() async throws { try await verify(name:"QDY",key:"qdy",url:"https://raw.githubusercontent.com/pdone/lx-music-source/main/qdy/latest.js") }
    func testXinghaiOnDevice() async throws { try await verify(name:"星海",key:"xinghai",url:"https://zrcdy.dpdns.org/lx/xinghai-music-source.js") }
    func testXinghaiUnbufferedSeek() async throws { try await verify(name:"星海",key:"xinghai",url:"https://zrcdy.dpdns.org/lx/xinghai-music-source.js",testSeek:true) }
    func testQDYUnbufferedSeek() async throws { try await verify(name:"QDY",key:"qdy",url:"https://raw.githubusercontent.com/pdone/lx-music-source/main/qdy/latest.js",testSeek:true) }
    func testOrderedQualityAndLyricsOnDevice() async throws {
        guard ProcessInfo.processInfo.environment["PAIDIAN_LIVE_SOURCE_VALIDATION"] == "1" else { throw XCTSkip("需明确启用真实音源验证") }
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=idle }
        let http=URLSessionHTTPClient(),provider=PlatformCatalog(platform:.wy,http:http)
        let page=try await provider.search(query:"天龙八部之宿敌",page:1,pageSize:10)
        let track=try XCTUnwrap(page.tracks.first{$0.key.providerID == "167691"})
        let root=URL.cachesDirectory.appendingPathComponent("RangeLive-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let files=try DiskFileStore(root:root),store=MusicStore(modelContainer:try MusicStore.container(inMemory:true))
        try await store.prepare()
        let source=SourceManager(repository:store,files:files,http:http)
        var report=["网易云167691；源内降档，跨源重置；用户数据使用独立内存库，不写入。"]
        for key in ["sixyin","lx","flower","qdy","xinghai"] {
            let input=URL.cachesDirectory.appendingPathComponent("SourceValidation/"+key+".js")
            guard FileManager.default.fileExists(atPath:input.path) else { report.append(key+"：缺少设备脚本快照");continue }
            do {
                let script=try await source.importScript(SourceImport(url:input,retainOnInitializationFailure:true))
                report.append("导入："+script.name+"；初始化成功=\(script.initializationError == nil)")
            } catch { report.append(key+"：导入失败") }
        }
        let stream=await source.snapshots()
        let observer=Task { @MainActor in
            for await value in stream {
                if let name=value.resolvingSourceName,let quality=value.resolvingQuality {
                    let text="尝试："+name+" / "+quality.rawValue
                    if report.last != text { report.append(text) }
                }
            }
        }
        defer { observer.cancel() }
        let engine=AVAudioEngineAdapter(muted:true),player=PlaybackCoordinator(source:source,snapshots:store,history:store,engine:engine)
        defer { player.pause() }
        let entry=QueueEntry(track:track);await player.play(entries:[entry],startEntryID:entry.id)
        let deadline=Date().addingTimeInterval(180)
        while Date() < deadline,player.state.status != .failed,!(player.state.status == .playing && player.state.positionMS >= 500) { try await Task.sleep(for:.milliseconds(100)) }
        let advanced=player.state.status == .playing && player.state.positionMS >= 500
        report.append("结果：\(player.state.status.rawValue)；来源=\(player.state.resolvedSourceName ?? "无")；成功请求档位=\(player.state.resolvedQuality?.rawValue ?? "无")；实际时长=\(player.state.durationMS)ms；进度=\(player.state.positionMS)ms")
        if let failure=player.state.failure { report.append("失败："+failure.userMessage) }
        let providers=Dictionary(uniqueKeysWithValues:MusicPlatform.allCases.map{($0,PlatformCatalog(platform:$0,http:http) as any CatalogProvider)})
        let lyrics=LyricsService(providers:providers,cache:try DiskResourceCache(root:root.appendingPathComponent("lyrics")))
        do {
            let doc=try await lyrics.load(track)
            report.append("歌词来源=\(doc.origin?.sourceKey.encoded ?? "未知")；格式=\(doc.origin?.format.rawValue ?? "未知")；行数=\(doc.timedLines.count)")
            if advanced {
                let sync=LyricSynchronizer();defer { sync.stop() }
                if let line=doc.timedLines.first(where:{$0.startMS >= 60000}) {
                    await player.seekAndPlay(toMS:max(0,line.startMS-1200))
                    let ready=Date().addingTimeInterval(15)
                    while Date() < ready,player.state.status != .playing,player.state.status != .failed { try await Task.sleep(for:.milliseconds(10)) }
                    sync.configure(document:doc,offsetMS:0,active:true,clock:{player.playbackClock()})
                    let end=Date().addingTimeInterval(15)
                    while Date() < end,player.state.status != .failed {
                        if let index=sync.currentIndex,doc.timedLines[index].startMS >= line.startMS,let sample=player.playbackClock() {
                            report.append("真实歌词高亮：媒体时间=\(sample.positionMS)ms；歌词行=\(doc.timedLines[index].startMS)ms；相对提前边界误差=\(sample.positionMS-(line.startMS-60))ms；逐曲偏移=0ms")
                            break
                        }
                        try await Task.sleep(for:.milliseconds(10))
                    }
                }
            }
        } catch { report.append("真实歌词请求失败："+String(describing:type(of:error))) }
        let attachment=XCTAttachment(string:report.joined(separator:"\n"));attachment.name="ordered-quality-lyrics-live";attachment.lifetime = .keepAlways;add(attachment)
        XCTAssertTrue(advanced,"真实音源未播放，见独立附件，外部服务失败需要单独记录")
        XCTAssertEqual(player.state.queue.current?.track.key,track.key)
    }
    func testSongCacheAndOfflineResume() async throws {
        guard ProcessInfo.processInfo.environment["PAIDIAN_LIVE_SOURCE_VALIDATION"] == "1" else { throw XCTSkip("需明确启用真实音源验证") }
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true;defer { UIApplication.shared.isIdleTimerDisabled=idle }
        let root=URL.cachesDirectory.appendingPathComponent("LiveAudioCache-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let http=URLSessionHTTPClient(),page=try await PlatformCatalog(platform:.wy,http:http).search(query:"天龙八部之宿敌",page:1,pageSize:10)
        let track=try XCTUnwrap(page.tracks.first{$0.key.providerID == "167691"})
        let repo=MusicStore(modelContainer:try MusicStore.container(inMemory:true));try await repo.prepare()
        let files=try DiskFileStore(root:root),sources=SourceManager(repository:repo,files:files,http:http)
        let fixture=URL.cachesDirectory.appendingPathComponent("SourceValidation/qdy.js")
        _ = try await sources.importScript(SourceImport(url:fixture))
        let counted=CountingSourceResolver(base:sources),cacheRoot=root.appendingPathComponent("audio"),cache=AudioCacheStore(root:cacheRoot)
        let engine=AVAudioEngineAdapter(muted:true,audioCache:cache),player=PlaybackCoordinator(source:counted,snapshots:repo,history:repo,engine:engine,audioCache:cache)
        defer {player.pause()}
        let entry=QueueEntry(track:track);await player.play(entries:[entry],startEntryID:entry.id)
        var deadline=Date().addingTimeInterval(120)
        while Date() < deadline,player.state.status != .failed,!(player.state.status == .playing && player.state.positionMS > 500){try await Task.sleep(for:.milliseconds(100))}
        XCTAssertEqual(player.state.status,.playing,"真实缓存加载路径应成功播放：\(player.state.failure?.userMessage ?? "无详情")")
        deadline=Date().addingTimeInterval(180)
        var hit:CachedAudio?
        while Date() < deadline,player.state.status != .failed {
            hit=try await cache.complete(for:track.key,range:QualityRange());if hit != nil {break};try await Task.sleep(for:.milliseconds(200))
        }
        let cached=try XCTUnwrap(hit,"当前整首音频应完成缓存")
        let before=await counted.count
        await player.editQueue(.setMode(.singleRepeat));await player.seekAndPlay(toMS:player.state.durationMS-400)
        deadline=Date().addingTimeInterval(15)
        while Date() < deadline,!(player.state.status == .playing && player.state.positionMS < 1000){try await Task.sleep(for:.milliseconds(50))}
        XCTAssertLessThan(player.state.positionMS,1000)
        let after=await counted.count;XCTAssertEqual(after,before,"真实单曲循环不能重新取链")
        await player.editQueue(.clear)
        let fresh=AudioCacheStore(root:cacheRoot),offline=OfflineAudioResolver(),memory=MemoryRepository()
        try await memory.savePlayback(PlaybackSnapshot(queue:QueueState(entries:[entry],currentEntryID:entry.id),positionMS:60000,requestedQuality:cached.record.quality))
        let restored=PlaybackCoordinator(source:offline,snapshots:memory,history:memory,engine:AVAudioEngineAdapter(muted:true,audioCache:fresh),audioCache:fresh)
        defer {restored.pause()}
        await restored.restore();await restored.resume();deadline=Date().addingTimeInterval(15)
        while Date() < deadline,restored.state.status != .failed,!(restored.state.status == .playing && restored.state.positionMS > 60500){try await Task.sleep(for:.milliseconds(50))}
        let offlineCount=await offline.count;XCTAssertEqual(offlineCount,0);XCTAssertTrue(restored.state.isLocallyCached);XCTAssertGreaterThan(restored.state.positionMS,60500)
        let attachment=XCTAttachment(string:"网易云167691，QDY；请求档位=\(cached.record.quality.rawValue)；完整文件=\(cached.record.length) bytes；格式=\(cached.record.mimeType)；音频时长=\(restored.state.durationMS)ms；单曲循环解析次数=\(before)→\(after)；重建存储与播放器、拒绝全部音源请求后从60000ms续播至\(restored.state.positionMS)ms；离线取链次数=\(offlineCount)。不记录临时URL或音频内容。")
        attachment.name="live-audio-cache-offline";attachment.lifetime = .keepAlways;add(attachment)
        let restartFixture=URL.cachesDirectory.appendingPathComponent("AudioCacheRestartValidation")
        try? FileManager.default.removeItem(at:restartFixture);try FileManager.default.createDirectory(at:restartFixture,withIntermediateDirectories:true)
        try FileManager.default.copyItem(at:cacheRoot,to:restartFixture.appendingPathComponent("audio"))
        var minimal=track;minimal.metadata=PlatformMetadata()
        try JSONEncoder().encode(minimal).write(to:restartFixture.appendingPathComponent("track.json"),options:.atomic)
        try Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to:restartFixture.appendingPathComponent("origin-pid.txt"))
        await restored.editQueue(.clear)
    }
    func testPersistedSongCacheAfterProcessRestart() async throws {
        guard ProcessInfo.processInfo.environment["PAIDIAN_LIVE_SOURCE_VALIDATION"] == "1" else { throw XCTSkip("需明确启用真实缓存验证") }
        let root=URL.cachesDirectory.appendingPathComponent("AudioCacheRestartValidation")
        guard FileManager.default.fileExists(atPath:root.appendingPathComponent("track.json").path) else { throw XCTSkip("先执行真实歌曲缓存验证生成跨进程夹具") }
        defer {try? FileManager.default.removeItem(at:root)}
        let oldPID=try String(contentsOf:root.appendingPathComponent("origin-pid.txt"),encoding:.utf8)
        XCTAssertNotEqual(oldPID,String(ProcessInfo.processInfo.processIdentifier),"本测试必须在独立重启的宿主进程执行")
        let track=try JSONDecoder().decode(Track.self,from:Data(contentsOf:root.appendingPathComponent("track.json")))
        let cache=AudioCacheStore(root:root.appendingPathComponent("audio")),repo=MemoryRepository(),offline=OfflineAudioResolver(),entry=QueueEntry(track:track)
        try await repo.savePlayback(PlaybackSnapshot(queue:QueueState(entries:[entry],currentEntryID:entry.id),positionMS:60000,requestedQuality:.flac))
        let player=PlaybackCoordinator(source:offline,snapshots:repo,history:repo,engine:AVAudioEngineAdapter(muted:true,audioCache:cache),audioCache:cache)
        defer {player.pause()}
        await player.restore();await player.resume();let deadline=Date().addingTimeInterval(15)
        while Date() < deadline,player.state.status != .failed,!(player.state.status == .playing && player.state.positionMS > 60500) {try await Task.sleep(for:.milliseconds(50))}
        let count=await offline.count;XCTAssertEqual(count,0);XCTAssertTrue(player.state.isLocallyCached);XCTAssertGreaterThan(player.state.positionMS,60500)
        let attachment=XCTAttachment(string:"独立测试宿主进程重启：原PID=\(oldPID)，本次PID=\(ProcessInfo.processInfo.processIdentifier)；网易云167691从磁盘缓存60000ms续播至\(player.state.positionMS)ms；所有音源请求均拒绝，取链次数=\(count)。")
        attachment.name="audio-cache-process-restart";attachment.lifetime = .keepAlways;add(attachment)
        await player.editQueue(.clear)
    }
    private func verify(name:String,key:String,url:String,testSeek:Bool = false) async throws {
        guard ProcessInfo.processInfo.environment["PAIDIAN_LIVE_SOURCE_VALIDATION"] == "1" else { throw XCTSkip("需明确启用真实音源验证") }
        let wasIdleDisabled=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=wasIdleDisabled }
        let http = URLSessionHTTPClient()
        let provider = PlatformCatalog(platform:.wy,http:http)
        let page = try await provider.search(query:"天龙八部之宿敌",page:1,pageSize:10)
        let track = try XCTUnwrap(page.tracks.first { $0.key.providerID == "167691" })
        do {
            let fixture = URL.cachesDirectory.appendingPathComponent("SourceValidation/" + key + ".js")
            let data: Data
            if FileManager.default.fileExists(atPath:fixture.path) { data = try Data(contentsOf:fixture) }
            else { let response = try await http.execute(HTTPPayload(url:URL(string:url)!,maximumBytes:2*1024*1024)); XCTAssertEqual(response.status,200); data = response.body }
            XCTAssertNotNil(String(data:data,encoding:.utf8))
            let root=URL.cachesDirectory.appendingPathComponent("LiveSourceChain-"+UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let files=try DiskFileStore(root:root),store=MusicStore(modelContainer:try MusicStore.container(inMemory:true))
            try await store.prepare()
            let input=root.appendingPathComponent("input.js");try data.write(to:input)
            let imported=SourceManager(repository:store,files:files,http:http)
            let script=try await imported.importScript(SourceImport(url:input));try await imported.activate(scriptID:script.id)
            let restored=SourceManager(repository:store,files:files,http:http);await restored.restoreActive()
            let snapshots=await restored.snapshots();var iterator=snapshots.makeAsyncIterator();let latest=await iterator.next();let source=try XCTUnwrap(latest)
            XCTAssertEqual(source.activeScriptID,script.id);XCTAssertNil(source.failure)
            let engine=AVAudioEngineAdapter(muted:true),counted=CountingSourceResolver(base:restored)
            let player=PlaybackCoordinator(source:counted,snapshots:store,history:store,engine:engine)
            player.updateCapabilities(source.playbackCapabilities)
            let entry=QueueEntry(track:track);await player.play(entries:[entry],startEntryID:entry.id)
            let deadline=Date().addingTimeInterval(35)
            while Date() < deadline,player.state.status != .failed,!(player.state.status == .playing && player.state.positionMS >= 500) { try await Task.sleep(for:.milliseconds(200)) }
            let advanced=player.state.status == .playing && player.state.positionMS >= 500
            let duration=Double(player.state.durationMS)/1000
            if testSeek,advanced {
                let candidates:[Int64]=[180_000,210_000,240_000]
                guard let target=candidates.first(where:{ !engine.isBuffered(atMS:$0) }) else {
                    player.pause();throw XCTSkip("该次音频已全部缓冲，无法证明未缓冲跳转")
                }
                let before=await counted.count
                let seek=Task { await player.seekAndPlay(toMS:target) }
                let seekDeadline=Date().addingTimeInterval(35)
                while Date() < seekDeadline,player.state.status != .failed,!(player.state.status == .playing && player.state.positionMS >= target+250) { try await Task.sleep(for:.milliseconds(100)) }
                let reached=player.state.status == .playing && player.state.positionMS >= target+250
                let after=await counted.count
                player.pause();await player.editQueue(.clear);await seek.value
                XCTAssertTrue(reached,"未缓冲歌词跳转必须在目标位置继续播放")
                XCTAssertEqual(after,before,"正常跳转不能重新解析或切换音源")
                let attachment=XCTAttachment(string:"\(name) 未缓冲位置=\(target)ms；跳转后实际进度继续推进=\(reached)；解析次数=\(before)→\(after)；未记录临时音频地址")
                attachment.name="unbuffered-seek-"+name;attachment.lifetime = .keepAlways;add(attachment)
                return
            }
            player.pause()
            XCTAssertTrue(advanced,"\(name) 完整服务链路必须播放：\(player.state.failure?.userMessage ?? player.state.status.rawValue)")
            XCTAssertEqual(player.state.queue.current?.track.key,track.key)
            XCTAssertEqual(player.state.resolvedSourceName,script.name)
            XCTAssertTrue((250...280).contains(duration),"时长应与完整歌曲一致")
            let attachment=XCTAttachment(string:"\(name)：导入→启用→恢复→PlaybackCoordinator→AVAudioEngineAdapter；网易云167691；成功请求档位=\(player.state.resolvedQuality?.rawValue ?? "未知")；进度推进=\(advanced)；时长=\(duration)；SHA256=\(DataDigest.sha256(data))")
            attachment.name="live-source-\(name)";attachment.lifetime = .keepAlways;add(attachment)

        }
    }
}

private actor CountingSourceResolver: SourceResolving {
    let base: any SourceResolving
    private(set) var count=0
    init(base:any SourceResolving) { self.base=base }
    func resolve(_ track:Track,request:SourceResolutionRequest) async throws -> ResolvedStream {
        count+=1;return try await base.resolve(track,request:request)
    }
}

private actor OfflineAudioResolver:SourceResolving {
    private(set) var count=0
    func resolve(_ track:Track,request:SourceResolutionRequest) async throws -> ResolvedStream {count+=1;throw URLError(.notConnectedToInternet)}
}
