import SwiftUI

// ============================================================================
//  HermesTheme — tokens visuais no estilo ChatGPT + helpers de layout
//  adaptativo (iPhone retrato/paisagem e iPad).
// ============================================================================

enum HermesTheme {
    /// Largura máxima da coluna de mensagens / composer (estilo ChatGPT web).
    static let chatMaxWidth: CGFloat = 768
    /// Largura ideal da sidebar no iPad.
    static let sidebarIdeal: CGFloat = 280
    static let sidebarMin: CGFloat = 240
    static let sidebarMax: CGFloat = 340

    static let composerCorner: CGFloat = 28
    static let bubbleCorner: CGFloat = 20
    static let avatarSize: CGFloat = 28

    static var drawerSpring: Animation {
        .interactiveSpring(response: 0.32, dampingFraction: 0.86, blendDuration: 0.12)
    }

    /// Fundo da área de chat.
    static var chatBackground: Color {
        Color(uiColor: .systemBackground)
    }

    /// Fundo da sidebar (ligeiramente distinto, como no ChatGPT).
    static var sidebarBackground: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
                : UIColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1)
        })
    }

    /// Bolha do usuário (cinza suave, não azul WhatsApp).
    static var userBubble: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1)
                : UIColor(red: 0.95, green: 0.95, blue: 0.94, alpha: 1)
        })
    }

    static var composerFill: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1)
                : UIColor.systemBackground
        })
    }

    static var composerStroke: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.10)
        })
    }

    static var rowHover: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.06)
                : UIColor.black.withAlphaComponent(0.04)
        })
    }

    static var assistantAvatarFill: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.92, alpha: 1)
                : UIColor(white: 0.12, alpha: 1)
        })
    }

    static var assistantAvatarForeground: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.12, alpha: 1)
                : UIColor.white
        })
    }

    static func speakerAccent(for key: String) -> Color {
        Color.hermesAccent(hex: nil, fallbackKey: key)
    }
}


struct HermesLayoutMetrics {
    let isLandscape: Bool
    let isRegularWidth: Bool
    let horizontalPadding: CGFloat
    let messageSpacing: CGFloat
    let composerBottomPadding: CGFloat
    let emptyStateTopPadding: CGFloat

    init(size: CGSize, horizontalSizeClass: UserInterfaceSizeClass?) {
        let landscape = size.width > size.height
        let regular = horizontalSizeClass == .regular
        isLandscape = landscape
        isRegularWidth = regular

        if regular {
            horizontalPadding = 24
            messageSpacing = 22
            composerBottomPadding = 12
            emptyStateTopPadding = 48
        } else if landscape {
            horizontalPadding = 16
            messageSpacing = 14
            composerBottomPadding = 4
            emptyStateTopPadding = 16
        } else {
            horizontalPadding = 16
            messageSpacing = 18
            composerBottomPadding = 8
            emptyStateTopPadding = 40
        }
    }
}

/// Centraliza conteúdo até `HermesTheme.chatMaxWidth`.
struct ChatColumn<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: HermesTheme.chatMaxWidth)
            .frame(maxWidth: .infinity)
    }
}
