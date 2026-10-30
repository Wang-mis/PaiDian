import Foundation
import CryptoKit

// Request shapes and LX musicInfo field names are tracked in docs/开发记录.md.
struct PlatformCatalog: CatalogProvider {
    let platform: MusicPlatform
    let http: any HTTPClient
    func search(query: String, page: Int, pageSize: Int) async throws -> SearchPage {
        guard !query.isEmpty, page > 0, (1...100).contains(pageSize) else { throw AppFailure.make("搜索参数无效", module: "catalog") }
        let request: HTTPPayload
        switch platform {
        case .kw:
            request = HTTPPayload(url: try url("http://search.kuwo.cn/r.s", ["client":"kt","all":query,"pn":"\(page - 1)","rn":"\(pageSize)","uid":"794762570","ver":"kwplayer_ar_9.2.2.1","vipver":"1","show_copyright_off":"1","newver":"1","ft":"music","cluster":"0","strategy":"2012","encoding":"utf8","rformat":"json","vermerge":"1","mobi":"1","issubtitle":"1"]))
        case .kg:
            request = HTTPPayload(url: try url("https://songsearch.kugou.com/song_search_v2", ["keyword":query,"page":"\(page)","pagesize":"\(pageSize)","userid":"0","clientver":"","platform":"WebFilter","filter":"2","iscorrection":"1","privilege_filter":"0","area_code":"1"]))
        case .tx:
            let object: [String: Any] = ["comm":["ct":"19","cv":"2151","uin":"0","tmeAppID":"qqmusic","tmeLoginType":0], "music.search.SearchCgiService":["module":"music.search.SearchCgiService","method":"DoSearchForQQMusicDesktop","param":["grp":1,"num_per_page":pageSize,"page_num":page,"query":query,"remoteplace":"txt.newclient.top","search_type":0,"searchid":UUID().uuidString.replacingOccurrences(of: "-", with: "") + "00000"]]]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            request = HTTPPayload(url: try url("https://u.y.qq.com/cgi-bin/musics.fcg", ["sign":Self.qqSignature(data)]), method: "POST", headers: ["User-Agent":"QQMusic 14090508(android 12)", "Content-Type":"application/json"], body: data)
        case .wy:
            request = try eapi("/api/search/song/list/page", ["keyword":query,"needCorrect":"1","channel":"typing","offset":pageSize * (page - 1),"scene":"normal","total":page == 1,"limit":pageSize])
        case .mg:
            let time = String(Int64(Date().timeIntervalSince1970 * 1000)), device = "963B7AA0D21511ED807EE5846EC87D20"
            let sign = CryptoTools.md5(Data((query + "6cdc72a439cef99a3418d2a78aa28c73yyapp2d16148780a1dcc7408e06336b98cfd50" + device + time).utf8))
            request = HTTPPayload(url: try url("https://jadeite.migu.cn/music_search/v3/search/searchAll", ["isCorrect":"0","isCopyright":"1","searchSwitch":"{\"song\":1,\"album\":0,\"singer\":0,\"tagSong\":1,\"mvSong\":0,\"bestShow\":1,\"songlist\":0,\"lyricSong\":0}","pageSize":"\(pageSize)","text":query,"pageNo":"\(page)","sort":"0","sid":"USS"]), headers: ["uiVersion":"A_music_3.6.1","deviceId":device,"timestamp":time,"sign":sign,"channel":"0146921","User-Agent":"Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Mobile Safari/537.36"])
        }
        let result = try await json(request); try Task.checkCancellation()
        return try decodeSearch(result, page: page, pageSize: pageSize)
    }
    func decodeSearch(_ root: [String: Any], page: Int, pageSize: Int) throws -> SearchPage {
        let rows: [[String: Any]], total: Int
        switch platform {
        case .kw:
            guard root["TOTAL"] != nil, let list = root["abslist"] as? [[String: Any]] ?? (integer(root["TOTAL"]) == 0 ? [] : nil) else { throw malformed() }; rows = list; total = integer(root["TOTAL"])
        case .kg:
            guard integer(root["error_code"], fallback: -1) == 0, let data = root["data"] as? [String: Any], let list = data["lists"] as? [[String: Any]] else { throw malformed() }
            rows = list.flatMap { [$0] + ($0["Grp"] as? [[String: Any]] ?? []) }; total = integer(data["total"])
        case .tx:
            let service = dict(root["music.search.SearchCgiService"] ?? root["req"]), data = dict(service["data"]), body = dict(data["body"]), song = dict(body["song"])
            guard integer(root["code"], fallback: -1) == 0, integer(service["code"], fallback: -1) == 0, let list = song["list"] as? [[String: Any]] else { throw malformed() }; rows = list; total = integer(dict(data["meta"])["sum"])
        case .wy:
            let data = dict(root["data"])
            guard integer(root["code"]) == 200, let list = data["resources"] as? [[String: Any]] else { throw malformed() }; rows = list.map { dict(dict($0["baseInfo"])["simpleSongData"]) }; total = integer(data["totalCount"])
        case .mg:
            guard string(root["code"]) == "000000", let result = root["songResultData"] as? [String: Any], let list = result["resultList"] as? [Any] else { throw malformed() }; rows = list.flatMap { ($0 as? [[String: Any]]) ?? (($0 as? [String: Any]).map { [$0] } ?? []) }; total = integer(result["totalCount"])
        }
        var seen = Set<TrackKey>()
        let tracks = rows.compactMap(mapTrack).filter { seen.insert($0.key).inserted }
        if !rows.isEmpty && tracks.isEmpty { throw malformed() }
        return SearchPage(tracks: tracks, page: page, hasMore: page * pageSize < total, total: total)
    }
    func mapTrack(_ row: [String: Any]) -> Track? {
        var id = "", title = "", artists: [String] = [], album = "", albumID = "", duration: Int64?, image: String?
        var fields: [String: Any] = [:], types: [[String: Any]] = [], typeMap: [String: Any] = [:]
        func add(_ quality: AudioQuality, _ size: Any?, hash: Any? = nil) {
            var details: [String: Any] = [:]; if let size { details["size"] = String(describing: size) }; if let hash, !string(hash).isEmpty { details["hash"] = string(hash) }
            typeMap[quality.rawValue] = details; var t = details; t["type"] = quality.rawValue; types.append(t)
        }
        switch platform {
        case .kw:
            id = string(row["MUSICRID"]).replacingOccurrences(of: "MUSIC_", with: ""); title = string(row["SONGNAME"]); artists = [string(row["ARTIST"])]; album = string(row["ALBUM"]); albumID = string(row["ALBUMID"]); duration = int64(row["DURATION"]).map { $0 * 1000 }
            let info = string(row["N_MINFO"])
            for (quality, bitrate) in [(AudioQuality.q128,"128"),(.q320,"320"),(.flac,"2000"),(.flac24bit,"4000")] { if info.contains("bitrate:\(bitrate),") { add(quality, nil) } }
        case .kg:
            id = string(row["Audioid"]); title = string(row["OriSongName"]); if !string(row["Suffix"]).isEmpty { title += " " + string(row["Suffix"]) }; artists = names(row["Singers"]); if artists.isEmpty { artists = [string(row["SingerName"])] }; album = string(row["AlbumName"]); albumID = string(row["AlbumID"]); duration = int64(row["Duration"]).map { $0 * 1000 }; fields["hash"] = string(row["FileHash"]); fields["_interval"] = integer(row["Duration"])
            for (quality, prefix) in [(AudioQuality.q128,""),(.q320,"HQ"),(.flac,"SQ"),(.flac24bit,"Res")] { if integer(row[prefix + "FileSize"]) > 0 { add(quality, row[prefix + "FileSize"], hash: row[prefix + "FileHash"]) } }
        case .tx:
            id = string(row["mid"]); title = string(row["title"] ?? row["name"]); artists = names(row["singer"]); let a = dict(row["album"]); album = string(a["name"]); albumID = string(a["mid"]); duration = int64(row["interval"]).map { $0 * 1000 }
            let file = dict(row["file"]); fields["songId"] = string(row["id"]); fields["albumMid"] = albumID; fields["strMediaMid"] = string(file["media_mid"])
            guard !string(file["media_mid"]).isEmpty else { return nil }
            if !albumID.isEmpty { image = "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumID).jpg" }
            for (quality, size) in [(AudioQuality.q128,"size_128mp3"),(.q320,"size_320mp3"),(.flac,"size_flac"),(.flac24bit,"size_hires")] { if integer(file[size]) > 0 { add(quality, file[size]) } }
        case .wy:
            id = string(row["id"]); title = string(row["name"]); artists = names(row["ar"]); let a = dict(row["al"]); album = string(a["name"]); albumID = string(a["id"]); image = a["picUrl"] as? String; duration = int64(row["dt"])
            let privilege = dict(row["privilege"]); let maxbr = integer(privilege["maxbr"])
            for (quality, field, bitrate) in [(AudioQuality.q128,"l",128000),(.q320,"h",320000),(.flac,"sq",999000),(.flac24bit,"hr",1999000)] { let d = dict(row[field]); if integer(d["size"]) > 0 || maxbr >= bitrate { add(quality, d["size"]) } }
        case .mg:
            id = string(row["songId"]); let copyright = string(row["copyrightId"]); guard !copyright.isEmpty else { return nil }; fields["copyrightId"] = copyright
            title = string(row["name"]); artists = names(row["singerList"]); album = string(row["album"]); albumID = string(row["albumId"]); duration = int64(row["duration"]).map { $0 * 1000 }
            image = (row["img3"] ?? row["img2"] ?? row["img1"]) as? String; if let img = image, !img.isEmpty, !img.hasPrefix("http") { image = "http://d.musicapp.migu.cn" + img }
            for key in ["lrcUrl", "mrcUrl", "trcUrl"] { fields[key] = row[key] ?? NSNull() }
            let qualities: [String: AudioQuality] = ["PQ":.q128,"HQ":.q320,"SQ":.flac,"ZQ24":.flac24bit]
            for audio in row["audioFormats"] as? [[String: Any]] ?? [] { if let q = qualities[string(audio["formatType"])] { add(q, audio["asize"] ?? audio["isize"]) } }
        }
        guard !id.isEmpty, !title.isEmpty else { return nil }
        title = decodeName(title); artists = artists.map(decodeName).filter { !$0.isEmpty }; album = decodeName(album)
        fields.merge(["source":platform.rawValue,"songmid":id,"name":title,"singer":artists.joined(separator: "、"),"albumName":album,"albumId":albumID,"interval":formatTime(duration ?? 0),"types":types,"_types":typeMap,"typeUrl":[String:String](),"img":image as Any? ?? NSNull(),"lrc":NSNull()]) { old, _ in old }
        guard let data = try? JSONSerialization.data(withJSONObject: fields), let metadata = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return Track(key: TrackKey(platform: platform, providerID: id), title: title, artists: artists, albumTitle: album, durationMS: duration, artworkURL: image.flatMap(URL.init(string:)), qualities: Set(types.compactMap { ($0["type"] as? String).flatMap(AudioQuality.init(rawValue:)) }), metadata: PlatformMetadata(payload: metadata))
    }
    func fetchTrackDetail(_ track: Track) async throws -> Track {
        guard track.key.platform == platform else { throw malformed() }
        if platform == .kw, track.artworkURL == nil {
            let root = try await json(HTTPPayload(url: try url("http://m.kuwo.cn/newh5/singles/songinfoandlrc", ["musicId":track.key.providerID])))
            var result = track; let info = dict(dict(root["data"])["songinfo"]); result.artworkURL = (info["pic"] as? String).flatMap(URL.init(string:)); return result
        }
        // Search results already contain the resolver's required identity and quality fields.
        return track
    }
    func fetchLyrics(_ track: Track) async throws -> RawLyrics { try await platformLyrics(track) }
    private func json(_ request: HTTPPayload) async throws -> [String: Any] {
        let result = try await http.execute(request); guard (200..<300).contains(result.status) else { throw AppFailure.make("\(platform.name)请求失败（HTTP \(result.status)）", code: "network", module: "catalog", retryable: true) }
        guard let root = try JSONSerialization.jsonObject(with: result.body) as? [String: Any] else { throw malformed() }; return root
    }
    func eapi(_ path: String, _ object: [String: Any]) throws -> HTTPPayload {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys,.withoutEscapingSlashes]), as: UTF8.self)
        let digest = CryptoTools.md5(Data("nobody\(path)use\(text)md5forencrypt".utf8))
        let data = Data("\(path)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)".utf8)
        let encrypted = try CryptoTools.aes(data, mode: "aes-128-ecb", key: Data("e82ckenh8dichen8".utf8), iv: Data(), pkcs7:true)
        return HTTPPayload(url: URL(string: "https://interface.music.163.com/eapi/batch")!, method: "POST", headers: ["Content-Type":"application/x-www-form-urlencoded","Origin":"https://music.163.com","User-Agent":"Mozilla/5.0"], body: ScriptRuntime.formEncoded(["params":encrypted.map { String(format: "%02X", $0) }.joined()]))
    }
    static func qqSignature(_ data: Data) -> String {
        let hash = Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined(); let chars = Array(hash)
        let first = [23,14,6,36,16,40,7,19].compactMap { $0 < chars.count ? String(chars[$0]) : nil }.joined()
        let last = [16,1,32,12,19,27,8,5].map { String(chars[$0]) }.joined()
        let scramble: [UInt8] = [89,39,179,150,218,82,58,252,177,52,186,123,120,64,242,133,143,161,121,179]
        let bytes = [UInt8](Insecure.SHA1.hash(data: data)).enumerated().map { $0.element ^ scramble[$0.offset] }
        let base64 = Data(bytes).base64EncodedString().filter { !"/+=\\".contains($0) }
        return ("zzc" + first + base64 + last).lowercased()
    }
    private func url(_ base: String, _ query: [String: String]) throws -> URL { var c = URLComponents(string: base)!; c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; guard let url = c.url else { throw malformed() }; return url }
    private func malformed() -> AppFailure { AppFailure(code: "invalidResponse", module: "catalog", platform: platform, userMessage: "\(platform.name)返回的数据不兼容或请求被拒绝，请稍后重试", retryable: true) }
    private func string(_ value: Any?) -> String { if let s = value as? String { return s }; if let n = value as? NSNumber { return n.stringValue }; return "" }
    private func integer(_ value: Any?, fallback: Int = 0) -> Int { Int(string(value)) ?? fallback }
    private func int64(_ value: Any?) -> Int64? { Int64(string(value)) }
    private func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private func names(_ value: Any?) -> [String] { (value as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } }
    private func decodeName(_ text: String) -> String { text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ") }
    private func formatTime(_ time: Int64, fraction: Bool = false) -> String { let seconds = max(0,time) / 1000; return String(format: "%02lld:%02lld", seconds / 60, seconds % 60) + (fraction ? String(format: ".%03lld", max(0,time) % 1000) : "") }
}
