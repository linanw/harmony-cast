import AVFoundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func pcm(_ value: Int16, frames: Int = 19200) -> Data {
    var samples = [Int16](repeating: value.littleEndian, count: frames * 2)
    return samples.withUnsafeMutableBytes { Data($0) }
}

let engine = AVAudioEngine()
let audio = AudioPlayback(engine: engine)
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!

func renderSignal() throws -> (Float, Float) {
    var minimum: Float = 0
    var maximum: Float = 0
    for _ in 0..<8 {
        let result = try engine.renderOffline(1024, to: rendered)
        require(result == .success, "Offline audio rendering failed")
        for channel in 0..<2 {
            for frame in 0..<Int(rendered.frameLength) {
                let sample = rendered.floatChannelData![channel][frame]
                minimum = min(minimum, sample)
                maximum = max(maximum, sample)
            }
        }
    }
    return (minimum, maximum)
}

require(!audio.isEnabled, "First launch must be silent")
audio.consume(pcm(12000))
require(!engine.isRunning, "Muted incoming PCM started playback")
audio.setEnabled(true)
audio.consume(pcm(12000))
let first = try renderSignal()
require(first.1 > 0.3, "Enabled audio did not reach the output")
audio.setEnabled(false)
require(!engine.isRunning, "Mute did not immediately stop queued playback")
audio.consume(pcm(12000))
require(!engine.isRunning, "Muted PCM restarted the engine")
audio.setEnabled(true)
require(!engine.isRunning, "Unmute replayed buffered audio without fresh PCM")
audio.consume(pcm(-12000))
let second = try renderSignal()
require(second.0 < -0.3 && second.1 < 0.001, "Unmute leaked stale positive audio")
audio.reset()
require(audio.isEnabled && !engine.isRunning, "Disconnect lost the selected audio setting")
audio.consume(pcm(8000))
let third = try renderSignal()
require(third.1 > 0.2, "Reconnect did not resume enabled playback")
audio.setEnabled(false)
audio.reset()
audio.consume(pcm(8000))
require(!engine.isRunning, "Reconnect ignored mute")
print("PASS: default mute, real PCM rendering, immediate stop, no stale replay, reconnect preference")
