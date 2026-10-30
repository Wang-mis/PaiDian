import XCTest
import SwiftUI
import Network
@testable import PaiDian

@MainActor final class AudioCacheDeviceTests:XCTestCase {
    func testHTTPPlaybackCacheLoopAndOfflineRestore() async throws {
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=idle }
        let server=try await LoopbackAudioServer(wave:wave(seconds:6)).start()
        defer { server.stop() }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let cache=AudioCacheStore(root:root),engine=AVAudioEngineAdapter(muted:true,audioCache:cache),source=LoopbackResolver(url:server.url),repo=MemoryRepository()
        let player=PlaybackCoordinator(source:source,snapshots:repo,history:repo,engine:engine,audioCache:cache)
        defer { player.pause() }
        var track=testTrack("http-cache");track.durationMS=6000
        let entry=QueueEntry(track:track);await player.play(entries:[entry],startEntryID:entry.id)
        try await until { player.state.status == .playing && player.state.positionMS > 100 }
        try await until { (try? await cache.complete(for:track.key,range:QualityRange())) != nil }
        XCTAssertFalse(player.state.bufferedRanges.isEmpty)
        let requests=server.requests
        await player.editQueue(.setMode(.singleRepeat));await player.seekAndPlay(toMS:5600)
        try await until { player.state.status == .playing && player.state.positionMS < 700 }
        let loopCount=await source.count;XCTAssertEqual(loopCount,1,"单曲循环应复用原媒体")
        XCTAssertEqual(server.requests,requests,"整首缓存后循环不增加HTTP请求")
        await player.seek(toMS:1800);player.pause();player.persist()
        try await Task.sleep(for:.milliseconds(100));await player.editQueue(.clear)
        // Restore from an explicit copy: clearing the original queue must not erase the saved test snapshot.
        let restoredRepo=MemoryRepository();try await restoredRepo.savePlayback(PlaybackSnapshot(queue:QueueState(entries:[entry],currentEntryID:entry.id,mode:.singleRepeat),positionMS:1800,requestedQuality:.flac))
        server.stop()
        let reopened=AudioCacheStore(root:root),offline=LoopbackResolver(url:server.url,offline:true)
        let restored=PlaybackCoordinator(source:offline,snapshots:restoredRepo,history:restoredRepo,engine:AVAudioEngineAdapter(muted:true,audioCache:reopened),audioCache:reopened)
        defer { restored.pause() }
        await restored.restore();await restored.resume()
        try await until { restored.state.status == .playing && restored.state.positionMS >= 1900 }
        let offlineCount=await offline.count;XCTAssertTrue(restored.state.isLocallyCached);XCTAssertEqual(offlineCount,0)
        let item=XCTAttachment(string:"本机HTTP WAV：首次播放、完整缓存、单曲循环复用成功；HTTP请求数=\(requests)；关闭HTTP服务后新建缓存与播放器，续播1800ms成功；离线取链次数=0。")
        item.name="audio-cache-loop-offline";item.lifetime = .keepAlways;add(item)
        await restored.editQueue(.clear)
    }
    func testSeekWaitAndBufferIndicator() async throws {
        let fixture=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"seek-marker",withExtension:"m4a"))
        let server=try await LoopbackAudioServer(wave:Data(contentsOf:fixture),gateAfterProbe:true,throttle:true,mime:"audio/mp4").start();defer {server.stop()}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let cache=AudioCacheStore(root:root),engine=AVAudioEngineAdapter(muted:true,audioCache:cache),source=LoopbackResolver(url:server.url),repo=MemoryRepository()
        let player=PlaybackCoordinator(source:source,snapshots:repo,history:repo,engine:engine,audioCache:cache),indicator=BufferingIndicatorState()
        var stage="等待首次播放"
        defer {
            let attachment=XCTAttachment(string:"阶段=\(stage)；状态=\(player.state.status.rawValue)；位置=\(player.state.positionMS)；已发送=\(server.sentBytes)；请求=\(server.requests)；错误=\(player.state.failure?.userMessage ?? "无")")
            attachment.name="unbuffered-seek-stages";attachment.lifetime = .keepAlways;add(attachment)
        }
        player.onStateChange={value in indicator.update(status:value.status,desiredPlaying:value.desiredPlaying)}
        defer {player.pause();indicator.stop()}
        var track=testTrack("stall");track.durationMS=130000;let entry=QueueEntry(track:track)
        await player.play(entries:[entry],startEntryID:entry.id)
        try await until {player.state.status == .playing && player.state.canSeek}
        stage="等待未缓冲跳转提示"
        server.pauseTransfers()
        XCTAssertFalse(engine.isBuffered(atMS:120000),"测试目标必须尚未缓冲")
        let seek=Task{await player.seekAndPlay(toMS:120000)}
        try await until {indicator.visible}
        XCTAssertEqual(player.state.status,.buffering)
        server.openGate();await seek.value
        stage="等待目标位置继续播放"
        try await until {player.state.status == .playing && player.state.positionMS > 120250}
        let report=XCTAttachment(string:"自生成带前置索引M4A：真实AVPlayer定位到未缓冲120000ms，延迟响应期间显示统一缓冲提示；恢复数据后实际播放进度=\(player.state.positionMS)ms；同一音源仅解析一次。")
        report.name="unbuffered-cache-seek";report.lifetime = .keepAlways;add(report)
        let stalledCount=await source.count;XCTAssertFalse(indicator.visible);XCTAssertEqual(stalledCount,1,"缓冲等待不能重新取链")
        player.pause();XCTAssertFalse(indicator.visible)
        await player.editQueue(.clear)
        stage="完成"
    }
    func testProgressAndMiniRingScreens() async throws {
        let indicator=BufferingIndicatorState();indicator.update(status:.buffering,desiredPlaying:true)
        try await Task.sleep(for:.milliseconds(200));XCTAssertFalse(indicator.visible)
        indicator.update(status:.paused,desiredPlaying:false);try await Task.sleep(for:.milliseconds(400));XCTAssertFalse(indicator.visible)
        indicator.update(status:.buffering,desiredPlaying:true);try await Task.sleep(for:.milliseconds(550));XCTAssertTrue(indicator.visible)
        indicator.update(status:.playing,desiredPlaying:true);XCTAssertFalse(indicator.visible)
        XCTAssertEqual(MiniPlaybackRing(positionMS:30000,durationMS:120000,playing:true).fraction,0.25)
        XCTAssertEqual(MiniPlaybackRing(positionMS:30000,durationMS:0,playing:false).fraction,0)
        for width:CGFloat in [375,393] {
            let model=AppModel(),entry=QueueEntry(track:testTrack("buffered"))
            model.playback=PlaybackViewState(status:.playing,queue:QueueState(entries:[entry],currentEntryID:entry.id),positionMS:30000,durationMS:120000,canSeek:true,desiredPlaying:true)
            model.playback.confirmedPositionMS=30000;model.playback.bufferedRanges=[PlaybackTimeRange(startMS:0,endMS:60000),PlaybackTimeRange(startMS:90000,endMS:105000)]
            try await screenshot(PlayerScreen().environment(model),size:CGSize(width:width,height:width == 375 ? 667 : 852),name:"buffered-player-\(Int(width))")
            model.playback.status = .buffering
            if width == 393 { try await screenshot(PlayerScreen().environment(model),size:CGSize(width:width,height:852),name:"buffering-player-393") }
            try await screenshot(MiniPlayer().environment(model).background(Color.black),size:CGSize(width:width,height:80),name:"mini-progress-\(Int(width))")
        }
    }
    private func screenshot<V:View>(_ view:V,size:CGSize,name:String) async throws {
        let host=UIHostingController(rootView:view),window=UIWindow(frame:CGRect(origin:.zero,size:size));host.safeAreaRegions=[];window.rootViewController=host;window.isHidden=false
        defer {window.isHidden=true;window.rootViewController=nil}
        host.view.frame=window.bounds;host.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(name.contains("buffering") ? 650 : 150))
        let attachment=XCTAttachment(image:UIGraphicsImageRenderer(bounds:host.view.bounds).image{_ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true)})
        attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
    private func until(_ condition:() async -> Bool) async throws {
        for _ in 0..<1500 {if await condition(){return};try await Task.sleep(for:.milliseconds(10))}
        throw ValidationFailure(message:"真机音频缓存测试超时")
    }
    private func wave(seconds:Int) -> Data {
        let size=16000*seconds*2;var data=Data()
        func text(_ s:String){data.append(Data(s.utf8))}
        func u32(_ n:UInt32){var v=n.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        func u16(_ n:UInt16){var v=n.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        text("RIFF");u32(UInt32(36+size));text("WAVEfmt ");u32(16);u16(1);u16(1);u32(16000);u32(32000);u16(2);u16(16);text("data");u32(UInt32(size));data.append(Data(repeating:0,count:size));return data
    }
}
private actor LoopbackResolver:SourceResolving {
    let url:URL,offline:Bool,id=UUID(),generation=UUID();private(set) var count=0
    init(url:URL,offline:Bool=false){self.url=url;self.offline=offline}
    func resolve(_ track:Track,request:SourceResolutionRequest) async throws -> ResolvedStream {
        count+=1;if offline{throw URLError(.notConnectedToInternet)}
        return ResolvedStream(url:url,requestedQuality:.flac,scriptID:id,sourceGeneration:generation,sourceName:"Local HTTP")
    }
}
@MainActor final class LoopbackAudioServer {
    let wave:Data;let listener:NWListener;let mime:String
    private(set) var url=URL(string:"http://127.0.0.1:1/audio.wav")!
    private(set) var requests:[String]=[]
    private var transferTasks:[Task<Void,Never>]=[]
    private let throttle:Bool
    private var gate:Bool;private var waiting:[()->Void]=[];private var connections:[NWConnection]=[]
    private var gateOffset:Int
    private(set) var sentBytes=0
    init(wave:Data,gateAfterProbe:Bool=false,throttle:Bool=false,mime:String="audio/wav") throws {self.wave=wave;self.mime=mime;self.gate=gateAfterProbe;self.gateOffset=262144;self.throttle=throttle;listener=try NWListener(using:.tcp,on:.any)}
    func start() async throws -> Self {
        try await withCheckedThrowingContinuation{(continuation:CheckedContinuation<Void,Error>) in
            var completed=false
            listener.stateUpdateHandler={ [weak self] state in MainActor.assumeIsolated {
                guard let self,!completed else{return}
                if case .ready=state,let port=self.listener.port{completed=true;self.url=URL(string:"http://127.0.0.1:\(port.rawValue)/audio.\(self.mime == "audio/mpeg" ? "mp3" : "wav")")!;continuation.resume()}
                if case .failed(let error)=state{completed=true;continuation.resume(throwing:error)}
            }}
            listener.newConnectionHandler={ [weak self] connection in MainActor.assumeIsolated { guard let self else{return};self.connections.append(connection);connection.start(queue:.main);self.read(connection,bytes:Data()) } }
            listener.start(queue:.main)
        }
        return self
    }
    private func read(_ connection:NWConnection,bytes:Data) {
        connection.receive(minimumIncompleteLength:1,maximumLength:65536){ [weak self] data,_,ended,error in MainActor.assumeIsolated {
            guard let self else{return};var all=bytes;if let data{all.append(data)}
            if let text=String(data:all,encoding:.utf8),text.contains("\r\n\r\n"){self.respond(connection,text:text)}
            else if !ended,error == nil,all.count < 65536{self.read(connection,bytes:all)}
        }}
    }
    private func respond(_ connection:NWConnection,text:String) {
        let line=text.components(separatedBy:"\r\n").first{$0.lowercased().hasPrefix("range:")} ?? "Range: bytes=0-\(wave.count-1)"
        requests.append(line)
        let fields=line.components(separatedBy:"=").last!.split(separator:"-",omittingEmptySubsequences:false)
        let start=Int(fields[0]) ?? 0,end=min(wave.count-1,fields.count > 1 ? Int(fields[1]) ?? wave.count-1 : wave.count-1)
        guard start <= end else{connection.cancel();return}
        let head="HTTP/1.1 206 Partial Content\r\nContent-Type: \(mime)\r\nContent-Length: \(end-start+1)\r\nContent-Range: bytes \(start)-\(end)/\(wave.count)\r\nAccept-Ranges: bytes\r\nETag: \"wave-v1\"\r\nConnection: close\r\n\r\n"
        let send:()->Void={ [weak self] in self?.send(connection,head:head,start:start,end:end) }
        if gate && start >= gateOffset {waiting.append(send)} else{send()}
    }
    private func send(_ connection:NWConnection,head:String,start:Int,end:Int) {
        guard throttle else {connection.send(content:Data(head.utf8)+wave.subdata(in:start..<(end+1)),completion:.contentProcessed{_ in connection.cancel()});return}
        connection.send(content:Data(head.utf8),completion:.contentProcessed{_ in})
        transferTasks.append(Task { [weak self] in
            guard let self else{return}
            do {
                for offset in stride(from:start,through:end,by:16384) {
                    while self.gate && offset >= self.gateOffset {try await Task.sleep(for:.milliseconds(20))}
                    try Task.checkCancellation()
                    connection.send(content:self.wave.subdata(in:offset..<min(end+1,offset+16384)),completion:.contentProcessed{_ in})
                    self.sentBytes+=min(end+1,offset+16384)-offset
                    try await Task.sleep(for:.milliseconds(80))
                }
                connection.send(content:nil,contentContext:.finalMessage,isComplete:true,completion:.contentProcessed{_ in connection.cancel()})
            } catch {connection.cancel()}
        })
    }
    func pauseTransfers(){gateOffset=0;gate=true}
    func openGate(){gate=false;let tasks=waiting;waiting=[];tasks.forEach{$0()}}
    func stop(){transferTasks.forEach{$0.cancel()};transferTasks=[];listener.cancel();connections.forEach{$0.cancel()};connections=[];waiting=[]}
}
