import SwiftUI

@MainActor struct PlayerScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showInfo = false
    @State private var presentation: PlayerPresentation
    init(presentation: PlayerPresentation? = nil) { _presentation=State(initialValue:presentation ?? PlayerPresentation()) }
    private var showLyrics: Bool { presentation.showLyrics }
    @State private var lyrics = LyricDocument()
    @State private var lyricSync=LyricSynchronizer()
    @State private var lyricError: String?
    @State private var loadingLyrics = false
    @State private var lyricOffsetMS: Int64 = 0
    @State private var showLyricTiming = false
    @State private var bufferingIndicator=BufferingIndicatorState()
    @State private var scrub: Double?
    @State private var recordRotation=RecordRotationClock()
    private var shouldRotateRecord: Bool { !showLyrics && model.playback.status == .playing && !reduceMotion && scenePhase == .active }
    private var track: Track? { model.playback.queue.current?.track }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                header
                GeometryReader { media in
                    ZStack {
                        recordView(size:media.size).opacity(showLyrics ? 0 : 1).allowsHitTesting(!showLyrics).accessibilityHidden(showLyrics)
                        lyricView.frame(width:media.size.width,height:media.size.height).opacity(showLyrics ? 1 : 0).allowsHitTesting(showLyrics).accessibilityHidden(!showLyrics)
                    }.animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:showLyrics)
                }.frame(maxHeight:.infinity).clipped()
                metadata.padding(.horizontal,25).padding(.top,8).padding(.bottom,14)
                if let failure = model.playback.failure { failureView(failure).padding(.horizontal,25) }
                if model.playback.status == .resolving { Text("正在尝试："+(model.source.resolvingSourceName ?? "音源")+" · "+(model.source.resolvingQuality?.name ?? "解析中")).font(.system(size:11)).padding(.horizontal,25).padding(.bottom,4) }
                progress.anchorPreference(key:PlayerLayoutAnchors.self,value:.bounds) { ["progress":$0] }.padding(.horizontal,25)
                transport.anchorPreference(key:PlayerLayoutAnchors.self,value:.bounds) { ["transport":$0] }.padding(.horizontal,22).frame(height:86)
                footer.padding(.horizontal,20).padding(.top,10).padding(.bottom,4)
            }
            .frame(width:geometry.size.width,height:geometry.size.height)
        }.background {
            LinearGradient(colors:[Color(red:0.20,green:0.13,blue:0.12),Color(red:0.105,green:0.07,blue:0.067)],startPoint:.top,endPoint:.bottom)
                .overlay { GeometryReader { background in
                    if let track { Artwork(url:track.artworkURL,size:max(background.size.width,background.size.height),track:track).blur(radius:100).opacity(0.12).position(x:background.size.width/2,y:background.size.height/2) }
                }.clipped() }.ignoresSafeArea()
        }.foregroundStyle(.white.opacity(0.62)).preferredColorScheme(.dark)
            .accessibilityIdentifier("playerViewport")
            .sheet(isPresented:Binding(get:{model.showQueue},set:{model.showQueue=$0})) { QueueScreen().presentationDetents([.medium,.large]) }
            .sheet(isPresented:$showInfo) { NavigationStack { List {
                LabeledContent("歌曲",value:track?.title ?? "—")
                LabeledContent("歌手",value:track?.artistText ?? "—")
                LabeledContent("专辑",value:track?.albumTitle ?? "—")
                LabeledContent("歌曲来源",value:track?.key.platform.name ?? "—")
                LabeledContent("歌曲 ID",value:track?.key.providerID ?? "—")
                LabeledContent("请求音质",value:model.playback.displayedQuality?.rawValue ?? "尚未解析成功")
                LabeledContent("播放音源",value:model.playback.resolvedSourceName ?? "尚未解析成功")
                if let origin=lyrics.origin { LabeledContent("歌词来源",value:origin.sourceKey.platform.name+" · "+origin.format.rawValue.uppercased()) }
            }.navigationTitle("歌曲信息").toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { showInfo=false } } } }.presentationDetents([.medium]) }
            .sheet(isPresented:$showLyricTiming) {
                LyricTimingSheet(offsetMS:$lyricOffsetMS) { value in if let key = track?.key { model.saveLyricOffset(value,for:key) } }
                    .presentationDetents([.height(260)]).presentationDragIndicator(.visible)
            }
            .task(id:track?.key) { showLyricTiming=false; await loadLyrics() }
            .onChange(of:shouldRotateRecord,initial:true) { _,running in
                recordRotation.setRunning(running,at:ProcessInfo.processInfo.systemUptime)
            }
            .onChange(of:model.playback.revision,initial:true) { _,_ in synchronizeLyrics();bufferingIndicator.update(status:model.playback.status,desiredPlaying:model.playback.desiredPlaying) }
            .onChange(of:showLyrics) { _,_ in synchronizeLyrics() }
            .onChange(of:lyricOffsetMS) { _,_ in synchronizeLyrics() }
            .onChange(of:scenePhase) { _,_ in synchronizeLyrics() }
            .onAppear { recordRotation.setRunning(shouldRotateRecord,at:ProcessInfo.processInfo.systemUptime);synchronizeLyrics() }
            .onDisappear { recordRotation.setRunning(false,at:ProcessInfo.processInfo.systemUptime);lyricSync.stop();bufferingIndicator.stop() }
    }
    private var header: some View {
        HStack(spacing:8) {
            Button { dismiss() } label: { Image(systemName:"chevron.down").font(.system(size:20,weight:.light)).frame(width:44,height:44) }.accessibilityLabel("收起播放器")
            ZStack {
                Text(track.flatMap { $0.albumTitle.isEmpty ? nil : $0.albumTitle } ?? "正在播放")
                    .font(.system(size:14)).lineLimit(1).opacity(showLyrics ? 0 : 1).accessibilityHidden(showLyrics)
                VStack(spacing:4) {
                    Text(track?.title ?? "播放器").font(.system(size:14)).lineLimit(1)
                    Text(track?.artistText ?? "").font(.system(size:13)).lineLimit(1)
                }.opacity(showLyrics ? 1 : 0).accessibilityHidden(!showLyrics)
            }.frame(maxWidth:.infinity).animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:showLyrics)
            songMenu
        }.padding(.horizontal,12).frame(height:44)
    }
    private var songMenu: some View {
        Menu {
            if let track {
                Button("加入歌单") { model.addTracks=[track];dismiss() }
                Button("下一首播放") { Task { await model.player?.editQueue(.insertNext([track])) } }
                if showLyrics { Button("歌词时间调整") { showLyricTiming=true } }
                Button("歌曲信息") { showInfo=true }
            }
        } label: { Image(systemName:"ellipsis").font(.system(size:21)).frame(width:44,height:44) }.accessibilityLabel("歌曲操作")
    }
    private func recordView(size:CGSize) -> some View {
        let diameter=max(70,min(350,size.width*0.81,size.height*0.77))
        let discCenter=CGPoint(x:size.width/2,y:size.height*0.59)
        return ZStack {
            ZStack {
                TimelineView(.animation(minimumInterval:1/30,paused:!shouldRotateRecord)) { _ in
                    ZStack {
                        Circle().fill(.white.opacity(0.025)).overlay(Circle().stroke(.white.opacity(0.055),lineWidth:1)).padding(-12)
                        Circle().fill(RadialGradient(colors:[.black,Color(white:0.12),.black],center:.center,startRadius:diameter*0.22,endRadius:diameter*0.5)).shadow(color:.black.opacity(0.25),radius:12,y:5)
                        ForEach(0..<23) { index in Circle().stroke(.white.opacity(index%3 == 0 ? 0.035 : 0.015),lineWidth:1).padding(CGFloat(index)*diameter*0.006+3) }
                        Artwork(url:track?.artworkURL,size:diameter*0.64,track:track).clipShape(Circle()).overlay(Circle().stroke(.black.opacity(0.7),lineWidth:3))
                    }.rotationEffect(.degrees(reduceMotion ? 0 : recordRotation.angle(at:ProcessInfo.processInfo.systemUptime)))
                        // The surrounding opacity transition must never interpolate disc angles.
                        .transaction { $0.animation=nil }
                }.frame(width:diameter,height:diameter)
            }.position(discCenter)
            Tonearm(pivot:CGPoint(x:size.width*0.53,y:20),
                    tip:CGPoint(x:discCenter.x+diameter*0.30,y:discCenter.y-diameter*0.31),
                    playing:model.playback.status == .playing)
                .animation(reduceMotion ? nil : .easeInOut(duration:0.35),value:model.playback.status).allowsHitTesting(false)
        }.frame(width:size.width,height:size.height).contentShape(Rectangle())
            .onTapGesture { presentation.showLyrics=true }.accessibilityAction(named:"显示歌词") { presentation.showLyrics=true }
    }
    private var favorite: some View {
        Button { if let track { Task { await model.toggleFavorite(track) } } } label: {
            Image(systemName:track.map{model.library.favoriteKeys.contains($0.key)} == true ? "heart.fill" : "heart")
                .font(.system(size:24,weight:.light)).foregroundStyle(track.map{model.library.favoriteKeys.contains($0.key)} == true ? Theme.red : .white.opacity(0.68)).frame(width:44,height:44)
        }.accessibilityLabel("喜欢这首歌").accessibilityIdentifier("playerFavorite")
            .anchorPreference(key:PlayerLayoutAnchors.self,value:.bounds) { ["favorite":$0] }
    }
    private var metadata: some View {
        HStack(spacing:16) {
            VStack(alignment:.leading,spacing:7) {
                Text(track?.title ?? "尚未选择歌曲").font(.system(size:18,weight:.regular)).lineLimit(2)
                HStack(spacing:7) { Text(track?.artistText ?? "从搜索或歌单开始播放").font(.system(size:15)).lineLimit(1);Image(systemName:"chevron.right").font(.system(size:10));if let track { Text(track.key.platform.name).font(.system(size:10)).padding(.horizontal,5).padding(.vertical,2).overlay(RoundedRectangle(cornerRadius:3).stroke(.white.opacity(0.18),lineWidth:0.5)) } }.foregroundStyle(.white.opacity(0.43))
            }.frame(maxWidth:.infinity,alignment:.leading).opacity(showLyrics ? 0 : 1)
                .accessibilityHidden(showLyrics).animation(reduceMotion ? nil : .easeInOut(duration:0.25),value:showLyrics)
            favorite
        }.fixedSize(horizontal:false,vertical:true)
    }
    private func failureView(_ failure:AppFailure) -> some View {
        VStack(alignment:.leading,spacing:2) {
            Text(failure.userMessage).font(.system(size:12)).lineLimit(3)
            HStack {
                if failure.retryable { Button("重试") { Task { await model.player?.resume() } }.frame(minHeight:44) }
                Spacer()
                if track?.key.platform != .wy,model.source.playbackCapabilities.platforms[.wy] != nil { Button("搜网易云版本") { model.alternativeSearchQuery=track?.title;model.alternativeSearchPlatform = .wy;model.showPlayer=false }.frame(minHeight:44) }
                Button("搜索其他版本") { model.alternativeSearchQuery=track?.title;model.showPlayer=false }.frame(minHeight:44)
            }.font(.system(size:12))
        }.foregroundStyle(Color(red:0.96,green:0.61,blue:0.57))
    }
    private var progress: some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                if bufferingIndicator.visible { ProgressView().controlSize(.mini).tint(.white);Text("正在缓冲…") }
                else if model.playback.isLocallyCached { Text("本地缓存") }
                else if let warning=model.playback.cacheWarning { Text(warning) }
            }.font(.system(size:11)).foregroundStyle(.white.opacity(0.5)).frame(height:18).accessibilityIdentifier("bufferingStatus")
            PlaybackProgress(value:Binding(get:{scrub ?? Double(model.playback.positionMS)},set:{scrub=$0}),bufferedRanges:model.playback.bufferedRanges,duration:Double(model.playback.durationMS),enabled:model.playback.canSeek) { position in scrub=nil;Task { await model.player?.seek(toMS:Int64(position)) } }
            HStack { Text(timeLabel(Int64(scrub ?? Double(model.playback.positionMS))));Spacer();qualityMenu;Spacer();Text(timeLabel(model.playback.durationMS)) }.font(.system(size:11)).foregroundStyle(.white.opacity(0.36)).monospacedDigit().frame(height:23)
        }
    }
    private var transport: some View {
        HStack(spacing:0) {
            Button { Task { await model.player?.editQueue(.setMode(model.playback.queue.mode.next)) } } label: { Image(systemName:model.playback.queue.mode.symbol).font(.system(size:21,weight:.light)).frame(width:44,height:60) }.accessibilityLabel(model.playback.queue.mode.name+"，切换模式")
            Spacer(minLength:0)
            Button { Task { await model.player?.previous() } } label: { Image(systemName:"backward.end.fill").font(.system(size:23)).frame(width:44,height:60) }.accessibilityLabel("上一首")
            Spacer(minLength:0)
            Button { Task { await model.togglePlay() } } label: { Image(systemName:model.playback.desiredPlaying ? "pause.fill" : "play.fill").font(.system(size:36)).frame(width:60,height:64) }.accessibilityLabel(model.playback.desiredPlaying ? "暂停" : "播放")
            Spacer(minLength:0)
            Button { Task { await model.player?.next() } } label: { Image(systemName:"forward.end.fill").font(.system(size:23)).frame(width:44,height:60) }.accessibilityLabel("下一首")
            Spacer(minLength:0)
            Button { model.showQueue=true } label: { Image(systemName:"text.line.first.and.arrowtriangle.forward").font(.system(size:22,weight:.light)).frame(width:44,height:60) }.accessibilityLabel("播放队列")
        }.buttonStyle(.plain).accessibilityIdentifier("playerTransport")
    }
    private var footer: some View {
        HStack {
            AudioRouteButton().frame(width:44,height:44)
            Spacer()
            Button { showInfo=true } label: { Image(systemName:"info.circle").frame(width:44,height:44) }.accessibilityLabel("歌曲信息")
            Spacer()
            songMenu
        }.font(.system(size:19,weight:.light)).foregroundStyle(.white.opacity(0.40)).buttonStyle(.plain)
    }
    private var qualityMenu: some View {
        Text(model.playback.displayedQuality?.name ?? "—").frame(minWidth:72,minHeight:44)
            .accessibilityLabel("请求音质").accessibilityIdentifier("playbackQualityLabel")
    }
    private var lyricView: some View {
        Group {
            if loadingLyrics { ProgressView("正在获取歌词").tint(.white).frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle()).onTapGesture { presentation.showLyrics=false } }
            else if let lyricError { VStack { Text(lyricError).foregroundStyle(.white.opacity(0.6)); Button("重试歌词") { Task { await loadLyrics() } }; Button("返回封面") { presentation.showLyrics=false } }.font(.subheadline) }
            else if lyrics.timedLines.isEmpty {
                ScrollView { Text(lyrics.plainText ?? "暂无歌词").font(.system(size:model.settings.lyricFontSize)).lineSpacing(model.settings.lyricLineSpacing).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center).frame(maxWidth:.infinity).padding(30) }
                    .contentShape(Rectangle()).onTapGesture { presentation.showLyrics=false }
            } else {
                LyricsScroller(lines:lyrics.timedLines,
                    currentIndex:lyricSync.currentIndex,
                    offsetMS:lyricOffsetMS,settings:model.settings,canSeek:model.playback.canSeek,reduceMotion:reduceMotion,isActive:showLyrics,
                    onConfirm: { line in
                        guard model.playback.canSeek else { return }
                        let position=LyricTiming.seekTime(for:line,offsetMS:lyricOffsetMS,durationMS:model.playback.durationMS)
                        Task { await model.player?.seekAndPlay(toMS:position) }
                    },onToggle: { presentation.showLyrics=false }).id(track?.key)
            }
        }
    }
    private func synchronizeLyrics() {
        let key=track?.key
        lyricSync.configure(document:lyrics,offsetMS:lyricOffsetMS,active:showLyrics && scenePhase == .active) {
            guard model.playback.queue.current?.track.key == key else { return nil }
            if let clock=model.player?.playbackClock() { return clock }
            guard let key,model.playback.status == .paused else { return nil }
            return PlaybackClockSample(mediaID:model.playback.queue.currentEntryID ?? UUID(),trackKey:key,positionMS:model.playback.positionMS,rate:0,advancing:false)
        }
    }
    private func loadLyrics() async {
        lyricSync.stop();let key = track?.key; lyrics = LyricDocument(); lyricError = nil; lyricOffsetMS=0
        guard let track, let service = model.lyricService else { loadingLyrics=false; return }; loadingLyrics = true
        do {
            let offset = try await model.loadLyricOffset(for:track.key)
            try Task.checkCancellation(); guard key == self.track?.key else { return }; lyricOffsetMS=offset
        } catch { guard !Task.isCancelled,key == self.track?.key else { return }; model.report(error) }
        do { let document = try await service.load(track); try Task.checkCancellation(); guard key == self.track?.key else { return }; lyrics = document; loadingLyrics = false;synchronizeLyrics() }
        catch { guard !Task.isCancelled, key == self.track?.key else { return }; lyricError = "歌词加载失败"; loadingLyrics = false }
    }

}
struct QueueScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var clear = false
    var body: some View { NavigationStack { List {
        Section { Button { Task { await model.player?.editQueue(.setMode(model.playback.queue.mode.next)) } } label: { Label(model.playback.queue.mode.name, systemImage: model.playback.queue.mode.symbol) } }
        if model.playback.queue.entries.isEmpty { EmptyState(symbol: "music.note.list",title: "队列为空",message: "从搜索或歌单选择歌曲开始播放") }
        ForEach(model.playback.queue.entries) { entry in Button { Task { await model.player?.editQueue(.select(entry.id)) } } label: { HStack { if model.playback.queue.currentEntryID == entry.id { Image(systemName: "waveform").foregroundStyle(Theme.red) }; VStack(alignment: .leading,spacing: 6) { Text(entry.track.title).foregroundStyle(model.playback.queue.currentEntryID == entry.id ? Theme.red : .primary); Text(entry.track.artistText).font(.caption).foregroundStyle(.secondary) }; Spacer() }.frame(minHeight: 44) }.buttonStyle(.plain) }
            .onDelete { offsets in let ids = Set(offsets.map { model.playback.queue.entries[$0].id }); Task { await model.player?.editQueue(.remove(ids)) } }
            .onMove { offsets, index in var entries = model.playback.queue.entries; entries.move(fromOffsets: offsets,toOffset: index); Task { await model.player?.editQueue(.move(entries.map(\.id))) } }
    }.environment(\.editMode,.constant(.active)).navigationTitle("播放队列 · \(model.playback.queue.entries.count)").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }; ToolbarItem(placement: .topBarTrailing) { Button("清空",role: .destructive) { clear = true }.disabled(model.playback.queue.entries.isEmpty) } }.confirmationDialog("清空播放队列并停止播放？", isPresented: $clear,titleVisibility: .visible) { Button("清空队列",role: .destructive) { Task { await model.player?.editQueue(.clear) } } } }.tint(Theme.red) }
}
