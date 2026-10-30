import XCTest
import SwiftUI
import AVFoundation
@testable import PaiDian

@MainActor final class QualityLyricsDeviceTests:XCTestCase {
    func testAVPlayerLyricBoundaryPrecision() async throws {
        let previous=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=previous }
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".wav")
        try silentWave().write(to:url);defer { try? FileManager.default.removeItem(at:url) }
        let source=LocalWaveResolver(url:url),engine=AVAudioEngineAdapter(muted:true),repo=MemoryRepository()
        let player=PlaybackCoordinator(source:source,snapshots:repo,history:repo,engine:engine)
        var track=testTrack("clock");track.durationMS=4000
        let entry=QueueEntry(track:track);await player.play(entries:[entry],startEntryID:entry.id)
        defer { player.pause() }
        try await wait { player.state.status == .playing }
        let times:[Int64]=[500,800,1150,1500,1900]
        let doc=LyricDocument(timedLines:times.enumerated().map{LyricLine(startMS:$0.element,text:"Line \($0.offset)")})
        let sync=LyricSynchronizer();defer { sync.stop() }
        sync.configure(document:doc,offsetMS:0,active:true,clock:{player.playbackClock()})
        var seen=Set<Int>(),errors:[Int64]=[]
        let deadline=Date().addingTimeInterval(3)
        while seen.count < times.count,Date() < deadline {
            if let index=sync.currentIndex,!seen.contains(index),let sample=player.playbackClock() {
                seen.insert(index);errors.append(sample.positionMS-(times[index]-60))
            }
            try await Task.sleep(for:.milliseconds(5))
        }
        XCTAssertEqual(seen.count,times.count)
        XCTAssertTrue(errors.allSatisfy{abs($0) <= 100},"高亮应按真实AVPlayer时钟在100ms内切行：\(errors)")
        player.pause();sync.configure(document:doc,offsetMS:0,active:true,clock:{player.playbackClock()})
        XCTAssertNil(sync.nextDelayMS)
        await player.seek(toMS:1200)
        sync.configure(document:doc,offsetMS:500,active:true,clock:{player.playbackClock()})
        XCTAssertEqual(sync.currentIndex,0,"暂停跳转后应按真实位置和用户偏移重新定位")
        let attachment=XCTAttachment(string:"固定本地WAV，逐行提前60ms；5次切行相对AVPlayer实际媒体时间的误差(ms)：\(errors)；暂停和定位同步通过。")
        attachment.name="avplayer-lyric-timing";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testQualityRangeScreens() async throws {
        for size in [CGSize(width:375,height:667),CGSize(width:393,height:852)] {
            let model=AppModel(),entry=QueueEntry(track:testTrack("range"))
            model.playback=PlaybackViewState(status:.playing,queue:QueueState(entries:[entry],currentEntryID:entry.id),positionMS:12000,durationMS:120000,canSeek:true,desiredPlaying:true)
            model.playback.resolvedQuality = .flac;model.playback.resolvedSourceName="测试音源"
            try await attach(NavigationStack{SettingsScreen()}.environment(model),size:size,name:"quality-settings-\(Int(size.width))")
            try await attach(PlayerScreen().environment(model),size:size,name:"quality-readonly-\(Int(size.width))")
        }
    }
    private func attach<V:View>(_ root:V,size:CGSize,name:String) async throws {
        let host=UIHostingController(rootView:root),window=UIWindow(frame:CGRect(origin:.zero,size:size))
        window.rootViewController=host;window.isHidden=false
        defer { window.isHidden=true;window.rootViewController=nil }
        host.view.frame=window.bounds;host.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(150))
        XCTAssertLessThanOrEqual(host.sizeThatFits(in:size).width,size.width+1)
        let renderer=UIGraphicsImageRenderer(bounds:host.view.bounds)
        let item=XCTAttachment(image:renderer.image{_ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)})
        item.name=name;item.lifetime = .keepAlways;add(item)
    }
    private func wait(_ condition:()->Bool) async throws {
        for _ in 0..<600 { if condition(){return};try await Task.sleep(for:.milliseconds(10)) }
        throw ValidationFailure(message:"AVPlayer固定测试媒体未就绪")
    }
    private func silentWave() -> Data {
        let count=16000*4,bytes=count*2
        var data=Data()
        func text(_ s:String){data.append(Data(s.utf8))}
        func u32(_ n:UInt32){var value=n.littleEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}}
        func u16(_ n:UInt16){var value=n.littleEndian;withUnsafeBytes(of:&value){data.append(contentsOf:$0)}}
        text("RIFF");u32(UInt32(36+bytes));text("WAVEfmt ");u32(16);u16(1);u16(1);u32(16000);u32(32000);u16(2);u16(16);text("data");u32(UInt32(bytes));data.append(Data(repeating:0,count:bytes));return data
    }
}
private actor LocalWaveResolver:SourceResolving {
    let url:URL,id=UUID(),generation=UUID()
    init(url:URL){self.url=url}
    func resolve(_ track:Track,request:SourceResolutionRequest) async throws -> ResolvedStream { ResolvedStream(url:url,requestedQuality:request.range.maximum,scriptID:id,sourceGeneration:generation) }
}
