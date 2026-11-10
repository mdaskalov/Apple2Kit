import AVFoundation

/// Plays the speaker as the Apple's would: its clicks streamed to the cycle
/// (`SpeakerStream`), the samples queued one batch after the other as the
/// machine runs, frame by frame.
public final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(SpeakerRenderer.sampleRate), channels: 1)!
    /// The player node reaches the output; if not, nothing plays.
    private let connected: Bool
    private var stream = SpeakerStream()

    #if !os(macOS)
    /// The audio session's category, set once for every player, off the main
    /// thread (it can block while the session is active): ambient, mixing
    /// with other apps' sound, silent with the ring/silent switch.
    private static let sessionCategory: Void = {
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.ambient)
        }
    }()
    #endif

    public init() {
        #if !os(macOS)
        SoundPlayer.sessionCategory
        #endif
        engine.attach(node)
        if #available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
            connected = (try? engine.connectNode(node, to: engine.mainMixerNode, format: format)) != nil
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connected = true
        }
    }

    /// A stretch of sound goes on (`SpeakerStream`): the speaker clicked
    /// within the last `SpeakerStream.hold`.
    public var isSounding: Bool { stream.isPlaying }

    /// Takes the speaker's `clicks` up to cycle `now`; plays them unless
    /// `muted`.  `quiet`: nothing clicks for a while after `now` (paused):
    /// the sound ends there, the cone settling.  A new stretch plays at
    /// once, after its lead: what is still queued goes (the last stretch's
    /// silence, or sound that came late), else it would play first.
    public func play(_ clicks: [UInt64], upTo now: UInt64, quiet: Bool = false, muted: Bool) {
        let starting = !stream.isPlaying
        let samples = stream.samples(clicks, upTo: now, quiet: quiet)
        guard !muted, !samples.isEmpty else { return }
        if starting { node.stop() }
        schedule(samples)
    }

    /// Plays `samples` at once (a whole sound), in place of what is still
    /// to play.
    public func play(_ samples: [Float]) {
        stop()
        schedule(samples)
    }

    /// Queues `samples` after what is still to play.
    private func schedule(_ samples: [Float]) {
        guard connected, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        do {
            if !engine.isRunning { try engine.start() }
            node.scheduleBuffer(buffer)
            if !node.isPlaying {
                if #available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
                    try node.playAudio()
                } else {
                    node.play()
                }
            }
        } catch {
            return
        }
    }

    /// Drops what is still to play.
    public func stop() {
        node.stop()
        stream.reset()
    }
}
