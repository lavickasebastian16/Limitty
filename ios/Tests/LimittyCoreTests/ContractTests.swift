import Foundation
import XCTest
@testable import LimittyCore

/// The phone and the PC talk through JSON files in your Gist. These check the
/// formats match: a snapshot made by the PC's own code (src/company/company.js
/// → snapshot()), and the inbox requests the PC reads (test/loop.test.js).
final class ContractTests: XCTestCase {
    static let pcSnapshot = #"{"v":1,"projects":[{"name":"shop"}],"workers":{"claude":{"name":"Claude Code","strengths":"complex reasoning, debugging, refactors across many files","available":true,"busy":false,"remaining":null,"models":[{"id":"opus","label":"Opus","tier":"strongest","remaining":null},{"id":"sonnet","label":"Sonnet","tier":"balanced","remaining":null},{"id":"haiku","label":"Haiku","tier":"fast","remaining":null}]},"codex":{"name":"Codex","strengths":"well-scoped implementation, tests, scripts","available":true,"busy":false,"remaining":null,"models":[{"id":"high","label":"high effort","tier":"strongest","remaining":null},{"id":"medium","label":"medium effort","tier":"balanced","remaining":null},{"id":"low","label":"low effort","tier":"fast","remaining":null}]},"agy":{"name":"Antigravity (Gemini)","strengths":"frontend/UI work, quick edits, research","available":true,"busy":false,"remaining":null,"models":[{"id":"default","label":"default model","tier":"balanced","remaining":null}]}},"ceo":"claude","tasks":[{"id":"20aa75ae5cf1","title":"Add checkout","project":"shop","worker":"auto","source":"phone","status":"done","error":null,"createdAt":1794329632,"updatedAt":1794329632,"plan":{"summary":"UI to agy","by":"claude","steps":[{"worker":"agy","model":"default","modelLabel":"default model","title":"Checkout UI","why":"frontend/UI work","status":"done","output":"ok","startedAt":1794329632,"finishedAt":1794329632}]}}]}"#

    func testPhoneReadsThePCsTaskList() throws {
        let state = try JSONDecoder().decode(CompanyState.self, from: Data(Self.pcSnapshot.utf8))
        XCTAssertEqual(state.projects.map(\.name), ["shop"])
        XCTAssertEqual(state.ceo, "claude")
        XCTAssertEqual(state.workers["agy"]?.strengths, "frontend/UI work, quick edits, research")
        let task = try XCTUnwrap(state.tasks.first)
        XCTAssertEqual(task.title, "Add checkout")
        XCTAssertEqual(task.statusLabel, "Done")
        XCTAssertEqual(task.source, "phone")
        XCTAssertEqual(task.plan?.steps.first?.why, "frontend/UI work")
        XCTAssertFalse(task.isActive)
    }

    func testPhoneWritesWhatThePCReads() throws {
        let req = CompanyRequest.create(title: "Add a checkout page", project: "shop", worker: "auto")
        let data = try JSONEncoder().encode(CompanyInbox(requests: [req, .action("cancel", task: "t1")]))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try XCTUnwrap(json["requests"] as? [[String: Any]])
        // The PC's Company.handleInbox reads: id, kind, title, project, worker, task.
        XCTAssertEqual(requests[0]["kind"] as? String, "create")
        XCTAssertEqual(requests[0]["title"] as? String, "Add a checkout page")
        XCTAssertEqual(requests[0]["project"] as? String, "shop")
        XCTAssertEqual(requests[0]["worker"] as? String, "auto")
        XCTAssertNotNil(requests[0]["id"] as? String)
        XCTAssertEqual(requests[1]["kind"] as? String, "cancel")
        XCTAssertEqual(requests[1]["task"] as? String, "t1")
    }
}
