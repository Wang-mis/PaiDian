import Foundation
import AVFoundation
import MediaPlayer

@MainActor final class SystemMediaController {
    private weak var playback: (any PlaybackControlling)?
    private var notifications: [NSObjectProtocol] = []
    private var targets: [(MPRemoteCommand, Any)] = []
    private var interruptionWasPlaying = false
    private var interruptionIntent: UUID?
    private let artwork: ArtworkLoader
    private var artworkTask: Task<Void,Never>?
    private var artworkKey: TrackKey?
    private var currentArtwork: MPMediaItemArtwork?
    init(playback: any PlaybackControlling, artwork: ArtworkLoader) {
        self.artwork = artwork
        self.playback = playback
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor () async -> Void) { let token = command.addTarget { _ in Task { @MainActor in await action() }; return .success }; targets.append((command, token)) }
        bind(center.playCommand) { [weak playback] in await playback?.resume() }
        bind(center.pauseCommand) { [weak playback] in playback?.pause() }
        bind(center.togglePlayPauseCommand) { [weak playback] in guard let playback else { return }; if playback.state.desiredPlaying { playback.pause() } else { await playback.resume() } }
        bind(center.nextTrackCommand) { [weak playback] in await playback?.next() }
        bind(center.previousTrackCommand) { [weak playback] in await playback?.previous() }
        let token = center.changePlaybackPositionCommand.addTarget { [weak playback] event in guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }; Task { @MainActor in await playback?.seek(toMS: Int64(event.positionTime * 1000)) }; return .success }; targets.append((center.changePlaybackPositionCommand, token))
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0, options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.interruption(type: type, options: options) }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak playback] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in playback?.pause() } }
        })
    }
    private func interruption(type: UInt, options: UInt) {
        if type == AVAudioSession.InterruptionType.began.rawValue { interruptionWasPlaying = playback?.state.desiredPlaying ?? false; playback?.pause(); interruptionIntent = (playback as? PlaybackCoordinator)?.intentRevision }
        else {
            let unchanged = interruptionIntent == (playback as? PlaybackCoordinator)?.intentRevision
            let shouldResume = interruptionWasPlaying && unchanged && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            interruptionWasPlaying = false; interruptionIntent = nil
            if shouldResume { Task { [weak playback] in await playback?.resume() } }
        }
    }
    func update(_ state: PlaybackViewState) {
        guard let track = state.queue.current?.track else { artworkTask?.cancel(); artworkKey = nil; currentArtwork = nil; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        if artworkKey != track.key {
            artworkKey = track.key; currentArtwork = nil; artworkTask?.cancel()
            artworkTask = Task { [weak self,artwork] in
                guard let data = try? await artwork.load(track), let image = UIImage(data:data), !Task.isCancelled, let self, self.artworkKey == track.key else { return }
                let mediaArtwork = MPMediaItemArtwork(boundsSize:image.size) { _ in image }; self.currentArtwork = mediaArtwork
                if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo { info[MPMediaItemPropertyArtwork] = mediaArtwork; MPNowPlayingInfoCenter.default().nowPlayingInfo = info }
            }
        }
        var info: [String:Any] = [MPMediaItemPropertyTitle:track.title, MPMediaItemPropertyArtist:track.artistText, MPMediaItemPropertyAlbumTitle:track.albumTitle, MPMediaItemPropertyPlaybackDuration:Double(state.durationMS)/1000, MPNowPlayingInfoPropertyElapsedPlaybackTime:Double(state.positionMS)/1000, MPNowPlayingInfoPropertyPlaybackRate:state.status == .playing ? 1.0 : 0.0]
        if let currentArtwork { info[MPMediaItemPropertyArtwork] = currentArtwork }; MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = state.canSeek
    }
    deinit { artworkTask?.cancel(); for (command, target) in targets { command.removeTarget(target) }; notifications.forEach(NotificationCenter.default.removeObserver) }
}
