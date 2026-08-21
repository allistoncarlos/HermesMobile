import SwiftUI

// ============================================================================
//  VoiceModeView — tela fullscreen de voz (orb + escuta/fala), estilo ChatGPT.
//  Layout empilhado em retrato; em paisagem orb + texto lado a lado.
// ============================================================================

struct VoiceModeView: View {
    @ObservedObject var voice: VoiceModeController
    @EnvironmentObject private var vm: HermesViewModel

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height

            ZStack {
                background

                VStack(spacing: 0) {
                    topBar
                    if landscape {
                        landscapeBody
                    } else {
                        portraitBody
                    }
                    bottomControls(compact: landscape)
                }
                .padding(.horizontal, landscape ? 20 : 24)
                .padding(.vertical, landscape ? 10 : 16)
            }
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


    private var portraitBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            orb(size: 168)
            caption
            Spacer(minLength: 0)
        }
    }

    private var landscapeBody: some View {
        HStack(alignment: .center, spacing: 24) {
            orb(size: 120)
                .frame(maxWidth: .infinity)
            caption
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }


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

            Color.clear.frame(width: 40, height: 40)
        }
    }

    private func orb(size: CGFloat) -> some View {
        let pulse = CGFloat(0.08 + Double(voice.audioLevel) * 0.35)

        return ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(orbTint.opacity(0.25 - Double(i) * 0.06), lineWidth: 1.5)
                    .frame(width: size + CGFloat(i + 1) * 28 + pulse * 32)
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
                        endRadius: size / 2
                    )
                )
                .frame(width: size + pulse * 22, height: size + pulse * 22)
                .shadow(color: orbTint.opacity(0.45), radius: 28, y: 8)
                .scaleEffect(phaseScale)
                .animation(orbAnimation, value: voice.audioLevel)
                .animation(orbAnimation, value: voice.phase)

            Image(systemName: orbIcon)
                .font(.system(size: size > 140 ? 36 : 28, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .symbolEffect(.variableColor.iterative, isActive: isAnimatingIcon)
        }
        .frame(height: size + 80)
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
                .multilineTextAlignment(.center)

            if case .listening = voice.phase, voice.silenceProgress > 0.08 {
                ProgressView(value: Double(voice.silenceProgress))
                    .tint(orbTint)
                    .frame(maxWidth: 180)
                    .animation(.linear(duration: 0.08), value: voice.silenceProgress)
            }

            Text(displayText)
                .font(.title3.weight(.regular))
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .frame(maxWidth: 340)
                .animation(.easeOut(duration: 0.15), value: displayText)

            if case .listening = voice.phase, vm.pendingApproval == nil {
                Text("Pare de falar para enviar · diga “parar” para sair")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.38))
            }

            if let approval = vm.pendingApproval {
                ApprovalBanner(approval: approval) { allow in
                    Task {
                        await vm.respondApproval(allow: allow)
                        voice.resumeAfterApproval()
                    }
                }
                .padding(.top, 8)

                Text("Ou diga “sim” / “não” sem tocar na tela")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 80, alignment: .top)
    }

    private func bottomControls(compact: Bool) -> some View {
        HStack(spacing: compact ? 28 : 36) {
            Button {
                voice.dismiss()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: compact ? 46 : 52, height: compact ? 46 : 52)
                        .background(Circle().fill(.white.opacity(0.12)))
                    if !compact {
                        Text("Teclado")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
            }

            Button {
                voice.primaryAction()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: primaryButtonIcon)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: compact ? 56 : 64, height: compact ? 56 : 64)
                        .background(Circle().fill(primaryButtonFill))
                    if !compact {
                        Text(primaryButtonLabel)
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.white)
            }

            Button {
                Task { await vm.newSession() }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: compact ? 46 : 52, height: compact ? 46 : 52)
                        .background(Circle().fill(.white.opacity(0.12)))
                    if !compact {
                        Text("Nova")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.bottom, compact ? 4 : 12)
    }


    private var displayText: String {
        switch voice.phase {
        case .listening:
            if vm.pendingApproval != nil {
                return voice.assistantCaption.isEmpty
                    ? "Aguardando sim ou não…"
                    : voice.assistantCaption
            }
            return voice.isHearingSpeech ? " " : " "
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
