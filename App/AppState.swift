import SwiftUI
import UIKit
import ComfyCore

@MainActor
final class AppState: ObservableObject {
    @Published var saved = SavedState()
    @Published var error: String?
    @Published var notice: String?
    @Published var draftUploads: [String: String] = [:]
    @Published var batch = 1
    @Published var randomSeed = true
    @Published var seedText = "1"
    @Published var connecting = false
    @Published var connectionResult = ""
    var disk: DiskStore?
    var tasks: [UUID: Task<Void, Never>] = [:]
    var saveTask: Task<Void, Never>?
    var pendingResumes = Set<UUID>()
    var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var storageReady: Bool { disk != nil }
    var selectedWorkflow: Workflow? { saved.workflows.first { $0.id == saved.selectedWorkflowID } }
    var selectedServer: ServerProfile? { saved.servers.first { $0.id == saved.selectedServerID } }
    var visibleAssets: [GalleryAsset] { saved.assets.filter { !$0.removed }.sorted { $0.createdAt > $1.createdAt } }
    var galleryAssets: [GalleryAsset] {
        let groups = Dictionary(grouping: saved.assets) { $0.jobID.uuidString + ":" + $0.promptID }
        return groups.values.flatMap { assets in
            let hasMedia = assets.contains { $0.output.kind != .text }
            let visible = assets.filter { !$0.removed && (!hasMedia || $0.output.kind != .text) }
            return OutputPresentation.galleryOutputs(visible.map { $0.output }).compactMap { output in visible.first { $0.output.id == output.id } }
        }.sorted { $0.createdAt > $1.createdAt }
    }
    func supplementaryTextOutputs(for asset: GalleryAsset) -> [OutputDescriptor] {
        let outputs = visibleAssets.filter { $0.jobID == asset.jobID && $0.promptID == asset.promptID }.map { $0.output }
        return OutputPresentation.distinctTextOutputs(outputs, excluding: job(asset.jobID)?.prompt(for: asset.promptID))
    }
    var activeJobs: [GenerationJob] { saved.jobs.filter { !$0.phase.isTerminal }.sorted { $0.createdAt > $1.createdAt } }
    var backgroundImage: UIImage? { loadBackgroundImage(maxPixel: 1600) }
    func loadBackgroundImage(maxPixel: Int) -> UIImage? {
        let images = visibleAssets.filter { $0.output.kind == .image && $0.localName != nil }
        let selected = images.first { $0.id == saved.backgroundAssetID }
        var candidates = images
        if let selected = selected { candidates = [selected] + images.filter { $0.id != selected.id } }
        for asset in candidates {
            if let name = asset.localName, let url = disk?.mediaURL(name), let image = MediaImages.image(url: url, maxPixel: maxPixel) { return image }
        }
        return nil
    }

    init(store suppliedStore: DiskStore? = nil) {
        do {
            let store = try suppliedStore ?? DiskStore()
            let state: SavedState
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") { state = SavedState() }
            else { state = try store.load() }
            disk = store
            saved = state
            saved.workflows = state.workflows.map { (try? WorkflowImporter.reanalyze($0)) ?? $0 }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--workflow-app-demo") {
                let fixture = try WorkflowApplicationFixture.make()
                saved.workflows = [fixture]
                saved.selectedWorkflowID = fixture.id
                var server = ServerProfile()
                server.address = "http://127.0.0.1:8188"
                saved.servers = [server]
                saved.selectedServerID = server.id
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--artwork-demo") {
                let name = "canvas-ui-fixture.png"
                if let data = WorkflowApplicationFixture.artwork().pngData() {
                    try data.write(to: store.mediaURL(name))
                    let outputs: JSONValue = .object(["fixture": .object(["images": .array([.object(["filename": .string(name), "type": .string("output")])])])])
                    guard let output = OutputParser.parse(promptID: "canvas-fixture", outputs: outputs).first else { throw ComfyError.invalid("测试画布无法创建。") }
                    let asset = GalleryAsset(jobID: UUID(), remoteKey: "canvas-fixture", promptID: "canvas-fixture", output: output, seed: 1, localName: name)
                    saved.assets = [asset]
                    saved.backgroundAssetID = asset.id
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--conversation-demo") {
                try WorkflowApplicationFixture.installConversation(in: self)
            }
            #endif
            loadGenerationDefaults()
            store.pruneUploads(keeping: Set(state.jobs.flatMap { Array($0.uploads.values) }))
        } catch {
            self.error = "无法读取本地资料，已停止写入以保护原文件。请保留 App，截取此错误后反馈，勿卸载：" + error.localizedDescription
            disk = nil
        }
    }

    func persist() throws {
        guard let disk = disk else { throw ComfyError.invalid("本地存储不可用，已停止操作以保护资料。") }
        try disk.save(saved)
    }
    func persistSoon() {
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(nanoseconds: 450_000_000); try persist() }
            catch is CancellationError {} catch { self.error = "保存失败：" + error.localizedDescription }
        }
    }
    func report(_ error: Error) { self.error = error.localizedDescription }

    func value(_ spec: InputSpec, workflowID: UUID? = nil) -> JSONValue {
        saved.workflows.first { $0.id == (workflowID ?? saved.selectedWorkflowID) }?.lastValues[spec.id] ?? spec.defaultValue
    }
    func setValue(_ spec: InputSpec, text: String, workflowID: UUID? = nil) {
        guard let index = saved.workflows.firstIndex(where: { $0.id == (workflowID ?? saved.selectedWorkflowID) }) else { return }
        let value: JSONValue
        switch spec.kind {
        case .integer, .width, .height: value = Int64(text).map(JSONValue.integer) ?? .string(text)
        case .decimal: value = Double(text).flatMap { $0.isFinite ? .decimal($0) : nil } ?? .string(text)
        case .seed: value = UInt64(text).map(JSONValue.unsigned) ?? .string(text)
        default: value = .string(text)
        }
        saved.workflows[index].lastValues[spec.id] = value
        persistSoon()
    }
    func setBool(_ spec: InputSpec, value: Bool, workflowID: UUID? = nil) {
        guard let index = saved.workflows.firstIndex(where: { $0.id == (workflowID ?? saved.selectedWorkflowID) }) else { return }
        saved.workflows[index].lastValues[spec.id] = .bool(value)
        persistSoon()
    }
    func setLoRA(_ nodeID: String, enabled: Bool) {
        guard let index = saved.workflows.firstIndex(where: { $0.id == saved.selectedWorkflowID }) else { return }
        saved.workflows[index].loraEnabled[nodeID] = enabled
        persistSoon()
    }
    func selectWorkflow(_ id: UUID) {
        if saved.selectedWorkflowID != id {
            if let disk = disk { for name in draftUploads.values { try? FileManager.default.removeItem(at: disk.uploadURL(name)) } }
            draftUploads = [:]
        }
        saved.selectedWorkflowID = id
        loadGenerationDefaults()
        persistSoon()
    }
    func loadGenerationDefaults() {
        guard let workflow = selectedWorkflow else { return }
        if let spec = workflow.editableInputs.first(where: { $0.kind == .seed }) {
            seedText = (workflow.lastValues[spec.id] ?? spec.defaultValue).text
        }
        if let node = workflow.graph.values.first(where: { $0["class_type"]?.string == "RayPromptQueue" }) {
            randomSeed = node["inputs"]?["seed_mode"]?.string?.contains("随机") ?? true
        }
    }
    func configureField(_ spec: InputSpec, workflowID: UUID, change: (inout ApplicationField) -> Void) {
        guard let index = saved.workflows.firstIndex(where: { $0.id == workflowID }) else { return }
        var field = saved.workflows[index].applicationField(spec)
        change(&field)
        if saved.workflows[index].applicationFields == nil { saved.workflows[index].applicationFields = [:] }
        saved.workflows[index].applicationFields?[spec.id] = field
        persistSoon()
    }
    func moveApplicationFields(workflowID: UUID, from: IndexSet, to: Int) {
        guard let workflow = saved.workflows.first(where: { $0.id == workflowID }) else { return }
        var fields = workflow.applicationInputs
        fields.move(fromOffsets: from, toOffset: to)
        for (position, spec) in fields.enumerated() { configureField(spec, workflowID: workflowID) { $0.order = position } }
    }
    func importWorkflow(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20 * 1024 * 1024 else { throw ComfyError.invalid("工作流超过 20 MB。") }
            let workflow = try WorkflowImporter.parse(Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
            saved.workflows.append(workflow)
            selectWorkflow(workflow.id)
            try persist()
            notice = "已导入「\(workflow.name)」"
            await refreshChoices()
        } catch { report(error) }
    }
    func refreshChoices() async {
        guard let server = selectedServer, let workflow = selectedWorkflow else { return }
        do {
            let client = try ComfyClient(server: server)
            defer { client.close() }
            let info = try await client.json("object_info")
            guard let index = saved.workflows.firstIndex(where: { $0.id == workflow.id }) else { return }
            let current = saved.workflows[index]
            guard selectedServer?.id == server.id, selectedServer?.address == server.address else { return }
            saved.workflows[index] = WorkflowImporter.applyChoices(current, objectInfo: info, serverID: server.id, serverAddress: server.address)
            try persist()
        } catch { report(error) }
    }
    func commitParameters(_ draft: WorkflowParameterDraft, batch: Int, randomSeed: Bool, seedText: String) throws {
        guard let index = saved.workflows.firstIndex(where: { $0.id == draft.source.id }) else { throw ComfyError.invalid("工作流已被删除。") }
        guard (1...8).contains(batch), draft.workflow.seedStrategy == .perNode || UInt64(seedText) != nil else { throw ComfyError.invalid("生成份数应为 1–8，种子应为非负整数。") }
        let updated = try draft.applied(to: saved.workflows[index])
        if let origin = updated.schemaServerID, origin != selectedServer?.id { throw ComfyError.invalid("节点能力来自另一台服务器，请刷新后再应用。") }
        if let address = updated.schemaServerAddress, address != selectedServer?.address { throw ComfyError.invalid("连接地址已改变，请刷新节点能力后再应用。") }
        if updated.hasRayQueue && updated.seedStrategy == .perNode { throw ComfyError.invalid("Ray 队列需要使用统一种子。") }
        let selection = try RayQueue.selection(workflow: updated, values: updated.lastValues)
        let count = (selection?.prompts.count ?? 1) * batch
        guard count <= RayQueue.maximumTasks else { throw ComfyError.invalid("本次超过手机端 64 个独立任务上限。") }
        for parameter in WorkflowParameters.nodes(updated).flatMap({ $0.fields }) where parameter.spec.kind == .seed && parameter.readOnlyReason == nil {
            if updated.seedStrategy != .perNode && randomSeed { continue }
            let text = updated.seedStrategy == .perNode ? (updated.lastValues[parameter.id] ?? parameter.rawValue).text : seedText
            guard let seed = UInt64(text) else { throw ComfyError.invalid("节点种子应为非负整数。") }
            let last = seed.addingReportingOverflow(UInt64(count - 1))
            guard !last.overflow else { throw ComfyError.invalid("种子随任务递增后溢出，请减小种子或任务数。") }
            _ = try WorkflowParameters.normalized(.unsigned(seed), parameter: parameter)
            _ = try WorkflowParameters.normalized(.unsigned(last.partialValue), parameter: parameter)
        }
        let backup = saved
        let oldBatch = self.batch
        let oldRandom = self.randomSeed
        let oldSeed = self.seedText
        saved.workflows[index] = updated
        if saved.selectedWorkflowID == updated.id {
            self.batch = batch
            self.randomSeed = randomSeed
            self.seedText = seedText
        }
        do { try persist() }
        catch {
            saved = backup
            self.batch = oldBatch
            self.randomSeed = oldRandom
            self.seedText = oldSeed
            throw error
        }
    }

    func parameterCapabilities() async throws -> (info: JSONValue, serverID: UUID, serverAddress: String) {
        guard let server = selectedServer else { throw ComfyError.invalid("请先保存并选择服务器连接。") }
        let client = try ComfyClient(server: server)
        defer { client.close() }
        let info = try await client.json("object_info")
        guard selectedServer?.id == server.id, selectedServer?.address == server.address else { throw ComfyError.invalid("连接已切换，请重新刷新能力。") }
        guard info.object != nil else { throw ComfyError.invalid("服务器节点描述不是有效对象。") }
        return (info, server.id, server.address)
    }

    func saveServer(_ profile: ServerProfile, password: String) throws {
        var server = profile
        server.address = try ServerAddress.normalized(profile.address).absoluteString
        guard !server.username.contains(":") else { throw ComfyError.invalid("Basic Auth 用户名不能包含冒号。") }
        try PasswordStore.save(password, id: server.id)
        if let index = saved.servers.firstIndex(where: { $0.id == server.id }) { saved.servers[index] = server }
        else { saved.servers.append(server) }
        saved.selectedServerID = server.id
        try persist()
        connectionResult = ""
    }
    func testConnection(_ profile: ServerProfile, password: String) async {
        connecting = true
        connectionResult = ""
        defer { connecting = false }
        do {
            try saveServer(profile, password: password)
            guard let server = selectedServer else { return }
            let client = try ComfyClient(server: server)
            defer { client.close() }
            let started = Date()
            let stats = try await client.json("system_stats")
            let version = stats["system"]?["comfyui_version"]?.string ?? "已连接"
            connectionResult = "ComfyUI \(version)  ·  \(Int(Date().timeIntervalSince(started) * 1000)) ms"
            await refreshChoices()
        } catch { connectionResult = "连接测试失败：" + error.localizedDescription }
    }
    func stageAttachment(from url: URL, specID: String) throws {
        guard let disk = disk else { throw ComfyError.invalid("本地存储不可用。") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 300 * 1024 * 1024 else { throw ComfyError.invalid("素材应大于 0 字节且不超过 300 MB。") }
        let isImage = selectedWorkflow?.inputs.first { $0.id == specID }?.kind == .image
        let needsConversion = isImage && ["heic", "heif"].contains(url.pathExtension.lowercased())
        let name = UUID().uuidString + "." + (needsConversion ? "jpg" : url.pathExtension.lowercased())
        if needsConversion {
            guard let image = MediaImages.image(url: url, maxPixel: 4096), let data = image.jpegData(compressionQuality: 0.95) else { throw ComfyError.invalid("无法转换 HEIC 参考图，请改选 PNG 或 JPEG。") }
            try data.write(to: disk.uploadURL(name), options: .atomic)
            notice = "参考图已转为 JPEG，最长边不超过 4096；相册原图未修改"
        } else { try FileManager.default.copyItem(at: url, to: disk.uploadURL(name)) }
        if let old = draftUploads[specID] { try? FileManager.default.removeItem(at: disk.uploadURL(old)) }
        draftUploads[specID] = name
    }
    @discardableResult
    func enqueue(clearPrompt: Bool = false) -> Bool {
        var copiedFiles: [URL] = []
        var appendedID: UUID?
        var clearedPrompt: (workflowID: UUID, specID: String, value: JSONValue?)?
        do {
            guard let disk = disk, let server = selectedServer else { throw ComfyError.invalid("先在设置里保存 ComfyUI 连接。") }
            guard let workflow = selectedWorkflow else { throw ComfyError.invalid("先导入一份 API 格式工作流。") }
            if let address = workflow.schemaServerAddress, address != server.address { throw ComfyError.invalid("连接地址已改变，请先在工作流参数中刷新节点能力并应用。") }
            if let origin = workflow.schemaServerID, origin != server.id { throw ComfyError.invalid("工作流的节点能力来自另一台服务器，请先在工作流参数中刷新能力并应用。") }
            if clearPrompt, let spec = workflow.mainPrompt, (workflow.lastValues[spec.id] ?? spec.defaultValue).text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ComfyError.invalid("先写下提示词再发送。")
            }
            guard let seed = workflow.seedStrategy == .perNode ? UInt64(0) : UInt64(seedText) else { throw ComfyError.invalid("种子应为非负整数。") }
            var job = GenerationJob(server: server, workflow: workflow, values: workflow.lastValues)
            job.batch = batch
            job.randomSeed = randomSeed
            job.seed = seed
            job.loraEnabled = workflow.loraEnabled
            for spec in workflow.editableInputs where [.image, .video].contains(spec.kind) {
                guard let staged = draftUploads[spec.id] else { throw ComfyError.invalid("请先选择\(spec.label)。") }
                let name = job.id.uuidString + "_" + staged
                let destination = disk.uploadURL(name)
                try FileManager.default.copyItem(at: disk.uploadURL(staged), to: destination)
                copiedFiles.append(destination)
                job.uploads[spec.id] = name
                job.values[spec.id] = .string(name)
            }
            _ = try WorkflowBuilder.build(workflow: workflow, values: job.values, batch: job.batch, randomSeed: job.randomSeed, baseSeed: job.seed, loraEnabled: job.loraEnabled)
            saved.jobs.append(job)
            appendedID = job.id
            if clearPrompt, let spec = workflow.mainPrompt, let index = saved.workflows.firstIndex(where: { $0.id == workflow.id }) {
                clearedPrompt = (workflow.id, spec.id, saved.workflows[index].lastValues[spec.id])
                saved.workflows[index].lastValues[spec.id] = .string("")
            }
            try persist()
            start(job.id)
            return true
        } catch {
            if let id = appendedID { saved.jobs.removeAll { $0.id == id } }
            if let cleared = clearedPrompt, let index = saved.workflows.firstIndex(where: { $0.id == cleared.workflowID }) {
                saved.workflows[index].lastValues[cleared.specID] = cleared.value
            }
            for url in copiedFiles { try? FileManager.default.removeItem(at: url) }
            report(error)
            return false
        }
    }
    func updateJob(_ id: UUID, _ change: (inout GenerationJob) -> Void) throws {
        guard let index = saved.jobs.firstIndex(where: { $0.id == id }) else { throw ComfyError.invalid("本地任务不存在。") }
        let wasCancelled = saved.jobs[index].phase == .cancelled
        change(&saved.jobs[index])
        if wasCancelled { saved.jobs[index].phase = .cancelled }
        try persist()
    }
    func job(_ id: UUID) -> GenerationJob? { saved.jobs.first { $0.id == id } }
    func setBackground(_ asset: GalleryAsset) {
        guard asset.output.kind == .image, let name = asset.localName, let url = disk?.mediaURL(name), MediaImages.image(url: url, maxPixel: 80) != nil else {
            error = "iOS 无法把此格式设为背景，原文件仍可分享。"
            return
        }
        saved.backgroundAssetID = asset.id
        persistSoon()
        notice = "已设为聊天背景"
    }
    func removeAsset(_ asset: GalleryAsset) {
        guard let index = saved.assets.firstIndex(where: { $0.id == asset.id }) else { return }
        saved.assets[index].removed = true
        do {
            try persist()
            if let name = asset.localName, let disk = disk { try? FileManager.default.removeItem(at: disk.mediaURL(name)) }
            if saved.backgroundAssetID == asset.id { saved.backgroundAssetID = nil; persistSoon() }
        } catch { report(error) }
    }
    func saveNote(title: String, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saved.notes.insert(PromptNote(title: title.isEmpty ? String(text.prefix(24)) : title, text: text), at: 0)
        persistSoon()
        notice = "已存入提示词库"
    }
    func regenerate(_ asset: GalleryAsset) {
        guard let original = job(asset.jobID), asset.output.kind == .image else { return }
        var next = original
        next.id = UUID()
        next.createdAt = Date()
        next.prompts = []
        next.records = []
        next.uploads = [:]
        next.phase = .preparing
        next.message = ""
        next.batch = 1
        next.randomSeed = true
        if let queueID = next.workflow.graph.keys.first(where: { next.workflow.graph[$0]?["class_type"]?.string == "RayPromptQueue" }) {
            next.workflow.queueMode = .single
            next.values[queueID + "|prompts"] = .string(original.prompt(for: asset.promptID))
            next.values[queueID + "|first"] = .integer(1)
            next.values[queueID + "|last"] = .integer(0)
        }
        saved.jobs.append(next)
        do { try persist(); start(next.id); notice = "已按原工作流随机再生成一张" } catch { report(error) }
    }
}
