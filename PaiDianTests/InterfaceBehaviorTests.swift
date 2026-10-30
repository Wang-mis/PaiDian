import XCTest
import SwiftUI
@testable import PaiDian

@MainActor final class InterfaceBehaviorTests: XCTestCase {
    private let lines = (0..<24).map { index in
        LyricLine(startMS:Int64(index)*3000,text:index == 5 ? "这是一句较长的测试歌词，用于验证换行之后仍能准确居中对齐" : "第 \(index+1) 句测试歌词",translation:index == 5 ? "A longer translated line for layout verification" : nil)
    }
    func testLyricsBrowseConfirmAndTimeoutWhilePaused() async throws {
        let surface=LyricsScrollSurface(frame:CGRect(x:0,y:0,width:393,height:480))
        surface.configure(lines:lines,current:1,offset:500,settings:AppSettings(),canSeek:true,reduceMotion:true)
        surface.layoutIfNeeded()
        var confirmed:[LyricLine]=[];surface.onConfirm={ confirmed.append($0) }
        surface.confirmSelection();XCTAssertTrue(confirmed.isEmpty,"正常跟随时点击不能直接跳转")
        drag(surface,to:5)
        XCTAssertEqual(surface.browsing.phase,.selected)
        XCTAssertEqual(surface.browsing.candidate,5)
        XCTAssertTrue(confirmed.isEmpty,"松手自动对齐不能改变播放进度")
        surface.confirmSelection();XCTAssertEqual(confirmed.map(\.startMS),[15_000]);XCTAssertEqual(surface.browsing.phase,.following)
        drag(surface,to:9)
        try await Task.sleep(for:.milliseconds(5200))
        XCTAssertEqual(surface.browsing.phase,.following,"暂停时也必须按时恢复，不依赖播放器进度更新")
        XCTAssertEqual(confirmed.count,1)
        drag(surface,to:4);surface.invalidate()
        XCTAssertEqual(surface.browsing.phase,.following)
    }
    func testLyricsWithoutSeekAndSettingsReflow() {
        let surface=LyricsScrollSurface(frame:CGRect(x:0,y:0,width:375,height:360))
        surface.configure(lines:lines,current:0,offset:-500,settings:AppSettings(),canSeek:false,reduceMotion:true);surface.layoutIfNeeded()
        var count=0;surface.onConfirm={ _ in count+=1 };drag(surface,to:5);surface.confirmSelection();XCTAssertEqual(count,0)
        var settings=AppSettings();settings.lyricFontSize=24;settings.lyricLineSpacing=28;settings.lyricCurrentLineScale=1.25
        surface.configure(lines:lines,current:5,offset:1000,settings:settings,canSeek:true,reduceMotion:true);surface.layoutIfNeeded()
        XCTAssertEqual(surface.browsing.phase,.following)
        drag(surface,to:5);XCTAssertEqual(surface.browsing.candidate,5,"改变字号后应按实际行高重新定位")
        surface.invalidate()
    }
    func testLyricsReferenceStatesFitViewports() {
        for size in [CGSize(width:375,height:400),CGSize(width:393,height:500),CGSize(width:430,height:560)] {
            let surface=LyricsScrollSurface(frame:CGRect(origin:.zero,size:size));surface.backgroundColor=UIColor(red:0.16,green:0.10,blue:0.09,alpha:1)
            surface.configure(lines:lines,current:3,offset:500,settings:AppSettings(),canSeek:true,reduceMotion:true);surface.layoutIfNeeded()
            attach(surface,name:"lyrics-\(Int(size.width))-following")
            drag(surface,to:5);attach(surface,name:"lyrics-\(Int(size.width))-selected")
            let stack=surface.scrollView.subviews.compactMap { $0 as? UIStackView }.first!
            let row=stack.arrangedSubviews[5].convert(stack.arrangedSubviews[5].bounds,to:surface)
            XCTAssertEqual(row.midY,size.height/2,accuracy:1,"选中行应对齐中央横线")
            surface.invalidate()
        }
    }
    func testPlaybackInsetReservesScrollableBottom() async throws {
        for kind in 0..<3 {
            let model=AppModel();model.isStarting=false
            let entry=QueueEntry(track:testTrack("inset"));model.playback=PlaybackViewState(queue:QueueState(entries:[entry],currentEntryID:entry.id))
            let content=Group {
                if kind == 0 { ScrollView { VStack { ForEach(0..<60) { Text("内容 \($0)").frame(maxWidth:.infinity,minHeight:44) } } } }
                else if kind == 1 { List(0..<60,id:\.self) { Text("内容 \($0)").frame(minHeight:44) } }
                else { Form { ForEach(0..<60) { Text("内容 \($0)").frame(minHeight:44) } } }
            }.playbackInset().environment(model)
            let controller=UIHostingController(rootView:NavigationStack { content.navigationTitle("底部布局验证") })
            let window=UIWindow(frame:CGRect(x:0,y:0,width:393,height:852));window.rootViewController=controller;window.isHidden=false
            defer { window.isHidden=true;window.rootViewController=nil }
            controller.view.frame=window.bounds;controller.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(250));controller.view.layoutIfNeeded()
            let scrolls=descendants(controller.view).compactMap { $0 as? UIScrollView }.filter { $0.bounds.height > 200 }
            XCTAssertFalse(scrolls.isEmpty)
            for scroll in scrolls {
                // Inset may shrink the viewport or be expressed as a scroll content inset.
                let rect=scroll.convert(scroll.bounds,to:controller.view)
                let occupied=controller.view.bounds.height-(rect.maxY-scroll.adjustedContentInset.bottom)
                XCTAssertGreaterThanOrEqual(occupied,66,"底部播放器必须占据真实布局空间（类型 \(kind)）")
            }
            attach(controller.view,name:"bottom-inset-\(kind)")
        }
    }
    private func drag(_ surface:LyricsScrollSurface,to index:Int) {
        surface.scrollViewWillBeginDragging(surface.scrollView)
        surface.layoutIfNeeded()
        let stack=surface.scrollView.subviews.compactMap { $0 as? UIStackView }.first!
        let row=stack.arrangedSubviews[index]
        surface.scrollView.setContentOffset(CGPoint(x:0,y:row.frame.midY-surface.bounds.height/2),animated:false)
        surface.scrollViewDidScroll(surface.scrollView)
        surface.scrollViewDidEndDragging(surface.scrollView,willDecelerate:false)
    }
    private func descendants(_ view:UIView)->[UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func attach(_ view:UIView,name:String) {
        let renderer=UIGraphicsImageRenderer(bounds:view.bounds)
        let attachment=XCTAttachment(image:renderer.image { context in view.layer.render(in:context.cgContext) });attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
}

