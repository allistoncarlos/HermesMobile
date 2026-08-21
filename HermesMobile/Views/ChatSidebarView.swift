import SwiftUI

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

    /// Histórico sem duplicar as que já estão em Abertas.
    private var historySessions: [SessionSummary] {
        let openStored = Set(vm.openChats.compactMap(\.storedSessionID))
        let openIDs = Set(vm.openChats.map(\.id))
        return vm.sessions.filter { !openStored.contains($0.id) && !openIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List {
                Section {
                    newChatButton
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                if !meaningfulOpenChats.isEmpty {
                    Section("Abertas") {
                        ForEach(meaningfulOpenChats) { chat in
                            openChatRow(chat)
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

                Section("Histórico") {
                    if historySessions.isEmpty {
                        Text("Nenhuma conversa salva ainda.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(historySessions) { session in
                            historyRow(session)
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
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable {
                await vm.loadSessions()
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
            Task { await vm.newSession() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.body.weight(.medium))
                Text("Nova conversa")
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
            Task { await vm.resumeSession(session) }
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
