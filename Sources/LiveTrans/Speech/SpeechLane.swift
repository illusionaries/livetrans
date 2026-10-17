import AVFoundation
import Speech

/// 一条语音识别链路：SpeechAnalyzer + SpeechTranscriber。
/// 输入必须已经是 `format` 指定的格式。
final class SpeechLane {

    enum Kind: String {
        case system
        case mic
    }

    let kind: Kind
    let format: AVAudioFormat

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var resultTask: Task<Void, Never>?
    private var stopped = false

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    init(kind: Kind, locale: Locale = Locale(identifier: "en-US")) async throws {
        self.kind = kind

        guard SpeechTranscriber.isAvailable else {
            throw LiveTransError.speechUnavailable
        }
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LiveTransError.speechUnavailable
        }

        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [.etiquetteReplacements],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw LiveTransError.audioFormatUnavailable
        }
        self.format = format

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        self.analyzer = analyzer

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = continuation
        try await analyzer.start(inputSequence: stream)

        startResultTask()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard !stopped else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultTask?.cancel()
        resultTask = nil
    }

    private static func hasMeaningfulText(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private func startResultTask() {
        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // 过滤纯标点/空结果（静音时偶尔会冒出 "."）
                    guard Self.hasMeaningfulText(text) else { continue }
                    if result.isFinal {
                        self.onFinal?(text)
                    } else {
                        self.onPartial?(text)
                    }
                }
            } catch {
                if !self.stopped {
                    self.onError?(error)
                }
            }
        }
    }
}
