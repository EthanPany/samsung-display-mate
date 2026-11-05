import AppKit
import DisplayMateCore
import Observation
import OSLog

private let log = Logger(subsystem: "com.ethanpan.SamsungDisplayMate", category: "app")

@MainActor @Observable final class AppModel {
    static let shared = AppModel()

    enum Status: Equatable {
        case noMonitor, displayAway, connecting, connected, needsPairing, unreachable(String)
    }

    var settings: AppSettings { didSet { if settings != oldValue { settings.save(); syncKeyTap() } } }
    private(set) var status: Status = .noMonitor { didSet { if status != oldValue { log.notice("status: \(self.statusText, privacy: .public)") } } }
    private(set) var values: [Setting: JSONValue] = [:]
    private(set) var available: Set<Setting> = []
    private(set) var discovered: [DiscoveredMonitor] = []
    private(set) var displays: [DisplayInfo] = []
    private(set) var activeMonitorID: String?
    private(set) var accessibilityTrusted = Accessibility.isTrusted
    private(set) var pairingMessage: String?
    private(set) var isPairing = false
    var lastError: String?

    @ObservationIgnored private var client: IPControlClient?
    @ObservationIgnored private var queue: LatestValueQueue<Setting, JSONValue>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DisplayWatcher?
    @ObservationIgnored private let discovery = MonitorDiscovery()
    @ObservationIgnored private let keys = KeyInterceptor()
    @ObservationIgnored private let hud = HUDController()
    @ObservationIgnored private let touchBar = TouchBarControls()
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var knob = KnobAccelerator()
    @ObservationIgnored private let feedback = VolumeFeedback()

    var activeMonitor: PairedMonitor? { settings.monitors.first { $0.id == activeMonitorID } }
    var activeDisplay: DisplayInfo? { activeMonitor.flatMap { m in displays.first { matches(m, $0) } } }
    var isConnected: Bool { status == .connected }
    var keysActive: Bool { keys.isRunning }

    var statusText: String {
        switch status {
        case .noMonitor: "No monitor paired"
        case .displayAway: "Monitor not plugged in"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .needsPairing: "Pairing needed"
        case .unreachable(let why): why
        }
    }

    var menuSymbol: String {
        switch status {
        case .connected: "display"
        case .connecting: "display"
        case .needsPairing, .unreachable: "exclamationmark.triangle"
        case .noMonitor, .displayAway: "display.trianglebadge.exclamationmark"
        }
    }

    init() {
        settings = .load()
        keys.handler = { [unowned self] key, flags in handleKey(key, flags) }
        keys.onRelease = { [unowned self] key, flags in
            if key == .soundUp || key == .soundDown { feedback.keyReleased(flags: flags) }
        }
        hud.onDrag = { [unowned self] kind, level in
            if kind == .brightness {
                set(.backlight, .int(Int((level * 50).rounded())))
            } else {
                if isMuted { set(.mute, .string("muteOff")) }
                set(.volume, .int(Int((level * 100).rounded())))
            }
        }
        touchBar.read = { [unowned self] in (int(.backlight), int(.volume)) }
        touchBar.setBrightness = { [unowned self] in set(.backlight, .int($0)) }
        touchBar.setVolume = { [unowned self] in set(.volume, .int($0)) }
        watcher = DisplayWatcher { [unowned self] in reconcile() }
        discovery.onChange = { [unowned self] found in discoveryChanged(found) }
        discovery.start()
        observeWorkspace()
        observeControlCenter()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated { tick() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in
            MainActor.assumeIsolated {
                let trusted = Accessibility.isTrusted
                if trusted != accessibilityTrusted { accessibilityTrusted = trusted; syncKeyTap() }
            }
        }
        reconcile()
    }

    // MARK: Plug and unplug

    private func matches(_ m: PairedMonitor, _ d: DisplayInfo) -> Bool {
        d.vendor == m.displayVendor && d.model == m.displayModel
    }

    func reconcile() {
        let previous = activeMonitorID
        displays = Displays.online()
        let next = settings.monitors.first { m in displays.contains { matches(m, $0) } }
        activeMonitorID = next?.id

        if previous != next?.id {
            if let leaving = settings.monitors.first(where: { $0.id == previous }), next == nil, settings.powerOffOnUnplug {
                sendPower(off: true, to: leaving)
            }
            teardown()
            if next != nil { connect(arrived: true) }
        }
        if next == nil { status = settings.monitors.isEmpty ? .noMonitor : .displayAway }
        syncKeyTap()
    }

    private func teardown() {
        connectTask?.cancel()
        connectTask = nil
        client = nil
        queue = nil
        values = [:]
        available = []
    }

    private func makeClient(for m: PairedMonitor) -> IPControlClient? {
        guard let token = Keychain.token(for: m.id) else { return nil }
        return IPControlClient(host: m.host, token: token, pin: m.pin)
    }

    private func connect(arrived: Bool) {
        guard let monitor = activeMonitor else { return }
        guard let client = makeClient(for: monitor) else { status = .needsPairing; return }
        self.client = client
        queue = LatestValueQueue { [weak self] setting, value in
            do { try await client.write(setting, value) }
            catch { await self?.writeFailed(setting, error) }
        }
        status = .connecting
        connectTask?.cancel()
        connectTask = Task { [weak self] in
            var delay = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await self.reloadAll(client)
                    self.status = .connected
                    self.syncKeyTap()
                    if arrived { await self.didConnectAfterPlugIn(client) }
                    return
                } catch IPControlError.unauthorized {
                    self.status = .needsPairing
                    return
                } catch IPControlError.certificateChanged {
                    self.status = .unreachable("Monitor certificate changed. Pair again.")
                    return
                } catch {
                    log.error("connect failed: \(String(describing: error), privacy: .public)")
                    self.status = .unreachable("Can't reach monitor. Check IP Remote.")
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    private func writeFailed(_ setting: Setting, _ error: Error) {
        switch error as? IPControlError {
        case .unauthorized: status = .needsPairing
        case .rejected, .unsupported: lastError = "The monitor refused that \(setting.rawValue) change."
        default: lastError = "Couldn't reach the monitor."
        }
        Task { await refreshQuick() }
    }

    /// Reads everything once. A setting the monitor refuses to read is hidden rather than shown broken.
    private func reloadAll(_ client: IPControlClient) async throws {
        var newValues: [Setting: JSONValue] = [:]
        var newAvailable: Set<Setting> = []
        for setting in Setting.allCases {
            do {
                if let v = try await client.read(setting) { newValues[setting] = v; newAvailable.insert(setting) }
            } catch IPControlError.unsupported {
            } catch IPControlError.rejected {
            }
        }
        guard !newValues.isEmpty else { throw IPControlError.badResponse }
        values = newValues
        available = newAvailable
        if let id = activeMonitorID, let i = settings.monitors.firstIndex(where: { $0.id == id }),
           let info = try? await client.deviceInformation() {
            settings.monitors[i].modelID = info["modelID"]?.stringValue
            settings.monitors[i].firmware = info["FWVersion"]?.stringValue
            if settings.monitors[i].macInput == nil { settings.monitors[i].macInput = newValues[.inputSource]?.stringValue }
        }
    }

    func refreshQuick() async {
        guard let client, let queue, await queue.isIdle else { return }
        for s in [Setting.backlight, .volume, .mute, .gameMode, .inputSource] where available.contains(s) {
            if let v = try? await client.read(s) { values[s] = v }
        }
    }

    private func didConnectAfterPlugIn(_ client: IPControlClient) async {
        if settings.autoSwitchInput, let wanted = activeMonitor?.macInput,
           values[.inputSource]?.stringValue?.lowercased() != wanted.lowercased() {
            set(.inputSource, .string(wanted))
        }
        applyScheduleIfNeeded()
    }

    private func discoveryChanged(_ found: [DiscoveredMonitor]) {
        discovered = found
        log.notice("discovered \(found.count) monitor(s)")
        var changedActive = false
        for f in found {
            if let i = settings.monitors.firstIndex(where: { $0.id == f.id }), settings.monitors[i].host != f.host {
                settings.monitors[i].host = f.host
                if f.id == activeMonitorID { changedActive = true }
            }
        }
        if changedActive { teardown(); connect(arrived: false) }
    }

    // MARK: Pairing

    func pair(id: String, name: String, host: String) {
        guard !isPairing else { return }
        isPairing = true
        pairingMessage = "Select Allow on the monitor…"
        Task {
            defer { isPairing = false }
            let trial = IPControlClient(host: host, token: nil, pin: nil)
            do {
                let token = try await trial.pair()
                Keychain.save(token, for: id)
                var m = settings.monitors.first { $0.id == id } ?? PairedMonitor(id: id, name: name, host: host)
                m.host = host
                m.pin = await trial.certificateFingerprint
                displays = Displays.online()
                let taken = Set(settings.monitors.filter { $0.id != id }.compactMap(\.displayModel))
                if let d = displays.first(where: { $0.isSamsung && !taken.contains($0.model) }) {
                    m.displayVendor = d.vendor
                    m.displayModel = d.model
                }
                settings.monitors.removeAll { $0.id == id }
                settings.monitors.append(m)
                pairingMessage = m.displayModel == nil ? "Paired. Plug in the monitor to start." : "Paired."
                teardown()
                activeMonitorID = nil
                reconcile()
            } catch IPControlError.unauthorized {
                pairingMessage = "The monitor declined, or the prompt timed out."
            } catch {
                log.error("pair failed: \(String(describing: error), privacy: .public)")
                pairingMessage = "Couldn't reach port 1516. Turn on IP Remote: Settings → All Settings → Connection → Network → Expert Settings."
            }
        }
    }

    func pairManually(host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        pair(id: discovered.first { $0.host == h }?.id ?? "manual:\(h)", name: discovered.first { $0.host == h }?.name ?? h, host: h)
    }

    func forget(_ m: PairedMonitor) {
        Keychain.delete(m.id)
        settings.monitors.removeAll { $0.id == m.id }
        reconcile()
    }

    func reconnect() {
        teardown()
        connect(arrived: false)
    }

    func useCurrentInputAsMac() {
        guard let i = settings.monitors.firstIndex(where: { $0.id == activeMonitorID }) else { return }
        settings.monitors[i].macInput = values[.inputSource]?.stringValue
    }

    // MARK: Controls

    func set(_ setting: Setting, _ value: JSONValue) {
        values[setting] = value
        guard let queue else { return }
        Task { await queue.submit(setting, value) }
    }

    func int(_ s: Setting, default d: Int = 0) -> Int { values[s]?.intValue ?? d }
    func string(_ s: Setting) -> String { values[s]?.stringValue ?? "" }
    var isMuted: Bool { string(.mute) == "muteOn" }
    var isGameMode: Bool { string(.gameMode) == "On" }

    func toggleMute() { set(.mute, .string(isMuted ? "muteOff" : "muteOn")) }
    func toggleGameMode() { set(.gameMode, .string(isGameMode ? "Off" : "On")) }

    func apply(_ p: Preset) {
        set(.backlight, .int(p.backlight))
        set(.contrast, .int(p.contrast))
        set(.colorTone, .string(p.colorTone))
        set(.soundMode, .string(p.soundMode))
    }

    func activePreset() -> Preset? {
        settings.presets.first {
            $0.backlight == int(.backlight, default: -1) && $0.contrast == int(.contrast, default: -1)
                && $0.colorTone == string(.colorTone) && $0.soundMode == string(.soundMode)
        }
    }

    func applyNextPreset() {
        let list = settings.presets
        guard !list.isEmpty else { return }
        let i = activePreset().flatMap { p in list.firstIndex { $0.id == p.id } } ?? -1
        apply(list[(i + 1) % list.count])
    }

    func captureCurrent(into id: UUID) {
        guard let i = settings.presets.firstIndex(where: { $0.id == id }) else { return }
        settings.presets[i].backlight = int(.backlight)
        settings.presets[i].contrast = int(.contrast)
        settings.presets[i].colorTone = string(.colorTone)
        settings.presets[i].soundMode = string(.soundMode)
    }

    /// Waits briefly for the connection, for Shortcuts runs that launch the app from cold.
    func waitUntilConnected() async -> Bool {
        for _ in 0..<40 where !isConnected { try? await Task.sleep(for: .milliseconds(150)) }
        return isConnected
    }

    // MARK: Keys

    private func syncKeyTap() {
        let wanted = settings.handleKeys && accessibilityTrusted && activeMonitorID != nil
        if wanted { keys.start() } else { keys.stop() }
        touchBar.setVisible(settings.showTouchBarControls && activeMonitorID != nil)
        log.notice("key tap running: \(self.keys.isRunning), trusted: \(self.accessibilityTrusted)")
    }

    private func handleKey(_ key: MediaKey, _ flags: NSEvent.ModifierFlags) -> Bool {
        guard isConnected, let display = activeDisplay else { return false }
        let fine = flags.contains(.shift) && flags.contains(.option)
        switch key {
        case .brightnessUp, .brightnessDown:
            guard Displays.pointerIsOn(display.id) else { return false }
            let v = KeyStep.brightness(int(.backlight), up: key == .brightnessUp, fine: fine, in: 0...50)
            set(.backlight, .int(v))
            showLevel(.brightness, Double(v) / 50, on: display)
        case .soundUp, .soundDown, .mute:
            guard settings.alwaysTakeVolumeKeys || AudioRouter.defaultOutputName()?.lowercased() == display.name.lowercased()
            else { return false }
            if key == .mute {
                toggleMute()
            } else {
                let up = key == .soundUp
                let step = knob.step(up: up, at: ProcessInfo.processInfo.systemUptime)
                let v = KeyStep.volume(int(.volume), up: up, step: fine ? 1 : step, in: 0...100)
                if isMuted { set(.mute, .string("muteOff")) }
                set(.volume, .int(v))
            }
            showLevel(isMuted ? .muted : .volume, isMuted ? 0 : Double(int(.volume)) / 100, on: display)
        }
        return true
    }

    private func showLevel(_ kind: LevelKind, _ level: Double, on display: DisplayInfo) {
        guard settings.showHUD else { return }
        hud.show(kind, level: level, title: display.name, on: Displays.screen(for: display.id))
    }

    // MARK: Power

    private func sendPower(off: Bool, to m: PairedMonitor) {
        guard let c = makeClient(for: m) else { return }
        Task { try? await c.write(.power, .string(off ? "powerOff" : "powerOn")) }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { macScreensSlept() }
        }
        center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { macScreensWoke() }
        }
    }

    /// Only powers off when the monitor is showing the Mac, so a film on another input keeps playing.
    private func macScreensSlept() {
        guard settings.followPower, let m = activeMonitor, let c = makeClient(for: m) else { return }
        let wanted = m.macInput?.lowercased()
        Task {
            let current = try? await c.read(.inputSource, timeout: 2)
            guard let current, current.stringValue?.lowercased() == wanted else { return }
            if (try? await c.write(.power, .string("powerOff"))) != nil { settings.poweredOffByApp = m.id }
        }
    }

    private func macScreensWoke() {
        if let id = settings.poweredOffByApp, let m = settings.monitors.first(where: { $0.id == id }) {
            settings.poweredOffByApp = nil
            sendPower(off: false, to: m)
        }
        if activeMonitorID != nil, status != .connected { reconnect() }
        else { Task { await refreshQuick() } }
    }

    // MARK: Schedule and background refresh

    private func tick() {
        applyScheduleIfNeeded()
        tickCount += 1
        if isConnected { Task { await refreshQuick() } }
    }

    func applyScheduleIfNeeded() {
        guard settings.schedule.enabled, isConnected else { return }
        let c = Calendar.current.dateComponents([.hour, .minute], from: .now)
        let phase = settings.schedule.phase(atMinute: (c.hour ?? 0) * 60 + (c.minute ?? 0))
        guard settings.schedule.lastPhase != phase else { return }
        settings.schedule.lastPhase = phase
        let id = phase == .day ? settings.schedule.dayPreset : settings.schedule.nightPreset
        if let p = settings.presets.first(where: { $0.id == id }) { apply(p) }
    }

    // MARK: Control Center

    private func observeControlCenter() {
        let center = DistributedNotificationCenter.default()
        let actions: [(String, @MainActor (AppModel) -> Void)] = [
            ("mute", { $0.toggleMute() }), ("game", { $0.toggleGameMode() }), ("preset", { $0.applyNextPreset() }),
        ]
        for (name, action) in actions {
            center.addObserver(forName: .init("com.ethanpan.SamsungDisplayMate.\(name)"), object: nil, queue: .main) { [unowned self] _ in
                MainActor.assumeIsolated { action(self) }
            }
        }
    }
}
