import SwiftUI
import AVKit
import Observation

@MainActor @Observable final class PlayerPresentation {
    var showLyrics = false
}
/// Anchors let layout checks measure the same shared controls across display modes.
struct PlayerLayoutAnchors: PreferenceKey {
    static let defaultValue: [String:Anchor<CGRect>] = [:]
    static func reduce(value:inout [String:Anchor<CGRect>],nextValue:()->[String:Anchor<CGRect>]) { value.merge(nextValue(),uniquingKeysWith: { _,new in new }) }
}

struct Tonearm: View, Animatable {
    var pivot: CGPoint
    var tip: CGPoint
    var playing: Bool
    private var lift: Double
    init(pivot:CGPoint,tip:CGPoint,playing:Bool) { self.pivot=pivot;self.tip=tip;self.playing=playing;self.lift=playing ? 0 : -24 }
    var animatableData: Double { get { lift } set { lift=newValue } }
    var body: some View {
        Canvas { context,size in
            var arm=context;arm.translateBy(x:pivot.x,y:pivot.y);arm.rotate(by:.degrees(lift))
            let vector=CGPoint(x:tip.x-pivot.x,y:tip.y-pivot.y)
            let bend=CGPoint(x:vector.x*0.20,y:vector.y*0.67)
            var path=Path();path.move(to:.zero);path.addLine(to:bend);path.addLine(to:vector)
            arm.stroke(path,with:.color(.white.opacity(0.93)),style:StrokeStyle(lineWidth:4,lineCap:.round,lineJoin:.round))
            arm.stroke(Path(ellipseIn:CGRect(x:-14,y:-14,width:28,height:28)),with:.color(.white.opacity(0.1)),lineWidth:0.7)
            arm.fill(Path(ellipseIn:CGRect(x:-8,y:-8,width:16,height:16)),with:.color(.white))
            arm.fill(Path(ellipseIn:CGRect(x:-3,y:-3,width:6,height:6)),with:.color(Color(white:0.85)))
            arm.translateBy(x:vector.x,y:vector.y);arm.rotate(by:.radians(atan2(vector.y-bend.y,vector.x-bend.x)))
            arm.fill(Path(roundedRect:CGRect(x:-10,y:-6,width:20,height:12),cornerRadius:2),with:.color(.white))
            for x in [3.0,6.0] { var line=Path();line.move(to:CGPoint(x:x,y:-4));line.addLine(to:CGPoint(x:x,y:4));arm.stroke(line,with:.color(.gray.opacity(0.5)),lineWidth:0.7) }
        }.accessibilityHidden(true)
    }
}
struct LyricTimingSheet: View {
    @Binding var offsetMS: Int64
    var save: (Int64) -> Void
    var body: some View {
        VStack(spacing:20) {
            Text("歌词时间调整").font(.headline)
            Text(LyricTiming.description(offsetMS)).font(.title3).monospacedDigit()
            HStack(spacing:20) {
                Button("−0.5 秒") { adjust(-500) }.buttonStyle(.bordered)
                Button("＋0.5 秒") { adjust(500) }.buttonStyle(.bordered)
                Button("重置") { offsetMS=0;save(0) }.buttonStyle(.borderless)
            }.frame(minHeight:44)
            Text("＋表示歌词延后，−表示歌词提前；仅保存到当前歌曲。").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24)
    }
    private func adjust(_ delta:Int64) { offsetMS=LyricTiming.adding(offsetMS,delta);save(offsetMS) }
}
struct PlaybackProgress: View {
    @Binding var value:Double
    var bufferedRanges:[PlaybackTimeRange]=[]
    var duration:Double; var enabled:Bool; var seek:(Double)->Void
    var body:some View {
        GeometryReader { geometry in
            let fraction=min(1,max(0,value/max(1,duration)))
            ZStack(alignment:.leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height:2)
                ForEach(Array(bufferedRanges.enumerated()),id:\.offset) { _,range in
                    let start=min(1,max(0,Double(range.startMS)/max(1,duration)))
                    let end=min(1,max(start,Double(range.endMS)/max(1,duration)))
                    Rectangle().fill(.white.opacity(0.30)).frame(width:geometry.size.width*(end-start),height:2).offset(x:geometry.size.width*start)
                }
                Capsule().fill(.white.opacity(0.44)).frame(width:geometry.size.width*fraction,height:2)
                Circle().fill(.white.opacity(enabled ? 0.85 : 0.40)).frame(width:6,height:6).offset(x:max(0,min(geometry.size.width-6,geometry.size.width*fraction-3)))
            }.frame(height:44).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:0).onChanged { event in if enabled { value=min(1,max(0,event.location.x/max(1,geometry.size.width)))*max(0,duration) } }.onEnded { _ in if enabled { seek(value) } })
        }.frame(height:35).accessibilityElement().accessibilityLabel("播放进度").accessibilityValue(timeLabel(Int64(value)))
            .accessibilityAdjustableAction { direction in guard enabled else { return };let next=min(max(0,duration),max(0,value+(direction == .increment ? 5000 : -5000)));value=next;seek(next) }
    }
}
struct AudioRouteButton:UIViewRepresentable {
    func makeUIView(context:Context)->AVRoutePickerView { let view=AVRoutePickerView();view.tintColor=UIColor.white.withAlphaComponent(0.4);view.activeTintColor = .white;view.accessibilityLabel="音频输出";return view }
    func updateUIView(_ uiView:AVRoutePickerView,context:Context) {}
}

/// Debounces real buffering without adding a second playback state machine.
@MainActor @Observable final class BufferingIndicatorState {
    private(set) var visible=false
    @ObservationIgnored private var task:Task<Void,Never>?
    func update(status:PlaybackStatus,desiredPlaying:Bool) {
        guard status == .buffering,desiredPlaying else { task?.cancel();task=nil;visible=false;return }
        guard task == nil,!visible else { return }
        task=Task { [weak self] in do { try await Task.sleep(for:.milliseconds(500)) } catch { return };guard !Task.isCancelled else { return };self?.visible=true;self?.task=nil }
    }
    func stop() { task?.cancel();task=nil;visible=false }
    isolated deinit { task?.cancel() }
}
struct MiniPlaybackRing:View {
    var positionMS:Int64;var durationMS:Int64;var playing:Bool
    var fraction:Double { durationMS > 0 ? min(1,max(0,Double(positionMS)/Double(durationMS))) : 0 }
    var body:some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.18),lineWidth:1.5)
            Circle().trim(from:0,to:fraction).stroke(.primary.opacity(0.8),style:StrokeStyle(lineWidth:1.5,lineCap:.round)).rotationEffect(.degrees(-90))
            Image(systemName:playing ? "pause.fill" : "play.fill").font(.system(size:11)).offset(x:playing ? 0 : 1)
        }.frame(width:27,height:27)
    }
}
