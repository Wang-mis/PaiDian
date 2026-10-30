import Foundation

@MainActor final class SearchService: SearchServing {
    private(set) var snapshot = SearchSnapshot()
    private let providers: [MusicPlatform: any CatalogProvider]; private let history: any SearchHistoryRepository
    private let broadcast = StateBroadcast<SearchSnapshot>()
    private var available = Set<MusicPlatform>(); private var tasks: [MusicPlatform: Task<Void, Never>] = [:]
    init(providers: [MusicPlatform: any CatalogProvider], history: any SearchHistoryRepository) { self.providers = providers; self.history = history }
    func snapshots() -> AsyncStream<SearchSnapshot> { broadcast.stream(initial: snapshot) }
    func cancel() { tasks.values.forEach { $0.cancel() }; tasks.removeAll(); snapshot.revision = UUID() }
    func submit(query: String, selection: SearchSelection) async {
        cancel(); let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let platforms = MusicPlatform.allCases.filter { available.contains($0) && (selection == .all || selection == .platform($0)) }
        snapshot = SearchSnapshot(query: trimmed, selection: selection, groups: platforms.map { PlatformSearchState(platform: $0) })
        publish(); guard !trimmed.isEmpty else { return }
        let revision = snapshot.revision
        try? await history.recordQuery(trimmed)
        guard snapshot.revision == revision else { return }
        for p in platforms { start(p, revision: revision) }
    }
    func updateAvailablePlatforms(_ platforms: Set<MusicPlatform>) async { guard available != platforms else { return }; available = platforms; await submit(query: snapshot.query, selection: snapshot.selection) }
    func loadMore() async { let revision = snapshot.revision; for group in snapshot.groups where group.hasMore && !group.isLoading && group.failure == nil { start(group.platform, revision: revision) } }
    func retry(platform: MusicPlatform) async { start(platform, revision: snapshot.revision) }
    private func start(_ platform: MusicPlatform, revision: UUID) {
        guard let index = snapshot.groups.firstIndex(where: { $0.platform == platform }), !snapshot.groups[index].isLoading, let provider = providers[platform], !snapshot.query.isEmpty else { return }
        let query = snapshot.query, page = snapshot.groups[index].nextPage
        snapshot.groups[index].isLoading = true; snapshot.groups[index].failure = nil; publish()
        tasks[platform] = Task { [weak self] in
            do { let result = try await provider.search(query: query, page: page, pageSize: 30); try Task.checkCancellation()
                guard let self, self.snapshot.revision == revision, let i = self.snapshot.groups.firstIndex(where: { $0.platform == platform }), self.snapshot.groups[i].nextPage == page else { return }
                var keys = Set(self.snapshot.groups[i].tracks.map(\.key)); self.snapshot.groups[i].tracks.append(contentsOf: result.tracks.filter { keys.insert($0.key).inserted }); self.snapshot.groups[i].nextPage += 1; self.snapshot.groups[i].hasMore = result.hasMore; self.snapshot.groups[i].isLoading = false; self.tasks.removeValue(forKey: platform); self.publish()
            } catch { guard !Task.isCancelled, let self, self.snapshot.revision == revision, let i = self.snapshot.groups.firstIndex(where: { $0.platform == platform }) else { return }; self.snapshot.groups[i].isLoading = false; self.snapshot.groups[i].failure = AppFailure.wrap(error, module: "search"); self.tasks.removeValue(forKey: platform); self.publish() }
        }
    }
    private func publish() { broadcast.send(snapshot) }
}
