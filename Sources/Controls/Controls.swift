import AppIntents
import Foundation
import SwiftUI
import WidgetKit

/// The extension is sandboxed, so it only signals the running app and never talks to the monitor itself.
private func signal(_ name: String) {
    DistributedNotificationCenter.default().postNotificationName(
        .init("com.ethanpan.SamsungDisplayMate.\(name)"), object: nil, userInfo: nil, deliverImmediately: true)
}

struct MuteControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Monitor Mute"
    func perform() async throws -> some IntentResult { signal("mute"); return .result() }
}
struct GameControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Monitor Game Mode"
    func perform() async throws -> some IntentResult { signal("game"); return .result() }
}
struct PresetControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Monitor Preset"
    func perform() async throws -> some IntentResult { signal("preset"); return .result() }
}

struct MuteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ethanpan.SamsungDisplayMate.mute") {
            ControlWidgetButton(action: MuteControlIntent()) { Label("Monitor Mute", systemImage: "speaker.slash") }
        }
        .displayName("Monitor Mute")
    }
}
struct GameControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ethanpan.SamsungDisplayMate.game") {
            ControlWidgetButton(action: GameControlIntent()) { Label("Game Mode", systemImage: "gamecontroller") }
        }
        .displayName("Monitor Game Mode")
    }
}
struct PresetControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ethanpan.SamsungDisplayMate.preset") {
            ControlWidgetButton(action: PresetControlIntent()) { Label("Next Preset", systemImage: "sparkles") }
        }
        .displayName("Monitor Preset")
    }
}

@main struct DisplayMateControls: WidgetBundle {
    var body: some Widget {
        MuteControl()
        GameControl()
        PresetControl()
    }
}
