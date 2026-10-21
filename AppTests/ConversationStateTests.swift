import XCTest
import ComfyCore
@testable import ComfyPocket

final class ConversationStateTests: XCTestCase {
    @MainActor
    private func fixture() throws -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyPocket-conversation-" + UUID().uuidString, isDirectory: true)
        let state = AppState(store: try DiskStore(rootURL: directory))
        let graph = #"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"original prompt"}},"2":{"class_type":"EmptyLatentImage","inputs":{"width":512,"height":768,"batch_size":1}}}"#
        var workflow = try WorkflowImporter.parse(Data(graph.utf8), name: "Conversation fixture")
        let prompt = try XCTUnwrap(workflow.mainPrompt)
        workflow.lastValues[prompt.id] = .string("a new prompt")
        if let width = workflow.editableInputs.first(where: { $0.kind == .width }) { workflow.lastValues[width.id] = .integer(640) }
        let server = ServerProfile()
        state.saved.workflows = [workflow]
        state.saved.selectedWorkflowID = workflow.id
        state.saved.servers = [server]
        state.saved.selectedServerID = server.id
        return state
    }

    @MainActor
    private func dispose(_ state: AppState) {
        state.saveTask?.cancel()
        for task in state.tasks.values { task.cancel() }
        if let root = state.disk?.root { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor
    private func outputs(_ json: String, promptID: String) throws -> [OutputDescriptor] {
        OutputParser.parse(promptID: promptID, outputs: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    @MainActor
    func testComposerClearsOnlyAfterDurableSnapshotAndKeepsOtherParameters() throws {
        let state = try fixture()
        defer { dispose(state) }
        let workflow = try XCTUnwrap(state.selectedWorkflow)
        let prompt = try XCTUnwrap(workflow.mainPrompt)
        let dimensions = workflow.lastValues.filter { $0.key != prompt.id }
        XCTAssertTrue(state.enqueue(clearPrompt: true))
        XCTAssertEqual(state.value(prompt).text, "")
        let job = try XCTUnwrap(state.saved.jobs.last)
        XCTAssertEqual(job.values[prompt.id]?.text, "a new prompt")
        XCTAssertEqual(job.prompt, "a new prompt")
        XCTAssertEqual(job.workflow.lastValues[prompt.id]?.text, "a new prompt")
        XCTAssertEqual(state.selectedWorkflow?.lastValues.filter { $0.key != prompt.id }, dimensions)
        let persisted = try XCTUnwrap(state.disk).load()
        XCTAssertEqual(persisted.workflows.first?.lastValues[prompt.id]?.text, "")
        XCTAssertEqual(persisted.jobs.first?.values[prompt.id]?.text, "a new prompt")
        XCTAssertFalse(state.enqueue(clearPrompt: true))
        XCTAssertEqual(state.saved.jobs.count, 1)
    }

    @MainActor
    func testInvalidSubmissionPreservesDraftAndDoesNotAppendJob() throws {
        let state = try fixture()
        defer { dispose(state) }
        let prompt = try XCTUnwrap(state.selectedWorkflow?.mainPrompt)
        state.seedText = "not a seed"
        XCTAssertFalse(state.enqueue(clearPrompt: true))
        XCTAssertEqual(state.value(prompt).text, "a new prompt")
        XCTAssertTrue(state.saved.jobs.isEmpty)
        XCTAssertNotNil(state.error)
    }

    @MainActor
    func testPersistenceFailureRestoresDraftAndRemovesUncommittedJob() throws {
        let state = try fixture()
        defer { dispose(state) }
        let prompt = try XCTUnwrap(state.selectedWorkflow?.mainPrompt)
        let store = try XCTUnwrap(state.disk)
        try FileManager.default.createDirectory(at: store.root.appendingPathComponent("state.json"), withIntermediateDirectories: true)
        XCTAssertFalse(state.enqueue(clearPrompt: true))
        XCTAssertEqual(state.value(prompt).text, "a new prompt")
        XCTAssertTrue(state.saved.jobs.isEmpty)
        XCTAssertTrue(state.tasks.isEmpty)
    }

    @MainActor
    func testOtherEnqueueCallersKeepTheirPrompt() throws {
        let state = try fixture()
        defer { dispose(state) }
        let prompt = try XCTUnwrap(state.selectedWorkflow?.mainPrompt)
        XCTAssertTrue(state.enqueue())
        XCTAssertEqual(state.value(prompt).text, "a new prompt")
    }

    @MainActor
    func testGalleryGroupsByJobAndPromptAndKeepsSupplementaryTextInDetail() throws {
        let state = try fixture()
        defer { dispose(state) }
        XCTAssertTrue(state.enqueue())
        let job = try XCTUnwrap(state.saved.jobs.last)
        let mixed = try outputs(#"{"1":{"images":[{"filename":"result.png"}]},"2":{"text":["a new prompt"],"string":"a new prompt"},"3":{"text":["negative: blur"]}}"#, promptID: "first")
        let mediaAssets = mixed.map { GalleryAsset(jobID: job.id, remoteKey: $0.id, promptID: "first", output: $0, seed: 1) }
        state.saved.assets = mediaAssets
        XCTAssertEqual(state.galleryAssets.count, 1)
        let image = try XCTUnwrap(state.galleryAssets.first)
        XCTAssertEqual(state.supplementaryTextOutputs(for: image).map { $0.text }, ["negative: blur"])
        let texts = try outputs(#"{"1":{"text":"a new prompt","string":"a new prompt"}}"#, promptID: "second")
        state.saved.assets += texts.map { GalleryAsset(jobID: job.id, remoteKey: $0.id, promptID: "second", output: $0, seed: 1) }
        let anotherJobID = UUID()
        state.saved.assets += texts.map { GalleryAsset(jobID: anotherJobID, remoteKey: $0.id, promptID: "second", output: $0, seed: 1) }
        XCTAssertEqual(state.galleryAssets.count, 3)
        XCTAssertEqual(state.saved.assets.count, 8)
        let store = try XCTUnwrap(state.disk)
        try state.persist()
        let restored = AppState(store: store)
        XCTAssertEqual(restored.galleryAssets.count, 3)
        XCTAssertEqual(restored.saved.assets.count, 8)
    }

    @MainActor
    func testDeletingMediaDoesNotResurrectPromptCards() throws {
        let state = try fixture()
        defer { dispose(state) }
        let result = try outputs(#"{"1":{"images":[{"filename":"result.png"}],"text":"prompt"}}"#, promptID: "first")
        let identity = UUID()
        state.saved.assets = result.map { GalleryAsset(jobID: identity, remoteKey: $0.id, promptID: "first", output: $0, seed: 1) }
        let image = try XCTUnwrap(state.galleryAssets.first)
        state.removeAsset(image)
        XCTAssertTrue(state.galleryAssets.isEmpty)
        XCTAssertEqual(state.saved.assets.count, 2)
        XCTAssertEqual(state.visibleAssets.count, 1)
    }
}
