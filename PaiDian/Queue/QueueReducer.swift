import Foundation

struct QueueReducer: QueueReducing {
    func reduce(_ state: QueueState, command: QueueCommand, random: inout any RandomNumberGenerator) throws -> QueueTransition {
        var s = state
        var selection: QueueSelection = .stay
        func shuffled(_ ids: [UUID]) -> [UUID] { ids.shuffled(using: &random) }
        func choose(_ id: UUID?) { s.currentEntryID = id; selection = id.map(QueueSelection.select) ?? .end }
        func consumePriority(excluding: Set<UUID>) -> UUID? {
            while !s.priorityIDs.isEmpty {
                let id = s.priorityIDs.removeFirst()
                s.shuffleRemaining.removeAll { $0 == id }
                if s.entries.contains(where: { $0.id == id }) && !excluding.contains(id) { return id }
            }
            return nil
        }
        func advance(_ direction: AdvanceDirection, _ reason: AdvanceReason, _ excluded: Set<UUID>) {
            guard !s.entries.isEmpty else { return }
            if direction == .next, let id = consumePriority(excluding: excluded) { choose(id); return }
            if s.mode == .shuffle {
                if direction == .previous {
                    if s.historyCursor > 0 { s.historyCursor -= 1; choose(s.historyIDs[s.historyCursor]) }
                    return
                }
                if s.historyCursor + 1 < s.historyIDs.count {
                    var cursor = s.historyCursor + 1
                    while cursor < s.historyIDs.count {
                        let id = s.historyIDs[cursor]
                        if !excluded.contains(id) { s.historyCursor = cursor; choose(id); return }
                        cursor += 1
                    }
                }
                s.shuffleRemaining.removeAll { excluded.contains($0) }
                if s.shuffleRemaining.isEmpty {
                    var candidates = s.entries.map(\.id).filter { !excluded.contains($0) }
                    candidates = shuffled(candidates)
                    if candidates.count > 1, candidates.first == s.currentEntryID { candidates.swapAt(0, 1) }
                    s.shuffleRemaining = candidates
                }
                choose(s.shuffleRemaining.isEmpty ? nil : s.shuffleRemaining.removeFirst())
                return
            }
            if s.mode == .singleRepeat && reason == .natural, let id = s.currentEntryID, !excluded.contains(id) { choose(id); return }
            let current = s.entries.firstIndex { $0.id == s.currentEntryID } ?? (direction == .next ? -1 : 0)
            let step = direction == .next ? 1 : -1
            var index = current
            for _ in 0..<s.entries.count {
                index += step
                if s.mode == .sequential && !(0..<s.entries.count).contains(index) {
                    if reason != .manual { selection = .end }
                    return
                }
                index = (index + s.entries.count) % s.entries.count
                if !excluded.contains(s.entries[index].id) { choose(s.entries[index].id); return }
            }
            selection = .end
        }
        switch command {
        case .replace(let entries, let start):
            guard Set(entries.map(\.id)).count == entries.count, entries.isEmpty || entries.contains(where: { $0.id == start }) else { throw invalid() }
            s = QueueState(entries: entries, currentEntryID: start, mode: s.mode)
            s.shuffleRemaining = shuffled(entries.map(\.id).filter { $0 != start })
            selection = entries.isEmpty ? .end : .select(start!)
        case .select(let id):
            guard s.entries.contains(where: { $0.id == id }) else { throw invalid() }
            if s.historyCursor + 1 < s.historyIDs.count { s.historyIDs = Array(s.historyIDs.prefix(s.historyCursor + 1)) }
            s.shuffleRemaining.removeAll { $0 == id }; s.priorityIDs.removeAll { $0 == id }; choose(id)
        case .commitStarted(let id):
            guard id == s.currentEntryID else { throw invalid() }
            if s.historyIDs.indices.contains(s.historyCursor), s.historyIDs[s.historyCursor] == id { break }
            s.historyIDs = Array(s.historyIDs.prefix(max(0, s.historyCursor + 1)))
            s.historyIDs.append(id); s.historyCursor = s.historyIDs.count - 1
            if s.historyIDs.count > 1000 { s.historyIDs.removeFirst(s.historyIDs.count - 1000); s.historyCursor = s.historyIDs.count - 1 }
        case .setMode(let mode):
            s.mode = mode
            if mode == .shuffle { s.shuffleRemaining = shuffled(s.entries.map(\.id).filter { $0 != s.currentEntryID }) }
        case .insertNext(let tracks):
            let entries = tracks.map { QueueEntry(track: $0) }
            let anchor = s.priorityIDs.last ?? s.currentEntryID
            let index = anchor.flatMap { id in s.entries.firstIndex { $0.id == id } }.map { $0 + 1 } ?? s.entries.count
            s.entries.insert(contentsOf: entries, at: index); s.priorityIDs.append(contentsOf: entries.map(\.id))
            if s.currentEntryID == nil, let first = entries.first { s.priorityIDs.removeAll { $0 == first.id }; choose(first.id) }
        case .move(let ids):
            guard ids.count == s.entries.count, Set(ids) == Set(s.entries.map(\.id)) else { throw invalid() }
            let entries = Dictionary(uniqueKeysWithValues: s.entries.map { ($0.id, $0) }); s.entries = ids.compactMap { entries[$0] }
        case .remove(let ids):
            let oldIndex = s.entries.firstIndex { $0.id == s.currentEntryID } ?? 0
            let removedCurrent = s.currentEntryID.map(ids.contains) ?? false
            let oldHistory = s.historyIDs
            let oldCursor = s.historyCursor
            s.entries.removeAll { ids.contains($0.id) }; s.priorityIDs.removeAll { ids.contains($0) }; s.shuffleRemaining.removeAll { ids.contains($0) }
            s.historyIDs = oldHistory.filter { !ids.contains($0) }
            s.historyCursor = oldHistory.prefix(max(0, oldCursor + 1)).filter { !ids.contains($0) }.count - 1
            if s.entries.isEmpty { s = QueueState(mode: s.mode); selection = .end }
            else if removedCurrent {
                if let id = consumePriority(excluding: []) { choose(id) }
                else if s.mode == .shuffle { advance(.next, .failure, ids) }
                else if oldIndex < s.entries.count { choose(s.entries[oldIndex].id) }
                else if s.mode == .sequential { s.currentEntryID = nil; selection = .end }
                else { choose(s.entries[0].id) }
            }
        case .clear: s = QueueState(mode: s.mode); selection = .end
        case .advance(let direction, let reason, let excluded): advance(direction, reason, excluded)
        }
        return QueueTransition(state: s, selection: selection)
    }
    func repaired(_ state: QueueState) -> QueueState {
        var s = state
        var seen = Set<UUID>(); s.entries = s.entries.filter { seen.insert($0.id).inserted }
        let ids = Set(s.entries.map(\.id))
        s.priorityIDs = s.priorityIDs.filter(ids.contains); s.shuffleRemaining = s.shuffleRemaining.filter(ids.contains)
        let prefix = s.historyIDs.prefix(max(0, s.historyCursor + 1)).filter(ids.contains)
        s.historyIDs = s.historyIDs.filter(ids.contains); s.historyCursor = min(prefix.count - 1, s.historyIDs.count - 1)
        if !ids.contains(s.currentEntryID ?? UUID()) { s.currentEntryID = s.entries.first?.id }
        return s.entries.isEmpty ? QueueState(mode: s.mode) : s
    }
    private func invalid() -> AppFailure { .make("播放队列已变化，请重试", code: "invalidQueue", module: "queue") }
}
