import Foundation

/// Imports the release's source snapshot once, without replacing an existing user's sources.
actor BundledSourceInstaller {
    struct Manifest: Codable {
        var version: Int
        var preferredDigest: String
        var scripts: [Entry]
    }
    struct Entry: Codable {
        var filename: String
        var name: String
        var version: String?
        var author: String?
        var originURL: URL?
        var sha256: String
    }
    static let stateKey = "bundledSources.v1.state"
    private let directory: URL
    private let repository: any SourceRepository
    private let manager: any SourceManaging
    private let defaults: UserDefaults

    init(directory: URL, repository: any SourceRepository, manager: any SourceManaging, defaults: UserDefaults) {
        self.directory = directory; self.repository = repository; self.manager = manager; self.defaults = defaults
    }

    func installIfNeeded() async throws {
        if defaults.string(forKey: Self.stateKey) == "complete" { return }
        let existing = try await repository.scripts()
        if defaults.string(forKey: Self.stateKey) == nil && !existing.isEmpty {
            defaults.set("complete", forKey: Self.stateKey); return
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.version == 1, !manifest.scripts.isEmpty,
              Set(manifest.scripts.map(\.filename)).count == manifest.scripts.count,
              Set(manifest.scripts.map(\.sha256)).count == manifest.scripts.count else {
            throw AppFailure.make("内置音源清单无效", module: "source")
        }
        // Validate the whole bundle before changing persistence or executing any script.
        for entry in manifest.scripts {
            guard entry.filename == URL(fileURLWithPath: entry.filename).lastPathComponent,
                  entry.filename.hasSuffix(".js") else { throw AppFailure.make("内置音源路径无效", module: "source") }
            let data = try Data(contentsOf: directory.appendingPathComponent(entry.filename))
            guard data.count <= 2 * 1024 * 1024, DataDigest.sha256(data) == entry.sha256,
                  let text = String(data: data, encoding: .utf8), SourceManager.metadata(text)["name"] == entry.name else {
                throw AppFailure.make("内置音源校验失败：\(entry.name)", module: "source")
            }
        }
        defaults.set("installing", forKey: Self.stateKey)
        for entry in manifest.scripts {
            try Task.checkCancellation()
            let current = try await repository.scripts()
            if current.contains(where: { $0.digest == entry.sha256 }) { continue }
            var script = try await manager.importScript(SourceImport(
                url: directory.appendingPathComponent(entry.filename), retainOnInitializationFailure: true))
            script.originURL = entry.originURL
            try await repository.save(script)
        }
        await manager.restoreActive()
        if try await repository.activeScriptID() == nil,
           let preferred = try await repository.scripts().first(where: { $0.digest == manifest.preferredDigest && $0.initializationError == nil }) {
            // A temporarily unavailable default must not prevent the other sources from being kept.
            do { try await manager.activate(scriptID: preferred.id) }
            catch is CancellationError { throw CancellationError() }
            catch { /* The source list retains its normal retry controls. */ }
        }
        defaults.set("complete", forKey: Self.stateKey)
    }
}
