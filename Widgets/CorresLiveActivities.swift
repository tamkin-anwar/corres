#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

/// Send Later's last few hours: "To Maya · 9:00 AM", counting down.
struct SendLaterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SendLaterActivity.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "paperplane.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WidgetPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sending to \(context.attributes.recipient)")
                        .font(.headline)
                    Text("At \(context.state.sendAt, format: .dateTime.hour().minute())")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(timerInterval: Date.now...max(context.state.sendAt, .now), countsDown: true)
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
            }
            .padding(16)
            .activityBackgroundTint(nil)
            .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Send Later", systemImage: "paperplane.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(WidgetPalette.accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date.now...max(context.state.sendAt, .now), countsDown: true)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .multilineTextAlignment(.trailing).frame(maxWidth: 80)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("To \(context.attributes.recipient) at \(context.state.sendAt, format: .dateTime.hour().minute())")
                        .font(.subheadline)
                }
            } compactLeading: {
                Image(systemName: "paperplane.fill").foregroundStyle(WidgetPalette.accent)
            } compactTrailing: {
                Text(timerInterval: Date.now...max(context.state.sendAt, .now), countsDown: true)
                    .monospacedDigit().frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "paperplane.fill").foregroundStyle(WidgetPalette.accent)
            }
            .widgetURL(context.attributes.link)
            .keylineTint(WidgetPalette.accent)
        }
    }
}

/// A package out for delivery today, from the store's own email.
struct DeliveryLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DeliveryActivity.self) { context in
            HStack(spacing: 14) {
                Image(systemName: context.state.delivered ? "shippingbox.and.arrow.backward.fill" : "shippingbox.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(WidgetPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.delivered ? "Delivered" : "Out for delivery today")
                        .font(.headline)
                    Text(subtitle(context.attributes))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "shippingbox.fill").font(.title3).foregroundStyle(WidgetPalette.accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.delivered ? "Delivered" : "Out for delivery today").font(.subheadline.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(subtitle(context.attributes)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: "shippingbox.fill").foregroundStyle(WidgetPalette.accent)
            } compactTrailing: {
                Image(systemName: context.state.delivered ? "checkmark" : "clock")
            } minimal: {
                Image(systemName: "shippingbox.fill").foregroundStyle(WidgetPalette.accent)
            }
            .widgetURL(context.attributes.link)
            .keylineTint(WidgetPalette.accent)
        }
    }

    private func subtitle(_ attributes: DeliveryActivity) -> String {
        attributes.carrier.map { "\(attributes.from) · \($0)" } ?? attributes.from
    }
}
#endif
