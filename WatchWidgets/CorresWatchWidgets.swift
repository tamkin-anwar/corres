import SwiftUI
import WidgetKit

/// Corres on the watch face and in the Smart Stack: how many emails need
/// you, at a glance, and who the first is from. Tap to open Corres.
@main
struct CorresWatchWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouFace()
    }
}

struct NeedsYouEntry: TimelineEntry {
    let date: Date
    let face: WatchFace?
    var relevance: TimelineEntryRelevance? {
        // Higher in the Smart Stack while something needs you.
        guard let count = face?.needsYou, count > 0 else { return TimelineEntryRelevance(score: 0) }
        return TimelineEntryRelevance(score: Float(min(count, 10)))
    }
}

struct NeedsYouProvider: TimelineProvider {
    func placeholder(in context: Context) -> NeedsYouEntry { NeedsYouEntry(date: .now, face: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (NeedsYouEntry) -> Void) {
        completion(NeedsYouEntry(date: .now, face: context.isPreview ? .placeholder : WatchFace.load()))
    }

    /// Drawn again only when the Watch app hears from the iPhone.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NeedsYouEntry>) -> Void) {
        completion(Timeline(entries: [NeedsYouEntry(date: .now, face: WatchFace.load())], policy: .never))
    }
}

struct NeedsYouFace: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NeedsYou", provider: NeedsYouProvider()) { entry in
            NeedsYouFaceView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Needs You")
        .description("How many emails need you, and who the first is from.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct NeedsYouFaceView: View {
    let entry: NeedsYouEntry
    @Environment(\.widgetFamily) private var family

    private var count: Int? { entry.face?.needsYou }
    private static let accent = Color(red: 0x8F / 255, green: 0xB4 / 255, blue: 0xE8 / 255)

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryCorner: corner
        case .accessoryInline: inline
        default: rectangular
        }
    }

    private var countText: String { count.map(String.init) ?? "–" }

    /// The count in a ring, the envelope above it.
    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: count == 0 ? "checkmark" : "envelope.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Self.accent)
                    .widgetAccentable()
                Text(countText)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .minimumScaleFactor(0.6)
            }
        }
        .accessibilityLabel(spokenSummary)
    }

    private var corner: some View {
        Text(countText)
            .font(.system(.title2, design: .rounded).weight(.semibold))
            .widgetAccentable()
            .widgetLabel { Text("Needs You") }
            .accessibilityLabel(spokenSummary)
    }

    private var inline: some View {
        Label(inlineText, systemImage: count == 0 ? "checkmark.circle" : "envelope")
    }

    private var inlineText: String {
        switch count {
        case nil: String(localized: "Corres")
        case 0: String(localized: "Nothing needs you")
        case 1: String(localized: "1 needs you")
        case let count?: String(localized: "\(count) need you")
        }
    }

    /// "Needs You · 3", then who the first is from, hidden with the wrist down.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "envelope.fill").foregroundStyle(Self.accent).widgetAccentable()
                Text("Needs You").font(.headline).widgetAccentable()
                Spacer(minLength: 0)
                Text(countText).font(.system(.headline, design: .rounded)).monospacedDigit()
            }
            if let count, count > 0, let first = entry.face?.firstSender {
                Text(count == 1 ? String(localized: "From \(first)") : String(localized: "From \(first) and \(count - 1) more"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .privacySensitive()
            } else if count == 0 {
                Text("You're all caught up").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Open Corres on your iPhone").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var spokenSummary: String {
        switch count {
        case nil: String(localized: "Corres")
        case 0: String(localized: "Nothing needs you")
        case 1: String(localized: "1 email needs you")
        case let count?: String(localized: "\(count) emails need you")
        }
    }
}
