import Foundation
#if !HOST_TESTS
@testable import PaiDian
#endif

@MainActor enum BundledSourceValidation {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "paidian.bundled-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let text = validScript
        let failed = "/**\n * @name 失败样本\n */\nthrow new Error('offline fixture')"
        let entries = [("01.js", text, "本地协议测试"), ("02.js", failed, "失败样本")].map { filename, script, name in
            BundledSourceInstaller.Entry(filename: filename, name: name, originURL: URL(string: "https://example.test/" + filename), sha256: DataDigest.sha256(Data(script.utf8)))
        }
        try Data(text.utf8).write(to: root.appendingPathComponent("01.js"))
        try Data(failed.utf8).write(to: root.appendingPathComponent("02.js"))
        let manifest = BundledSourceInstaller.Manifest(version: 1, preferredDigest: entries[0].sha256, scripts: entries)
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
        let files = try DiskFileStore(root: root.appendingPathComponent("files"))
        let repository = MemoryRepository(), manager = SourceManager(repository: repository, files: files, http: FixedHTTP())
        let installer = BundledSourceInstaller(directory: root, repository: repository, manager: manager, defaults: defaults)
        try await installer.installIfNeeded()
        var rows = await repository.scripts()
        try expect(rows.map(\.digest) == entries.map(\.sha256), "内置顺序或失败条目丢失")
        try expect(rows[1].initializationError != nil && rows[0].originURL == entries[0].originURL, "失败原因或来源丢失")
        let active = await repository.activeScriptID()
        try expect(active == rows[0].id, "默认音源未激活")
        for row in rows { try await manager.delete(scriptID: row.id) }
        try await installer.installIfNeeded()
        rows = await repository.scripts()
        try expect(rows.isEmpty, "已删除的内置音源被重新安装")
        defaults.removePersistentDomain(forName: suite)
        let custom = SourceScript(name: "用户自定义", fileKey: "scripts/custom", digest: "custom")
        try await repository.save(custom)
        try await installer.installIfNeeded()
        rows = await repository.scripts()
        try expect(rows.map(\.id) == [custom.id], "升级覆盖了用户音源")
        try await repository.delete(custom.id)
        // Simulate interruption after importing the first source: resume without duplicates.
        defaults.set("installing", forKey: BundledSourceInstaller.stateKey)
        _ = try await manager.importScript(SourceImport(url: root.appendingPathComponent("01.js")))
        try await installer.installIfNeeded()
        rows = await repository.scripts()
        try expect(rows.map(\.digest) == entries.map(\.sha256), "中断恢复重复或丢失条目")
        for row in rows { try await manager.delete(scriptID: row.id) }
        defaults.removePersistentDomain(forName: suite)
        try Data("tampered".utf8).write(to: root.appendingPathComponent("02.js"))
        do { try await installer.installIfNeeded(); throw ValidationFailure(message: "篡改的内置音源未被拒绝") }
        catch is AppFailure { }
        rows = await repository.scripts()
        try expect(rows.isEmpty, "校验失败前已修改用户数据")
    }
}
