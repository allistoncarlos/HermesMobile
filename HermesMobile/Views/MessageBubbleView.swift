import SwiftUI
import UIKit

// ============================================================================
//  MessageBubbleView — mensagens estilo ChatGPT:
//  usuário à direita em bolha cinza; assistente à esquerda com avatar.
// ============================================================================

struct MessageBubbleView: View {
    let message: ChatMessage
    /// Status de atividade do turno (upload, pensando, ferramenta…).
    var activityText: String? = nil
    var isCompact: Bool = false

    var body: some View {
        switch message.role {
        case .user:
            userRow
        case .assistant:
            assistantRow
        case .system:
            Text(message.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }


    private var userRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: isCompact ? 36 : 56)
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachments.isEmpty {
                    MessageAttachmentsView(attachments: message.attachments)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(HermesTheme.userBubble)
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: HermesTheme.bubbleCorner, style: .continuous))
                        .textSelection(.enabled)
                }
            }
        }
    }


    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 12) {
            assistantAvatar
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                reasoningBlock
                if showThinkingPlaceholder {
                    thinkingIndicator
                }
                if !message.text.isEmpty {
                    MarkdownText(message.text + streamingCursor)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                toolsRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var assistantAvatar: some View {
        ZStack {
            Circle()
                .fill(HermesTheme.assistantAvatarFill)
                .frame(width: HermesTheme.avatarSize, height: HermesTheme.avatarSize)
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HermesTheme.assistantAvatarForeground)
        }
        .accessibilityHidden(true)
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
            FlowToolChips(tools: message.tools)
        }
    }
}

// ============================================================================
//  FlowToolChips — chips de ferramentas em wrap simples.
// ============================================================================

private struct FlowToolChips: View {
    let tools: [ToolCall]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tools) { tool in
                HStack(spacing: 4) {
                    Image(systemName: icon(for: tool.status))
                        .foregroundStyle(color(for: tool.status))
                    Text(tool.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                )
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

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
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
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(HermesTheme.userBubble)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

// ============================================================================
//  MarkdownText — renderiza markdown leve via AttributedString.
// ============================================================================

struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if let attr = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
        } else {
            Text(text)
        }
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
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
