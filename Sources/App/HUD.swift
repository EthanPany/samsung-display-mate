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
    var visible = false
}

/// Drawn to match the banner macOS 26 and later show in the top corner.
/// The real one needs an entitlement only Apple can grant, so apps can't show it for this monitor.
struct HUDView: View {
    let state: HUDState
    let onDrag: (Double) -> Void
    let onInteraction: (Bool) -> Void

    private var percent: Int { Int((state.level * 100).rounded()) }

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: state.kind.symbol(at: state.level))
                .font(.system(size: 22, weight: .medium))
                .frame(width: 34)
                .contentTransition(.symbolEffect(.replace))
            SegmentBar(level: state.level, onDrag: onDrag, onInteraction: onInteraction)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
        .padding(.leading, 20)
        .padding(.trailing, 28)
        .frame(width: 308, height: 65)
        .glassEffect(.regular, in: .capsule)
        .environment(\.colorScheme, .dark)
        .opacity(state.visible ? 1 : 0)
        .scaleEffect(state.visible ? 1 : 0.97, anchor: .top)
        .animation(.easeOut(duration: 0.18), value: state.visible)
        .padding(10)
        .onHover(perform: onInteraction)
        .accessibilityElement()
        .accessibilityLabel(state.kind.label)
        .accessibilityValue(state.kind == .muted ? "Muted" : "\(percent) percent")
        .accessibilityAdjustableAction { direction in
            onDrag(min(max(state.level + (direction == .increment ? 1.0 / 16 : -1.0 / 16), 0), 1))
        }
    }
}

private struct SegmentBar: View {
    let level: Double
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
        .frame(height: 24)
    }
}

/// The level banner for key presses. It takes clicks for dragging but never takes focus from your app.
@MainActor final class HUDController {
    var onDrag: ((LevelKind, Double) -> Void)?
    private let state = HUDState()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var interacting = false

    func show(_ kind: LevelKind, level: Double, on screen: NSScreen?) {
        let panel = panel ?? makePanel()
        self.panel = panel
        state.kind = kind
        state.level = level
        if let area = (screen ?? NSScreen.main)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: area.maxX - size.width - 2, y: area.maxY - size.height + 4))
        }
        panel.orderFrontRegardless()
        state.visible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !interacting else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            self.state.visible = false
            try? await Task.sleep(for: .milliseconds(250))
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
