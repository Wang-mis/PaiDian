import SwiftUI

enum Theme {
    static let red = Color(red: 1, green: 0.224, blue: 0.224)
    static let dark = Color(red: 0.051, green: 0.051, blue: 0.071)
}
struct ScreenBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { (scheme == .dark ? Theme.dark : Color(uiColor: .systemGroupedBackground)).ignoresSafeArea() }
}
struct Artwork: View {
    @Environment(AppModel.self) private var model
    var url: URL?; var size: CGFloat; var favorite = false; var fileKey: String?
    var track: Track?; var playlistID: UUID?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: favorite ? [Theme.red.opacity(0.75), .orange.opacity(0.35)] : [Color(red: 0.27, green: 0.34, blue: 0.44), Color(red: 0.13, green: 0.17, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: favorite ? "heart.fill" : "music.note").font(.system(size: max(16,size * 0.3))).foregroundStyle(.white.opacity(0.7)) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size > 80 ? 14 : 7))
            .task(id: (fileKey ?? "") + (url?.absoluteString ?? "") + (track?.key.encoded ?? "") + (playlistID?.uuidString ?? "") + (playlistID == nil ? "" : model.library.revision.uuidString)) {
                image = nil
                if let fileKey, let data = await model.coverData(fileKey), let decoded = UIImage(data:data) { try? Task.checkCancellation(); if !Task.isCancelled { image = decoded }; return }
                do { guard let data = try await model.artworkData(url:url,track:track,playlistID:playlistID) else { return }; let decoded = await Task.detached { UIImage(data:data) }.value; try Task.checkCancellation(); image = decoded } catch { }
            }.accessibilityHidden(true)
    }
}
struct EmptyState: View {
    var symbol: String; var title: String; var message: String
    var body: some View { VStack(spacing: 14) { Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary); Text(title).font(.headline); Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 48).padding(.horizontal, 24) }
}
struct TrackRow: View {
    @Environment(AppModel.self) private var model
    var track: Track; var artwork = false; var query = ""; var showsSource = true; var play: () -> Void
    private var title: AttributedString {
        var value = AttributedString(track.title)
        if !query.isEmpty, let range = value.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) { value[range].foregroundColor = Theme.red }; return value
    }
    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) { HStack(spacing: 12) {
                if artwork { Artwork(url: track.artworkURL, size: 46, track: track) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 16)).foregroundStyle(model.playback.queue.current?.track.key == track.key ? Theme.red : .primary).lineLimit(1)
                    Text([track.artistText,track.albumTitle].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if !artwork && showsSource { Text(track.key.platform.name).font(.system(size: 11)).foregroundStyle(.tertiary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityLabel("播放 \(track.title)，\(track.artistText)")
            if !artwork { Button { Task { await model.toggleFavorite(track) } } label: { Image(systemName: model.library.favoriteKeys.contains(track.key) ? "heart.fill" : "heart").foregroundStyle(model.library.favoriteKeys.contains(track.key) ? Theme.red : .secondary).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("收藏 \(track.title)") }
            Menu {
                Button("加入歌单", systemImage: "text.badge.plus") { model.addTracks = [track] }
                Button("下一首播放", systemImage: "text.insert") { Task { await model.player?.editQueue(.insertNext([track])) } }
                Button(model.library.favoriteKeys.contains(track.key) ? "取消喜欢" : "喜欢", systemImage: "heart") { Task { await model.toggleFavorite(track) } }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).foregroundStyle(.secondary) }.accessibilityLabel("\(track.title)更多操作")
        }.padding(.vertical, 5)
    }
}
struct MiniPlayer: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 10) {
            Button { model.showPlayer = true } label: { HStack(spacing: 10) { Artwork(url: model.playback.queue.current?.track.artworkURL, size: 38, track: model.playback.queue.current?.track).clipShape(Circle()); Text(model.playback.queue.current.map { $0.track.title + " - " + $0.track.artistText } ?? "选择歌曲开始播放").font(.system(size: 13)).lineLimit(1); Spacer(minLength: 0) }.contentShape(Rectangle()) }.buttonStyle(.plain).accessibilityIdentifier("miniPlayer")
            Button { Task { await model.togglePlay() } } label: { MiniPlaybackRing(positionMS:model.playback.confirmedPositionMS,durationMS:model.playback.durationMS,playing:model.playback.desiredPlaying).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel(model.playback.desiredPlaying ? "暂停" : "播放")
            Button { model.showQueue = true } label: { Image(systemName: "list.bullet").font(.system(size: 22)).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("播放队列")
        }.padding(.leading, 6).padding(.trailing, 4).frame(height: 50).background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.primary.opacity(0.08), lineWidth: 0.5)).padding(.horizontal, 16)
    }
}
func timeLabel(_ ms: Int64) -> String { let s = max(0,ms)/1000; return String(format: "%02lld:%02lld", s/60, s%60) }

/// Apply inside the NavigationStack so each destination receives the occupied bottom region.
private struct PlaybackInset: ViewModifier {
    @Environment(AppModel.self) private var model
    func body(content: Content) -> some View {
        content.safeAreaInset(edge:.bottom,spacing:0) {
            if !model.isStarting && model.startupError == nil && model.playback.queue.current != nil {
                MiniPlayer().padding(.vertical,8).frame(maxWidth:.infinity)
            }
        }
    }
}
extension View { func playbackInset() -> some View { modifier(PlaybackInset()) } }
