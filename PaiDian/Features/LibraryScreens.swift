import SwiftUI
import PhotosUI

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var targetPlaylistID: UUID?
    var initialQuery = ""
    var initialSelection: SearchSelection?
    @State private var query = ""
    @State private var selection: SearchSelection = .all
    @State private var selected = Set<TrackKey>()
    @State private var initialized = false
    private var tracks: [Track] { model.search.groups.flatMap(\.tracks) }
    private func submit() { selected.removeAll(); Task { await model.searchService?.submit(query: query, selection: selection); await model.reloadHistory() } }
    var body: some View {
        ZStack { ScreenBackground(); VStack(spacing: 12) {
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索音乐", text: $query).submitLabel(.search).onSubmit(submit).accessibilityIdentifier("searchField"); if !query.isEmpty { Button { query = ""; submit() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("清空搜索") } }.padding(.horizontal, 14).frame(minHeight: 44).background(.thinMaterial, in: Capsule()).padding(.horizontal, 18)
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 23) { filter("全部", .all); ForEach(MusicPlatform.allCases.filter { model.source.playbackCapabilities.platforms[$0] != nil }) { filter($0.name, .platform($0)) } }.padding(.horizontal, 18) }
            if model.source.playbackCapabilities.platforms.isEmpty { EmptyState(symbol: "link", title: "尚无可用音源", message: "导入音源并完成初始化后即可搜索支持的平台"); NavigationLink("前往音源管理", value: AppRoute.sources); Spacer() }
            else if model.search.query.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 16) { HStack { Text("搜索历史").font(.headline); Spacer(); Button("清空") { Task { await model.clearQueries() } } }; ForEach(model.queries, id: \.self) { q in Button { query = q; submit() } label: { HStack { Text(q).foregroundStyle(.primary); Spacer(); Image(systemName: "arrow.up.left").foregroundStyle(.secondary) }.frame(minHeight: 44) } } }.padding(20) }
            } else {
                List { ForEach(model.search.groups) { group in Section {
                    ForEach(group.tracks) { track in
                        HStack { if targetPlaylistID != nil { Button { if selected.contains(track.key) { selected.remove(track.key) } else { selected.insert(track.key) } } label: { Image(systemName: selected.contains(track.key) ? "checkmark.circle.fill" : "circle").frame(width: 44,height: 44) }.accessibilityLabel("选择 \(track.title)") }; TrackRow(track: track, query: model.search.query, showsSource: selection == .all) { if targetPlaylistID != nil { if selected.contains(track.key) { selected.remove(track.key) } else { selected.insert(track.key) } } else { Task { await model.play(tracks, at: track.key) } } } }
                    }.listRowBackground(Color.clear)
                    if group.isLoading { ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear) }
                    if let failure = group.failure { VStack(alignment: .leading, spacing: 10) { Text(failure.userMessage).font(.caption).foregroundStyle(.secondary); Button("重试 \(group.platform.name)") { Task { await model.searchService?.retry(platform: group.platform) } } }.listRowBackground(Color.clear) }
                    if group.tracks.isEmpty && !group.isLoading && group.failure == nil { Text("没有找到相关歌曲").foregroundStyle(.secondary).listRowBackground(Color.clear) }
                } header: { if selection == .all { Text(group.platform.name) } } }
                    if model.search.groups.contains(where: { $0.hasMore && !$0.isLoading && $0.failure == nil }) { Button("加载更多") { Task { await model.searchService?.loadMore() } }.frame(maxWidth: .infinity).listRowBackground(Color.clear) }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        } }.navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .bottomBar) { if targetPlaylistID != nil { Button("将 \(selected.count) 首加入歌单") { let chosen = tracks.filter { selected.contains($0.key) }; if let targetPlaylistID { Task { if await model.perform(.addTracks(targetPlaylistID,chosen)) != nil { dismiss() } } } else { model.addTracks = chosen } }.disabled(selected.isEmpty) } } }
            .task {
                guard !initialized else { return }; initialized=true
                selection=model.settings.searchSelection(explicit:initialSelection,available:Set(model.source.playbackCapabilities.platforms.keys))
                query=initialQuery; await model.reloadHistory(); submit()
            }
            .onChange(of:Set(model.source.playbackCapabilities.platforms.keys)) { _,available in
                if case .platform(let platform)=selection, !available.contains(platform) { selection = .all;submit() }
            }
    }
    private func filter(_ title: String, _ value: SearchSelection) -> some View { Button { selection = value; if case .platform(let platform)=value { model.settings.preferredSearchPlatform=platform } else { model.settings.preferredSearchPlatform=nil }; Task { await model.saveSettings() }; submit() } label: { VStack(spacing: 6) { Text(title).font(.system(size: 14, weight: selection == value ? .bold : .regular)).foregroundStyle(selection == value ? .primary : .secondary); Capsule().fill(selection == value ? Theme.red : .clear).frame(width: 19, height: 3) }.frame(minHeight: 44) }.buttonStyle(.plain) }
}
struct PlaylistScreen: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    @State private var items: [PlaylistItem] = []
    @State private var editMode: EditMode = .inactive
    @State private var selected = Set<UUID>()
    @State private var rename = false
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var photo: PhotosPickerItem?
    @Environment(\.dismiss) private var dismiss
    private var playlist: Playlist? { model.library.playlists.first { $0.id == id } }
    var body: some View {
        ZStack { ScreenBackground(); List(selection: $selected) {
            if let p = playlist { Section {
                HStack(alignment: .top, spacing: 20) { Artwork(url: p.artworkURL, size: 118, favorite: p.kind == .favorites, fileKey: p.coverFileKey, playlistID: p.id); VStack(alignment: .leading, spacing: 12) { Text(p.name).font(.title2.bold()); Text("\(items.count) 首歌曲").font(.subheadline).foregroundStyle(.secondary) } }.padding(.vertical, 16)
                HStack { Button { Task { await model.play(items.map(\.track)) } } label: { Label("播放全部", systemImage: "play.circle.fill").font(.headline).foregroundStyle(Theme.red) }.disabled(items.isEmpty); Spacer(); Button { Task { await model.play(items.map(\.track), shuffle: true) } } label: { Image(systemName: "shuffle").frame(width: 44, height: 44) }.disabled(items.isEmpty).accessibilityLabel("随机播放歌单") }.buttonStyle(.plain)
            }.listRowSeparator(.hidden).listRowBackground(Color.clear) }
            if items.isEmpty { EmptyState(symbol: "music.note.list", title: "歌单还是空的", message: "搜索歌曲后，通过更多菜单加入此歌单").listRowBackground(Color.clear).listRowSeparator(.hidden) }
            ForEach(items) { item in
                Group {
                    if editMode.isEditing { HStack { Text(item.track.title); Spacer(); Text(item.track.artistText).foregroundStyle(.secondary).font(.caption) }.frame(minHeight: 48) }
                    else { TrackRow(track: item.track, artwork: true) { Task { await model.play(items.map(\.track), at: item.track.key) } } }
                }.tag(item.id).listRowBackground(Color.clear)
            }.onDelete { offsets in let ids = Set(offsets.map { items[$0].id }); Task { _ = await model.perform(.removeItems(id, ids)); await reload() } }
                .onMove { from, to in var reordered = items; reordered.move(fromOffsets: from, toOffset: to); let order = reordered.map(\.id); Task { _ = await model.perform(.reorder(id, order)); await reload() } }
        }.listStyle(.plain).scrollContentBackground(.hidden).environment(\.editMode, $editMode) }
            .navigationTitle("歌单").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Menu {
                NavigationLink("添加歌曲",value:AppRoute.searchForPlaylist(id))
                Button(editMode.isEditing ? "完成编辑" : "编辑歌曲") { editMode = editMode.isEditing ? .inactive : .active; selected.removeAll() }
                if playlist?.kind == .user { Button("重命名") { name = playlist?.name ?? ""; rename = true }; PhotosPicker(selection: $photo, matching: .images) { Label("更换封面", systemImage: "photo") }; Button("删除歌单", role: .destructive) { confirmDelete = true } }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("歌单操作") }
                ToolbarItem(placement: .bottomBar) { if editMode.isEditing { HStack { Button("加入其他歌单") { model.addTracks = items.filter { selected.contains($0.id) }.map(\.track) }; Button("移除 \(selected.count) 首", role: .destructive) { Task { _ = await model.perform(.removeItems(id, selected)); selected.removeAll(); await reload() } } }.disabled(selected.isEmpty) } }
            }
            .alert("重命名歌单", isPresented: $rename) { TextField("名称", text: $name); Button("保存") { Task { _ = await model.perform(.update(id, PlaylistDraft(name: name, coverFileKey: playlist?.coverFileKey))) } }; Button("取消", role: .cancel) {} }
            .confirmationDialog("删除“\(playlist?.name ?? "歌单")”？", isPresented: $confirmDelete, titleVisibility: .visible) { Button("删除歌单", role: .destructive) { Task { if await model.perform(.delete(id)) != nil { dismiss() } } } }
            .task { await reload() }.onChange(of: model.library.revision) { _, _ in Task { await reload() } }
            .onChange(of: photo) { _, value in Task { do { guard let data = try await value?.loadTransferable(type: Data.self), data.count <= 8 * 1024 * 1024, UIImage(data: data) != nil, let files = model.fileStore, let p = playlist else { return }; let key = try await files.stage(data, namespace: "covers"); if await model.perform(.update(id, PlaylistDraft(name: p.name, coverFileKey: key))) == nil { try? await files.remove(key) } else if let old = p.coverFileKey { try? await files.remove(old) } } catch { model.report(error) } } }
    }
    private func reload() async { items = await model.playlistItems(id) }
}
struct AddToPlaylistScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]
    @State private var name = ""
    @State private var creating = false
    @State private var saving = false
    var body: some View { NavigationStack { List {
        Button("新建歌单", systemImage: "plus") { creating = true }
        ForEach(model.library.playlists) { p in Button { Task { saving = true; if await model.perform(.addTracks(p.id, tracks)) != nil { dismiss() }; saving = false } } label: { HStack { Artwork(url: p.artworkURL, size: 48, favorite: p.kind == .favorites, fileKey: p.coverFileKey, playlistID: p.id); VStack(alignment: .leading) { Text(p.name); Text("\(p.count) 首").font(.caption).foregroundStyle(.secondary) } } } }
    }.disabled(saving).navigationTitle("添加 \(tracks.count) 首歌曲").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }.alert("新建歌单", isPresented: $creating) { TextField("歌单名称", text: $name); Button("创建并添加") { Task { saving = true; if let result = await model.perform(.create(PlaylistDraft(name: name))), let id = result.playlistID, await model.perform(.addTracks(id, tracks)) != nil { dismiss() }; saving = false } }; Button("取消", role: .cancel) {} } }.tint(Theme.red) }
}
struct HistoryScreen: View {
    @Environment(AppModel.self) private var model
    var body: some View { ZStack { ScreenBackground(); if model.history.isEmpty { EmptyState(symbol: "clock", title: "还没有播放记录", message: "成功播放的音乐会保存在这里") } else { List(model.history) { item in TrackRow(track: item.track, artwork: true) { Task { await model.play(model.history.map(\.track), at: item.track.key) } }.listRowBackground(Color.clear) }.listStyle(.plain).scrollContentBackground(.hidden) } }.navigationTitle("最近播放").task { await model.reloadHistory() } }
}
