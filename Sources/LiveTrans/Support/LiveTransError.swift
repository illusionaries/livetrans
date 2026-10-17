import Foundation

enum LiveTransError: LocalizedError {
    case speechUnavailable
    case audioFormatUnavailable
    case noDisplay
    case microphoneUnavailable
    case translationUnavailable
    case screenCaptureFailed(String)

    var errorDescription: String? {
        switch self {
        case .speechUnavailable:
            return L10n.t("error.speech_unavailable")
        case .audioFormatUnavailable:
            return L10n.t("error.audio_format_unavailable")
        case .noDisplay:
            return L10n.t("error.no_display")
        case .microphoneUnavailable:
            return L10n.t("error.microphone_unavailable")
        case .translationUnavailable:
            return L10n.t("error.translation_unavailable")
        case .screenCaptureFailed(let message):
            return L10n.t("error.screen_capture_failed", message)
        }
    }
}
