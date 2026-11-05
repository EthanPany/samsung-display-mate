import XCTest
@testable import DisplayMateCore

final class CoreTests: XCTestCase {
    func testPairingOmitsParams() throws {
        let json = try JSONSerialization.jsonObject(with: RPC.body(method: "createAccessToken", token: nil)) as! [String: Any]
        XCTAssertNil(json["params"])
    }
    func testTokenGoesInParams() throws {
        let json = try JSONSerialization.jsonObject(with: RPC.body(method: "backlightControl", token: "t", params: ["backlight": .int(5)])) as! [String: Any]
        let p = json["params"] as! [String: Any]
        XCTAssertEqual(p["AccessToken"] as? String, "t")
        XCTAssertEqual(p["backlight"] as? Int, 5)
    }
    func testParseRealResponses() throws {
        let ok = #"{"jsonrpc":"2.0","id":"1","result":{"backlight":25}}"#
        XCTAssertEqual(try RPC.parse(Data(ok.utf8))["backlight"], .int(25))
        let flat = #"{"code":-32700,"message":"Parse error"}"#
        XCTAssertThrowsError(try RPC.parse(Data(flat.utf8))) { XCTAssertEqual($0 as? IPControlError, .unauthorized) }
        let missing = #"{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"}}"#
        XCTAssertThrowsError(try RPC.parse(Data(missing.utf8))) { XCTAssertEqual($0 as? IPControlError, .unsupported) }
        let refused = #"{"error":{"code":-32002,"message":"Server error","data":"Failed"}}"#
        XCTAssertThrowsError(try RPC.parse(Data(refused.utf8))) { XCTAssertEqual($0 as? IPControlError, .rejected("Server error")) }
    }
    func testBonjourParsing() {
        XCTAssertEqual(Bonjour.host(fromServiceEndpoint: "http://192.0.2.10:8001/api/v2/"), "192.0.2.10")
        XCTAssertEqual(Bonjour.friendlyName("32&quot; Odyssey OLED G8"), "32\" Odyssey OLED G8")
    }
    func testSchedulePhases() {
        var s = Schedule()
        XCTAssertEqual(s.phase(atMinute: 12 * 60), .day)
        XCTAssertEqual(s.phase(atMinute: 21 * 60), .night)
        XCTAssertEqual(s.phase(atMinute: 3 * 60), .night)
        s.dayStartMinute = 22 * 60; s.nightStartMinute = 6 * 60
        XCTAssertEqual(s.phase(atMinute: 23 * 60), .day)
        XCTAssertEqual(s.phase(atMinute: 12 * 60), .night)
    }
    func testBrightnessStepsLikeMacOS() {
        XCTAssertEqual(KeyStep.brightness(50, up: false, fine: false, in: 0...50), 48)
        XCTAssertEqual(KeyStep.brightness(48, up: true, fine: false, in: 0...50), 50)
        XCTAssertEqual(KeyStep.brightness(25, up: true, fine: false, in: 0...50), 27)
        XCTAssertEqual(KeyStep.brightness(1, up: false, fine: false, in: 0...50), 0)
        XCTAssertEqual(KeyStep.brightness(5, up: true, fine: true, in: 0...50), 6)
    }
    func testVolumeStepsAreFinerWhenQuiet() {
        XCTAssertEqual(KeyStep.volume(0, up: true, fine: false, in: 0...100), 1)
        XCTAssertEqual(KeyStep.volume(9, up: true, fine: false, in: 0...100), 11)
        XCTAssertEqual(KeyStep.volume(80, up: false, fine: false, in: 0...100), 74)
        XCTAssertEqual(KeyStep.volume(5, up: false, fine: true, in: 0...100), 4)
    }
    func testVolumeStepsReachBothEnds() {
        var v = 0, presses = 0
        while v < 100, presses < 100 { let n = KeyStep.volume(v, up: true, fine: false, in: 0...100); XCTAssertGreaterThan(n, v); v = n; presses += 1 }
        XCTAssertEqual(v, 100); XCTAssertLessThan(presses, 40)
        presses = 0
        while v > 0, presses < 100 { let n = KeyStep.volume(v, up: false, fine: false, in: 0...100); XCTAssertLessThan(n, v); v = n; presses += 1 }
        XCTAssertEqual(v, 0)
    }
    func testOlderSavedSettingsKeepTheirPairing() throws {
        let old = #"{"monitors":[{"id":"a","name":"M","host":"192.0.2.10"}],"volumeStep":2,"handleKeys":false}"#
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.monitors.first?.id, "a")
        XCTAssertFalse(s.handleKeys)
        XCTAssertTrue(s.showHUD)
    }
    func testQueueKeepsOnlyNewestValue() async throws {
        final class Box: @unchecked Sendable { let l = NSLock(); var v: [Int] = []; func add(_ i: Int) { l.withLock { v.append(i) } } }
        let box = Box()
        let q = LatestValueQueue<String, Int> { _, v in
            try? await Task.sleep(for: .milliseconds(40)); box.add(v)
        }
        for i in 0..<20 { await q.submit("a", i) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(box.v.last, 19)
        XCTAssertLessThan(box.v.count, 4)
    }
    func testSettingsSurviveEncoding() throws {
        var s = AppSettings(); s.showHUD = false
        let d = UserDefaults(suiteName: "test-\(UUID())")!
        s.save(d)
        XCTAssertEqual(AppSettings.load(d), s)
    }
}
