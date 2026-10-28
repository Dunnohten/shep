import AVFoundation
import ShepCore

// Written for Shep.

/// Plays the finish woof. The samples come from `BarkSynth` (ShepCore), synthesized at play time: no audio file exists anywhere.
/// They go into an AVAudioPCMBuffer and out through AVAudioEngine and one AVAudioPlayerNode.
@MainActor
final class BarkPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var connected = false

    func play(volume: Double) {
        let rate = Double(BarkSynth.defaultSampleRate)
        let samples = BarkSynth.samples(volume: volume)
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
