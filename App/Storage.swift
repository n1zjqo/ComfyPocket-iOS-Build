import Foundation
import Security
import UIKit
import ComfyCore

final class DiskStore {
    let root: URL
    let media: URL
    let uploads: URL
    private let stateURL: URL
    init(rootURL: URL? = nil) throws {
        let root: URL
        if let rootURL = rootURL { root = rootURL }
        else {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "ComfyPocketUITests" : "ComfyPocket"
            root = support.appendingPathComponent(folder, isDirectory: true)
        }
        self.root = root
        media = root.appendingPathComponent("Media", isDirectory: true)
        uploads = root.appendingPathComponent("Uploads", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        for directory in [root, media, uploads] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var location = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try location.setResourceValues(values)
        }
    }
    func load() throws -> SavedState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return SavedState() }
        return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: stateURL))
    }
    func save(_ state: SavedState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func mediaURL(_ name: String) -> URL { media.appendingPathComponent(name) }
    func uploadURL(_ name: String) -> URL { uploads.appendingPathComponent(name) }
    func pruneUploads(keeping names: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: uploads, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for file in files where !names.contains(file.lastPathComponent) {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { try? FileManager.default.removeItem(at: file) }
        }
    }
    func usedBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
enum PasswordStore {
    private static let service = "com.ray.comfypocket.server"
    static func save(_ password: String, id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ComfyError.invalid("无法把密码安全保存到钥匙串（\(status)）。没有回退为明文。") }
    }
    static func read(id: UUID) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else { throw ComfyError.invalid("无法读取服务器密码（\(status)），请解锁设备或重新保存连接。") }
        return password
    }
}
