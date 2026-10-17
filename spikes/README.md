# Spikes：先用两个最小脚本验证可行性

这两个脚本是调研时的实测代码，跑通即可确认「系统声音 → 流式英文识别 → 本地英译中」整条链路。

环境要求：

- macOS 26.4+（SpeechAnalyzer 需要 26.0+；`lowLatency` 翻译策略需要 26.4+）
- Xcode / Swift 6.x（本机为 Xcode 27.1、Swift 6.4、macOS 27.0.1）
- 已安装 en ↔ zh-Hans 翻译语言包（系统设置 > 通用 > 语言与地区 > 翻译语言）
- 运行终端有「屏幕与系统音频录制」权限（第一次运行会弹窗，或到系统设置里勾选）

## 1. 只测翻译

```sh
swiftc -O spikes/translate-bench.swift -o /tmp/translate-bench
/tmp/translate-bench
```

本机结果（warm）：

```
lowLatency   avg 58ms
highFidelity avg 39ms
```

## 2. 端到端：系统声音 → 英文识别 → 中文

```sh
swiftc -O spikes/live-caption.swift -o /tmp/live-caption
/tmp/live-caption
# 也可以换成自己的句子：
/tmp/live-caption "Let's ship the beta on Friday."
```

脚本自己用 `/usr/bin/say` 播一段英文，ScreenCaptureKit 捕获系统输出，SpeechAnalyzer 出英文临时/最终结果，最终结果再交给 Translation 翻译成中文。

预期输出（节选）：

```
ASR 期望格式: <AVAudioFormat 1 ch, 16000 Hz, Int16>
开始采集系统声音（Ctrl+C 结束）
音频转换: <AVAudioFormat 1 ch, 16000 Hz, Float32> -> <AVAudioFormat 1 ch, 16000 Hz, Int16>
 2.43s … Hello
 3.59s EN: Hello, everyone.
       ZH: 大家好。   [翻译 22ms]
 5.39s EN: Thanks for joining the call.
       ZH: 感谢您加入通话。   [翻译 29ms]
 9.25s EN: Today we will talk about the new release schedule and the migration plan.
       ZH: 今天我们将讨论新的发布时间表和迁移计划。   [翻译 36ms]
```

## 注意

- `say` 的声音即使从耳机播放，ScreenCaptureKit 也能在系统混音处采到。
- 纯命令行进程的 TCC 授权归属于终端（Terminal/iTerm 等）。正式 App 必须打成 `.app`、带稳定 bundle id，否则每次换路径都可能重新授权。
- `AVAudioConverter` 那一步不能省：ScreenCaptureKit 输出 Float32，而 `SpeechAnalyzer` 在本机要求 16 kHz / 单声道 / Int16，直接喂错格式会 crash（实测 SIGTRAP）。
- 这是调研用脚本，没有麦克风、HUD、错误恢复；正式工程见 `../RESEARCH.md` 的架构与代码片段。
