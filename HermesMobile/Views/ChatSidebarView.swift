import SwiftUI

// ============================================================================
//  ChatSidebarView — lista de chats abertos + histórico do servidor.
// ============================================================================

struct ChatSidebarView: View {
    @EnvironmentObject private var vm: HermesViewModel

    var body: some View {
        List {
            Section {
                Button {
                    Task { await vm.newSession() }
                } label: {
                    Label("Nova conversa", systemImage: "square.and.pencil")
                }
            }

            if !vm.openChats.isEmpty {
                Section("Abertas") {
                    ForEach(vm.openChats) { chat in
                        Button {
                            Task { await vm.selectChat(chat.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(chat.title.isEmpty ? "Nova conversa" : chat.title)
                                        .font(.body)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    if chat.isStreaming {
                                        Text("Respondendo…")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if chat.needsAttention || chat.pendingApproval != nil || chat.hasPendingClarify {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 8, height: 8)
                                } else if chat.id == vm.activeChatID {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if vm.openChats.count > 1 {
                                Button(role: .destructive) {
                                    vm.closeChat(chat.id)
                                } label: {
                                    Label("Fechar", systemImage: "xmark")
                                }
                            }
                        }
                    }
                }
            }

            Section("Histórico") {
                if vm.sessions.isEmpty {
                    Text("Nenhuma conversa salva ainda.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.sessions) { session in
                        Button {
                            Task { await vm.resumeSession(session) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(session.title.isEmpty ? "(sem título)" : session.title)
                                        .font(.body)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    if session.isActive {
                                        Circle().fill(.green).frame(width: 8, height: 8)
                                    }
                                }
                                if let date = session.startedAt {
                                    Text(date, format: .dateTime.day().month().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Conversas")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await vm.loadSessions()
        }
        .task {
            await vm.loadSessions()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fechar") { vm.showSidebar = false }
            }
        }
    }
}
