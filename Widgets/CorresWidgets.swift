import SwiftUI
import WidgetKit

@main
struct CorresWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
        WaitingWidget()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// The app writes a fresh snapshot and reloads timelines whenever mail
/// changes, so the widget only ever shows what's already on the phone.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry { SnapshotEntry(date: .now, snapshot: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .placeholder : (WidgetSnapshot.load() ?? .placeholder)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load() ?? .placeholder)
        // A fallback refresh in case the app hasn't run for a while, so
        // relative times ("2h") stay roughly right.
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Palette

/// The app's Obsidian / Ivory tokens, repeated here: a widget extension
/// can't read the app's asset catalog.
enum WidgetPalette {
    static let accent = Color(light: 0x2F5D9E, dark: 0x8FB4E8)
    static let ink = Color(light: 0x141312, dark: 0xF2F3F5)
    static let secondary = Color(light: 0x5E5A54, dark: 0xA1A3AA)
    static let tertiary = Color(light: 0x6F6A63, dark: 0x8A8C93)
    static let background = Color(light: 0xF6F3EC, dark: 0x0A0A0C)
    static let line = Color(light: 0xE4E0D8, dark: 0x232327)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

// MARK: - Needs You

struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "corres.needsYou", provider: SnapshotProvider()) { entry in
            ListWidgetView(title: "Needs You", count: entry.snapshot.needsYouCount, items: entry.snapshot.needsYou,
                           emptyText: "Nothing in Needs You", showsReason: true, destination: "needs-you",
                           isSample: entry.snapshot.isSample)
        }
        .configurationDisplayName("Needs You")
        .description("The conversations that ask something of you, with the reason for each.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct WaitingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "corres.waiting", provider: SnapshotProvider()) { entry in
            ListWidgetView(title: "Waiting", count: entry.snapshot.waitingCount, items: entry.snapshot.waiting,
                           emptyText: "Nothing in Waiting", showsReason: false, destination: "waiting",
                           isSample: entry.snapshot.isSample)
        }
        .configurationDisplayName("Waiting")
        .description("Conversations waiting on someone else's reply.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct ListWidgetView: View {
    let title: String
    let count: Int
    let items: [WidgetSnapshot.Item]
    let emptyText: String
    let showsReason: Bool
    let destination: String
    let isSample: Bool
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(WidgetSnapshot.url(for: destination))
            .containerBackground(for: .widget) { WidgetPalette.background }
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(count, format: .number).font(.system(.title2, design: .serif)).minimumScaleFactor(0.6)
                    Image(systemName: destination == "waiting" ? "clock" : "exclamationmark.circle").font(.caption2)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count) \(title)").font(.headline).widgetAccentable()
                if let first = items.first {
                    Text(first.sender).font(.caption).lineLimit(1)
                    Text(showsReason ? first.reason : first.subject).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                } else {
                    Text(emptyText).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text(count == 0 ? emptyText : "\(count) \(title.lowercased())" + (items.first.map { " · \($0.sender)" } ?? ""))
        case .systemSmall:
            small
        default:
            list(limit: family == .systemLarge ? 6 : 3)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(WidgetPalette.accent)
            Spacer(minLength: 4)
            if isSample { Text("SAMPLE").font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(WidgetPalette.tertiary) }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(count, format: .number)
                .font(.system(size: 44, weight: .regular, design: .serif))
                .foregroundStyle(WidgetPalette.ink)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            if let first = items.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(first.sender).font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
                    Text(showsReason ? first.reason : first.subject).font(.caption2).foregroundStyle(WidgetPalette.secondary).lineLimit(2)
                }
            } else {
                Text(emptyText).font(.caption).foregroundStyle(WidgetPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func list(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                header
                Text(count, format: .number).font(.system(.title3, design: .serif)).foregroundStyle(WidgetPalette.ink)
            }
            if items.isEmpty {
                Spacer()
                Text(emptyText).font(.subheadline).foregroundStyle(WidgetPalette.secondary)
                Spacer()
            } else {
                ForEach(Array(items.prefix(limit).enumerated()), id: \.element.id) { index, item in
                    Link(destination: item.url) { row(item) }
                    if index < min(limit, items.count) - 1 {
                        Rectangle().fill(WidgetPalette.line).frame(height: 0.5)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ item: WidgetSnapshot.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(item.isUnread ? WidgetPalette.accent : .clear).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.sender).font(.subheadline.weight(.semibold)).foregroundStyle(WidgetPalette.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    if let due = item.dueLabel {
                        Text(due).font(.caption2.weight(.semibold)).foregroundStyle(WidgetPalette.accent)
                    } else {
                        Text(item.receivedAt.formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                            .font(.caption2).foregroundStyle(WidgetPalette.tertiary)
                    }
                }
                Text(showsReason ? item.reason : item.subject).font(.caption).foregroundStyle(WidgetPalette.secondary).lineLimit(1)
            }
        }
    }
}
