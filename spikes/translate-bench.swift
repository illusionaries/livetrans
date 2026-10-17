// translate-bench.swift
// 只验证 macOS 自带翻译：en -> zh-Hans，比较 lowLatency / highFidelity。
//
//   swiftc -O spikes/translate-bench.swift -o /tmp/translate-bench && /tmp/translate-bench

import Foundation
import Translation

let source = Locale.Language(identifier: "en")
let target = Locale.Language(identifier: "zh-Hans")
let sentences = [
    "Let's align on the timeline for the next release.",
    "I think we should postpone the migration until next week.",
    "Can you share the dashboard with the design team?",
    "The latency is around two hundred milliseconds.",
    "We need to double-check the pricing before we commit.",
]

for strategy in [TranslationSession.Strategy.lowLatency, .highFidelity] {
    let availability = LanguageAvailability(preferredStrategy: strategy)
    let status = await availability.status(from: source, to: target)
    guard status == .installed else {
        print("语言包未安装（\(status)）：系统设置 > 通用 > 语言与地区 > 翻译语言")
        exit(1)
    }

    let session = TranslationSession(
        installedSource: source,
        target: target,
        preferredStrategy: strategy
    )
    _ = try? await session.translate("warm up")   // 冷启动约 1s，先预热

    var times: [Int] = []
    print("== \(strategy == .lowLatency ? "lowLatency" : "highFidelity") ==")
    for sentence in sentences {
        let t0 = Date()
        guard let response = try? await session.translate(sentence) else { continue }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        times.append(ms)
        print("  \(ms)ms  \(response.targetText)")
    }
    if !times.isEmpty {
        print("  avg \(times.reduce(0, +) / times.count)ms\n")
    }
}
