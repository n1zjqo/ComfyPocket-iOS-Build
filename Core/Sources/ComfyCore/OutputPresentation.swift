import Foundation

public enum OutputPresentation {
    public static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func distinctTextOutputs(_ outputs: [OutputDescriptor], excluding prompt: String? = nil) -> [OutputDescriptor] {
        var seen = Set<String>()
        if let prompt = prompt { seen.insert(normalizedText(prompt)) }
        return outputs.filter { output in
            guard output.kind == .text else { return false }
            let text = normalizedText(output.text)
            return !text.isEmpty && seen.insert(text).inserted
        }
    }

    public static func galleryOutputs(_ outputs: [OutputDescriptor]) -> [OutputDescriptor] {
        let media = outputs.filter { $0.kind != .text }
        return media.isEmpty ? distinctTextOutputs(outputs) : media
    }
}
