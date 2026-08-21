import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// ============================================================================
//  ChatView — conversa estilo ChatGPT: header limpo, mensagens centralizadas,
//  composer flutuante. Adaptado a iPhone (retrato/paisagem) e iPad.
// ============================================================================

struct ChatView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var onToggleSidebar: (() -> Void)?

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
        GeometryReader { geo in
            let metrics = HermesLayoutMetrics(size: geo.size, horizontalSizeClass: horizontalSizeClass)

            VStack(spacing: 0) {
                chatHeader(metrics: metrics)
                messageList(metrics: metrics)
                composer(metrics: metrics)
            }
            .background(HermesTheme.chatBackground.ignoresSafeArea())
        }
        .navigationBarHidden(true)
        .fullScreenCover(isPresented: $voice.isPresented) {
            VoiceModeView(voice: voice)
                .environmentObject(vm)
        }
        .onAppear {
            voice.attach(vm)
            vm.onAssistantMessageComplete = { text in
                voice.speakServerPush(text)
            }
            Task { await fulfillSiriVoiceLaunchIfNeeded() }
            fulfillSiriVoiceStopIfNeeded()
        }
        .onChange(of: vm.connectionState) { _, _ in
            Task { await fulfillSiriVoiceLaunchIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesStartVoice)) { _ in
            Task { await fulfillSiriVoiceLaunchIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesStopVoice)) { _ in
            fulfillSiriVoiceStopIfNeeded()
        }
        .confirmationDialog("Anexar", isPresented: $showAttachOptions, titleVisibility: .visible) {
            Button("Fotos e vídeos") { showPhotosPicker = true }
            Button("Arquivos") { showFileImporter = true }
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


    private func chatHeader(metrics: HermesLayoutMetrics) -> some View {
        HStack(spacing: 12) {
            Button {
                openSidebar()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(HermesTheme.rowHover))
                    if vm.hasAttentionElsewhere {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .offset(x: 2, y: 2)
                    }
                }
            }
            .accessibilityLabel("Conversas")

            VStack(spacing: 1) {
                Text(vm.sessionTitle)
                    .font(metrics.isLandscape ? .subheadline.weight(.semibold) : .headline)
                    .lineLimit(1)
                if let model = vm.sessionModel, !metrics.isLandscape {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await vm.newSession() }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(HermesTheme.rowHover))
            }
            .accessibilityLabel("Nova conversa")

            Menu {
                Button {
                    Task { await vm.newSession() }
                } label: {
                    Label("Nova conversa", systemImage: "square.and.pencil")
                }
                Button {
                    openSidebar()
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
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(HermesTheme.rowHover))
            }
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.vertical, metrics.isLandscape ? 6 : 10)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }


    private func messageList(metrics: HermesLayoutMetrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: metrics.messageSpacing) {
                    if vm.messages.isEmpty {
                        emptyState(metrics: metrics)
                    }
                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { index, message in
                        let isLastAssistant = message.role == .assistant
                            && index == vm.messages.lastIndex(where: { $0.role == .assistant })
                        MessageBubbleView(
                            message: message,
                            activityText: isLastAssistant ? vm.toolStatusText : nil,
                            isCompact: metrics.isLandscape && !metrics.isRegularWidth
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.vertical, metrics.isLandscape ? 8 : 14)
                .frame(maxWidth: HermesTheme.chatMaxWidth)
                .frame(maxWidth: .infinity)
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

    private func emptyState(metrics: HermesLayoutMetrics) -> some View {
        VStack(spacing: metrics.isLandscape ? 8 : 14) {
            Image(systemName: "sparkles")
                .font(.system(size: metrics.isLandscape ? 28 : 40, weight: .medium))
                .foregroundStyle(.primary)
            Text("Como posso ajudar?")
                .font(metrics.isLandscape ? .title3.weight(.semibold) : .title2.weight(.semibold))
            if !metrics.isLandscape {
                Text("Pergunte qualquer coisa. O Hermes pode usar ferramentas e executar tarefas no servidor.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, metrics.emptyStateTopPadding)
        .padding(.bottom, 20)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = vm.messages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }


    private func composer(metrics: HermesLayoutMetrics) -> some View {
        VStack(spacing: 8) {
            if let approval = vm.pendingApproval {
                ChatColumn {
                    ApprovalBanner(approval: approval) { allow in
                        Task { await vm.respondApproval(allow: allow) }
                    }
                }
                .padding(.horizontal, metrics.horizontalPadding)
            }

            if !pendingAttachments.isEmpty {
                attachmentStrip
                    .padding(.horizontal, metrics.horizontalPadding)
            }

            ChatColumn {
                HStack(alignment: .bottom, spacing: 8) {
                    attachButton

                    TextField(
                        vm.hasPendingClarify ? "Resposta…" : "Pergunte qualquer coisa",
                        text: $draft,
                        axis: .vertical
                    )
                    .lineLimit(1...(metrics.isLandscape ? 3 : 6))
                    .focused($inputFocused)
                    .padding(.vertical, metrics.isLandscape ? 8 : 10)

                    if showVoiceButton {
                        Button {
                            inputFocused = false
                            voice.attach(vm)
                            voice.present()
                        } label: {
                            Image(systemName: "waveform")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 34, height: 34)
                        }
                        .disabled(!vm.canSend)
                        .accessibilityLabel("Modo de voz")
                    } else {
                        Button {
                            sendOrStop()
                        } label: {
                            Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle().fill(
                                        vm.isStreaming
                                            ? Color.primary
                                            : Color.accentColor
                                    )
                                )
                        }
                        .disabled((!vm.canSend && !vm.isStreaming) || (isSending && !vm.isStreaming))
                        .accessibilityLabel(vm.isStreaming ? "Parar" : "Enviar")
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: HermesTheme.composerCorner, style: .continuous)
                        .fill(HermesTheme.composerFill)
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: HermesTheme.composerCorner, style: .continuous)
                        .strokeBorder(HermesTheme.composerStroke, lineWidth: 1)
                )
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.bottom, metrics.composerBottomPadding)
        }
        .padding(.top, 6)
        .background(HermesTheme.chatBackground)
    }

    private var attachButton: some View {
        Button {
            inputFocused = false
            showAttachOptions = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
        }
        .disabled(!vm.canSend || vm.isStreaming || vm.hasPendingClarify || isSending)
        .accessibilityLabel("Anexar")
    }

    private var attachmentStrip: some View {
        ChatColumn {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pendingAttachments) { attachment in
                        AttachmentChip(attachment: attachment) {
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
            }
        }
    }

    private var showVoiceButton: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && pendingAttachments.isEmpty
            && !vm.isStreaming
            && !isSending
    }

    private func openSidebar() {
        if let onToggleSidebar {
            onToggleSidebar()
        } else {
            vm.showSidebar = true
        }
    }

    /// Siri / App Shortcut: nova sessão + modo voz.
    private func fulfillSiriVoiceLaunchIfNeeded() async {
        guard HermesLaunchActions.shared.wantsVoiceSession else { return }
        guard case .connected = vm.connectionState else { return }
        HermesLaunchActions.shared.clearVoiceRequest()
        inputFocused = false
        await vm.newSession()
        voice.attach(vm)
        voice.present()
    }

    private func fulfillSiriVoiceStopIfNeeded() {
        guard HermesLaunchActions.shared.wantsStopVoice else { return }
        HermesLaunchActions.shared.clearStopRequest()
        voice.dismiss()
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
