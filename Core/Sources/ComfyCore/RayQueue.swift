import Foundation

public struct RayQueueSelection {
    public var nodeID: String
    public var prompts: [String]
    public var first: Int
    public var total: Int
    public var folder: String
}

public enum RayQueue {
    public static let maximumTasks = 64

    public static func selection(workflow: Workflow, values: [String: JSONValue]) throws -> RayQueueSelection? {
        let identifiers = workflow.graph.keys.filter { workflow.graph[$0]?["class_type"]?.string == "RayPromptQueue" }
        if identifiers.isEmpty { return nil }
        guard identifiers.count == 1, let identifier = identifiers.first, let inputs = workflow.graph[identifier]?["inputs"]?.object else {
            throw ComfyError.invalid("手机目前只支持一个 RayPromptQueue；请先在电脑拆分多队列工作流。")
        }
        func value(_ field: String) -> JSONValue { values[identifier + "|" + field] ?? inputs[field] ?? .null }
        guard let text = value("prompts").string, let format = value("format").string,
              let first = Int(value("first").text), let last = Int(value("last").text),
              let folder = value("output_folder").string else {
            throw ComfyError.invalid("Ray 队列输入需为直接填写的文字和整数，不能连接另一个节点。")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let entries: [String]
        if format == "用 --- 分隔" {
            var sections: [String] = []
            var lines: [String] = []
            for line in normalized.components(separatedBy: "\n") {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    sections.append(lines.joined(separator: "\n"))
                    lines = []
                } else { lines.append(line) }
            }
            sections.append(lines.joined(separator: "\n"))
            entries = sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else {
            throw ComfyError.invalid("手机端 Ray 队列目前支持“用 --- 分隔”；请将每条提示词用独占一行的 --- 分开。不会猜测其他格式。")
        }
        guard !entries.isEmpty else { throw ComfyError.invalid("队列里没有提示词。请填写一条，或用 --- 分隔多条。") }
        let end = last == 0 ? entries.count : last
        guard first >= 1, first <= entries.count, end >= first, end <= entries.count else {
            throw ComfyError.invalid("队列范围无效：共有 \(entries.count) 条；起始从 1 开始，结束填 0 表示末条。")
        }
        let cleaned = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.hasPrefix("/"), !cleaned.contains("\\"), !cleaned.contains(":"),
              !cleaned.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ComfyError.invalid("输出目录应是相对目录，例如 NAS/资产库，不能包含盘符或 ..。")
        }
        let selected = Array(entries[(first - 1)..<end])
        let prompts = (workflow.queueMode ?? .single) == .single ? [selected[0]] : selected
        return RayQueueSelection(nodeID: identifier, prompts: prompts, first: first, total: entries.count, folder: cleaned)
    }

    public static func materialize(_ graph: [String: JSONValue], selection: RayQueueSelection, prompt: String, seed: UInt64, ordinal: Int) throws -> [String: JSONValue] {
        var result = graph
        let basename = String(format: "ComfyPocket_%04d", ordinal) + "_" + String(seed)
        let prefix = selection.folder.isEmpty ? basename : selection.folder + "/" + basename
        var references = 0
        for identifier in graph.keys where identifier != selection.nodeID {
            guard var node = graph[identifier]?.object, var inputs = node["inputs"]?.object else { continue }
            for (field, value) in inputs where value.isLink && value.array?.first?.string == selection.nodeID {
                references += 1
                switch value.array?[1].double {
                case 0: inputs[field] = .string(prompt)
                case 1: inputs[field] = .string(prefix)
                case 2: inputs[field] = .unsigned(seed)
                default: throw ComfyError.invalid("Ray 队列包含未知输出槽。手机仅支持提示词、文件名前缀和种子三个输出，不会提交不完整的图。")
                }
            }
            node["inputs"] = .object(inputs)
            result[identifier] = .object(node)
        }
        guard references > 0 else { throw ComfyError.invalid("Ray 队列没有连接到执行节点，请检查工作流。") }
        result.removeValue(forKey: selection.nodeID)
        return result
    }
}
