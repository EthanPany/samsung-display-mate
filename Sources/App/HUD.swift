import AppKit
import SwiftUI

enum LevelKind {
    case brightness, volume, muted
    var label: String { self == .brightness ? "Brightness" : "Volume" }
    func symbol(at level: Double) -> String {
        switch self {
        case .brightness: "sun.max.fill"
        case .muted: "speaker.slash.fill"
        case .volume: level <= 0 ? "speaker.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        }
    }
}

@MainActor @Observable final class HUDState {
    var kind = LevelKind.brightness
    var level = 0.0
    var title = ""
    var visible = false
}

/// Drawn to match the banner macOS 26 and later show in the top corner.
/// The real one needs an entitlement only Apple can grant, so apps can't show it for this monitor.
struct HUDView: View {
    let state: HUDState
    let onDrag: (Double) -> Void
    let onInteraction: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var percent: Int { Int((state.level * 100).rounded()) }
    private var hidden: Bool { !state.visible }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: state.kind.symbol(at: state.level))
                .font(.system(size: 22, weight: .medium))
                .frame(width: 34)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(state.title).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(state.kind == .muted ? "Muted" : "\(percent)%")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(percent)))
                        .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: percent)
                }
                .font(.system(size: 11, weight: .semibold))
                .opacity(0.9)
                SegmentBar(level: state.level, reduceMotion: reduceMotion, onDrag: onDrag, onInteraction: onInteraction)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
        .padding(.leading, 20)
        .padding(.trailing, 28)
        .frame(width: 308, height: 65)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .blur(radius: hidden && !reduceMotion ? 6 : 0)
        .scaleEffect(hidden && !reduceMotion ? 0.72 : 1, anchor: .top)
        .offset(y: hidden && !reduceMotion ? -16 : 0)
        .opacity(hidden ? 0 : 1)
        .animation(state.visible ? .spring(response: 0.34, dampingFraction: 0.72) : .easeIn(duration: 0.2), value: state.visible)
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .onHover(perform: onInteraction)
        .accessibilityElement()
        .accessibilityLabel("\(state.title) \(state.kind.label)")
        .accessibilityValue(state.kind == .muted ? "Muted" : "\(percent) percent")
        .accessibilityAdjustableAction { direction in
            onDrag(min(max(state.level + (direction == .increment ? 1.0 / 16 : -1.0 / 16), 0), 1))
        }
    }
}

private struct SegmentBar: View {
    let level: Double
    let reduceMotion: Bool
    let onDrag: (Double) -> Void
    let onInteraction: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(0..<16, id: \.self) { i in
                    let fill = min(max(level * 16 - Double(i), 0), 1)
                    GeometryReader { seg in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white.opacity(0.26))
                            Rectangle().fill(.white).frame(width: seg.size.width * fill)
                                .animation(reduceMotion ? nil : .smooth(duration: 0.16), value: fill)
                        }
                    }
                }
            }
            .frame(height: 4)
            .clipShape(.capsule)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onInteraction(true)
                onDrag(min(max(value.location.x / geo.size.width, 0), 1))
            }.onEnded { _ in onInteraction(false) })
        }
        .frame(height: 14)
    }
}

/// The level banner for key presses. It takes clicks for dragging but never takes focus from your app.
@MainActor final class HUDController {
    var onDrag: ((LevelKind, Double) -> Void)?
    private let state = HUDState()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var interacting = false

    func show(_ kind: LevelKind, level: Double, title: String, on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        state.kind = kind
        state.level = level
        state.title = title
        if let area = (screen ?? NSScreen.main)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 2, y: area.maxY - size.height + 14))
        }
        panel.orderFrontRegardless()
        // On the next turn, so a hidden banner renders once and the spring has somewhere to start from.
        DispatchQueue.main.async { [state] in state.visible = true }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !interacting else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            self.state.visible = false
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { self.panel?.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let view = HUDView(state: state, onDrag: { [weak self] level in
            guard let self else { return }
            self.state.level = level
            self.onDrag?(self.state.kind, level)
        }, onInteraction: { [weak self] active in
            self?.interacting = active
            self?.scheduleHide()
        })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
