import Foundation

/// The Apple II's speaker as sound samples.  Each click ($C030) moves the
/// cone to its other side, so the sound is a square wave with an edge at
/// every click: here averaged over each sample, and with the DC taken out as
/// the speaker's coupling does (a high pass at about 35 Hz), which lets the
/// cone settle after the last click.  The cone and the high pass keep their
/// state from one call to the next (`SpeakerStream`).
nonisolated struct SpeakerRenderer {
    static let sampleRate = 44_100
    /// Time for the cone to settle after the last click: a click's swing is
    /// down to 1/50,000 (after 20 ms still 1/80, a faint click if cut off).
    static let settle = sampleRate / 20
    static let volume = 0.4
    /// CPU cycles per sample.
    static let perSample = Apple2.clock / Double(sampleRate)
    private static let pole = 0.995

    /// The cone's side (-1 or 1), and the high pass's last input and output.
    private var side = -1.0
    private var input = -1.0
    private var output = 0.0

    /// `count` samples from here on, with `clicks` at their cycles from here
    /// (in order); those past the last sample are left out.
    mutating func samples(_ count: Int, clicks: [Double]) -> [Float] {
        var t = 0.0, next = 0
        return (0 ..< count).map { i in
            let sampleEnd = Double(i + 1) * Self.perSample
            var sum = 0.0
            while next < clicks.count && clicks[next] < sampleEnd {
                sum += side * (clicks[next] - t)
                t = clicks[next]
                side = -side
                next += 1
            }
            sum += side * (sampleEnd - t)
            t = sampleEnd
            let x = sum / Self.perSample
            output = x - input + Self.pole * output
            input = x
            return Float(max(-1, min(1, output * Self.volume)))
        }
    }

    /// The cone has settled where it is.
    mutating func rest() {
        input = side
        output = 0
    }
}

/// The speaker as the machine runs (`SpeakerRenderer`): the clicks as they
/// come, rendered to the cycle up to where the machine is, so a tune taken
/// frame by frame keeps its time.  A stretch of sound goes on through the
/// silences of up to `hold`; after that the stream rests, and the next click
/// starts a new stretch at once.  `quiet` (nothing will click for a while:
/// the machine paused, or the end of a recording) ends the stretch
/// at once with the cone settling, even past where the machine is: going on,
/// its samples would run out while the cone still moves, and the player
/// would cut it off – a click.
nonisolated struct SpeakerStream {
    /// The silence after a click that is still part of a stretch: a tune's
    /// pauses keep their length.
    static let hold = Apple2.clock / 4
    /// The least a stretch starts with, silence ahead of its first samples:
    /// a frame may come late by that much before the sound breaks up.
    static let lead = SpeakerRenderer.sampleRate / 25

    private var speaker = SpeakerRenderer()
    /// The cycle the samples reach (nil: resting); not a whole cycle, as a
    /// sample takes 23.14 cycles.
    private var position: Double?
    /// The clicks not rendered yet, and the last click.
    private var pending: [UInt64] = []
    private var lastClick: UInt64 = 0

    /// Rendering, not resting.
    var isPlaying: Bool { position != nil }

    /// The samples from where the stream is to cycle `now`, with `clicks`
    /// (in order, the machine's since the last call); empty while it rests.
    /// A stretch starts with at least `lead` samples.  `quiet`: nothing
    /// clicks for a while after `now`, so the stretch ends with the cone
    /// settled (`SpeakerRenderer.settle` after its last click).
    mutating func samples(_ clicks: [UInt64], upTo now: UInt64, quiet: Bool = false, lead: Int = lead) -> [Float] {
        pending += clicks
        if let last = clicks.last { lastClick = last }
        let starting = position == nil
        if starting {
            guard let first = pending.first else { return [] }
            position = Double(first)
            speaker.rest()
        }
        let start = position!
        let settled = Double(lastClick) + Double(SpeakerRenderer.settle) * SpeakerRenderer.perSample
        let end = quiet ? settled : min(Double(now), Double(lastClick) + Self.hold)
        let count = max(0, Int((end - start) / SpeakerRenderer.perSample))
        let reached = start + Double(count) * SpeakerRenderer.perSample
        let rendered = pending.prefix { Double($0) < reached }
        var out = speaker.samples(count, clicks: rendered.map { max(0, Double($0) - start) })
        pending.removeFirst(rendered.count)
        position = reached
        if starting && out.count < lead {
            out = [Float](repeating: 0, count: lead - out.count) + out
        }
        if pending.isEmpty && (quiet || reached + SpeakerRenderer.perSample > Double(lastClick) + Self.hold) {
            position = nil
        }
        return out
    }

    /// Drops what is pending and rests.
    mutating func reset() {
        position = nil
        pending = []
    }
}
