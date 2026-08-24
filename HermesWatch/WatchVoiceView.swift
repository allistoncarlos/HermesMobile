import SwiftUI
import WatchKit

// ============================================================================
//  WatchVoiceView — conversa só por voz no Apple Watch.
//  O relógio não fala com o servidor Hermes (Tailscale/LAN): grava e toca,
//  e o iPhone faz STT, chat e TTS.
// ============================================================================

struct WatchVoiceView: View {
    @ObservedObject var voice: VoiceModeController
    @ObservedObject private var companion = CompanionSync.shared

    var body: some View {
        ZStack {
            background
            switch displayedConnection {
            case .connected:
                sessionContent
            case .connecting:
                statusScreen(title: "Conectando…", detail: companion.phoneDetail, progress: true)
            case .waitingAuth:
                statusScreen(
                    title: "Faça login no iPhone",
                    detail: "Abra o Hermes no iPhone para autenticar. O Watch usa a sessão do iPhone."
                )
            case .failed(let message):
                statusScreen(
                    title: "iPhone sem conexão",
                    detail: message,
                    retry: true
                )
            case .disconnected:
                if companion.didReceivePhoneState {
                    statusScreen(
                        title: "Abra o Hermes no iPhone",
                        detail: companion.phoneDetail.isEmpty
                            ? "Conecte no iPhone; o Watch usa essa sessão."
                            : companion.phoneDetail,
                        retry: true
                    )
                } else {
                    statusScreen(
                        title: companion.phoneReachable ? "Aguardando o iPhone…" : "Mantenha o iPhone por perto",
                        detail: "O Watch não fala sozinho com o servidor — a conversa passa pelo iPhone.",
                        progress: companion.phoneReachable,
                        retry: true
                    )
                }
            }
        }
        .onAppear {
            CompanionSync.shared.bind()
            updateRuntime(for: voice.phase)
        }
        .onChange(of: companion.phoneConnection) { _, state in
            if case .connected = state { return }
            voice.endSession()
            WatchRuntimeSession.shared.stop()
        }
        .onChange(of: voice.phase) { _, phase in
            playHaptic(for: phase)
            updateRuntime(for: phase)
        }
        // Não encerrar em onDisappear: abaixar o braço apaga a tela e
        // disparava disappear, matando a conversa no meio.
    }

    private var displayedConnection: ConnectionState {
        companion.phoneConnection
    }


    private var sessionContent: some View {
        VStack(spacing: 4) {
            botTabs

            Text(voice.statusLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if case .listening = voice.phase, voice.silenceProgress > 0.1 {
                ProgressView(value: Double(voice.silenceProgress))
                    .tint(orbTint)
                    .scaleEffect(0.8)
            }

            Spacer(minLength: 0)

            orb
                .onTapGesture { handlePrimary() }

            Spacer(minLength: 0)

            Text(displayText)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)

            if let approval = companion.pendingApproval {
                WatchApprovalPanel(approval: approval) { allow in
                    CompanionSync.shared.respondApproval(allow: allow)
                    voice.resumeAfterApproval()
                }
            } else {
                controls
            }
        }
        .padding(.horizontal, 6)
    }

    private var botTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(companion.roster.slots) { slot in
                    let selected = companion.activeProfileName == slot.profileName
                    let accent = Color.hermesAccent(hex: slot.accentHex, fallbackKey: slot.profileName)
                    Button {
                        if isInSession { voice.endSession() }
                        CompanionSync.shared.selectBot(slot)
                    } label: {
                        Text(slot.isDefault ? String(slot.displayName.prefix(1)) : slot.initials)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(accent.opacity(selected ? 0.95 : 0.32))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(accent, lineWidth: selected ? 1.4 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(slot.displayName)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .frame(height: 26)
    }

    private var orb: some View {
        let size: CGFloat = 72
        let pulse = CGFloat(voice.audioLevel) * 10

        return ZStack {
            Circle()
                .stroke(orbTint.opacity(0.35), lineWidth: 1.5)
                .frame(width: size + 18 + pulse, height: size + 18 + pulse)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            orbTint.opacity(0.95),
                            orbTint.opacity(0.5),
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: size / 2
                    )
                )
                .frame(width: size + pulse, height: size + pulse)
                .shadow(color: orbTint.opacity(0.45), radius: 10)

            Image(systemName: orbIcon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, isActive: isAnimatingIcon)
        }
        .frame(height: 96)
        .animation(.easeOut(duration: 0.12), value: voice.audioLevel)
        .accessibilityLabel(voice.statusLabel)
        .accessibilityAddTraits(.isButton)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                handlePrimary()
            } label: {
                Image(systemName: primaryButtonIcon)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(primaryButtonFill))

            Button {
                voice.endSession()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(.white.opacity(0.14)))
            .opacity(isInSession ? 1 : 0.35)
            .disabled(!isInSession)

            Button {
                CompanionSync.shared.startVoiceOnSelectedBot()
            } label: {
                Image(systemName: "plus.bubble")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(.white.opacity(0.14)))
        }
        .foregroundStyle(.white)
        .padding(.top, 2)
    }


    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.10),
                Color(red: 0.08, green: 0.10, blue: 0.16),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private func statusScreen(title: String, detail: String, progress: Bool = false, retry: Bool = false) -> some View {
        VStack(spacing: 8) {
            if progress {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: retry ? "wifi.exclamationmark" : "applewatch.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .lineLimit(5)
            if retry {
                Button("Tentar") {
                    CompanionSync.shared.requestPhoneStatus()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.35, green: 0.72, blue: 0.98))
                .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }


    private func handlePrimary() {
        switch voice.phase {
        case .idle:
            Task {
                CompanionSync.shared.startVoiceOnSelectedBot()
                try? await Task.sleep(nanoseconds: 400_000_000)
                await voice.startSession()
            }
        default:
            voice.primaryAction()
        }
    }

    private func playHaptic(for phase: VoiceModeController.Phase) {
        switch phase {
        case .listening:
            WKInterfaceDevice.current().play(.start)
        case .transcribing:
            WKInterfaceDevice.current().play(.click)
        case .speaking:
            WKInterfaceDevice.current().play(.directionUp)
        case .error:
            WKInterfaceDevice.current().play(.failure)
        default:
            break
        }
    }

    private func updateRuntime(for phase: VoiceModeController.Phase) {
        switch phase {
        case .idle:
            WatchRuntimeSession.shared.stop()
        case .listening, .transcribing, .processing, .speaking, .error:
            WatchRuntimeSession.shared.startIfNeeded()
            try? HermesAudioSession.activatePlayAndRecord()
        }
    }


    private var isInSession: Bool {
        switch voice.phase {
        case .idle: return false
        default: return true
        }
    }

    private var displayText: String {
        switch voice.phase {
        case .listening, .idle:
            return isInSession ? "Fale com \(selectedBotName)" : "Toque para falar"
        case .transcribing:
            return voice.liveTranscript.isEmpty ? "…" : voice.liveTranscript
        case .processing, .speaking:
            return voice.assistantCaption.isEmpty
                ? (voice.liveTranscript.isEmpty ? "\(selectedBotName)…" : voice.liveTranscript)
                : voice.assistantCaption
        case .error(let message):
            return message
        }
    }

    private var selectedBotName: String {
        companion.roster.slots.first(where: { $0.profileName == companion.activeProfileName })?.displayName
            ?? companion.roster.defaultSlot.displayName
    }

    private var selectedBotAccent: Color {
        let slot = companion.roster.slots.first(where: { $0.profileName == companion.activeProfileName })
            ?? companion.roster.defaultSlot
        return Color.hermesAccent(hex: slot.accentHex, fallbackKey: slot.profileName)
    }

    private var orbTint: Color {
        switch voice.phase {
        case .listening: return selectedBotAccent
        case .transcribing: return selectedBotAccent.opacity(0.85)
        case .processing: return Color(red: 0.72, green: 0.55, blue: 0.98)
        case .speaking: return Color(red: 0.40, green: 0.85, blue: 0.70)
        case .error: return Color(red: 0.95, green: 0.40, blue: 0.40)
        case .idle: return selectedBotAccent.opacity(0.75)
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

    private var primaryButtonIcon: String {
        switch voice.phase {
        case .listening: return "checkmark"
        case .speaking, .processing, .transcribing: return "stop.fill"
        case .error, .idle: return "mic.fill"
        }
    }

    private var primaryButtonFill: Color {
        switch voice.phase {
        case .speaking, .processing, .transcribing: return Color.red.opacity(0.85)
        default: return selectedBotAccent
        }
    }
}

private struct WatchApprovalPanel: View {
    let approval: PendingApproval
    let onRespond: (Bool) -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(approval.message)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            HStack(spacing: 8) {
                Button("Não") { onRespond(false) }
                    .tint(.red)
                Button("Sim") { onRespond(true) }
                    .tint(.green)
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 2)
    }
}
