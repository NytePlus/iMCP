import AppKit
import SwiftUI

struct WeChatSettingsView: View {
    @State private var directory = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? "尚未选择"
    @State private var key = ""
    @State private var query = ""
    @State private var status = "请选择账号目录并导入密钥。"
    @State private var conversations: [Value] = []
    @State private var quotaGB = 5
    @State private var busy = false
    @State private var bootstrapCommand = ""
    @State private var bootstrapPending = false
    @State private var deleteID: String?
    var body: some View {
        Form {
            Section("账号和密钥") {
                Text(directory).textSelection(.enabled)
                Button("选择包含 db_storage 的微信账号目录") { chooseDirectory() }
                SecureField("64 位数据库原始密钥", text: $key)
                Button("保存到 Keychain 并连接") { perform {
                    let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
                    guard !account.isEmpty else { throw WeChatError.message("请先选择账号目录。") }
                    try WeChatKeychain.save(key, account: account); key = ""
                    await WeChatBackend.shared.stop(); try await refresh()
                }}
                Button("生成一次性 Terminal 提取命令") {
                    do {
                        let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
                        guard !account.isEmpty else { throw WeChatError.message("请先选择账号目录。") }
                        let pending = try WeChatBootstrap.prepare(account: account)
                        bootstrapCommand = pending.command; bootstrapPending = true
                        Task { defer { bootstrapPending = false; bootstrapCommand = "" }
                            do { try await pending.completion.value; status = "密钥已保存到 Keychain；请恢复 SIP，然后连接。" }
                            catch { status = error.localizedDescription }
                        }
                    } catch { status = error.localizedDescription }
                }.disabled(bootstrapPending)
                if !bootstrapCommand.isEmpty { Text(bootstrapCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Text("首次提取：在 macOS 恢复环境临时关闭 SIP，回到系统后在 Terminal 执行命令。命令会重启微信并等待你登录；完成后恢复 SIP。密钥有效期间无需再次关闭。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("状态") {
                Text(status).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("刷新状态") { perform { try await refresh() } }
                Stepper("磁盘告警阈值：\(quotaGB) GB", value: $quotaGB, in: 1...100)
                Button("保存阈值") { perform { _ = try await WeChatBackend.shared.request("local_quota", ["bytes": .int(quotaGB * 1024 * 1024 * 1024)]); try await refresh() } }
            }
            Section("图片配置只读授权") {
                Text("选择当前微信账号对应的 app_data/radium/ilink/…/kvcomm/config.ini。仅授予这个文件的只读访问，用于派生图片密钥；配置内容不会显示或记录。多账号请勿选择其他账号的配置。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("选择图片配置 config.ini（只读）") { chooseImageConfig() }
                Button("撤销当前账号的图片配置授权") { perform {
                    let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
                    UserDefaults.standard.removeObject(forKey: WeChatImageConfig.bookmarkKey(account))
                    await WeChatBackend.shared.stop(); await WeChatResources.shared.clear()
                    try await refresh()
                }}
            }
            Section("持久授权") {
                TextField("群聊或联系人名称", text: $query)
                Button("查找并授权") { perform { _ = try await WeChatService.requestAccess(query); try await refresh() } }
                ForEach(Array(conversations.enumerated()), id: \.offset) { _, value in
                    let row = value.objectValue ?? [:]
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row["name"]?.stringValue ?? "")
                            Text("\(row["conversation_id"]?.stringValue ?? "") · \(row["index_state"]?.stringValue ?? "")").font(.caption)
                        }
                        Spacer()
                        if row["enabled"]?.boolValue == true {
                            Button("撤销（保留档案）") { perform { _ = try await WeChatBackend.shared.request("local_revoke", ["conversation_id": row["conversation_id"] ?? .null]); try await refresh() } }
                        } else { Text("已禁用").foregroundStyle(.secondary) }
                        Button("彻底清除", role: .destructive) { deleteID = row["conversation_id"]?.stringValue }
                    }
                }
            }
        }
        .formStyle(.grouped).disabled(busy)
        .alert("彻底清除此会话档案？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
            Button("取消", role: .cancel) { deleteID = nil }
            Button("清除", role: .destructive) {
                let id = deleteID ?? ""; deleteID = nil
                perform { _ = try await WeChatBackend.shared.request("local_revoke", ["conversation_id": .string(id), "delete": .bool(true)]); try await refresh() }
            }
        } message: { Text("此操作删除本地文本索引和成员记录，无法恢复；不会修改微信源库。") }
    }
    @MainActor private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "选择包含 db_storage 的微信账号目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("db_storage/session/session.db").path) else {
            status = "目录中没有 db_storage/session/session.db。"; return
        }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "wechatDirectoryBookmark")
            UserDefaults.standard.set(url.lastPathComponent, forKey: "wechatDirectoryName")
            directory = url.lastPathComponent
            Task { await WeChatBackend.shared.stop(); await WeChatResources.shared.clear() }
        } catch { status = error.localizedDescription }
    }
    @MainActor private func refresh() async throws {
        let result = try await WeChatBackend.shared.request("status")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        status = String(decoding: try encoder.encode(result), as: UTF8.self)
        let list = try await WeChatBackend.shared.request("local_list")
        conversations = list.objectValue?["items"]?.arrayValue ?? []
    }
    @MainActor private func chooseImageConfig() {
        let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
        guard !account.isEmpty else { status = "请先选择微信账号目录。"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "为当前账号选择 config.ini，只读授权；不会修改文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == "config.ini" else { status = "请选择 config.ini 文件。"; return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try WeChatImageConfig.readUIN(url)
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: WeChatImageConfig.bookmarkKey(account))
            perform {
                await WeChatBackend.shared.stop(); await WeChatResources.shared.clear()
                try await refresh()
            }
        } catch { status = "配置无法读取或格式不正确，请确认选择的是当前账号的 config.ini。" }
    }
    @MainActor private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await operation() } catch { status = error.localizedDescription } }
    }
}
