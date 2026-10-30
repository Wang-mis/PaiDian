import SwiftUI

enum AppRoute: Hashable { case search, searchQuery(String,MusicPlatform?), searchForPlaylist(UUID), sources, settings, history, playlist(UUID) }
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [AppRoute] = []
    @State private var newPlaylist = false
    @State private var name = ""
    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            ZStack { ScreenBackground()
                if model.isStarting { ProgressView("正在打开音乐库") }
                else if let failure = model.startupError { VStack { EmptyState(symbol: "externaldrive.badge.exclamationmark", title: "音乐库未能打开", message: failure); Button("重试") { Task { await model.start() } }.buttonStyle(.borderedProminent) } }
                else { ScrollView { VStack(alignment: .leading, spacing: 26) {
                    header
                    if model.source.playbackCapabilities.platforms.isEmpty { sourceIntroduction }
                    if !model.history.isEmpty { recentSection }
                    librarySection
                }.padding(.horizontal, 20).padding(.bottom, 20) } }
            }.playbackInset().navigationTitle("音乐库").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { HStack { NavigationLink(value: AppRoute.search) { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("搜索"); NavigationLink(value: AppRoute.settings) { Image(systemName: "gearshape").frame(width: 44, height: 44) }.accessibilityLabel("设置") } } }
                .navigationDestination(for: AppRoute.self) { route in Group { switch route { case .search: SearchScreen(); case .searchQuery(let query,let platform): SearchScreen(initialQuery:query,initialSelection:platform.map{.platform($0)}); case .searchForPlaylist(let id): SearchScreen(targetPlaylistID:id); case .sources: SourcesScreen(); case .settings: SettingsScreen(); case .history: HistoryScreen(); case .playlist(let id): PlaylistScreen(id: id) } }.playbackInset() }
        }.tint(Theme.red).preferredColorScheme(model.colorScheme)
            .fullScreenCover(isPresented: $model.showPlayer,onDismiss: {
                if let query = model.alternativeSearchQuery { let platform=model.alternativeSearchPlatform;model.alternativeSearchQuery = nil;model.alternativeSearchPlatform=nil; path.append(.searchQuery(query,platform)) }
            }) { PlayerScreen() }
            .sheet(isPresented: Binding(get: { model.showQueue && !model.showPlayer },set: { model.showQueue = $0 })) { QueueScreen().presentationDetents([.medium,.large]) }
            .sheet(isPresented: Binding(get: { !model.addTracks.isEmpty }, set: { if !$0 { model.addTracks = [] } })) { AddToPlaylistScreen(tracks: model.addTracks) }
            .alert("提示", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
            .alert("新建歌单", isPresented: $newPlaylist) { TextField("歌单名称", text: $name); Button("创建") { let draft = name; Task { if let result = await model.perform(.create(PlaylistDraft(name: draft))) , let id = result.playlistID { path.append(.playlist(id)) } } }; Button("取消", role: .cancel) {} } message: { Text("输入 1–40 个字符的名称") }
            .onChange(of: scenePhase) { _, phase in if phase == .background { model.pauseAndSave() } }
            .task { await model.reloadHistory() }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            NavigationLink(value: AppRoute.search) { Label("搜索歌曲、歌手、专辑", systemImage: "magnifyingglass").font(.system(size: 15)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 14).background(.thinMaterial, in: Capsule()) }.buttonStyle(.plain)
            Group {
                VStack(alignment: .leading, spacing: 8) { Text("我的音乐").font(.system(size: 25, weight: .bold)); Text("\(model.library.playlists.filter { $0.kind == .user }.count) 个歌单 · \(model.library.trackCount) 首歌曲").font(.system(size: 13)).foregroundStyle(.secondary) }.padding(.top, 20)
                HStack(spacing: 8) { quickLink("最近播放", "clock.fill", .history); quickLink("我喜欢的", "heart.fill", .playlist(Playlist.favoritesID)); quickLink("音源管理", "folder", .sources) }
            }
        }.padding(.top, 10)
    }
    private func quickLink(_ text: String, _ icon: String, _ route: AppRoute) -> some View { NavigationLink(value: route) { Label(text, systemImage: icon).font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 46).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain) }
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("音乐").font(.title3.bold()).padding(.bottom, 6).overlay(alignment: .bottomLeading) { Rectangle().frame(width: 24, height: 2) }
            HStack { Text("创建的歌单").foregroundStyle(.secondary); Spacer(); Button { name = ""; newPlaylist = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("新建歌单").accessibilityIdentifier("createPlaylist") }.font(.system(size: 14))
            ForEach(model.library.playlists) { playlist in playlistLink(playlist) }
        }
    }
    private var sourceIntroduction:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("从你的音源开始").font(.title2)
            Text("导入洛雪移动版自定义音源，搜索并聆听音乐。").font(.subheadline).foregroundStyle(.secondary)
            NavigationLink("导入音源",value:AppRoute.sources).buttonStyle(.borderedProminent)
        }.padding(20).frame(maxWidth:.infinity,alignment:.leading).background(.thinMaterial,in:RoundedRectangle(cornerRadius:16))
    }
    private var recentSection:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("最近播放").font(.title3);Spacer();NavigationLink("全部",value:AppRoute.history).font(.caption) }
            ForEach(Array(model.history.prefix(3))) { entry in TrackRow(track:entry.track,artwork:true) { Task { await model.play(model.history.map(\.track),at:entry.track.key) } } }
        }
    }
    private func playlistLink(_ playlist: Playlist) -> some View { NavigationLink(value: AppRoute.playlist(playlist.id)) { HStack(spacing: 14) { Artwork(url: playlist.artworkURL, size: 58, favorite: playlist.kind == .favorites, fileKey: playlist.coverFileKey); VStack(alignment: .leading, spacing: 7) { Text(playlist.name).font(.system(size: 16, weight: .medium)); Text("\(playlist.count) 首").font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }.contentShape(Rectangle()) }.buttonStyle(.plain) }
}
