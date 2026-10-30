import Foundation
#if !HOST_TESTS
@testable import PaiDian
#endif

@MainActor enum AudioCacheValidation {
    static func stream(_ name:String="one",quality:AudioQuality = .flac) -> ResolvedStream { ResolvedStream(url:URL(string:"https://audio.test/"+name+".mp3")!,requestedQuality:quality,scriptID:UUID(),sourceGeneration:UUID(),sourceName:"Test") }
    static func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("AudioCacheTest-"+UUID().uuidString) }
    static func write(_ store:AudioCacheStore,track:Track,stream:ResolvedStream,bytes:Data) async throws -> AudioCacheRecord {
        let value=try await store.open(track:track,stream:stream)
        let configured=try await store.configure(value.id,length:Int64(bytes.count),mime:"audio/mpeg",validator:"\"one\"",reset:true)
        try await store.write(bytes,id:configured.id,version:configured.version,offset:0);return configured
    }
    static func disk() async throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=AudioCacheStore(root:root),track=testTrack("disk"),resolved=stream()
        let value=try await store.open(track:track,stream:resolved)
        let r=try await store.configure(value.id,length:12,mime:"audio/mpeg",validator:"\"one\"",reset:true)
        try await store.write(Data([1,2,3,4]),id:r.id,version:r.version,offset:0)
        try await store.write(Data([9,10,11,12]),id:r.id,version:r.version,offset:8)
        try expect(try await store.complete(for:track.key,range:QualityRange()) == nil,"有空洞的文件不能命中完整缓存")
        try expect(try await store.read(r.id,offset:4,count:4).isEmpty,"空洞不能作为已缓存字节读取")
        let reopened=AudioCacheStore(root:root),partial=try await reopened.record(r.id)
        try expect(partial.ranges == [AudioByteRange(start:0,end:4),AudioByteRange(start:8,end:12)],"重启后部分缓存区间应保留")
        try await reopened.write(Data([5,6,7,8]),id:r.id,version:partial.version,offset:4)
        let hit=try await reopened.complete(for:track.key,range:QualityRange())
        try expect(hit != nil && (try Data(contentsOf:hit!.url)) == Data(1...12),"完整缓存内容应准确且可重开")
        let bounds=QualityRange(minimum:.q128,maximum:.q320)
        try expect(try await reopened.complete(for:track.key,range:bounds) == nil,"不能复用范围外的缓存")
        var other=resolved;other.url=URL(string:"https://audio.test/two.mp3")!
        let different=try await reopened.open(track:track,stream:other)
        try expect(different.id != r.id,"不同URL不能拼接部分缓存")
        let current=try await reopened.configure(r.id,length:12,mime:"audio/mpeg",validator:"\"two\"",reset:true)
        try expect(current.version != r.version && current.ranges.isEmpty,"资源变化必须丢弃原来的字节区间")
        do { try await reopened.write(Data([0]),id:r.id,version:r.version,offset:0);throw ValidationFailure(message:"迟到写入不应成功") } catch CacheTransferFailure.stale {}
    }
    static func capacity() async throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=AudioCacheStore(root:root);try await store.setBudget(12)
        let a=try await write(store,track:testTrack("a"),stream:stream(),bytes:Data(repeating:1,count:8))
        let lease=UUID();try await store.pin(a.id,lease:lease)
        _ = try await write(store,track:testTrack("b"),stream:stream(),bytes:Data(repeating:2,count:8))
        try expect(try await store.complete(for:testTrack("a").key,range:QualityRange()) != nil,"当前播放文件不能被容量淘汰")
        try expect(try await store.size() == 8,"超过上限必须淘汰未保护文件")
        try await store.clear();try expect(try await store.size() == 8,"清理不得删除正在读取的文件")
        try expect(try await store.complete(for:testTrack("a").key,range:QualityRange()) == nil,"待删除的播放文件不应成为新缓存命中")
        await store.release(lease);try expect(try await store.size() == 0,"播放释放后完成延迟清理")
        do { let record=try await store.open(track:testTrack("oversized"),stream:stream());_ = try await store.configure(record.id,length:13,mime:"audio/mpeg",validator:nil,reset:true);throw ValidationFailure(message:"超过容量的文件不应缓存") } catch CacheTransferFailure.unsupported {}
        let old=try JSONDecoder().decode(AppSettings.self,from:Data(#"{"appearance":"dark"}"#.utf8))
        try expect(old.audioCacheGB == 2 && old.appearance == .dark,"升级默认2GB且保留已有设置")
    }
    static func transfer() async throws {
        try expect(AudioResourceLoader.detectMime(Data("fLaC".utf8)) == "audio/flac","必须识别音源错误标记Content-Type的FLAC")

        for ignoresRange in [false,true] {
            let root=root();defer { try? FileManager.default.removeItem(at:root) }
            let store=AudioCacheStore(root:root),bytes=Data((0..<196608).map{UInt8($0%251)}),transport=AudioFixtureDownloader(bytes:bytes,ignoresRange:ignoresRange)
            let context=AudioCacheContext(track:testTrack("transfer"),stream:stream())
            let loader=AudioResourceLoader(store:store,context:context,downloader:transport)
            _ = try await loader.prepare()
            try await wait { (try? await store.complete(for:context.track.key,range:QualityRange())) != nil }
            let hit=try await store.complete(for:context.track.key,range:QualityRange())
            try expect(try Data(contentsOf:hit!.url) == bytes,"音频下载必须完整且无重复拼接")
            let calls=await transport.calls
            try expect(calls.count == (ignoresRange ? 1 : 2),"播放读取和整首缓存应共享下载，不应重复请求")
            loader.stop()
        }
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=AudioCacheStore(root:root),context=AudioCacheContext(track:testTrack("resume"),stream:stream()),bytes=Data(repeating:7,count:196608)
        let r=try await store.open(track:context.track,stream:context.stream)
        let configured=try await store.configure(r.id,length:196608,mime:"audio/mpeg",validator:"\"one\"",reset:true)
        try await store.write(bytes.prefix(131072),id:r.id,version:configured.version,offset:0)
        let transport=AudioFixtureDownloader(bytes:bytes),loader=AudioResourceLoader(store:store,context:context,downloader:transport)
        _ = try await loader.prepare();try await wait { (try? await store.complete(for:context.track.key,range:QualityRange())) != nil }
        try expect(await transport.calls == ["bytes=0-65535","bytes=131072-196607"],"重启先验证身份，再只下载缺失部分")
        loader.stop()
        let changedRoot=self.root();defer {try? FileManager.default.removeItem(at:changedRoot)}
        let changed=AudioCacheStore(root:changedRoot),old=try await changed.open(track:context.track,stream:context.stream)
        let oldVersion=try await changed.configure(old.id,length:196608,mime:"audio/mpeg",validator:"\"old\"",reset:true)
        try await changed.write(Data(repeating:2,count:131072),id:old.id,version:oldVersion.version,offset:0)
        let newer=AudioResourceLoader(store:changed,context:context,downloader:AudioFixtureDownloader(bytes:bytes))
        _ = try await newer.prepare();try await wait{(try? await changed.complete(for:context.track.key,range:QualityRange())) != nil}
        let refreshed=try await changed.complete(for:context.track.key,range:QualityRange())
        try expect(try Data(contentsOf:refreshed!.url) == bytes,"ETag改变后必须重下，不能混入旧字节")
        newer.stop()
    }
    static func failures() async throws {
        for status in [403,416] {
            let root=root();defer { try? FileManager.default.removeItem(at:root) }
            let store=AudioCacheStore(root:root),loader=AudioResourceLoader(store:store,context:AudioCacheContext(track:testTrack("error"),stream:stream()),downloader:AudioFixtureDownloader(bytes:Data(repeating:1,count:100),status:status))
            var expired:Bool?;loader.onFailure={expired=$0}
            do { _ = try await loader.prepare();throw ValidationFailure(message:"HTTP失败不能标记可播放缓存") } catch CacheTransferFailure.http {}
            try expect(expired == (status == 403),"鉴权过期应正确传回刷新策略")
            loader.stop()
        }
        for kind in ["invalidRange","truncated","disk"] {
            let root=root();defer{try? FileManager.default.removeItem(at:root)}
            let store=AudioCacheStore(root:root),context=AudioCacheContext(track:testTrack(kind),stream:stream())
            let downloader=AudioFixtureDownloader(bytes:Data(repeating:3,count:100000),badRange:kind == "invalidRange",truncated:kind == "truncated",diskRoot:kind == "disk" ? root : nil)
            let loader=AudioResourceLoader(store:store,context:context,downloader:downloader)
            var bypass=false;loader.onCacheUnavailable={bypass=true}
            do {
                _ = try await loader.prepare()
                try await wait{bypass}
                try expect(kind == "truncated","损坏响应或磁盘错误应阻止缓存准备")
            } catch is CacheTransferFailure {try expect(kind != "truncated","截断在首批字节后才应触发回退")}
            try expect((try? await store.complete(for:context.track.key,range:QualityRange())) == nil,"异常响应不能成为完整缓存")
            loader.stop()
        }
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=AudioCacheStore(root:root),transport=AudioFixtureDownloader(bytes:Data(repeating:8,count:196608),delay:true)
        let context=AudioCacheContext(track:testTrack("cancel"),stream:stream())
        let loader=AudioResourceLoader(store:store,context:context,downloader:transport)
        _ = try await loader.prepare();loader.stop();try await Task.sleep(for:.milliseconds(100))
        try expect(try await store.complete(for:context.track.key,range:QualityRange()) == nil,"切歌取消不能把不完整文件标记完整")
        let invalid=AudioCacheStore(root:root.appendingPathComponent("not-directory"));try Data([1]).write(to:root.appendingPathComponent("not-directory"))
        do { _ = try await invalid.open(track:testTrack("disk"),stream:stream());throw ValidationFailure(message:"磁盘错误必须可识别") } catch is CocoaError {}
    }
    static func playback() async throws {
        let root=root();defer { try? FileManager.default.removeItem(at:root) }
        let store=AudioCacheStore(root:root),track=testTrack("offline"),source=FakeResolver(),repo=MemoryRepository()
        _ = try await write(store,track:track,stream:stream(),bytes:Data(repeating:3,count:1024))
        let engine=FakeAudioEngine(),player=PlaybackCoordinator(source:source,snapshots:repo,history:repo,engine:engine,audioCache:store),entry=QueueEntry(track:track)
        await player.play(entries:[entry],startEntryID:entry.id);try await PlaybackValidation.wait{engine.loaded.count == 1}
        try expect(await source.requests.isEmpty && engine.loaded[0].1.isFileURL && player.state.isLocallyCached,"完整缓存必须在取链之前命中")
        let id=engine.loaded[0].0;engine.emit(.ready(id,120000,true));engine.emit(.playing(id));try await PlaybackValidation.wait{player.state.status == .playing}
        await player.editQueue(.setMode(.singleRepeat));engine.emit(.position(id,100000));engine.emit(.ended(id))
        try await PlaybackValidation.wait{engine.seeks == [0]}
        let loopRequests=await source.requests
        try expect(engine.loaded.count == 1 && loopRequests.isEmpty,"单曲循环不得清除媒体或重新尝试音源")
        engine.emit(.playing(id));engine.emit(.position(id,45000));try await PlaybackValidation.wait{player.state.positionMS == 45000}
        player.pause();player.persist();try await Task.sleep(for:.milliseconds(100))
        let freshEngine=FakeAudioEngine(),fresh=PlaybackCoordinator(source:source,snapshots:repo,history:repo,engine:freshEngine,audioCache:AudioCacheStore(root:root))
        await fresh.restore();try expect(fresh.state.confirmedPositionMS == 45000,"重启应恢复已确认进度")
        await fresh.resume();try await PlaybackValidation.wait{freshEngine.loaded.count == 1}
        freshEngine.emit(.ready(freshEngine.loaded[0].0,120000,true));try await PlaybackValidation.wait{freshEngine.seeks == [45000]}
        try expect((await source.requests).isEmpty,"缓存重启续播不得重新取链")
        await fresh.editQueue(.clear);await player.editQueue(.clear)
        let net=FakeResolver(),netEngine=FakeAudioEngine(),netPlayer=PlaybackCoordinator(source:net,snapshots:repo,history:repo,engine:netEngine)
        await netPlayer.play(entries:[entry],startEntryID:entry.id);try await PlaybackValidation.wait{netEngine.loaded.count == 1}
        let media=netEngine.loaded[0].0
        netEngine.emit(.ready(media,120000,true));netEngine.emit(.playing(media));netEngine.emit(.position(media,30000));try await PlaybackValidation.wait{netPlayer.state.confirmedPositionMS == 30000}
        netEngine.emit(.cacheUnavailable(media));try await PlaybackValidation.wait{netEngine.loaded.count == 2}
        netPlayer.pause();netEngine.emit(.ready(netEngine.loaded.last!.0,120000,true));try await PlaybackValidation.wait{netEngine.seeks == [30000]}
        try expect(await net.requests.count == 1 && !netPlayer.state.desiredPlaying,"缓存写入失败应复用原链接、保留进度及最新暂停意图")
        let second=netEngine.loaded.last!.0;netEngine.emit(.cacheCompleted(second,UUID()));netEngine.emit(.failed(second,false))
        try await PlaybackValidation.wait{netPlayer.state.status == .failed}
        try expect(netEngine.loaded.count == 2,"联网媒体失败不能因刚完成缓存而重复同一组合无限循环")
        await netPlayer.editQueue(.clear)
    }
    static func wait(_ condition:() async -> Bool) async throws { for _ in 0..<400 { if await condition(){return};try await Task.sleep(for:.milliseconds(10)) };throw ValidationFailure(message:"音频缓存测试超时") }
}
actor AudioFixtureDownloader:AudioDownloading {
    let bytes:Data,ignoresRange:Bool,status:Int?,delay:Bool,badRange:Bool,truncated:Bool,diskRoot:URL?
    private(set) var calls:[String]=[]
    init(bytes:Data,ignoresRange:Bool=false,status:Int?=nil,delay:Bool=false,badRange:Bool=false,truncated:Bool=false,diskRoot:URL?=nil) { self.bytes=bytes;self.ignoresRange=ignoresRange;self.status=status;self.delay=delay;self.badRange=badRange;self.truncated=truncated;self.diskRoot=diskRoot }
    func transfer(_ request:URLRequest,response:@escaping @Sendable (HTTPURLResponse) async throws -> Void,data:@escaping @Sendable (Data) async throws -> Void) async throws {
        let range=request.value(forHTTPHeaderField:"Range")!;calls.append(range)
        let numbers=range.replacingOccurrences(of:"bytes=",with:"").split(separator:"-").map{Int($0)!}
        let start=ignoresRange ? 0 : numbers[0],end=ignoresRange ? bytes.count : min(bytes.count,numbers[1]+1)
        var headers=["Content-Type":"audio/mpeg","Content-Length":String(end-start),"ETag":"\"one\""]
        if !ignoresRange { headers["Content-Range"]="bytes \(badRange ? start+1 : start)-\(end-1)/\(bytes.count)" }
        try await response(HTTPURLResponse(url:request.url!,statusCode:status ?? (ignoresRange ? 200 : 206),httpVersion:"HTTP/1.1",headerFields:headers)!)
        if delay { try await Task.sleep(for:.seconds(2)) }
        if let diskRoot { try FileManager.default.removeItem(at:diskRoot);try Data([1]).write(to:diskRoot) }
        let finish=truncated ? start+(end-start)/2 : end
        for offset in stride(from:start,to:finish,by:32768) { try Task.checkCancellation();try await data(bytes.subdata(in:offset..<min(finish,offset+32768))) }
    }
}
