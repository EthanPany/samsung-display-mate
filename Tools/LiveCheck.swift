// Checks the real client against a real monitor. Run it with scripts/live-check.sh.
// Brightness is only rewritten with its current value, so nothing visibly changes.
import DisplayMateCore
import Foundation

@main struct LiveCheck {
    nonisolated(unsafe) static var failures = 0
    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print(ok ? "PASS" : "FAIL", name, detail)
        if !ok { failures += 1 }
    }
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SDM_HOST"], let token = env["SDM_TOKEN"] else {
            print("Set SDM_HOST and SDM_TOKEN"); exit(2)
        }
        let c = IPControlClient(host: host, token: token, pin: nil)
        for s in Setting.allCases {
            let v = try? await c.read(s)
            check("read \(s.rawValue)", v != nil, v.map { "\($0)" } ?? "")
        }
        let fp = await c.certificateFingerprint
        check("certificate fingerprint captured", fp?.count == 64)

        let start = try await c.read(.backlight)?.intValue ?? 50
        var failed = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 { group.addTask { (try? await c.write(.backlight, .int(start))) != nil } }
            for await ok in group where !ok { failed += 1 }
        }
        check("12 overlapping writes all succeed", failed == 0, "\(failed) failed")
        let end = try await c.read(.backlight)?.intValue
        check("brightness unchanged", end == start)

        do { _ = try await IPControlClient(host: host, token: "invalid", pin: nil).read(.backlight); check("bad token rejected", false) }
        catch { check("bad token reported as unauthorized", error as? IPControlError == .unauthorized, "\(error)") }

        do { _ = try await IPControlClient(host: host, token: token, pin: String(repeating: "0", count: 64)).read(.backlight); check("wrong pin rejected", false) }
        catch { check("wrong certificate pin rejected", error as? IPControlError == .certificateChanged, "\(error)") }

        if let fp {
            let v = try? await IPControlClient(host: host, token: token, pin: fp).read(.backlight)
            check("correct pin accepted", v != nil)
        }
        print(failures == 0 ? "All checks passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
