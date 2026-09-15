import Foundation
import MCP

protocol ResourceService: Service {
    func resources() async -> [MCP.Resource]
    func readResource(_ uri: String) async throws -> MCP.Resource.Content?
}

actor WeChatResources {
    static let shared = WeChatResources()
    private struct Asset { let url: URL; let messageID: String; let mime: String; let size: Int; let expires: Date }
    private var assets: [String: Asset] = [:]
    func register(_ value: Value) throws -> Value {
        cleanup()
        guard let obj = value.objectValue, let path = obj["path"]?.stringValue,
              let id = obj["message_id"]?.stringValue, let size = obj["size"]?.intValue,
              size <= 100 * 1024 * 1024 else { throw WeChatError.message("媒体返回值无效。") }
        let uri = "wechat://media/" + UUID().uuidString.lowercased()
        let mime = obj["mime_type"]?.stringValue ?? "application/octet-stream"
        assets[uri] = Asset(url: URL(fileURLWithPath: path), messageID: id, mime: mime, size: size, expires: Date().addingTimeInterval(1800))
        Task { try? await Task.sleep(for: .seconds(1800)); self.cleanup() }
        return .object(["resource_uri": .string(uri), "mime_type": .string(mime), "size": .int(size), "expires_in_seconds": .int(1800)])
    }
    func list() async -> [MCP.Resource] {
        cleanup()
        var result: [MCP.Resource] = []
        for (uri, asset) in assets {
            guard (try? await WeChatBackend.shared.request("authorize_message", ["message_id": .string(asset.messageID)])) != nil else { continue }
            result.append(MCP.Resource(name: "WeChat media", uri: uri, mimeType: asset.mime, size: asset.size))
        }
        return result
    }
    func read(_ uri: String) async throws -> MCP.Resource.Content? {
        guard uri.hasPrefix("wechat://media/") else { return nil }
        cleanup()
        guard let asset = assets[uri] else { throw WeChatError.message("媒体资源已过期或不可用。") }
        _ = try await WeChatBackend.shared.request("authorize_message", ["message_id": .string(asset.messageID)])
        let data = try Data(contentsOf: asset.url, options: .mappedIfSafe)
        guard data.count <= 100 * 1024 * 1024 else { throw WeChatError.message("媒体超过 100 MB。") }
        return .binary(data, uri: uri, mimeType: asset.mime)
    }
    func clear() { for a in assets.values { try? FileManager.default.removeItem(at: a.url) }; assets.removeAll() }
    private func cleanup() {
        for (uri, asset) in assets where asset.expires <= Date() {
            try? FileManager.default.removeItem(at: asset.url); assets.removeValue(forKey: uri)
        }
    }
}

extension WeChatService: ResourceService {
    func resources() async -> [MCP.Resource] { await WeChatResources.shared.list() }
    func readResource(_ uri: String) async throws -> MCP.Resource.Content? { try await WeChatResources.shared.read(uri) }
}
