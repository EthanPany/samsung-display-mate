import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import DisplayMateCore
import Network
import Security
import ServiceManagement

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let vendor: UInt32
    let model: UInt32
    let name: String
    static let samsungVendor: UInt32 = 0x4C2D
    var isSamsung: Bool { vendor == Self.samsungVendor }
}

enum Displays {
    static func online() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            DisplayInfo(id: id, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                        name: screen(for: id)?.localizedName ?? "Display")
        }
    }
    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    static func pointerIsOn(_ id: CGDirectDisplayID) -> Bool {
        guard let screen = screen(for: id) else { return false }
        return NSScreen.screens.count == 1 || screen.frame.contains(NSEvent.mouseLocation)
    }
}

/// Runs its callback on the main thread whenever a display is added, removed or reconfigured.
final class DisplayWatcher: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        CGDisplayRegisterReconfigurationCallback({ _, flags, info in
            guard !flags.contains(.beginConfigurationFlag), let info else { return }
            let me = Unmanaged<DisplayWatcher>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.onChange() } }
        }, Unmanaged.passUnretained(self).toOpaque())
    }
}

enum AudioRouter {
    static func defaultOutputName() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
}

/// Plays the macOS volume feedback sound, following System Settings → Sound → "Play feedback when volume is changed".
/// macOS can't play it itself here, because the app takes the key before the system sees it.
@MainActor final class VolumeFeedback {
    private static let path = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
    private let sound = NSSound(contentsOfFile: path, byReference: true)
    private var pending: Task<Void, Never>?

    private var isEnabledInSystem: Bool {
        let value = CFPreferencesCopyValue("com.apple.sound.beep.feedback" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? NSNumber)?.boolValue ?? false
    }

    /// Holding Shift flips the setting, as it does for the system. Spinning a knob plays once, when it stops.
    func keyReleased(flags: NSEvent.ModifierFlags) {
        pending?.cancel()
        guard isEnabledInSystem != flags.contains(.shift) else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let sound = self?.sound else { return }
            sound.stop()
            sound.play()
        }
    }
}

enum Keychain {
    private static let service = "com.ethanpan.SamsungDisplayMate.token"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func save(_ token: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
    static func token(for account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    static func delete(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func requestPrompt() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

struct DiscoveredMonitor: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
}

/// Browses for Samsung Tizen displays. The TXT record carries the current address, so IP changes are followed.
@MainActor final class MonitorDiscovery {
    private var browser: NWBrowser?
    var onChange: (([DiscoveredMonitor]) -> Void)?

    func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_samsungmsf._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { r -> DiscoveredMonitor? in
                guard case .bonjour(let txt) = r.metadata,
                      let id = txt["id"], let host = Bonjour.host(fromServiceEndpoint: txt["se"]) else { return nil }
                return DiscoveredMonitor(id: id, name: Bonjour.friendlyName(txt["fn"] ?? "Samsung display"), host: host)
            }
            let unique = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values.sorted { $0.name < $1.name }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onChange?(unique) } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}

enum MediaKey: Int { case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7 }

/// Catches media keys only while installed; the app removes it when the monitor is unplugged.
@MainActor final class KeyInterceptor {
    /// Returns true when the app handled the key, which removes it from the normal system path.
    var handler: ((MediaKey, NSEvent.ModifierFlags) -> Bool)?
    /// Called when a key the app handled is released.
    var onRelease: ((MediaKey, NSEvent.ModifierFlags) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowedDown = Set<Int>()

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyInterceptor>.fromOpaque(info).takeUnretainedValue()
            let swallow = MainActor.assumeIsolated { me.process(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: info) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        swallowedDown.removeAll()
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF0000) >> 16
        guard let key = MediaKey(rawValue: code) else { return false }
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        if isDown {
            guard handler?(key, ns.modifierFlags) == true else { swallowedDown.remove(code); return false }
            swallowedDown.insert(code)
            return true
        }
        guard swallowedDown.remove(code) != nil else { return false }
        onRelease?(key, ns.modifierFlags)
        return true
    }
}
