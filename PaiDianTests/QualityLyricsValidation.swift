import Foundation
#if !HOST_TESTS
@testable import PaiDian
#endif

@MainActor enum QualityLyricsValidation {
    static func settings() async throws {
        let old=try JSONDecoder().decode(AppSettings.self,from:Data(#"{"appearance":"dark","defaultQuality":"128k","lyricFontSize":21}"#.utf8))
        try expect(old.qualityRange == QualityRange() && old.appearance == .dark && old.lyricFontSize == 21,"旧单档不能限制新的默认范围或清空其他设置")
        let invalid=try JSONDecoder().decode(QualityRange.self,from:Data(#"{"minimum":"flac24bit","maximum":"320k"}"#.utf8))
        try expect(invalid.minimum == .q320 && invalid.maximum == .flac24bit,"异常范围必须归一化")
        var settings=old;settings.qualityRange=QualityRange(minimum:.q320,maximum:.flac)
        let read=try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings))
        try expect(read == settings && read.qualityRange.descending == [.flac,.q320],"范围未持久化或未包含边界")
    }
    static func manager(http:QualityTraceHTTP) async throws -> (SourceManager,[SourceScript],URL) {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files=try DiskFileStore(root:root),repo=MemoryRepository(),manager=SourceManager(repository:repo,files:files,http:http)
        var scripts:[SourceScript]=[]
        for name in ["A","B"] {
            let text="""
            /**
             * @name \(name)
             */
            lx.on('request', ({info}) => new Promise((resolve,reject) => {
                lx.request('https://quality.test/\(name)/'+info.type,{},(error,response,body) => {
                    if(error || !body.url) reject(new Error('failed'));else resolve(body.url);
                });
            }));
            lx.send('inited',{sources:{kw:{type:'music',actions:['musicUrl'],qualitys:['128k','320k','flac','flac24bit']}}});
            """
            let file=root.appendingPathComponent(name+".js");try Data(text.utf8).write(to:file)
            scripts.append(try await manager.importScript(SourceImport(url:file)))
        }
        try await manager.setSourceOrder(scriptIDs:scripts.map(\.id))
        return (manager,scripts,root)
    }
    static func order() async throws {
        let http=QualityTraceHTTP(success:["A/320k"])
        let (manager,scripts,root)=try await manager(http:http);defer { try? FileManager.default.removeItem(at:root) }
        let track=testTrack("range") // Search advertises only 128k; it must not exclude higher source qualities.
        let result=try await manager.resolve(track,request:SourceResolutionRequest(range:QualityRange()))
        let calls=await http.calls
        try expect(calls == ["A/flac24bit","A/flac","A/320k"],"必须先耗尽同源高档位，成功后不得请求后续源")
        try expect(result.requestedQuality == .q320 && result.scriptID == scripts[0].id && result.failedAttempts.count == 2,"应返回成功组合和之前失败组合")
        await http.configure(success:["B/flac"])
        _ = try await manager.resolve(track,request:SourceResolutionRequest(range:QualityRange()))
        try expect(await http.calls == ["A/flac24bit","A/flac","A/320k","A/128k","B/flac24bit","B/flac"],"换源后必须从最高档重新开始")
        await http.configure(success:["B/flac"])
        _ = try await manager.resolve(track,request:SourceResolutionRequest(range:QualityRange(minimum:.q320,maximum:.flac)))
        try expect(await http.calls == ["A/flac","A/320k","B/flac"],"不得越过最低或最高边界")
        await http.configure(success:[])
        do { _ = try await manager.resolve(track,request:SourceResolutionRequest(range:QualityRange(minimum:.q128,maximum:.q128)));throw ValidationFailure(message:"全部失败应结束") }
        catch let error as AppFailure { try expect(error.code == "sourcesExhausted","耗尽应明确报错") }
        try expect(await http.calls == ["A/128k","B/128k"],"固定档位只能每源尝试一次")
        await http.configure(success:[])
        let retry=SourceQualityKey(scriptID:scripts[0].id,quality:.flac)
        do { _ = try await manager.resolve(track,request:SourceResolutionRequest(range:QualityRange(),retrying:retry));throw ValidationFailure(message:"刷新失败应返回") } catch is AppFailure {}
        try expect(await http.calls == ["A/flac"],"地址刷新只能刷新指定组合，不能抢先进入后续音源")
    }
    static func mediaRange() async throws {
        let http=QualityTraceHTTP(success:nil), (manager,_,root)=try await manager(http:http)
        defer { try? FileManager.default.removeItem(at:root) }
        let engine=FakeAudioEngine(),repo=MemoryRepository(),player=PlaybackCoordinator(source:manager,snapshots:repo,history:repo,engine:engine)
        let entries=[QueueEntry(track:testTrack("a")),QueueEntry(track:testTrack("b"))]
        await player.play(entries:entries,startEntryID:entries[0].id)
        try await PlaybackValidation.wait { engine.loaded.count == 1 }
        try expect(player.state.resolvedQuality == .flac24bit,"新一轮必须从最高档开始")
        player.setQualityRange(QualityRange(minimum:.q320,maximum:.q320))
        engine.emit(.failed(engine.loaded.last!.0,false));try await PlaybackValidation.wait { engine.loaded.count == 2 }
        try expect(player.state.resolvedQuality == .flac && player.state.resolvedSourceName == "A","媒体失败要在同源降档，设置修改不污染当前轮")
        engine.emit(.ready(engine.loaded.last!.0,302000,true));try await PlaybackValidation.wait { engine.loaded.count == 3 }
        try expect(player.state.resolvedQuality == .q320,"时长不符应继续同源下一档")
        let media=engine.loaded.last!.0
        engine.emit(.ready(media,120000,true));engine.emit(.playing(media));try await PlaybackValidation.wait { player.state.status == .playing }
        engine.holdSeeks=true
        let seeking=Task { await player.seekAndPlay(toMS:80000) };try await PlaybackValidation.wait { engine.seeks.count == 1 }
        engine.emit(.failed(media,false));try await PlaybackValidation.wait { engine.loaded.count == 4 }
        engine.completeSeek(0,finished:false);await seeking.value
        let fresh=engine.loaded.last!.0
        try expect(player.state.resolvedQuality == .q128 && player.state.positionMS == 80000,"降档不能丢失歌词跳转目标")
        player.pause();engine.emit(.ready(fresh,120000,true));try await PlaybackValidation.wait { engine.seeks.count == 2 }
        let count=engine.playCount;engine.completeSeek(1);try await PlaybackValidation.wait { player.state.status == .paused }
        try expect(engine.playCount == count && !player.state.desiredPlaying,"等待时暂停不能被降档恢复覆盖")
        engine.emit(.failed(fresh,false));try await PlaybackValidation.wait { engine.loaded.count == 5 }
        try expect(player.state.resolvedSourceName == "B" && player.state.resolvedQuality == .flac24bit,"同源耗尽后下一个源必须从原范围最高开始")
        await player.next();try await PlaybackValidation.wait { engine.loaded.count == 6 }
        try expect(player.state.resolvedSourceName == "A" && player.state.resolvedQuality == .q320 && player.state.qualityRange.minimum == .q320,"下一首应采用新范围")
        await player.editQueue(.clear)
    }
    static func codecs() async throws {
        let krc=try LyricDecoders.krc(krcVector),kw=try LyricDecoders.kuwo(Data(base64Encoded:kwVector)!,lyricx:true)
        let parser=LRCParser()
        let a=try parser.parse(LyricText.krc(krc)),b=try parser.parse(LyricText.kuwo(kw))
        try expect(a.timedLines.map(\.startMS) == [900,2400] && b.timedLines.map(\.startMS) == [900,2400],"KRC与Lyricx必须保留行起点并仅应用一次offset")
        let qrc=try LyricDecoders.qrc(qrcVector),q=try parser.parse(RawLyrics(original:LyricText.qrc(qrc),translation:nil))
        try expect(q.timedLines.map(\.startMS) == [1000,2500] && q.timedLines.map(\.text) == ["Alpha","Beta"],"QRC变体解码结果与官方向量不一致")
        let mrc=try LyricDecoders.mrc(mrcVector),m=try parser.parse(RawLyrics(original:LyricText.wordLines(mrc,wordPattern:#"\(\d+,\d+\)"#),translation:nil))
        try expect(m.timedLines.map(\.startMS) == [1000,2500] && m.timedLines.map(\.text) == ["Alpha","Beta"],"MRC签名64位计算或UTF16解码错误")
        let yrc=LyricText.yrc("[offset:100]\n{\"t\":0,\"c\":[{\"tx\":\"Credits\"}]}\n[1000,500](1000,500,0)Alpha\n[2500,500](2500,500,0)Beta")
        let y=try parser.parse(RawLyrics(original:yrc,translation:"[00:01.000]First\n[00:02.500]Second",format:.yrc))
        try expect(y.timedLines.map(\.startMS) == [0,900,2400],"YRC行起点或头部信息丢失")
        try expect(try parser.parse(RawLyrics(original:"[00:12:34]Fixed",translation:nil)).timedLines.first?.startMS == 12340,"特殊时间标签修复失败")
        try expectFailure { _ = try LyricDecoders.qrc("not-hex") }
        try expectFailure { _ = try LyricDecoders.krc("bad") }
        try expectFailure { _ = try LyricDecoders.kuwo(Data("bad".utf8),lyricx:true) }
    }
    static func fallback() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let cache=try DiskResourceCache(root:root),track=Track(key:TrackKey(platform:.wy,providerID:"origin"),title:"Alpha",artists:["Singer"],albumTitle:"Album",durationMS:120000)
        var wrong=track;wrong.key=TrackKey(platform:.kw,providerID:"wrong");wrong.durationMS=180000
        var correct=track;correct.key=TrackKey(platform:.kw,providerID:"correct")
        let fallback=LyricFixtureCatalog(platform:.kw,tracks:[wrong,correct])
        let service=LyricsService(providers:[.wy:LyricFixtureCatalog(platform:.wy,fail:true),.kw:fallback],cache:cache)
        let oldKey="lrc-v1-m1-"+track.key.encoded
        try await cache.write(JSONEncoder().encode(LyricDocument(timedLines:[LyricLine(startMS:90000,text:"Old")])),key:oldKey,kind:.lyrics,epoch:await cache.epoch())
        let result=try await service.load(track)
        try expect(result.origin?.requestedKey == track.key && result.origin?.sourceKey == correct.key,"歌词回退必须记录原身份与匹配来源")
        try expect(result.timedLines.first?.startMS == 1000,"不能命中旧版本缓存或选择时长不符的歌曲")
        let reopened=try await service.load(track)
        try expect(reopened.origin == result.origin,"新缓存没有保留来源")
        let cancel=Task { try await service.load(track) };cancel.cancel()
        do { _ = try await cancel.value;throw ValidationFailure(message:"取消的缓存读取不应成功") } catch is CancellationError {}
    }
    static func timing() async throws {
        let sync=LyricSynchronizer(),clock=FixtureClock(),document=LyricDocument(timedLines:[LyricLine(startMS:1000,text:"A"),LyricLine(startMS:2000,text:"B"),LyricLine(startMS:3000,text:"C")])
        clock.position=900
        sync.configure(document:document,offsetMS:0,active:true,clock:{clock.sample})
        try expect(sync.currentIndex == nil && sync.nextDelayMS == 40,"应按下一句调度，并提前60ms高亮")
        clock.position=1940;sync.synchronize()
        try expect(sync.currentIndex == 1,"调度晚到应读取真实进度并跨过已过的行")
        clock.advancing=false;sync.configure(document:document,offsetMS:0,active:true,clock:{clock.sample})
        try expect(sync.nextDelayMS == nil,"暂停和缓冲不能继续推进歌词时钟")
        clock.position=1440
        sync.configure(document:document,offsetMS:500,active:true,clock:{clock.sample})
        try expect(sync.currentIndex == 0,"用户延后与60ms补偿叠加错误")
        try expect(LyricTiming.seekTime(for:document.timedLines[0],offsetMS:500,durationMS:5000) == 1500,"高亮补偿不能改变选句跳转位置")
        sync.stop();clock.position=3000;sync.synchronize()
        try expect(sync.currentIndex == 0 && sync.nextDelayMS == nil,"隐藏后旧调度不能追赶")
        sync.configure(document:document,offsetMS:0,active:true,clock:{clock.sample})
        try expect(sync.currentIndex == 2,"返回前台应立即按实际位置恢复")
        sync.stop()
    }
    static func platformFixtures() async throws {
        let recorder=LyricHTTPRecorder(),http=LyricFixtureHTTP(krc:krcVector,kw:Data(base64Encoded:kwVector)!,qrc:qrcVector,mrc:mrcVector,recorder:recorder)
        for platform in MusicPlatform.allCases {
            var track=testTrack("123",platform:platform)
            track.metadata.payload["hash"] = .string("HASH")
            track.metadata.payload["songId"] = .string("123")
            let raw=try await PlatformCatalog(platform:platform,http:http).fetchLyrics(track)
            let doc=try LRCParser().parse(raw)
            let expected:LyricFormat
            switch platform { case .kw:expected = .lyricx;case .kg:expected = .krc;case .wy:expected = .yrc;case .tx:expected = .qrc;case .mg:expected = .mrc }
            try expect(raw.format == expected,"平台没有选择预期的完整歌词格式")
            let expectedStart:Int64 = platform == .kw || platform == .kg || platform == .wy ? 900 : 1000
            try expect(doc.timedLines.first?.startMS == expectedStart,"平台响应没有正确转换成统一时间轴")
            if platform == .wy { try expect(doc.timedLines.first?.translation == "First","YRC译文或嵌入offset未统一") }
        }
        let requests=await recorder.requests
        let kg=requests.first{$0.url.host == "lyrics.kugou.com" && $0.url.path == "/search"}!
        let time=URLComponents(url:kg.url,resolvingAgainstBaseURL:false)?.queryItems?.first{$0.name == "timelength"}?.value
        try expect(time == "120","酷狗应采用官方适配器的时长单位")
        let invalidYRC=LyricFixtureHTTP(krc:krcVector,kw:Data(base64Encoded:kwVector)!,qrc:qrcVector,mrc:mrcVector,recorder:recorder,invalidYRC:true)
        let raw=try await PlatformCatalog(platform:.wy,http:invalidYRC).fetchLyrics(testTrack("123",platform:.wy))
        try expect(raw.format == .lrc,"无效YRC必须回退到有效LRC")
    }
    // Fixed synthetic interoperability vectors, generated with the upstream algorithms.
    static let krcVector="a3JjMTjb6rkReV8JfIcDGf5ai+NG1WdN+HLSSsnkAJ29HkehCKPrQWx34zcbG3gpziE9Zsk="
    static let kwVector="dHA9Y29udGVudA0KDQp4nPNMz3dxzsj3ds/2Cw0LKzeICgnzCguzTA53dUsNDgs1CXXLcQk3yAkLrzRw8yiPjEyqMk0ODwtLDTYoCYxwy64Mzc7xCnWriAoNLk92DQy0BQA6Nxr6"
    static let qrcVector="ee7befb746f93831d42dcdf2e21f0d5dd9fd95a45509a6454e1d4966f9a90d4667380973756aca0eb04cad2dcdb92e62c9a276da77cab8fae197bbca934bb90cbcf40707ce51438f02534f846b55cabe"
    static let mrcVector="7b9e9d7e1012466a66e560ce88e9e4be0a844c7fd849bd92dfca77a9280ddc15288a3060fb468f77c02e88b81d46fd63a82cf020748593422c550d6d24dfde9a29b298f47f77c5314146fce96ace56a87233ba6468d647a9bd8bddfb941bcd43f92c472f5d047212"
}

actor QualityTraceHTTP:HTTPClient {
    var success:Set<String>?
    private(set) var calls:[String]=[]
    init(success:Set<String>?) { self.success=success }
    func configure(success:Set<String>?) { self.success=success;calls=[] }
    func execute(_ request:HTTPPayload) async throws -> HTTPResult {
        let path=request.url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"));calls.append(path)
        let ok=success?.contains(path) ?? true
        let body=try JSONSerialization.data(withJSONObject:ok ? ["url":"https://audio.test/"+path+".mp3"] : [:])
        return HTTPResult(status:200,headers:["content-type":"application/json"],body:body,finalURL:request.url)
    }
}
private struct LyricFixtureCatalog:CatalogProvider {
    var platform:MusicPlatform
    var fail=false
    var tracks:[Track]=[]
    func search(query:String,page:Int,pageSize:Int) async throws -> SearchPage { SearchPage(tracks:tracks,page:page,hasMore:false) }
    func fetchTrackDetail(_ track:Track) async throws -> Track { track }
    func fetchLyrics(_ track:Track) async throws -> RawLyrics { if fail { throw LyricDecoders.invalid() };return RawLyrics(original:"[00:01.000]Alpha",translation:nil) }
}
@MainActor private final class FixtureClock {
    var position:Int64=0,advancing=true
    let id=UUID(),key=TrackKey(platform:.wy,providerID:"clock")
    var sample:PlaybackClockSample { PlaybackClockSample(mediaID:id,trackKey:key,positionMS:position,rate:1,advancing:advancing) }
}

private actor LyricHTTPRecorder {
    var requests:[HTTPPayload]=[]
    func record(_ request:HTTPPayload) { requests.append(request) }
}
private struct LyricFixtureHTTP:HTTPClient {
    let krc:String,kw:Data,qrc:String,mrc:String
    let recorder:LyricHTTPRecorder
    var invalidYRC=false
    func execute(_ request:HTTPPayload) async throws -> HTTPResult {
        await recorder.record(request)
        let object:[String:Any]
        switch request.url.host ?? "" {
        case "mlyric.kuwo.cn":return HTTPResult(status:200,headers:[:],body:kw,finalURL:request.url)
        case "lyrics.kugou.com":
            object=request.url.path == "/search" ? ["candidates":[["id":"1","accesskey":"test","krctype":1,"contenttype":0]]] : ["fmt":"krc","content":krc]
        case "interface3.music.163.com":
            object=["code":200,"lrc":["lyric":"[00:01.000]Fallback"],"yrc":["lyric":invalidYRC ? "bad" : "[offset:100]\n[1000,500](1000,500,0)Alpha"],"ytlrc":["lyric":"[00:01.000]First"]]
        case "u.y.qq.com":object=["code":0,"req":["code":0,"data":["lyric":qrc,"trans":"","roma":""]]]
        case "c.musicapp.migu.cn":object=["code":"000000","resource":[["songId":"123","mrcUrl":"https://fixture.test/mrc","trcUrl":"https://fixture.test/trc"]]]
        case "fixture.test":return HTTPResult(status:200,headers:[:],body:Data((request.url.path == "/mrc" ? mrc : "[00:01.000]First").utf8),finalURL:request.url)
        default:throw LyricDecoders.invalid()
        }
        return HTTPResult(status:200,headers:["content-type":"application/json"],body:try JSONSerialization.data(withJSONObject:object),finalURL:request.url)
    }
}
