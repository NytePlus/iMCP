import Foundation

/// Only the user-selected file is read. Its content never enters logs or defaults.
enum WeChatImageConfig {
    static func bookmarkKey(_ account: String) -> String { "wechatImageConfigBookmark." + account }
    static func readUIN(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536, let content = String(data: data, encoding: .utf8) else {
            throw WeChatError.message("配置文件过大或编码不支持。")
        }
        let values = content.components(separatedBy: .newlines).compactMap { line -> String? in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("last_uin=") else { return nil }
            let encoded = String(line.dropFirst(9)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let bytes = Data(base64Encoded: encoded), let uin = String(data: bytes, encoding: .utf8),
                  !uin.isEmpty, uin.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return uin
        }
        guard Set(values).count == 1, let value = values.first else {
            throw WeChatError.message("配置缺少有效、唯一的 last_uin，请选择当前账号对应的 config.ini。")
        }
        return value
    }
    static func loadUIN(account: String) throws -> String? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey(account)) else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, url.startAccessingSecurityScopedResource() else {
            throw WeChatError.message("图片配置授权失效，请重新选择 config.ini。")
        }
        defer { url.stopAccessingSecurityScopedResource() }
        return try readUIN(url)
    }
}
