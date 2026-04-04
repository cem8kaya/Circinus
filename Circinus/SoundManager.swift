import AVFoundation

// MARK: - SoundManager

/// Synthesizes short audio feedback using AVAudioEngine sine-wave generation.
/// No external audio asset files are required.
final class SoundManager {

    static let shared = SoundManager()

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let sampleRate: Double = 44100
    private let format: AVAudioFormat

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        setupEngine()
    }

    private func setupEngine() {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.5

        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            return
        }

        self.engine = engine
        self.playerNode = player
    }

    // MARK: - Tone generation

    private func playTone(frequency: Double, duration: Double, volume: Float = 0.15) {
        guard let player = playerNode,
              let engine = engine,
              engine.isRunning else { return }

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        let fadeFrames = min(Int(sampleRate * 0.005), Int(frameCount) / 2)

        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            // Envelope: quick fade-in / fade-out to avoid clicks
            var envelope: Double = 1.0
            if i < fadeFrames {
                envelope = Double(i) / Double(fadeFrames)
            } else if i > Int(frameCount) - fadeFrames {
                envelope = Double(Int(frameCount) - i) / Double(fadeFrames)
            }
            data[i] = Float(sin(2.0 * .pi * frequency * t) * envelope * Double(volume))
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Play a two-tone sequence (for chime effects).
    private func playChime(frequencies: [(Double, Double, Float)]) {
        var delay: TimeInterval = 0
        for (freq, dur, vol) in frequencies {
            let d = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                self?.playTone(frequency: freq, duration: dur, volume: vol)
            }
            delay += dur * 0.6
        }
    }

    // MARK: - Sound effects

    /// Soft mechanical click for tile rotation.
    func playRotate() {
        playTone(frequency: 1200, duration: 0.035, volume: 0.08)
    }

    /// Gentle ascending chime when a connection is made.
    func playConnect() {
        playChime(frequencies: [
            (880, 0.07, 0.10),
            (1320, 0.09, 0.08)
        ])
    }

    /// Triumphant short jingle on win.
    func playWin() {
        playChime(frequencies: [
            (784, 0.12, 0.14),
            (988, 0.12, 0.14),
            (1318, 0.22, 0.16)
        ])
    }

    /// Soft pop for button taps.
    func playButtonTap() {
        playTone(frequency: 900, duration: 0.025, volume: 0.06)
    }

    /// Reverse click sound for undo.
    func playUndo() {
        playTone(frequency: 600, duration: 0.04, volume: 0.07)
    }
}
