import XCTest
import SwiftUI
import Security
import ComfyCore
@testable import ComfyPocket

final class GenerationIntegrationTests: XCTestCase {
    @MainActor
    func testRealComfyUIGenerationUploadAndBackground() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComfyPocket-integration-" + UUID().uuidString, isDirectory: true)
        let store = try DiskStore(rootURL: directory)
        let state = AppState(store: store)
        var server = ServerProfile()
        server.address = "http://127.0.0.1:8188"
        defer {
            for task in state.tasks.values { task.cancel() }
            state.saveTask?.cancel()
            try? FileManager.default.removeItem(at: directory)
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.ray.comfypocket.server", kSecAttrAccount as String: server.id.uuidString]
            SecItemDelete(query as CFDictionary)
        }
        try state.saveServer(server, password: "")
        let api = try ComfyClient(server: server)
        defer { api.close() }
        let stats = try await api.json("system_stats")
        XCTAssertNotNil(stats["system"]?["python_version"]?.string)
        let graph = #"{"1":{"class_type":"EmptyImage","inputs":{"width":384,"height":768,"batch_size":1,"color":3297127}},"2":{"class_type":"SaveImage","inputs":{"images":["1",0],"filename_prefix":"ComfyPocket_native_test"}}}"#
        var workflow = try WorkflowImporter.parse(Data(graph.utf8), name: "原生生成验收")
        let chatField = try XCTUnwrap(workflow.editableInputs.first { $0.field == "filename_prefix" })
        workflow.mainPromptID = chatField.id
        workflow.lastValues[chatField.id] = chatField.defaultValue
        state.saved.workflows = [workflow]
        state.selectWorkflow(workflow.id)
        state.batch = 2
        state.randomSeed = false
        state.seedText = "42"
        XCTAssertTrue(state.enqueue(clearPrompt: true))
        XCTAssertEqual(state.value(chatField).text, "")
        XCTAssertEqual(state.saved.jobs.last?.values[chatField.id]?.text, "ComfyPocket_native_test")
        XCTAssertNil(state.error)
        let firstJobID = try XCTUnwrap(state.saved.jobs.last?.id)
        try await waitForSuccess(firstJobID, state: state)
        XCTAssertEqual(state.job(firstJobID)?.finishedCount, 2)
        XCTAssertEqual(Set(state.job(firstJobID)?.records.compactMap(\.promptID) ?? []).count, 2)
        XCTAssertEqual(state.visibleAssets.count, 2)
        XCTAssertNotNil(state.saved.backgroundAssetID)
        XCTAssertNotNil(state.backgroundImage)
        let generated = try XCTUnwrap(state.visibleAssets.first)
        let filename = try XCTUnwrap(generated.localName)
        let imageURL = store.mediaURL(filename)
        let image = try XCTUnwrap(UIImage(contentsOfFile: imageURL.path))
        XCTAssertEqual(image.size.width, 384)
        XCTAssertEqual(image.size.height, 768)
        try await attachGeneratedScreen(state)
        let uploadGraph = #"{"1":{"class_type":"LoadImage","inputs":{"image":"select.png"}},"2":{"class_type":"SaveImage","inputs":{"images":["1",0],"filename_prefix":"ComfyPocket_upload_test"}}}"#
        let uploadWorkflow = try WorkflowImporter.parse(Data(uploadGraph.utf8), name: "参考图上传验收")
        state.saved.workflows.append(uploadWorkflow)
        state.selectWorkflow(uploadWorkflow.id)
        let input = try XCTUnwrap(uploadWorkflow.inputs.first { $0.kind == .image })
        try state.stageAttachment(from: imageURL, specID: input.id)
        state.batch = 1
        state.enqueue()
        XCTAssertNil(state.error)
        let uploadJobID = try XCTUnwrap(state.saved.jobs.last?.id)
        XCTAssertNotEqual(uploadJobID, firstJobID)
        try await waitForSuccess(uploadJobID, state: state)
        XCTAssertTrue(state.job(uploadJobID)?.values[input.id]?.string?.hasPrefix("comfy_pocket/") == true)
        XCTAssertEqual(state.visibleAssets.count, 3)
        let persisted = try store.load()
        XCTAssertEqual(persisted.assets.filter { !$0.removed }.count, 3)
        XCTAssertEqual(persisted.jobs.filter { $0.phase == .success }.count, 2)
        XCTAssertEqual(persisted.backgroundAssetID, state.saved.backgroundAssetID)
        XCTAssertTrue(persisted.assets.allSatisfy { asset in
            guard let local = asset.localName else { return false }
            return FileManager.default.fileExists(atPath: store.mediaURL(local).path)
        })
        let queueGraph = #"{"1":{"class_type":"EmptyImage","inputs":{"width":96,"height":128,"batch_size":1,"color":3297127}},"2":{"class_type":"SaveImage","inputs":{"images":["1",0],"filename_prefix":["16",1]}},"16":{"class_type":"RayPromptQueue","inputs":{"prompts":"queue first\n---\nqueue second","format":"用 --- 分隔","first":1,"last":0,"base_seed":42,"output_folder":"ComfyPocket_queue_test","seed_mode":"每张随机"}}}"#
        var queueWorkflow = try WorkflowImporter.parse(Data(queueGraph.utf8), name: "手机 Ray 队列展开验收")
        queueWorkflow.queueMode = .all
        state.saved.workflows.append(queueWorkflow)
        state.selectWorkflow(queueWorkflow.id)
        state.randomSeed = false
        state.seedText = "100"
        state.enqueue()
        XCTAssertNil(state.error)
        let queueJobID = try XCTUnwrap(state.saved.jobs.last?.id)
        try await waitForSuccess(queueJobID, state: state)
        let queueJob = try XCTUnwrap(state.job(queueJobID))
        XCTAssertEqual(queueJob.totalCount, 2)
        XCTAssertEqual(queueJob.finishedCount, 2)
        XCTAssertTrue(queueJob.prompts.allSatisfy { $0.graph["16"] == nil })
        XCTAssertEqual(queueJob.prompts.map { $0.promptText ?? "" }, ["queue first", "queue second"])
        XCTAssertEqual(queueJob.prompts.map { $0.seed }, [100, 101])
        XCTAssertEqual(state.visibleAssets.filter { $0.jobID == queueJobID }.count, 2)
        XCTAssertTrue(state.visibleAssets.filter { $0.jobID == queueJobID }.allSatisfy { $0.output.subfolder == "ComfyPocket_queue_test" })
    }

    @MainActor
    private func waitForSuccess(_ identity: UUID, state: AppState) async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let current = try XCTUnwrap(state.job(identity))
            if current.phase == .success { return }
            if [.failed, .attention, .waiting, .cancelled].contains(current.phase) {
                XCTFail("Native generation stopped: " + current.phase.rawValue + " — " + current.message)
                throw ComfyError.invalid(current.message)
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("Real ComfyUI did not complete within 90 seconds")
        throw URLError(.timedOut)
    }

    @MainActor
    private func attachGeneratedScreen(_ state: AppState) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = UIHostingController(rootView: RootView().environmentObject(state))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        window.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 500_000_000)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Native XS-sized view — real ComfyUI output background"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
