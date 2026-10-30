import Foundation

/// Counts only visible playing time. The caller supplies a monotonic clock.
struct RecordRotationClock {
    static let degreesPerSecond: Double = 15
    private var accumulated: Double = 0
    private var startedAt: TimeInterval?
    var isRunning: Bool { startedAt != nil }
    func angle(at time: TimeInterval) -> Double {
        let elapsed=startedAt.map { max(0,time-$0) } ?? 0
        return (accumulated+elapsed*Self.degreesPerSecond).truncatingRemainder(dividingBy:360)
    }
    mutating func setRunning(_ running: Bool, at time: TimeInterval) {
        if running {
            if startedAt == nil { startedAt=time }
        } else if startedAt != nil {
            accumulated=angle(at:time);startedAt=nil
        }
    }
}
