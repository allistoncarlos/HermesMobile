import SwiftUI
import UIKit

// ============================================================================
//  MessageBubbleView — renderiza uma mensagem do chat (usuario / assistente /
//  sistema), com markdown, bloco de raciocínio e chips de ferramentas.
// ============================================================================

struct MessageBubbleView: View {
    let message: ChatMessage
    /// Status de atividade do turno (upload, pensando, ferramenta…).
    var activityText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.role {
            case .user:
                HStack {
                    Spacer(minLength: 48)
                    VStack(alignment: .trailing, spacing: 6) {
                        if !message.attachments.isEmpty {
                            MessageAttachmentsView(attachments: message.attachments)
                        }
                        if !message.text.isEmpty {
                            Text(message.text)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.accentColor)
                                .foregroundStyle(.white)
                                .cornerRadius(18, corners: [.topLeft, .topRight, .bottomLeft])
                                .textSelection(.enabled)
                        }
                    }
                }

            case .assistant:
                VStack(alignment: .leading, spacing: 8) {
                    reasoningBlock
                    if showThinkingPlaceholder {
                        thinkingIndicator
                    }
                    if !message.text.isEmpty {
                        MarkdownText(message.text + streamingCursor)
                            .textSelection(.enabled)
                    }
                    toolsRow
                }
                .padding(.horizontal, 2)

            case .system:
                Text(message.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
        }
    }

    private var streamingCursor: String {
        message.isStreaming ? "▍" : ""
    }

    /// Placeholder enquanto o servidor trabalha e ainda não há texto na bolha.
    private var showThinkingPlaceholder: Bool {
        message.isStreaming
            && message.text.isEmpty
            && message.tools.isEmpty
            && (message.reasoning ?? "").isEmpty
    }

    private var thinkingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(activityText ?? "Pensando…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemBackground))
        )
        .accessibilityLabel(activityText ?? "Pensando")
    }

    @ViewBuilder
    private var reasoningBlock: some View {
        if let reasoning = message.reasoning, !reasoning.isEmpty {
            ReasoningIndicator(
                text: reasoning,
                isStreaming: message.isStreaming && message.text.isEmpty
            )
        }
    }

    @ViewBuilder
    private var toolsRow: some View {
        if !message.tools.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 6) {
                ForEach(message.tools) { tool in
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: tool.status))
                            .foregroundStyle(color(for: tool.status))
                        Text(tool.name)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(.tertiarySystemBackground)))
                }
            }
        }
    }

    private func icon(for status: String) -> String {
        switch status {
        case "running": return "ellipsis"
        case "done": return "checkmark.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "wrench.and.screwdriver"
        }
    }
    private func color(for status: String) -> Color {
        switch status {
        case "running": return .orange
        case "done": return .green
        case "error": return .red
        default: return .secondary
        }
    }
}

// ============================================================================
//  ReasoningIndicator — bloco de raciocínio com estado ao vivo.
// ============================================================================

private struct ReasoningIndicator: View {
    let text: String
    let isStreaming: Bool

    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
                Label(
                    isStreaming ? "Raciocinando…" : "Raciocínio",
                    systemImage: "brain"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
        .onAppear {
            if isStreaming { expanded = true }
        }
        .onChange(of: isStreaming) { _, streaming in
            if streaming { expanded = true }
        }
    }
}

// ============================================================================
//  MessageAttachmentsView — thumbnails / chips de anexos na bolha do usuário.
// ============================================================================

private struct MessageAttachmentsView: View {
    let attachments: [ChatAttachment]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(attachments) { attachment in
                if attachment.kind == .image, let preview = attachment.previewData {
                    AttachmentThumbnail(data: preview, cornerRadius: 14)
                        .frame(width: 180, height: 180)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: attachment.isVideo
                              ? "video.fill"
                              : (attachment.isPDF ? "doc.richtext.fill" : "doc.fill"))
                        Text(attachment.filename)
                            .lineLimit(1)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

// ============================================================================
//  MarkdownText — renderiza markdown inline via AttributedString,
//  preservando quebras de linha (o parser .full trata \n como soft break
//  e o Text do SwiftUI acaba colapsando tudo numa única linha).
// ============================================================================

struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(attributed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var attributed: AttributedString {
        Self.attributed(from: text)
    }

    /// Converte o texto do assistente em AttributedString com markdown inline
    /// e quebras de linha literais (uma por `\n` no texto original).
    static func attributed(from raw: String) -> AttributedString {
        let normalized = normalize(raw)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace

        // Parse por linha + `\n` explícito: evita soft-breaks do markdown .full
        // e garante que cada quebra do servidor apareça no Text.
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            let piece = String(line)
            if let parsed = try? AttributedString(markdown: piece, options: options) {
                result.append(parsed)
            } else {
                result.append(AttributedString(piece))
            }
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    /// Normaliza CRLF/CR para LF para o markdown e o Text tratarem as quebras igual.
    private static func normalize(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}

// ============================================================================
//  Corner rounding helper
// ============================================================================

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
