import Foundation

public struct ApplicationField: Codable, Equatable {
    public var title: String
    public var group: String
    public var help: String
    public var featured: Bool
    public var order: Int
    public var kind: InputKind?

    public init(title: String, group: String, help: String = "", featured: Bool = true, order: Int = 0, kind: InputKind? = nil) {
        self.title = title
        self.group = group
        self.help = help
        self.featured = featured
        self.order = order
        self.kind = kind
    }
}

public enum QueueExecutionMode: String, Codable, CaseIterable {
    case single, all
    public var title: String { self == .single ? "先试一条" : "执行选中范围" }
}

public extension Workflow {
    var editableInputs: [InputSpec] {
        inputs.map { input in
            var spec = input
            if let kind = applicationFields?[input.id]?.kind { spec.kind = kind }
            return spec
        }
    }

    var mainPrompt: InputSpec? {
        if let identifier = mainPromptID, let spec = editableInputs.first(where: { $0.id == identifier && [.prompt, .text].contains($0.kind) }) { return spec }
        return editableInputs.first { $0.kind == .prompt && $0.label != "负向提示词" }
    }

    var hasRayQueue: Bool { graph.values.contains { $0["class_type"]?.string == "RayPromptQueue" } }

    func applicationField(_ spec: InputSpec) -> ApplicationField {
        if let configured = applicationFields?[spec.id] { return configured }
        let title = graph[spec.nodeID]?["_meta"]?["title"]?.string ?? spec.classType
        let position = inputs.firstIndex { $0.id == spec.id } ?? 0
        var group = title
        var name = spec.label.components(separatedBy: " · ").first ?? spec.label
        var featured = false
        if [.prompt, .image, .video].contains(spec.kind) { group = "提示词与素材"; featured = true }
        else if [.width, .height].contains(spec.kind) { group = "输出尺寸"; featured = true }
        else if spec.classType == "RayPromptQueue" {
            group = "提示词队列"
            name = ["first": "起始条目（从 1 开始）", "last": "结束条目（0 表示末条）", "format": "分隔格式", "output_folder": "输出目录", "seed_mode": "原节点种子模式"][spec.field] ?? name
            featured = ["first", "last", "output_folder"].contains(spec.field)
        } else if spec.classType.lowercased().contains("sampler") {
            featured = ["steps", "cfg", "denoise", "sampler_name", "scheduler", "start_at_step", "end_at_step"].contains(spec.field)
            name = ["sampler_name": "采样器", "scheduler": "调度器", "start_at_step": "开始步数", "end_at_step": "结束步数", "add_noise": "添加噪声", "return_with_leftover_noise": "保留剩余噪声"][spec.field] ?? name
        } else if spec.kind == .model { group = "模型与编码器" }
        if spec.classType == "PrimitiveInt" && [.width, .height].contains(spec.kind) { name = spec.kind == .width ? "最终宽度" : "最终高度" }
        let priority = group == "提示词与素材" ? -3000 : group == "输出尺寸" ? -2000 : group == "提示词队列" ? -1000 : 0
        return ApplicationField(title: name, group: group, featured: featured, order: priority + position)
    }

    var applicationInputs: [InputSpec] {
        editableInputs.sorted {
            let left = applicationField($0).order
            let right = applicationField($1).order
            return left == right ? $0.id < $1.id : left < right
        }
    }

    var orderedNodeIDs: [String] {
        var remaining = Set(graph.keys)
        var ordered: [String] = []
        while !remaining.isEmpty {
            let ready = remaining.filter { identifier in
                let dependencies = graph[identifier]?["inputs"]?.object?.values.filter(\.isLink).compactMap { $0.array?.first?.string } ?? []
                return dependencies.allSatisfy { !remaining.contains($0) }
            }.sorted { (Int($0) ?? Int.max, $0) < (Int($1) ?? Int.max, $1) }
            if ready.isEmpty { ordered += remaining.sorted(); break }
            ordered += ready
            remaining.subtract(ready)
        }
        return ordered
    }
}
