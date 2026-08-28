import WidgetKit
import SwiftUI

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: UsageSnapshot(
            limits: [
                UsageLimit(id: "five_hour", label: "Session (5 h)",
                           utilization: 42, resetsAt: Date().addingTimeInterval(7200)),
                UsageLimit(id: "seven_day", label: "Weekly · all models",
                           utilization: 18, resetsAt: nil),
            ],
            updated: Date(), subscription: "pro", orgName: nil, orgCount: nil
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: SharedStore.read() ?? placeholder(in: context).snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let snapshot = SharedStore.read() ?? .empty
        let entry = UsageEntry(date: Date(), snapshot: snapshot)
        // The host app pushes reloads on every successful poll; this is just a
        // backstop so the "updated Xm ago" text and reset countdowns stay honest.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Pieces

struct UsageRing: View {
    let value: Double
    var lineWidth: CGFloat = 10
    var showLabel = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(value / 100, 1)))
                .stroke(
                    severityColor(value),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            if showLabel {
                VStack(spacing: 0) {
                    Text("\(Int(value.rounded()))")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.5)
                    Text("%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LimitBar: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(limit.label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(UsageFormat.percent(limit.utilization))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(severityColor(limit.utilization))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(severityColor(limit.utilization))
                        .frame(width: max(3, geo.size.width * limit.utilization / 100))
                }
            }
            .frame(height: 5)
        }
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "chart.pie")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("Open Claudar")
                .font(.system(size: 10, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(6)
    }
}

// MARK: - Views per family

struct SmallUsageView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        if let headline = snapshot.headline {
            VStack(spacing: 6) {
                UsageRing(value: headline.utilization)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(UsageFormat.resetString(headline.resetsAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            EmptyState()
        }
    }
}

struct MediumUsageView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        if let headline = snapshot.headline {
            HStack(spacing: 14) {
                VStack(spacing: 3) {
                    UsageRing(value: headline.utilization, lineWidth: 9)
                        .frame(width: 72, height: 72)
                    Text(headline.label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if headline.resetsAt != nil {
                        Text(UsageFormat.resetString(headline.resetsAt))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(snapshot.limits.prefix(4)) { limit in
                        LimitBar(limit: limit)
                    }
                    Text(snapshot.showsOrgName
                         ? "\(snapshot.orgName ?? "") · \(UsageFormat.staleString(snapshot.updated))"
                         : "Updated \(UsageFormat.staleString(snapshot.updated))")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        } else {
            EmptyState()
        }
    }
}

struct LargeUsageView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        if let headline = snapshot.headline {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(snapshot.showsOrgName ? (snapshot.orgName ?? "Claudar") : "Claudar")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    if let sub = snapshot.subscription, !sub.isEmpty {
                        Text(sub.capitalized)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.12)))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 14) {
                    UsageRing(value: headline.utilization, lineWidth: 11)
                        .frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline.label)
                            .font(.system(size: 12, weight: .semibold))
                        Text(UsageFormat.resetString(headline.resetsAt))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                VStack(spacing: 9) {
                    ForEach(snapshot.limits) { limit in
                        LimitBar(limit: limit)
                    }
                }
                Spacer(minLength: 0)
                Text("Updated \(UsageFormat.staleString(snapshot.updated))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        } else {
            EmptyState()
        }
    }
}

// MARK: - Widget

struct ClaudarWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: UsageProvider.Entry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallUsageView(snapshot: entry.snapshot)
            case .systemLarge: LargeUsageView(snapshot: entry.snapshot)
            default: MediumUsageView(snapshot: entry.snapshot)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        // Without this a click does nothing visible: the host app is an accessory
        // with no Dock icon, so merely activating it shows the user no window.
        .widgetURL(ClaudarURL.window)
    }
}

struct ClaudarWidget: Widget {
    let kind = "ClaudarWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            ClaudarWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Claudar")
        .description("Your Claude usage limits at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main
struct ClaudarWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudarWidget()
    }
}
