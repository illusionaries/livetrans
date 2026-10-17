import Foundation
import Speech
import Translation

enum SelfTest {

    static func runAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)

        Task {
            let source = Locale.Language(identifier: "en")
            let target = Locale.Language(identifier: "zh-Hans")

            let status = await LanguageAvailability().status(from: source, to: target)
            print("translation status: \(status)")

            if status == .installed {
                let session: TranslationSession
                if #available(macOS 26.4, *) {
                    session = TranslationSession(
                        installedSource: source,
                        target: target,
                        preferredStrategy: .lowLatency
                    )
                } else {
                    session = TranslationSession(installedSource: source, target: target)
                }

                do {
                    let start = Date()
                    let response = try await session.translate(
                        "Hello everyone, thanks for joining the call. Today we will talk about the new release schedule."
                    )
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    print("zh: \(response.targetText) [\(ms)ms]")
                } catch {
                    print("translate error: \(error)")
                }
            }

            print("speech available: \(SpeechTranscriber.isAvailable)")
            if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) {
                print("speech locale: \(locale.identifier(.bcp47))")
            }

            done.signal()
        }

        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }

        exit(0)
    }
}
