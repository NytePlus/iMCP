import AppKit
import SwiftUI

struct WeChatSettingsView: View {
    @State private var directory = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? "尚未选择"
    @State private var key = ""
    @State private var query = ""
    @State private var status = "请选择账号目录并导入密钥。"
    @State private var statusRows: [StatusRow] = []
    @State private var conversations: [Value] = []
    @State private var quotaGB = 5
    @State private var busy = false
    @State private var bootstrapCommand = ""
    @State private var bootstrapPending = false
    @State private var deleteID: String?
    private struct StatusRow: Identifiable {
        let id: String
        let title: String
        let value: String
    }
    var body: some View {
        Form {
            Section("账号和密钥") {
                Text(directory).textSelection(.enabled)
                Button("选择包含 db_storage 的微信账号目录") { chooseDirectory() }
                SecureField("64 位数据库原始密钥", text: $key)
                Button("保存到 Keychain 并连接") {
                    perform {
                        let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
                        guard !account.isEmpty else { throw WeChatError.message("请先选择账号目录。") }
                        try WeChatKeychain.save(key, account: account); key = ""
                        await WeChatBackend.shared.stop(); try await refresh()
                    }
                }
                Button("生成一次性 Terminal 提取命令") {
                    do {
                        let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
                        guard !account.isEmpty else { throw WeChatError.message("请先选择账号目录。") }
                        let pending = try WeChatBootstrap.prepare(account: account)
                        bootstrapCommand = pending.command; bootstrapPending = true
                        Task {
                            defer { bootstrapPending = false; bootstrapCommand = "" }
                            do {
                                try await pending.completion.value; statusRows = [];
                                status = "密钥已保存到 Keychain；请恢复 SIP，然后连接。"
                            } catch { statusRows = []; status = error.localizedDescription }
                        }
                    } catch { statusRows = []; status = error.localizedDescription }
                }.disabled(bootstrapPending)
                if !bootstrapCommand.isEmpty {
                    Text(bootstrapCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                Text("首次提取：在 macOS 恢复环境临时关闭 SIP，回到系统后在 Terminal 执行命令。命令会重启微信并等待你登录；完成后恢复 SIP。密钥有效期间无需再次关闭。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("状态") {
                if statusRows.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    ForEach(statusRows) { row in
                        LabeledContent(row.title, value: row.value).textSelection(.enabled)
                    }
                }
                Button("刷新状态") { perform { try await refresh() } }
                Stepper("磁盘告警阈值：\(quotaGB) GB", value: $quotaGB, in: 1 ... 100)
                Button("保存阈值") {
                    perform {
                        _ = try await WeChatBackend.shared.request(
                            "local_quota",
                            ["bytes": .int(quotaGB * 1024 * 1024 * 1024)]
                        ); try await refresh()
                    }
                }
            }
            Section("图片配置只读授权") {
                Text(
                    "选择当前微信账号对应的 app_data/radium/ilink/…/kvcomm/config.ini。仅授予这个文件的只读访问，用于派生图片密钥；配置内容不会显示或记录。多账号请勿选择其他账号的配置。"
                )
                .font(.caption).foregroundStyle(.secondary)
                Button("选择图片配置 config.ini（只读）") { chooseImageConfig() }
                Button("撤销当前账号的图片配置授权") {
                    perform {
                        let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
                        UserDefaults.standard.removeObject(forKey: WeChatImageConfig.bookmarkKey(account))
                        await WeChatBackend.shared.stop(); await WeChatResources.shared.clear()
                        try await refresh()
                    }
                }
            }
            Section("持久授权") {
                Text("消息仅在手动同步时更新；本次快照之后的新消息留待下次同步。首次同步会导入历史消息。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("群聊或联系人名称", text: $query)
                Button("查找并授权") {
                    perform {
                        _ = try await WeChatService.requestAccess(query); try await refresh()
                    }
                }
                ForEach(Array(conversations.enumerated()), id: \.offset) { _, value in
                    let row = value.objectValue ?? [:]
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row["name"]?.stringValue ?? "")
                            Text(
                                "\(row["conversation_id"]?.stringValue ?? "") · \(row["index_state"]?.stringValue ?? "")"
                            ).font(.caption)
                        }
                        Spacer()
                        if row["enabled"]?.boolValue == true {
                            Button("手动同步") {
                                perform {
                                    _ = try await WeChatBackend.shared.request(
                                        "sync", ["conversation": row["conversation_id"] ?? .null]
                                    ); try await refresh()
                                }
                            }
                            Button("撤销（保留档案）") {
                                perform {
                                    _ = try await WeChatBackend.shared.request(
                                        "local_revoke",
                                        ["conversation_id": row["conversation_id"] ?? .null]
                                    ); try await refresh()
                                }
                            }
                        } else {
                            Text("已禁用").foregroundStyle(.secondary)
                        }
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
                perform {
                    _ = try await WeChatBackend.shared.request(
                        "local_revoke",
                        ["conversation_id": .string(id), "delete": .bool(true)]
                    ); try await refresh()
                }
            }
        } message: {
            Text("此操作删除本地文本索引和成员记录，无法恢复；不会修改微信源库。")
        }
    }
    @MainActor private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.message = "选择包含 db_storage 的微信账号目录"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files",
                isDirectory: true
            )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("db_storage/session/session.db").path)
        else {
            statusRows = []; status = "目录中没有 db_storage/session/session.db。"; return
        }
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: "wechatDirectoryBookmark")
            UserDefaults.standard.set(url.lastPathComponent, forKey: "wechatDirectoryName")
            directory = url.lastPathComponent
            Task {
                await WeChatBackend.shared.stop(); await WeChatResources.shared.clear()
            }
        } catch { statusRows = []; status = error.localizedDescription }
    }
    @MainActor private func refresh() async throws {
        let result = try await WeChatBackend.shared.request("status")
        statusRows = makeStatusRows(result.objectValue ?? [:])
        status = statusRows.isEmpty ? "后端未返回状态信息。" : "状态已刷新。"
        let list = try await WeChatBackend.shared.request("local_list")
        conversations = list.objectValue?["items"]?.arrayValue ?? []
    }
    private func makeStatusRows(_ values: [String: Value]) -> [StatusRow] {
        var values = values
        values["image_config_available"] = .bool(
            values["image_key_configured"]?.boolValue == true
                && values["image_config_unavailable"]?.boolValue != true
        )
        let fields: [(String, String)] = [
            ("source_available", "源数据库可用"),
            ("sync_mode", "同步方式"),
            ("manual_sync_ready", "手动同步可用"),
            ("image_key_configured", "图片密钥已配置"),
            ("image_config_available", "图片配置可用"),
            ("compatibility", "兼容性"),
            ("session_index_diagnostics", "会话索引诊断"),
            ("index_bytes", "归档索引大小"),
            ("quota_bytes", "磁盘告警阈值"),
            ("quota_warning", "磁盘告警"),
            ("archive_semantics", "归档语义"),
        ]
        return fields.compactMap { key, title in
            guard let value = values[key] else { return nil }
            return StatusRow(id: key, title: title, value: formatStatusValue(value, key: key))
        }
    }
    private func formatStatusValue(_ value: Value, key: String? = nil) -> String {
        switch value {
        case .null: return "无"
        case .bool(let value): return value ? "是" : "否"
        case .int(let value):
            if key == "index_bytes" || key == "quota_bytes" {
                return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
            }
            return value.formatted()
        case .double(let value): return value.formatted()
        case .string(let value):
            if key == "sync_mode", value == "manual" { return "手动同步" }
            if key == "archive_semantics", value == "first_observed" { return "保留首次观测内容" }
            return value.isEmpty ? "无" : value
        case .array(let values):
            return values.isEmpty ? "无" : values.map { formatStatusValue($0) }.joined(separator: "、")
        case .object(let values):
            if values.isEmpty { return "无" }
            return values.sorted { $0.key < $1.key }
                .map { "\(diagnosticTitle($0.key))：\(formatStatusValue($0.value))" }
                .joined(separator: "；")
        case .data: return "二进制数据"
        }
    }
    private func diagnosticTitle(_ key: String) -> String {
        switch key {
        case "available_indexes": return "可用索引"
        case "existing_index": return "现有索引"
        case "query_plan": return "查询计划"
        case "reason": return "原因"
        case "required_index": return "所需索引"
        case "state": return "状态"
        default: return key
        }
    }
    @MainActor private func chooseImageConfig() {
        let account = UserDefaults.standard.string(forKey: "wechatDirectoryName") ?? ""
        guard !account.isEmpty else { statusRows = []; status = "请先选择微信账号目录。"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "为当前账号选择 config.ini，只读授权；不会修改文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == "config.ini" else { statusRows = []; status = "请选择 config.ini 文件。"; return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            _ = try WeChatImageConfig.readUIN(url)
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: WeChatImageConfig.bookmarkKey(account))
            perform {
                await WeChatBackend.shared.stop(); await WeChatResources.shared.clear()
                try await refresh()
            }
        } catch { statusRows = []; status = "配置无法读取或格式不正确，请确认选择的是当前账号的 config.ini。" }
    }
    @MainActor private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false };
            do { try await operation() } catch {
                statusRows = []; status = error.localizedDescription
            }
        }
    }
}
