import AVFoundation
import ShepCore

// Written for Shep.

/// Plays the finish bark: the recorded bark in `BarkSound` (ShepCore; CC0, see NOTICE), or the synthesized woof if it ever
/// could not be read. The samples go into an AVAudioPCMBuffer and out through AVAudioEngine and one AVAudioPlayerNode to the
/// system's default output, so the system volume applies on top of `volume` (from `BarkPolicy`).
@MainActor
final class BarkPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connected = false   // connected once, in the format of the first bark (the same every time)

    func play(volume: Double) {
        let recorded = BarkSound.samples(volume: volume)
        let rate = Double(recorded.isEmpty ? BarkSynth.defaultSampleRate : BarkSound.sampleRate)
        let samples = recorded.isEmpty ? BarkSynth.samples(volume: volume) : recorded
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { channel[i] = samples[i] }
        if !connected {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            connected = true
        }
        if !engine.isRunning {
            do { try engine.start() } catch { print("[shep] bark: audio engine did not start: \(error.localizedDescription)"); return }
        }
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        node.play()
    }
}
