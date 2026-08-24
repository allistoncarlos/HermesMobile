import Foundation
#if os(watchOS) && !WIDGET_EXTENSION
import WidgetKit
#endif
#if os(iOS)
import UIKit
#endif

// ============================================================================
//  WatchComplicationRoster — slots da complication retangular (perfil default
//  + dois bots recentes). Compartilhado entre iPhone, Watch e a widget.
// ============================================================================

struct WatchComplicationSlot: Codable, Equatable, Identifiable, Sendable {
    var profileName: String
    var displayName: String
    var isDefault: Bool
    var initials: String
    var avatarJPEG: Data?

    var id: String { profileName }
}

struct WatchComplicationRoster: Codable, Equatable, Sendable {
    var slots: [WatchComplicationSlot]
    var updatedAt: Date

    /// Layout do editor de mostrador, sem dados do gateway.
    static let placeholder = WatchComplicationRoster(
        slots: [
            WatchComplicationSlot(
                profileName: "default",
                displayName: "Hermes",
                isDefault: true,
                initials: "H",
                avatarJPEG: nil
            ),
            WatchComplicationSlot(
                profileName: "bot-a",
                displayName: "Bot",
                isDefault: false,
                initials: "A",
                avatarJPEG: nil
            ),
            WatchComplicationSlot(
                profileName: "bot-b",
                displayName: "Bot",
                isDefault: false,
                initials: "B",
                avatarJPEG: nil
            ),
        ],
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    static let defaultOnly = WatchComplicationRoster(
        slots: [
            WatchComplicationSlot(
                profileName: "default",
                displayName: "Hermes",
                isDefault: true,
                initials: "H",
                avatarJPEG: nil
            ),
        ],
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    var defaultSlot: WatchComplicationSlot {
        slots.first(where: \.isDefault) ?? slots.first ?? Self.defaultOnly.slots[0]
    }

    var recentBotSlots: [WatchComplicationSlot] {
        Array(slots.filter { !$0.isDefault }.prefix(2))
    }
}

enum WatchComplicationStore {
    static let widgetKind = "HermesBots"
    static let appGroupID = "group.com.hermesmobile.app.watchkitapp"
    static let rosterKey = "hermes.watch.roster"
    static let pendingVoiceProfileKey = "hermes.pendingVoiceProfile"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func save(_ roster: WatchComplicationRoster) {
        guard let data = try? JSONEncoder().encode(roster) else { return }
        defaults.set(data, forKey: rosterKey)
        reloadWidgets()
    }

    static func load() -> WatchComplicationRoster? {
        guard let data = defaults.data(forKey: rosterKey) else { return nil }
        return try? JSONDecoder().decode(WatchComplicationRoster.self, from: data)
    }

    static func loadOrPlaceholder() -> WatchComplicationRoster {
        load() ?? .placeholder
    }

    static func setPendingVoiceProfile(_ name: String?) {
        if let name, !name.isEmpty {
            defaults.set(name, forKey: pendingVoiceProfileKey)
        } else {
            defaults.removeObject(forKey: pendingVoiceProfileKey)
        }
    }

    /// Perfil pendente gravado pela complication (App Group), ainda não consumido.
    static func pendingVoiceProfile() -> String? {
        defaults.string(forKey: pendingVoiceProfileKey)
    }

    static func consumePendingVoiceProfile() -> String? {
        let value = defaults.string(forKey: pendingVoiceProfileKey)
        defaults.removeObject(forKey: pendingVoiceProfileKey)
        return value
    }

    static func encodeJSONString(_ roster: WatchComplicationRoster) -> String? {
        guard let data = try? JSONEncoder().encode(roster) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeJSONString(_ json: String) -> WatchComplicationRoster? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WatchComplicationRoster.self, from: data)
    }

    private static func reloadWidgets() {
        #if os(watchOS) && !WIDGET_EXTENSION
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        #endif
    }
}

#if os(iOS)
enum AvatarThumbnail {
    static func jpeg(from data: Data, maxSide: CGFloat = 96, quality: CGFloat = 0.65) -> Data? {
        guard let image = UIImage(data: data) else {
            return data.count <= 12_000 ? data : nil
        }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let size = CGSize(
            width: max(1, (image.size.width * scale).rounded()),
            height: max(1, (image.size.height * scale).rounded())
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}
#endif
