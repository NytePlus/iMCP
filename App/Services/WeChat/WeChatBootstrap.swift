import Darwin
import Foundation
import Security

/// The token is not a database key. Its private directory and single-use
/// handshake bind this Terminal command to this account and this app instance.
enum WeChatBootstrap {
    struct Pending: Sendable { let command: String; let completion: Task<Void, Error> }
    static func prepare(account: String) throws -> Pending {
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "imcp-wechat-bootstrap") else {
            throw WeChatError.message("应用缺少密钥提取助手。")
        }
        var random = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw WeChatError.message("无法创建安全令牌。")
        }
        let token = random.map { String(format: "%02x", $0) }.joined()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wk-" + String(token.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("s").path
        guard path.utf8.count < 104 else { throw WeChatError.message("临时 socket 路径过长。") }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WeChatError.message("无法创建密钥传输 socket。") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in buffer.copyBytes(from: source) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd); try? FileManager.default.removeItem(at: directory)
            throw WeChatError.message("无法监听密钥传输 socket。")
        }
        let command = [executable.path, path, token, account].map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let completion = Task.detached(priority: .userInitiated) {
            defer { Darwin.close(fd); try? FileManager.default.removeItem(at: directory) }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&pollDescriptor, 1, 180_000) > 0 else { throw WeChatError.message("密钥提取命令已过期。") }
            let client = Darwin.accept(fd, nil, nil)
            guard client >= 0 else { throw WeChatError.message("密钥连接失败。") }
            let handle = FileHandle(fileDescriptor: client, closeOnDealloc: true)
            defer { try? handle.close() }
            var timeout = timeval(tv_sec: 150, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
            let hello = try receive(handle)
            guard hello["token"] == token else { throw WeChatError.message("无效的一次性令牌。") }
            try handle.write(contentsOf: Data([1]))
            let payload = try receive(handle)
            guard payload["account"] == account, let key = payload["key"] else { throw WeChatError.message("密钥账号不匹配。") }
            try WeChatKeychain.save(key, account: account)
            try handle.write(contentsOf: Data([1]))
        }
        return Pending(command: command, completion: completion)
    }
    private static func receive(_ handle: FileHandle) throws -> [String: String] {
        func exact(_ count: Int) throws -> Data {
            var data = Data()
            while data.count < count {
                guard let bytes = try handle.read(upToCount: count-data.count), !bytes.isEmpty else { throw WeChatError.message("密钥传输中断。") }
                data.append(bytes)
            }
            return data
        }
        let count = try exact(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= 4096 else { throw WeChatError.message("密钥传输格式错误。") }
        return try JSONDecoder().decode([String: String].self, from: exact(count))
    }
}
