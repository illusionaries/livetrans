// live-caption.swift
// 端到端验证：系统声音 -> SpeechAnalyzer 流式英文识别 -> Apple Translation 英译中
//
// 运行（macOS 26.4+，需要给终端「屏幕与系统音频录制」权限）：
//   swiftc -O spikes/live-caption.swift -o /tmp/live-caption
//   /tmp/live-caption
//   /tmp/live-caption "Your own English sentence."
//
// 说明：
// - 用 `say` 朗读一段英文，声音会走系统输出，被 ScreenCaptureKit 采集；
// - 这不是一个 App，只是验证 API 可行性；正式版应放进 .app bundle 以稳定 TCC 授权。
// - 如果没装 en<->zh 语言包，会提示去「系统设置 > 通用 > 语言与地区 > 翻译语言」安装。

import Foundation
import AVFoundation
import Speech
import ScreenCaptureKit
import Translation

setvbuf(stdout, nil, _IONBF, 0)

let sourceLanguage = Locale.Language(identifier: "en")
let targetLanguage = Locale.Language(identifier: "zh-Hans")
let start = Date()

func stamp() -> String {
    String(format: "%5.2fs", Date().timeIntervalSince(start))
}

// MARK: - 1. 检查/准备翻译语言包

let availability = LanguageAvailability(preferredStrategy: .lowLatency)
let status = await availability.status(from: sourceLanguage, to: targetLanguage)
guard status == .installed else {
    print("""
    翻译语言包未安装（status=\(status)）。
    请打开：系统设置 > 通用 > 语言与地区 > 翻译语言，安装 English 与简体中文。
    注意：直接创建的 TranslationSession 不能弹下载框，canRequestDownloads == false；
    若要在 App 内引导下载，需要用 SwiftUI 的 .translationTask。
    """)
    exit(1)
}

// 预热：第一次调用会有约 1 秒的模型加载开销
let translator = TranslationSession(
    installedSource: sourceLanguage,
    target: targetLanguage,
    preferredStrategy: .lowLatency
)
_ = try? await translator.translate("warm up")

// MARK: - 2. 流式语音识别

let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [.etiquetteReplacements],
    reportingOptions: [.volatileResults, .fastResults],
    attributeOptions: [.audioTimeRange]
)

if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    print("正在下载英文语音模型…")
    try await request.downloadAndInstall()
}

guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
    fatalError("SpeechTranscriber 没有可用的音频格式")
}
print("ASR 期望格式: \(analyzerFormat)")

let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence: inputStream)

let resultsTask = Task {
    var showingPartial = false
    for try await result in transcriber.results {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { continue }
        if result.isFinal {
            if showingPartial {
                print("")
                showingPartial = false
            }
            let t0 = Date()
            let zh = (try? await translator.translate(text))?.targetText ?? "<翻译失败>"
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("\(stamp()) EN: \(text)")
            print("         ZH: \(zh)   [翻译 \(ms)ms]")
        } else {
            // 临时结果（会不断被后面的结果覆盖），真实 HUD 里用灰色/斜体显示
            showingPartial = true
            let tail = text.count > 120 ? "…" + text.suffix(120) : text
            print("\u{1B}[2K\r\(stamp()) … \(tail)", terminator: "")
        }
    }
}

// MARK: - 3. 采集系统声音

final class SystemAudioSink: NSObject, SCStreamOutput, SCStreamDelegate {
    private let targetFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let srcFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                // noCopy 的 buffer 只在回调期间有效，必须 copy 后再异步使用
                guard let src = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                                 bufferListNoCopy: audioBufferList.unsafePointer),
                      let srcCopy = src.copy() as? AVAudioPCMBuffer else { return }

                if converter == nil || sourceFormat != srcFormat {
                    sourceFormat = srcFormat
                    converter = AVAudioConverter(from: srcFormat, to: targetFormat)
                    print("音频转换: \(srcFormat) -> \(targetFormat)")
                }
                guard let converter else { return }

                // ScreenCaptureKit 输出 Float32，而 SpeechAnalyzer 这里要 Int16，必须转换
                let capacity = AVAudioFrameCount(
                    Double(srcCopy.frameLength) * targetFormat.sampleRate / srcFormat.sampleRate
                ) + 64
                guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

                var error: NSError?
                var supplied = false
                converter.convert(to: out, error: &error) { _, outStatus in
                    if supplied {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    outStatus.pointee = .haveData
                    return srcCopy
                }
                if let error {
                    print("convert error: \(error)")
                    return
                }
                continuation.yield(AnalyzerInput(buffer: out))
            }
        } catch {
            print("audio buffer error: \(error)")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        print("stream stopped: \(error)")
    }
}

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
guard let display = content.displays.first else {
    fatalError("没有找到显示器；SCStream 需要一个 display 作为 filter")
}

let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
let configuration = SCStreamConfiguration()
configuration.capturesAudio = true
configuration.excludesCurrentProcessAudio = true   // 不采自己 App 播放的声音
configuration.sampleRate = Int(analyzerFormat.sampleRate)
configuration.channelCount = Int(analyzerFormat.channelCount)
configuration.width = 2                            // 纯音频也要给一个合法尺寸
configuration.height = 2
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
configuration.queueDepth = 5

let sink = SystemAudioSink(targetFormat: analyzerFormat, continuation: inputContinuation)
let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "livetrans.audio"))
try await stream.startCapture()
print("开始采集系统声音（Ctrl+C 结束）")

// MARK: - 4. 用 say 制造一段英文语音

let spokenText = CommandLine.arguments.dropFirst().joined(separator: " ").isEmpty
    ? "Hello everyone, thanks for joining the call. Today we will talk about the new release schedule and the migration plan."
    : CommandLine.arguments.dropFirst().joined(separator: " ")

let say = Process()
say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
say.arguments = ["-v", "Samantha", spokenText]
try? say.run()

try? await Task.sleep(nanoseconds: 14_000_000_000)

await stream.stopCapture()
inputContinuation.finish()
try? await analyzer.finalizeAndFinishThroughEndOfInput()
_ = try? await resultsTask.value
print("\n完成")
