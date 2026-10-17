import AppKit
import Carbon

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    var controller: AppController!

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var hotKeyRef: EventHotKeyRef?
    private var minimalHotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AppController()
        setupStatusItem()
        controller.showHUD()
        controller.start()
        registerHotKey()

        if CommandLine.arguments.contains("--appearance") {
            controller.showAppearanceSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let minimalHotKeyRef {
            UnregisterEventHotKey(minimalHotKeyRef)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "LiveTrans")
                ?? NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "LiveTrans")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = L10n.t("status.tooltip")
        }

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: L10n.t("menu.header"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let hudItem = NSMenuItem(
            title: controller.isHUDVisible ? L10n.t("menu.hide_hud") : L10n.t("menu.show_hud"),
            action: #selector(toggleHUD),
            keyEquivalent: "l"
        )
        hudItem.keyEquivalentModifierMask = [.option, .command]
        hudItem.target = self
        menu.addItem(hudItem)

        let minimalItem = NSMenuItem(title: L10n.t("menu.minimal"), action: #selector(toggleMinimal), keyEquivalent: "m")
        minimalItem.keyEquivalentModifierMask = [.option, .command]
        minimalItem.target = self
        minimalItem.state = controller.isMinimal ? .on : .off
        menu.addItem(minimalItem)

        let appearanceItem = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openAppearanceSettings), keyEquivalent: ",")
        appearanceItem.target = self
        menu.addItem(appearanceItem)

        let materialItem = NSMenuItem(title: L10n.t("menu.material"), action: #selector(toggleMaterial), keyEquivalent: "")
        materialItem.target = self
        materialItem.state = controller.appearance.useMaterial ? .on : .off
        menu.addItem(materialItem)

        let runItem = NSMenuItem(
            title: controller.isRunning ? L10n.t("menu.stop") : L10n.t("menu.start"),
            action: #selector(toggleRunning),
            keyEquivalent: ""
        )
        runItem.target = self
        menu.addItem(runItem)

        let micItem = NSMenuItem(title: L10n.t("menu.microphone"), action: #selector(toggleMic), keyEquivalent: "")
        micItem.target = self
        micItem.state = controller.micEnabled ? .on : .off
        menu.addItem(micItem)

        let aecItem = NSMenuItem(title: L10n.t("menu.aec"), action: #selector(toggleAEC), keyEquivalent: "")
        aecItem.target = self
        aecItem.state = controller.audioSettings.aecEnabled ? .on : .off
        menu.addItem(aecItem)

        menu.addItem(.separator())

        let clickItem = NSMenuItem(title: L10n.t("menu.click_through"), action: #selector(toggleClickThrough), keyEquivalent: "")
        clickItem.target = self
        clickItem.state = controller.clickThrough ? .on : .off
        menu.addItem(clickItem)

        let shareItem = NSMenuItem(title: L10n.t("menu.hide_in_share"), action: #selector(toggleHideFromShare), keyEquivalent: "")
        shareItem.target = self
        shareItem.state = controller.hideFromScreenShare ? .on : .off
        menu.addItem(shareItem)

        menu.addItem(.separator())

        let languageItem = NSMenuItem(title: L10n.t("menu.translation_languages"), action: #selector(openTranslationSettings), keyEquivalent: "")
        languageItem.target = self
        menu.addItem(languageItem)

        let quitItem = NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func toggleHUD() {
        controller.toggleHUD()
    }

    @objc private func toggleMinimal() {
        controller.toggleMinimal()
    }

    @objc private func openAppearanceSettings() {
        controller.showAppearanceSettings()
    }

    @objc private func toggleMaterial() {
        controller.toggleMaterialBackground()
    }

    @objc private func toggleRunning() {
        controller.toggleRunning()
    }

    @objc private func toggleMic() {
        controller.setMicEnabled(!controller.micEnabled)
    }

    @objc private func toggleAEC() {
        controller.toggleAEC()
    }

    @objc private func toggleClickThrough() {
        controller.toggleClickThrough()
    }

    @objc private func toggleHideFromShare() {
        controller.toggleHideFromScreenShare()
    }

    @objc private func openTranslationSettings() {
        Permissions.openTranslationSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Global hotkey (⌥⌘L)

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == OSType(0x4C54524E) else {
                    return noErr
                }
                DispatchQueue.main.async {
                    guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
                    switch hotKeyID.id {
                    case 1:
                        appDelegate.controller.toggleHUD()
                    case 2:
                        appDelegate.controller.toggleMinimal()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &hotKeyHandler
        )

        let showHideID = EventHotKeyID(signature: OSType(0x4C54524E), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey | optionKey),
            showHideID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        let minimalID = EventHotKeyID(signature: OSType(0x4C54524E), id: 2)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(cmdKey | optionKey),
            minimalID,
            GetApplicationEventTarget(),
            0,
            &minimalHotKeyRef
        )
    }
}
