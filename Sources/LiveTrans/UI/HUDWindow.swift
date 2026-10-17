import AppKit
import Combine
import SwiftUI

/// NSHostingView 默认可能带一层不透明背景，会把圆角外面画成黑色。
/// 这里显式声明透明，并清掉 layer 背景。
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

final class HUDPanel: NSPanel {

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        animationBehavior = .utilityWindow

        contentView = TransparentHostingView(rootView: content)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class HUDWindowController {

    private let store: CaptionStore
    private let appearance: AppearanceSettings
    private let panel: HUDPanel
    private(set) var isMinimal: Bool

    private let normalSize = NSSize(width: 560, height: 340)
    private let normalAutosaveName = "LiveTransHUD"
    private let minimalAutosaveName = "LiveTransHUD.minimal"

    private var cancellables = Set<AnyCancellable>()

    var isVisible: Bool { panel.isVisible }

    private var minimalSize: NSSize {
        NSSize(
            width: max(320, appearance.width),
            height: max(80, appearance.height)
        )
    }

    init(store: CaptionStore, appearance: AppearanceSettings, minimal: Bool = false) {
        self.store = store
        self.appearance = appearance
        self.isMinimal = minimal

        let size = minimal
            ? NSSize(width: max(320, appearance.width), height: max(80, appearance.height))
            : normalSize
        let autosaveName = minimal ? minimalAutosaveName : normalAutosaveName

        panel = HUDPanel(content: HUDView(store: store, appearance: appearance, minimal: minimal))

        if panel.setFrameUsingName(autosaveName) {
            var frame = panel.frame
            frame.size = size
            panel.setFrame(frame, display: false)
        } else {
            panel.setContentSize(size)
            position(forMinimal: minimal)
        }
        panel.setFrameAutosaveName(autosaveName)
        panel.hasShadow = false
        constrainToScreen()

        observeAppearance()
    }

    func show() {
        constrainToScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func setClickThrough(_ enabled: Bool) {
        panel.ignoresMouseEvents = enabled
    }

    func setHideFromScreenShare(_ hidden: Bool) {
        panel.sharingType = hidden ? .none : .readOnly
    }

    func setMinimal(_ enabled: Bool) {
        guard enabled != isMinimal else { return }

        panel.saveFrame(usingName: isMinimal ? minimalAutosaveName : normalAutosaveName)
        isMinimal = enabled

        let size = enabled ? minimalSize : normalSize
        let autosaveName = enabled ? minimalAutosaveName : normalAutosaveName

        panel.contentView = TransparentHostingView(
            rootView: HUDView(store: store, appearance: appearance, minimal: enabled)
        )

        if panel.setFrameUsingName(autosaveName) {
            var frame = panel.frame
            frame.size = size
            panel.setFrame(frame, display: true)
        } else {
            panel.setContentSize(size)
            position(forMinimal: enabled)
        }
        panel.setFrameAutosaveName(autosaveName)
        panel.hasShadow = false
        constrainToScreen()
    }

    // MARK: - Live appearance updates

    private func observeAppearance() {
        // @Published 在 willSet 时发事件，这里直接用回调里的新值，避免读到旧尺寸。
        appearance.$width
            .dropFirst()
            .sink { [weak self] width in
                guard let self else { return }
                self.applyMinimalSize(width: width, height: self.appearance.height)
            }
            .store(in: &cancellables)

        appearance.$height
            .dropFirst()
            .sink { [weak self] height in
                guard let self else { return }
                self.applyMinimalSize(width: self.appearance.width, height: height)
            }
            .store(in: &cancellables)
    }

    /// 高度/宽度变化时保持底部和水平中心，让字幕条向上/两侧生长。
    private func applyMinimalSize(width: Double, height: Double) {
        guard isMinimal else { return }

        let size = NSSize(width: max(320, width), height: max(80, height))
        let old = panel.frame
        var frame = old
        frame.size = size
        frame.origin.x = old.midX - size.width / 2
        frame.origin.y = old.origin.y
        panel.setFrame(frame, display: true, animate: false)
        constrainToScreen()
    }

    private func position(forMinimal minimal: Bool) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = minimal ? minimalSize : normalSize

        if minimal {
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 48
            )
            panel.setFrameOrigin(origin)
        } else {
            let origin = NSPoint(
                x: visible.maxX - size.width - 24,
                y: visible.maxY - size.height - 24
            )
            panel.setFrameOrigin(origin)
        }
    }

    /// 把窗口完整地夹回屏幕的可见区域；如果已经完全在屏幕外，就回到默认位置。
    private func constrainToScreen() {
        let screens = NSScreen.screens
        guard let main = NSScreen.main ?? screens.first else { return }

        let current = panel.frame
        let areas = screens.map { ($0, intersectionArea($0.visibleFrame, current)) }
        let maxArea = areas.map { $0.1 }.max() ?? 0

        if maxArea <= 0 {
            // 完全在屏幕外（比如之前接过外接屏）：回到默认位置
            let size = isMinimal ? minimalSize : normalSize
            var frame = current
            frame.size = size
            let visible = main.visibleFrame
            if isMinimal {
                frame.origin = NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.minY + 48
                )
            } else {
                frame.origin = NSPoint(
                    x: visible.maxX - size.width - 24,
                    y: visible.maxY - size.height - 24
                )
            }
            panel.setFrame(frame, display: true)
            return
        }

        let target = areas.max { $0.1 < $1.1 }?.0 ?? main
        let bounds = target.visibleFrame
        var frame = current

        frame.size.width = min(frame.width, bounds.width)
        frame.size.height = min(frame.height, bounds.height)

        if frame.maxX > bounds.maxX { frame.origin.x = bounds.maxX - frame.width }
        if frame.minX < bounds.minX { frame.origin.x = bounds.minX }
        if frame.maxY > bounds.maxY { frame.origin.y = bounds.maxY - frame.height }
        if frame.minY < bounds.minY { frame.origin.y = bounds.minY }

        if frame != current {
            panel.setFrame(frame, display: true)
        }
    }

    private func intersectionArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

}
