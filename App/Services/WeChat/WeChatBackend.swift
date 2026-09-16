import Foundation
import Security

enum WeChatError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

enum WeChatKeychain {
    private static let service = "co.dododo.iMCP.wechat.database"
    static func read(account: String) throws -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: account, kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne,
            ] as CFDictionary,
            &result
        )
        guard status == errSecSuccess, let data = result as? Data,
            let key = String(data: data, encoding: .utf8)
        else {
            throw WeChatError.message("请在设置 → WeChat 中导入此账号的数据库密钥。")
        }
        return key
    }
    static func save(_ key: String, account: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count == 64, key.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw WeChatError.message("密钥必须为 64 位十六进制字符。")
        }
        let query =
            [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as [CFString: Any]
        let data = Data(key.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WeChatError.message("Keychain 写入失败（\(status)）。") }
    }
}

/// One serialized channel per app. Never forwards backend parameters to a log.
actor WeChatBackend {
    static let shared = WeChatBackend()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var scopedURL: URL?
    private var serial: Int = 0
    private var retryAfter = Date.distantPast

    func stop() {
        try? input?.close(); try? output?.close()
        if process?.isRunning == true { process?.terminate() }
        process = nil; input = nil; output = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
    }

    private func start() throws {
        if process?.isRunning == true { return }
        stop()
        guard Date() >= retryAfter else { throw WeChatError.message("后端重启冷却中，请稍后重试。") }
        retryAfter = Date().addingTimeInterval(5)
        guard let bookmark = UserDefaults.standard.data(forKey: "wechatDirectoryBookmark") else {
            throw WeChatError.message("请在设置 → WeChat 中选择微信账号目录。")
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale, url.startAccessingSecurityScopedResource() else {
            throw WeChatError.message("微信目录授权已失效，请重新选择目录。")
        }
        scopedURL = url
        var initialized = false
        defer { if !initialized { stop() } }
        let account = url.lastPathComponent
        let key = try WeChatKeychain.read(account: account)
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "imcp-wechat") else {
            throw WeChatError.message("应用内缺少 imcp-wechat 后端，请使用完整构建。")
        }
        let storage = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("WeChat", isDirectory: true)
        .appendingPathComponent(account, isDirectory: true)
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let p = Process(), stdin = Pipe(), stdout = Pipe()
        p.executableURL = executable; p.arguments = []
        p.standardInput = stdin; p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        do {
            var parameters: [String: Value] = [
                "data_root": .string(url.path), "account": .string(account),
                "key": .string(key), "index_path": .string(storage.appendingPathComponent("archive.sqlite").path),
            ]
            do {
                if let uin = try WeChatImageConfig.loadUIN(account: account) {
                    parameters["image_uin"] = .string(uin)
                }
            } catch {
                // Image configuration problems must not disable text queries.
                parameters["image_config_unavailable"] = .bool(true)
            }
            _ = try exchange("initialize", parameters)
            initialized = true
        } catch { stop(); throw error }
    }

    func request(_ method: String, _ params: [String: Value] = [:]) throws -> Value {
        try start()
        do { return try exchange(method, params) } catch { if process?.isRunning != true { stop() }; throw error }
    }

    private func exchange(_ method: String, _ params: [String: Value]) throws -> Value {
        guard let input, let output, let process else { throw WeChatError.message("后端未启动。") }
        serial += 1
        let request: Value = .object([
            "jsonrpc": .string("2.0"), "id": .int(serial),
            "method": .string(method), "params": .object(params),
        ])
        let payload = try JSONEncoder().encode(request)
        guard payload.count <= 4 * 1024 * 1024 else { throw WeChatError.message("请求过大。") }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }; frame.append(payload)
        // Bound a stalled backend even if it stops reading/writing its pipes.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel() }
        try input.write(contentsOf: frame)
        let header = try readExactly(4, from: output)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 4 * 1024 * 1024 else { throw WeChatError.message("后端响应长度无效。") }
        let response = try JSONDecoder().decode(Value.self, from: readExactly(count, from: output))
        guard response.objectValue?["id"]?.intValue == serial else { throw WeChatError.message("后端响应 ID 不匹配。") }
        if let error = response.objectValue?["error"]?.objectValue?["message"]?.stringValue {
            throw WeChatError.message(error)
        }
        return response.objectValue?["result"] ?? .null
    }
    private func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var result = Data()
        while result.count < count {
            guard let next = try handle.read(upToCount: count - result.count), !next.isEmpty else {
                throw WeChatError.message("WeChat 后端连接已关闭。")
            }
            result.append(next)
        }
        return result
    }
}
