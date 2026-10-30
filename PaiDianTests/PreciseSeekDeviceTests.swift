import XCTest
import AVFoundation
import MediaToolbox
import Accelerate
import UIKit
@testable import PaiDian

/// Compare decoded content against a sequential decode, independently of the reported seek clock.
@MainActor final class PreciseSeekDeviceTests: XCTestCase {
    func testGeneratedFLACSeekContent() async throws {
        let url=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"seek-marker",withExtension:"flac"))
        try await verify(url:url,routes:[.file,.resource,.http],name:"generated-flac")
    }

    func testExistingSongFLACSeekContent() async throws {
        guard ProcessInfo.processInfo.environment["PAIDIAN_LIVE_SOURCE_VALIDATION"] == "1" else { throw XCTSkip("需明确启用现有歌曲真机验证") }
        let root=URL.cachesDirectory.appendingPathComponent("AnyListenAudio")
        let records=try JSONDecoder().decode([AudioCacheRecord].self,from:Data(contentsOf:root.appendingPathComponent("index.json")))
        guard let record=records.first(where:{$0.trackKey == TrackKey(platform:.wy,providerID:"4872687") && $0.complete}) else { throw XCTSkip("手机没有《同花顺》完整缓存") }
        let url=root.appendingPathComponent(record.id.uuidString+"."+record.fileExtension)
        // Read-only: no source requests, cache-index writes, user queue edits or audio attachments.
        try await verify(url:url,routes:[.file,.resource],name:"existing-song-flac")
    }

    private enum Route:String { case file,resource,http }
    private func verify(url:URL,routes:[Route],name:String) async throws {
        let idle=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=idle }
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try await AVAudioSession.sharedInstance().setActive(true)
        let reference=try await SequentialAudio.read(url)
        let bytes=try Data(contentsOf:url)
        var report=["逐块波形比对；参考为完整顺播解码，不以seek回调或媒体时钟代替内容验证。",
                    "样本=\(name)，采样率=\(reference.rate)，顺播样本数=\(reference.samples.count)，文件字节=\(bytes.count)。"]
        for route in routes {
            let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at:root) }
            let prepareStart=Date()
            var loader:AudioResourceLoader?,server:LoopbackAudioServer?
            defer { loader?.stop();server?.stop() }
            let asset:AVURLAsset
            switch route {
            case .file: asset=PlaybackAsset.make(url:url)
            case .resource:
                let track=testTrack("precise-content")
                let stream=ResolvedStream(url:URL(string:"https://local-fixture.invalid/audio.flac")!,requestedQuality:.flac,scriptID:UUID(),sourceGeneration:UUID())
                let value=AudioResourceLoader(store:AudioCacheStore(root:root),context:AudioCacheContext(track:track,stream:stream),downloader:FixtureAudioDownloader(bytes:bytes))
                loader=value;asset=try await value.prepare()
            case .http:
                let value=try await LoopbackAudioServer(wave:bytes,mime:"audio/flac").start();server=value
                asset=PlaybackAsset.make(url:value.url)
            }
            let tracks=try await asset.loadTracks(withMediaType:.audio)
            let capture=DecodedAudioCapture(),tap=try capture.makeTap()
            let input=AVMutableAudioMixInputParameters(track:try XCTUnwrap(tracks.first));input.audioTapProcessor=tap
            let mix=AVMutableAudioMix();mix.inputParameters=[input]
            let item=AVPlayerItem(asset:asset);item.audioMix=mix
            let player=AVPlayer(playerItem:item);player.isMuted=true
            defer { player.pause();player.replaceCurrentItem(with:nil) }
            try await until {item.status != .unknown}
            XCTAssertEqual(item.status,.readyToPlay)
            guard item.status == .readyToPlay else {throw ValidationFailure(message:"音频未就绪")}
            let readyMS=Int(Date().timeIntervalSince(prepareStart)*1000)
            var errors=[Double]()
            for target in [15.34,60.0,15.34,120.0,15.34] {
                player.pause()
                let completed=await player.seek(to:CMTime(seconds:target,preferredTimescale:1000),toleranceBefore:.zero,toleranceAfter:.zero)
                XCTAssertTrue(completed)
                capture.reset();player.play()
                try await Task.sleep(for:.milliseconds(1500));player.pause()
                let blocks=capture.blocks.filter{$0.position >= target+0.35 && $0.position < target+1 && $0.samples.count >= 1024}
                XCTAssertGreaterThanOrEqual(blocks.count,3,"必须得到可核对的真实音频块")
                // Audio-mix preroll may contain muted transition blocks. Sample stable output after 350 ms.
                for block in blocks.prefix(3) {
                    XCTAssertEqual(block.rate,reference.rate)
                    let match=reference.match(block)
                    if match.correlation <= 0.995 && name == "generated-flac" {
                        let attachment=XCTAttachment(data:block.samples.withUnsafeBytes{Data($0)},uniformTypeIdentifier:"public.data")
                        attachment.name="diagnostic-\(route.rawValue)-\(target)-\(block.position)-\(block.rate).f32";attachment.lifetime = .keepAlways;add(attachment)
                    }
                    XCTAssertGreaterThan(match.correlation,0.995,"\(route.rawValue) 目标\(target)s：音频内容未匹配时间戳附近的顺播波形")
                    XCTAssertLessThanOrEqual(abs(match.errorMS),100.0001)
                    errors.append(match.errorMS)
                }
            }
            XCTAssertGreaterThanOrEqual(errors.count,5)
            report.append("\(route.rawValue)：准备至ready=\(readyMS)ms；各音频块内容时间误差(ms)=\(errors.map{String(format:"%.3f",$0)}.joined(separator:","))；最大绝对误差=\(errors.map(abs).max() ?? .infinity)ms。")
        }
        let attachment=XCTAttachment(string:report.joined(separator:"\n"));attachment.name=name+"-seek-content";attachment.lifetime = .keepAlways;add(attachment)
    }
    private func until(_ condition:()->Bool) async throws {
        for _ in 0..<3000 {if condition(){return};try await Task.sleep(for:.milliseconds(10))}
        throw ValidationFailure(message:"精确定位测试媒体准备超时")
    }
}

private struct FixtureAudioDownloader:AudioDownloading {
    let bytes:Data
    func transfer(_ request:URLRequest,response:@escaping @Sendable (HTTPURLResponse) async throws -> Void,data:@escaping @Sendable (Data) async throws -> Void) async throws {
        let fields=(request.value(forHTTPHeaderField:"Range") ?? "bytes=0-\(bytes.count-1)").dropFirst(6).split(separator:"-")
        let start=Int(fields[0])!,end=min(bytes.count-1,Int(fields[1])!)
        try await response(HTTPURLResponse(url:request.url!,statusCode:206,httpVersion:nil,headerFields:["Content-Type":"audio/flac","Content-Length":"\(end-start+1)","Content-Range":"bytes \(start)-\(end)/\(bytes.count)","ETag":"\"seek-fixture-v1\""])!)
        for offset in stride(from:start,through:end,by:65536) {
            try Task.checkCancellation();try await data(bytes.subdata(in:offset..<min(end+1,offset+65536)))
        }
    }
}

private struct DecodedAudioBlock {
    var position:Double,rate:Double,samples:[Float]
}
private final class DecodedAudioCapture {
    private let lock=NSLock()
    private var captured=[DecodedAudioBlock]()
    private var rate=0.0,channels=0,flags:AudioFormatFlags=0
    var blocks:[DecodedAudioBlock] {lock.lock();defer{lock.unlock()};return captured}
    func reset(){lock.lock();captured=[];lock.unlock()}
    func makeTap() throws -> MTAudioProcessingTap {
        var callbacks=MTAudioProcessingTapCallbacks(version:kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo:Unmanaged.passRetained(self).toOpaque(),
            init:{_,info,storage in storage.pointee=info},
            finalize:{tap in Unmanaged<DecodedAudioCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()},
            prepare:{tap,_,format in
                let capture=Unmanaged<DecodedAudioCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                capture.lock.lock();defer{capture.lock.unlock()}
                capture.rate=format.pointee.mSampleRate;capture.channels=Int(format.pointee.mChannelsPerFrame);capture.flags=format.pointee.mFormatFlags
            },unprepare:nil,process:{tap,frames,_,buffers,outFrames,outFlags in
                var time=CMTimeRange.invalid
                guard MTAudioProcessingTapGetSourceAudio(tap,frames,buffers,outFlags,&time,outFrames) == 0 else{return}
                let capture=Unmanaged<DecodedAudioCapture>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                capture.lock.lock();defer{capture.lock.unlock()}
                guard time.start.seconds.isFinite,capture.captured.count < 128,capture.flags & kAudioFormatFlagIsFloat != 0,
                      let data=buffers.pointee.mBuffers.mData,outFrames.pointee > 0 else{return}
                let values=data.assumingMemoryBound(to:Float.self)
                let step=capture.flags & kAudioFormatFlagIsNonInterleaved != 0 ? 1:capture.channels
                capture.captured.append(DecodedAudioBlock(position:time.start.seconds,rate:capture.rate,samples:(0..<outFrames.pointee).map{values[$0*step]}))
            })
        var tap:MTAudioProcessingTap?
        let result=MTAudioProcessingTapCreate(kCFAllocatorDefault,&callbacks,kMTAudioProcessingTapCreationFlag_PreEffects,&tap)
        guard result == 0,let tap else {Unmanaged.passUnretained(self).release();throw ValidationFailure(message:"无法创建解码音频采集器")}
        return tap
    }
}

private struct SequentialAudio {
    var rate:Double,samples:[Float]
    static func read(_ url:URL) async throws -> Self {
        let asset=PlaybackAsset.make(url:url)
        let tracks=try await asset.loadTracks(withMediaType:.audio)
        let reader=try AVAssetReader(asset:asset)
        let output=AVAssetReaderTrackOutput(track:try XCTUnwrap(tracks.first),outputSettings:[AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMIsFloatKey:true,AVLinearPCMBitDepthKey:32,AVLinearPCMIsNonInterleaved:false])
        reader.add(output)
        guard reader.startReading() else {throw reader.error ?? ValidationFailure(message:"顺播解码未启动")}
        var samples=[Float](),rate=0.0
        while let sample=output.copyNextSampleBuffer() {
            guard let description=sample.formatDescription,let format=CMAudioFormatDescriptionGetStreamBasicDescription(description),let block=CMSampleBufferGetDataBuffer(sample) else {throw ValidationFailure(message:"顺播解码缺少PCM")}
            rate=format.pointee.mSampleRate
            let channels=Int(format.pointee.mChannelsPerFrame),count=CMSampleBufferGetNumSamples(sample)
            var values=[Float](repeating:0,count:count*channels)
            let status=values.withUnsafeMutableBytes{CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:$0.count,destination:$0.baseAddress!)}
            guard status == 0 else {throw ValidationFailure(message:"顺播PCM读取失败")}
            for index in 0..<count {samples.append(values[index*channels])}
        }
        guard reader.status == .completed,!samples.isEmpty else {throw reader.error ?? ValidationFailure(message:"顺播解码未完成")}
        return Self(rate:rate,samples:samples)
    }
    func match(_ block:DecodedAudioBlock) -> (errorMS:Double,correlation:Float) {
        let query=Array(block.samples.prefix(2048)),center=Int((block.position*rate).rounded()),radius=Int(rate*0.1)
        let lower=max(0,center-radius),upper=min(samples.count-query.count,center+radius)
        guard !query.isEmpty,lower<=upper else{return (.infinity,0)}
        var qEnergy:Float=0
        vDSP_svesq(query,1,&qEnergy,vDSP_Length(query.count))
        guard qEnergy>0 else{return (.infinity,0)}
        var best:Float = -1,bestOffset=lower
        query.withUnsafeBufferPointer { q in samples.withUnsafeBufferPointer { reference in
            for offset in lower...upper {
                var dot:Float=0,energy:Float=0
                vDSP_dotpr(reference.baseAddress!+offset,1,q.baseAddress!,1,&dot,vDSP_Length(query.count))
                vDSP_svesq(reference.baseAddress!+offset,1,&energy,vDSP_Length(query.count))
                let score=dot/sqrt(max(1e-30,energy*qEnergy))
                if score>best {best=score;bestOffset=offset}
            }
        }}
        return ((Double(bestOffset)/rate-block.position)*1000,best)
    }
}
