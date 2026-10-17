import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 用 ScreenCaptureKit 采集系统播放的声音（不采画面）。
/// 输出已经转换到 SpeechAnalyzer 需要的格式。
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    private let targetFormat: AVAudioFormat
    private let sampleQueue = DispatchQueue(label: "blog.illusion.LiveTrans.system-audio", qos: .userInitiated)
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var stopped = false

    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onError: ((Error) -> Void)?

    private(set) var isRunning = false

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
        super.init()
    }

    func start() async throws {
        stopped = false
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            guard let display = content.displays.first else {
                throw LiveTransError.noDisplay
            }

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )

            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(targetFormat.sampleRate)
            configuration.channelCount = Int(targetFormat.channelCount)
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.queueDepth = 5

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            // 纯音频也注册一个 screen 输出，避免 SCK 每秒打印 "stream output NOT found"。
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            isRunning = true
        } catch {
            throw LiveTransError.screenCaptureFailed(error.localizedDescription)
        }
    }

    func stop() async {
        isRunning = false
        stopped = true
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let sourceFormat = AVAudioFormat(streamDescription: &asbd) else {
            return
        }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                // noCopy 的 buffer 只在回调期间有效，异步使用前必须 copy
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ), let copy = buffer.copy() as? AVAudioPCMBuffer else {
                    return
                }

                if self.sourceFormat != sourceFormat || self.converter == nil {
                    self.sourceFormat = sourceFormat
                    self.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
                }
                guard let converter = self.converter,
                      let converted = AudioConversion.convert(copy, to: targetFormat, using: converter) else {
                    return
                }
                onBuffer?(converted)
            }
        } catch {
            onError?(error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        guard !stopped else { return }
        isRunning = false
        onError?(error)
    }
}
