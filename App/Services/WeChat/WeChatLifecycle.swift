import AppKit

@MainActor final class WeChatLifecycle {
    static let shared = WeChatLifecycle()
    private var observers: [NSObjectProtocol] = []
    private init() {}
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
                Task {
                    await WeChatBackend.shared.stop(); await WeChatResources.shared.clear()
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { await Self.resumeIfEnabled() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                // stdin closes on app exit; the child terminates on EOF. Temp files
                // are also removed deterministically when the next backend starts.
                Task {
                    await WeChatBackend.shared.stop(); await WeChatResources.shared.clear()
                }
            }
        )
        Task { await Self.resumeIfEnabled() }
    }
    static func resumeIfEnabled() async {
        if UserDefaults.standard.bool(forKey: "wechatEnabled"),
            UserDefaults.standard.object(forKey: "isEnabled") as? Bool != false
        {
            _ = try? await WeChatBackend.shared.request("status")
        }
    }
}
