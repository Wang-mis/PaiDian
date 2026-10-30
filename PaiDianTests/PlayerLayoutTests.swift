import XCTest
import SwiftUI
@testable import PaiDian

@MainActor final class PlayerLayoutTests: XCTestCase {
    func testRecordRotationDoesNotCatchUpAfterLyrics() {
        var rotation=RecordRotationClock()
        rotation.setRunning(true,at:0)
        XCTAssertEqual(rotation.angle(at:2),30,accuracy:0.001)
        rotation.setRunning(false,at:2)
        XCTAssertEqual(rotation.angle(at:602),30,accuracy:0.001,"歌词页停留十分钟不应累积旋转")
        rotation.setRunning(true,at:602)
        XCTAssertEqual(rotation.angle(at:602),30,accuracy:0.001,"返回封面应延续隐藏时的角度")
        XCTAssertEqual(rotation.angle(at:602.25),33.75,accuracy:0.001,"切换过渡期间也只能按正常速度旋转")
        rotation.setRunning(true,at:603)
        XCTAssertEqual(rotation.angle(at:603),45,accuracy:0.001,"重复播放状态不能重置计时")
        rotation.setRunning(false,at:603)
        rotation.setRunning(false,at:903)
        XCTAssertEqual(rotation.angle(at:903),45,accuracy:0.001,"暂停、后台和重复隐藏不应推进角度")
        rotation.setRunning(true,at:903)
        XCTAssertEqual(rotation.angle(at:927),45,accuracy:0.001,"完整一周后的角度应连续等价")
    }
    func testRecordRotationRapidVisibilityAndClockBounds() {
        var rotation=RecordRotationClock()
        for index in 0..<100 {
            let start=Double(index)*100
            rotation.setRunning(true,at:start)
            rotation.setRunning(false,at:start+0.1)
        }
        XCTAssertFalse(rotation.isRunning)
        XCTAssertEqual(rotation.angle(at:20_000),150,accuracy:0.001,"快速切换只计算可见的十秒")
        rotation.setRunning(true,at:20_000)
        XCTAssertEqual(rotation.angle(at:19_999),150,accuracy:0.001,"意外早于起点的时间不能倒转")
    }
    func testPlayerFitsPortraitViewports() async throws {
        for size in [CGSize(width:375,height:667), CGSize(width:393,height:852), CGSize(width:430,height:932)] {
            try await render(size:size,failed:false,dynamicType:.large)
            try await render(size:size,failed:false,dynamicType:.large,playing:true)
            try await render(size:size,failed:true,dynamicType:.xxxLarge)
        }
    }
    func testSharedControlsStayFixedAcrossDisplayTransitions() async throws {
        for size in [CGSize(width:375,height:667),CGSize(width:393,height:852),CGSize(width:430,height:932)] {
            for failed in [false,true] {
                let model=AppModel(),presentation=PlayerPresentation(),probe=PlayerFrameProbe()
                var track=testTrack("transition",platform:.wy);track.title="切换时保持位置不变的较长歌曲名称";track.artists=["测试歌手"]
                let entry=QueueEntry(track:track)
                model.playback=PlaybackViewState(status:failed ? .failed : .playing,queue:QueueState(entries:[entry],currentEntryID:entry.id),durationMS:263_000)
                model.playback.desiredPlaying = !failed
                if failed { model.playback.failure = .make("音源暂时无法播放，请重试",module:"source",retryable:true) }
                let root=PlayerScreen(presentation:presentation).environment(model).environment(\.dynamicTypeSize,failed ? .xxxLarge : .large)
                    .safeAreaPadding(.top,size.width == 375 ? 20 : 59).safeAreaPadding(.bottom,size.width == 375 ? 0 : 34)
                    .overlayPreferenceValue(PlayerLayoutAnchors.self) { anchors in
                        GeometryReader { geometry in
                            let frames=anchors.mapValues { geometry[$0] }
                            Color.clear.onAppear { probe.frames=frames }.onChange(of:frames) { _,value in probe.frames=value }
                        }.allowsHitTesting(false)
                    }
                let controller=UIHostingController(rootView:root),window=UIWindow(frame:CGRect(origin:.zero,size:size))
                // Test windows acquire the physical device's insets asynchronously. Use explicit
                // per-viewport insets so a system window transition isn't mistaken for UI movement.
                controller.safeAreaRegions=[]
                window.rootViewController=controller;window.isHidden=false
                defer { window.isHidden=true;window.rootViewController=nil }
                controller.view.frame=window.bounds;controller.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(150))
                let baseline=probe.frames
                XCTAssertEqual(Set(baseline.keys),["favorite","progress","transport"])
                presentation.showLyrics=true;try await Task.sleep(for:.milliseconds(125));controller.view.layoutIfNeeded()
                assertFrames(probe.frames,equalTo:baseline)
                if size.width == 393 && !failed { attach(controller.view,name:"transition-halfway") }
                try await Task.sleep(for:.milliseconds(175));controller.view.layoutIfNeeded()
                assertFrames(probe.frames,equalTo:baseline)
                attach(controller.view,name:"lyrics-controls-\(Int(size.width))-\(failed ? "failed" : "normal")")
                presentation.showLyrics=false;try await Task.sleep(for:.milliseconds(60));presentation.showLyrics=true
                try await Task.sleep(for:.milliseconds(300));controller.view.layoutIfNeeded()
                assertFrames(probe.frames,equalTo:baseline)
                XCTAssertEqual(model.playback.queue.currentEntryID,entry.id)
            }
        }
    }
    private func assertFrames(_ actual:[String:CGRect],equalTo expected:[String:CGRect],file:StaticString = #filePath,line:UInt = #line) {
        for key in ["favorite","progress","transport"] {
            guard let a=actual[key],let b=expected[key] else { XCTFail("缺少控件坐标",file:file,line:line);continue }
            XCTAssertEqual(a.minX,b.minX,accuracy:0.5,key,file:file,line:line)
            XCTAssertEqual(a.minY,b.minY,accuracy:0.5,key,file:file,line:line)
            XCTAssertEqual(a.width,b.width,accuracy:0.5,key,file:file,line:line)
            XCTAssertEqual(a.height,b.height,accuracy:0.5,key,file:file,line:line)
        }
    }
    private func attach(_ view:UIView,name:String) {
        let renderer=UIGraphicsImageRenderer(bounds:view.bounds)
        let attachment=XCTAttachment(image:renderer.image { _ in view.drawHierarchy(in:view.bounds,afterScreenUpdates:true) });attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    private func render(size:CGSize, failed:Bool, dynamicType:DynamicTypeSize, playing:Bool = false) async throws {
        let model = AppModel()
        var track = testTrack("167691",platform:.wy); track.title = "天龙八部之宿敌"; track.artists = ["许嵩"];track.albumTitle="苏格拉底没有底"
        let entry = QueueEntry(track:track)
        model.playback = PlaybackViewState(status:failed ? .failed : (playing ? .playing : .paused),queue:QueueState(entries:[entry],currentEntryID:entry.id),positionMS:60_000,durationMS:263_000,canSeek:!failed)
        model.playback.desiredPlaying = playing
        if failed { model.playback.failure = .make("网易云未提供这首歌的播放地址（-110），请更换音源或搜索其他版本",code:"upstreamUnavailable",module:"source") }
        let controller = UIHostingController(rootView:PlayerScreen().environment(model).environment(\.dynamicTypeSize,dynamicType))
        let window = UIWindow(frame:CGRect(origin:.zero,size:size)); window.rootViewController = controller; window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for:.milliseconds(200))
        let fitting = controller.sizeThatFits(in:size)
        XCTAssertLessThanOrEqual(fitting.width,size.width + 1,"播放器不能被大封面背景撑宽")
        XCTAssertLessThanOrEqual(fitting.height,size.height + 1,"播放器高度应适配可用区域")
        let renderer = UIGraphicsImageRenderer(bounds:controller.view.bounds)
        let image = renderer.image { _ in controller.view.drawHierarchy(in:controller.view.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "player-\(Int(size.width))x\(Int(size.height))-\(failed ? "failed-largeText" : (playing ? "playing" : "paused"))"; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor private final class PlayerFrameProbe { var frames: [String:CGRect] = [:] }
