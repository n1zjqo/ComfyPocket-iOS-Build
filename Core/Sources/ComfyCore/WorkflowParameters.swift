import Foundation

public enum WorkflowSeedStrategy: String, Codable, CaseIterable {
    case synchronized, perNode
    public var title: String { self == .synchronized ? "统一种子" : "保留各节点种子" }
}

public struct WorkflowParameter: Identifiable, Equatable {
    public let spec: InputSpec
    public let rawValue: JSONValue
    public let schema: JSONValue?
    public let readOnlyReason: String?
    public var id: String { spec.id }
    public var options: [JSONValue] { schema?.array?.first?.array ?? [] }
    public var configuration: JSONValue? { schema?.array?.dropFirst().first }
    public var typeName: String { schema?.array?.first?.string ?? (options.isEmpty ? "未声明" : "选项") }
    public var connection: String? {
        guard rawValue.isLink, let values = rawValue.array else { return nil }
        return "节点 " + values[0].text + " · 输出 " + values[1].text
    }
}

public struct WorkflowParameterNode: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let classType: String
    public let fields: [WorkflowParameter]
    public let outputs: [String]
    public let hasServerSchema: Bool
}

public enum WorkflowParameters {
    private static let localClasses: Set<String> = ["KSampler", "KSamplerAdvanced", "CLIPTextEncode", "CLIPTextEncodeSDXL", "CLIPTextEncodeFlux", "PrimitiveInt", "PrimitiveFloat", "PrimitiveString", "EmptyLatentImage", "EmptySD3LatentImage", "LoadImage", "LoadVideo", "SaveImage", "RayPromptQueue"]

    public static func nodes(_ workflow: Workflow) -> [WorkflowParameterNode] {
        workflow.orderedNodeIDs.compactMap { identifier in
            guard let node = workflow.graph[identifier], let classType = node["class_type"]?.string, let inputs = node["inputs"]?.object else { return nil }
            let schema = workflow.nodeSchemas?[classType]
            let fields = inputs.keys.sorted().map { name -> WorkflowParameter in
                let raw = inputs[name] ?? .null
                let slot = schema?["input"]?["required"]?[name] ?? schema?["input"]?["optional"]?[name]
                var spec = workflow.editableInputs.first { $0.nodeID == identifier && $0.field == name }
                    ?? InputSpec(nodeID: identifier, field: name, label: name, kind: .text, defaultValue: raw, classType: classType, choices: [])
                let type = slot?.array?.first?.string
                let options = slot?.array?.first?.array ?? []
                if type == "INT", spec.kind != .seed && spec.kind != .width && spec.kind != .height { spec.kind = .integer }
                if type == "FLOAT" { spec.kind = .decimal }
                if type == "BOOLEAN" { spec.kind = .boolean }
                if type == "STRING", slot?.array?.dropFirst().first?["multiline"]?.bool == true { spec.kind = .prompt }
                if !options.isEmpty { spec.choices = options.map { $0.text }; if spec.kind != .model { spec.kind = .choice } }
                let reason: String?
                if raw.isLink { reason = "输入来自连线；本阶段不修改拓扑。" }
                else if raw.object != nil || raw.array != nil || raw == .null { reason = "结构化或空值输入，原样保留；暂无安全的编辑器。" }
                else if name == "batch_size", inputs["width"] != nil && inputs["height"] != nil { reason = "由手机的生成份数拆成独立任务，每个任务 batch_size 为 1。" }
                else if classType == "RayPromptQueue", name == "seed_mode" { reason = "由手机端统一种子策略控制；原始字段保留。" }
                else if slot?.array?.dropFirst().first?["forceInput"]?.bool == true { reason = "服务器要求连接输入，不支持改成手填值。" }
                else if slot != nil {
                    let scalarOptions = !options.isEmpty && options.allSatisfy { $0.object == nil && $0.array == nil && $0 != .null } && Set(options.map { $0.text }).count == options.count
                    reason = ["INT", "FLOAT", "BOOLEAN", "STRING"].contains(type ?? "") || scalarOptions ? nil : "服务器字段类型「\(type ?? "未知")」暂不支持编辑。"
                } else if workflow.nodeSchemas != nil && classType != "RayPromptQueue" { reason = "服务器未提供该字段描述；原样保留。请检查自定义节点或刷新能力。" }
                else if !localClasses.contains(classType) { reason = "尚无服务器描述；未知节点保留只读，连接后刷新能力。" }
                else { reason = nil }
                return WorkflowParameter(spec: spec, rawValue: raw, schema: slot, readOnlyReason: reason)
            }
            let outputTypes = schema?["output"]?.array ?? []
            let outputNames = schema?["output_name"]?.array ?? []
            let outputs = outputTypes.enumerated().map { position, type in
                let name = position < outputNames.count ? outputNames[position].text : type.text
                return "\(position) · \(name)（\(type.text)）"
            }
            return WorkflowParameterNode(id: identifier, title: node["_meta"]?["title"]?.string ?? schema?["display_name"]?.string ?? classType, classType: classType, fields: fields, outputs: outputs, hasServerSchema: schema != nil)
        }
    }

    public static func normalized(_ value: JSONValue, parameter: WorkflowParameter) throws -> JSONValue {
        let spec = parameter.spec
        func invalid(_ message: String) -> ComfyError { .invalid("节点 \(spec.nodeID) · \(spec.field)：" + message) }
        if let reason = parameter.readOnlyReason {
            guard value == parameter.rawValue else { throw invalid(reason) }
            return parameter.rawValue
        }
        if !parameter.options.isEmpty {
            guard let option = parameter.options.first(where: { $0.text == value.text }) else { throw invalid("请选择服务器提供的选项；列表可能需要刷新。") }
            return option
        }
        let result: JSONValue
        let serverType = parameter.schema?.array?.first?.string
        if serverType == "INT" || [.integer, .seed, .width, .height].contains(spec.kind) {
            if let number = Int64(value.text) { result = .integer(number) }
            else if let number = UInt64(value.text) { result = .unsigned(number) }
            else { throw invalid("请输入有效整数；种子不能经过浮点数转换。") }
            if spec.kind == .seed && value.text.hasPrefix("-") { throw invalid("种子不能为负数。") }
        } else if serverType == "FLOAT" || spec.kind == .decimal {
            guard let number = Double(value.text), number.isFinite else { throw invalid("请输入有限数值。") }
            result = .decimal(number)
        } else if serverType == "BOOLEAN" || spec.kind == .boolean {
            guard let enabled = value.bool else { throw invalid("开关值无效。") }
            result = .bool(enabled)
        } else {
            guard value.string != nil else { throw invalid("应为文字。") }
            result = value
        }
        if parameter.schema == nil && [.width, .height].contains(spec.kind) {
            guard let size = Int64(result.text), (64...8192).contains(size) else { throw invalid("未取得服务器尺寸约束，兼容范围为 64–8192。") }
            return .integer(size / 16 * 16)
        }
        if result.double != nil {
            let locale = Locale(identifier: "en_US_POSIX")
            guard let number = Decimal(string: result.text, locale: locale), !number.isNaN else { throw invalid("数值无法表示。") }
            for (key, below) in [("min", true), ("max", false)] {
                if let bound = parameter.configuration?[key], let limit = Decimal(string: bound.text, locale: locale), (below ? number < limit : number > limit) { throw invalid("\(key == "min" ? "最小" : "最大")值为 \(bound.text)。") }
            }
        }
        return result
    }

    public static func validatedValues(workflow: Workflow, values: [String: JSONValue]) throws -> [String: JSONValue] {
        var result = values
        for node in nodes(workflow) {
            for parameter in node.fields where parameter.rawValue.isLink {
                guard let connection = parameter.rawValue.array, let sourceID = connection[0].string, let port = Int(connection[1].text), let source = workflow.graph[sourceID] else { throw ComfyError.invalid("节点 \(node.id) 的 \(parameter.spec.field) 连线源不存在。") }
                if let classType = source["class_type"]?.string, let outputs = workflow.nodeSchemas?[classType]?["output"]?.array, port >= outputs.count { throw ComfyError.invalid("节点 \(node.id) 的 \(parameter.spec.field) 引用了不存在的输出端口。") }
            }
            for parameter in node.fields where parameter.readOnlyReason == nil || values[parameter.id] != nil {
                result[parameter.id] = try normalized(values[parameter.id] ?? parameter.rawValue, parameter: parameter)
            }
        }
        return result
    }
}

public struct WorkflowParameterDraft: Equatable {
    public let source: Workflow
    public var workflow: Workflow
    public var values: [String: JSONValue]
    public init(workflow: Workflow) {
        source = workflow
        self.workflow = workflow
        values = workflow.lastValues
    }
    public mutating func refresh(objectInfo: JSONValue, serverID: UUID, serverAddress: String? = nil) {
        workflow = WorkflowImporter.applyChoices(workflow, objectInfo: objectInfo, serverID: serverID, serverAddress: serverAddress)
    }
    public func applied(to current: Workflow) throws -> Workflow {
        guard current == source else { throw ComfyError.invalid("工作流已在别处更新，请取消后重新打开，避免覆盖新值。") }
        var result = workflow
        result.lastValues = try WorkflowParameters.validatedValues(workflow: workflow, values: values)
        return result
    }
}

