import SwiftUI

// ============================================================================
//  VoiceModeView — tela fullscreen de voz (orb + escuta/fala), estilo ChatGPT.
// ============================================================================

struct VoiceModeView: View {
    @ObservedObject var voice: VoiceModeController
    @EnvironmentObject private var vm: HermesViewModel

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                topBar
                Spacer()
                orb
                caption
                Spacer()
                bottomControls
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear {
            voice.attach(vm)
            if case .idle = voice.phase {
                Task { await voice.startSession() }
            }
        }
        .onDisappear {
            voice.endSession()
        }
    }

    // MARK: - Layers

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.06, blue: 0.10),
                    Color(red: 0.08, green: 0.10, blue: 0.16),
                    Color(red: 0.04, green: 0.05, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Glow sutil sob o orb
            Circle()
                .fill(orbTint.opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(y: -20)
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                voice.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .accessibilityLabel("Fechar modo de voz")

            Spacer()

            Text("Modo de voz")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))

            Spacer()

            // Espelho do botão X para centralizar o título
            Color.clear.frame(width: 40, height: 40)
        }
    }

    private var orb: some View {
        let base: CGFloat = 168
        let pulse = CGFloat(0.08 + Double(voice.audioLevel) * 0.35)

        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(orbTint.opacity(0.25 - Double(i) * 0.06), lineWidth: 1.5)
                    .frame(width: base + CGFloat(i + 1) * 36 + pulse * 40)
                    .scaleEffect(phaseScale)
                    .animation(orbAnimation, value: voice.audioLevel)
                    .animation(orbAnimation, value: voice.phase)
            }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            orbTint.opacity(0.95),
                            orbTint.opacity(0.55),
                            orbTint.opacity(0.25),
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: base / 2
                    )
                )
                .frame(width: base + pulse * 28, height: base + pulse * 28)
                .shadow(color: orbTint.opacity(0.45), radius: 28, y: 8)
                .scaleEffect(phaseScale)
                .animation(orbAnimation, value: voice.audioLevel)
                .animation(orbAnimation, value: voice.phase)

            Image(systemName: orbIcon)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .symbolEffect(.variableColor.iterative, isActive: isAnimatingIcon)
        }
        .frame(height: 260)
        .contentShape(Rectangle())
        .onTapGesture { voice.primaryAction() }
        .accessibilityLabel(voice.statusLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var caption: some View {
        VStack(spacing: 12) {
            Text(voice.statusLabel)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.55))
                .animation(.easeInOut(duration: 0.2), value: voice.statusLabel)

            Text(displayText)
                .font(.title3.weight(.regular))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .frame(maxWidth: 340)
                .animation(.easeOut(duration: 0.15), value: displayText)

            if let approval = vm.pendingApproval {
                ApprovalBanner(approval: approval) { allow in
                    Task {
                        await vm.respondApproval(allow: allow)
                        voice.resumeAfterApproval()
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 120, alignment: .top)
    }

    private var bottomControls: some View {
        HStack(spacing: 36) {
            Button {
                voice.dismiss()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.white.opacity(0.12)))
                    Text("Teclado")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.85))
            }

            Button {
                voice.primaryAction()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: primaryButtonIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(primaryButtonFill))
                    Text(primaryButtonLabel)
                        .font(.caption2)
                }
                .foregroundStyle(.white)
            }

            Button {
                Task { await vm.newSession() }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.white.opacity(0.12)))
                    Text("Nova")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - Derived

    private var displayText: String {
        switch voice.phase {
        case .listening:
            return " "
        case .transcribing:
            return voice.liveTranscript.isEmpty ? "…" : voice.liveTranscript
        case .processing, .speaking:
            return voice.assistantCaption.isEmpty
                ? (voice.liveTranscript.isEmpty ? " " : voice.liveTranscript)
                : voice.assistantCaption
        case .error(let m):
            return m
        case .idle:
            return " "
        }
    }

    private var orbTint: Color {
        switch voice.phase {
        case .listening: return Color(red: 0.35, green: 0.72, blue: 0.98)
        case .transcribing: return Color(red: 0.55, green: 0.70, blue: 0.98)
        case .processing: return Color(red: 0.72, green: 0.55, blue: 0.98)
        case .speaking: return Color(red: 0.40, green: 0.85, blue: 0.70)
        case .error: return Color(red: 0.95, green: 0.40, blue: 0.40)
        case .idle: return Color(red: 0.55, green: 0.60, blue: 0.70)
        }
    }

    private var orbIcon: String {
        switch voice.phase {
        case .listening: return "waveform"
        case .transcribing: return "text.bubble"
        case .processing: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .idle: return "mic.fill"
        }
    }

    private var isAnimatingIcon: Bool {
        switch voice.phase {
        case .listening, .transcribing, .processing, .speaking: return true
        default: return false
        }
    }

    private var phaseScale: CGFloat {
        switch voice.phase {
        case .listening: return 1.0 + CGFloat(voice.audioLevel) * 0.06
        case .speaking: return 1.04
        case .transcribing, .processing: return 0.96
        default: return 1.0
        }
    }

    private var orbAnimation: Animation {
        switch voice.phase {
        case .listening:
            return .easeOut(duration: 0.12)
        case .transcribing, .processing:
            return .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        case .speaking:
            return .easeInOut(duration: 0.35)
        default:
            return .easeInOut(duration: 0.25)
        }
    }

    private var primaryButtonIcon: String {
        switch voice.phase {
        case .listening: return "checkmark"
        case .speaking, .processing, .transcribing: return "stop.fill"
        case .error, .idle: return "arrow.clockwise"
        }
    }

    private var primaryButtonLabel: String {
        switch voice.phase {
        case .listening: return "Enviar"
        case .speaking, .processing, .transcribing: return "Parar"
        case .error, .idle: return "Tentar"
        }
    }

    private var primaryButtonFill: Color {
        switch voice.phase {
        case .speaking, .processing, .transcribing: return Color.red.opacity(0.85)
        default: return Color.accentColor
        }
    }
}
