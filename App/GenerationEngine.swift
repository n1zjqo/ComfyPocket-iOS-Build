import Foundation
import UIKit
import ComfyCore

@MainActor
extension AppState {
    func start(_ id: UUID) {
        guard tasks[id] == nil, let current = job(id), ![.cancelled, .success].contains(current.phase) else { return }
        tasks[id] = Task { [weak self] in
            guard let self = self else { return }
            await self.run(id)
            self.tasks[id] = nil
            self.endBackgroundIfIdle()
            if self.pendingResumes.remove(id) != nil, UIApplication.shared.applicationState == .active { self.start(id) }
        }
    }
    func resumeAll() {
        for job in saved.jobs where !job.phase.isTerminal {
            if tasks[job.id]?.isCancelled == true { pendingResumes.insert(job.id) }
            else { start(job.id) }
        }
    }
    func resume(_ id: UUID) {
        guard let current = job(id), ![.cancelled, .success].contains(current.phase) else { return }
        do {
            try updateJob(id) { $0.phase = .waiting; $0.message = "" }
            if tasks[id] != nil { pendingResumes.insert(id) } else { start(id) }
        } catch { report(error) }
    }
    func enteredBackground() {
        saveTask?.cancel()
        do { try persist() } catch { report(error) }
        guard !tasks.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ComfyPocketSave") { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                for task in self.tasks.values { task.cancel() }
                if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
            }
        }
    }
    func enteredForeground() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        resumeAll()
    }
    func endBackgroundIfIdle() {
        if tasks.values.allSatisfy({ $0.isCancelled }) || tasks.isEmpty {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
        }
    }
    func cancel(_ id: UUID) {
        guard let snapshot = job(id), ![.cancelled, .success].contains(snapshot.phase) else { return }
        do { try updateJob(id) { $0.phase = .cancelled; $0.message = snapshot.server.allowInterrupt == true ? "已在手机停止；服务器撤销为尽力操作。" : "已停止手机查询并尝试移除排队项。未开启定向中断，正在运行的服务器任务可能继续。" } }
        catch { report(error); return }
        tasks[id]?.cancel()
        Task {
            do {
                let client = try ComfyClient(server: snapshot.server)
                defer { client.close() }
                let queue = try await client.json("queue")
                let entries = QueueParser.entries(queue).filter {
                    snapshot.records.compactMap(\.promptID).contains($0.promptID) || $0.extra["comfy_pocket_job"]?.string == id.uuidString
                }
                let ids = entries.map { JSONValue.string($0.promptID) }
if !ids.isEmpty { try await client.command("queue", body: .object(["delete": .array(ids)])) }
                if snapshot.server.allowInterrupt == true, let running = entries.first(where: \.running) {
try await client.command("interrupt", body: .object(["prompt_id": .string(running.promptID)]))
                }
            } catch {
                try? updateJob(id) { $0.message = "手机已停止，但未能确认服务器撤销。请在电脑检查队列。" }
            }
        }
    }

    private func run(_ id: UUID) async {
        var progressTask: Task<Void, Never>?
        var client: ComfyClient?
        defer { progressTask?.cancel(); client?.close() }
        do {
            guard let disk = disk, let original = job(id), original.phase != .cancelled else { return }
            let api = try ComfyClient(server: original.server)
            client = api
            let clientID = saved.clientID + ":" + id.uuidString
            progressTask = Task { await self.watchProgress(id: id, client: api, clientID: clientID) }
            for (specID, name) in original.uploads.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                try updateJob(id) { $0.phase = .uploading; $0.message = "" }
                let source = disk.uploadURL(name)
                guard FileManager.default.fileExists(atPath: source.path) else { throw ComfyError.invalid("暂存素材已不存在，请重新选择并生成。") }
                let video = original.workflow.inputs.first(where: { $0.id == specID })?.kind == .video
                let ext = source.pathExtension.lowercased()
                let mime = video ? (["mov": "video/quicktime", "webm": "video/webm"][ext] ?? "video/mp4") : (["png": "image/png", "heic": "image/heic", "webp": "image/webp"][ext] ?? "image/jpeg")
                let remote = try await api.upload(file: source, mime: mime, directory: disk.uploads)
                try updateJob(id) { $0.values[specID] = .string(remote); $0.uploads.removeValue(forKey: specID) }
                try? FileManager.default.removeItem(at: source)
            }
            guard var snapshot = job(id) else { return }
            if snapshot.prompts.isEmpty {
                let prompts = try WorkflowBuilder.build(workflow: snapshot.workflow, values: snapshot.values, batch: snapshot.batch, randomSeed: snapshot.randomSeed, baseSeed: snapshot.seed, loraEnabled: snapshot.loraEnabled)
                try updateJob(id) { $0.prompts = prompts; $0.records = prompts.map { PromptRecord(index: $0.index) } }
                guard let refreshed = job(id) else { return }
                snapshot = refreshed
            }
            for prompt in snapshot.prompts {
                try Task.checkCancellation()
                guard let current = job(id), let position = current.records.firstIndex(where: { $0.index == prompt.index }) else { return }
                let record = current.records[position]
                if record.promptID != nil { continue }
                if record.attempted {
                    let queue = try await api.json("queue")
                    let history = try await api.json("history", query: [URLQueryItem(name: "max_items", value: "200")])
                    if let recovered = QueueParser.recover(jobID: id.uuidString, index: prompt.index, queue: queue, history: history) {
                        try updateJob(id) { $0.records[position].promptID = recovered }
                        continue
                    }
                    throw ComfyError.uncertainSubmission
                }
                try updateJob(id) { $0.phase = .submitting; $0.records[position].attempted = true }
                let payload = JSONValue.object([
                    "prompt": prompt.graph,
                    "client_id": .string(clientID),
                    "extra_data": .object(["comfy_pocket_job": .string(id.uuidString), "comfy_pocket_index": .integer(Int64(prompt.index))])
                ])
                let response: JSONValue
                do { response = try await api.json("prompt", method: "POST", body: payload) }
                catch let error as ComfyError {
                    if case .server(let status, _) = error, (400..<500).contains(status) {
                        try updateJob(id) { $0.records[position].attempted = false }
                    }
                    throw error
                }
                guard let promptID = response["prompt_id"]?.string, !promptID.isEmpty else { throw ComfyError.uncertainSubmission }
                try updateJob(id) { $0.records[position].promptID = promptID; $0.phase = .queued }
            }
            let deadline = Date().addingTimeInterval(2 * 60 * 60)
            while Date() < deadline {
                try Task.checkCancellation()
                guard let snapshot = job(id), snapshot.phase != .cancelled else { return }
                let queue = try await api.json("queue")
                let entries = QueueParser.entries(queue)
                var running = false
                for (position, record) in snapshot.records.enumerated() where !record.completed && record.failure == nil {
                    guard let promptID = record.promptID else { throw ComfyError.uncertainSubmission }
                    let history = try await api.json("history/" + promptID)
                    if let details = history[promptID] {
                        let status = details["status"]
                        if status?["status_str"]?.string == "error" {
                            let detail = Self.executionError(status?["messages"])
                            try updateJob(id) { $0.records[position].failure = detail }
                        } else if status?["completed"]?.bool == true {
                            try updateJob(id) { $0.phase = .downloading }
                            let outputs = OutputParser.parse(promptID: promptID, outputs: details["outputs"] ?? .object([:]))
                            let seed = snapshot.prompts.first { $0.index == record.index }?.seed ?? 0
                            for output in outputs { try await saveOutput(output, id: id, promptID: promptID, seed: seed, client: api) }
                            try updateJob(id) { $0.records[position].completed = true; $0.records[position].missingSince = nil }
                        }
                    } else if let entry = entries.first(where: { $0.promptID == promptID }) {
                        running = running || entry.running
                        if record.missingSince != nil { try updateJob(id) { $0.records[position].missingSince = nil } }
                    } else {
                        if let missing = record.missingSince, Date().timeIntervalSince(missing) > 60 {
                            throw ComfyError.invalid("任务不在服务器队列或历史中，可能已被清理。请检查电脑后再决定是否重新生成。")
                        }
                        if record.missingSince == nil { try updateJob(id) { $0.records[position].missingSince = Date() } }
                    }
                }
                guard let current = job(id) else { return }
                if current.records.allSatisfy({ $0.completed || $0.failure != nil }) {
                    let failures = current.records.compactMap(\.failure)
                    try updateJob(id) {
                        $0.phase = failures.isEmpty ? .success : .failed
                        $0.message = failures.isEmpty ? "" : "\($0.finishedCount)/\($0.records.count) 条完成。" + (failures.first ?? "")
                    }
                    return
                }
                let phase: JobPhase = running ? .running : .queued
                if current.phase != phase || !current.message.isEmpty { try updateJob(id) { $0.phase = phase; $0.message = "" } }
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
            try updateJob(id) { $0.phase = .waiting; $0.message = "已检查两小时。服务器任务未被取消，可稍后继续查询。" }
        } catch is CancellationError {
            if job(id)?.phase != .cancelled { try? updateJob(id) { $0.phase = .waiting; $0.message = "手机已暂停检查，服务器可以继续生成。回到前台后继续。" } }
        } catch {
            if job(id)?.phase == .cancelled { return }
            if Task.isCancelled {
                try? updateJob(id) { $0.phase = .waiting; $0.message = "手机已暂停检查，服务器可以继续生成。回到前台后继续。" }
                return
            }
            let attention: Bool
            if case ComfyError.uncertainSubmission = error { attention = true } else { attention = false }
            try? updateJob(id) { $0.phase = attention ? .attention : .waiting; $0.message = error.localizedDescription }
        }
    }

    private func watchProgress(id: UUID, client: ComfyClient, clientID: String) async {
        while !Task.isCancelled {
            do {
                let socket = try client.progressSocket(clientID: clientID)
                defer { socket.cancel(with: .normalClosure, reason: nil) }
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case .string(let text) = message, let data = text.data(using: .utf8), let event = try? JSONDecoder().decode(JSONValue.self, from: data), event["type"]?.string == "progress", let details = event["data"],
                          let index = saved.jobs.firstIndex(where: { $0.id == id }), !saved.jobs[index].phase.isTerminal else { continue }
                    let promptID = details["prompt_id"]?.string
                    if let promptID = promptID, !saved.jobs[index].records.compactMap(\.promptID).contains(promptID) { continue }
                    let step = details["value"]?.double ?? 0
                    let total = details["max"]?.double ?? 0
                    guard step.isFinite, total.isFinite else { continue }
                    saved.jobs[index].step = Int(min(max(step, 0), 10_000_000))
                    saved.jobs[index].totalSteps = Int(min(max(total, 0), 10_000_000))
                }
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func saveOutput(_ output: OutputDescriptor, id: UUID, promptID: String, seed: UInt64, client: ComfyClient) async throws {
        try Task.checkCancellation()
        guard let disk = disk else { throw ComfyError.invalid("本地存储不可用。") }
        var asset: GalleryAsset
        if let existing = saved.assets.first(where: { $0.remoteKey == output.id && $0.jobID == id }) {
            if existing.removed { return }
            if output.kind == .text { return }
            if let name = existing.localName, FileManager.default.fileExists(atPath: disk.mediaURL(name).path) { return }
            asset = existing
        } else {
            asset = GalleryAsset(jobID: id, remoteKey: output.id, promptID: promptID, output: output, seed: seed)
            saved.assets.append(asset)
            try persist()
        }
        if output.kind == .text { return }
        let ext = (output.filename as NSString).pathExtension.lowercased()
        let safeExtensions = ["png", "jpg", "jpeg", "webp", "heic", "gif", "avif", "apng", "tiff", "tif", "bmp", "mp4", "webm", "mov", "mkv", "m4v"]
        let name = asset.id.uuidString + "." + (safeExtensions.contains(ext) ? ext : "bin")
        let destination = disk.mediaURL(name)
        try await client.download(output, destination: destination)
        let canPreview = output.kind == .image && MediaImages.image(url: destination, maxPixel: 80) != nil
        if Task.isCancelled || job(id)?.phase == .cancelled {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        }
        guard let index = saved.assets.firstIndex(where: { $0.id == asset.id }), !saved.assets[index].removed else {
            try? FileManager.default.removeItem(at: destination)
            return
        }
        saved.assets[index].localName = name
        if canPreview { saved.backgroundAssetID = asset.id }
        try persist()
    }

    private static func executionError(_ messages: JSONValue?) -> String {
        for message in messages?.array ?? [] {
            guard let pair = message.array, pair.count > 1 else { continue }
            if let text = pair[1]["exception_message"]?.string { return text }
        }
        return "服务器执行失败，请检查模型、节点及电脑日志。"
    }
}
