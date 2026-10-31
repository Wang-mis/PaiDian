import Foundation
import CoreGraphics
import ImageIO
#if !HOST_TESTS
@testable import PaiDian
#endif

@MainActor enum ArtworkValidation {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let context = CGContext(data:nil,width:2,height:2,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        let bytes = NSMutableData()
        let output = CGImageDestinationCreateWithData(bytes,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(output,context.makeImage()!,nil)
        try expect(CGImageDestinationFinalize(output),"无法生成封面样本")
        let png = bytes as Data
        let http = CoverHTTP(png:png), cache = try DiskResourceCache(root:root)
        let providers: [MusicPlatform:any CatalogProvider] = [.kw:PlatformCatalog(platform:.kw,http:http),.kg:PlatformCatalog(platform:.kg,http:http)]
        let loader = ArtworkLoader(cache:cache,http:http,providers:providers)
        var kw = testTrack("1090336"), kg = testTrack("149497",platform:.kg)
        kw.artworkURL = nil; kg.artworkURL = nil
        kg.metadata.payload["hash"] = .string("test-hash"); kg.metadata.payload["albumId"] = .string("503947")
        try await withThrowingTaskGroup(of:Data.self) { group in
            for _ in 0..<10 { group.addTask { try await loader.load(kw) } }
            for try await result in group { try expect(result == png,"并发封面内容错误") }
        }
        var requests = await http.requests
        try expect(requests.filter{$0.url.host == "artistpicserver.kuwo.cn"}.count == 1 && requests.filter{$0.url.host == "img1.kuwo.cn"}.count == 1,"多个封面视图重复请求详情或图片")
        let restarted = ArtworkLoader(cache:cache,http:http,providers:providers)
        let cached = try await restarted.load(kw)
        let cachedRequests = await http.requests
        try expect(cached == png && cachedRequests.count == requests.count,"旧记录重开未命中地址或图片磁盘缓存")
        let kgImage = try await loader.load(kg)
        requests = await http.requests
        let privilege = requests.first{$0.url.host == "media.store.kugou.com"}!
        let body = try JSONSerialization.jsonObject(with:privilege.body!) as! [String:Any]
        let resource = (body["resource"] as! [[String:Any]])[0]
        try expect(kgImage == png && resource["hash"] as? String == "test-hash" && resource["album_audio_id"] as? String == "149497","酷狗封面请求未使用原歌曲身份")
        try expect(requests.contains{$0.url.absoluteString == "https://imge.kugou.com/stdmusic/500/test.jpg"},"酷狗图片尺寸占位符未归一化")
        try await cache.clear()
        await http.failPrimary()
        _ = try await loader.load(kw)
        requests = await http.requests
        try expect(requests.contains{$0.url.host == "m.kuwo.cn"},"酷我主封面接口失败时未回退")
        try await cache.clear()
        await http.returnHTMLOnce()
        _ = try await loader.load(kg)
        let cachedImage = try await cache.read(key:"https://imge.kugou.com/stdmusic/500/test.jpg",kind:.artwork)
        try expect(cachedImage == png,"错误网页被当成封面缓存")
        var stale = kg; stale.artworkURL = URL(string:"https://imge.kugou.com/expired.jpg")
        _ = try await loader.load(stale)
        try expect(stale.artworkURL?.lastPathComponent == "expired.jpg","补查改变了调用方歌曲数据")
    }
    static func live() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let http = URLSessionHTTPClient(), cache = try DiskResourceCache(root:root)
        let providers: [MusicPlatform:any CatalogProvider] = [.kw:PlatformCatalog(platform:.kw,http:http),.kg:PlatformCatalog(platform:.kg,http:http)]
        let loader = ArtworkLoader(cache:cache,http:http,providers:providers)
        for platform in [MusicPlatform.kw,.kg] {
            let page = try await providers[platform]!.search(query:"许嵩",page:1,pageSize:1)
            guard var track = page.tracks.first else { throw ValidationFailure(message:"真实搜索无结果") }
            track.artworkURL = nil // Exercise the same path as an existing saved song with no image.
            let data = try await loader.load(track)
            print("PASS LIVE ARTWORK \(platform.rawValue) bytes=\(data.count)")
        }
    }
}

private actor CoverHTTP: HTTPClient {
    let png: Data
    var requests: [HTTPPayload] = []
    var primaryFails = false
    var htmlOnce = false
    init(png:Data) { self.png = png }
    func failPrimary() { primaryFails = true }
    func returnHTMLOnce() { htmlOnce = true }
    func execute(_ request:HTTPPayload) async throws -> HTTPResult {
        requests.append(request)
        try await Task.sleep(for:.milliseconds(5))
        var status = 200, data = png
        switch request.url.host {
        case "artistpicserver.kuwo.cn":
            data = Data((primaryFails ? "no cover" : "http://img1.kwcdn.kuwo.cn/test.jpg\n").utf8)
        case "m.kuwo.cn": data = Data(#"{"data":{"songinfo":{"pic":"https://img1.kuwo.cn/test.jpg"}}}"#.utf8)
        case "media.store.kugou.com": data = Data(#"{"data":[{"info":{"image":"http://imge.kugou.com/stdmusic/{size}/test.jpg"}}]}"#.utf8)
        default:
            if request.url.lastPathComponent == "expired.jpg" { status = 404 }
            if htmlOnce { htmlOnce = false; data = Data("<html>temporarily unavailable</html>".utf8) }
        }
        return HTTPResult(status:status,headers:[:],body:data,finalURL:request.url)
    }
}
