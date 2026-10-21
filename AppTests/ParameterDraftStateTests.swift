import XCTest
import ComfyCore
@testable import ComfyPocket

final class ParameterDraftStateTests: XCTestCase {
    @MainActor
    private func fixture() throws -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyPocket-parameters-" + UUID().uuidString)
        let state = AppState(store: try DiskStore(rootURL: directory))
        let workflow = try WorkflowApplicationFixture.make()
        state.saved.workflows = [workflow]
        state.saved.selectedWorkflowID = workflow.id
        state.seedText = "42"
        return state
    }
    @MainActor
    private func dispose(_ state: AppState) {
        state.saveTask?.cancel()
        if let root = state.disk?.root { try? FileManager.default.removeItem(at: root) }
    }
    @MainActor
    func testCancelSessionLeavesAllAppliedStateUntouched() throws {
        let state = try fixture()
        defer { dispose(state) }
        let original = state.saved
        let session = ParameterEditSession(workflow: try XCTUnwrap(state.selectedWorkflow), batch: 1, randomSeed: true, seedText: "42")
        session.draft.values["92|value"] = .string("1024")
        session.draft.values["26|steps"] = .string("25")
        session.allNodes = true
        session.selection = "26"
        XCTAssertEqual(session.draft.values["92|value"], .string("1024"))
        XCTAssertEqual(state.saved.workflows, original.workflows)
        XCTAssertEqual(state.batch, 1)
        XCTAssertTrue(state.randomSeed)
    }
    @MainActor
    func testApplyPersistsBothStagesAndDoesNotModifyGraph() throws {
        let state = try fixture()
        defer { dispose(state) }
        let original = try XCTUnwrap(state.selectedWorkflow)
        var draft = WorkflowParameterDraft(workflow: original)
        draft.values["26|steps"] = .string("22")
        draft.values["28|steps"] = .string("11")
        try state.commitParameters(draft, batch: 2, randomSeed: false, seedText: "18446744073709551614")
        XCTAssertEqual(state.selectedWorkflow?.graph, original.graph)
        XCTAssertEqual(state.selectedWorkflow?.lastValues["26|steps"], .integer(22))
        XCTAssertEqual(state.selectedWorkflow?.lastValues["28|steps"], .integer(11))
        XCTAssertEqual(state.batch, 2)
        XCTAssertFalse(state.randomSeed)
        XCTAssertEqual(state.seedText, "18446744073709551614")
        XCTAssertEqual(try state.disk?.load().workflows.first?.lastValues["28|steps"], .integer(11))
    }
    @MainActor
    func testDiskFailureRollsBackAppliedStateAndKeepsSessionDraft() throws {
        let state = try fixture()
        defer { dispose(state) }
        let original = try XCTUnwrap(state.selectedWorkflow)
        let session = ParameterEditSession(workflow: original, batch: 2, randomSeed: false, seedText: "99")
        session.draft.values["92|value"] = .string("1024")
        let store = try XCTUnwrap(state.disk)
        try FileManager.default.createDirectory(at: store.root.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try state.commitParameters(session.draft, batch: session.batch, randomSeed: session.randomSeed, seedText: session.seedText))
        XCTAssertEqual(state.selectedWorkflow, original)
        XCTAssertEqual(state.batch, 1)
        XCTAssertEqual(state.seedText, "42")
        XCTAssertTrue(state.randomSeed)
        XCTAssertEqual(session.draft.values["92|value"], .string("1024"))
    }
    @MainActor
    func testStaleApplyAndDeletedWorkflowDoNotOverwrite() throws {
        let state = try fixture()
        defer { dispose(state) }
        let draft = WorkflowParameterDraft(workflow: try XCTUnwrap(state.selectedWorkflow))
        state.saved.workflows[0].lastValues["92|value"] = .integer(1280)
        XCTAssertThrowsError(try state.commitParameters(draft, batch: 1, randomSeed: true, seedText: "42"))
        XCTAssertEqual(state.saved.workflows[0].lastValues["92|value"], .integer(1280))
        state.saved.workflows = []
        XCTAssertThrowsError(try state.commitParameters(draft, batch: 1, randomSeed: true, seedText: "42"))
    }
    @MainActor
    func testSelectedGroupsAndAllNodesShareOneDraft() throws {
        let state = try fixture()
        defer { dispose(state) }
        let session = ParameterEditSession(workflow: try XCTUnwrap(state.selectedWorkflow), batch: 1, randomSeed: true, seedText: "42")
        XCTAssertEqual(session.nodes.count, session.draft.workflow.graph.count)
        session.selection = "canvas"
        let width = try XCTUnwrap(session.selectedNodes.flatMap { $0.fields }.first { $0.id == "92|value" })
        session.text(width).wrappedValue = "1536"
        session.allNodes = true
        session.selection = "92"
        let same = try XCTUnwrap(session.selectedNodes.first?.fields.first { $0.id == "92|value" })
        XCTAssertEqual(session.value(same).text, "1536")
        XCTAssertTrue(state.selectedWorkflow?.lastValues.isEmpty == true)
    }
    @MainActor
    func testChangedAddressWithSameProfileIDRejectsStaleCapabilities() throws {
        let state = try fixture()
        defer { dispose(state) }
        let server = ServerProfile(address: "http://127.0.0.1:8188")
        state.saved.servers = [server]
        state.saved.selectedServerID = server.id
        state.saved.workflows[0].schemaServerID = server.id
        state.saved.workflows[0].schemaServerAddress = "http://127.0.0.1:9999"
        XCTAssertFalse(state.enqueue())
        XCTAssertTrue(state.saved.jobs.isEmpty)
        let draft = WorkflowParameterDraft(workflow: try XCTUnwrap(state.selectedWorkflow))
        XCTAssertThrowsError(try state.commitParameters(draft, batch: 1, randomSeed: true, seedText: "42"))
    }

    func testExhibitionFrameStaysWithinPhoneAndLandscapeBounds() {
        for viewport in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 812), CGSize(width: 812, height: 375)] {
            let rect = FuyuArtworkGeometry.exhibitionRect(viewport: viewport)
            XCTAssertGreaterThan(rect.width, 0)
            XCTAssertGreaterThan(rect.height, 0)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertGreaterThanOrEqual(rect.minY, 0)
            XCTAssertLessThanOrEqual(rect.maxX, viewport.width)
            XCTAssertLessThanOrEqual(rect.maxY, viewport.height)
        }
    }
}

