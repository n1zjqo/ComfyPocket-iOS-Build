import Foundation

public enum AssetKind: String, Codable { case image, video, text }

public struct OutputDescriptor: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: AssetKind
    public var filename: String
    public var subfolder: String
    public var fileType: String
    public var text: String
}
public enum OutputParser {
    public static func parse(promptID: String, outputs: JSONValue) -> [OutputDescriptor] {
        guard let nodes = outputs.object else { return [] }
        var result: [OutputDescriptor] = []
        var seenFiles = Set<String>()
        for nodeID in nodes.keys.sorted() {
            guard let node = nodes[nodeID]?.object else { continue }
            for collection in ["images", "gifs", "videos"] {
                for (position, value) in (node[collection]?.array ?? []).enumerated() {
                    guard let filename = value["filename"]?.string, !filename.isEmpty else { continue }
                    let subfolder = value["subfolder"]?.string ?? ""
                    let type = value["type"]?.string ?? "output"
                    let fileKey = type + "|" + subfolder + "|" + filename
                    guard seenFiles.insert(fileKey).inserted else { continue }
                    let ext = (filename as NSString).pathExtension.lowercased()
                    let video = ext != "gif" && (["mp4", "webm", "mov", "mkv", "m4v"].contains(ext) || (value["format"]?.string ?? "").hasPrefix("video/") || value["animated"]?.bool == true)
                    result.append(OutputDescriptor(id: "\(promptID):\(nodeID):\(collection):\(position):\(fileKey)", kind: video ? .video : .image, filename: filename, subfolder: subfolder, fileType: type, text: ""))
                }
            }
            for field in ["text", "string"] {
                guard let value = node[field], let text = normalize(value), !text.isEmpty else { continue }
                result.append(OutputDescriptor(id: "\(promptID):\(nodeID):\(field)", kind: .text, filename: "", subfolder: "", fileType: "", text: text))
            }
        }
        return result
    }

    public static func normalize(_ value: JSONValue) -> String? {
        if let text = value.string { return text }
        if let array = value.array {
            let parts = array.map(\.text)
            return parts.joined(separator: parts.allSatisfy { $0.count <= 1 } ? "" : "\n")
        }
        return nil
    }
}

public enum QueueParser {
    public static func entries(_ value: JSONValue) -> [(promptID: String, extra: JSONValue, running: Bool)] {
        var entries: [(String, JSONValue, Bool)] = []
        for key in ["queue_running", "queue_pending"] {
            for entry in value[key]?.array ?? [] {
                guard let row = entry.array, row.count > 3, let promptID = row[1].string else { continue }
                entries.append((promptID, row[3], key == "queue_running"))
            }
        }
        return entries
    }
    public static func recover(jobID: String, index: Int, queue: JSONValue, history: JSONValue) -> String? {
        for entry in entries(queue) where matches(entry.extra, jobID: jobID, index: index) { return entry.promptID }
        for (promptID, record) in history.object ?? [:] {
            if let prompt = record["prompt"]?.array, prompt.count > 3, matches(prompt[3], jobID: jobID, index: index) { return promptID }
        }
        return nil
    }
    private static func matches(_ extra: JSONValue, jobID: String, index: Int) -> Bool {
        extra["comfy_pocket_job"]?.string == jobID && extra["comfy_pocket_index"]?.double == Double(index)
    }
}
