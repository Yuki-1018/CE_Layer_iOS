import AVFoundation

final class AudioOutput {
    private let engine = AVAudioEngine()
    private let bridge: Win95CoreBridge
    private var source: AVAudioSourceNode?

    init(bridge: Win95CoreBridge) {
        self.bridge = bridge
    }

    func start() throws {
        guard source == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(48_000)
        // A stable 512-frame render quantum keeps latency reasonable while
        // leaving enough time for the emulator thread to produce audio.
        try? session.setPreferredIOBufferDuration(512.0 / 48_000.0)
        try session.setActive(true)

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ) else { return }

        let bridge = self.bridge
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let list = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let audioBuffer = list.first, let raw = audioBuffer.mData else { return noErr }
            let bufferFrames = Int(audioBuffer.mDataByteSize) / (MemoryLayout<Int16>.size * 2)
            let safeFrames = min(Int(frameCount), bufferFrames)
            _ = bridge.readAudioFrames(raw.assumingMemoryBound(to: Int16.self), maxFrames: UInt(safeFrames))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.source = source
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
