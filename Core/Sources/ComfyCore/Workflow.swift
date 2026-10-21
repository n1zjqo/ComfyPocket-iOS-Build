import Foundation

public enum InputKind: String, Codable, CaseIterable {
    case prompt, text, integer, decimal, boolean, choice, model, image, video, seed, width, height
}
public struct InputSpec: Identifiable, Codable, Equatable {
    public var nodeID: String
    public var field: String
    public var label: String
    public var kind: InputKind
    public var defaultValue: JSONValue
    public var classType: String
    public var choices: [String]
    public var id: String { nodeID + "|" + field }
    public var isMain: Bool { [.prompt, .image, .video, .seed, .width, .height].contains(kind) }
}

public struct Workflow: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var graph: [String: JSONValue]
    public var inputs: [InputSpec]
    public var createdAt: Date
    public var lastValues: [String: JSONValue]
    public var loraEnabled: [String: Bool]
    public var applicationFields: [String: ApplicationField]?
    public var mainPromptID: String?
    public var queueMode: QueueExecutionMode?
    public var nodeSchemas: [String: JSONValue]?
    public var schemaServerID: UUID?
    public var schemaServerAddress: String?
    public var seedStrategy: WorkflowSeedStrategy?
    public var outputLabel: String {
        let classes = graph.values.compactMap { $0["class_type"]?.string?.lowercased() }
        if classes.contains(where: { $0.contains("videocombine") || $0.contains("savevideo") || $0.contains("savewebm") }) { return "视频" }
        if classes.contains(where: { $0.contains("showtext") || $0.contains("showanything") || $0 == "previewany" }) { return "文本" }
        return "图片"
    }
    public var loraNodes: [(id: String, title: String)] {
        graph.keys.sorted().compactMap { nodeID in
            guard let node = graph[nodeID], let classType = node["class_type"]?.string,
                  classType.lowercased().contains("lora"), let inputs = node["inputs"]?.object,
                  inputs.contains(where: { $0.key.lowercased().contains("strength") && $0.value.double != nil }) else { return nil }
            return (nodeID, node["_meta"]?["title"]?.string ?? classType)
        }
    }
}

public enum WorkflowImporter {
    public static func parse(_ data: Data, name: String) throws -> Workflow {
        guard data.count <= 20 * 1024 * 1024 else { throw ComfyError.invalid("工作流超过 20 MB，请缩小文件后导入。") }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard var graph = value.object else { throw ComfyError.invalid("请选择 API 格式 JSON 工作流。") }
        if graph["nodes"] != nil && graph["links"] != nil { throw ComfyError.invalid("这是编辑器格式。请在 ComfyUI 中选择 Export (API) 后重新导入。") }
        if let wrapped = graph["prompt"]?.object { graph = wrapped }
        guard !graph.isEmpty, graph.values.allSatisfy({ $0["class_type"]?.string != nil && $0["inputs"]?.object != nil }) else {
            throw ComfyError.invalid("文件不是完整的 ComfyUI API 节点图。")
        }
        var specs: [InputSpec] = []
        let negativeNodes = conditioningAncestors(graph, field: "negative")
        let promptSources = scalarSources(graph, fields: ["text", "positive_prompt", "negative_prompt"], classes: ["CLIPTextEncode", "CLIPTextEncodeSDXL", "CLIPTextEncodeFlux"])
        let widthSources = scalarSources(graph, fields: ["width"])
        let heightSources = scalarSources(graph, fields: ["height"])
        let modelFields = Set(["ckpt_name", "unet_name", "clip_name", "clip_name1", "clip_name2", "clip_name3", "vae_name", "lora_name", "model_name"])
        let decimalFields = Set(["cfg", "denoise", "shift", "strength", "strength_model", "strength_clip"])
        for nodeID in graph.keys.sorted(by: numericOrder) {
            guard let node = graph[nodeID], let classType = node["class_type"]?.string, let inputs = node["inputs"]?.object else { continue }
            let base = classType.components(separatedBy: "|")[0]
            let title = node["_meta"]?["title"]?.string ?? base
            for field in inputs.keys.sorted() {
                if field == "batch_size", inputs["width"] != nil, inputs["height"] != nil { continue }
                guard let value = inputs[field], !value.isLink, value.object == nil, value.array == nil, value != .null else { continue }
                var kind: InputKind
                var label = field
                if base == "LoadImage" && field == "image" { kind = .image; label = "参考图片" }
                else if (["VHS_LoadVideo", "VHS_LoadVideoFFmpeg"].contains(base) && field == "video") || (base == "LoadVideo" && field == "file") { kind = .video; label = "参考视频" }
                else if ["seed", "noise_seed"].contains(field) || (base == "RayPromptQueue" && field == "base_seed") { kind = .seed; label = "种子" }
                else if (field == "width" || (field == "value" && widthSources.contains(nodeID))) && value.double != nil { kind = .width; label = "宽度" }
                else if (field == "height" || (field == "value" && heightSources.contains(nodeID))) && value.double != nil { kind = .height; label = "高度" }
                else if (base == "RayPromptQueue" && field == "prompts") || (promptSources.contains(nodeID) && ["text", "value", "string", "prompt"].contains(field) && value.string != nil) {
                    kind = .prompt
                    label = negativeNodes.contains(nodeID) && !(base == "RayPromptQueue") ? "负向提示词" : "提示词"
                }
                else if (base.lowercased().contains("textencode") && ["text", "prompt", "negative_prompt"].contains(field)) || field == "positive_prompt" {
                    kind = .prompt
                    label = negativeNodes.contains(nodeID) || title.lowercased().contains("negative") || title.contains("负向") || title.contains("负面") || field == "negative_prompt" ? "负向提示词" : "提示词"
                }
                else if modelFields.contains(field) && value.string != nil { kind = .model; label = "模型" }
                else if value.bool != nil { kind = .boolean }
                else if value.double != nil {
                    kind = decimalFields.contains(field) || field.lowercased().contains("strength") ? .decimal : (JSONValue.integer(0).sameNumberKind(as: value) ? .integer : .decimal)
                    label = ["steps": "步数", "cfg": "引导强度", "denoise": "重绘强度", "length": "帧数", "frame_rate": "帧率" ][field] ?? field
                }
                else if value.string != nil {
                    kind = .text
                }
                else { continue }
                if ![.prompt, .image, .video, .seed, .width, .height].contains(kind) { label += " · " + title }
                specs.append(InputSpec(nodeID: nodeID, field: field, label: label, kind: kind, defaultValue: value, classType: classType, choices: []))
            }
        }
        guard specs.filter({ $0.kind == .image }).count <= 1, specs.filter({ $0.kind == .video }).count <= 1 else {
            throw ComfyError.invalid("当前版本支持一个参考图槽和一个参考视频槽。请先在电脑端合并或移除多余素材输入。")
        }
        return Workflow(id: UUID(), name: name.replacingOccurrences(of: ".json", with: ""), graph: graph, inputs: specs, createdAt: Date(), lastValues: [:], loraEnabled: [:])
    }

    public static func reanalyze(_ workflow: Workflow) throws -> Workflow {
        let imported = try parse(JSONValue.object(workflow.graph).encoded(), name: workflow.name)
        var updated = workflow
        updated.inputs = imported.inputs.map { input in
            var spec = input
            spec.choices = workflow.inputs.first { $0.id == input.id }?.choices ?? []
            if spec.kind == .text && !spec.choices.isEmpty { spec.kind = .choice }
            return spec
        }
        return updated
    }

    private static func scalarSources(_ graph: [String: JSONValue], fields: Set<String>, classes: Set<String>? = nil) -> Set<String> {
        var sources = Set<String>()
        for node in graph.values {
            if let classes = classes, !classes.contains(node["class_type"]?.string ?? "") { continue }
            for (field, input) in node["inputs"]?.object ?? [:] where fields.contains(field) && input.isLink {
                if let source = input.array?.first?.string { sources.insert(source) }
            }
        }
        return sources
    }

    public static func applyChoices(_ workflow: Workflow, objectInfo: JSONValue, serverID: UUID? = nil, serverAddress: String? = nil) -> Workflow {
        var result = workflow
        let classes = Set(workflow.graph.values.compactMap { $0["class_type"]?.string })
        result.nodeSchemas = objectInfo.object?.filter { classes.contains($0.key) } ?? [:]
        result.schemaServerID = serverID
        result.schemaServerAddress = serverAddress
        for index in result.inputs.indices {
            let spec = result.inputs[index]
            let node = objectInfo[spec.classType]
            let slot = node?["input"]?["required"]?[spec.field] ?? node?["input"]?["optional"]?[spec.field]
            guard let choices = slot?.array?.first?.array?.compactMap(\.string), !choices.isEmpty else { continue }
            result.inputs[index].choices = choices
            if spec.kind == .text { result.inputs[index].kind = .choice }
        }
        return result
    }

    private static func conditioningAncestors(_ graph: [String: JSONValue], field: String) -> Set<String> {
        var pending = graph.values.compactMap { $0["inputs"]?[field]?.array?.first?.string }
        var visited = Set<String>()
        while let nodeID = pending.popLast() {
            guard visited.insert(nodeID).inserted, let inputs = graph[nodeID]?["inputs"]?.object else { continue }
            pending.append(contentsOf: inputs.values.filter(\.isLink).compactMap { $0.array?.first?.string })
        }
        return visited
    }

    private static func numericOrder(_ left: String, _ right: String) -> Bool {
        if let leftNumber = Int(left), let rightNumber = Int(right) { return leftNumber < rightNumber }
        return left < right
    }
}

private extension JSONValue {
    func sameNumberKind(as other: JSONValue) -> Bool {
        switch other { case .integer, .unsigned: return true; default: return false }
    }
}
