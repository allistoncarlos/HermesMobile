import SwiftUI
import UIKit

// ============================================================================
//  MessageBubbleView — renderiza uma mensagem do chat (usuario / assistente /
//  sistema), com markdown, bloco de raciocínio e chips de ferramentas.
// ============================================================================

struct MessageBubbleView: View {
    let message: ChatMessage

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

    @ViewBuilder
    private var reasoningBlock: some View {
        if let reasoning = message.reasoning, !reasoning.isEmpty {
            DisclosureGroup {
                Text(reasoning)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } label: {
                Label("Raciocínio", systemImage: "brain")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemBackground)))
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
//  MessageAttachmentsView — thumbnails / chips de anexos na bolha do usuário.
// ============================================================================

private struct MessageAttachmentsView: View {
    let attachments: [ChatAttachment]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(attachments) { attachment in
                if attachment.kind == .image,
                   let preview = attachment.previewData,
                   let uiImage = UIImage(data: preview) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 180, height: 180)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: attachment.isPDF ? "doc.richtext.fill" : "doc.fill")
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
//  MarkdownText — renderiza markdown leve via AttributedString.
// ============================================================================

struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        if #available(iOS 15.0, *) {
            if let attr = try? AttributedString(markdown: text) {
                Text(attr)
            } else {
                Text(text)
            }
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
        let path = UIBezierPath(roundedRect: rect,
                                byRoundingCorners: corners,
                                cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
