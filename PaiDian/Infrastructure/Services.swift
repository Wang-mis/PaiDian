import Foundation
import CryptoKit
import Security
import OSLog

final class URLSessionHTTPClient: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) { session = URLSession(configuration: configuration, delegate: HTTPRedirectDelegate(), delegateQueue: nil) }
    func execute(_ payload: HTTPPayload) async throws -> HTTPResult {
        guard ["http", "https"].contains(payload.url.scheme?.lowercased() ?? ""), payload.url.host != nil else { throw AppFailure.make("仅支持 HTTP 或 HTTPS 地址", module: "http") }
        var request = URLRequest(url: payload.url, timeoutInterval: Double(min(60_000, max(1, payload.timeoutMS))) / 1000)
        request.httpMethod = payload.method; request.allHTTPHeaderFields = payload.headers; request.httpBody = payload.body
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw AppFailure.make("服务器响应无效", code: "invalidResponse", module: "http") }
            guard response.expectedContentLength <= payload.maximumBytes else { throw AppFailure.make("服务器响应超过大小限制", module: "http") }
            var body = Data(); body.reserveCapacity(min(payload.maximumBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                if body.count >= payload.maximumBytes { throw AppFailure.make("服务器响应超过大小限制", module: "http") }
                body.append(byte)
            }
            try Task.checkCancellation()
            return HTTPResult(status: response.statusCode, headers: response.allHeaderFields.reduce(into: [:]) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) }, body: body, finalURL: response.url ?? payload.url)
        } catch { if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }; throw error }
    }
    deinit { session.invalidateAndCancel() }
}
private final class HTTPRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard ["http", "https"].contains(request.url?.scheme ?? "") else { completionHandler(nil); return }
        var redirected = request
        if task.currentRequest?.url?.host != request.url?.host {
            for field in ["Authorization", "Cookie", "Proxy-Authorization"] { redirected.setValue(nil, forHTTPHeaderField: field) }
        }
        completionHandler(redirected)
    }
}
enum DataDigest {
    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
actor DiskFileStore: ManagedFileStore {
    let root: URL
    init(root: URL) throws { self.root = root; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func stage(_ data: Data, namespace: String) throws -> String {
        guard ["scripts", "covers"].contains(namespace) else { throw AppFailure.make("文件分类无效", module: "files") }
        let key = "\(namespace)/\(UUID().uuidString)"
        let url = root.appendingPathComponent(key); try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); return key
    }
    private func url(_ key: String) throws -> URL {
        guard key.split(separator: "/").count == 2, !key.contains(".."), !key.hasPrefix("/"), ["scripts", "covers"].contains(String(key.split(separator: "/")[0])) else { throw AppFailure.make("文件标识无效", module: "files") }
        return root.appendingPathComponent(key)
    }
    func read(_ fileKey: String) throws -> Data { try Data(contentsOf: url(fileKey)) }
    func remove(_ fileKey: String) throws { let u = try url(fileKey); if FileManager.default.fileExists(atPath: u.path) { try FileManager.default.removeItem(at: u) } }
}
actor DiskResourceCache: ResourceCache {
    let root: URL; let budget: Int
    private var currentEpoch = UUID()
    func epoch() -> UUID { currentEpoch }
    init(root: URL, budget: Int = 200 * 1024 * 1024) throws { self.root = root; self.budget = budget; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    private func url(_ key: String, _ kind: CacheKind) -> URL { root.appendingPathComponent(kind.rawValue + "-" + DataDigest.sha256(Data(key.utf8))) }
    func read(key: String, kind: CacheKind) throws -> Data? {
        let path = url(key, kind); guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path); try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path); return data
    }
    func write(_ data: Data, key: String, kind: CacheKind) throws {
        guard data.count <= budget else { return }; try data.write(to: url(key, kind), options: .atomic)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).map { ($0, try $0.resourceValues(forKeys: keys)) }.sorted { ($0.1.contentModificationDate ?? .distantPast) < ($1.1.contentModificationDate ?? .distantPast) }
        var total = files.reduce(0) { $0 + ($1.1.fileSize ?? 0) }
        for (file, info) in files where total > budget { try FileManager.default.removeItem(at: file); total -= info.fileSize ?? 0 }
    }
    func write(_ data: Data, key: String, kind: CacheKind, epoch: UUID) throws { guard epoch == currentEpoch else { return }; try write(data,key:key,kind:kind) }
    func clear() throws { currentEpoch = UUID(); for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: url) } }
    func size() throws -> Int { try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
}
actor KeychainCredentialStore: CredentialStore {
    // Stable credential namespace: changing the brand must not lose existing keychain items.
    private let service = "AnyListen.credentials"
    func read(key: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }; guard status == errSecSuccess else { throw AppFailure.make("无法读取安全存储", code: "storage", module: "keychain") }; return result as? Data
    }
    func write(_ data: Data?, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        if let data { var values = query; values[kSecValueData as String] = data; values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw AppFailure.make("无法保存安全存储", code: "storage", module: "keychain") }
        }
    }
}
actor DefaultsSettingsStore: SettingsStore {
    // Persisted settings.v1 remains stable across application and module renames.
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> AppSettings { defaults.data(forKey: "settings.v1").flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings() }
    func save(_ settings: AppSettings) throws { defaults.set(try JSONEncoder().encode(settings), forKey: "settings.v1") }
}
actor DiagnosticLogger: DiagnosticLogging {
    private let logger = Logger(subsystem: "PaiDian", category: "diagnostic")
    func record(_ failure: AppFailure) { logger.error("module=\(failure.module, privacy: .public) code=\(failure.code, privacy: .public) request=\(failure.requestID?.uuidString ?? "none", privacy: .public)") }
}
