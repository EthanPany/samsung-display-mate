import Foundation

public struct PairedMonitor: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var pin: String?
    public var modelID: String?
    public var firmware: String?
    public var displayVendor: UInt32?
    public var displayModel: UInt32?
    public var macInput: String?
    public init(id: String, name: String, host: String) { self.id = id; self.name = name; self.host = host }
}

public struct Preset: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var symbol: String
    public var backlight: Int
    public var contrast: Int
    public var colorTone: String
    public var soundMode: String
    public init(name: String, symbol: String, backlight: Int, contrast: Int, colorTone: String, soundMode: String) {
        self.name = name; self.symbol = symbol; self.backlight = backlight
        self.contrast = contrast; self.colorTone = colorTone; self.soundMode = soundMode
    }
    public static let defaults = [
        Preset(name: "Day", symbol: "sun.max", backlight: 50, contrast: 50, colorTone: "Warm1", soundMode: "Amplify"),
        Preset(name: "Night", symbol: "moon", backlight: 15, contrast: 50, colorTone: "Warm2", soundMode: "Amplify"),
        Preset(name: "Movie", symbol: "film", backlight: 30, contrast: 50, colorTone: "Standard", soundMode: "Standard"),
    ]
}

public struct Schedule: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case day, night }
    public var enabled = false
    public var dayStartMinute = 7 * 60
    public var nightStartMinute = 20 * 60
    public var dayPreset: UUID?
    public var nightPreset: UUID?
    public var lastPhase: Phase?
    public init() {}

    public func phase(atMinute m: Int) -> Phase {
        if dayStartMinute == nightStartMinute { return .day }
        if dayStartMinute < nightStartMinute {
            return (dayStartMinute..<nightStartMinute).contains(m) ? .day : .night
        }
        return (nightStartMinute..<dayStartMinute).contains(m) ? .night : .day
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var monitors: [PairedMonitor] = []
    public var handleKeys = true
    public var alwaysTakeVolumeKeys = false
    public var showHUD = true
    public var showTouchBarControls = true
    public var followPower = false
    public var powerOffOnUnplug = false
    public var autoSwitchInput = false
    public var poweredOffByApp: String?
    public var presets = Preset.defaults
    public var schedule = Schedule()
    public init() {}

    /// Missing keys fall back to defaults, so adding a setting never loses a saved pairing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        monitors = try c.decodeIfPresent([PairedMonitor].self, forKey: .monitors) ?? d.monitors
        handleKeys = try c.decodeIfPresent(Bool.self, forKey: .handleKeys) ?? d.handleKeys
        alwaysTakeVolumeKeys = try c.decodeIfPresent(Bool.self, forKey: .alwaysTakeVolumeKeys) ?? d.alwaysTakeVolumeKeys
        showHUD = try c.decodeIfPresent(Bool.self, forKey: .showHUD) ?? d.showHUD
        showTouchBarControls = try c.decodeIfPresent(Bool.self, forKey: .showTouchBarControls) ?? d.showTouchBarControls
        followPower = try c.decodeIfPresent(Bool.self, forKey: .followPower) ?? d.followPower
        powerOffOnUnplug = try c.decodeIfPresent(Bool.self, forKey: .powerOffOnUnplug) ?? d.powerOffOnUnplug
        autoSwitchInput = try c.decodeIfPresent(Bool.self, forKey: .autoSwitchInput) ?? d.autoSwitchInput
        poweredOffByApp = try c.decodeIfPresent(String.self, forKey: .poweredOffByApp)
        presets = try c.decodeIfPresent([Preset].self, forKey: .presets) ?? d.presets
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? d.schedule
    }

    public static func load(_ d: UserDefaults = .standard) -> AppSettings {
        guard let data = d.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }
    public func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: "settings") }
    }
}

public enum KeyStep {
    /// One key press of brightness: 1/16 of the range like macOS, landing on even multiples.
    public static func brightness(_ value: Int, up: Bool, fine: Bool, in range: ClosedRange<Int>) -> Int {
        let step = fine ? 1 : max(1, (range.count - 1) / 16)
        let next: Int
        if step == 1 { next = value + (up ? 1 : -1) }
        else { next = up ? (value / step + 1) * step : ((value + step - 1) / step - 1) * step }
        return min(max(next, range.lowerBound), range.upperBound)
    }

    /// One key press of volume: fine near silence where small changes are loud, coarser higher up.
    public static func volume(_ value: Int, up: Bool, fine: Bool, in range: ClosedRange<Int>) -> Int {
        let reference = up ? value : max(value - 1, 0)
        let step = fine ? 1 : min(max(reference / 8 + 1, 1), 6)
        return min(max(value + (up ? step : -step), range.lowerBound), range.upperBound)
    }
}
