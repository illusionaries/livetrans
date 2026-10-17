import AVFoundation
import os

/// 用 AVAudioEngine 采集麦克风，并转换成 SpeechAnalyzer 需要的格式。
final class MicrophoneCapture {

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let useVoiceProcessing: Bool
    private let log = Logger(subsystem: "blog.illusion.LiveTrans", category: "mic")
    private var converter: AVAudioConverter?

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var isRunning = false

    init(targetFormat: AVAudioFormat, useVoiceProcessing: Bool = true) {
        self.targetFormat = targetFormat
        self.useVoiceProcessing = useVoiceProcessing
    }

    func start() throws {
        let input = engine.inputNode
        guard useVoiceProcessing else {
            try startEngine(input: input, voiceProcessing: false)
            return
        }
        do {
            // 外放时用系统 AEC 抵消扬声器回声；失败则退回普通采集。
            try startEngine(input: input, voiceProcessing: true)
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            try startEngine(input: input, voiceProcessing: false)
        }
    }

    private func startEngine(input: AVAudioInputNode, voiceProcessing: Bool) throws {
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
        } else {
            try? input.setVoiceProcessingEnabled(false)
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw LiveTransError.microphoneUnavailable
        }
        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            throw LiveTransError.audioFormatUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.converter else { return }
            if let converted = AudioConversion.convert(buffer, to: self.targetFormat, using: converter) {
                self.onBuffer?(converted)
            }
        }

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            log.info("mic engine started, voiceProcessing=\(voiceProcessing, privacy: .public), format=\(hardwareFormat.description, privacy: .public)")
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
