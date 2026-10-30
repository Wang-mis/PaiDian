import Foundation

/// User adjustment is applied after the LRC file's own offset, without mutating the cached document.
enum LyricTiming {
    static func adding(_ time: Int64, _ offset: Int64) -> Int64 {
        let result = time.addingReportingOverflow(offset)
        return result.overflow ? (offset > 0 ? .max : .min) : result.partialValue
    }
    static func index(in document: LyricDocument, positionMS: Int64, offsetMS: Int64) -> Int? {
        let result = positionMS.subtractingReportingOverflow(offsetMS)
        let adjusted = result.overflow ? (offsetMS < 0 ? Int64.max : Int64.min) : result.partialValue
        return LRCParser().lineIndex(in: document, positionMS: adjusted)
    }
    static func seekTime(for line: LyricLine, offsetMS: Int64, durationMS: Int64) -> Int64 {
        min(max(0,durationMS),max(0,adding(line.startMS,offsetMS)))
    }
    static func description(_ offsetMS: Int64) -> String {
        guard offsetMS != 0 else { return "未调整" }
        return String(format: "%@ %.1f 秒", offsetMS > 0 ? "延后" : "提前", abs(Double(offsetMS)) / 1000)
    }
}

struct LyricBrowsingState: Equatable {
    enum Phase: Equatable { case following, dragging, selected }
    private(set) var phase: Phase = .following
    private(set) var candidate: Int?
    mutating func begin() { phase = .dragging; candidate = nil }
    mutating func preview(_ index: Int?) { guard phase != .following else { return }; candidate = index }
    mutating func settle() { phase = candidate == nil ? .following : .selected }
    mutating func follow() { phase = .following; candidate = nil }
    var confirmedIndex: Int? { phase == .selected ? candidate : nil }
}
