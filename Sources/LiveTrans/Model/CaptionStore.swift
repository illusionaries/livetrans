import Foundation
import Combine

/// 所有会显示在 HUD 上的状态。只在主线程读写。
@MainActor
final class CaptionStore: ObservableObject {

    enum Lane: String, CaseIterable, Hashable {
        case system   // 系统声音 / 对方
        case mic      // 麦克风 / 我
    }

    struct Line: Identifiable {
        let id: UUID
        let lane: Lane
        let source: String
        var translation: String?
        let createdAt: Date

        init(id: UUID = UUID(), lane: Lane, source: String,
             translation: String? = nil, createdAt: Date = Date()) {
            self.id = id
            self.lane = lane
            self.source = source
            self.translation = translation
            self.createdAt = createdAt
        }
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var partials: [Lane: String] = [:]
    /// 最近更新的 partial 来自哪条 lane；极简模式只显示这一条。
    @Published private(set) var partialLane: Lane?

    @Published var statusText: String = L10n.t("status.starting")
    @Published var systemActive: Bool = false
    @Published var micActive: Bool = false
    @Published var translatorReady: Bool = false
    @Published var needsLanguagePack: Bool = false
    @Published var systemError: String?
    @Published var micError: String?

    var isListening: Bool { systemActive || micActive }

    private var recent: [(lane: Lane, norm: String, at: Date)] = []
    private let maxLines = 80
    private let dedupeWindow: TimeInterval = 8

    // MARK: - 临时结果

    func setPartial(_ text: String, lane: Lane) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            partials[lane] = nil
            if partialLane == lane {
                partialLane = partials.keys.first
            }
        } else {
            partials[lane] = trimmed
            partialLane = lane
        }
    }

    func clearPartial(lane: Lane) {
        partials[lane] = nil
        if partialLane == lane {
            partialLane = partials.keys.first
        }
    }

    func clearAllPartials() {
        partials.removeAll()
        partialLane = nil
    }

    // MARK: - 最终结果

    /// 返回新行的 id；如果是重复（回声/重复 final）则返回 nil。
    @discardableResult
    func appendFinal(lane: Lane, source: String) -> UUID? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let norm = normalize(text)
        guard !norm.isEmpty else { return nil }

        let now = Date()
        recent.removeAll { now.timeIntervalSince($0.at) > dedupeWindow }

        for entry in recent {
            if entry.norm == norm { return nil }
            guard entry.lane != lane else { continue }
            if similarity(entry.norm, norm) >= 0.8 { return nil }
        }

        let line = Line(lane: lane, source: text)
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        partials[lane] = nil
        if partialLane == lane {
            partialLane = partials.keys.first
        }
        recent.append((lane, norm, now))
        return line.id
    }

    func setTranslation(_ text: String?, for id: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[index].translation = text
    }

    // MARK: - 文本归一化 / 去重

    private func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let characters = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(characters)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) {
            let shorter = min(a.count, b.count)
            let longer = max(a.count, b.count)
            if longer > 0, Double(shorter) / Double(longer) > 0.6 { return 1 }
        }
        let setA = Set(a.split(separator: " "))
        let setB = Set(b.split(separator: " "))
        guard !setA.isEmpty, !setB.isEmpty else { return 0 }
        return Double(setA.intersection(setB).count) / Double(setA.union(setB).count)
    }
}
