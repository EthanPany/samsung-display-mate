import AppIntents
import DisplayMateCore

enum IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    case notConnected
    var localizedStringResource: LocalizedStringResource { "The Samsung monitor isn't connected." }
}

@MainActor private func connectedModel() async throws -> AppModel {
    let model = AppModel.shared
    guard await model.waitUntilConnected() else { throw IntentFailure.notConnected }
    return model
}

struct SetBrightnessIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Monitor Brightness"
    @Parameter(title: "Percent", inclusiveRange: (0, 100)) var percent: Int
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedModel().set(.backlight, .int(percent / 2))
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Monitor Volume"
    @Parameter(title: "Percent", inclusiveRange: (0, 100)) var percent: Int
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedModel().set(.volume, .int(percent))
        return .result()
    }
}

struct ToggleMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Monitor Mute"
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedModel().toggleMute()
        return .result()
    }
}

struct ToggleGameModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Monitor Game Mode"
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedModel().toggleGameMode()
        return .result()
    }
}

struct NextPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Monitor Preset"
    @MainActor func perform() async throws -> some IntentResult {
        try await connectedModel().applyNextPreset()
        return .result()
    }
}

struct DisplayMateShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextPresetIntent(), phrases: ["Next preset in \(.applicationName)"],
                    shortTitle: "Next Preset", systemImageName: "sparkles")
        AppShortcut(intent: ToggleMuteIntent(), phrases: ["Toggle mute in \(.applicationName)"],
                    shortTitle: "Toggle Mute", systemImageName: "speaker.slash")
        AppShortcut(intent: ToggleGameModeIntent(), phrases: ["Toggle game mode in \(.applicationName)"],
                    shortTitle: "Game Mode", systemImageName: "gamecontroller")
    }
}
