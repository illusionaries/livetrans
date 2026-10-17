# 实时英译中 HUD（macOS）技术调研

> 调研环境：macOS 27.0.1 / Xcode 27.1 / Swift 6.4 / SDK 27。文中「实测」都是在这台机器上跑出来的，脚本在 `spikes/`。
>
> 结论先行：**纯 Swift 可行，而且不需要装 BlackHole 之类的虚拟声卡。** 系统声音用 ScreenCaptureKit，麦克风用 AVAudioEngine（或同一个 SCStream），识别用 Speech.framework 的 `SpeechAnalyzer`，翻译用系统自带的 `Translation.framework`，HUD 用 `NSPanel` + SwiftUI。

---

## 1. 先回答你问的三个问题

### 1.1 可以用 Swift 吗？

可以，而且这是 macOS 上最合适的方案：

| 需求 | 原生方案 | 最低系统 |
|---|---|---|
| 采系统声音 | ScreenCaptureKit（`SCStream` + `.audio`） | macOS 13 |
| 同时采麦克风 | 同一个 `SCStream` 的 `.microphone` 输出，或 `AVAudioEngine` | macOS 15（SCK 麦克风） |
| 流式英文识别 | `SpeechAnalyzer` + `SpeechTranscriber` | macOS 26 |
| 英译中 | `Translation.framework`（`TranslationSession`） | 15（无 UI 直接调用要 26） |
| 置顶 HUD | `NSPanel` + `NSHostingView` | 一直都有 |

不需要 Electron/Tauri，也不需要 Python。整套是本地推理，离线可用（语言包/语音模型预装后）。

### 1.2 能同时接麦克风和系统声音吗？

能。两条独立音频链路：

- **系统声音（对方）**：`SCStream`，`capturesAudio = true`。macOS 13 起可用，不需要虚拟声卡。
- **麦克风（我）**：两种做法
  1. `AVAudioEngine.inputNode.installTap`，最稳，缓冲区直接是 `AVAudioPCMBuffer`，还能开回声消除；
  2. 同一个 `SCStream` 设 `captureMicrophone = true`，再注册 `.microphone` 输出（macOS 15+）。好处是权限流程统一，坏处是麦克风 buffer 是设备原生格式，仍要转换，而且回声消除不如 AVAudioEngine 可控。

建议：**系统声音走 SCK，麦克风走 AVAudioEngine**。两条链路分别进两个 `SpeechAnalyzer`，天然带「我/对方」标签；如果混成一路，重叠说话时识别会互相干扰。

### 1.3 Mac 自带的翻译可以调用吗？

**可以。** 用 `Translation.framework`，它和系统「翻译」App 共用同一套本地模型和语言包。不是私有 API。

但有几个关键细节：

1. **语言包必须先安装。** en ↔ zh-Hans 要在「系统设置 > 通用 > 语言与地区 > 翻译语言」里装好（本机已装，实测 `LanguageAvailability.status == .installed`）。
2. **macOS 26+ 才能无 UI 直接创建 session：**
   ```swift
   let session = TranslationSession(
       installedSource: Locale.Language(identifier: "en"),
       target: Locale.Language(identifier: "zh-Hans")
   )
   let zh = try await session.translate("Hello everyone.").targetText
   ```
   官方文档原话：*"Another way for contexts where there's no UI, you can directly initialize the TranslationSession... throws an error if the languages aren't already installed."*
3. **直接创建的 session 不能弹下载框**：`canRequestDownloads == false`，语言包缺失时 `translate` 抛 `TranslationError.notInstalled`。如果要在 App 内引导安装，得用一个 SwiftUI 视图挂 `.translationTask(...)`，在里面调 `session.prepareTranslation()`；或者干脆把用户送到系统设置。
4. **它不是 Apple Intelligence 的「实时翻译」**（FaceTime/电话里那个），那个没有公开 API。我们能调用的是 `Translation.framework` 的文本翻译。
5. **质量**：日常会议够用，但偏直译、没有术语表。实测把 "pipeline" 译成「管道」、"API contract" 译成「API合同」。要专业术语就得换 LLM 或加后处理。

---

## 2. 本机实测结果

| 实验 | 结果 | 含义 |
|---|---|---|
| `Translation.framework` en→zh，5 个短句 | lowLatency 平均 **58ms**，highFidelity 平均 **39ms**（预热后） | 翻译不是瓶颈 |
| 第一次调用（冷启动） | 约 **1.1s** | 启动时先预热一句 |
| 一段 110 词英文 | 约 **290–500ms** | 长句也能接受 |
| `SpeechAnalyzer` 文件转写 | 逐词 partial，句末 final；无需语音识别授权 | 流式识别可用 |
| 系统声音 SCK（4 秒） | 197 个 buffer，16kHz 单声道 Float32，共 3.94s | 纯音频 2×2 配置可行 |
| 系统声音 → 识别 → 翻译，实时 | 句末 final 后约 **0.2–1.5s**（常见 0.5–1s）出中文；翻译本身 20–120ms | 端到端约 0.5–2s |
| partial 结果更新频率 | 约每 **0.9s** 一批 | 视觉上「逐词跳动」，不是每 20ms |

实时链路实测输出（`spikes/live-caption.swift`，一次运行）：

```
 2.43s … Hello
 3.59s EN: Hello, everyone.
       ZH: 大家好。   [翻译 22ms]
 5.39s EN: Thanks for joining the call.
       ZH: 感谢您加入通话。   [翻译 29ms]
 9.25s EN: Today we will talk about the new release schedule and the migration plan.
       ZH: 今天我们将讨论新的发布时间表和迁移计划。   [翻译 36ms]
```

**一个必须知道的坑**：SCK 输出 Float32，而本机 `SpeechAnalyzer.bestAvailableAudioFormat` 要 **16kHz / 单声道 / Int16**。直接把 Float32 buffer 喂进去会 crash（实测 SIGTRAP），必须用 `AVAudioConverter` 转。

---

## 3. 整体架构

```
┌─────────────┐   SCStream .audio    ┌────────────────────┐
│ 系统声音     │ ───────────────────▶ │ SystemAudioCapture │──▶ SpeechLane("them") ─┐
└─────────────┘   Float32 16k mono   └────────────────────┘                        │
                                                                                   ├──▶ Translator ──▶ CaptionStore ──▶ HUD
┌─────────────┐   AVAudioEngine tap   ┌────────────────────┐                        │
│ 麦克风       │ ───────────────────▶ │ MicrophoneCapture  │──▶ SpeechLane("me") ───┘
└─────────────┘   Float32 48k mono   └────────────────────┘
```

两条 lane 各自有独立的 `SpeechAnalyzer`；翻译和 UI 是汇聚点。

关键设计：

- **两条 lane 不要混音**：说话人标签、重叠语音、回声去重都更好处理。
- **只翻译 final**：partial 只更新原文（灰色）；final 到了再翻译并落成一条记录。这样不会每 0.9s 重翻一次、闪烁。
- **翻译串行化**：`TranslationSession` 不是 `Sendable`，放在一个 actor / `@MainActor` 里，一次只翻一条。
- **启动预热**：翻译第一句有 ~1.1s 冷启动，App 启动时先翻一句 "warm up"。

---

## 4. 关键实现

完整可运行版本见 `spikes/live-caption.swift`，下面只列骨架和容易踩的点。

### 4.1 系统声音（ScreenCaptureKit）

```swift
import ScreenCaptureKit

let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
let display = content.displays[0]   // 纯音频也需要一个 display 作为 filter
let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

let config = SCStreamConfiguration()
config.capturesAudio = true
config.excludesCurrentProcessAudio = true   // 不采自己 App 的声音（以后加 TTS 很重要）
config.sampleRate = 16_000
config.channelCount = 1
config.width = 2                            // 不采视频也要给合法尺寸，否则可能启动失败
config.height = 2
config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
config.queueDepth = 5

let stream = SCStream(filter: filter, configuration: config, delegate: sink)
try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: audioQueue)
try await stream.startCapture()
```

回调里：

```swift
func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, sb.isValid, sb.numSamples > 0 else { return }
    try sb.withAudioBufferList { abl, _ in
        // noCopy 的 buffer 只在回调期间有效，异步使用前必须 copy
        let src = AVAudioPCMBuffer(pcmFormat: srcFormat, bufferListNoCopy: abl.unsafePointer)!
        let copy = src.copy() as! AVAudioPCMBuffer
        // 再转成 analyzerFormat（16k/Int16）
        continuation.yield(AnalyzerInput(buffer: converted))
    }
}
```

注意：

- 这个 API 会触发「屏幕与系统音频录制」TCC 权限，即使你只采音频。
- 纯音频的 `width/height = 2` 是社区常用做法，本机验证可行。
- `sampleRate/channelCount` 可以对齐 analyzer 的采样率和声道数，但**格式**（Float32 → Int16）仍要自己转。
- 显示器休眠后 SCK 可能停；会议期间可以用 `ProcessInfo.beginActivity` 防休眠，或在 `didStopWithError` 里重启。

### 4.2 麦克风（AVAudioEngine）

```swift
let engine = AVAudioEngine()
let input = engine.inputNode

// 外放时建议开回声消除；注意它会改变输入格式，要在取 format 之前调用
try? input.setVoiceProcessingEnabled(true)

let hwFormat = input.outputFormat(forBus: 0)
input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
    // 转成 analyzerFormat 后 yield
}
try engine.start()
```

- 需要 `NSMicrophoneUsageDescription`，首次会弹麦克风权限。
- 如果不想处理 AEC，最简单的办法是提示用户戴耳机；否则外放时麦克风会把系统声音再收一遍，HUD 出现重复行。
- 也可以给麦克风单独一个 `SpeechAnalyzer`，和系统声音互不影响。

### 4.3 流式识别（SpeechAnalyzer + SpeechTranscriber）

```swift
import Speech

let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [.etiquetteReplacements],
    reportingOptions: [.volatileResults, .fastResults],  // partial + 低延迟
    attributeOptions: [.audioTimeRange]
)

// 模型没装时下载（首次可能几十 MB）
if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    try await request.downloadAndInstall()
}

let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])!
let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence: stream)

// 结果
for try await result in transcriber.results {
    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    if result.isFinal {
        // 落一条记录，送翻译
    } else {
        // 只更新「正在说」的灰色行
    }
}
```

要点：

- `transcriber.results` 是 `AsyncSequence`，partial 会不断替换，`result.isFinal` 才是稳定文本。
- `AnalysisContext.contextualStrings` 可以塞人名、产品名、缩写，显著改善专有名词识别。
- 实测**不需要** `SFSpeechRecognizer` 的语音识别授权（`authorizationStatus == .notDetermined` 也能跑）；但麦克风权限仍然需要。只有你保留 `SFSpeechRecognizer` 兜底时才需要 `NSSpeechRecognitionUsageDescription`。
- 结果更新约 0.9s 一批；想要更细的「逐词」视觉，只能靠 partial。

### 4.4 翻译（Translation.framework）

```swift
import Translation

let source = Locale.Language(identifier: "en")
let target = Locale.Language(identifier: "zh-Hans")

let availability = LanguageAvailability(preferredStrategy: .lowLatency)
guard await availability.status(from: source, to: target) == .installed else {
    // 引导用户去系统设置，或用 .translationTask 触发下载
    return
}

let session = TranslationSession(
    installedSource: source,
    target: target,
    preferredStrategy: .lowLatency   // macOS 26.4+；26.0–26.3 去掉这个参数
)
let zh = try await session.translate("Hello everyone.").targetText
```

- `LanguageAvailability.status` 的 `.supported` 表示「支持但没装」，`.installed` 才是能直接翻。
- 部署目标如果是 macOS 26.0，`TranslationSession.Strategy` / `LanguageAvailability(preferredStrategy:)`（26.4+）要包在 `if #available(macOS 26.4, *)` 里；否则直接去掉 `preferredStrategy` 参数。
- 直接创建的 session `canRequestDownloads == false`，不能弹下载框。要弹，用 SwiftUI：

  ```swift
  Text("准备翻译语言包…")
      .translationTask(.init(source: source, target: target)) { session in
          try? await session.prepareTranslation()   // 这里会弹系统下载授权
      }
  ```
  下载完成后，再用 `TranslationSession(installedSource:target:)` 做后台连续翻译。
- `TranslationSession` 不是 `Sendable`，别跨 actor 传；放在一个 actor 里串行调用。
- 翻译在设备上完成；Apple 文档说明可能收集 API 使用/性能指标（bundle id、语言对），但不含原文/译文。
- 质量预期：会议大意没问题；术语、长难句偏直译。要更好可以选 LLM（本地 Qwen / 云端），代价是延迟和隐私。

### 4.5 HUD（NSPanel + SwiftUI）

```swift
final class HUDPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // 配合 Info.plist 的 LSUIElement；也可在 AppDelegate 里 NSApp.setActivationPolicy(.accessory)
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = NSHostingView(rootView: content)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- `orderFrontRegardless()` 显示，不抢焦点。
- `level = .floating` 能压住普通窗口；要盖住全屏会议，靠 `[.canJoinAllSpaces, .fullScreenAuxiliary]`。如果某些全屏 App 仍压不住，再试 `.statusBar`（会盖住菜单栏，慎用）。
- `panel.sharingType = .none` 可以让 HUD 不出现在屏幕共享里（默认 `.readOnly` 会被共享）。
- 外观：`NSVisualEffectView` 或 SwiftUI `.ultraThinMaterial` + `RoundedRectangle(cornerRadius: 16)`。
- 布局：原文 12pt 灰色在上，译文 16–17pt 在下；`ScrollViewReader` 自动滚到底；partial 用斜体/更低透明度。
- 拖动：`isMovableByWindowBackground = true`；如果 SwiftUI 内容吃掉鼠标事件，就在背景放一个 `mouseDownCanMoveWindow = true` 的 NSView。
- 交互（关闭、透明度、点击穿透）建议放菜单栏 `NSStatusItem`，HUD 本体保持 `canBecomeKey == false`，避免抢焦点。
- 全局快捷键：Carbon `RegisterEventHotKey`（不需要辅助功能权限）；`NSEvent.addGlobalMonitorForEvents` 需要辅助功能授权。

### 4.6 编排（伪代码）

```swift
@MainActor
final class CaptionStore: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let source: String
        var translation: String?
    }
    @Published var lines: [Line] = []
    @Published var partial: String = ""

    func commit(_ text: String, translate: @escaping (String) async -> String?) {
        let line = Line(source: text)
        lines.append(line)
        Task {
            let zh = await translate(text)
            if let i = lines.firstIndex(where: { $0.id == line.id }) {
                lines[i].translation = zh
            }
        }
    }
}
```

结果循环里：

```swift
if result.isFinal {
    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { continue }
    // 去掉和上一条完全重复的（回声/重复 final）
    if text != lastFinal {
        lastFinal = text
        store.commit(text) { try? await translator.translate($0) }
    }
} else {
    store.partial = String(result.text.characters)
}
```

---

## 5. 权限与工程配置

### 5.1 Info.plist

```xml
<key>LSUIElement</key>
<true/>                                  <!-- 菜单栏 App，不显示 Dock 图标 -->
<key>NSMicrophoneUsageDescription</key>
<string>用于转录你说话的内容并实时翻译。</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>仅在使用 SFSpeechRecognizer 兜底时需要。</string>
<key>LSMinimumSystemVersion</key>
<string>26.0</string>
```

屏幕录制**没有**对应的 usage description key；第一次 `SCShareableContent` 时系统自动弹 TCC。

### 5.2 权限清单

| 权限 | 触发点 | 说明 |
|---|---|---|
| 屏幕与系统音频录制 | `SCShareableContent` / `SCStream.startCapture` | 即使只采音频也要给 |
| 麦克风 | `AVAudioEngine.start` / `SCStream` 麦克风 | Info.plist + TCC |
| 语音识别 | `SFSpeechRecognizer` | `SpeechAnalyzer` 实测不需要 |
| 辅助功能 | 全局键鼠监听 | 用 Carbon 热键可避开 |

调试时重置：

```sh
tccutil reset ScreenCapture com.example.LiveTrans
tccutil reset Microphone com.example.LiveTrans
```

### 5.3 打包/签名

- **一定要打成 `.app`**：TCC 基本按 bundle id + 签名识别；`swift run` 的裸可执行文件会借用终端权限，行为不稳定。
- 本地开发 ad-hoc 签名即可；分发用 Developer ID + notarization。
- 建议**非沙盒**。沙盒下麦克风要 `com.apple.security.device.audio-input`，屏幕录制在沙盒里的行为需要单独验证；上架 App Store 会更麻烦。
- SwiftPM 也能做原型：`swift build` 后手工拼 `LiveTrans.app/Contents/{MacOS,Info.plist,Resources}`；正式项目建议直接建 Xcode App target。

---

## 6. 延迟预算与优化

| 阶段 | 实测/预期 |
|---|---|
| SCK 音频缓冲 | ~20ms/块 |
| 识别 partial 延迟 | 语音开始后约 0.5–1.2s |
| final（句末静音判定） | 句末后约 0.2–1.5s，常见 0.5–1s |
| 翻译 | 20–120ms（短句），300–500ms（长段） |
| UI | 16ms |
| **端到端（句级）** | **约 0.5–2s，常见 1s 左右** |

优化顺序：

1. 启动时预热翻译模型（否则第一句多 ~1s）。
2. `SpeechAnalyzer` 用 `.processLifetime` 模型保留，避免反复加载。
3. `reportingOptions: [.volatileResults, .fastResults]` 是常用的低延迟组合（`fastResults` 可能牺牲一点准确率，可按需去掉）。
4. 只翻 final；如果嫌慢，可以对「稳定 partial」节流翻译（每 400–600ms 一次，只翻最后一句），但会闪烁。
5. 用 `AnalysisContext.contextualStrings` 提升人名/术语识别，减少翻错。
6. 长会议要裁掉 HUD 里的旧行（保留最近 50–100 条），否则内存和滚动都会变差。

---

## 7. 十个坑（按踩到的概率排序）

1. **格式不匹配直接 crash**：SCK Float32 → SpeechAnalyzer Int16，必须 `AVAudioConverter`。
2. **buffer 生命周期**：`bufferListNoCopy` 的 buffer 出了回调就失效，异步用之前 `copy()`。
3. **纯音频 SCK 也要 width/height**：设 2×2，别留 0。
4. **语言包没装**：直接 `TranslationSession` 不会弹下载，只会抛 `notInstalled`；要预检 + 引导。
5. **`TranslationSession` 非 Sendable**：放进 actor / MainActor 串行用。
6. **外放回声**：麦克风收进系统声音 → 重复字幕；耳机 / AEC / 文本去重三选一。
7. **final 延迟**：句末静音判定 + 约 0.9s 的结果批次，导致 0.2–1.5s 的抖动；这是「实时」的主要体感瓶颈。
8. **屏幕录制权限很宽**：用户可能介意；要解释清楚只采音频。Core Audio Taps（macOS 14.2+）是更细粒度的替代，但要搭 aggregate device，代码复杂。
9. **DRM/受保护音频**：部分受保护内容 SCK 采不到，表现为静音。
10. **显示器休眠/切换设备**：SCK 可能停、音频格式会变；监听 `didStopWithError`，格式变化时重建 converter。

---

## 8. 备选方案

| 环节 | 备选 | 什么时候用 |
|---|---|---|
| 识别 | `SFSpeechRecognizer`（on-device） | 支持 macOS < 26；有单次任务时长限制，需要定期重启任务 |
| 识别 | WhisperKit / whisper.cpp | 想要更好的英文准确率/术语，代价是延迟和内存 |
| 翻译 | 本地 LLM（Qwen3 / MLX / Ollama） | 要术语表、上下文、更自然的中文 |
| 翻译 | DeepL / Google / OpenAI API | 要质量、能联网；有成本和隐私问题 |
| 系统声音 | BlackHole 虚拟声卡 | 老系统/特殊路由；要用户装驱动 |
| 系统声音 | Core Audio Taps | 权限粒度更细（只采系统音频）；但要自己搭 aggregate device，实现复杂 |
| HUD | 菜单栏 popover | 不想遮挡屏幕；但不算 always-on-top |

---

## 9. 工作量

MVP（能开会用）：

| 天 | 内容 |
|---|---|
| 1 | Xcode App 骨架 + HUD 面板 + 菜单栏 |
| 2 | SCK 系统声音 + 麦克风 + 权限处理 |
| 3 | 两条 SpeechLane + partial/final UI |
| 4 | 翻译 + 语言包引导 + 去重/回声 |
| 5 | 设置、热键、崩溃恢复、打包 |

再花 1–2 周做：术语表、LLM 可选后端、历史记录、导出、多语言、自动更新。

---

## 10. 参考

- [TranslationSession — Apple Developer Documentation](https://developer.apple.com/documentation/translation/translationsession)（无 UI 初始化的官方说明）
- [LanguageAvailability](https://developer.apple.com/documentation/translation/languageavailability)
- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [WWDC25: Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [WWDC24: Meet the Translation API](https://developer.apple.com/videos/play/wwdc2024/10117/)
- [SCStreamConfiguration.captureMicrophone](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone)
- [hotchpotch/trn](https://github.com/hotchpotch/trn)：用 `TranslationSession(installedSource:target:preferredStrategy:)` 做 CLI 的现成例子，还有延迟对比
- [rryam/AuralKit](https://github.com/rryam/AuralKit)：SpeechAnalyzer 实时转写的完整参考实现（含 SCK 输入）
- [Recall.ai: How to use ScreenCaptureKit to capture microphone and meeting audio](https://www.recall.ai/blog/how-to-use-screencapturekit-to-record-a-meeting)：SCK 麦克风/系统声音的实践与限制

---

## 附：验证脚本

```sh
# 只测翻译
swiftc -O spikes/translate-bench.swift -o /tmp/translate-bench && /tmp/translate-bench

# 系统声音 -> 识别 -> 翻译
swiftc -O spikes/live-caption.swift -o /tmp/live-caption && /tmp/live-caption
```

先跑这两个，确认你机器上的语言包、权限、音频链路都通，再开始搭 App。
