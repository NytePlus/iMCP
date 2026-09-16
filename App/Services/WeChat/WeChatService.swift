import AppKit
import JSONSchema

final class WeChatService: Service, @unchecked Sendable {
    static let shared = WeChatService()
    var isActivated: Bool { get async { UserDefaults.standard.data(forKey: "wechatDirectoryBookmark") != nil } }
    func activate() async throws { _ = try await WeChatBackend.shared.request("status") }
    var tools: [Tool] {
        let common: [String: JSONSchema] = [
            "conversation": .string(description: "已授权群聊名称或 conversation_id；同名时先查找稳定 ID"),
            "start": .string(description: "开始时间，包含；带时区 RFC3339", format: .dateTime),
            "end": .string(description: "结束时间，不包含；带时区 RFC3339", format: .dateTime),
            "members": .array(description: "成员名称或 member_id，多值 OR；重名返回歧义", items: .string()),
            "types": .array(
                description: "消息类型，多值 OR；与成员、时间和关键词 AND",
                items: .string(
                    enum: [
                        "text", "file", "link", "image", "voice", "video", "emoji", "location", "mini_program",
                        "merged_messages", "quote", "transfer", "system", "revoke", "other",
                    ].map { .string($0) }
                )
            ),
            "keyword": .string(description: "检索正文、引用、链接标题/描述/URL、文件名；无 OCR/语音转写"),
            "order": .string(default: .string("desc"), enum: [.string("asc"), .string("desc")]),
            "limit": .integer(description: "每页 1–500 条", default: .int(50)),
            "cursor": .string(description: "上次响应的 next_cursor；保持筛选条件不变"),
        ]
        let definitions: [(String, String, [String: JSONSchema], [String])] = [
            ("status", "查看微信源库兼容性、归档状态和磁盘占用。数据仅在手动同步时更新。", [:], []),
            ("find_conversations", "按名称查找已授权会话，不显示未授权会话。", ["query": .string()], []),
            ("request_access", "请求本机用户持久授权群聊/联系人；只有用户确认后才可访问。", ["query": .string()], ["query"]),
            (
                "list_members", "分页查找群成员、稳定 member_id 和已见名称；重名时用 ID 筛选。",
                [
                    "conversation": .string(), "query": .string(), "limit": .integer(default: .int(100)),
                    "cursor": .string(description: "上页 next_cursor；保持群聊与查询条件不变"),
                ], ["conversation"]
            ),
            ("sync", "手动同步已授权会话：读取本次源库快照中的新增消息，之后到达的消息留待下次同步。", ["conversation": .string()], ["conversation"]),
            ("get_messages", "读取归档消息；支持时间、成员、类型和关键词 AND 筛选。保留曾见消息，可能包含源库已删除内容。", common, ["conversation"]),
            ("search_messages", "组合筛选全文检索。首次完整索引完成后才开放查询。", common, ["conversation", "keyword"]),
            (
                "get_message_context", "读取指定已授权消息的前后文。",
                ["message_id": .string(), "context": .integer(default: .int(20))], ["message_id"]
            ),
            (
                "get_updates", "读取已手动同步的归档新增消息；先调用 wechat_sync 更新归档。此接口不访问源库、不等待新消息，重试不消费游标。",
                common,
                ["conversation"]
            ),
            ("get_media", "获取已授权消息的临时媒体资源；不可用时明确报错。", ["message_id": .string()], ["message_id"]),
        ]
        return definitions.map { name, description, properties, required in
            Tool(
                name: "wechat_" + name,
                description: description,
                inputSchema: .object(
                    properties: .init(uniqueKeysWithValues: properties.sorted { $0.key < $1.key }),
                    required: required,
                    additionalProperties: false
                ),
                annotations: .init(
                    title: "WeChat · " + name,
                    readOnlyHint: name != "request_access" && name != "sync",
                    openWorldHint: false
                )
            ) { input in
                if name == "request_access" { return try await Self.requestAccess(input["query"]?.stringValue ?? "") }
                if name == "get_media" {
                    let result = try await WeChatBackend.shared.request(name, input)
                    return try await WeChatResources.shared.register(result)
                }
                return try await WeChatBackend.shared.request(name, input)
            }
        }
    }

    @MainActor static func requestAccess(_ query: String) async throws -> Value {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WeChatError.message("请输入会话名称。")
        }
        let found = try await WeChatBackend.shared.request("local_discover", ["query": .string(query)])
        let candidates = found.objectValue?["items"]?.arrayValue ?? []
        guard !candidates.isEmpty else { return .object(["approved": .bool(false)]) }
        let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 28))
        for candidate in candidates {
            selector.addItem(
                withTitle:
                    "\(candidate.objectValue?["name"]?.stringValue ?? "") — \(candidate.objectValue?["conversation_id"]?.stringValue ?? "")"
            )
        }
        let alert = NSAlert()
        alert.messageText = "允许 MCP 访问微信会话？"
        alert.informativeText = "请选择要授权的会话。批准后可手动同步本地历史文本，持续授权直到你撤销。撤销默认保留档案但禁止访问。"
        alert.accessoryView = selector
        alert.addButton(withTitle: "批准"); alert.addButton(withTitle: "拒绝")
        guard alert.runModal() == .alertFirstButtonReturn else { return .object(["approved": .bool(false)]) }
        let choice = candidates[selector.indexOfSelectedItem].objectValue ?? [:]
        return try await WeChatBackend.shared.request("local_grant", choice)
    }
}
