import AVFoundation

// Called only on the receiver queue; playback completions use the lock below.
final class AudioPlayback {
    private let engine: AVAudioEngine
    private(set) var isEnabled = false
    var onFailure: ((String) -> Void)?
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private let lock = NSLock()
    private var queuedFrames = 0
    private var generation = 0

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        // Stop already scheduled buffers immediately; re-enabling starts fresh.
        if !enabled { reset() }
    }

    func reset() {
        player.stop()
        engine.stop()
        lock.lock()
        generation += 1
        queuedFrames = 0
        lock.unlock()
    }

    func consume(_ data: Data) {
        guard isEnabled, data.count % 4 == 0 else { return }
        let frames = data.count / 4
        guard frames > 0, frames <= 48000,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        if !engine.isRunning {
            do { try engine.start(); player.play() }
            catch { onFailure?(error.localizedDescription); return }
        }
        lock.lock()
        let session = generation
        let overloaded = queuedFrames + frames > 48000
        if !overloaded { queuedFrames += frames }
        lock.unlock()
        guard !overloaded else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for frame in 0..<frames {
                for channel in 0..<2 {
                    let sample = raw.loadUnaligned(fromByteOffset: frame * 4 + channel * 2, as: Int16.self)
                    channels[channel][frame] = Float(Int16(littleEndian: sample)) / 32768
                }
            }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if session == self.generation { self.queuedFrames -= frames }
            self.lock.unlock()
        }
    }
}
