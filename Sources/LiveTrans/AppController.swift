import AppKit
import AVFoundation
import Combine
import os

@MainActor
final class AppController {

    let store = CaptionStore()
    let appearance: AppearanceSettings
    let audioSettings: AudioSettings

    private let translator = Translator()
    private let hud: HUDWindowController
    private let appearanceWindow: AppearanceWindowController
    private let log = Logger(subsystem: "blog.illusion.LiveTrans", category: "app")

    private var systemLane: SpeechLane?
    private var micLane: SpeechLane?
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var startTask: Task<Void, Never>?
    private var partialTimeouts: [CaptionStore.Lane: Task<Void, Never>] = [:]
    private var cancellables = Set<AnyCancellable>()

    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var micEnabled = true
    private(set) var clickThrough = false
    private(set) var hideFromScreenShare = false
    private(set) var isHUDVisible = true
    private(set) var isMinimal: Bool

    private static let minimalDefaultsKey = "LiveTrans.minimal"
    private var lastMinimalToggle = Date.distantPast

    init() {
        let appearance = AppearanceSettings()
        let audio = AudioSettings()
        self.appearance = appearance
        self.audioSettings = audio

        let minimal = UserDefaults.standard.bool(forKey: Self.minimalDefaultsKey)
        isMinimal = minimal
        hud = HUDWindowController(store: store, appearance: appearance, minimal: minimal)
        appearanceWindow = AppearanceWindowController(settings: appearance, audio: audio)
        observeAudioSettings()
    }

    private func observeAudioSettings() {
        audioSettings.$aecEnabled
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isRunning, !self.isStarting else { return }
                self.stopMicLane()
                if self.micEnabled {
                    Task { await self.startMicLaneIfEnabled() }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - HUD

    func showHUD() {
        hud.show()
        isHUDVisible = true
    }

    func toggleHUD() {
        if hud.isVisible {
            hud.hide()
            isHUDVisible = false
        } else {
            hud.show()
            isHUDVisible = true
        }
    }

    func toggleMaterialBackground() {
        appearance.useMaterial.toggle()
    }

    func showAppearanceSettings() {
        appearanceWindow.show()
    }

    func toggleMinimal() {
        // 菜单快捷键和 Carbon 全局热键可能同时触发，做个去抖
        let now = Date()
        guard now.timeIntervalSince(lastMinimalToggle) > 0.25 else { return }
        lastMinimalToggle = now

        isMinimal.toggle()
        hud.setMinimal(isMinimal)
        UserDefaults.standard.set(isMinimal, forKey: Self.minimalDefaultsKey)
    }

    func toggleClickThrough() {
        clickThrough.toggle()
        hud.setClickThrough(clickThrough)
    }

    func toggleHideFromScreenShare() {
        hideFromScreenShare.toggle()
        hud.setHideFromScreenShare(hideFromScreenShare)
    }

    // MARK: - Start / stop

    func toggleRunning() {
        if isRunning || isStarting {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isRunning, !isStarting else { return }
        isRunning = true
        isStarting = true
        store.statusText = L10n.t("status.preparing_translation")

        startTask = Task { [weak self] in
            guard let self else { return }

            await self.translator.prepare()
            guard !Task.isCancelled else { return }
            await self.refreshTranslatorState()

            self.store.statusText = L10n.t("status.preparing_speech")
            async let system: Void = self.startSystemLane()
            async let mic: Void = self.startMicLaneIfEnabled()
            _ = await (system, mic)

            guard !Task.isCancelled else { return }
            self.isStarting = false
            self.updateStatus()
        }
    }

    func stop() {
        guard isRunning || isStarting else { return }
        isRunning = false
        isStarting = false
        startTask?.cancel()
        startTask = nil

        let systemCapture = self.systemCapture
        let micCapture = self.micCapture
        let systemLane = self.systemLane
        let micLane = self.micLane
        self.systemCapture = nil
        self.micCapture = nil
        self.systemLane = nil
        self.micLane = nil

        store.systemActive = false
        store.micActive = false
        partialTimeouts.values.forEach { $0.cancel() }
        partialTimeouts.removeAll()
        store.clearAllPartials()
        store.statusText = L10n.t("status.stopped")

        Task {
            await systemCapture?.stop()
            micCapture?.stop()
            await systemLane?.stop()
            await micLane?.stop()
        }
    }

    // MARK: - Microphone toggle

    func toggleAEC() {
        audioSettings.aecEnabled.toggle()
    }

    func setMicEnabled(_ enabled: Bool) {
        guard micEnabled != enabled else { return }
        micEnabled = enabled

        if enabled {
            if isRunning {
                Task { await startMicLaneIfEnabled() }
            }
        } else {
            stopMicLane()
        }
    }

    // MARK: - Lanes

    private func startSystemLane() async {
        do {
            let lane = try await SpeechLane(kind: .system)
            if Task.isCancelled {
                await lane.stop()
                return
            }

            lane.onPartial = { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.updatePartial(text, lane: .system)
                }
            }
            lane.onFinal = { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.handleFinal(text, lane: .system)
                }
            }
            lane.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleLaneError(error, lane: .system)
                }
            }

            let capture = SystemAudioCapture(targetFormat: lane.format)
            capture.onBuffer = { [weak lane] buffer in
                lane?.feed(buffer)
            }
            capture.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleCaptureError(error, lane: .system)
                }
            }

            try await capture.start()
            if Task.isCancelled {
                await capture.stop()
                await lane.stop()
                return
            }

            systemLane = lane
            systemCapture = capture
            store.systemActive = true
            store.systemError = nil
            log.info("system lane started")
        } catch {
            log.error("system lane failed: \(error.localizedDescription, privacy: .public)")
            store.systemActive = false
            store.systemError = error.localizedDescription
            if !Task.isCancelled {
                presentSystemCaptureError(error)
            }
        }
    }

    private func startMicLaneIfEnabled() async {
        guard micEnabled else { return }

        guard await Permissions.requestMicrophone() else {
            store.micActive = false
            store.micError = L10n.t("status.mic_not_authorized")
            return
        }
        guard !Task.isCancelled else { return }

        do {
            let lane = try await SpeechLane(kind: .mic)
            if Task.isCancelled || !micEnabled {
                await lane.stop()
                return
            }

            lane.onPartial = { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.updatePartial(text, lane: .mic)
                }
            }
            lane.onFinal = { [weak self] text in
                Task { @MainActor [weak self] in
                    self?.handleFinal(text, lane: .mic)
                }
            }
            lane.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleLaneError(error, lane: .mic)
                }
            }

            let capture = MicrophoneCapture(targetFormat: lane.format, useVoiceProcessing: audioSettings.aecEnabled)
            capture.onBuffer = { [weak lane] buffer in
                lane?.feed(buffer)
            }
            capture.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleCaptureError(error, lane: .mic)
                }
            }

            try capture.start()
            if Task.isCancelled {
                capture.stop()
                await lane.stop()
                return
            }

            micCapture = capture
            micLane = lane
            store.micActive = true
            store.micError = nil
            log.info("mic lane started")
        } catch {
            log.error("mic lane failed: \(error.localizedDescription, privacy: .public)")
            store.micActive = false
            store.micError = error.localizedDescription
            if !Task.isCancelled {
                presentMicrophoneError(error)
            }
        }
    }

    private func stopMicLane() {
        let capture = micCapture
        let lane = micLane
        micCapture = nil
        micLane = nil

        capture?.stop()
        Task {
            await lane?.stop()
        }

        store.micActive = false
        clearPartial(lane: .mic)
        updateStatus()
    }

    // MARK: - Results

    private func updatePartial(_ text: String, lane: CaptionStore.Lane) {
        store.setPartial(text, lane: lane)
        partialTimeouts[lane]?.cancel()
        partialTimeouts[lane] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.store.clearPartial(lane: lane)
            }
        }
    }

    private func clearPartial(lane: CaptionStore.Lane) {
        partialTimeouts[lane]?.cancel()
        partialTimeouts[lane] = nil
        store.clearPartial(lane: lane)
    }

    private func handleFinal(_ text: String, lane: CaptionStore.Lane) {
        clearPartial(lane: lane)
        guard let id = store.appendFinal(lane: lane, source: text) else { return }

        guard store.translatorReady else {
            store.setTranslation(L10n.t("line.translation_unavailable"), for: id)
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await self.translator.translate(text)
                await MainActor.run {
                    self.store.setTranslation(translated, for: id)
                }
            } catch {
                self.log.error("translate failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.store.setTranslation(L10n.t("line.translation_failed"), for: id)
                }
            }
        }
    }

    private func handleLaneError(_ error: Error, lane: CaptionStore.Lane) {
        log.error("lane error: \(error.localizedDescription, privacy: .public)")
        switch lane {
        case .system:
            store.systemActive = false
            store.systemError = error.localizedDescription
        case .mic:
            store.micActive = false
            store.micError = error.localizedDescription
        }
        updateStatus()
    }

    private func handleCaptureError(_ error: Error, lane: CaptionStore.Lane) {
        log.error("capture error: \(error.localizedDescription, privacy: .public)")
        switch lane {
        case .system:
            store.systemActive = false
            store.systemError = error.localizedDescription
        case .mic:
            store.micActive = false
            store.micError = error.localizedDescription
        }
        updateStatus()
    }

    // MARK: - Status

    private func refreshTranslatorState() async {
        switch await translator.state {
        case .ready:
            store.translatorReady = true
            store.needsLanguagePack = false
        case .missingLanguagePack:
            store.translatorReady = false
            store.needsLanguagePack = true
            store.statusText = L10n.t("status.language_pack_missing_short")
        case .unsupported:
            store.translatorReady = false
            store.needsLanguagePack = false
            store.statusText = L10n.t("status.translation_unsupported")
        case .failed(let message):
            store.translatorReady = false
            store.needsLanguagePack = false
            store.statusText = L10n.t("status.translation_failed_init", message)
        case .unknown:
            break
        }
    }

    private func updateStatus() {
        if store.needsLanguagePack {
            store.statusText = L10n.t("status.language_pack_missing")
            return
        }
        guard isRunning else {
            store.statusText = L10n.t("status.stopped")
            return
        }

        var active: [String] = []
        if store.systemActive { active.append(L10n.t("hud.lane.system")) }
        if store.micActive { active.append(L10n.t("status.lane.mic")) }

        if active.isEmpty {
            if let error = store.systemError {
                store.statusText = L10n.t("status.system_error", error)
            } else if let error = store.micError {
                store.statusText = L10n.t("status.mic_error", error)
            } else {
                store.statusText = L10n.t("status.listening")
            }
        } else {
            store.statusText = L10n.t("status.listening_lanes", active.joined(separator: " + "))
        }
    }

    // MARK: - Permission alerts

    private func presentSystemCaptureError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("alert.screen_capture_title")
        alert.informativeText = L10n.t("alert.screen_capture_body", error.localizedDescription)
        alert.addButton(withTitle: L10n.t("alert.open_settings"))
        alert.addButton(withTitle: L10n.t("alert.later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openScreenCaptureSettings()
        }
    }

    private func presentMicrophoneError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t("alert.microphone_title")
        alert.informativeText = L10n.t("alert.microphone_body", error.localizedDescription)
        alert.addButton(withTitle: L10n.t("alert.open_settings"))
        alert.addButton(withTitle: L10n.t("alert.later"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openMicrophoneSettings()
        }
    }
}
