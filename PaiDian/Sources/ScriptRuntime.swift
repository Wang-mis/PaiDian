import Foundation
import JavaScriptCore

final class ScriptRuntime: @unchecked Sendable {
    let generation = UUID()
    private let queue = DispatchQueue(label: "PaiDian.JavaScript", qos: .userInitiated)
    private let http: any HTTPClient
    private let ecbPKCS7: Bool
    private var context: JSContext?
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var responseFailures: [String: AppFailure] = [:]
    private var requests: [String: Task<Void, Never>] = [:]
    private var timers: [String: DispatchWorkItem] = [:]
    private var invalidated = false
    private var cancelledIDs = Set<String>()
    private var evaluated = false
    private var initializationReply: String?
    private var updateNotice: SourceUpdateNotice?
    private var updateSubscribers: [UUID: AsyncStream<SourceUpdateNotice>.Continuation] = [:]
    init(http: any HTTPClient = URLSessionHTTPClient(), ecbPKCS7: Bool = false) { self.http = http; self.ecbPKCS7 = ecbPKCS7 }
    func initialize(script: SourceScript, text: String) async throws -> SourceCapabilities {
        let response = try await operation(id: "init", timeout: 15) { [self] in
            guard let context = JSContext() else { finish("init", .failure(AppFailure.make("无法创建脚本环境", module: "source"))); return }
            self.context = context
            context.exceptionHandler = { [weak self] context, exception in
                let kind = exception?.objectForKeyedSubscript("name")?.toString() ?? "Error"
                let reason = Self.safeMessage(exception?.objectForKeyedSubscript("message")?.toString() ?? "未知异常")
                let stage = self?.pending["init"] == nil ? "运行" : "初始化"
                #if HOST_TESTS
                let name = exception?.objectForKeyedSubscript("name")?.toString() ?? "Error"
                let message = exception?.objectForKeyedSubscript("message")?.toString() ?? ""
                if name == "ReferenceError", message.range(of: #"^[A-Za-z0-9 _:'-]{1,120}$"#,options:.regularExpression) != nil { print("SCRIPT \(name) \(message)") }
                else { let sanitized = message.replacingOccurrences(of: #"https?://\S+"#,with:"[URL]",options:.regularExpression).replacingOccurrences(of:#"[A-Za-z0-9_+/=-]{32,}"#,with:"[REDACTED]",options:.regularExpression); print("SCRIPT \(name) \(String(sanitized.prefix(200)))") }
                #endif
                context?.exception = nil
                self?.failAll(AppFailure.make("\(script.name)\(stage)失败：\(kind) · \(reason)", code:"scriptException", module:"source", retryable:true))
            }
            let complete: @convention(block) (String, String, String) -> Void = { [weak self] id, value, error in
                if id == "init", let self, !self.evaluated { self.initializationReply = value; return }
                guard let self else { return }
                if error.isEmpty { self.finish(id, .success(value)) }
                else {
                    #if HOST_TESTS
                    let diagnostic = error.replacingOccurrences(of:#"https?://\S+"#,with:"[URL]",options:.regularExpression).replacingOccurrences(of:#"[A-Za-z0-9_+/=-]{32,}"#,with:"[REDACTED]",options:.regularExpression)
                    print("SCRIPT REJECT \(String(diagnostic.prefix(160)))")
                    #endif
                    let generic = ["Error: failed", "failed", "Error: 音源未返回有效播放地址"].contains(error)
                    let fallback = AppFailure.make(generic ? "当前音源未能取得播放地址，请重试或搜索其他版本" : "解析失败：" + Self.safeMessage(error), code:"mediaUnavailable", module:"source", retryable:true)
                    self.finish(id, .failure(self.responseFailures[id] ?? fallback))
                }
            }
            let startHTTP: @convention(block) (String, String) -> Void = { [weak self] id, json in self?.startHTTP(id, json) }
            let cancelHTTP: @convention(block) (String) -> Void = { [weak self] id in self?.requests.removeValue(forKey: id)?.cancel() }
            let setTimer: @convention(block) (String, Double) -> Void = { [weak self] id, ms in
                guard let self else { return }; let work = DispatchWorkItem { [weak self] in self?.timers.removeValue(forKey: id); self?.context?.objectForKeyedSubscript("__fireTimer")?.call(withArguments: [id]) }
                timers[id] = work; queue.asyncAfter(deadline: .now() + min(86_400, max(0, ms / 1000)), execute: work)
            }
            let clearTimer: @convention(block) (String) -> Void = { [weak self] id in self?.timers.removeValue(forKey: id)?.cancel() }
            let compatibility = ecbPKCS7
            let crypto: @convention(block) (String, String) -> String = { op, json in Self.crypto(op, json, ecbPKCS7:compatibility) }
            let update: @convention(block) (String) -> Void = { [weak self] json in
                guard let self, self.updateNotice == nil, let data = json.data(using:.utf8), let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let log = object["log"] as? String else { return }
                let candidate = (object["updateUrl"] as? String).flatMap(URL.init(string:))
                let url = candidate.flatMap { ["http","https"].contains($0.scheme ?? "") && $0.absoluteString.count <= 1024 ? $0 : nil }
                let notice = SourceUpdateNotice(message:String(log.prefix(1024)),url:url); self.updateNotice = notice
                for continuation in self.updateSubscribers.values { continuation.yield(notice) }
            }
            context.setObject(complete, forKeyedSubscript: "__nativeComplete" as NSString)
            context.setObject(startHTTP, forKeyedSubscript: "__nativeHTTP" as NSString)
            context.setObject(cancelHTTP, forKeyedSubscript: "__nativeCancelHTTP" as NSString)
            context.setObject(setTimer, forKeyedSubscript: "__nativeTimer" as NSString)
            context.setObject(clearTimer, forKeyedSubscript: "__nativeClearTimer" as NSString)
            context.setObject(crypto, forKeyedSubscript: "__nativeCrypto" as NSString)
            context.setObject(update, forKeyedSubscript:"__nativeUpdate" as NSString)
            let info: [String: Any] = ["name": script.name, "version": script.version ?? "", "description": script.description ?? "", "author": script.author ?? "", "homepage": script.homepage ?? "", "rawScript": text]
            context.setObject(info, forKeyedSubscript: "__scriptInfo" as NSString)
            context.evaluateScript(Self.bootstrap)
            context.evaluateScript(text, withSourceURL: URL(string: "paidian-source://script.js"))
            evaluated = true
            if let initializationReply, context.exception == nil { finish("init", .success(initializationReply)) }
        }
        guard let data = response.data(using: .utf8), let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let sources = root["sources"] as? [String: [String: Any]] else { throw AppFailure.make("音源未声明平台能力", code: "invalidResponse", module: "source") }
        var capabilities = SourceCapabilities()
        for platform in MusicPlatform.allCases {
            guard let source = sources[platform.rawValue], source["type"] as? String == "music", let actions = source["actions"] as? [String], actions.contains("musicUrl") else { continue }
            let qualities = Set((source["qualitys"] as? [String] ?? []).compactMap(AudioQuality.init(rawValue:)))
            if !qualities.isEmpty { capabilities.platforms[platform] = SourceCapability(actions: ["musicUrl"], qualities: qualities) }
        }
        guard !capabilities.platforms.isEmpty else { throw AppFailure.make("此音源没有支持的在线平台或音质", code: "unsupportedAPI", module: "source") }
        return capabilities
    }
    func resolve(_ track: Track, quality: AudioQuality) async throws -> URL {
        let id = UUID().uuidString
        let metadata = track.metadata.payload
        let encoded = try JSONEncoder().encode(JSONValue.object(metadata))
        let info = try JSONSerialization.jsonObject(with: encoded)
        let request: [String: Any] = ["source": track.key.platform.rawValue, "action": "musicUrl", "info": ["type": quality.rawValue, "musicInfo": info]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let result = try await operation(id: id, timeout: 30) { [self] in context?.objectForKeyedSubscript("__resolve")?.call(withArguments: [id, json]) }
        guard let data = result.data(using: .utf8), let raw = (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) as? String, raw.count <= 2048, let url = URL(string: raw), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else { throw AppFailure.make("音源返回了无效播放地址", code: "invalidResponse", module: "source") }
        return url
    }
    private func operation(id: String, timeout: Double, action: @escaping @Sendable () -> Void) async throws -> String {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
                guard !invalidated, cancelledIDs.remove(id) == nil else { continuation.resume(throwing: CancellationError()); return }
                pending[id] = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(id, .failure(AppFailure.make("音源响应超时", code: "timeout", module: "source", retryable: true))) }
                action()
            } }
        } onCancel: { [self] in queue.async { if self.pending[id] == nil { self.cancelledIDs.insert(id) } else { self.finish(id, .failure(CancellationError())) } } }
    }
    private func finish(_ id: String, _ result: Result<String, Error>) {
        responseFailures.removeValue(forKey:id)
        guard let continuation = pending.removeValue(forKey: id) else { return }; continuation.resume(with: result)
        queue.async { [weak self] in self?.context?.objectForKeyedSubscript("__forget")?.call(withArguments: [id]) }
        if pending.isEmpty { for task in requests.values { task.cancel() }; requests.removeAll() }
    }
    private func failAll(_ error: Error) { for id in Array(pending.keys) { finish(id, .failure(error)) } }
    func updates() async -> AsyncStream<SourceUpdateNotice> {
        await withCheckedContinuation { continuation in queue.async { [self] in
            let id = UUID()
            let stream = AsyncStream<SourceUpdateNotice>(bufferingPolicy:.bufferingNewest(1)) { c in
                guard !invalidated else { c.finish(); return }; updateSubscribers[id] = c; if let updateNotice { c.yield(updateNotice) }
                c.onTermination = { [weak self] _ in self?.queue.async { [weak self] in self?.updateSubscribers.removeValue(forKey:id) } }
            }
            continuation.resume(returning:stream)
        } }
    }
    func invalidate() async { await withCheckedContinuation { continuation in queue.async { [self] in invalidated = true; failAll(CancellationError()); for task in requests.values { task.cancel() }; requests.removeAll(); for timer in timers.values { timer.cancel() }; timers.removeAll(); for c in updateSubscribers.values { c.finish() }; updateSubscribers.removeAll(); context?.exceptionHandler = nil; context = nil; continuation.resume() } } }
    private func startHTTP(_ id: String, _ json: String) {
        // Only attribute an HTTP response when exactly one resolution owns the runtime.
        // A cancelled or concurrent request must never supply the next song's failure.
        let resolutions = pending.keys.filter { $0 != "init" }
        let resolutionID = resolutions.count == 1 ? resolutions.first : nil
        requests[id] = Task { [weak self, http] in
            do {
                let payload = try Self.httpPayload(json)
                let result = try await http.execute(payload); try Task.checkCancellation()
                let contentType = result.headers["content-type"] ?? ""
                let text = String(data: result.body, encoding: .utf8)
                let body: Any = (try? JSONSerialization.jsonObject(with: result.body, options: .fragmentsAllowed)) ?? (text as Any?) ?? [UInt8](result.body)
                let options = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
                let binary = (options?["options"] as? [String: Any])?["binary"] as? Bool ?? false
                let response: [String: Any] = ["statusCode": result.status, "headers": result.headers, "body": body, "raw": [UInt8](result.body), "contentType": contentType, "binary": binary]
                let json = String(decoding: try JSONSerialization.data(withJSONObject: response, options: [.fragmentsAllowed]), as: UTF8.self)
                self?.deliver(id, response: json, error: "", resolutionID:resolutionID, failure:Self.unavailableResponse(result,request:payload))
            } catch { if !Task.isCancelled {
                let code = (error as? URLError)?.code
                let reason = code == .timedOut ? "音源接口连接超时" : (code == .secureConnectionFailed || code == .serverCertificateUntrusted ? "音源接口 TLS 连接失败" : "音源接口网络请求失败")
                let failure = AppFailure.make(reason,code:"sourceNetwork",module:"source",retryable:true)
                self?.deliver(id,response:"null",error:reason,resolutionID:resolutionID,failure:failure)
            } }
        }
    }
    private func deliver(_ id: String, response: String, error: String, resolutionID: String? = nil, failure: AppFailure? = nil) { queue.async { [weak self] in
        guard let self, requests.removeValue(forKey:id) != nil, !invalidated else { return }
        if let resolutionID, pending[resolutionID] != nil, let failure { responseFailures[resolutionID] = failure }
        context?.objectForKeyedSubscript("__deliverHTTP")?.call(withArguments:[id,response,error])
    } }
    private static func unavailableResponse(_ result: HTTPResult, request: HTTPPayload) -> AppFailure? {
        if !(200..<300).contains(result.status) {
            let object = (try? JSONSerialization.jsonObject(with:result.body)) as? [String:Any]
            let unsupported = request.url.host == "music-api.gdstudio.xyz" && object?["detail"] as? String == "Value of `source` is not supported."
            return AppFailure.make(unsupported ? "音源接口不支持此歌曲平台（HTTP 400），请搜索其他平台版本" : "音源接口返回 HTTP \(result.status)",code:unsupported ? "upstreamPlatformUnsupported" : "upstreamHTTP",module:"source",retryable:result.status == 429 || result.status >= 500)
        }
        guard let host = request.url.host?.lowercased(), host == "music.163.com" || host.hasSuffix(".music.163.com"),
              let root = (try? JSONSerialization.jsonObject(with:result.body)) as? [String:Any],
              let rows = root["data"] as? [[String:Any]], rows.count == 1, let row = rows.first,
              row["url"] is NSNull, let code = row["code"] as? Int else { return nil }
        return AppFailure.make("网易云未提供这首歌的播放地址（\(code)），请更换音源或搜索其他版本",code:"upstreamUnavailable",module:"source",retryable:false)
    }
    private static func safeMessage(_ text: String) -> String {
        String(text.replacingOccurrences(of:#"https?://[^\s]+"#,with:"[地址]",options:.regularExpression).replacingOccurrences(of:#"(?i)(token|cookie|authorization|key)\s*[:=]\s*[^\s,;]+"#,with:"$1=[已隐藏]",options:.regularExpression).replacingOccurrences(of:#"[A-Za-z0-9_+/=-]{32,}"#,with:"[已隐藏]",options:.regularExpression).prefix(180))
    }
    static func httpPayload(_ json: String) throws -> HTTPPayload {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], let string = object["url"] as? String, let url = URL(string: string) else { throw AppFailure.make("脚本请求地址无效", module: "source") }
        let options = object["options"] as? [String: Any] ?? [:]
        var payload = HTTPPayload(url: url, method: (options["method"] as? String ?? "GET").uppercased(), headers: options["headers"] as? [String: String] ?? [:], timeoutMS: options["timeout"] as? Int ?? 15_000)
        if let form = options["form"] as? [String: Any] { payload.headers["Content-Type"] = "application/x-www-form-urlencoded"; payload.body = formEncoded(form) }
        else if let form = options["formData"] as? [String: Any] {
            let boundary = UUID().uuidString; payload.headers["Content-Type"] = "multipart/form-data; boundary=\(boundary)"; var body = Data()
            for (key, value) in form.sorted(by: { $0.key < $1.key }) { guard !key.contains("\r"), !key.contains("\n"), !key.contains("\"") else { throw AppFailure.make("表单字段无效", module: "source") }; body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8)) }; body.append(Data("--\(boundary)--\r\n".utf8)); payload.body = body
        } else if let body = options["body"] as? String { payload.body = Data(body.utf8) }
        else if let bytes = options["body"] as? [UInt8] { payload.body = Data(bytes) }
        else if let body = options["body"], !(body is NSNull) { payload.body = try JSONSerialization.data(withJSONObject: body, options: .fragmentsAllowed) }
        return payload
    }
    static func formEncoded(_ form: [String: Any]) -> Data { var components = URLComponents(); components.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }; return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8) }
    private static func crypto(_ operation: String, _ json: String, ecbPKCS7: Bool) -> String {
        do {
            let args = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
            func bytes(_ key: String) -> Data { Data(args[key] as? [UInt8] ?? []) }
            let value: Any
            switch operation {
            case "md5": value = CryptoTools.md5(Data((args["text"] as? String ?? "").utf8))
            case "random": value = [UInt8](try CryptoTools.random(args["size"] as? Int ?? -1))
            case "aes": value = [UInt8](try CryptoTools.aes(bytes("data"), mode: args["mode"] as? String ?? "", key: bytes("key"), iv: bytes("iv"), pkcs7:ecbPKCS7 ? true : nil))
            case "rsa": value = [UInt8](try CryptoTools.rsa(bytes("data"), pem: args["key"] as? String ?? ""))
            case "from":
                let text = args["text"] as? String ?? "", format = args["format"] as? String ?? "utf8"
                let data: Data
                switch format { case "base64": guard let d = Data(base64Encoded: text) else { throw AppFailure.make("Base64 无效") }; data = d
                case "hex": guard text.count % 2 == 0 else { throw AppFailure.make("Hex 无效") }; var d = Data(); var i = text.startIndex; while i < text.endIndex { let end = text.index(i, offsetBy: 2); guard let b = UInt8(text[i..<end], radix: 16) else { throw AppFailure.make("Hex 无效") }; d.append(b); i = end }; data = d
                case "utf8", "utf-8": data = Data(text.utf8)
                default: throw AppFailure.make("不支持的编码") }; value = [UInt8](data)
            case "to": let data = bytes("data"); switch args["format"] as? String ?? "utf8" { case "base64": value = data.base64EncodedString(); case "hex": value = data.map { String(format: "%02x", $0) }.joined(); case "utf8", "utf-8": value = String(decoding: data, as: UTF8.self); default: throw AppFailure.make("不支持的编码") }
            default: throw AppFailure.make("不支持的工具 API")
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: ["value": value]), as: UTF8.self)
        } catch { return String(decoding:(try? JSONSerialization.data(withJSONObject:["error":error.localizedDescription])) ?? Data("{\"error\":\"工具 API 不受支持\"}".utf8),as:UTF8.self) }
    }
    private static let bootstrap = #"""
    (() => {
      let handler, seq = 0, initialized = false, updateSent = false; const callbacks = new Map(), timers = new Map(), alive = new Set();
      const native = (op, args) => { const r = JSON.parse(__nativeCrypto(op, JSON.stringify(args))); if (r.error) throw new Error(r.error); return r.value; };
      const bytes = x => Array.from(typeof x === 'string' ? native('from', {text:x,format:'utf8'}) : (x || []));
      globalThis.__forget = id => alive.delete(id);
      globalThis.__resolve = (id, json) => { alive.add(id); Promise.resolve().then(() => { if (!handler) throw new Error('未注册 request'); return handler(JSON.parse(json)); }).then(value => { if (typeof value !== 'string' || value.length > 2048 || !/^https?:/.test(value)) throw new Error('音源未返回有效播放地址'); if (alive.has(id)) __nativeComplete(id, JSON.stringify(value), ''); }).catch(error => { if (alive.has(id)) __nativeComplete(id, '', String(error)); }); };
      globalThis.__deliverHTTP = (id, json, error) => { const cb = callbacks.get(id); callbacks.delete(id); if (!cb) return; if (error) { cb(new Error(error), null, null); return; } const r = JSON.parse(json); const body = r.binary ? new Uint8Array(r.raw) : r.body; cb(null, {statusCode:r.statusCode,headers:r.headers,body,raw:new Uint8Array(r.raw)}, body); };
      globalThis.__fireTimer = id => { const cb = timers.get(id); timers.delete(id); if (cb) cb(); };
      globalThis.setTimeout = (cb, ms, ...args) => { const id = String(++seq); timers.set(id, () => cb(...args)); __nativeTimer(id, Number(ms)||0); return id; };
      globalThis.clearTimeout = id => { id=String(id); timers.delete(id); __nativeClearTimer(id); };
      globalThis.console = { log(){}, warn(){}, error(){}, info(){} };
      globalThis.lx = {
        version:'2.0.0', env:'mobile', currentScriptInfo:__scriptInfo,
        EVENT_NAMES:Object.freeze({request:'request',inited:'inited',updateAlert:'updateAlert'}),
        on(name, cb) { if (name !== 'request') throw new Error('不支持的事件'); handler=cb; },
        send(name, data) { if (name === 'inited') { if (initialized) return Promise.reject(new Error('禁止重复初始化')); if (!handler) throw new Error('未注册 request'); initialized=true; __nativeComplete('init', JSON.stringify(data), ''); } else if (name === 'updateAlert' && !updateSent) { updateSent=true; __nativeUpdate(JSON.stringify(data)); } return Promise.resolve(); },
        request(url, options, cb) { const id=String(++seq); callbacks.set(id,cb); __nativeHTTP(id,JSON.stringify({url,options:options||{}})); return () => {callbacks.delete(id); __nativeCancelHTTP(id);}; },
        utils: {
          buffer:{from:(text,format='utf8')=>new Uint8Array(Array.isArray(text) ? text : native('from',{text,format})),bufToString:(data,format='utf8')=>native('to',{data:bytes(data),format})},
          crypto:{md5:text=>native('md5',{text}),randomBytes:size=>new Uint8Array(native('random',{size})),aesEncrypt:(data,mode,key,iv)=>new Uint8Array(native('aes',{data:bytes(data),mode,key:bytes(key),iv:bytes(iv)})),rsaEncrypt:(data,key)=>new Uint8Array(native('rsa',{data:bytes(data),key}))}
        }
      };
    })();
    """#
}
