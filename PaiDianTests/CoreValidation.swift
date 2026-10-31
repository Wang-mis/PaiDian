import Foundation
import SwiftData
#if !HOST_TESTS
@testable import PaiDian
#endif

@MainActor enum CoreValidation {
    static let cases: [(String, @MainActor () async throws -> Void)] = [
        ("封面补查、去重、缓存与失效恢复", ArtworkValidation.run),
        ("内置音源安装、升级隔离与中断恢复", BundledSourceValidation.run),
        ("音频缓存持久化",AudioCacheValidation.disk),("音频缓存容量与清理",AudioCacheValidation.capacity),("音频缓存分段与完整下载",AudioCacheValidation.transfer),("音频缓存错误与取消",AudioCacheValidation.failures),("缓存播放、循环与重启",AudioCacheValidation.playback),
        ("音质范围设置与迁移", QualityLyricsValidation.settings), ("同源音质降级顺序", QualityLyricsValidation.order), ("媒体失败同源降级", QualityLyricsValidation.mediaRange), ("五类歌词解码", QualityLyricsValidation.codecs), ("五平台歌词固定响应", QualityLyricsValidation.platformFixtures), ("歌词回退和缓存隔离", QualityLyricsValidation.fallback), ("精确歌词调度", QualityLyricsValidation.timing), ("领域身份与快照", domain), ("四种播放模式边界", modes), ("随机历史与前进", shuffle), ("下一首 FIFO 与恢复", priorities), ("LRC、译文与 offset", lyrics), ("逐曲歌词偏移、浏览与设置兼容", lyricPresentation), ("AES 与 MD5 向量", crypto), ("五个平台字段映射", catalog), ("本地文件与缓存", files), ("SwiftData 歌单事务", storage), ("SwiftData 历史和快照", persistence), ("磁盘存储重开", diskReopen), ("脚本初始化与取链", runtime), ("跨端兼容隔离", compatibility), ("脚本 HTTP 和编码桥接", scriptHTTP), ("上游空地址归因与回退", upstreamFailure), ("脚本异常与取消", scriptErrors), ("音源替换失败回滚", sourceLifecycle), ("音源回退顺序与耗尽", sourceFallbacks), ("音源排序持久化与失败回滚", sourceOrderingPersistence), ("保留导入失败状态", retainedSourceFailure), ("搜索分页、部分失败与竞态", search)
    ]
    static func run() async throws { for (name, test) in cases { try await test(); print("PASS \(name)") }; print("PASS \(cases.count) 组核心验证") }
    static func domain() async throws {
        let key = TrackKey(platform:.kw,providerID:"a:b/中文\"9007199254740999")
        try expect(try TrackKey(encoded:key.encoded) == key,"TrackKey 往返失败")
        try expect(Set((0..<100).map { _ in key.encoded }).count == 1,"歌曲持久身份编码必须稳定")
        try expect(key != TrackKey(platform:.wy,providerID:key.providerID),"平台身份冲突")
        let entries = [QueueEntry(track:testTrack("1")),QueueEntry(track:testTrack("1"))]
        try expect(entries[0].id != entries[1].id,"重复歌曲应有独立队列身份")
        let snapshot = PlaybackSnapshot(queue:QueueState(entries:entries,currentEntryID:entries[0].id),positionMS:1234,requestedQuality:.q320)
        let data = try JSONEncoder().encode(snapshot), read = try JSONDecoder().decode(PlaybackSnapshot.self,from:data)
        try expect(read.queue == snapshot.queue && read.positionMS == 1234,"快照往返失败")
        try expect(!String(decoding:data,as:UTF8.self).contains("sourceGeneration"),"快照不应保存临时解析状态")
    }
    static func transition(_ state: QueueState, _ command: QueueCommand) throws -> QueueTransition { var random: any RandomNumberGenerator = SeededRandom(); return try QueueReducer().reduce(state,command:command,random:&random) }
    static func modes() async throws {
        for mode in PlaybackMode.allCases {
            let empty = try transition(QueueState(mode:mode),.advance(.next,.natural,[])); try expect(empty.state.entries.isEmpty,"空队列错误")
            let a = QueueEntry(track:testTrack("1")), b = QueueEntry(track:testTrack("2")), s = QueueState(entries:[a,b],currentEntryID:b.id,mode:mode)
            let t = try transition(s,.advance(.next,.natural,[]))
            switch mode { case .sequential: try expect(t.selection == .end,"顺序末尾应停止"); case .listRepeat: try expect(t.state.currentEntryID == a.id,"列表循环应回首曲"); case .singleRepeat: try expect(t.state.currentEntryID == b.id,"单曲自然结束应重播"); case .shuffle: try expect(t.state.currentEntryID == a.id,"随机新轮应避开上一末曲") }
            let failed = try transition(s,.advance(.next,.failure,[a.id,b.id])); try expect(failed.selection == .end,"全部失败必须终止")
            let single = QueueState(entries:[a],currentEntryID:a.id,mode:mode), next = try transition(single,.advance(.next,.manual,[])); try expect(next.selection != .end,"手动边界应保留当前项")
        }
    }
    static func shuffle() async throws {
        let entries = (1...5).map { QueueEntry(track:testTrack("\($0)")) }; var s = QueueState(entries:entries,currentEntryID:entries[0].id)
        s = try transition(s,.setMode(.shuffle)).state; s = try transition(s,.commitStarted(entries[0].id)).state
        var played = [entries[0].id]
        for _ in 1..<5 { s = try transition(s,.advance(.next,.natural,[])).state; played.append(s.currentEntryID!); s = try transition(s,.commitStarted(s.currentEntryID!)).state }
        try expect(Set(played).count == 5,"随机一轮存在重复")
        s = try transition(s,.advance(.previous,.manual,[])).state; try expect(s.currentEntryID == played[3],"随机上一首不按历史")
        s = try transition(s,.commitStarted(s.currentEntryID!)).state; s = try transition(s,.advance(.next,.manual,[])).state; try expect(s.currentEntryID == played[4],"随机前进应返回实际历史")
        s = try transition(s,.commitStarted(s.currentEntryID!)).state; try expect(s.historyIDs.count == 5,"历史返回不应重复追加")
    }
    static func priorities() async throws {
        let first = try transition(QueueState(),.insertNext([testTrack("empty-first")]))
        try expect(first.state.current != nil && first.selection != .stay,"空队列下一首播放应建立当前条目")
        let a = QueueEntry(track:testTrack("a")), b = QueueEntry(track:testTrack("b")); var s = QueueState(entries:[a,b],currentEntryID:a.id,mode:.singleRepeat)
        s = try transition(s,.insertNext([testTrack("x")])).state; s = try transition(s,.insertNext([testTrack("y")])).state
        s = try transition(s,.advance(.next,.natural,[])).state; try expect(s.current?.track.key.providerID == "x","优先项应覆盖单曲循环")
        s = try transition(s,.advance(.next,.manual,[])).state; try expect(s.current?.track.key.providerID == "y","下一首须 FIFO")
        s = try transition(s,.remove([s.currentEntryID!])).state; try expect(s.current?.id == b.id,"移除当前项应选择后继")
        try expectFailure { _ = try transition(s,.move([a.id,a.id])) }
        let orphan = UUID(), broken = QueueState(entries:[a],currentEntryID:orphan,mode:.shuffle,priorityIDs:[orphan],shuffleRemaining:[orphan,a.id],historyIDs:[orphan,a.id],historyCursor:1)
        let fixed = QueueReducer().repaired(broken); try expect(fixed.currentEntryID == a.id && fixed.priorityIDs.isEmpty && fixed.historyIDs == [a.id] && fixed.historyCursor == 0,"恢复未清理无效引用")
    }
    static func lyrics() async throws {
        let parser = LRCParser(), raw = RawLyrics(original:"[ar:测试]\n[offset:500]\n[00:01.5][00:03.050]你好\n[00:03.050]世界\n[100:00]长歌",translation:"[offset:500]\n[00:01.500]Hello"), d = try parser.parse(raw)
        try expect(d.timedLines.map(\.startMS) == [1000,2550,5_999_500],"时间或 offset 错误")
        try expect(d.timedLines[1].text == "你好\n世界" && d.timedLines[0].translation == "Hello","合并或翻译失败")
        try expect(parser.lineIndex(in:d,positionMS:999) == nil && parser.lineIndex(in:d,positionMS:3000) == 1,"歌词定位错误")
        try expect(try parser.parse(RawLyrics(original:"无时间歌词",translation:nil)).plainText == "无时间歌词","纯文本回退失败")
        try expect(try parser.parse(RawLyrics(original:"[00:88]错误",translation:nil)).timedLines.isEmpty,"非法时间应忽略")
    }
    static func lyricPresentation() async throws {
        let old = Data(#"{"appearance":"dark","defaultQuality":"320k"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self,from:old)
        try expect(settings.appearance == .dark && settings.qualityRange == QualityRange() && settings.lyricFontSize == 17 && settings.lyricLineSpacing == 14 && settings.lyricCurrentLineScale == 1.08,"升级应保留外观并使用新的默认音质范围")
        var preference = settings; preference.preferredSearchPlatform = .wy; preference.lyricCurrentLineScale=1.15
        let read = try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(preference))
        try expect(read == preference,"新增设置未保存")
        try expect(read.searchSelection(explicit:nil,available:[.wy]) == .platform(.wy),"未恢复上次平台")
        try expect(read.searchSelection(explicit:nil,available:[.kw]) == .all && read.preferredSearchPlatform == .wy,"平台不可用时不能丢弃偏好")
        try expect(read.searchSelection(explicit:.platform(.kw),available:[.kw,.wy]) == .platform(.kw) && read.preferredSearchPlatform == .wy,"明确入口应覆盖本次筛选而不改变偏好")
        let parser=LRCParser(), document=try parser.parse(RawLyrics(original:"[offset:500]\n[00:02]第一句\n[00:04]第二句",translation:"[offset:500]\n[00:02]First"))
        try expect(LyricTiming.index(in:document,positionMS:1999,offsetMS:500) == nil && LyricTiming.index(in:document,positionMS:2000,offsetMS:500) == 0,"正偏移应延后，并叠加原始 LRC offset")
        try expect(LyricTiming.index(in:document,positionMS:1000,offsetMS:-500) == 0,"负偏移应提前")
        try expect(LyricTiming.seekTime(for:document.timedLines[0],offsetMS:500,durationMS:9000) == 2000,"选句跳转未使用相同时间轴")
        try expect(LyricTiming.seekTime(for:document.timedLines[0],offsetMS:-5000,durationMS:9000) == 0 && LyricTiming.seekTime(for:document.timedLines[1],offsetMS:9000,durationMS:5000) == 5000,"歌词跳转超出音频边界")
        try expect(LyricTiming.adding(.max,500) == .max && LyricTiming.adding(.min,-500) == .min,"极端偏移不能溢出")
        try expect(document.timedLines[0].startMS == 1500 && document.timedLines[0].translation == "First","用户偏移不能修改缓存文档或译文")
        var browse=LyricBrowsingState();browse.begin();browse.preview(2)
        try expect(browse.confirmedIndex == nil,"拖动中不能确认跳转")
        browse.settle();try expect(browse.confirmedIndex == 2,"松手后应保留选中行")
        browse.begin();try expect(browse.confirmedIndex == nil,"再次拖动应清除旧确认")
        browse.preview(3);browse.settle();browse.follow();try expect(browse.phase == .following && browse.candidate == nil,"超时或离开应恢复跟随")
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let url=root.appendingPathComponent("library.store"), wy=TrackKey(platform:.wy,providerID:"same"), kw=TrackKey(platform:.kw,providerID:"same")
        do {
            let store=MusicStore(modelContainer:try MusicStore.container(url:url));try await store.prepare()
            try expect(try await store.lyricOffset(for:wy) == 0,"缺省偏移不是零")
            try await store.saveLyricOffset(500,for:wy);try await store.saveLyricOffset(-1000,for:kw)
            let savedWY = try await store.lyricOffset(for:wy), savedKW = try await store.lyricOffset(for:kw)
            try expect(savedWY == 500 && savedKW == -1000,"跨平台歌曲偏移应独立")
        }
        let reopened=MusicStore(modelContainer:try MusicStore.container(url:url));try await reopened.prepare()
        try expect(try await reopened.lyricOffset(for:wy) == 500,"重启后逐曲偏移丢失")
        try await reopened.resetLyricOffset(for:wy)
        let resetWY = try await reopened.lyricOffset(for:wy), keptKW = try await reopened.lyricOffset(for:kw)
        try expect(resetWY == 0 && keptKW == -1000,"重置不能影响其他歌曲")
    }
    static func crypto() async throws {
        try expect(CryptoTools.md5(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72","MD5 向量错误")
        func hex(_ text: String) -> Data { var d = Data(); var i = text.startIndex; while i < text.endIndex { let end = text.index(i,offsetBy:2); d.append(UInt8(text[i..<end],radix:16)!); i=end }; return d }
        let data = hex("6bc1bee22e409f96e93d7e117393172a"), key = hex("2b7e151628aed2a6abf7158809cf4f3c"), iv = hex("000102030405060708090a0b0c0d0e0f")
        let cbc = try CryptoTools.aes(data,mode:"aes-128-cbc",key:key,iv:iv), ecb = try CryptoTools.aes(data,mode:"aes-128-ecb",key:key,iv:Data())
        try expect(cbc.prefix(16) == hex("7649abac8119b246cee98e9b12e9197d") && ecb.prefix(16) == hex("3ad77bb40d7a3660a89ecaf32466ef97"),"AES NIST 向量错误")
        try expect(cbc.count == 32 && ecb.count == 16,"AES 填充不兼容移动版")
        try expectFailure { _ = try CryptoTools.aes(Data([1]),mode:"aes-128-ecb",key:key,iv:Data()) }
        let publicKey = "-----BEGIN PUBLIC KEY-----\nMIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDgtQn2JZ34ZC28NWYpAUd98iZ37BUrX/aKzmFbt7clFSs6sXqHauqKWqdtLkF2KexO40H1YTX8z2lSgBBOAxLsvaklV8k4cBFK9snQXE9/DDaFt6Rr7iVZMldczhC0JNgTz+SHXT6CBHuX3e9SdB1Ua44oncaTWz7OBGLbCiK45wIDAQAB\n-----END PUBLIC KEY-----"
        try expect(try CryptoTools.rsa(Data([1]),pem:publicKey) == Data(repeating:0,count:127) + Data([1]),"RSA 无填充/SPKI 向量错误")
        try expect(try CryptoTools.random(32).count == 32,"随机长度错误")
        try expectFailure { _ = try CryptoTools.aes(data,mode:"unknown",key:key,iv:iv) }
    }
    static func catalog() async throws {
        let rows: [MusicPlatform:[String:Any]] = [
            .kw:["MUSICRID":"MUSIC_123","SONGNAME":"标题 &amp; 音乐","ARTIST":"作者","DURATION":"120","N_MINFO":"level:ff,bitrate:128,format:mp3,size:2M"],
            .kg:["Audioid":123,"OriSongName":"标题","Singers":[["name":"作者"]],"FileHash":"HASH128","FileSize":123,"HQFileHash":"HASH320","HQFileSize":456,"Duration":120],
            .tx:["mid":"mid-1","id":123,"title":"标题","singer":[["name":"作者"]],"file":["media_mid":"media-1","size_128mp3":100],"album":["mid":"album-1","name":"专辑"],"interval":120],
            .wy:["id":NSNumber(value:9007199254740991),"name":"标题","ar":[["name":"作者"]],"al":["id":123,"name":"专辑"],"dt":120000,"l":["size":100]],
            .mg:["songId":"song-1","copyrightId":"cp-1","name":"标题","singerList":[["name":"作者"]],"duration":120,"audioFormats":[["formatType":"PQ","asize":123]],"lrcUrl":"https://example.test/lyric"]]
        for p in MusicPlatform.allCases { let catalog = PlatformCatalog(platform:p,http:FixedHTTP()), track = catalog.mapTrack(rows[p]!); try expect(track != nil && track?.key.platform == p && track?.metadata.payload["source"]?.string == p.rawValue,"\(p) 映射失败"); try expect(track?.durationMS == 120_000,"\(p) 毫秒转换错误"); let read = try JSONDecoder().decode(Track.self,from:JSONEncoder().encode(track!)); try expect(read == track,"\(p) 字段持久化丢失") }
        let kg = PlatformCatalog(platform:.kg,http:FixedHTTP()).mapTrack(rows[.kg]!)!; try expect(kg.metadata.payload["_types"]?.object["320k"]?.object["hash"]?.string == "HASH320","酷狗品质 hash 丢失")
        let tx = PlatformCatalog(platform:.tx,http:FixedHTTP()).mapTrack(rows[.tx]!)!; try expect(tx.metadata.payload["strMediaMid"]?.string == "media-1","QQ 媒体 ID 丢失")
    }
    static func files() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }
        let files = try DiskFileStore(root:root.appendingPathComponent("files")), cache = try DiskResourceCache(root:root.appendingPathComponent("cache"),budget:8)
        let key = try await files.stage(Data("abc".utf8),namespace:"scripts"), read = try await files.read(key); try expect(read == Data("abc".utf8),"文件往返失败")
        do { _ = try await files.read("../secret"); throw ValidationFailure(message:"应阻止越界文件") } catch is AppFailure { }
        try await cache.write(Data(repeating:1,count:6),key:"1",kind:.lyrics); try await cache.write(Data(repeating:2,count:6),key:"2",kind:.artwork)
        let size = try await cache.size(); try expect(size <= 8,"缓存超预算"); let epoch = await cache.epoch(); try await cache.clear(); try await cache.write(Data([1]),key:"late",kind:.lyrics,epoch:epoch); let empty = try await cache.size(); try expect(empty == 0,"清理后被旧请求重新填充缓存")
    }
    static func storage() async throws {
        let store = MusicStore(modelContainer:try MusicStore.container(inMemory:true)); try await store.prepare(); try await store.prepare()
        let stream = await store.snapshots(); var iterator = stream.makeAsyncIterator(); let initial = await iterator.next(); try expect(initial?.playlists.count == 1,"收藏歌单应幂等创建")
        let result = try await store.perform(.create(PlaylistDraft(name:"测试歌单"))), id = result.playlistID!
        let added = try await store.perform(.addTracks(id,[testTrack("a"),testTrack("a"),testTrack("a",platform:.wy)])); try expect(added.added == 2 && added.duplicates == 1,"同平台去重错误")
        let items = try await store.items(playlistID:id), reversed = items.reversed().map(\.id); _ = try await store.perform(.reorder(id,reversed))
        do { _ = try await store.perform(.reorder(id,[UUID()])); throw ValidationFailure(message:"非法重排应失败") } catch is AppFailure { }
        let unchanged = try await store.items(playlistID:id); try expect(unchanged.map(\.id) == reversed,"失败重排未回滚")
        do { _ = try await store.perform(.delete(Playlist.favoritesID)); throw ValidationFailure(message:"不应删除收藏歌单") } catch is AppFailure { }
        _ = try await store.perform(.setFavorite(testTrack("a"),true)); _ = try await store.perform(.delete(id)); let favorites = try await store.items(playlistID:Playlist.favoritesID); try expect(favorites.count == 1,"删除歌单破坏收藏")
    }
    static func persistence() async throws {
        let store = MusicStore(modelContainer:try MusicStore.container(inMemory:true)); try await store.prepare()
        for q in 1...25 { try await store.recordQuery("q\(q)") }; let queries = try await store.recentQueries(); try expect(queries.count == 20 && queries.first == "q25","搜索历史上限错误")
        try await store.recordStarted(testTrack("a"),at:Date()); try await store.recordStarted(testTrack("a"),at:Date()); let history = try await store.recentTracks(limit:10); try expect(history.count == 1 && history[0].playCount == 2,"播放历史聚合错误：\(history.map { $0.playCount })")
        let snapshot = PlaybackSnapshot(queue:QueueState(entries:[QueueEntry(track:testTrack("a"))]),positionMS:500,requestedQuality:.flac); try await store.savePlayback(snapshot); let read = try await store.loadPlayback(); try expect(read?.positionMS == 500,"快照往返错误")
        let script = SourceScript(name:"测试",fileKey:"scripts/test",digest:"test"); try await store.save(script); try await store.setActive(script.id); try await store.delete(script.id); let active = try await store.activeScriptID(); try expect(active == nil,"删除音源未清理活动身份")
    }
    static func runtime() async throws {
        let runtime = ScriptRuntime(http:FixedHTTP()), script = SourceScript(name:"测试",fileKey:"scripts/test",digest:"test")
        let caps = try await runtime.initialize(script:script,text:validScript + "\nlx.send('updateAlert',{log:'测试更新',updateUrl:'https://example.test/update'});"); try expect(caps.platforms[.kw]?.qualities == [.q128],"能力声明错误")
        let updates = await runtime.updates(); var iterator = updates.makeAsyncIterator(); let notice = await iterator.next(); try expect(notice?.message == "测试更新","更新事件未传递")
        let url = try await runtime.resolve(testTrack("abc"),quality:.q128); try expect(url.absoluteString == "https://example.test/abc.mp3","musicInfo 或 Promise 失败"); await runtime.invalidate()
    }
    static func diskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:directory) }
        let url = directory.appendingPathComponent("library.store"), first = MusicStore(modelContainer:try MusicStore.container(url:url))
        try await first.prepare(); let result = try await first.perform(.create(PlaylistDraft(name:"磁盘歌单"))); _ = try await first.perform(.addTracks(result.playlistID!,[testTrack("disk")]))
        let second = MusicStore(modelContainer:try MusicStore.container(url:url)); try await second.prepare()
        let read = try await second.items(playlistID:result.playlistID!); try expect(read.map(\.track.key.providerID) == ["disk"],"重新打开磁盘后歌单丢失")
    }
    static func scriptHTTP() async throws {
        let runtime = ScriptRuntime(http:FixedHTTP())
        let text = """
        lx.on('request', () => new Promise((resolve,reject) => {
          const u=lx.utils;
          if(u.crypto.md5('abc')!=='900150983cd24fb0d6963f7d28e17f72') throw Error('md5');
          if(u.buffer.bufToString(u.buffer.from('5L2g5aW9','base64'),'utf8')!=='你好') throw Error('unicode');
          lx.request('https://example.test/request',{method:'post',form:{q:'你好'}},(err,resp) => err ? reject(err) : resolve(resp.body.url));
        }));
        lx.send('inited',{sources:{kw:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});
        """
        _ = try await runtime.initialize(script:SourceScript(name:"测试",fileKey:"scripts/test",digest:"test"),text:text)
        let url = try await runtime.resolve(testTrack("x"),quality:.q128); try expect(url.absoluteString == "https://example.test/audio.mp3","HTTP 宿主回调失败"); await runtime.invalidate()
    }
    static func upstreamFailure() async throws {
        let body = Data(#"{"code":200,"data":[{"code":-110,"url":null,"fee":1,"payed":0}]}"#.utf8)
        for host in ["interface3.music.163.com","example.test"] {
            let runtime = ScriptRuntime(http:FixedHTTP(body:body))
            let text = """
            lx.on('request', ({info}) => {
              if (info.musicInfo.songmid === 'next') return Promise.reject(new Error('failed'));
              return new Promise((resolve,reject) => lx.request('https://\(host)/api/song/enhance/player/url',{},(error,response) => {
                if (info.musicInfo.songmid === 'fallback') resolve('https://example.test/fallback.mp3');
                else reject(new Error('failed'));
              }));
            });
            lx.send('inited',{sources:{wy:{type:'music',actions:['musicUrl'],qualitys:['128k']}}});
            """
            _ = try await runtime.initialize(script:SourceScript(name:"错误响应测试",fileKey:"scripts/test",digest:"test"),text:text)
            do { _ = try await runtime.resolve(testTrack("167691",platform:.wy),quality:.q128); throw ValidationFailure(message:"空地址应失败") }
            catch let failure as AppFailure {
                try expect(failure.code == (host == "example.test" ? "mediaUnavailable" : "upstreamUnavailable"),"上游错误归因不正确")
                if host != "example.test" { try expect(failure.userMessage.contains("-110") && !failure.retryable,"应明确显示上游返回码") }
                try expect(!failure.userMessage.contains("Error: failed"),"不应直接展示脚本的模糊错误")
            }
            let fallback = try await runtime.resolve(testTrack("fallback",platform:.wy),quality:.q128)
            try expect(fallback.lastPathComponent == "fallback.mp3","不能阻止脚本在空地址响应后自行回退成功")
            do { _ = try await runtime.resolve(testTrack("next",platform:.wy),quality:.q128); throw ValidationFailure(message:"下一首应失败") }
            catch let failure as AppFailure { try expect(failure.code == "mediaUnavailable","上一首的响应原因污染了下一首") }
            await runtime.invalidate()
        }
    }
    static func compatibility() async throws {
        try expect(SourceManager.compatibilityPolicy(digest:"a407ffe0ab23c29cd32ce249b83e61c8e2b70719895f16034566ad7557282785") && !SourceManager.compatibilityPolicy(digest:"unknown"),"自动兼容只适用于已验证脚本摘要")
        let expression = "Promise.resolve('https://example.test/' + lx.utils.crypto.aesEncrypt(lx.utils.buffer.from('0000000000000000'), 'aes-128-ecb', lx.utils.buffer.from('1234567890123456'), []).length + '.mp3')"
        let text = validScript.replacingOccurrences(of:"Promise.resolve('https://example.test/' + info.musicInfo.songmid + '.mp3')",with:expression)
        for enabled in [false,true] { let runtime = ScriptRuntime(ecbPKCS7:enabled); _ = try await runtime.initialize(script:SourceScript(name:"测试",fileKey:"scripts/test",digest:"test"),text:text); let url = try await runtime.resolve(testTrack("x"),quality:.q128); try expect(url.lastPathComponent == (enabled ? "32.mp3" : "16.mp3"),"兼容填充污染了标准模式"); await runtime.invalidate() }
    }
    static func scriptErrors() async throws {
        let broken = ScriptRuntime(); do { _ = try await broken.initialize(script:SourceScript(name:"错误",fileKey:"scripts/test",digest:"test"),text:validScript + "\nthrow new Error('初始化末尾失败');"); throw ValidationFailure(message:"初始化异常应失败") } catch is AppFailure { }; await broken.invalidate()
        let runtime = ScriptRuntime(), text = validScript.replacingOccurrences(of:"Promise.resolve('https://example.test/' + info.musicInfo.songmid + '.mp3')",with:"new Promise(resolve => setTimeout(() => resolve('https://example.test/late.mp3'), 1000))")
        _ = try await runtime.initialize(script:SourceScript(name:"测试",fileKey:"scripts/test",digest:"test"),text:text)
        let task = Task { try await runtime.resolve(testTrack("x"),quality:.q128) }; task.cancel()
        do { _ = try await task.value; throw ValidationFailure(message:"解析取消未生效") } catch is CancellationError { }; await runtime.invalidate()
    }
    static func sourceLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer { try? FileManager.default.removeItem(at:root) }
        let files = try DiskFileStore(root:root.appendingPathComponent("files")), repository = MemoryRepository(), manager = SourceManager(repository:repository,files:files,http:FixedHTTP())
        let input = root.appendingPathComponent("source.js"); try Data(validScript.utf8).write(to:input)
        let script = try await manager.importScript(SourceImport(url:input)); let active = await repository.activeScriptID(); try expect(active == nil,"导入不应自动启用")
        try await manager.activate(scriptID:script.id); await repository.setRejectSave(true)
        var failed = false
        do { _ = try await manager.importScript(SourceImport(url:input,replacementID:script.id)) } catch { failed = true }; try expect(failed,"保存失败未传递")
        let resolved = try await manager.resolve(testTrack("retained"),quality:.q128); try expect(resolved.scriptID == script.id,"替换失败破坏活动源")
        await repository.setRejectSave(false);try await manager.activate(scriptID:script.id)
        let changed=try await manager.resolve(testTrack("retained"),quality:.q128)
        try expect(changed.sourceGeneration != resolved.sourceGeneration,"重新初始化应隔离旧实例")
        try await manager.delete(scriptID:script.id)
        do { _ = try await manager.resolve(testTrack("x"),quality:.q128); throw ValidationFailure(message:"删除后仍可解析") } catch is AppFailure { }
    }
    static func sourceFallbacks() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let files=try DiskFileStore(root:root),repository=MemoryRepository(),manager=SourceManager(repository:repository,files:files,http:FixedHTTP())
        var scripts:[SourceScript]=[]
        for (name,expression) in [("主音源","Promise.reject(new Error('主接口不可用'))"),("备用失败","Promise.resolve(null)"),("备用成功","Promise.resolve('https://example.test/success.mp3')")] {
            let text=validScript.replacingOccurrences(of:"本地协议测试",with:name).replacingOccurrences(of:"Promise.resolve('https://example.test/' + info.musicInfo.songmid + '.mp3')",with:expression)
            let url=root.appendingPathComponent(name+".js");try Data(text.utf8).write(to:url)
            scripts.append(try await manager.importScript(SourceImport(url:url)))
        }
        try await manager.activate(scriptID:scripts[0].id);try await manager.setSourceOrder(scriptIDs:scripts.map(\.id))
        let ids=await repository.sourceOrderIDs();try expect(ids == scripts.map(\.id),"列表顺序必须作为唯一音源优先级持久化")
        let result=try await manager.resolve(testTrack("same"),quality:.q128)
        try expect(result.scriptID == scripts[2].id && result.sourceName == "备用成功","取链失败应依次尝试备用音源")
        try expect(result.failedScriptIDs == Set([scripts[0].id,scripts[1].id]),"已取链失败的音源必须交给播放器排除，不能在媒体失败后重复尝试")
        do { _ = try await manager.resolve(testTrack("same"),quality:.q128,excluding:[scripts[2].id]);throw ValidationFailure(message:"应排除已失败的音源") } catch let failure as AppFailure { try expect(failure.code == "sourcesExhausted","所有源失败必须有明确终止状态") }
        try await manager.setSourceOrder(scriptIDs:[scripts[2].id,scripts[0].id,scripts[1].id])
        let reordered=try await manager.resolve(testTrack("same"),quality:.q128)
        try expect(reordered.scriptID == scripts[2].id && reordered.failedScriptIDs.isEmpty,"拖动到首位后必须首先尝试该音源")
    }
    static func sourceOrderingPersistence() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("library.store"),files=try DiskFileStore(root:directory.appendingPathComponent("files"))
        let scripts=["一","二","三"].map { SourceScript(name:$0,fileKey:"scripts/"+$0,digest:$0) },original=scripts.map(\.id),expected=[scripts[2].id,scripts[0].id,scripts[1].id]
        do {
            let store=MusicStore(modelContainer:try MusicStore.container(url:url));try await store.prepare()
            for script in scripts { try await store.save(script) }
            let manager=SourceManager(repository:store,files:files,http:FixedHTTP());await manager.restoreActive()
            try await manager.setSourceOrder(scriptIDs:expected)
            let rows=try await store.scripts();try expect(rows.map(\.id) == expected,"音源顺序未写入持久化")
            do { try await manager.setSourceOrder(scriptIDs:[scripts[0].id]);throw ValidationFailure(message:"缺项排序应拒绝") } catch is AppFailure { }
            let unchanged=try await store.sourceOrderIDs();try expect(unchanged == expected,"非法排序不应改动已保存顺序")
        }
        let reopened=MusicStore(modelContainer:try MusicStore.container(url:url));try await reopened.prepare()
        let restored=SourceManager(repository:reopened,files:files,http:FixedHTTP());await restored.restoreActive()
        let stream=await restored.snapshots();var iterator=stream.makeAsyncIterator();let snapshot=await iterator.next()
        try expect(snapshot?.scripts.map(\.id) == expected,"重新打开应用后顺序应保持")
        let memory=MemoryRepository();for script in scripts { try await memory.save(script) }
        let failing=SourceManager(repository:memory,files:files,http:FixedHTTP());await failing.restoreActive();await memory.setRejectSave(true)
        var rejected=false
        do { try await failing.setSourceOrder(scriptIDs:expected) } catch { rejected=true }
        try expect(rejected,"注入排序保存失败后必须报错")
        let failedOrder=await memory.sourceOrderIDs();try expect(failedOrder == original,"保存失败应保留原顺序")
        let failedStream=await failing.snapshots();var failedIterator=failedStream.makeAsyncIterator();let failedSnapshot=await failedIterator.next()
        try expect(failedSnapshot?.scripts.map(\.id) == original,"失败不应发布假成功顺序")
    }
    static func retainedSourceFailure() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let files=try DiskFileStore(root:root),repository=MemoryRepository(),manager=SourceManager(repository:repository,files:files,http:FixedHTTP())
        let url=root.appendingPathComponent("broken.js");try Data((validScript+"\nthrow new Error('服务器不可用');").utf8).write(to:url)
        let script=try await manager.importScript(SourceImport(url:url,retainOnInitializationFailure:true))
        let saved=await repository.scripts();try expect(saved.count == 1 && saved[0].initializationError?.contains("服务器不可用") == true && script.lastValidatedCapabilities == nil,"批量导入应保留失败记录，不能伪造能力通过")
        let active=await repository.activeScriptID();try expect(active == nil,"保留失败记录不应自动启用")
    }
    static func search() async throws {
        let service = SearchService(providers:[.kw:FixedCatalog(platform:.kw),.kg:FixedCatalog(platform:.kg,fail:true)],history:MemoryRepository())
        await service.updateAvailablePlatforms([.kw,.kg]); await service.submit(query:"新请求",selection:.all); try await Task.sleep(for:.milliseconds(30))
        try expect(service.snapshot.groups[0].tracks.count == 2 && service.snapshot.groups[1].failure != nil,"部分成功未保留")
        await service.loadMore(); try await Task.sleep(for:.milliseconds(30)); try expect(service.snapshot.groups[0].tracks.count == 3 && service.snapshot.groups[0].nextPage == 3,"分页去重错误")
        await service.submit(query:"旧请求",selection:.all); await service.submit(query:"最新请求",selection:.all); try await Task.sleep(for:.milliseconds(100)); try expect(service.snapshot.groups[0].tracks.first?.key.providerID == "最新请求","迟到请求覆盖新搜索")
        await service.updateAvailablePlatforms([]); try expect(service.snapshot.groups.isEmpty,"无能力不应搜索")
    }
}
