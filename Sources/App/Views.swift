import DisplayMateCore
import SwiftUI

@main struct SamsungDisplayMateApp: App {
    @State private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            PanelView().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView().environment(model)
        }
    }
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Image(systemName: model.menuSymbol)
            .task {
                guard model.settings.monitors.isEmpty else { return }
                openSettings()
                NSApp.activate()
            }
    }
}

struct PanelView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.isConnected {
                controls
            } else {
                Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let e = model.lastError {
                Text(e).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("Settings…") {
                    openSettings()
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 310)
        .task { await model.refreshQuick() }
    }

    private var hint: String {
        switch model.status {
        case .noMonitor: "Open Settings to pair your Samsung monitor."
        case .displayAway: "Controls return when the monitor is plugged in. Keys work normally until then."
        case .needsPairing: "Open Settings → Monitors and pair again."
        default: model.statusText
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "display").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.activeMonitor.map { Bonjour.friendlyName($0.name) } ?? "Samsung Display Mate").font(.headline).lineLimit(1)
                Text(model.statusText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(model.isConnected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
        }
    }

    @ViewBuilder private var controls: some View {
        LevelRow(symbol: "sun.max.fill", label: "Brightness", range: 0...50, value: model.int(.backlight)) { model.set(.backlight, .int($0)) }
        LevelRow(symbol: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Volume", range: 0...100, value: model.int(.volume)) { model.set(.volume, .int($0)) }

        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            QuickToggle(title: "Mute", symbol: "speaker.slash", isOn: model.isMuted) { model.toggleMute() }
            if model.available.contains(.gameMode) {
                QuickToggle(title: "Game Mode", symbol: "gamecontroller", isOn: model.isGameMode) { model.toggleGameMode() }
            }
            QuickToggle(title: "Follow Mac Power", symbol: "power", isOn: model.settings.followPower) { model.settings.followPower.toggle() }
            QuickToggle(title: "Keyboard Keys", symbol: "keyboard", isOn: model.settings.handleKeys) { model.settings.handleKeys.toggle() }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(model.settings.presets) { p in
                    Button { model.apply(p) } label: {
                        Label(p.name, systemImage: p.symbol).frame(maxWidth: .infinity)
                    }
                    .tint(model.activePreset()?.id == p.id ? .accentColor : nil)
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct LevelRow: View {
    let symbol: String
    let label: String
    let range: ClosedRange<Int>
    let value: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
                   in: Double(range.lowerBound)...Double(range.upperBound))
                .accessibilityLabel(label)
        }
    }
}

struct QuickToggle: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).symbolVariant(isOn ? .fill : .none).frame(width: 18)
                Text(title).font(.callout).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .contentShape(.rect(cornerRadius: 12))
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralTab() }
            Tab("Monitors", systemImage: "display") { MonitorsTab() }
            Tab("Display", systemImage: "slider.horizontal.3") { DisplayTab() }
            Tab("Automation", systemImage: "clock") { AutomationTab() }
        }
        .frame(width: 520, height: 520)
    }
}

struct GeneralTab: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LoginItem.set(on); loginError = nil }
                        catch { loginError = error.localizedDescription; launchAtLogin = LoginItem.isEnabled }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
            Section {
                Toggle("Use brightness and volume keys", isOn: $model.settings.handleKeys)
                if !model.accessibilityTrusted {
                    LabeledContent("Needs Accessibility access") {
                        Button("Allow…") { Accessibility.requestPrompt() }
                    }
                }
                Toggle("Volume keys always control this monitor", isOn: $model.settings.alwaysTakeVolumeKeys)
                Toggle("Show level indicator", isOn: $model.settings.showHUD)
                Toggle("Add monitor sliders to the Touch Bar", isOn: $model.settings.showTouchBarControls)
            } footer: {
                Text("Keys only reach the monitor while it's plugged in. Hold Shift and Option for single steps.")
            }
        }
        .formStyle(.grouped)
    }
}

struct MonitorsTab: View {
    @Environment(AppModel.self) private var model
    @State private var manualHost = ""

    var body: some View {
        Form {
            Section("Paired") {
                if model.settings.monitors.isEmpty { Text("No monitors yet").foregroundStyle(.secondary) }
                ForEach(model.settings.monitors) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Bonjour.friendlyName(m.name)).font(.headline)
                            Spacer()
                            if m.id == model.activeMonitorID { Text(model.statusText).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text([m.modelID, m.host, m.firmware].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("Pair Again") { model.pair(id: m.id, name: m.name, host: m.host) }
                            Button("Forget", role: .destructive) { model.forget(m) }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section {
                let new = model.discovered.filter { d in !model.settings.monitors.contains { $0.id == d.id } }
                if new.isEmpty { Text("Nothing new").foregroundStyle(.secondary) }
                ForEach(new) { d in
                    LabeledContent {
                        Button("Pair") { model.pair(id: d.id, name: d.name, host: d.host) }.disabled(model.isPairing)
                    } label: {
                        Text(d.name)
                        Text(d.host)
                    }
                }
                HStack {
                    TextField("IP address", text: $manualHost)
                    Button("Pair") { model.pairManually(host: manualHost) }.disabled(model.isPairing || manualHost.isEmpty)
                }
            } header: {
                Text("Found on your network")
            } footer: {
                Text(model.pairingMessage ?? "Turn on IP Remote first: monitor Settings → All Settings → Connection → Network → Expert Settings. Pairing here can sign out another app paired the same way.")
            }
            Section("Connected displays") {
                ForEach(model.displays) { d in
                    LabeledContent(d.name, value: d.isSamsung ? "Samsung" : "Other")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DisplayTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if !model.isConnected {
                Text("Connect a monitor to see its settings.").foregroundStyle(.secondary)
            } else {
                Section("Picture") {
                    slider("Brightness", .backlight)
                    slider("Contrast", .contrast)
                    slider("Sharpness", .sharpness)
                    slider("Color", .color)
                    slider("Tint", .tint)
                    slider("Shadow Detail", .shadowDetail)
                    picker("Color Tone", .colorTone, ["Cool", "Standard", "Warm1", "Warm2"])
                    picker("Contrast Enhancer", .contrastEnhancer, ["Off", "Low", "High"])
                }
                Section("Sound") {
                    slider("Volume", .volume)
                    picker("Sound Mode", .soundMode, ["Standard", "Amplify"])
                }
                Section("Modes") {
                    picker("Game Mode", .gameMode, ["Off", "On"])
                    LabeledContent("Picture Mode", value: model.string(.pictureMode))
                    LabeledContent("Input", value: model.string(.inputSource))
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func slider(_ title: String, _ s: Setting) -> some View {
        if model.available.contains(s), let r = s.range {
            LabeledContent(title) {
                HStack {
                    Slider(value: Binding(get: { Double(model.int(s)) }, set: { model.set(s, .int(Int($0.rounded()))) }),
                           in: Double(r.lowerBound)...Double(r.upperBound))
                    Text("\(model.int(s))").monospacedDigit().frame(width: 30, alignment: .trailing)
                }
            }
        }
    }

    @ViewBuilder private func picker(_ title: String, _ s: Setting, _ options: [String]) -> some View {
        if model.available.contains(s) {
            Picker(title, selection: Binding(get: { model.string(s) }, set: { model.set(s, .string($0)) })) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
                if !options.contains(model.string(s)) { Text(model.string(s)).tag(model.string(s)) }
            }
        }
    }
}

struct AutomationTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Turn the monitor off and on with the Mac's screens", isOn: $model.settings.followPower)
                Toggle("Turn the monitor off when unplugged", isOn: $model.settings.powerOffOnUnplug)
                Toggle("Switch to the Mac's input when plugged in", isOn: $model.settings.autoSwitchInput)
                if let input = model.activeMonitor?.macInput {
                    LabeledContent("Mac's input") {
                        HStack {
                            Text(input)
                            Button("Use Current") { model.useCurrentInputAsMac() }.controlSize(.small).disabled(!model.isConnected)
                        }
                    }
                }
            } header: {
                Text("Power and input")
            } footer: {
                Text("The monitor only turns off if it's showing the Mac, so anything playing on another input isn't interrupted.")
            }
            Section("Schedule") {
                Toggle("Change preset by time of day", isOn: $model.settings.schedule.enabled)
                minutePicker("Day starts", $model.settings.schedule.dayStartMinute)
                presetPicker("Day preset", $model.settings.schedule.dayPreset)
                minutePicker("Night starts", $model.settings.schedule.nightStartMinute)
                presetPicker("Night preset", $model.settings.schedule.nightPreset)
            }
            Section("Presets") {
                ForEach($model.settings.presets) { $p in
                    LabeledContent {
                        Button("Use Current Settings") { model.captureCurrent(into: p.id) }.controlSize(.small).disabled(!model.isConnected)
                    } label: {
                        Label(p.name, systemImage: p.symbol)
                        Text("Brightness \(p.backlight), contrast \(p.contrast), \(p.colorTone), \(p.soundMode)")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: seedSchedule)
    }

    private func seedSchedule() {
        let presets = model.settings.presets
        if model.settings.schedule.dayPreset == nil { model.settings.schedule.dayPreset = presets.first { $0.name == "Day" }?.id }
        if model.settings.schedule.nightPreset == nil { model.settings.schedule.nightPreset = presets.first { $0.name == "Night" }?.id }
    }

    private func minutePicker(_ title: String, _ minutes: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        ), displayedComponents: .hourAndMinute)
    }

    private func presetPicker(_ title: String, _ selection: Binding<UUID?>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(UUID?.none)
            ForEach(model.settings.presets) { Text($0.name).tag(UUID?.some($0.id)) }
        }
    }
}
