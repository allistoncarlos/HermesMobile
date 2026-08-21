import SwiftUI

// ============================================================================
//  ContentView — raiz da navegação.
//  Com URL + senha/cookie/token salvos, NÃO mostra login: restaura ou reconecta.
//  Login só após logout, “trocar servidor” ou credenciais inválidas.
// ============================================================================

struct ContentView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @State private var didAttemptRestore = false

    var body: some View {
        Group {
            switch vm.connectionState {
            case .connected:
                ChatShellView()
            case .connecting where shouldStayOnSessionUI:
                restoreSplash
            case .disconnected where shouldStayOnSessionUI && !didAttemptRestore:
                restoreSplash
            case .disconnected where shouldStayOnSessionUI:
                reconnectPane
            case .failed where shouldStayOnSessionUI:
                reconnectPane
            case .disconnected, .failed, .waitingAuth, .connecting:
                NavigationStack {
                    ServerSetupView()
                }
            }
        }
        .task {
            guard !didAttemptRestore else { return }
            didAttemptRestore = true
            guard vm.config.hasSavedConfig, vm.config.hasRestorableAuth, !vm.needsManualAuth else { return }
            switch vm.connectionState {
            case .disconnected, .connecting:
                await vm.connect()
            default:
                break
            }
        }
    }

    /// Mantém fora do formulário de login enquanto há como reentrar sozinho.
    private var shouldStayOnSessionUI: Bool {
        vm.config.hasSavedConfig
            && vm.config.hasRestorableAuth
            && !vm.needsManualAuth
    }

    private var restoreSplash: some View {
        ZStack {
            HermesTheme.chatBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Entrando…")
                    .font(.headline)
                if !vm.config.baseURLString.isEmpty {
                    Text(vm.config.baseURLString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
        }
    }

    private var reconnectPane: some View {
        ZStack {
            HermesTheme.chatBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                if vm.connectionState == .connecting {
                    ProgressView()
                        .controlSize(.large)
                    Text("Reconectando…")
                        .font(.headline)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("Sem conexão")
                        .font(.headline)
                    if let msg = vm.statusMessage ?? vm.connectionState.failureMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                    }
                    Button {
                        Task { await vm.connect() }
                    } label: {
                        Text("Tentar de novo")
                            .fontWeight(.semibold)
                            .frame(maxWidth: 220)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Trocar servidor") {
                        vm.presentServerSetup()
                    }
                    .font(.subheadline)
                }
            }
        }
        .task(id: reconnectTaskID) {
            guard shouldStayOnSessionUI else { return }
            if case .disconnected = vm.connectionState {
                await vm.connect()
            }
        }
    }

    private var reconnectTaskID: String {
        "\(vm.connectionState)-\(vm.needsManualAuth)"
    }
}

// ============================================================================
//  ChatShellView — iPad: NavigationSplitView. iPhone: drawer com gesto de
//  borda (→ abrir) e deslize para a esquerda (← fechar), padrão iOS.
// ============================================================================

struct ChatShellView: View {
    @EnvironmentObject private var vm: HermesViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadSplit
            } else {
                iPhoneDrawer
            }
        }
    }


    private var iPadSplit: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ChatSidebarView(isEmbedded: true)
                .navigationSplitViewColumnWidth(
                    min: HermesTheme.sidebarMin,
                    ideal: HermesTheme.sidebarIdeal,
                    max: HermesTheme.sidebarMax
                )
        } detail: {
            ChatView(onToggleSidebar: {
                columnVisibility = columnVisibility == .all ? .detailOnly : .all
            })
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            columnVisibility = .all
        }
    }


    private var iPhoneDrawer: some View {
        SidebarDrawer(
            isPresented: $vm.showSidebar,
            width: HermesTheme.sidebarIdeal
        ) {
            ChatSidebarView(isEmbedded: true)
        } content: {
            ChatView(onToggleSidebar: {
                withAnimation(HermesTheme.drawerSpring) {
                    vm.showSidebar.toggle()
                }
            })
        }
        .onChange(of: vm.activeChatID) { _, _ in
            withAnimation(HermesTheme.drawerSpring) {
                vm.showSidebar = false
            }
        }
    }
}

// ============================================================================
//  SidebarDrawer — painel lateral interativo (estilo navigation drawer iOS):
//  • deslizar da borda esquerda → abre
//  • deslizar a sidebar / scrim para a esquerda → fecha
//  • toque no scrim → fecha
// ============================================================================

struct SidebarDrawer<Sidebar: View, Content: View>: View {
    @Binding var isPresented: Bool
    var width: CGFloat
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var content: () -> Content

    /// Deslocamento durante o arraste (negativo = fechando, positivo = abrindo).
    @State private var dragTranslation: CGFloat = 0
    @State private var isDragging = false

    static var spring: Animation { HermesTheme.drawerSpring }

    private let edgeWidth: CGFloat = 24
    private let openThreshold: CGFloat = 0.35
    private let velocityThreshold: CGFloat = 450

    var body: some View {
        GeometryReader { geo in
            let sidebarWidth = min(width, geo.size.width * 0.86)
            let revealed = revealedWidth(sidebarWidth: sidebarWidth)
            let progress = revealed / sidebarWidth

            ZStack(alignment: .leading) {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(progress < 0.05)

                // Scrim — toque ou deslize para fechar
                Color.black
                    .opacity(0.28 * progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(progress > 0.02)
                    .onTapGesture {
                        settle(open: false)
                    }
                    .highPriorityGesture(horizontalDrag(sidebarWidth: sidebarWidth, mode: .close))

                // Sidebar — swipeActions das linhas têm prioridade; fechar pelo scrim/borda
                sidebar()
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(
                        HermesTheme.sidebarBackground
                            .shadow(color: .black.opacity(0.22 * progress), radius: 18, x: 6)
                            .ignoresSafeArea()
                    )
                    .offset(x: revealed - sidebarWidth)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityHidden(progress < 0.5)

                // Zona de borda esquerda → abrir (padrão iOS)
                if !isPresented {
                    Color.clear
                        .frame(width: edgeWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .highPriorityGesture(horizontalDrag(sidebarWidth: sidebarWidth, mode: .open))
                }
            }
            .onChange(of: isPresented) { _, _ in
                if !isDragging {
                    dragTranslation = 0
                }
            }
        }
    }

    private func revealedWidth(sidebarWidth: CGFloat) -> CGFloat {
        let base: CGFloat = isPresented ? sidebarWidth : 0
        return min(sidebarWidth, max(0, base + dragTranslation))
    }

    private enum DragMode {
        case open
        case close
    }

    private func horizontalDrag(sidebarWidth: CGFloat, mode: DragMode) -> some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .global)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                // Só trata como gesto do drawer se o movimento for predominantemente horizontal.
                guard abs(dx) > abs(dy) * 1.15 else { return }

                switch mode {
                case .open:
                    guard !isPresented else { return }
                    isDragging = true
                    dragTranslation = max(0, min(sidebarWidth, dx))
                case .close:
                    guard isPresented else { return }
                    isDragging = true
                    dragTranslation = max(-sidebarWidth, min(0, dx))
                }
            }
            .onEnded { value in
                guard isDragging else { return }
                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let velocity = predicted - dx
                let revealed = revealedWidth(sidebarWidth: sidebarWidth)
                let progress = sidebarWidth > 0 ? revealed / sidebarWidth : 0

                let shouldOpen: Bool
                if velocity > velocityThreshold {
                    shouldOpen = true
                } else if velocity < -velocityThreshold {
                    shouldOpen = false
                } else {
                    shouldOpen = progress >= openThreshold
                }

                settle(open: shouldOpen)
            }
    }

    private func settle(open: Bool) {
        withAnimation(Self.spring) {
            isPresented = open
            dragTranslation = 0
            isDragging = false
        }
    }
}
