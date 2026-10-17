import Foundation
import Combine

/// 音频相关、需要跨启动保留的设置。
@MainActor
final class AudioSettings: ObservableObject {

    @Published var aecEnabled: Bool { didSet { save() } }

    private static let aecKey = "LiveTrans.audio.aec"

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: Self.aecKey) as? Bool
        aecEnabled = stored ?? true
        if stored == nil {
            defaults.set(aecEnabled, forKey: Self.aecKey)
        }
    }

    private func save() {
        UserDefaults.standard.set(aecEnabled, forKey: Self.aecKey)
    }
}
