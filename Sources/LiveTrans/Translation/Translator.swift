import Foundation
import Translation

/// 串行使用一个 TranslationSession（它不是 Sendable，不能跨 actor 传）。
actor Translator {

    enum State: Equatable {
        case unknown
        case ready
        case missingLanguagePack
        case unsupported
        case failed(String)
    }

    private(set) var state: State = .unknown
    private var session: TranslationSession?

    private let sourceLanguage = Locale.Language(identifier: "en")
    private let targetLanguage = Locale.Language(identifier: "zh-Hans")

    func prepare() async {
        let availability = LanguageAvailability()
        let status = await availability.status(from: sourceLanguage, to: targetLanguage)

        switch status {
        case .installed:
            if #available(macOS 26.4, *) {
                session = TranslationSession(
                    installedSource: sourceLanguage,
                    target: targetLanguage,
                    preferredStrategy: .lowLatency
                )
            } else {
                session = TranslationSession(
                    installedSource: sourceLanguage,
                    target: targetLanguage
                )
            }
            // 第一次调用有约 1s 的模型加载开销，这里先预热。
            _ = try? await session?.translate("warm up")
            state = .ready
        case .supported:
            state = .missingLanguagePack
        case .unsupported:
            state = .unsupported
        @unknown default:
            state = .failed(L10n.t("error.translation_state_unknown"))
        }
    }

    func translate(_ text: String) async throws -> String {
        guard let session else {
            throw LiveTransError.translationUnavailable
        }
        let response = try await session.translate(text)
        return response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
