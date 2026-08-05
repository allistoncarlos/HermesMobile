import SwiftUI

// ============================================================================
//  ChatView — conversa estilo ChatGPT com chats simultâneos e sidebar.
// ============================================================================

struct ChatView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if vm.openChats.count > 1 {
                openChatsStrip
                Divider()
            }
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(vm.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    vm.showSidebar = true
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "list.bullet")
                        if vm.hasAttentionElsewhere {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                                .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let model = vm.sessionModel {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Menu {
                    Button {
                        Task { await vm.newSession() }
                    } label: {
                        Label("Nova conversa", systemImage: "square.and.pencil")
                    }
                    Button {
                        vm.showSidebar = true
                    } label: {
                        Label("Todas as conversas", systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { await vm.logout() }
                    } label: {
                        Label("Sair", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    Button(role: .destructive) {
                        vm.disconnect()
                    } label: {
                        Label("Trocar de servidor", systemImage: "network")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $vm.showSidebar) {
            NavigationStack {
                ChatSidebarView()
            }
        }
    }

    // MARK: - Faixa de chats abertos

    private var openChatsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.openChats) { chat in
                    Button {
                        Task { await vm.selectChat(chat.id) }
                    } label: {
                        HStack(spacing: 6) {
                            if chat.isStreaming {
                                ProgressView().controlSize(.mini)
                            }
                            Text(chat.title.isEmpty ? "Nova" : chat.title)
                                .font(.caption.weight(chat.id == vm.activeChatID ? .semibold : .regular))
                                .lineLimit(1)
                            if chat.needsAttention || chat.pendingApproval != nil {
                                Circle().fill(.red).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(chat.id == vm.activeChatID
                                      ? Color.accentColor.opacity(0.18)
                                      : Color(.secondarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task { await vm.newSession() }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .padding(8)
                        .background(Circle().fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Lista de mensagens

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    if vm.messages.isEmpty {
                        emptyState
                    }
                    ForEach(vm.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                    if let status = vm.toolStatusText {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(status).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: vm.messages.count) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.messages.last?.text) { _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.activeChatID) { _ in
                scrollToBottom(proxy)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Fale com seu Hermes")
                .font(.headline)
            Text("O agente pode usar ferramentas, acessar o terminal e executar tarefas no servidor. Abra várias conversas ao mesmo tempo pela lista.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.vertical, 60)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = vm.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: - Barra de entrada

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let approval = vm.pendingApproval {
                ApprovalBanner(approval: approval) { allow in
                    Task { await vm.respondApproval(allow: allow) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(vm.hasPendingClarify ? "Resposta…" : "Mensagem", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))

                Button {
                    sendOrStop()
                } label: {
                    Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
                .disabled(!vm.canSend && !vm.isStreaming)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .padding(.top, 6)
    }

    private func sendOrStop() {
        inputFocused = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if vm.isStreaming {
            Task { await vm.stopStreaming() }
            return
        }
        guard !text.isEmpty else { return }
        draft = ""
        Task { await vm.send(text) }
    }
}

// ============================================================================
//  ApprovalBanner — pedido de aprovação do agente.
// ============================================================================

struct ApprovalBanner: View {
    let approval: PendingApproval
    let onRespond: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("O agente precisa de aprovação", systemImage: "exclamationmark.shield.fill")
                .font(.subheadline.weight(.semibold))
            Text(approval.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Recusar") { onRespond(false) }
                    .buttonStyle(.bordered)
                Button("Permitir") { onRespond(true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}
