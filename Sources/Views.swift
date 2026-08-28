import SwiftUI
import AppKit

/// Layout constants for `UsagePanelView`, in one place because
/// `UsageWindowController.sizeToFitContent()` has to compute the panel's height
/// arithmetically (AppKit's measurement APIs over-report badly for this layout,
/// see the note there). Two copies of these numbers would silently drift.
enum PanelMetrics {
    static let padding: CGFloat = 14
    static let compactPadding: CGFloat = 12
    static let stackSpacing: CGFloat = 10

    // LimitRow internals.
    static let rowSpacing: CGFloat = 3
    static let labelHeight: CGFloat = 16     // a 12 pt label, rendered
    static let barHeight: CGFloat = 6
    static let resetHeight: CGFloat = 13     // a 10 pt line, rendered

    static let loadingHeight: CGFloat = 16
    static let errorHeight: CGFloat = 30     // allows for a second wrapped line
    static let footerHeight: CGFloat = 18
    static let bottomBreathingRoom: CGFloat = 12

    // Grouped (all-orgs) layout.
    static let orgHeaderHeight: CGFloat = 17
    static let orgGroupSpacing: CGFloat = 16

    static func rowHeight(hasReset: Bool) -> CGFloat {
        labelHeight + rowSpacing + barHeight
            + (hasReset ? rowSpacing + resetHeight : 0)
    }
}

/// The Pro / Max / Team / Enterprise pill.
struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan.capitalized)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.12)))
            .foregroundStyle(.secondary)
    }
}

struct LimitRow: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.rowSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.label)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text(UsageFormat.percent(limit.utilization))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(severityColor(limit.utilization))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(severityColor(limit.utilization))
                        .frame(width: max(4, geo.size.width * limit.utilization / 100))
                }
            }
            .frame(height: PanelMetrics.barHeight)
            if limit.resetsAt != nil {
                Text(UsageFormat.resetString(limit.resetsAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One org's block in the all-orgs layout: its name, its plan, its limits.
struct OrgGroup: View {
    let org: OrgInfo
    let limits: [UsageLimit]
    let error: String?
    /// The org the menu bar ring is tracking, marked so the two agree.
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.stackSpacing) {
            HStack(spacing: 5) {
                if isActive {
                    Circle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .help("The menu bar is showing this org")
                }
                Text(org.name)
                    .font(.system(size: 11, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if let plan = org.plan { PlanBadge(plan: plan) }
            }
            if limits.isEmpty && error == nil {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(limits) { LimitRow(limit: $0) }
            if let error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct UsagePanelView: View {
    @ObservedObject var model: UsageModel
    var compact: Bool = false
    /// Menus need an intrinsic width; the resizable window passes nil to flex.
    var fixedWidth: CGFloat? = 264
    /// The window puts the name in its title bar, so it hides this one.
    var showsTitle: Bool = true

    @ViewBuilder private var subscriptionBadge: some View {
        if let sub = model.subscription, !sub.isEmpty {
            PlanBadge(plan: sub)
        }
    }

    /// Every org, stacked. Each group carries its own name, plan, and errors, so
    /// the shared title row and badge would only duplicate them.
    private var allOrgsBody: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.orgGroupSpacing) {
            ForEach(model.orgs) { org in
                OrgGroup(
                    org: org,
                    limits: model.limits(for: org.id),
                    error: model.error(for: org.id),
                    isActive: org.id == model.activeOrg?.id
                )
            }
        }
    }

    private var singleOrgBody: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.stackSpacing) {
            // Without the title there's nothing to balance the badge against, so
            // the whole row is dropped and the badge moves to the footer.
            if showsTitle {
                HStack {
                    // With several orgs the panel names the one it's showing;
                    // with one there's nothing to disambiguate, so it stays put.
                    Text(model.orgs.count > 1 ? (model.activeOrg?.name ?? "Claudar") : "Claudar")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    subscriptionBadge
                }
            }
            if model.limits.isEmpty && model.errorMessage == nil {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ForEach(model.limits) { limit in
                LimitRow(limit: limit)
            }
            if let err = model.errorMessage {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.stackSpacing) {
            if model.showsAllOrgs {
                allOrgsBody
            } else {
                singleOrgBody
            }
            HStack(alignment: .center) {
                if let updated = model.lastUpdated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if !showsTitle && !model.showsAllOrgs {
                    Spacer()
                    subscriptionBadge
                }
            }
        }
        .padding(compact ? PanelMetrics.compactPadding : PanelMetrics.padding)
        .frame(width: fixedWidth, alignment: .leading)
        .frame(maxWidth: fixedWidth == nil ? .infinity : nil, alignment: .leading)
    }
}

// The frosted-glass chrome that used to wrap this view is gone: the usage window
// is now a standard titled window and uses the system's own window background.
