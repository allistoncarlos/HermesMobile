import SwiftUI
import WidgetKit
import AppIntents
#if canImport(UIKit)
import UIKit
#endif

@main
struct HermesWatchWidgets: WidgetBundle {
    var body: some Widget {
        HermesBotsWidget()
    }
}

struct HermesBotsWidget: Widget {
    let kind: String = WatchComplicationStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: HermesBotsProvider()) { entry in
            HermesBotsEntryView(entry: entry)
        }
        .configurationDisplayName("Hermes")
        .description("Perfil padrão e os dois bots mais recentes. Cada botão abre a fala ativa.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct HermesBotsEntry: TimelineEntry {
    let date: Date
    let roster: WatchComplicationRoster
}

struct HermesBotsProvider: TimelineProvider {
    func placeholder(in context: Context) -> HermesBotsEntry {
        HermesBotsEntry(date: Date(), roster: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (HermesBotsEntry) -> Void) {
        completion(HermesBotsEntry(date: Date(), roster: WatchComplicationStore.loadOrPlaceholder()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HermesBotsEntry>) -> Void) {
        let entry = HermesBotsEntry(date: Date(), roster: WatchComplicationStore.load() ?? .defaultOnly)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct HermesBotsEntryView: View {
    var entry: HermesBotsEntry

    var body: some View {
        let slots = Array(entry.roster.slots.prefix(3))
        group(slots)
            .accessoryWidgetGroupStyle(.circular)
            .foregroundStyle(Color(red: 0.45, green: 0.78, blue: 1.0))
            .containerBackground(for: .widget) {
                Color.clear
            }
    }

    @ViewBuilder
    private func group(_ slots: [WatchComplicationSlot]) -> some View {
        switch slots.count {
        case 3:
            AccessoryWidgetGroup("Hermes", systemImage: "waveform") {
                slotButton(slots[0])
                slotButton(slots[1])
                slotButton(slots[2])
            }
        case 2:
            AccessoryWidgetGroup("Hermes", systemImage: "waveform") {
                slotButton(slots[0])
                slotButton(slots[1])
            }
        default:
            AccessoryWidgetGroup("Hermes", systemImage: "waveform") {
                slotButton(slots.first ?? WatchComplicationRoster.defaultOnly.slots[0])
            }
        }
    }

    private func slotButton(_ slot: WatchComplicationSlot) -> some View {
        Button(intent: OpenHermesVoiceProfileIntent(profileName: slot.profileName)) {
            ComplicationAvatarView(slot: slot)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Falar com \(slot.displayName)")
    }
}

struct ComplicationAvatarView: View {
    let slot: WatchComplicationSlot

    var body: some View {
        Group {
            if let data = slot.avatarJPEG, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityHidden(true)
            } else if slot.isDefault {
                ZStack {
                    Color(red: 0.35, green: 0.72, blue: 0.98)
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .widgetAccentable()
                }
            } else {
                ZStack {
                    Color.white.opacity(0.22)
                    Text(slot.initials)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                }
            }
        }
        .accessibilityLabel(slot.displayName)
    }
}
