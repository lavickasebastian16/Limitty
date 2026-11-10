import Foundation
import XCTest
@testable import LimittyCore

final class NotifyTests: XCTestCase {
    private func status(_ sessions: [(String, AgentState, String)]) -> AgentStatus {
        AgentStatus(host: "pc", sentAt: 1, sessions: sessions.map { id, state, detail in
            AgentSession(agent: "claude", name: "Claude Code", id: id, project: "site", state: state, detail: detail, since: 1)
        })
    }

    func testBarkLinkParsing() {
        XCTAssertEqual(BarkLink.parse("https://api.day.app/AbCdEf123456/This is a test"), .init(key: "AbCdEf123456"))
        XCTAssertEqual(BarkLink.parse(" AbCdEf123456 "), .init(key: "AbCdEf123456"))
        XCTAssertEqual(BarkLink.parse("Example: https://bark.example.com:8443/Key_123456/hello?sound=bell"),
                       .init(server: "https://bark.example.com:8443", key: "Key_123456"))
        XCTAssertNil(BarkLink.parse("http://api.day.app/AbCdEf123456"))
        XCTAssertNil(BarkLink.parse("hello"))
    }

    func testAlertsOnlyForChanges() {
        let a = status([("1", .working, "Using Bash")])
        XCTAssertEqual(AlertDetector.alerts(from: nil, to: a), [], "nothing on first load")
        let b = status([("1", .attention, "Claude needs your permission to use Bash")])
        let alerts = AlertDetector.alerts(from: a, to: b)
        XCTAssertEqual(alerts.map(\.kind), [.attention])
        XCTAssertEqual(alerts.first?.title, "Claude Code needs you · site")
        XCTAssertEqual(AlertDetector.alerts(from: b, to: b), [], "no repeat")
        let c = status([("1", .idle, "Finished")])
        XCTAssertEqual(AlertDetector.alerts(from: b, to: c).map(\.kind), [.done])
        XCTAssertEqual(AlertDetector.alerts(from: c, to: c), [])
    }

    func testTaskAlerts() throws {
        func company(_ status: String) throws -> CompanyState {
            let json = #"{"projects":[],"workers":{},"tasks":[{"id":"t1","title":"Fix login","project":"site","worker":"auto","status":"\#(status)","createdAt":1,"updatedAt":2}]}"#
            return try JSONDecoder().decode(CompanyState.self, from: Data(json.utf8))
        }
        XCTAssertEqual(AlertDetector.alerts(from: try company("running"), to: try company("done")).map(\.kind), [.done])
        XCTAssertEqual(AlertDetector.alerts(from: try company("running"), to: try company("failed")).map(\.kind), [.attention])
        XCTAssertEqual(AlertDetector.alerts(from: try company("done"), to: try company("done")), [])
    }

    func testSettingsDefaultsAndSwitches() throws {
        var s = PhoneSettings()
        XCTAssertEqual(s.notify.sounds.attention, "alarm")
        XCTAssertNotEqual(s.notify.localSounds.attention, s.notify.localSounds.done, "different sounds by default")
        XCTAssertTrue(s.wants(.done))
        s.notify.finished = false
        XCTAssertFalse(s.wants(.done))
        XCTAssertTrue(s.wants(.attention))
        // Old/partial files still decode.
        let partial = try JSONDecoder().decode(PhoneSettings.self, from: Data(#"{"v":1,"notify":{"bark":{"server":"https://api.day.app","key":"AbCdEf123456"}},"updatedAt":0}"#.utf8))
        XCTAssertEqual(partial.notify.bark?.key, "AbCdEf123456")
        XCTAssertEqual(partial.notify.sounds.done, "glass")
        XCTAssertTrue(BarkSound.all.contains(s.notify.sounds.attention))
    }

    func testGeneratedSoundsAreValidWAVs() throws {
        for sound in LocalSound.allCases where sound != .system {
            let d = sound.wav()
            XCTAssertEqual(String(decoding: d.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: d[8..<12], as: UTF8.self), "WAVE")
            XCTAssertGreaterThan(d.count, 10_000, "\(sound) has audio")
            XCTAssertLessThan(d.count, 200_000, "\(sound) is short")
        }
        XCTAssertNotEqual(LocalSound.alert.wav(), LocalSound.chime.wav())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("limitty-sounds-\(UUID().uuidString)")
        LocalSound.install(in: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("limitty-alert.wav").path))
    }

    func testBarkSendFromPhone() async throws {
        let http = FakeHTTP(["https://api.day.app/push": (200, "{}")])
        try await BarkLink.send(.init(key: "AbCdEf123456"), title: "t", body: "b", sound: "bell", kind: .done, http: http)
        let sent = try XCTUnwrap(http.calls.last?.body)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: String])
        XCTAssertEqual(json["sound"], "bell")
        XCTAssertEqual(json["level"], "active")
    }
}
