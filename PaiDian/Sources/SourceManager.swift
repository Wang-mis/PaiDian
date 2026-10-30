import Foundation

actor SourceManager: SourceManaging, SourceResolving {
    private let repository: any SourceRepository; private let files: any ManagedFileStore; private let http: any HTTPClient
    private var snapshot = SourceSnapshot(); private var runtime: ScriptRuntime?
    private var subscribers: [UUID: AsyncStream<SourceSnapshot>.Continuation] = [:]
    private var locked = false; private var waiters: [CheckedContinuation<Void, Never>] = []
    private var updateTask: Task<Void,Never>?
    private var fallbackRuntimes:[UUID:ScriptRuntime] = [:]
    private var resolvingID=UUID()
    init(repository: any SourceRepository, files: any ManagedFileStore, http: any HTTPClient) { self.repository = repository; self.files = files; self.http = http }
    private func lock() async { if !locked { locked = true; return }; await withCheckedContinuation { waiters.append($0) } }
    private func unlock() { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
    func snapshots() -> AsyncStream<SourceSnapshot> {
        let id = UUID(); return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c in subscribers[id] = c; c.yield(snapshot); c.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } } }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }
    private func publish() { snapshot.revision = UUID(); for c in subscribers.values { c.yield(snapshot) } }
    func importScript(_ input: SourceImport) async throws -> SourceScript {
        await lock(); defer { unlock() }; try Task.checkCancellation()
        let data: Data
        if input.url.isFileURL {
            let scoped = input.url.startAccessingSecurityScopedResource(); defer { if scoped { input.url.stopAccessingSecurityScopedResource() } }
            let size = try input.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2 * 1024 * 1024 else { throw AppFailure.make("脚本不能超过 2 MiB", module: "source") }; data = try Data(contentsOf: input.url)
        } else { let response = try await http.execute(HTTPPayload(url: input.url, maximumBytes: 2 * 1024 * 1024)); guard (200..<300).contains(response.status) else { throw AppFailure.make("下载脚本失败（HTTP \(response.status)）", module: "source", retryable: true) }; data = response.body }
        guard data.count <= 2 * 1024 * 1024, let text = String(data: data, encoding: .utf8) else { throw AppFailure.make("请选择 2 MiB 以内的 UTF-8 JavaScript 脚本", module: "source") }
        let metadata = Self.metadata(text)
        guard let name = metadata["name"], !name.isEmpty else { throw AppFailure.make("脚本头缺少 @name", module: "source") }
        let scripts = try await repository.scripts()
        if let id = input.replacementID, !scripts.contains(where: { $0.id == id }) { throw AppFailure.make("待替换音源不存在", module: "source") }
        let key = try await files.stage(data, namespace: "scripts")
        let compatibility = Self.compatibilityPolicy(digest:DataDigest.sha256(data))
        let candidate = ScriptRuntime(http:http,ecbPKCS7:compatibility)
        var script = SourceScript(id: input.replacementID ?? UUID(), name: name, version: metadata["version"], author: metadata["author"], description: metadata["description"], homepage: metadata["homepage"], originURL: input.url.isFileURL ? nil : input.url, fileKey: key, digest: DataDigest.sha256(data))
        script.ecbPKCS7Compatibility = compatibility
        do {
            let capabilities = try await candidate.initialize(script: script, text: text); try Task.checkCancellation()
            script.lastValidatedCapabilities = capabilities; script.lastValidatedAt = Date()
            try await repository.save(script)
            // Persistence is the commit point: finish the in-memory commit even if the caller cancels now.
            let old = runtime
            if snapshot.activeScriptID == script.id { runtime = candidate; snapshot.generation = candidate.generation; snapshot.capabilities = capabilities; snapshot.updateNotice = nil; watchUpdates(candidate) } else { await candidate.invalidate() }
            snapshot.scripts = try await repository.scripts(); snapshot.failure = nil; publish()
            if snapshot.activeScriptID == script.id { await old?.invalidate() }
            await fallbackRuntimes.removeValue(forKey:script.id)?.invalidate()
            snapshot.generation=UUID();publish()
            if let previous = scripts.first(where: { $0.id == script.id }) { try? await files.remove(previous.fileKey) }
            return script
        } catch {
            await candidate.invalidate()
            if input.retainOnInitializationFailure, input.replacementID == nil, !(error is CancellationError), script.lastValidatedAt == nil {
                script.initializationError = error.localizedDescription
                do { try await repository.save(script) } catch { try? await files.remove(key); throw error }
                snapshot.scripts = try await repository.scripts(); publish(); return script
            }
            try? await files.remove(key); throw error
        }
    }
    func activate(scriptID: UUID) async throws {
        await lock(); defer { unlock() }; try await activateLocked(scriptID)
    }
    private func activateLocked(_ id: UUID) async throws {
        var scripts = try await repository.scripts(); guard var script = scripts.first(where: { $0.id == id }) else { throw AppFailure.make("音源不存在", module: "source") }
        let data = try await files.read(script.fileKey); guard let text = String(data: data, encoding: .utf8) else { throw AppFailure.make("脚本文件损坏，请重新导入", module: "source") }
        let candidate = ScriptRuntime(http:http,ecbPKCS7:Self.compatibilityPolicy(digest:script.digest))
        do {
            let capabilities = try await candidate.initialize(script: script, text: text); try Task.checkCancellation()
            script.ecbPKCS7Compatibility=Self.compatibilityPolicy(digest:script.digest);script.initializationError = nil; script.lastValidatedCapabilities = capabilities; script.lastValidatedAt = Date()
            try await repository.save(script); try await repository.setActive(id)
            scripts = scripts.map { $0.id == id ? script : $0 }
            let previous = runtime; runtime = candidate; snapshot = SourceSnapshot(scripts:scripts,activeScriptID:id,generation:candidate.generation,capabilities:capabilities); watchUpdates(candidate); publish(); await previous?.invalidate(); await clearFallbackRuntimes()
        } catch { await candidate.invalidate(); throw error }
    }
    func delete(scriptID: UUID) async throws {
        await lock(); defer { unlock() }; try Task.checkCancellation()
        let scripts = try await repository.scripts(), previous = scripts.first { $0.id == scriptID }
        try await repository.delete(scriptID)
        let old = snapshot.activeScriptID == scriptID ? runtime : nil
        if old != nil { updateTask?.cancel(); runtime = nil; snapshot.activeScriptID = nil; snapshot.generation = UUID(); snapshot.capabilities = SourceCapabilities(); snapshot.updateNotice = nil }
        snapshot.generation=UUID();
        await fallbackRuntimes.removeValue(forKey:scriptID)?.invalidate()
        snapshot.scripts = scripts.filter { $0.id != scriptID }; publish(); await old?.invalidate(); if let previous { try? await files.remove(previous.fileKey) }
    }
    func restoreActive() async {
        await lock(); defer { unlock() }
        do { snapshot.scripts = try await repository.scripts(); if let id = try await repository.activeScriptID() { try await activateLocked(id) } else { publish() } }
        catch { snapshot.failure = AppFailure.wrap(error, module: "source"); publish() }
    }
    static func compatibilityPolicy(digest:String)->Bool {
        // Verified sixyin v1.2.1 needs desktop-style ECB padding. Unknown scripts
        // retain the standard mobile API behavior; names alone are not trusted.
        digest == "a407ffe0ab23c29cd32ce249b83e61c8e2b70719895f16034566ad7557282785"
    }
    func setSourceOrder(scriptIDs:[UUID]) async throws {
        await lock();defer { unlock() };try Task.checkCancellation()
        let scripts=try await repository.scripts(),existing=Set(scripts.map(\.id))
        guard Set(scriptIDs) == existing,scriptIDs.count == existing.count else { throw AppFailure.make("音源列表已变化，请刷新后重新排序",module:"source") }
        try await repository.setSourceOrderIDs(scriptIDs)
        let rows=Dictionary(uniqueKeysWithValues:scripts.map{($0.id,$0)})
        snapshot.scripts=scriptIDs.compactMap{rows[$0]};snapshot.generation=UUID();publish();await clearFallbackRuntimes()
    }
    private func clearFallbackRuntimes() async {
        let old=Array(fallbackRuntimes.values);fallbackRuntimes.removeAll()
        for value in old { await value.invalidate() }
    }
    private func runtimeFor(_ script:SourceScript,generation:UUID) async throws -> ScriptRuntime {
        if script.id == snapshot.activeScriptID,let runtime { return runtime }
        await lock();defer { unlock() };try Task.checkCancellation()
        guard generation == snapshot.generation else { throw CancellationError() }
        if let cached=fallbackRuntimes[script.id] { return cached }
        let text=String(decoding:try await files.read(script.fileKey),as:UTF8.self)
        let candidate=ScriptRuntime(http:http,ecbPKCS7:Self.compatibilityPolicy(digest:script.digest))
        do {
            _ = try await candidate.initialize(script:script,text:text);try Task.checkCancellation()
            guard generation == snapshot.generation else { throw CancellationError() }
            fallbackRuntimes[script.id]=candidate;return candidate
        } catch { await candidate.invalidate();throw error }
    }
    func resolve(_ track:Track,request:SourceResolutionRequest) async throws -> ResolvedStream {
        guard !snapshot.scripts.isEmpty else { throw AppFailure.make("请先导入音源",code:"sourceUnavailable",module:"source") }
        let generation=snapshot.generation,id=UUID();resolvingID=id
        defer { if resolvingID == id { snapshot.resolvingSourceName=nil;snapshot.resolvingQuality=nil;publish() } }
        let scripts=snapshot.scripts
        var failures:[String]=[],failed=Set<SourceQualityKey>()
        for script in scripts where script.initializationError == nil {
            let supported=script.lastValidatedCapabilities?.platforms[track.key.platform]?.qualities ?? []
            let candidates=request.range.descending.map{SourceQualityKey(scriptID:script.id,quality:$0)}.filter {
                supported.contains($0.quality) && !request.excluding.contains($0) && (request.retrying == nil || request.retrying == $0)
            }
            guard !candidates.isEmpty else { continue }
            let candidate:ScriptRuntime
            do { candidate=try await runtimeFor(script,generation:generation) }
            catch is CancellationError { throw CancellationError() }
            catch {
                failed.formUnion(candidates);failures.append(script.name+" · 初始化失败");continue
            }
            for attempt in candidates {
                try Task.checkCancellation();guard generation == snapshot.generation else { throw CancellationError() }
                snapshot.resolvingSourceName=script.name;snapshot.resolvingQuality=attempt.quality;publish()
                do {
                    let url=try await candidate.resolve(track,quality:attempt.quality);try Task.checkCancellation()
                    guard generation == snapshot.generation else { throw CancellationError() }
                    return ResolvedStream(url:url,requestedQuality:attempt.quality,scriptID:script.id,sourceGeneration:generation,sourceName:script.name,failedAttempts:failed)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    guard generation == snapshot.generation else { throw CancellationError() }
                    failed.insert(attempt)
                    let message=AppFailure.wrap(error,module:"source").userMessage
                    failures.append("\(script.name) · \(attempt.quality.rawValue)：\(message)")
                }
            }
        }
        throw AppFailure.make(failures.isEmpty ? "没有剩余音源支持所设音质范围" : "所设范围内的音源均未成功。\n"+failures.prefix(3).joined(separator:"\n"),code:"sourcesExhausted",module:"source",retryable:true)
    }
    static func metadata(_ text: String) -> [String: String] {
        let header = String(text.prefix(8192)); let re = try! NSRegularExpression(pattern: #"(?m)^\s*\*?\s*@(name|version|author|description|homepage)\s+(.+?)\s*$"#)
        var result: [String: String] = [:]
        for match in re.matches(in: header, range: NSRange(header.startIndex..., in: header)) { if let key = Range(match.range(at: 1), in: header), let value = Range(match.range(at: 2), in: header) { result[String(header[key])] = String(header[value]) } }
        return result
    }
    private func watchUpdates(_ runtime: ScriptRuntime) {
        updateTask?.cancel(); let generation = runtime.generation
        updateTask = Task { [weak self] in for await notice in await runtime.updates() { guard !Task.isCancelled else { return }; await self?.receiveUpdate(notice,generation:generation) } }
    }
    private func receiveUpdate(_ notice: SourceUpdateNotice,generation: UUID) { guard snapshot.generation == generation else { return }; snapshot.updateNotice = notice; publish() }
    deinit { updateTask?.cancel();let values=Array(fallbackRuntimes.values)+[runtime].compactMap{$0};Task { for value in values { await value.invalidate() } } }
}
