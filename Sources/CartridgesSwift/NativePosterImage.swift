import SwiftUI
import AppKit
import QuartzCore
import AVFoundation

struct AnimatedPosterImage: NSViewRepresentable {
    var url: URL
    var fill: Bool
    func makeNSView(context: Context) -> NativePosterImageView { NativePosterImageView() }
    func updateNSView(_ view: NativePosterImageView, context: Context) { view.fillsBounds = fill; view.setURL(url) }
    static func dismantleNSView(_ view: NativePosterImageView, coordinator: ()) { view.stop() }
}

@MainActor
final class NativePosterImageView: NSView {
    // Explicit benchmark-only playback, so CPU checks don't confuse inactive-window pausing
    // with animation performance. This flag changes no persistent preference or system setting.
    private static let benchmarkPlayback = ProcessInfo.processInfo.arguments.contains("--benchmark-playback")
    var fillsBounds = true { didSet {
        if oldValue != fillsBounds {
            layer?.contentsGravity = fillsBounds ? .resizeAspectFill : .resizeAspect
            videoLayer?.videoGravity = fillsBounds ? .resizeAspectFill : .resizeAspect
        }
    } }
    private var url: URL?
    private var modified: Date?
    private var decoder: PosterDecoder?
    private var currentFrame: PosterFrame?
    private var buffered: PosterFrame?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var generation = 0
    private var deadline: CFTimeInterval = 0
    private var wasPlaying = false
    private var observers: [NSObjectProtocol] = []
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    private var videoPending = false
    private var readyObservation: NSKeyValueObservation?
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, NSView.boundsDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.updatePlayback() } })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit {
        timer?.invalidate(); loadTask?.cancel(); prefetchTask?.cancel()
        for token in observers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func setURL(_ newURL: URL) {
        let date = newURL.isFileURL ? try? newURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate : nil
        guard url != newURL || date != modified else { return }
        stop(); generation += 1; let request = generation
        url = newURL; modified = date
        let decoder = PosterDecoder(url: newURL)
        self.decoder = decoder
        loadTask = Task { [weak self] in
            do {
                let first = try await decoder.nextFrame()
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.show(first)
                if first.animated {
                    self.videoPending = true
                    do {
                        let movie = try await PosterVideoCache.shared.video(for: newURL)
                        guard self.generation == request, !Task.isCancelled else { return }
                        self.installVideo(movie)
                    } catch {
                        // Unsupported movie preparation must not restore an expensive software loop.
                        self.currentFrame = PosterFrame(image: first.image, duration: first.duration, animated: false)
                        self.videoPending = false; self.updatePlayback()
                    }
                } else { self.updatePlayback() }
                self.loadTask = nil
            } catch { self?.loadTask = nil }
        }
    }
    func stop() {
        generation += 1
        timer?.invalidate(); timer = nil
        loadTask?.cancel(); loadTask = nil
        prefetchTask?.cancel(); prefetchTask = nil
        decoder = nil; currentFrame = nil; buffered = nil; wasPlaying = false
        player?.pause(); looper?.disableLooping(); player?.removeAllItems()
        player = nil; looper = nil; videoLayer?.removeFromSuperlayer(); videoLayer = nil
        videoPending = false; readyObservation?.invalidate(); readyObservation = nil
        layer?.contents = nil
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updatePlayback() }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView { clip.postsBoundsChangedNotifications = true; break }
            ancestor = view.superview
        }
        updatePlayback()
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updatePlayback() }
    override func setFrameOrigin(_ newOrigin: NSPoint) { super.setFrameOrigin(newOrigin); updatePlayback() }
    override func layout() { super.layout(); videoLayer?.frame = bounds }

    private func installVideo(_ url: URL) {
        let player = AVQueuePlayer()
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(url: url)
        let videoLayer = AVPlayerLayer(player: player)
        videoLayer.videoGravity = fillsBounds ? .resizeAspectFill : .resizeAspect
        videoLayer.frame = bounds
        layer?.addSublayer(videoLayer)
        self.player = player; self.videoLayer = videoLayer
        looper = AVPlayerLooper(player: player, templateItem: item)
        readyObservation = videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
            if layer.isReadyForDisplay { Task { @MainActor [weak self] in
                guard self?.videoLayer === layer else { return }
                self?.layer?.contents = nil
            } }
        }
        decoder = nil; videoPending = false; wasPlaying = false
        updatePlayback()
    }

    private var shouldPlay: Bool {
        PosterPlaybackPolicy.shouldAnimate(animated: currentFrame?.animated == true, active: Self.benchmarkPlayback || NSApp.isActive,
            visible: window?.isVisible == true && window?.isMiniaturized == false && (Self.benchmarkPlayback || window?.occlusionState.contains(.visible) == true),
            onscreen: !isHiddenOrHasHiddenAncestor && (Self.benchmarkPlayback ? !bounds.isEmpty : !visibleRect.intersection(bounds).isEmpty),
            reduceMotion: !Self.benchmarkPlayback && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    private func show(_ newFrame: PosterFrame) {
        currentFrame = newFrame
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = newFrame.image
        CATransaction.commit()
        deadline = CACurrentMediaTime() + newFrame.duration
    }
    private func updatePlayback() {
        if videoPending { return }
        if let player {
            if shouldPlay {
                if !wasPlaying { player.play(); wasPlaying = true }
            } else { player.pause(); wasPlaying = false }
            return
        }
        guard shouldPlay else { timer?.invalidate(); timer = nil; wasPlaying = false; return }
        if !wasPlaying { deadline = CACurrentMediaTime() + (currentFrame?.duration ?? 0.1); wasPlaying = true }
        guard timer == nil else { return }
        if buffered != nil { schedule() } else { prefetch() }
    }
    private func prefetch() {
        guard prefetchTask == nil, let decoder else { return }
        let request = generation
        prefetchTask = Task { [weak self] in
            do {
                let next = try await decoder.nextFrame()
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.prefetchTask = nil; self.buffered = next; self.updatePlayback()
            } catch { self?.prefetchTask = nil }
        }
    }
    private func schedule() {
        guard timer == nil, shouldPlay else { return }
        let nextTimer = Timer(timeInterval: max(0.001, deadline - CACurrentMediaTime()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        nextTimer.tolerance = 0.003
        timer = nextTimer; RunLoop.main.add(nextTimer, forMode: .common)
    }
    private func advance() {
        timer = nil
        guard shouldPlay, let next = buffered else { updatePlayback(); return }
        buffered = nil; show(next); prefetch()
    }
}
