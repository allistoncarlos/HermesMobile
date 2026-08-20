import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ============================================================================
//  ChatView — conversa estilo ChatGPT com chats simultâneos, sidebar e anexos.
// ============================================================================

struct ChatView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @StateObject private var voice = VoiceModeController()
    @State private var draft: String = ""
    @State private var pendingAttachments: [ChatAttachment] = []
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var showAttachOptions = false
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    @State private var attachError: String?
    @State private var isSending = false
    @FocusState private var inputFocused: Bool

    /// Teto do gateway Hermes (`image.attach_bytes` / `file.attach`).
    private static let maxAttachmentBytes = 25 * 1024 * 1024
    private static let uploadMaxSide: CGFloat = 2048
    private static let previewMaxSide: CGFloat = 360

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
        .fullScreenCover(isPresented: $voice.isPresented) {
            VoiceModeView(voice: voice)
                .environmentObject(vm)
        }
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
                        vm.presentServerSetup()
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
        // PhotosPicker dentro de Menu não abre no iOS — usar confirmationDialog + modifier.
        .confirmationDialog("Anexar", isPresented: $showAttachOptions, titleVisibility: .visible) {
            Button("Fotos e vídeos") {
                showPhotosPicker = true
            }
            Button("Arquivos") {
                showFileImporter = true
            }
            Button("Cancelar", role: .cancel) {}
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoPickerItems,
            maxSelectionCount: 8,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            Task { await handleFileImport(result) }
        }
        .alert("Anexo", isPresented: Binding(
            get: { attachError != nil },
            set: { if !$0 { attachError = nil } }
        )) {
            Button("OK", role: .cancel) { attachError = nil }
        } message: {
            Text(attachError ?? "")
        }
        .onChange(of: photoPickerItems) { _, items in
            Task { await loadLibraryItems(items) }
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
                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { index, message in
                        let isLastAssistant = message.role == .assistant
                            && index == vm.messages.lastIndex(where: { $0.role == .assistant })
                        MessageBubbleView(
                            message: message,
                            activityText: isLastAssistant ? vm.toolStatusText : nil
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .onChange(of: vm.messages.count) { _, _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.messages.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.toolStatusText) { _, status in
                guard status != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    if let last = vm.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.activeChatID) { _, _ in
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

            if !pendingAttachments.isEmpty {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: 10) {
                attachButton

                TextField(vm.hasPendingClarify ? "Resposta…" : "Mensagem", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemBackground)))

                if showVoiceButton {
                    Button {
                        inputFocused = false
                        voice.attach(vm)
                        voice.present()
                    } label: {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 36))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.accentColor)
                    }
                    .disabled(!vm.canSend)
                    .accessibilityLabel("Modo de voz")
                } else {
                    Button {
                        sendOrStop()
                    } label: {
                        Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .background(Circle().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                    .disabled((!vm.canSend && !vm.isStreaming) || (isSending && !vm.isStreaming))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .padding(.top, 6)
    }

    private var attachButton: some View {
        Button {
            inputFocused = false
            showAttachOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .foregroundStyle(Color.accentColor)
        }
        .disabled(!vm.canSend || vm.isStreaming || vm.hasPendingClarify || isSending)
        .accessibilityLabel("Anexar")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pendingAttachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        pendingAttachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var showVoiceButton: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingAttachments.isEmpty
            && !vm.isStreaming
            && !isSending
    }

    private func sendOrStop() {
        inputFocused = false
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if vm.isStreaming {
            Task { await vm.stopStreaming() }
            return
        }
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        isSending = true
        draft = ""
        pendingAttachments = []
        photoPickerItems = []
        Task {
            await vm.send(text, attachments: attachments)
            isSending = false
        }
    }

    // MARK: - Pickers

    private func loadLibraryItems(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        var loaded: [ChatAttachment] = []
        for item in items {
            do {
                if let attachment = try await makeAttachment(from: item) {
                    loaded.append(attachment)
                }
            } catch {
                attachError = "Não foi possível carregar o item da biblioteca."
            }
        }
        pendingAttachments.append(contentsOf: loaded)
        photoPickerItems = []
    }

    private func makeAttachment(from item: PhotosPickerItem) async throws -> ChatAttachment? {
        let isVideo = item.supportedContentTypes.contains {
            $0.conforms(to: .movie) || $0.conforms(to: .video) || $0.conforms(to: .audiovisualContent)
        }

        if isVideo {
            guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                return nil
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: movie.url)
            }.value
            guard data.count <= Self.maxAttachmentBytes else {
                attachError = "O vídeo excede o limite de 25 MB."
                return nil
            }
            let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
            let mime = Self.mimeType(for: movie.url) ?? "video/quicktime"
            return ChatAttachment(
                kind: .file,
                filename: "video-\(UUID().uuidString.prefix(8)).\(ext)",
                mimeType: mime,
                data: data
            )
        }

        guard let data = try await item.loadTransferable(type: Data.self) else {
            return nil
        }
        guard let prepared = await Self.prepareImage(data) else {
            attachError = "Não foi possível processar a imagem."
            return nil
        }
        guard prepared.upload.count <= Self.maxAttachmentBytes else {
            attachError = "A imagem excede o limite de 25 MB."
            return nil
        }
        return ChatAttachment(
            kind: .image,
            filename: "image-\(UUID().uuidString.prefix(8)).jpg",
            mimeType: "image/jpeg",
            data: prepared.upload,
            previewData: prepared.preview
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) async {
        switch result {
        case .failure(let error):
            attachError = error.localizedDescription
        case .success(let urls):
            var loaded: [ChatAttachment] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    let filename = url.lastPathComponent
                    let mime = Self.mimeType(for: url) ?? "application/octet-stream"
                    let isImage = mime.hasPrefix("image/")
                    guard data.count <= Self.maxAttachmentBytes else {
                        attachError = "“\(filename)” excede o limite de 25 MB."
                        continue
                    }
                    if isImage, let prepared = await Self.prepareImage(data) {
                        loaded.append(ChatAttachment(
                            kind: .image,
                            filename: filename,
                            mimeType: "image/jpeg",
                            data: prepared.upload,
                            previewData: prepared.preview
                        ))
                    } else {
                        loaded.append(ChatAttachment(
                            kind: .file,
                            filename: filename,
                            mimeType: mime,
                            data: data
                        ))
                    }
                } catch {
                    attachError = "Não foi possível ler “\(url.lastPathComponent)”."
                }
            }
            pendingAttachments.append(contentsOf: loaded)
        }
    }

    private static func mimeType(for url: URL) -> String? {
        if let ut = UTType(filenameExtension: url.pathExtension),
           let mime = ut.preferredMIMEType {
            return mime
        }
        return nil
    }

    private struct PreparedImage: Sendable {
        let upload: Data
        let preview: Data
    }

    /// Comprime para upload (até 2048px) e gera thumbnail leve separado para a UI.
    private static func prepareImage(_ data: Data) async -> PreparedImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            guard let upload = jpeg(image, maxSide: uploadMaxSide, quality: 0.82) else { return nil }
            let preview = jpeg(image, maxSide: previewMaxSide, quality: 0.7) ?? upload
            return PreparedImage(upload: upload, preview: preview)
        }.value
    }

    private static func jpeg(_ image: UIImage, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}

// ============================================================================
//  PickedMovie — Transferable para vídeos do PhotosPicker.
// ============================================================================

private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try Self.importMovie(from: received.file)
        }
        FileRepresentation(contentType: .mpeg4Movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try Self.importMovie(from: received.file)
        }
        FileRepresentation(contentType: .quickTimeMovie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            try Self.importMovie(from: received.file)
        }
    }

    private static func importMovie(from file: URL) throws -> PickedMovie {
        let ext = file.pathExtension.isEmpty ? "mov" : file.pathExtension
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-video-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: file, to: dest)
        return Self(url: dest)
    }
}

// ============================================================================
//  AttachmentChip — preview compacto de anexo pendente no composer.
// ============================================================================

private struct AttachmentChip: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image, let preview = attachment.previewData {
                    AttachmentThumbnail(data: preview, cornerRadius: 10)
                        .frame(width: 64, height: 64)
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: chipIcon)
                            .font(.title3)
                        Text(attachment.filename)
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: 88, height: 64)
                    .padding(.horizontal, 4)
                }
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .font(.system(size: 18))
            }
            .offset(x: 6, y: -6)
        }
    }

    private var chipIcon: String {
        if attachment.isVideo { return "video.fill" }
        if attachment.isPDF { return "doc.richtext" }
        return "doc.fill"
    }
}

/// Decodifica o JPEG uma vez e reutiliza o `UIImage` entre re-renders do streaming.
struct AttachmentThumbnail: View {
    let data: Data
    var cornerRadius: CGFloat = 14

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.tertiarySystemFill)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: data.count) {
            guard image == nil else { return }
            image = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
        }
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
