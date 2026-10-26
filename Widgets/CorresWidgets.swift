import SwiftUI
import WidgetKit

@main
struct CorresWidgets: WidgetBundle {
    var body: some Widget {
        NeedsYouWidget()
        WaitingWidget()
        #if os(iOS)
        SendLaterLiveActivity()
        DeliveryLiveActivity()
        if #available(iOS 18.0, *) {
            ComposeControl()
            NeedsYouControl()
        }
        #endif
    }
}

#if os(iOS)
/// Control Center, the Lock Screen and the Action button: a new email.
@available(iOS 18.0, *)
struct ComposeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "studio.anwarcreative.corres.control.compose") {
            ControlWidgetButton(action: ComposeControlIntent()) {
                Label("New Email", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Email")
        .description("Start a new email in Corres.")
    }
}

/// Control Center: straight to what needs you.
@available(iOS 18.0, *)
struct NeedsYouControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "studio.anwarcreative.corres.control.needsYou") {
            ControlWidgetButton(action: OpenNeedsYouControlIntent()) {
                Label("Needs You", systemImage: "exclamationmark.circle")
            }
        }
        .displayName("Needs You")
        .description("Open Needs You in Corres.")
    }
}
#endif

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
        let snapshot = WidgetSnapshot.load() ?? .placeholder
        // One entry each quarter hour, each with its own "2h", so the times
        // move on without the app; then a fresh look in case it hasn't run.
        let now = Date.now
        let entries = (0..<8).map { SnapshotEntry(date: now.addingTimeInterval(Double($0) * 15 * 60), snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

/// The Mac's desktop and Notification Center take the home-screen sizes;
/// the Lock Screen's are the iPhone's own.
enum WidgetSizes {
    #if os(macOS)
    static let needsYou: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
    static let waiting: [WidgetFamily] = [.systemSmall, .systemMedium]
    #else
    static let needsYou: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
    static let waiting: [WidgetFamily] = [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular]
    #endif
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
        func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255)
        }
        #if os(macOS)
        // The Mac's desktop widgets follow the system appearance too.
        self.init(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #else
        self.init(uiColor: UIColor { traits in
            let (r, g, b) = rgb(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

// MARK: - Needs You

struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "corres.needsYou", provider: SnapshotProvider()) { entry in
            ListWidgetView(title: String(localized: "Needs You"), count: entry.snapshot.needsYouCount, items: entry.snapshot.needsYou,
                           emptyText: String(localized: "Nothing in Needs You"), showsReason: true, destination: "needs-you",
                           isSample: entry.snapshot.isSample, isLocked: entry.snapshot.isLocked == true, now: entry.date)
        }
        .configurationDisplayName("Needs You")
        .description("The conversations that ask something of you, with the reason for each.")
        .supportedFamilies(WidgetSizes.needsYou)
    }
}

struct WaitingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "corres.waiting", provider: SnapshotProvider()) { entry in
            ListWidgetView(title: String(localized: "Waiting"), count: entry.snapshot.waitingCount, items: entry.snapshot.waiting,
                           emptyText: String(localized: "Nothing in Waiting"), showsReason: false, destination: "waiting",
                           isSample: entry.snapshot.isSample, isLocked: entry.snapshot.isLocked == true, now: entry.date)
        }
        .configurationDisplayName("Waiting")
        .description("Conversations waiting on someone else's reply.")
        .supportedFamilies(WidgetSizes.waiting)
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
    /// `.privacy` on the Lock Screen while the iPhone is locked.
    @Environment(\.redactionReasons) private var redactionReasons

    var isLocked = false
    /// The entry's moment, for "2h": each entry in the timeline says it as of its own time.
    var now = Date.now

    var body: some View {
        Group {
            if isLocked { locked } else { content }
        }
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
                // Who wrote and why stay hidden on the Lock Screen until
                // it's unlocked, as with a notification's preview.
                if let first = items.first {
                    Text(first.sender).font(.caption).lineLimit(1).privacySensitive()
                    Text(showsReason ? first.reason : first.subject).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                        .privacySensitive()
                } else {
                    Text(emptyText).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            // One line can't be part hidden: the sender is left out instead.
            let sender = redactionReasons.contains(.privacy) ? nil : items.first.map { " · \($0.sender)" }
            Text(count == 0 ? emptyText : "\(count) \(title.lowercased())" + (sender ?? ""))
        case .systemSmall:
            small
        default:
            list(limit: family == .systemLarge ? 6 : 3)
        }
    }

    /// Pro has lapsed: no mail shown, one clear way back.
    private var locked: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(WidgetPalette.accent)
            Spacer(minLength: 0)
            Text("Corres Pro").font(.system(.headline, design: .serif)).foregroundStyle(WidgetPalette.ink)
            Text("Open Corres to start your free trial.").font(.caption).foregroundStyle(WidgetPalette.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .privacySensitive()
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
                    HStack(alignment: .top, spacing: 6) {
                        Link(destination: item.url) { row(item) }
                        // Done with it, without opening Corres.
                        if showsReason, !item.account.isEmpty {
                            Button(intent: MarkHandledFromWidgetIntent(conversation: item.id)) {
                                Image(systemName: "checkmark.circle")
                                    .font(.body)
                                    .foregroundStyle(WidgetPalette.accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Mark as Handled")
                        }
                    }
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
                        // As of the entry's moment: moved by however far ahead
                        // of it this is drawn, then said relative to now.
                        Text(min(item.receivedAt.addingTimeInterval(Date.now.timeIntervalSince(now)), .now)
                            .formatted(.relative(presentation: .numeric, unitsStyle: .narrow)))
                            .font(.caption2).foregroundStyle(WidgetPalette.tertiary)
                    }
                }
                Text(showsReason ? item.reason : item.subject).font(.caption).foregroundStyle(WidgetPalette.secondary).lineLimit(1)
            }
            .privacySensitive()
        }
    }
}
