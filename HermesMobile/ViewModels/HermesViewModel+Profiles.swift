import Foundation

// ============================================================================
//  Roster da complication do Apple Watch (perfil default + 2 bots recentes).
// ============================================================================

extension HermesViewModel {
    static let recentBotsKey = "hermes.recentBotProfiles"

    var recentBotNames: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentBotsKey) ?? []
    }

    func rememberRecentBot(_ raw: String?) {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !name.isEmpty, !AgentProfileInfo.isDefaultProfileName(name) else { return }
        var list = recentBotNames
        list.removeAll { $0 == name }
        list.insert(name, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        UserDefaults.standard.set(list, forKey: Self.recentBotsKey)
    }

    func complicationRoster() -> WatchComplicationRoster {
        WatchComplicationRoster.make(
            profiles: Array(profilesByName.values),
            recentBotNames: recentBotNames,
            avatars: compressedAvatars()
        )
    }

    func seedRecentBotsIfNeeded() {
        guard recentBotNames.isEmpty else { return }
        let seeded = profilesByName.values
            .filter { !AgentProfileInfo.isDefaultProfileName($0.name) && !$0.isDefault }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(2)
            .map(\.name)
        if !seeded.isEmpty {
            UserDefaults.standard.set(Array(seeded), forKey: Self.recentBotsKey)
        }
    }

    private func compressedAvatars() -> [String: Data] {
        #if os(iOS)
        var out: [String: Data] = [:]
        for (key, data) in avatarDataByProfile {
            out[key] = AvatarThumbnail.jpeg(from: data) ?? (data.count <= 12_000 ? data : nil)
        }
        return out
        #else
        return avatarDataByProfile
        #endif
    }

    static func parseDate(_ value: JSONValue?) -> Date? {
        if let n = value?.number {
            let seconds = n > 20_000_000_000 ? n / 1000 : n
            return Date(timeIntervalSince1970: seconds)
        }
        if let s = value?.stringValue, !s.isEmpty {
            if let n = Double(s) {
                let seconds = n > 20_000_000_000 ? n / 1000 : n
                return Date(timeIntervalSince1970: seconds)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: s) { return date }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        return nil
    }

    static func normalizedProfileName(_ raw: String?) -> String? {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return name.isEmpty ? nil : name
    }
}

extension WatchComplicationRoster {
    static func make(
        profiles: [AgentProfileInfo],
        recentBotNames: [String],
        avatars: [String: Data]
    ) -> WatchComplicationRoster {
        let defaultProfile = profiles.first(where: { $0.isDefault })
            ?? profiles.first(where: { AgentProfileInfo.isDefaultProfileName($0.name) })

        let defaultName = defaultProfile?.name ?? "default"
        let defaultSlot = WatchComplicationSlot(
            profileName: defaultName,
            displayName: defaultProfile?.displayName ?? "Hermes",
            isDefault: true,
            initials: AgentProfileInfo.initials(from: defaultProfile?.displayName ?? "Hermes"),
            avatarJPEG: avatars[defaultName] ?? avatars["default"]
        )

        let others = profiles.filter {
            $0.name != defaultName && !$0.isDefault && !AgentProfileInfo.isDefaultProfileName($0.name)
        }

        var ordered: [AgentProfileInfo] = []
        var seen = Set<String>()
        for raw in recentBotNames {
            let key = raw.lowercased()
            guard key != defaultName, !seen.contains(key) else { continue }
            if let match = others.first(where: { $0.name == key }) {
                ordered.append(match)
                seen.insert(key)
            }
        }
        let remaining = others
            .filter { !seen.contains($0.name) }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        ordered.append(contentsOf: remaining)

        let recentSlots = ordered.prefix(2).map { profile in
            WatchComplicationSlot(
                profileName: profile.name,
                displayName: profile.displayName,
                isDefault: false,
                initials: AgentProfileInfo.initials(from: profile.displayName),
                avatarJPEG: avatars[profile.name]
            )
        }

        return WatchComplicationRoster(
            slots: [defaultSlot] + recentSlots,
            updatedAt: Date()
        )
    }
}
