import Foundation

// Platform acquisition and formats follow AnyListen Online Metadata; UI remains line based.
extension PlatformCatalog {
    func platformLyrics(_ track:Track) async throws -> RawLyrics {
        guard track.key.platform == platform else { throw LyricDecoders.invalid() }
        switch platform {
        case .wy:
            var request=try eapi("/api/song/lyric/v1",["id":track.key.providerID,"cp":false,"tv":0,"lv":0,"rv":0,"kv":0,"yv":0,"ytv":0,"yrv":0])
            request.url=URL(string:"https://interface3.music.163.com/eapi/song/lyric/v1")!
            let root=try await lyricJSON(request)
            guard (root["code"] as? Int) == 200 else { throw LyricDecoders.invalid() }
            func value(_ key:String) -> String? { (root[key] as? [String:Any])?["lyric"] as? String }
            if let yrc=value("yrc"),!yrc.isEmpty {
                let original=LyricText.yrc(yrc)
                if !(try LRCParser().parse(RawLyrics(original:original,translation:nil))).timedLines.isEmpty {
                    return RawLyrics(original:original,translation:value("ytlrc").map(LyricText.repair),format:.yrc)
                }
            }
            return RawLyrics(original:value("lrc").map(LyricText.repair),translation:value("tlyric").map(LyricText.repair))
        case .kw:
            for word in [true,false] {
                do {
                    let url=try lyricURL("http://mlyric.kuwo.cn/mobi.s",["f":"web","type":"lyric","lrcx":word ? "1" : "0","rid":track.key.providerID,"encode":"utf8"])
                    let response=try await lyricResponse(HTTPPayload(url:url,maximumBytes:2*1024*1024))
                    return try LyricText.kuwo(LyricDecoders.kuwo(response.body,lyricx:word))
                } catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation() }
            }
            throw LyricDecoders.invalid()
        case .kg:
            let hash=track.metadata.payload["hash"]?.string ?? ""
            let seconds=track.metadata.payload["_interval"]?.string ?? String((track.durationMS ?? 0)/1000)
            let headers=["KG-RC":"1","KG-THash":"expand_search_manager.cpp:852736169:451","User-Agent":"KuGou2012-9020-ExpandSearchManager"]
            let root=try await lyricJSON(HTTPPayload(url:try lyricURL("http://lyrics.kugou.com/search",["ver":"1","man":"yes","client":"pc","keyword":track.title,"hash":hash,"timelength":seconds,"lrctxt":"1"]),headers:headers))
            guard let candidate=(root["candidates"] as? [[String:Any]])?.first,let id=lyricString(candidate["id"]),let key=lyricString(candidate["accesskey"]) else { throw LyricDecoders.invalid() }
            let hasKRC=(candidate["krctype"] as? Int) == 1 && (candidate["contenttype"] as? Int) != 1
            for format in hasKRC ? ["krc","lrc"] : ["lrc"] {
                do {
                    let root=try await lyricJSON(HTTPPayload(url:try lyricURL("http://lyrics.kugou.com/download",["ver":"1","client":"pc","id":id,"accesskey":key,"fmt":format,"charset":"utf8"]),headers:headers))
                    guard let content=root["content"] as? String else { throw LyricDecoders.invalid() }
                    if (root["fmt"] as? String ?? format) == "krc" { return LyricText.krc(try LyricDecoders.krc(content)) }
                    guard let data=Data(base64Encoded:content),let text=String(data:data,encoding:.utf8) else { throw LyricDecoders.invalid() }
                    return RawLyrics(original:LyricText.repair(text),translation:nil)
                } catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation() }
            }
            throw LyricDecoders.invalid()
        case .tx:
            var id=track.metadata.payload["songId"]?.string
            if id == nil {
                let payload:[String:Any]=["comm":["ct":"19","cv":"1859","uin":"0"],"req":["module":"music.pf_song_detail_svr","method":"get_song_detail_yqq","param":["song_type":0,"song_mid":track.key.providerID]]]
                let root=try await qqLyricRequest(payload)
                let info=((root["req"] as? [String:Any])?["data"] as? [String:Any])?["track_info"] as? [String:Any]
                id=lyricString(info?["id"])
            }
            guard let id,let songID=Int(id) else { throw LyricDecoders.invalid() }
            let payload:[String:Any]=["comm":["ct":"19","cv":"1859","uin":"0"],"req":["method":"GetPlayLyricInfo","module":"music.musichallSong.PlayLyricInfo","param":["format":"json","crypt":1,"ct":19,"cv":1873,"interval":0,"lrc_t":0,"qrc":1,"qrc_t":0,"roma":1,"roma_t":0,"songID":songID,"trans":1,"trans_t":0,"type": -1]]]
            let root=try await qqLyricRequest(payload),req=root["req"] as? [String:Any]
            guard (root["code"] as? Int) == 0,(req?["code"] as? Int) == 0,let data=req?["data"] as? [String:Any],let content=data["lyric"] as? String,!content.isEmpty else { throw LyricDecoders.invalid() }
            let original=LyricText.qrc(try LyricDecoders.qrc(content))
            var translation:String?
            if let text=data["trans"] as? String,!text.isEmpty { translation=try? LyricText.qrc(LyricDecoders.qrc(text)) }
            return RawLyrics(original:original,translation:translation,format:.qrc)
        case .mg:
            var urls=track.metadata.payload
            if urls["mrcUrl"] == nil {
                var request=HTTPPayload(url:URL(string:"https://c.musicapp.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?resourceType=2")!,method:"POST",headers:["Content-Type":"application/x-www-form-urlencoded"])
                request.body=ScriptRuntime.formEncoded(["resourceId":track.key.providerID])
                let root=try await lyricJSON(request)
                if let resource=(root["resource"] as? [[String:Any]])?.first {
                    for key in ["lrcUrl","mrcUrl","trcUrl"] { if let value=resource[key] as? String { urls[key] = .string(value) } }
                }
            }
            let mrc=urls["mrcUrl"]?.string.flatMap{ $0.isEmpty ? nil : URL(string:$0) },lrc=urls["lrcUrl"]?.string.flatMap{ $0.isEmpty ? nil : URL(string:$0) }
            let original:String,format:LyricFormat
            if let mrc {
                do { original=LyricText.wordLines(try LyricDecoders.mrc(await miguLyric(mrc)),wordPattern:#"\(\d+,\d+\)"#);format = .mrc }
                catch is CancellationError { throw CancellationError() }
                catch { guard let lrc else { throw error };original=try await miguLyric(lrc);format = .lrc }
            } else if let lrc { original=try await miguLyric(lrc);format = .lrc }
            else { throw LyricDecoders.invalid() }
            var translation:String?
            if let raw=urls["trcUrl"]?.string,let url=URL(string:raw) { translation=try? await miguLyric(url) }
            return RawLyrics(original:original,translation:translation,format:format)
        }
    }
    private func lyricString(_ value:Any?) -> String? {
        if let value=value as? String { return value };return (value as? NSNumber)?.stringValue
    }
    private func lyricURL(_ base:String,_ values:[String:String]) throws -> URL {
        guard var c=URLComponents(string:base) else { throw LyricDecoders.invalid() }
        c.queryItems=values.sorted{$0.key < $1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        guard let url=c.url else { throw LyricDecoders.invalid() };return url
    }
    private func lyricResponse(_ request:HTTPPayload) async throws -> HTTPResult {
        let response=try await http.execute(request);try Task.checkCancellation()
        guard (200..<300).contains(response.status) else { throw AppFailure.make("歌词接口返回 HTTP \(response.status)",code:"lyricsHTTP",module:"lyrics",retryable:true) }
        return response
    }
    private func lyricJSON(_ request:HTTPPayload) async throws -> [String:Any] {
        let r=try await lyricResponse(request)
        guard let root=(try? JSONSerialization.jsonObject(with:r.body)) as? [String:Any] else { throw LyricDecoders.invalid() };return root
    }
    private func qqLyricRequest(_ object:[String:Any]) async throws -> [String:Any] {
        try await lyricJSON(HTTPPayload(url:URL(string:"https://u.y.qq.com/cgi-bin/musicu.fcg")!,method:"POST",headers:["Content-Type":"application/json","Referer":"https://y.qq.com","User-Agent":"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 Chrome/86.0.4240.198 Safari/537.36"],body:JSONSerialization.data(withJSONObject:object)))
    }
    private func miguLyric(_ url:URL) async throws -> String {
        let result=try await lyricResponse(HTTPPayload(url:url,headers:["Referer":"https://app.c.nf.migu.cn/","channel":"0146921","User-Agent":"Mozilla/5.0 (Linux; Android 5.1.1) AppleWebKit/537.36 Chrome/59.0.3071.115 Mobile Safari/537.36"],maximumBytes:2*1024*1024))
        guard let text=String(data:result.body,encoding:.utf8) else { throw LyricDecoders.invalid() };return text
    }
}
