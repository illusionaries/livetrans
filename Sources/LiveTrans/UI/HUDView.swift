import AppKit
import SwiftUI

struct HUDView: View {

    @ObservedObject var store: CaptionStore
    @ObservedObject var appearance: AppearanceSettings
    let minimal: Bool

    var body: some View {
        Group {
            if minimal {
                minimalLayout
            } else {
                fullLayout
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Full layout

    private var fullLayout: some View {
        VStack(spacing: 0) {
            header
            if store.needsLanguagePack {
                languagePackBanner
            }
            Divider().overlay(Color.white.opacity(0.08))
            transcript
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(width: 560, height: 340)
        .background(fullBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(store.isListening ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: (store.isListening ? Color.green : Color.orange).opacity(0.8), radius: 4)

            Text("LIVE")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.85))

            Text(L10n.t("hud.direction"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))

            Spacer(minLength: 8)

            Text(store.statusText)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        // 顶部整条都是拖动区
        .overlay(WindowDragArea())
    }

    private var languagePackBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
            Text(L10n.t("hud.language_pack_banner"))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.yellow.opacity(0.08))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.lines.isEmpty && partialItems.isEmpty {
                        emptyState
                    }

                    ForEach(store.lines) { line in
                        CaptionRow(line: line)
                            .id(line.id)
                    }

                    ForEach(partialItems) { item in
                        PartialRow(lane: item.lane, text: item.text)
                            .id("partial-\(item.id)")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onChange(of: store.lines.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: store.partials) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.white.opacity(0.35))
            Text(L10n.t("hud.empty_title"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(L10n.t("hud.empty_subtitle"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 42)
    }

    private var footer: some View {
        HStack {
            Text(L10n.t("hud.footer_shortcuts"))
            Spacer()
            Text(L10n.t("hud.footer_local"))
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.white.opacity(0.3))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var fullBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [.black.opacity(0.55), .black.opacity(0.30)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var partialItems: [PartialItem] {
        CaptionStore.Lane.allCases.compactMap { lane in
            guard let text = store.partials[lane], !text.isEmpty else { return nil }
            return PartialItem(lane: lane, text: text)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - Minimal layout (subtitle strip)

    private var minimalLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)

            if store.lines.isEmpty && currentPartial == nil {
                Text(L10n.t("hud.empty_title"))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(recentLines) { line in
                    minimalRow(
                        source: line.source,
                        translation: line.translation,
                        dimmed: line.id != recentLines.last?.id
                    )
                }

                if let partial = currentPartial {
                    minimalPartial(partial.text)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .frame(width: appearance.width, height: appearance.height, alignment: .leading)
        .background(minimalBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // 极简模式没有控件，整块区域都可以拖动
        .overlay(WindowDragArea())
        .overlay {
            if appearance.useMaterial || appearance.backgroundOpacity > 0.02 {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var recentLines: [CaptionStore.Line] {
        let maxLines = max(1, min(3, appearance.lineCount))
        let count = currentPartial == nil ? maxLines : max(1, maxLines - 1)
        return Array(store.lines.suffix(count))
    }

    private var currentPartial: (lane: CaptionStore.Lane, text: String)? {
        guard let lane = store.partialLane,
              let text = store.partials[lane],
              !text.isEmpty else {
            return nil
        }
        return (lane, text)
    }

    private func minimalRow(source: String, translation: String?, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(source)
                .font(.system(size: appearance.sourceFontSize))
                .foregroundStyle(.white.opacity(dimmed ? 0.34 : 0.52))
                .lineLimit(2)

            Text(translation ?? "…")
                .font(.system(size: appearance.translationFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(dimmed ? 0.55 : 0.96))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
    }

    private func minimalPartial(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text)
                .font(.system(size: appearance.sourceFontSize))
                .italic()
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)

            Text("…")
                .font(.system(size: appearance.translationFontSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.28))
        }
        .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1)
    }

    @ViewBuilder
    private var minimalBackground: some View {
        ZStack {
            if appearance.useMaterial {
                VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            }
            if appearance.backgroundOpacity > 0.001 {
                Color.black.opacity(appearance.backgroundOpacity)
            }
        }
    }
}

// MARK: - Rows

private struct CaptionRow: View {
    let line: CaptionStore.Line

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LaneBadge(lane: line.lane)

            VStack(alignment: .leading, spacing: 3) {
                Text(line.source)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.52))
                    .textSelection(.enabled)

                Text(line.translation ?? L10n.t("hud.translating"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(line.translation == nil ? .white.opacity(0.30) : .white.opacity(0.95))
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            Text(line.createdAt, style: .time)
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.22))
                .padding(.top, 2)
        }
    }
}

private struct PartialRow: View {
    let lane: CaptionStore.Lane
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LaneBadge(lane: lane)
                .opacity(0.7)

            VStack(alignment: .leading, spacing: 3) {
                Text(text)
                    .font(.system(size: 12.5))
                    .italic()
                    .foregroundStyle(.white.opacity(0.72))

                Text(L10n.t("hud.recognizing"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.30))
            }

            Spacer(minLength: 0)
        }
    }
}

private struct LaneBadge: View {
    let lane: CaptionStore.Lane

    var body: some View {
        Text(lane.title)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(lane.tint.opacity(0.16), in: Capsule())
            .foregroundStyle(lane.tint.opacity(0.95))
            .padding(.top, 1)
    }
}

private struct PartialItem: Identifiable {
    let lane: CaptionStore.Lane
    let text: String

    var id: String { lane.rawValue }
}

// MARK: - Drag area

/// 透明覆盖层：在这个区域按下鼠标就拖动整个窗口。
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

private final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

extension CaptionStore.Lane {
    var title: String {
        switch self {
        case .system: return L10n.t("hud.lane.system")
        case .mic: return L10n.t("hud.lane.mic")
        }
    }

    var tint: Color {
        switch self {
        case .system: return .cyan
        case .mic: return .green
        }
    }
}
