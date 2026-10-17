import Foundation
import Combine

/// 极简模式的外观设置。只影响 HUD，不碰识别/翻译。
@MainActor
final class AppearanceSettings: ObservableObject {

    struct Defaults {
        static let backgroundOpacity = 0.0      // 0 = 完全透明
        static let useMaterial = false
        static let height = 180.0
        static let width = 760.0
        static let lineCount = 2
        static let sourceFontSize = 12.5
        static let translationFontSize = 19.0
    }

    @Published var backgroundOpacity: Double { didSet { save() } }
    @Published var useMaterial: Bool { didSet { save() } }
    @Published var height: Double { didSet { save() } }
    @Published var width: Double { didSet { save() } }
    @Published var lineCount: Int { didSet { save() } }
    @Published var sourceFontSize: Double { didSet { save() } }
    @Published var translationFontSize: Double { didSet { save() } }

    private let store = UserDefaults.standard

    private enum Key {
        static let opacity = "LiveTrans.appearance.opacity"
        static let material = "LiveTrans.appearance.material"
        static let height = "LiveTrans.appearance.height"
        static let width = "LiveTrans.appearance.width"
        static let lineCount = "LiveTrans.appearance.lines"
        static let sourceFont = "LiveTrans.appearance.sourceFont"
        static let translationFont = "LiveTrans.appearance.translationFont"
    }

    init() {
        let defaults = UserDefaults.standard
        backgroundOpacity = defaults.object(forKey: Key.opacity) as? Double
            ?? Defaults.backgroundOpacity
        useMaterial = defaults.object(forKey: Key.material) as? Bool
            ?? Defaults.useMaterial
        height = defaults.object(forKey: Key.height) as? Double
            ?? Defaults.height
        width = defaults.object(forKey: Key.width) as? Double
            ?? Defaults.width
        lineCount = defaults.object(forKey: Key.lineCount) as? Int
            ?? Defaults.lineCount
        sourceFontSize = defaults.object(forKey: Key.sourceFont) as? Double
            ?? Defaults.sourceFontSize
        translationFontSize = defaults.object(forKey: Key.translationFont) as? Double
            ?? Defaults.translationFontSize
    }

    func reset() {
        backgroundOpacity = Defaults.backgroundOpacity
        useMaterial = Defaults.useMaterial
        height = Defaults.height
        width = Defaults.width
        lineCount = Defaults.lineCount
        sourceFontSize = Defaults.sourceFontSize
        translationFontSize = Defaults.translationFontSize
    }

    private func save() {
        store.set(backgroundOpacity, forKey: Key.opacity)
        store.set(useMaterial, forKey: Key.material)
        store.set(height, forKey: Key.height)
        store.set(width, forKey: Key.width)
        store.set(lineCount, forKey: Key.lineCount)
        store.set(sourceFontSize, forKey: Key.sourceFont)
        store.set(translationFontSize, forKey: Key.translationFont)
    }
}
