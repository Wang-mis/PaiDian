import Foundation
import AVFoundation

// Runs only through the explicit --live-source path. Prints no stream URLs or script bodies.
@MainActor enum LiveValidation {
    static func run(path: String) async throws {
        let data = try Data(contentsOf:URL(fileURLWithPath:path)); guard let text = String(data:data,encoding:.utf8) else { throw ValidationFailure(message:"脚本不是 UTF-8") }
        let meta = SourceManager.metadata(text), script = SourceScript(name:meta["name"] ?? "未命名",version:meta["version"],author:meta["author"],description:meta["description"],homepage:meta["homepage"],fileKey:"scripts/temporary",digest:DataDigest.sha256(data))
        let compatibility = CommandLine.arguments.contains("--ecb-compat")
        let tracing = CommandLine.arguments.contains("--trace-source")
        let runtime = ScriptRuntime(http:tracing ? TracingHTTP() : URLSessionHTTPClient(),ecbPKCS7:compatibility); let capabilities = try await runtime.initialize(script:script,text:text)
        print("SOURCE \(script.name) \(script.version ?? "") sha256=\(script.digest)")
        print("INITIALIZED \(capabilities.platforms.keys.map(\.rawValue).sorted().joined(separator:","))")
        print("ECB_COMPATIBILITY \(compatibility)")
        func argument(_ name:String) -> String? { guard let i=CommandLine.arguments.firstIndex(of:name),CommandLine.arguments.indices.contains(i+1) else{return nil};return CommandLine.arguments[i+1] }
        let query=argument("--query") ?? "晴天"
        for platform in MusicPlatform.allCases where argument("--platform").map({$0 == platform.rawValue}) ?? true {
            print("PROBE \(platform.rawValue)")
            let provider = PlatformCatalog(platform:platform,http:URLSessionHTTPClient())
            do {
                let page = try await provider.search(query:query,page:1,pageSize:10)
                print("SEARCH \(platform.rawValue) count=\(page.tracks.count) more=\(page.hasMore)")
                guard let track = argument("--track-id").flatMap({ id in page.tracks.first(where:{$0.key.providerID == id}) }) ?? (argument("--track-id") == nil ? page.tracks.first(where:{$0.title == query}) ?? page.tracks.first : nil), let quality = AudioQuality.allCases.first(where:{ capabilities.platforms[platform]?.qualities.contains($0) == true }) else { print("RESOLVE \(platform.rawValue) SKIP no track/capability"); continue }
                print("TRACK \(track.title) artist=\(track.artistText) id=\(track.key.providerID)")
                do { let url = try await runtime.resolve(track,quality:quality); print("RESOLVE \(platform.rawValue) OK quality=\(quality.rawValue)"); await probeAudio(url,platform:platform) }
                catch { let code = (error as? AppFailure)?.code ?? String(describing:type(of:error)); let message = error.localizedDescription.replacingOccurrences(of:#"https?://\S+"#,with:"[URL]",options:.regularExpression).replacingOccurrences(of:#"[A-Za-z0-9_+/=-]{32,}"#,with:"[REDACTED]",options:.regularExpression); print("RESOLVE \(platform.rawValue) FAIL \(code) \(String(message.prefix(180)))") }
                do { let raw = try await provider.fetchLyrics(track), document = try LRCParser().parse(raw); print("LYRICS \(platform.rawValue) lines=\(document.timedLines.count) plain=\(document.plainText != nil)") }
                catch { print("LYRICS \(platform.rawValue) FAIL \((error as? AppFailure)?.code ?? "network")") }
            } catch { print("SEARCH \(platform.rawValue) FAIL \((error as? AppFailure)?.code ?? "network")") }
        }
        await runtime.invalidate()
    }
    static func probeAudio(_ url: URL, platform: MusicPlatform) async {
        let session = URLSession(configuration:.ephemeral); defer { session.invalidateAndCancel() }
        do { var request = URLRequest(url:url,timeoutInterval:15); request.setValue("bytes=0-4095",forHTTPHeaderField:"Range")
            let (bytes,response) = try await session.bytes(for:request); var prefix = Data(); for try await byte in bytes { prefix.append(byte); if prefix.count >= 4096 { break } }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let format = prefix.starts(with:Data("fLaC".utf8)) ? "flac" : prefix.starts(with:Data("ID3".utf8)) ? "mp3" : "unclassified"
            print("AUDIO \(platform.rawValue) status=\(status) prefixBytes=\(prefix.count) format=\(format) mime=\(response.mimeType ?? "unknown")")
            if CommandLine.arguments.contains("--verify-player"), [200,206].contains(status), prefix.count >= 4096 { await verifyPlayer(url,platform:platform) }
        } catch { print("AUDIO \(platform.rawValue) FAIL network code=\((error as? URLError)?.code.rawValue ?? (error as NSError).code)") }
    }
    private static func verifyPlayer(_ url: URL, platform: MusicPlatform) async {
        let player = AVPlayer(url:url); player.isMuted = true; player.play(); defer { player.pause(); player.replaceCurrentItem(with:nil) }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if player.currentItem?.status == .failed { print("PLAYER \(platform.rawValue) FAIL decode/load"); return }
            if player.timeControlStatus == .playing, player.currentTime().seconds >= 0.5 {
                let duration = player.currentItem?.duration.seconds ?? 0
                print("PLAYER \(platform.rawValue) OK advanced=true durationSeconds=\(duration.isFinite ? Int(duration) : 0)"); return
            }
            try? await Task.sleep(for:.milliseconds(200))
        }
        print("PLAYER \(platform.rawValue) FAIL timeout")
    }
}

private struct TracingHTTP: HTTPClient {
    private let base=URLSessionHTTPClient()
    func execute(_ request:HTTPPayload) async throws -> HTTPResult {
        let host=request.url.host ?? "unknown"
        print("HTTP BEGIN \(request.method) host=\(host) bytes=\(request.body?.count ?? 0)")
        let response: HTTPResult
        do { response = try await base.execute(request) }
        catch { print("HTTP FAIL host=\(host) code=\((error as? URLError)?.code.rawValue ?? (error as NSError).code)"); throw error }
        print("HTTP END host=\(host) status=\(response.status) bytes=\(response.body.count)")
        if let object=(try? JSONSerialization.jsonObject(with:response.body)) as? [String:Any] {
            print("HTTP JSON keys=\(object.keys.sorted().joined(separator:","))")
            if let code=object["code"] as? NSNumber {print("HTTP JSON code=\(code)")}
            if let rows=object["data"] as? [[String:Any]],let row=rows.first {
                print("HTTP JSON data.keys=\(row.keys.sorted().joined(separator:",")) urlType=\(row["url"].map{String(describing:type(of:$0))} ?? "missing")")
                for key in ["code","fee","payed","br","size"] { if let number=row[key] as? NSNumber {print("HTTP SONG \(key)=\(number)")} }
            }
        }
        return response
    }
}
