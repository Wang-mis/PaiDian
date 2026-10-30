import Foundation
import Observation

/// Schedules the next line boundary, then re-reads the media clock instead of trusting timer drift.
@MainActor @Observable final class LyricSynchronizer {
    private(set) var currentIndex:Int?
    @ObservationIgnored private var document=LyricDocument()
    @ObservationIgnored private var offsetMS:Int64=0
    @ObservationIgnored private var readClock:(@MainActor () -> PlaybackClockSample?)?
    @ObservationIgnored private var task:Task<Void,Never>?
    @ObservationIgnored private var revision=UUID()
    @ObservationIgnored private(set) var nextDelayMS:Int64?
    static let lineAdvanceMS:Int64=60
    func configure(document:LyricDocument,offsetMS:Int64,active:Bool,clock:@escaping @MainActor () -> PlaybackClockSample?) {
        stop();self.document=document;self.offsetMS=offsetMS;readClock=clock
        guard active else { return };synchronize(schedule:true)
    }
    func synchronize(schedule:Bool = false) {
        guard let sample=readClock?() else { return }
        let now=LyricTiming.adding(sample.positionMS,Self.lineAdvanceMS)
        currentIndex=LyricTiming.index(in:document,positionMS:now,offsetMS:offsetMS)
        let next=(currentIndex ?? -1)+1
        guard sample.advancing,sample.rate > 0,document.timedLines.indices.contains(next) else { nextDelayMS=nil;return }
        let target=LyricTiming.adding(document.timedLines[next].startMS,offsetMS)
        let delay=Double(target)-Double(now)
        let wait=Int64(min(3_600_000,max(4,(delay/sample.rate).rounded(.up))))
        nextDelayMS=wait
        guard schedule else { return }
        task?.cancel();let id=revision,media=sample.mediaID,key=sample.trackKey
        task=Task { [weak self] in
            do { try await Task.sleep(for:.milliseconds(wait)) } catch { return }
            guard !Task.isCancelled,let self,self.revision == id,let current=self.readClock?(),current.mediaID == media,current.trackKey == key else { return }
            self.synchronize(schedule:true)
        }
    }
    func stop() { revision=UUID();task?.cancel();task=nil;nextDelayMS=nil;readClock=nil }
    isolated deinit { task?.cancel() }
}
