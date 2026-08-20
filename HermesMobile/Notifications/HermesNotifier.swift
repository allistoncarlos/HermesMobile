import Foundation
import UserNotifications
import UIKit

// ============================================================================
//  HermesNotifier — notificações locais de sistema (paridade com o Desktop).
//  Alerta quando o agente responde / pede aprovação e a UI não está olhando.
// ============================================================================

@MainActor
final class HermesNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = HermesNotifier()

    /// App em primeiro plano (scene active).
    private(set) var isForeground = true
    /// Chat que o usuário está vendo agora.
    var activeChatID: String?

    /// Chamado no tap da notificação (session_id do chat).
    var onOpenChat: ((String) -> Void)?

    private var permissionRequested = false
    private var authorized = false

    private enum Category {
        static let reply = "hermes.reply_ready"
        static let approval = "hermes.approval"
        static let clarify = "hermes.clarify"
        static let error = "hermes.error"
    }

    private enum Keys {
        static let sessionID = "session_id"
        static let kind = "kind"
    }

    private override init() {
        super.init()
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories()
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    /// Pede permissão (idempotente). Chamar após connect bem-sucedido.
    func requestAuthorizationIfNeeded() async {
        guard !permissionRequested else { return }
        permissionRequested = true
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorized = granted
            // APNs (registerForRemoteNotifications) fica para Fase 2 — exige App ID
            // com Push e perfil não-wildcard.
        } catch {
            authorized = false
        }
    }

    // MARK: - Events

    func notifyReplyReady(sessionID: String, title: String, body: String) {
        guard shouldNotify(for: sessionID) else { return }
        post(
            category: Category.reply,
            sessionID: sessionID,
            title: title.isEmpty ? "Hermes" : title,
            body: truncate(body),
            kind: "reply"
        )
    }

    func notifyApproval(sessionID: String, message: String) {
        guard shouldNotify(for: sessionID) else { return }
        post(
            category: Category.approval,
            sessionID: sessionID,
            title: "Hermes precisa de aprovação",
            body: truncate(message),
            kind: "approval"
        )
    }

    func notifyClarify(sessionID: String, message: String) {
        guard shouldNotify(for: sessionID) else { return }
        post(
            category: Category.clarify,
            sessionID: sessionID,
            title: "Hermes tem uma pergunta",
            body: truncate(message),
            kind: "clarify"
        )
    }

    func notifyError(sessionID: String?, message: String) {
        let sid = sessionID ?? "system"
        guard shouldNotify(for: sid) || sessionID == nil else { return }
        post(
            category: Category.error,
            sessionID: sid,
            title: "Hermes",
            body: truncate(message),
            kind: "error"
        )
    }

    func notifyConnectionLost(message: String) {
        guard !isForeground else { return }
        post(
            category: Category.error,
            sessionID: "system",
            title: "Hermes",
            body: truncate(message),
            kind: "connection"
        )
    }

    // MARK: - Policy

    /// Notifica se o app não está em foreground olhando exatamente esse chat.
    private func shouldNotify(for sessionID: String) -> Bool {
        if !isForeground { return true }
        if let active = activeChatID, active == sessionID { return false }
        return true
    }

    private func post(category: String, sessionID: String, title: String, body: String, kind: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.badge = NSNumber(value: UIApplication.shared.applicationIconBadgeNumber + 1)
        content.categoryIdentifier = category
        content.userInfo = [
            Keys.sessionID: sessionID,
            Keys.kind: kind,
        ]
        content.threadIdentifier = sessionID

        let id = "\(kind).\(sessionID).\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func truncate(_ text: String, limit: Int = 180) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: limit)
        return String(trimmed[..<idx]) + "…"
    }

    private func registerCategories() {
        let open = UNNotificationAction(
            identifier: "hermes.open",
            title: "Abrir",
            options: [.foreground]
        )
        let cats: [UNNotificationCategory] = [
            UNNotificationCategory(identifier: Category.reply, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.approval, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.clarify, actions: [open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Category.error, actions: [open], intentIdentifiers: []),
        ]
        UNUserNotificationCenter.current().setNotificationCategories(Set(cats))
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor in
            // Em foreground: banner só se não for o chat ativo.
            let sid = notification.request.content.userInfo[Keys.sessionID] as? String
            if let sid, let active = self.activeChatID, sid == active {
                completionHandler([])
            } else {
                completionHandler([.banner, .sound, .badge, .list])
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            let info = response.notification.request.content.userInfo
            if let sid = info[Keys.sessionID] as? String, sid != "system" {
                self.onOpenChat?(sid)
            }
            completionHandler()
        }
    }
}
