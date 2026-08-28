import AppKit
import SwiftUI
import Combine

/// A standard titled window showing the full usage breakdown.
///
/// This replaces the old borderless desktop-level panel. That panel sat at
/// desktop-icon level, so it was invisible to Mission Control and the window
/// switcher and got buried behind everything. A real window shows up in all the
/// usual places, can be moved/resized/minimised normally, and remembers its
/// frame. The at-a-glance role now belongs to the WidgetKit widget.
@MainActor
final class UsageWindowController: NSObject, NSWindowDelegate {
    private let model: UsageModel
    private let window: NSWindow
    private var cancellable: AnyCancellable?
    private static let frameAutosave = "ClaudarWindowFrame"
    private static let floatKey = "UsageWindowFloats"

    /// True once the user has a remembered/manually-set frame, so we stop
    /// auto-fitting and respect their size.
    private var hasUserFrame = false

    /// Called when the user closes the window, so the menu checkmark stays honest.
    var onVisibilityChange: (() -> Void)?

    init(model: UsageModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 210),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Claudar"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        // Low floor: the computed fit is the real driver, and a tall floor would
        // silently pad the window when there are few limits.
        window.minSize = NSSize(width: 260, height: 120)
        // Scrollable because the all-orgs layout can outgrow the height ceiling
        // below (three or more orgs), and clipping the bottom org would be worse
        // than a scrollbar. With one org it never scrolls and looks unchanged.
        window.contentView = NSHostingView(
            rootView: ScrollView(.vertical) {
                UsagePanelView(model: model, fixedWidth: nil, showsTitle: false)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        )
        // Show on every Space — it's a reference window, not a document.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        super.init()
        window.delegate = self

        hasUserFrame = window.setFrameUsingName(Self.frameAutosave)
        if !hasUserFrame {
            positionTopRight()
        }
        window.setFrameAutosaveName(Self.frameAutosave)
        applyFloating(Self.floats)

        // Keep the window title showing the headline number at a glance.
        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let name = model.orgs.count > 1
                        ? (model.activeOrg?.name ?? "Claudar") : "Claudar"
                    if let pct = model.menuBarUtilization {
                        self.window.title = "\(name) · \(UsageFormat.percent(pct))"
                    } else {
                        self.window.title = name
                    }
                    // If the window was opened before the first fetch landed, the
                    // row count just changed — re-fit unless the user has sized it.
                    if !self.hasUserFrame, self.window.isVisible {
                        self.sizeToFitContent()
                    }
                }
            }
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        // Snug the window to its content on first open, so there's no dead space
        // below the limits. Once the user resizes (or a saved frame exists), we
        // leave their size alone.
        if !hasUserFrame { sizeToFitContent() }
        // The app is an accessory (no Dock icon), so it isn't active by default;
        // activate explicitly or the window opens behind the current app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Sizes the window's height to wrap the current content, keeping the
    /// top-left corner fixed.
    ///
    /// The height is computed from the content rather than measured. Both
    /// `NSHostingView.fittingSize` and `NSHostingController.sizeThatFits` over-
    /// report badly for this layout (fittingSize returned ~844pt, and
    /// sizeThatFits still came back far too tall), because the panel is pinned
    /// to the top with a flexible frame for resize behavior. The layout is
    /// simple and fixed-metric, so adding it up is both accurate and stable.
    private func sizeToFitContent() {
        let width = window.contentView?.bounds.width ?? 300

        // Every number here comes from PanelMetrics, which UsagePanelView lays
        // itself out with, so the two can't drift.
        let padding = PanelMetrics.padding * 2
        var content: CGFloat = 0

        if model.showsAllOrgs {
            // Each org contributes a header plus its own rows, and the groups are
            // separated by orgGroupSpacing rather than the usual stack spacing.
            var groups: [CGFloat] = []
            for org in model.orgs {
                var blocks: [CGFloat] = [PanelMetrics.orgHeaderHeight]
                let limits = model.limits(for: org.id)
                if limits.isEmpty && model.error(for: org.id) == nil {
                    blocks.append(PanelMetrics.loadingHeight)
                }
                for limit in limits {
                    blocks.append(PanelMetrics.rowHeight(hasReset: limit.resetsAt != nil))
                }
                if model.error(for: org.id) != nil {
                    blocks.append(PanelMetrics.errorHeight)
                }
                groups.append(
                    blocks.reduce(0, +)
                        + PanelMetrics.stackSpacing * CGFloat(max(0, blocks.count - 1))
                )
            }
            content = groups.reduce(0, +)
                + PanelMetrics.orgGroupSpacing * CGFloat(max(0, groups.count - 1))
                + PanelMetrics.stackSpacing + PanelMetrics.footerHeight
        } else {
            var blocks: [CGFloat] = []
            if model.limits.isEmpty && model.errorMessage == nil {
                blocks.append(PanelMetrics.loadingHeight)
            }
            for limit in model.limits {
                blocks.append(PanelMetrics.rowHeight(hasReset: limit.resetsAt != nil))
            }
            if model.errorMessage != nil {
                blocks.append(PanelMetrics.errorHeight)
            }
            blocks.append(PanelMetrics.footerHeight)    // "Updated …" + plan badge
            content = blocks.reduce(0, +)
                + PanelMetrics.stackSpacing * CGFloat(max(0, blocks.count - 1))
        }

        let desired = padding + content + PanelMetrics.bottomBreathingRoom

        // Guard rails: never smaller than minSize, never a full-screen window.
        let ceiling = min(560, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
        let clamped = min(max(desired, window.minSize.height), ceiling)

        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(NSSize(width: width, height: clamped))
        window.setFrameTopLeftPoint(topLeft)
    }

    /// Re-fits after something changed the panel's height wholesale, such as
    /// switching the all-orgs layout on or off. Respects a size the user chose.
    func refit() {
        guard !hasUserFrame, window.isVisible else { return }
        sizeToFitContent()
    }

    func hide() { window.orderOut(nil) }

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    // MARK: - Float on top

    static var floats: Bool {
        get { UserDefaults.standard.object(forKey: floatKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: floatKey) }
    }

    func applyFloating(_ on: Bool) {
        window.level = on ? .floating : .normal
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Closing is just hiding; report it so the menu updates.
        DispatchQueue.main.async { [weak self] in self?.onVisibilityChange?() }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // The user chose a size — stop auto-fitting and respect it from now on.
        hasUserFrame = true
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: vf.maxX - window.frame.width - 24, y: vf.maxY - 24))
    }
}
