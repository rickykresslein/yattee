import AVKit
import CoreData
#if os(iOS)
    import CoreMotion
#endif
import Defaults
import Foundation
import Logging
import MediaPlayer
import Siesta
import SwiftUI
import SwiftyJSON
#if !os(macOS)
    import UIKit
#endif

final class PlayerModel: ObservableObject {
    enum PlaybackMode: String, CaseIterable, Defaults.Serializable {
        case queue, shuffle, loopOne, related

        var systemImage: String {
            switch self {
            case .queue:
                return "list.number"
            case .shuffle:
                return "shuffle"
            case .loopOne:
                return "repeat.1"
            case .related:
                return "infinity"
            }
        }
    }

    static let availableRates: [Float] = [0.5, 0.67, 0.8, 1, 1.25, 1.5, 2]
    let logger = Logger(label: "stream.yattee.app")

    var avPlayerView = AppleAVPlayerView()
    var playerItem: AVPlayerItem?

    var mpvPlayerView = MPVPlayerView()

    @Published var presentingPlayer = false { didSet { handlePresentationChange() } }
    @Published var activeBackend = PlayerBackendType.mpv

    var avPlayerBackend: AVPlayerBackend!
    var mpvBackend: MPVBackend!

    var backends: [PlayerBackend] {
        [avPlayerBackend, mpvBackend]
    }

    var backend: PlayerBackend! {
        switch activeBackend {
        case .mpv:
            return mpvBackend
        case .appleAVPlayer:
            return avPlayerBackend
        }
    }

    @Published var playerSize: CGSize = .zero { didSet {
        backend.setSize(playerSize.width, playerSize.height)
    }}
    @Published var aspectRatio = VideoPlayerView.defaultAspectRatio
    @Published var stream: Stream?
    @Published var currentRate: Float = 1.0 { didSet { backend.setRate(currentRate) } }

    @Published var availableStreams = [Stream]() { didSet { handleAvailableStreamsChange() } }
    @Published var streamSelection: Stream? { didSet { rebuildTVMenu() } }

    @Published var queue = [PlayerQueueItem]() { didSet { handleQueueChange() } }
    @Published var currentItem: PlayerQueueItem! { didSet { handleCurrentItemChange() } }
    @Published var videoBeingOpened: Video?
    @Published var historyVideos = [Video]()

    @Published var preservedTime: CMTime?

    @Published var sponsorBlock = SponsorBlockAPI()
    @Published var segmentRestorationTime: CMTime?
    @Published var lastSkipped: Segment? { didSet { rebuildTVMenu() } }
    @Published var restoredSegments = [Segment]()

    @Published var musicMode = false
    @Published var playbackMode = PlaybackMode.queue { didSet { handlePlaybackModeChange() } }
    @Published var autoplayItem: PlayerQueueItem?
    @Published var autoplayItemSource: Video?
    @Published var advancing = false

    @Published var returnYouTubeDislike = ReturnYouTubeDislikeAPI()

    @Published var isSeeking = false { didSet {
        backend.setNeedsNetworkStateUpdates(true)
    }}

    #if os(iOS)
        @Published var lockedOrientation: UIInterfaceOrientationMask?
    #endif

    var accounts: AccountsModel
    var comments: CommentsModel
    var controls: PlayerControlsModel { didSet {
        backends.forEach { backend in
            var backend = backend
            backend.controls = controls
        }
    }}
    var playerTime: PlayerTimeModel { didSet {
        backends.forEach { backend in
            var backend = backend
            backend.playerTime = playerTime
            backend.playerTime.player = self
        }
    }}
    var networkState: NetworkStateModel { didSet {
        backends.forEach { backend in
            var backend = backend
            backend.networkState = networkState
            backend.networkState.player = self
        }
    }}
    var navigation: NavigationModel

    var context: NSManagedObjectContext = PersistenceController.shared.container.viewContext
    var backgroundContext = PersistenceController.shared.container.newBackgroundContext()

    #if os(tvOS)
        static let fullScreenIsDefault = true
    #else
        static let fullScreenIsDefault = false
    #endif
    @Published var playingFullScreen = PlayerModel.fullScreenIsDefault

    @Published var playingInPictureInPicture = false
    var pipController: AVPictureInPictureController?
    var pipDelegate = PiPDelegate()

    @Published var presentingErrorDetails = false
    var playerError: Error? { didSet {
        #if !os(tvOS)
            if !playerError.isNil {
                presentingErrorDetails = true
            }
        #endif
    }}

    @Default(.pauseOnHidingPlayer) private var pauseOnHidingPlayer
    @Default(.closePiPOnNavigation) var closePiPOnNavigation
    @Default(.closePiPOnOpeningPlayer) var closePiPOnOpeningPlayer

    #if !os(macOS)
        @Default(.closePiPAndOpenPlayerOnEnteringForeground) var closePiPAndOpenPlayerOnEnteringForeground
    #endif

    private var currentArtwork: MPMediaItemArtwork?
    #if !os(macOS)
        var playerLayerView: PlayerLayerView!
    #endif

    var onPresentPlayer: (() -> Void)?
    private var remoteCommandCenterConfigured = false

    init(
        accounts: AccountsModel = AccountsModel(),
        comments: CommentsModel = CommentsModel(),
        controls: PlayerControlsModel = PlayerControlsModel(),
        navigation: NavigationModel = NavigationModel(),
        playerTime: PlayerTimeModel = PlayerTimeModel(),
        networkState: NetworkStateModel = NetworkStateModel()
    ) {
        self.accounts = accounts
        self.comments = comments
        self.controls = controls
        self.navigation = navigation
        self.playerTime = playerTime
        self.networkState = networkState

        self.avPlayerBackend = AVPlayerBackend(
            model: self,
            controls: controls,
            playerTime: playerTime
        )
        self.mpvBackend = MPVBackend(
            model: self,
            playerTime: playerTime,
            networkState: networkState
        )

        Defaults[.activeBackend] = .mpv
        playbackMode = Defaults[.playbackMode]
    }

    func show() {
        #if os(macOS)
            if presentingPlayer {
                Windows.player.focus()
                return
            }
        #endif

        DispatchQueue.main.async { [weak self] in
            withAnimation {
                self?.presentingPlayer = true
            }
        }

        #if os(macOS)
            Windows.player.open()
            Windows.player.focus()
        #endif
    }

    func hide() {
        DispatchQueue.main.async { [weak self] in
            self?.playingFullScreen = false
            withAnimation {
                self?.presentingPlayer = false
            }
        }

        #if os(iOS)
            if Defaults[.lockPortraitWhenBrowsing] {
                Orientation.lockOrientation(.portrait, andRotateTo: .portrait)
            } else {
                Orientation.lockOrientation(.allButUpsideDown)
            }
        #endif
    }

    func togglePlayer() {
        #if os(macOS)
            if !presentingPlayer {
                Windows.player.open()
            }
            Windows.player.focus()
        #else
            if presentingPlayer {
                hide()
            } else {
                show()
            }
        #endif
    }

    var isLoadingVideo: Bool {
        guard !currentVideo.isNil else {
            return false
        }

        return backend.isLoadingVideo
    }

    var isPlaying: Bool {
        backend.isPlaying
    }

    var playerItemDuration: CMTime? {
        guard !currentItem.isNil else {
            return nil
        }

        return backend.playerItemDuration
    }

    var playerItemDurationWithoutSponsorSegments: CMTime? {
        guard let playerItemDuration = playerItemDuration, !playerItemDuration.seconds.isZero else {
            return nil
        }

        return playerItemDuration - .secondsInDefaultTimescale(
            sponsorBlock.segments.reduce(0) { $0 + $1.duration }
        )
    }

    var videoDuration: TimeInterval? {
        playerItemDuration?.seconds ?? currentItem?.duration ?? currentVideo?.length
    }

    var time: CMTime? {
        currentItem?.playbackTime
    }

    var live: Bool {
        currentVideo?.live ?? false
    }

    var playingLive: Bool {
        guard live,
              let videoDuration = videoDuration,
              let time = backend.currentTime?.seconds else { return false }

        return videoDuration - time < 30
    }

    var liveStreamInAVPlayer: Bool {
        live && activeBackend == .appleAVPlayer
    }

    func togglePlay() {
        backend.togglePlay()
    }

    func play() {
        backend.play()
    }

    func pause() {
        backend.pause()
    }

    func play(_ video: Video, at time: CMTime? = nil, showingPlayer: Bool = true) {
        pause()

        #if os(iOS)
            if !playingInPictureInPicture, showingPlayer {
                onPresentPlayer = { [weak self] in self?.playNow(video, at: time) }
                show()
                return
            }
        #endif

        playNow(video, at: time)

        guard !playingInPictureInPicture else {
            return
        }

        if showingPlayer {
            show()
        }
    }

    func playStream(
        _ stream: Stream,
        of video: Video,
        preservingTime: Bool = false,
        upgrading: Bool = false
    ) {
        playerError = nil
        if !upgrading {
            resetSegments()

            DispatchQueue.main.async { [weak self] in
                self?.sponsorBlock.loadSegments(
                    videoID: video.videoID,
                    categories: Defaults[.sponsorBlockCategories]
                )

                guard Defaults[.enableReturnYouTubeDislike] else {
                    return
                }

                self?.returnYouTubeDislike.loadDislikes(videoID: video.videoID) { [weak self] dislikes in
                    self?.currentItem?.video?.dislikes = dislikes
                }
            }
        }

        playerTime.reset()

        backend.playStream(
            stream,
            of: video,
            preservingTime: preservingTime,
            upgrading: upgrading
        )

        if !upgrading {
            updateCurrentArtwork()
        }
    }

    func saveTime(completionHandler: @escaping () -> Void = {}) {
        guard let currentTime = backend.currentTime, currentTime.seconds > 0 else {
            completionHandler()
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.preservedTime = currentTime
            completionHandler()
        }
    }

    func upgradeToStream(_ stream: Stream, force: Bool = false) {
        guard let video = currentVideo else {
            return
        }

        if !self.stream.isNil, force || self.stream != stream {
            playStream(stream, of: video, preservingTime: true, upgrading: true)
        }
    }

    private func handleAvailableStreamsChange() {
        rebuildTVMenu()

        guard stream.isNil else {
            return
        }

        guard let stream = preferredStream(availableStreams) else {
            return
        }

        streamSelection = stream
        playStream(
            stream,
            of: currentVideo!,
            preservingTime: !currentItem.playbackTime.isNil
        )
    }

    private func handlePresentationChange() {
        var delay = 0.0

        #if os(iOS)
            if presentingPlayer {
                delay = 0.2
            }
        #endif

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.backend.setNeedsDrawing(self.presentingPlayer)

            #if os(tvOS)
                if self.presentingPlayer {
                    self.controls.show()
                }
            #endif
        }

        controls.hide()

        #if !os(macOS)
            UIApplication.shared.isIdleTimerDisabled = presentingPlayer
        #endif

        if presentingPlayer, closePiPOnOpeningPlayer, playingInPictureInPicture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.closePiP()
            }
        }

        if !presentingPlayer, pauseOnHidingPlayer, !playingInPictureInPicture {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pause()
            }
        }

        if !presentingPlayer, !pauseOnHidingPlayer, backend.isPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.play()
            }
        }
    }

    func changeActiveBackend(from: PlayerBackendType, to: PlayerBackendType) {
        guard activeBackend != to else {
            return
        }

        Defaults[.activeBackend] = to
        self.activeBackend = to

        guard var stream = stream else {
            return
        }

        if to == .mpv {
            addVideoTrackFromStream()
        } else {
            musicMode = false
        }

        inactiveBackends().forEach { $0.pause() }

        let fromBackend: PlayerBackend = from == .appleAVPlayer ? avPlayerBackend : mpvBackend
        let toBackend: PlayerBackend = to == .appleAVPlayer ? avPlayerBackend : mpvBackend

        if let stream = toBackend.stream, toBackend.video == fromBackend.video {
            toBackend.seek(to: fromBackend.currentTime?.seconds ?? .zero) { finished in
                guard finished else {
                    return
                }
                toBackend.play()
            }

            self.stream = stream
            streamSelection = stream

            return
        }

        if !backend.canPlay(stream) || (to == .mpv && !stream.hlsURL.isNil) {
            guard let preferredStream = preferredStream(availableStreams) else {
                return
            }

            stream = preferredStream
            streamSelection = preferredStream
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else {
                return
            }
            self.upgradeToStream(stream, force: true)
            self.setNeedsDrawing(self.presentingPlayer)
        }
    }

    private func inactiveBackends() -> [PlayerBackend] {
        [activeBackend == PlayerBackendType.mpv ? avPlayerBackend : mpvBackend]
    }

    func rateLabel(_ rate: Float) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2

        return "\(formatter.string(from: NSNumber(value: rate))!)×"
    }

    func closeCurrentItem(finished: Bool = false) {
        prepareCurrentItemForHistory(finished: finished)
        currentItem = nil

        backend.closeItem()
        aspectRatio = VideoPlayerView.defaultAspectRatio
        resetAutoplay()
    }

    func closePiP() {
        guard playingInPictureInPicture else {
            return
        }

        let wasPlaying = isPlaying
        pause()

        #if os(tvOS)
            show()
        #endif

        backend.closePiP(wasPlaying: wasPlaying)
    }

    func handleQueueChange() {
        Defaults[.queue] = queue

        updateRemoteCommandCenter()
        controls.objectWillChange.send()
    }

    func handleCurrentItemChange() {
        #if os(macOS)
            Windows.player.window?.title = windowTitle
        #endif

        DispatchQueue.main.async(qos: .background) { [weak self] in
            guard let self = self else { return }
            Defaults[.lastPlayed] = self.currentItem

            if self.playbackMode == .related,
               let video = self.currentVideo,
               self.autoplayItemSource.isNil || self.autoplayItemSource?.videoID != video.videoID
            {
                self.setRelatedAutoplayItem()
            }
        }
    }

    func handlePlaybackModeChange() {
        Defaults[.playbackMode] = playbackMode

        updateRemoteCommandCenter()

        guard playbackMode == .related else {
            autoplayItem = nil
            return
        }
        setRelatedAutoplayItem()
    }

    func setRelatedAutoplayItem() {
        guard let video = currentVideo else { return }
        let related = video.related.filter { $0.videoID != autoplayItem?.video?.videoID }

        let watchFetchRequest = Watch.fetchRequest()
        watchFetchRequest.predicate = NSPredicate(format: "videoID IN %@", related.map(\.videoID) as [String])

        let results = try? context.fetch(watchFetchRequest)

        context.perform { [weak self] in
            guard let self = self,
                  let results = results else { return }
            let resultsIds = results.map(\.videoID)

            guard let autoplayVideo = related.filter({ !resultsIds.contains($0.videoID) }).randomElement() else {
                return
            }

            let item = PlayerQueueItem(autoplayVideo)
            self.autoplayItem = item
            self.autoplayItemSource = video

            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self else { return }
                self.accounts.api.loadDetails(item, completionHandler: { newItem in
                    guard newItem.videoID == self.autoplayItem?.videoID else { return }
                    self.autoplayItem = newItem
                    self.updateRemoteCommandCenter()
                    self.controls.objectWillChange.send()
                })
            }
        }
    }

    func updateRemoteCommandCenter() {
        let skipForwardCommand = MPRemoteCommandCenter.shared().skipForwardCommand
        let skipBackwardCommand = MPRemoteCommandCenter.shared().skipBackwardCommand
        let previousTrackCommand = MPRemoteCommandCenter.shared().previousTrackCommand
        let nextTrackCommand = MPRemoteCommandCenter.shared().nextTrackCommand

        if !remoteCommandCenterConfigured {
            remoteCommandCenterConfigured = true

            #if !os(macOS)
                try? AVAudioSession.sharedInstance().setCategory(
                    .playback,
                    mode: .moviePlayback
                )

                UIApplication.shared.beginReceivingRemoteControlEvents()
            #endif

            let preferredIntervals = [NSNumber(10)]

            skipForwardCommand.preferredIntervals = preferredIntervals
            skipBackwardCommand.preferredIntervals = preferredIntervals

            skipForwardCommand.addTarget { [weak self] _ in
                self?.backend.seek(relative: .secondsInDefaultTimescale(10))
                return .success
            }

            skipBackwardCommand.addTarget { [weak self] _ in
                self?.backend.seek(relative: .secondsInDefaultTimescale(-10))
                return .success
            }

            previousTrackCommand.addTarget { [weak self] _ in
                self?.backend.seek(to: .zero)
                return .success
            }

            nextTrackCommand.addTarget { [weak self] _ in
                self?.advanceToNextItem()
                return .success
            }

            MPRemoteCommandCenter.shared().playCommand.addTarget { [weak self] _ in
                self?.play()
                return .success
            }

            MPRemoteCommandCenter.shared().pauseCommand.addTarget { [weak self] _ in
                self?.pause()
                return .success
            }

            MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget { [weak self] _ in
                self?.togglePlay()
                return .success
            }

            MPRemoteCommandCenter.shared().changePlaybackPositionCommand.addTarget { [weak self] remoteEvent in
                guard let event = remoteEvent as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }

                self?.backend.seek(to: event.positionTime)

                return .success
            }
        }

        switch Defaults[.systemControlsCommands] {
        case .seek:
            previousTrackCommand.isEnabled = false
            nextTrackCommand.isEnabled = false
            skipForwardCommand.isEnabled = true
            skipBackwardCommand.isEnabled = true

        case .restartAndAdvanceToNext:
            skipForwardCommand.isEnabled = false
            skipBackwardCommand.isEnabled = false
            previousTrackCommand.isEnabled = true
            nextTrackCommand.isEnabled = isAdvanceToNextItemAvailable
        }
    }

    func resetAutoplay() {
        autoplayItem = nil
        autoplayItemSource = nil
    }

    #if os(macOS)
        var windowTitle: String {
            currentVideo.isNil ? "Not playing" : "\(currentVideo!.title) - \(currentVideo!.author)"
        }
    #else
        func handleEnterForeground() {
            setNeedsDrawing(presentingPlayer)

            guard closePiPAndOpenPlayerOnEnteringForeground, playingInPictureInPicture else {
                return
            }

            show()
            closePiP()
        }

        func handleEnterBackground() {
            setNeedsDrawing(false)

            if Defaults[.pauseOnEnteringBackground], !playingInPictureInPicture, !musicMode {
                pause()
            }
        }

        func enterFullScreen() {
            guard !playingFullScreen else {
                return
            }

            logger.info("entering fullscreen")

            backend.enterFullScreen()
        }

        func exitFullScreen() {
            guard playingFullScreen else {
                return
            }

            logger.info("exiting fullscreen")

            if playingFullScreen {
                toggleFullscreen(true)
            }

            backend.exitFullScreen()
        }
    #endif

    func updateNowPlayingInfo() {
        guard let video = currentItem?.video else {
            return
        }

        let currentTime = (backend.currentTime?.seconds.isFinite ?? false) ? backend.currentTime!.seconds : 0
        var nowPlayingInfo: [String: AnyObject] = [
            MPMediaItemPropertyTitle: video.title as AnyObject,
            MPMediaItemPropertyArtist: video.author as AnyObject,
            MPNowPlayingInfoPropertyIsLiveStream: live as AnyObject,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime as AnyObject,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count as AnyObject,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: 1 as AnyObject,
            MPMediaItemPropertyMediaType: MPMediaType.anyVideo.rawValue as AnyObject
        ]

        if !currentArtwork.isNil {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = currentArtwork as AnyObject
        }

        if !video.live {
            let itemDuration = (backend.playerItemDuration ?? .zero).seconds
            let duration = itemDuration.isFinite ? Double(itemDuration) : nil

            if !duration.isNil {
                nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration as AnyObject
            }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func updateCurrentArtwork() {
        guard let video = currentVideo,
              let thumbnailURL = video.thumbnailURL(quality: .medium)
        else {
            return
        }

        let task = URLSession.shared.dataTask(with: thumbnailURL) { [weak self] thumbnailData, _, _ in
            guard let thumbnailData = thumbnailData else {
                return
            }

            #if os(macOS)
                guard let image = NSImage(data: thumbnailData) else { return }
            #else
                guard let image = UIImage(data: thumbnailData) else { return }
            #endif

            self?.currentArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        task.resume()
    }

    func toggleFullscreen(_ isFullScreen: Bool) {
        controls.presentingControls = false

        #if os(macOS)
            if isFullScreen {
                Windows.player.toggleFullScreen()
            }
        #endif
        #if os(iOS)
            withAnimation(.linear(duration: 0.2)) {
                playingFullScreen = !isFullScreen
            }
        #else
            playingFullScreen = !isFullScreen
        #endif

        #if os(macOS)
            if !isFullScreen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    Windows.player.toggleFullScreen()
                }
            }
        #endif

        #if os(iOS)
            if !playingFullScreen {
                Orientation.lockOrientation(.allButUpsideDown)
            }
        #endif
    }

    func setNeedsDrawing(_ needsDrawing: Bool) {
        backends.forEach { $0.setNeedsDrawing(needsDrawing) }
    }

    func toggleMusicMode() {
        musicMode.toggle()

        if musicMode {
            if playingInPictureInPicture {
                avPlayerBackend.pause()
                avPlayerBackend.switchToMPVOnPipClose = false
                closePiP()
            }
            changeActiveBackend(from: .appleAVPlayer, to: .mpv)
            controls.presentingControls = true
            controls.removeTimer()
            mpvBackend.setVideoToNo()
        } else {
            addVideoTrackFromStream()
            mpvBackend.setVideoToAuto()

            controls.resetTimer()
        }
    }

    func addVideoTrackFromStream() {
        if let videoTrackURL = stream?.videoAsset?.url,
           mpvBackend.tracks < 2
        {
            logger.info("adding video track")

            mpvBackend.addVideoTrack(videoTrackURL)
        }

        mpvBackend.setVideoToAuto()
    }
}
