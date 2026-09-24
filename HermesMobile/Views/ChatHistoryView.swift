import SwiftUI
import UIKit

// ============================================================================
//  ChatHistoryView — histórico completo de conversas.
//  Lista todas as sessões do servidor (mais as abertas e os grupos), mostrando
//  qual bot respondeu em cada uma e, quando há, o grupo a que pertence.
// ============================================================================

struct ChatHistoryView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @Environment(\.dismiss) private var dismiss

    enum Grouping: String, CaseIterable, Identifiable {
        case recent = "Recentes"
        case bot = "Por bot"
        var id: String { rawValue }
    }

    /// Uma linha do histórico, já resolvida (bot + grupo).
    private struct Entry: Identifiable {
        let id: String
        let title: String
        let preview: String?
        let date: Date?
        let botKey: String
        let botName: String
        let group: GroupRoom?
        let isOpen: Bool
        let isActive: Bool
        let session: SessionSummary?
        let groupRoom: GroupRoom?
        /// Id usado por `vm.isPinned` / `vm.togglePin`.
        let pinID: String
        var isPinned = false
    }

    private struct Section_: Identifiable {
        let id: String
        let title: String
        let botKey: String?
        let group: GroupRoom?
        let entries: [Entry]
    }

    @State private var grouping: Grouping = .recent
    @State private var search = ""
    @State private var botFilter: String?
    @State private var loading = false

    // MARK: - Dados

    private var entries: [Entry] {
        var result: [Entry] = []
        var seen = Set<String>()

        for session in vm.sessions {
            let key = vm.botKey(for: session)
            let open = vm.openChats.first { $0.id == session.id || $0.storedSessionID == session.id }
            seen.insert(session.id)
            if let open { seen.insert(open.id) }
            result.append(Entry(
                id: "s::\(session.id)",
                title: session.title.isEmpty ? "(sem título)" : session.title,
                preview: session.preview,
                date: session.startedAt,
                botKey: key,
                botName: vm.displayName(forBotKey: key),
                group: nil,
                isOpen: open != nil,
                isActive: session.isActive,
                session: session,
                groupRoom: nil,
                pinID: session.id
            ))
        }

        // Chats abertos que ainda não estão na lista do servidor.
        for chat in vm.openChats where chat.kind != .group && !seen.contains(chat.id)
            && !(chat.storedSessionID.map(seen.contains) ?? false)
            && !HermesViewModel.isBlankChat(chat) {
            let key = chat.profileName ?? "default"
            result.append(Entry(
                id: "o::\(chat.id)",
                title: chat.title.isEmpty ? "Nova conversa" : chat.title,
                preview: chat.messages.last(where: { $0.role != .system })?.text,
                date: chat.lastActivity,
                botKey: key,
                botName: vm.displayName(forBotKey: key),
                group: nil,
                isOpen: true,
                isActive: chat.isStreaming,
                session: nil,
                groupRoom: nil,
                pinID: chat.storedSessionID ?? chat.id
            ))
        }

        // Salas de grupo como conversas próprias.
        for room in vm.groupRooms {
            result.append(Entry(
                id: "g::\(room.id)",
                title: room.name,
                preview: room.preview,
                date: room.lastActivity,
                botKey: "group",
                botName: room.members.map(\.displayName).joined(separator: ", "),
                group: room,
                isOpen: vm.openChats.contains { $0.id == room.id },
                isActive: false,
                session: nil,
                groupRoom: room,
                pinID: room.id
            ))
        }

        return result
            .map { entry in
                var e = entry
                e.isPinned = entry.session?.pinned ?? vm.isPinned(entry.pinID)
                return e
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private var filtered: [Entry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            if let botFilter, entry.botKey != botFilter { return false }
            guard !q.isEmpty else { return true }
            return entry.title.lowercased().contains(q)
                || entry.botName.lowercased().contains(q)
                || (entry.preview?.lowercased().contains(q) ?? false)
                || (entry.group?.name.lowercased().contains(q) ?? false)
        }
    }

    private var sections: [Section_] {
        let pinned = filtered.filter(\.isPinned)
        let pinnedSection = pinned.isEmpty ? [] : [
            Section_(id: "pinned", title: "Fixadas", botKey: nil, group: nil, entries: pinned)
        ]
        return pinnedSection + groupedSections(filtered.filter { !$0.isPinned })
    }

    private func groupedSections(_ items: [Entry]) -> [Section_] {
        switch grouping {
        case .recent:
            return items.isEmpty ? [] : [Section_(id: "all", title: "Recentes", botKey: nil, group: nil, entries: items)]
        case .bot:
            var buckets: [String: [Entry]] = [:]
            var order: [String] = []
            for e in items {
                if buckets[e.botKey] == nil { order.append(e.botKey) }
                buckets[e.botKey, default: []].append(e)
            }
            return order.map { key in
                Section_(
                    id: key,
                    title: key == "group" ? "Grupos" : vm.displayName(forBotKey: key),
                    botKey: key, group: nil, entries: buckets[key] ?? []
                )
            }
        }
    }

    private var botOptions: [(key: String, name: String)] {
        let keys = Set(entries.map(\.botKey)).subtracting(["group"])
        return keys.map { ($0, vm.displayName(forBotKey: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - UI

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Agrupar", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                let secs = sections
                if secs.allSatisfy({ $0.entries.isEmpty }) {
                    Text(loading ? "Carregando…" : "Nenhuma conversa encontrada.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(secs) { section in
                        SwiftUI.Section {
                            ForEach(section.entries) { entry in
                                row(entry)
                            }
                        } header: {
                            if !section.title.isEmpty { sectionHeader(section) }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $search, prompt: "Buscar conversas, bots ou grupos")
            .refreshable { await reload() }
            .navigationTitle("Histórico")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Fechar") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            botFilter = nil
                        } label: {
                            Label("Todos os bots", systemImage: botFilter == nil ? "checkmark" : "person.2")
                        }
                        ForEach(botOptions, id: \.key) { option in
                            Button {
                                botFilter = option.key
                            } label: {
                                Label(option.name, systemImage: botFilter == option.key ? "checkmark" : "cpu")
                            }
                        }
                    } label: {
                        Image(systemName: botFilter == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .task { await reload() }
        }
        .navigationViewStyle(.stack)
    }

    private func reload() async {
        loading = true
        await vm.loadSessions(limit: 500)
        await vm.refreshRoster()
        loading = false
    }

    private func sectionHeader(_ section: Section_) -> some View {
        HStack(spacing: 8) {
            if section.id == "pinned" {
                Image(systemName: "pin.fill").font(.caption2)
            } else if let key = section.botKey, key != "group" {
                avatar(botKey: key, size: 18)
            } else {
                Image(systemName: "person.3.fill").font(.caption2)
            }
            Text(section.title)
            Text("\(section.entries.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ entry: Entry) -> some View {
        Button {
            Task {
                if let room = entry.groupRoom {
                    await vm.openGroupRoom(room)
                } else if let session = entry.session {
                    vm.selectedBotFilter = entry.botKey
                    await vm.resumeSession(session)
                } else if let id = entry.id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: true).last {
                    await vm.selectChat(String(id))
                }
                vm.showSidebar = false
                dismiss()
            }
        } label: {
            HStack(spacing: 12) {
                if entry.groupRoom != nil {
                    Image(systemName: "person.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(HermesTheme.rowHover))
                } else {
                    avatar(botKey: entry.botKey, size: 38)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if entry.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        if entry.isActive {
                            Circle().fill(.green).frame(width: 7, height: 7)
                        }
                        Spacer(minLength: 0)
                        if let date = entry.date {
                            Text(date, format: .dateTime.day().month().hour().minute())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let preview = entry.preview, !preview.isEmpty {
                        Text(preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 6) {
                        badge(entry.groupRoom != nil ? "Grupo · \(entry.botName)" : entry.botName,
                              systemImage: entry.groupRoom != nil ? "person.3.fill" : "cpu")
                        if let g = entry.group, entry.groupRoom == nil {
                            badge(g.name, systemImage: "person.3.fill")
                        }
                        if entry.isOpen {
                            badge("Aberta", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button {
                if let session = entry.session {
                    Task { await vm.setSessionPinned(session, pinned: !entry.isPinned) }
                } else {
                    vm.togglePin(entry.pinID)
                }
            } label: {
                Label(entry.isPinned ? "Desafixar" : "Fixar", systemImage: entry.isPinned ? "pin.slash" : "pin")
            }
            .tint(.yellow)
        }
    }

    private func badge(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(HermesTheme.rowHover))
            .foregroundStyle(.secondary)
    }

    private func avatar(botKey: String, size: CGFloat) -> some View {
        let profile = vm.profilesByName[botKey]
            ?? vm.profilesByName.values.first(where: { AgentProfileInfo.isDefaultProfileName(botKey) && $0.isDefault })
        let accent = Color.hermesAccent(hex: profile?.accentHex, fallbackKey: botKey)
        return Group {
            if let data = vm.avatarData(for: profile?.name ?? botKey), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(accent)
                    Text(AgentProfileInfo.initials(from: vm.displayName(forBotKey: botKey)))
                        .font(.system(size: size * 0.36, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
