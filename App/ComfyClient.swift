import Foundation
import ComfyCore

final class ComfyClient: NSObject, URLSessionTaskDelegate {
    let base: URL
    private let authorization: String?
    private let configuration: URLSessionConfiguration
    private lazy var session: URLSession = {
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(server: ServerProfile, configuration: URLSessionConfiguration = .ephemeral) throws {
        self.configuration = configuration
        base = try ServerAddress.normalized(server.address)
        let password = try PasswordStore.read(id: server.id)
        authorization = server.username.isEmpty ? nil : "Basic " + Data((server.username + ":" + password).utf8).base64EncodedString()
        super.init()
    }

    func close() { session.invalidateAndCancel() }

    private func request(route: String, method: String = "GET", body: JSONValue? = nil, query: [URLQueryItem] = []) throws -> URLRequest {
        var request = URLRequest(url: try ServerAddress.endpoint(base: base, route: route, query: query))
        request.httpMethod = method
        request.setValue("ComfyPocket/0.1", forHTTPHeaderField: "User-Agent")
        if let authorization = authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        if let body = body {
            request.httpBody = try body.encoded()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func json(_ route: String, method: String = "GET", body: JSONValue? = nil, query: [URLQueryItem] = []) async throws -> JSONValue {
        let (data, response) = try await session.data(for: request(route: route, method: method, body: body, query: query))
        try validate(response: response, data: data)
        guard data.count <= 40 * 1024 * 1024 else { throw ComfyError.invalid("服务器响应超过 40 MB，请清理历史或检查地址。") }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func command(_ route: String, body: JSONValue) async throws {
        let (data, response) = try await session.data(for: request(route: route, method: "POST", body: body))
        try validate(response: response, data: data)
    }

    func upload(file: URL, mime: String, directory: URL) async throws -> String {
        let boundary = "ComfyPocket-" + UUID().uuidString
        let multipart = directory.appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: multipart.path, contents: nil)
        let output = try FileHandle(forWritingTo: multipart)
        defer { try? output.close(); try? FileManager.default.removeItem(at: multipart) }
        func append(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        let filename = UUID().uuidString + "." + (file.pathExtension.isEmpty ? "bin" : file.pathExtension.lowercased())
        try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n")
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        while let bytes = try source.read(upToCount: 64 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try append("\r\n")
        for (field, value) in [("type", "input"), ("subfolder", "comfy_pocket"), ("overwrite", "false")] {
            try append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n")
        }
        try append("--\(boundary)--\r\n")
        try output.synchronize()
        var request = try self.request(route: "upload/image", method: "POST")
        request.timeoutInterval = 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: multipart)
        try validate(response: response, data: data)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let name = value["name"]?.string, !name.isEmpty else { throw ComfyError.invalid("上传响应没有文件名。") }
        let subfolder = value["subfolder"]?.string ?? "comfy_pocket"
        return subfolder.isEmpty ? name : subfolder + "/" + name
    }

    func download(_ output: OutputDescriptor, destination: URL) async throws {
        let query = [URLQueryItem(name: "filename", value: output.filename), URLQueryItem(name: "subfolder", value: output.subfolder), URLQueryItem(name: "type", value: output.fileType)]
        let request = try self.request(route: "view", query: query)
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try validate(response: response, data: nil)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ComfyError.invalid("服务器返回了空文件，请保留任务并重试下载。") }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func progressSocket(clientID: String) throws -> URLSessionWebSocketTask {
        guard var components = URLComponents(url: try ServerAddress.endpoint(base: base, route: "ws", query: [URLQueryItem(name: "clientId", value: clientID)]), resolvingAgainstBaseURL: false) else { throw ComfyError.invalid("WebSocket 地址无效。") }
        components.scheme = base.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw ComfyError.invalid("WebSocket 地址无效。") }
        var request = URLRequest(url: url)
        if let authorization = authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let socket = session.webSocketTask(with: request)
        socket.resume()
        return socket
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ServerAddress.sameOrigin(base, url) else { completionHandler(nil); return }
        var redirect = request
        if let authorization = authorization { redirect.setValue(authorization, forHTTPHeaderField: "Authorization") }
        completionHandler(redirect)
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let response = response as? HTTPURLResponse else { throw ComfyError.invalid("未收到有效 HTTP 响应。") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw ComfyError.invalid("认证失败，请在连接设置中检查账号和密码。") }
            let detail: String
            if let data = data, let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                detail = value["error"]?["message"]?.string ?? value["error"]?.string ?? String(data: data.prefix(1200), encoding: .utf8) ?? "未知错误"
            } else { detail = HTTPURLResponse.localizedString(forStatusCode: response.statusCode) }
            throw ComfyError.server(response.statusCode, detail)
        }
    }
}
