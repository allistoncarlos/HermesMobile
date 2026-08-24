import SwiftUI
import UIKit

// ============================================================================
//  ChatSidebarView — sidebar estilo ChatGPT com List + swipeActions nativos
//  (arquivar / excluir). Uma única “nova conversa” ativa.
// ============================================================================

struct ChatSidebarView: View {
    @EnvironmentObject private var vm: HermesViewModel
    /// Quando embutida no shell, não mostra botão Fechar.
    var isEmbedded: Bool = false

    @State private var pendingDelete: PendingDelete?

    private struct PendingDelete: Identifiable {
        let id: String
        let title: String
        let isOpenChat: Bool
        let openChat: OpenChat?
    }

    /// Abertas com conteúdo (em branco não polui a lista — “Nova conversa” já cobre).
    private var meaningfulOpenChats: [OpenChat] {
        vm.openChats.filter { !HermesViewModel.isBlankChat($0) }
    }

    /// Histórico sem duplicar as que já estão em Abertas, opcionalmente só de um bot.
    private var historySessions: [SessionSummary] {
        let openStored = Set(vm.openChats.compactMap(\.storedSessionID))
        let openIDs = Set(vm.openChats.map(\.id))
        let all = vm.sessions.filter { !openStored.contains($0.id) && !openIDs.contains($0.id) }
        guard let filter = vm.selectedBotFilter else { return all }
        return all.filter { session in
            let key = vm.botKey(for: session)
            if AgentProfileInfo.isDefaultProfileName(filter) {
                return key == "default" || AgentProfileInfo.isDefaultProfileName(key)
            }
            return key == filter
        }
    }

    private var pinnedItems: [DrawerPinItem] {
        vm.effectivePinnedIDs.compactMap { id in
            if let room = vm.groupRooms.first(where: { $0.id == id }) {
                return DrawerPinItem(id: id, title: room.name, subtitle: room.preview ?? "Grupo", kind: .group, room: room, bot: nil, session: nil)
            }
            if id.hasPrefix("bot::"),
               let bot = vm.drawerBots.first(where: { vm.pinKey(forBot: $0.name) == id }) {
                return DrawerPinItem(id: id, title: bot.displayName, subtitle: bot.lastPreview ?? bot.summary ?? "Bot", kind: .bot, room: nil, bot: bot, session: nil)
            }
            if let chat = vm.openChats.first(where: { $0.id == id || $0.storedSessionID == id }) {
                return DrawerPinItem(id: id, title: chat.title, subtitle: chat.subtitle ?? "Conversa", kind: .direct, room: nil, bot: nil, session: nil)
            }
            if let session = vm.sessions.first(where: { $0.id == id }) {
                return DrawerPinItem(id: id, title: session.title, subtitle: session.preview ?? "Conversa", kind: .direct, room: nil, bot: nil, session: session)
            }
            return nil
        }
    }

    private var unpinnedGroupRooms: [GroupRoom] {
        vm.groupRooms.filter { !vm.isPinned($0.id) }
    }

    private struct HistoryGroup: Identifiable {
        let id: String
        let title: String
        let bot: AgentProfileInfo?
        let sessions: [SessionSummary]
    }

    private var historyGroups: [HistoryGroup] {
        var buckets: [String: [SessionSummary]] = [:]
        var order: [String] = []
        for session in historySessions {
            let key = vm.botKey(for: session)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(session)
        }
        return order.map { key in
            HistoryGroup(
                id: key,
                title: vm.displayName(forBotKey: key),
                bot: vm.profilesByName[key] ?? vm.profilesByName.values.first(where: {
                    AgentProfileInfo.isDefaultProfileName(key) && $0.isDefault
                }),
                sessions: buckets[key] ?? []
            )
        }
    }

    private func pinButton(_ id: String) -> some View {
        Button {
            vm.togglePin(id)
        } label: {
            Label(vm.isPinned(id) ? "Desafixar" : "Fixar", systemImage: vm.isPinned(id) ? "pin.slash" : "pin")
        }
        .tint(.yellow)
    }

    private func drawerRow(_ item: DrawerPinItem) -> some View {
        Button {
            Task {
                if let room = item.room { await vm.openGroupRoom(room) }
                else if let bot = item.bot { await vm.openBotProfile(bot) }
                else if let session = item.session { await vm.resumeSession(session) }
                else { await vm.selectChat(item.id) }
            }
        } label: {
            conversationRow(
                title: item.title,
                subtitle: item.subtitle,
                systemImage: item.kind == .group ? "person.3.fill" : (item.kind == .bot ? "cpu" : "pin.fill"),
                isActive: vm.activeChatID == item.id
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) { pinButton(item.id) }
        .listRowBackground(vm.activeChatID == item.id ? HermesTheme.rowHover : Color.clear)
    }

    private func groupRow(_ room: GroupRoom) -> some View {
        Button {
            Task { await vm.openGroupRoom(room) }
        } label: {
            conversationRow(
                title: room.name,
                subtitle: room.preview ?? room.members.map(\.displayName).joined(separator: ", "),
                systemImage: "person.3.fill",
                isActive: vm.activeChatID == room.id,
                showPin: vm.isPinned(room.id)
            )
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) { pinButton(room.id) }
        .listRowBackground(vm.activeChatID == room.id ? HermesTheme.rowHover : Color.clear)
    }

    private var botsStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bots")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if vm.selectedBotFilter != nil {
                    Button("Todos") {
                        vm.selectedBotFilter = nil
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(vm.drawerBots) { bot in
                        botAvatarButton(bot)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func isBotActive(_ bot: AgentProfileInfo) -> Bool {
        let filter = vm.filterKey(for: bot)
        if vm.selectedBotFilter == filter { return true }
        let key = vm.pinKey(forBot: bot.name)
        if vm.activeChatID == key { return true }
        guard let chat = vm.openChats.first(where: { $0.id == vm.activeChatID }) else { return false }
        if chat.kind == .bot {
            return chat.id == key || chat.title.caseInsensitiveCompare(bot.displayName) == .orderedSame
        }
        if bot.isDefault || AgentProfileInfo.isDefaultProfileName(bot.name) {
            return chat.kind == .direct && vm.selectedBotFilter == nil
        }
        return false
    }

    private func botAvatarButton(_ bot: AgentProfileInfo) -> some View {
        let active = isBotActive(bot)
        let accent = Color.hermesAccent(hex: bot.accentHex, fallbackKey: bot.name)
        return Button {
            Task { await vm.openBotProfile(bot) }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(accent, lineWidth: active ? 2.5 : 1.5)
                        .frame(width: 56, height: 56)
                    botAvatarImage(bot, size: 48)
                }
                Text(bot.displayName)
                    .font(.caption2.weight(active ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 64)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .contextMenu {
            pinButton(vm.pinKey(forBot: bot.name))
        }
        .accessibilityLabel("Abrir chat com \(bot.displayName)")
    }

    private func botAvatarImage(_ bot: AgentProfileInfo, size: CGFloat) -> some View {
        Group {
            if let data = vm.avatarData(for: bot.name), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.hermesAccent(hex: bot.accentHex, fallbackKey: bot.name))
                    Text(AgentProfileInfo.initials(from: bot.displayName))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func historyHeader(_ group: HistoryGroup) -> some View {
        HStack(spacing: 8) {
            if let bot = group.bot {
                botAvatarImage(bot, size: 18)
            } else {
                Image(systemName: "clock")
                    .font(.caption2)
            }
            Text(group.title)
            Text("\(group.sessions.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func conversationRow(
        title: String,
        subtitle: String?,
        systemImage: String,
        isActive: Bool,
        avatarKey: String? = nil,
        showPin: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            if let avatarKey, let data = vm.avatarData(for: avatarKey), let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(Circle())
            } else {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(HermesTheme.rowHover))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if showPin {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isActive {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }


    var body: some View {
        VStack(spacing: 0) {
            header
            if !vm.drawerBots.isEmpty {
                botsStrip
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            List {
                Section {
                    newChatButton
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !pinnedItems.isEmpty {
                    Section("Fixadas") {
                        ForEach(pinnedItems) { item in
                            drawerRow(item)
                        }
                    }
                }

                if !unpinnedGroupRooms.isEmpty {
                    Section("Chats em grupo") {
                        ForEach(unpinnedGroupRooms) { room in
                            groupRow(room)
                        }
                    }
                }

                if !meaningfulOpenChats.isEmpty {
                    Section("Abertas") {
                        ForEach(meaningfulOpenChats) { chat in
                            openChatRow(chat)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    pinButton(vm.isPinned(chat.id) ? chat.id : chat.storedSessionID ?? chat.id)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        pendingDelete = PendingDelete(
                                            id: chat.storedSessionID ?? chat.id,
                                            title: chat.title.isEmpty ? "Nova conversa" : chat.title,
                                            isOpenChat: true,
                                            openChat: chat
                                        )
                                    } label: {
                                        Label("Excluir", systemImage: "trash")
                                    }
                                    Button {
                                        Task { await vm.archiveOpenChat(chat) }
                                    } label: {
                                        Label("Arquivar", systemImage: "archivebox")
                                    }
                                    .tint(.orange)
                                }
                        }
                    }
                }

                if historySessions.isEmpty {
                    Section("Histórico") {
                        Text(vm.selectedBotFilter == nil
                             ? "Nenhuma conversa salva ainda."
                             : "Nenhuma conversa com \(vm.displayName(forBotKey: vm.selectedBotFilter ?? "")).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(historyGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                historyRow(session)
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        pinButton(session.id)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            pendingDelete = PendingDelete(
                                                id: session.id,
                                                title: session.title.isEmpty ? "Conversa" : session.title,
                                                isOpenChat: false,
                                                openChat: nil
                                            )
                                        } label: {
                                            Label("Excluir", systemImage: "trash")
                                        }
                                        Button {
                                            Task { await vm.archiveSession(storedID: session.id) }
                                        } label: {
                                            Label("Arquivar", systemImage: "archivebox")
                                        }
                                        .tint(.orange)
                                    }
                            }
                        } header: {
                            historyHeader(group)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await vm.loadSessions()
                await vm.refreshRoster()
            }

            Divider()
            footer
        }
        .background(HermesTheme.sidebarBackground.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            await vm.loadSessions()
        }
        .alert(
            "Excluir conversa?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { item in
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
            Button("Excluir", role: .destructive) {
                Task {
                    if item.isOpenChat, let chat = item.openChat {
                        await vm.deleteOpenChat(chat)
                    } else {
                        await vm.deleteSession(storedID: item.id)
                    }
                    pendingDelete = nil
                }
            }
        } message: { item in
            Text("“\(item.title)” será removida permanentemente.")
        }
    }


    private var header: some View {
        HStack {
            Text("Hermes")
                .font(.title3.weight(.semibold))
            Spacer()
            if !isEmbedded {
                Button("Fechar") { vm.showSidebar = false }
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        Menu {
            Button {
                Task { await vm.logout() }
            } label: {
                Label("Sair", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button {
                vm.presentServerSetup()
            } label: {
                Label("Trocar de servidor", systemImage: "network")
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.config.username.isEmpty ? "Conta" : vm.config.username)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(shortServerHost)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shortServerHost: String {
        let raw = vm.config.baseURLString
        if let url = URL(string: raw), let host = url.host {
            return host
        }
        return raw
    }


    private var newChatButton: some View {
        Button {
            Task {
                if let filter = vm.selectedBotFilter, !AgentProfileInfo.isDefaultProfileName(filter) {
                    await vm.newSession(profile: filter)
                } else {
                    await vm.newSession()
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.medium))
                Text(newChatTitle)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(HermesTheme.composerStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var newChatTitle: String {
        guard let filter = vm.selectedBotFilter, !AgentProfileInfo.isDefaultProfileName(filter) else {
            return "Nova conversa"
        }
        return "Nova conversa · \(vm.displayName(forBotKey: filter))"
    }

    private func openChatRow(_ chat: OpenChat) -> some View {
        Button {
            Task { await vm.selectChat(chat.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title.isEmpty ? "Nova conversa" : chat.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if chat.isStreaming {
                        Text("Respondendo…")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if chat.needsAttention || chat.pendingApproval != nil || chat.hasPendingClarify {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                } else if chat.id == vm.activeChatID {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            chat.id == vm.activeChatID ? HermesTheme.rowHover : Color.clear
        )
    }

    private func historyRow(_ session: SessionSummary) -> some View {
        Button {
            Task {
                vm.selectedBotFilter = vm.botKey(for: session)
                await vm.resumeSession(session)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "(sem título)" : session.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if let date = session.startedAt {
                        Text(date, format: .dateTime.day().month().hour().minute())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if session.isActive {
                    Circle().fill(.green).frame(width: 7, height: 7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}
