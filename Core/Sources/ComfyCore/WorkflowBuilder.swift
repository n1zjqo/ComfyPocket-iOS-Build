import Foundation

public struct BuiltPrompt: Codable, Equatable {
    public var index: Int
    public var seed: UInt64
    public var graph: JSONValue
    public var promptText: String?
}
public enum WorkflowBuilder {
    public static func build(workflow: Workflow, values: [String: JSONValue], batch: Int, randomSeed: Bool, baseSeed: UInt64, loraEnabled: [String: Bool]) throws -> [BuiltPrompt] {
        guard (1...8).contains(batch) else { throw ComfyError.invalid("一次生成数量应为 1–8。") }
        let resolved = try WorkflowParameters.validatedValues(workflow: workflow, values: values)
        let parameters = WorkflowParameters.nodes(workflow).flatMap { $0.fields }
        let descriptors = Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0) })
        let queue = try RayQueue.selection(workflow: workflow, values: resolved)
        if workflow.seedStrategy == .perNode && queue != nil { throw ComfyError.invalid("Ray 队列需要统一种子；请切换策略后应用。") }
        if workflow.schemaServerID != nil, let schemas = workflow.nodeSchemas {
            let missing = Set(workflow.graph.values.compactMap { $0["class_type"]?.string }).filter { schemas[$0] == nil && $0 != "RayPromptQueue" }
            guard missing.isEmpty else { throw ComfyError.invalid("服务器缺少节点：" + missing.sorted().joined(separator: "、")) }
        }
        let seedFields = parameters.filter { $0.spec.kind == .seed && $0.readOnlyReason == nil }
        let minimum = seedFields.compactMap { $0.configuration?["min"].flatMap { UInt64($0.text) } }.max() ?? 0
        let maximum = min(seedFields.compactMap { $0.configuration?["max"].flatMap { UInt64($0.text) } }.min() ?? 9_007_199_254_740_991, 9_007_199_254_740_991)
        guard workflow.seedStrategy == .perNode || !randomSeed || minimum <= maximum else { throw ComfyError.invalid("各采样器种子范围没有交集，请改为保留各节点种子。") }
        let total = batch * (queue?.prompts.count ?? 1)
        guard total <= RayQueue.maximumTasks else { throw ComfyError.invalid("本次将提交 \(total) 个独立任务，超过手机端 64 个上限。请缩小队列范围或每条份数。") }
        var result: [BuiltPrompt] = []
        for index in 0..<total {
            let addition = baseSeed.addingReportingOverflow(UInt64(index))
            if workflow.seedStrategy != .perNode && !randomSeed && addition.overflow { throw ComfyError.invalid("种子过大，增加批次会溢出。请减小种子。") }
            var seed = workflow.seedStrategy != .perNode && randomSeed ? UInt64.random(in: minimum...maximum) : addition.partialValue
            var graph = workflow.graph
            for imported in workflow.editableInputs {
                guard let parameter = descriptors[imported.id], parameter.readOnlyReason == nil else { continue }
                let spec = parameter.spec
                guard var node = graph[spec.nodeID]?.object, var inputs = node["inputs"]?.object,
                      let original = inputs[spec.field], !original.isLink else { throw ComfyError.invalid("工作流参数 \(spec.label) 已变化，请重新导入。") }
                var value = resolved[spec.id] ?? spec.defaultValue
                switch spec.kind {
                case .seed:
                    if workflow.seedStrategy == .perNode {
                        guard let original = UInt64(value.text) else { throw ComfyError.invalid("节点 \(spec.nodeID) 种子无效。") }
                        let increment = original.addingReportingOverflow(UInt64(index))
                        guard !increment.overflow else { throw ComfyError.invalid("节点 \(spec.nodeID) 种子随批次增加后溢出。") }
                        value = .unsigned(increment.partialValue)
                        if imported.id == seedFields.first?.id { seed = increment.partialValue }
                    } else { value = .unsigned(seed) }
                    value = try WorkflowParameters.normalized(value, parameter: parameter)
                case .width, .height:
                    if parameter.schema == nil {
                        guard let number = value.double, number.isFinite, (64...8192).contains(number) else { throw ComfyError.invalid("未取得服务器尺寸约束，兼容范围为 64–8192。") }
                        value = .integer(Int64(number) / 16 * 16)
                    }
                case .integer:
                    if let number = Int64(value.text) { value = .integer(number) }
                    else if let number = UInt64(value.text) { value = .unsigned(number) }
                    else { throw ComfyError.invalid("\(spec.label) 不是有效整数。") }
                case .decimal:
                    guard let number = value.double, number.isFinite else { throw ComfyError.invalid("\(spec.label) 不是有效数值。") }
                    value = .decimal(number)
                case .image, .video:
                    guard let filename = value.string, !filename.isEmpty else { throw ComfyError.invalid("请先选择\(spec.label)。") }
                case .boolean:
                    guard value.bool != nil else { throw ComfyError.invalid("\(spec.label) 不是有效开关值。") }
                default: break
                }
                inputs[spec.field] = value
                node["inputs"] = .object(inputs)
                graph[spec.nodeID] = .object(node)
            }
            for nodeID in workflow.graph.keys {
                guard var node = graph[nodeID]?.object, var inputs = node["inputs"]?.object else { continue }
                if inputs["width"] != nil, inputs["height"] != nil, inputs["batch_size"]?.double != nil { inputs["batch_size"] = .integer(1) }
                if loraEnabled[nodeID] == false {
                    for field in inputs.keys where field.lowercased().contains("strength") && inputs[field]?.double != nil { inputs[field] = .decimal(0) }
                }
                node["inputs"] = .object(inputs)
                graph[nodeID] = .object(node)
            }
            if let queue = queue {
                graph = try RayQueue.materialize(graph, selection: queue, prompt: queue.prompts[index / batch], seed: seed, ordinal: queue.first + index / batch)
            }
            let text = queue.map { $0.prompts[index / batch] } ?? workflow.mainPrompt.map { (resolved[$0.id] ?? $0.defaultValue).text }
            result.append(BuiltPrompt(index: index + 1, seed: seed, graph: .object(graph), promptText: text))
        }
        return result
    }
}

public enum ServerAddress {
    public static func normalized(_ raw: String) throws -> URL {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ComfyError.invalid("请填写 ComfyUI 地址。") }
        let address = cleaned.contains("://") ? cleaned : "http://" + cleaned
        guard var components = URLComponents(string: address), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw ComfyError.invalid("地址应为 http(s)://主机:端口；账号密码请分开填写。") }
        components.scheme = components.scheme?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw ComfyError.invalid("服务器地址无效。") }
        return url
    }

    public static func endpoint(base: URL, route: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ComfyError.invalid("服务器地址无效。") }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([components.path, route.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }.joined(separator: "/"))
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ComfyError.invalid("无法构造请求地址。") }
        return url
    }

    public static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased() && first.host?.lowercased() == second.host?.lowercased() && port(first) == port(second)
    }
}
