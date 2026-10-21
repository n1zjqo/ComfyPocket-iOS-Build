import Foundation
import ComfyCore

struct ServerProfile: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "我的 ComfyUI"
    var address = ""
    var username = ""
    var allowInterrupt: Bool? = false
}
enum JobPhase: String, Codable {
    case preparing, uploading, submitting, queued, running, downloading, waiting, attention, success, failed, cancelled
    var title: String {
        switch self {
        case .preparing: return "准备中"
        case .uploading: return "上传素材"
        case .submitting: return "提交任务"
        case .queued: return "排队中"
        case .running: return "生成中"
        case .downloading: return "保存作品"
        case .waiting: return "等待继续"
        case .attention: return "需要确认"
        case .success: return "已完成"
        case .failed: return "未完成"
        case .cancelled: return "已取消"
        }
    }
    var isTerminal: Bool { [.success, .failed, .cancelled, .attention].contains(self) }
}

struct PromptRecord: Codable, Equatable {
    var index: Int
    var promptID: String?
    var attempted = false
    var completed = false
    var failure: String?
    var missingSince: Date?
}

struct GenerationJob: Identifiable, Codable {
    var id = UUID()
    var server: ServerProfile
    var workflow: Workflow
    var values: [String: JSONValue]
    var prompts: [BuiltPrompt] = []
    var records: [PromptRecord] = []
    var uploads: [String: String] = [:]
    var phase: JobPhase = .preparing
    var createdAt = Date()
    var message = ""
    var step = 0
    var totalSteps = 0
    var batch = 1
    var randomSeed = true
    var seed: UInt64 = 1
    var loraEnabled: [String: Bool] = [:]
    var prompt: String {
        if let first = prompts.first?.promptText { return first }
        if let queue = try? RayQueue.selection(workflow: workflow, values: values) { return queue.prompts.first ?? workflow.name }
        guard let spec = workflow.mainPrompt else { return workflow.name }
        return (values[spec.id] ?? spec.defaultValue).text
    }
    var finishedCount: Int { records.filter(\.completed).count }
    var totalCount: Int {
        if !prompts.isEmpty { return prompts.count }
        return ((try? RayQueue.selection(workflow: workflow, values: values))?.prompts.count ?? 1) * batch
    }
    func prompt(for promptID: String) -> String {
        guard let record = records.first(where: { $0.promptID == promptID }) else { return prompt }
        return prompts.first { $0.index == record.index }?.promptText ?? prompt
    }
}

struct GalleryAsset: Identifiable, Codable {
    var id = UUID()
    var jobID: UUID
    var remoteKey: String
    var promptID: String
    var output: OutputDescriptor
    var seed: UInt64
    var localName: String?
    var removed = false
    var createdAt = Date()
}

struct PromptNote: Identifiable, Codable {
    var id = UUID()
    var title: String
    var text: String
}

struct SavedState: Codable {
    var schema = 1
    var servers: [ServerProfile] = []
    var selectedServerID: UUID?
    var workflows: [Workflow] = []
    var selectedWorkflowID: UUID?
    var jobs: [GenerationJob] = []
    var assets: [GalleryAsset] = []
    var notes: [PromptNote] = []
    var backgroundAssetID: UUID?
    var clientID = UUID().uuidString
    var backgroundDim = 0.38
}
