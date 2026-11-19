import AppKit
import SwiftUI
import XCTest
@testable import OpenUsage

@MainActor
final class PriorityDashboardTests: QuietWindowTestCase {
    private final class Frames {
        var byID: [String: CGRect] = [:]
    }

    private struct Hosted {
        let window: NSWindow
        let host: NSView
        let defaults: UserDefaults
        let popover: PopoverState
        let frames: Frames
        let accounts: [String]
    }

    /// The popover with accounts tall enough to scroll, where only the last one has a limit in trouble.
    private func hostDashboard(tab: DashboardTab) -> Hosted {
        let defaults = isolatedDefaults()
        let store = AccountStore(defaults: defaults, vault: InMemoryCredentialVault())
        let accounts = ["One", "Two", "Three", "Four", "Five", "Six"].map {
            store.add(kind: .claude, label: $0, credential: .apiKey("key")).cardID
        }
        let container = AppContainer.forTesting(accounts: store, defaults: defaults)
        container.popover.dashboardTab = tab
        for id in accounts {
            container.dataStore.snapshots[id] = ProviderSnapshot(
                providerID: id, displayName: "Claude", plan: "Ultra",
                lines: ["Session", "Weekly"].map {
                    .progress(label: $0, used: id == accounts.last ? 95 : 10, limit: 100, format: .percent)
                }
            )
        }
        let frames = Frames()
        let view = DashboardView()
            .defaultAppStorage(defaults)
            .onPreferenceChange(ReorderFramePreferenceKey.self) { frames.byID = $0 }
            .environment(\.reduceAnimations, true)
            .environment(container)
            .environment(container.layout)
            .environment(container.popover)
            .environment(container.dataStore)
            .environment(container.renaming)
            .environment(UpdaterController())
            .environment(\.colorScheme, .light)
        let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 300))
        return Hosted(window: window, host: host, defaults: defaults, popover: container.popover, frames: frames, accounts: accounts)
    }

    func testClickingAnAmountFlipsItAndTheRowItselfDoesNothing() async throws {
        let hosted = hostDashboard(tab: .priority)
        click(CGPoint(x: hosted.host.bounds.midX, y: 90), hosted.window, hosted.host)
        XCTAssertEqual(hosted.popover.dashboardTab, .priority)
        XCTAssertNil(hosted.defaults.string(forKey: "meterStyle"))

        click(CGPoint(x: hosted.host.bounds.maxX - 40, y: 90), hosted.window, hosted.host)
        try await waitUntil { hosted.defaults.string(forKey: "meterStyle") == WidgetDisplayMode.used.rawValue }
    }

    func testPickingATabGoesBackToTheTop() async throws {
        let hosted = hostDashboard(tab: .allUsage)
        let first = try XCTUnwrap(hosted.accounts.first)
        try await waitUntil { hosted.frames.byID[first] != nil }
        let top = try XCTUnwrap(hosted.frames.byID[first]).minY
        let scroller = try XCTUnwrap(scrollViews(in: hosted.host).first)
        scroller.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroller.reflectScrolledClipView(scroller.contentView)
        try await waitUntil { hosted.frames.byID[first].map { $0.minY < top - 50 } == true }

        hosted.popover.dashboardTab = .priority
        try await waitUntil { hosted.frames.byID[first] == nil }
        hosted.popover.dashboardTab = .allUsage
        try await waitUntil { hosted.frames.byID[first].map { abs($0.minY - top) < 1 } == true }
    }

    func testFirstAccountCanBeAddedFromEitherEmptyTab() async throws {
        let defaults = isolatedDefaults()
        let registry = WidgetRegistry(providers: [], descriptors: [])
        for tab in DashboardTab.allCases {
            let popover = PopoverState()
            popover.dashboardTab = tab
            let view = DashboardContentView(reorderSpaceName: "reorder", reorderLift: .constant(nil), scrollPosition: .constant(ScrollPosition(edge: .top)))
                .environment(LayoutStore(registry: registry, defaults: defaults))
                .environment(popover)
                .environment(UpdaterController())
            let (window, host) = show(view, in: .titled, size: CGSize(width: PanelMetrics.width, height: 300))
            if #available(macOS 26, *) {
                // The call to action is the last control, just above the empty view's bottom padding.
                let empty = EmptyDashboardView {}.frame(width: PanelMetrics.width - 2 * PanelMetrics.margin)
                let height = NSHostingView(rootView: empty).fittingSize.height
                click(CGPoint(x: host.bounds.midX, y: DashboardContentView.barGap + height - 26 - 14), window, host)
            } else {
                // An AppKit button tracks mouse-down in a modal loop on macOS 15.
                let button = try XCTUnwrap(firstButton(in: host))
                button.performClick(nil)
            }
            try await waitUntil { popover.isAddingAccount }
        }
    }

    /// With nothing running out, Running Out leaves no header or row behind, and every limit waits under Up Next.
    func testRunningOutIsHiddenWhenNothingIsRunningOut() async throws {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
        let provider = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
        let data = WidgetData(title: "Session", kind: .percent, used: 10, limit: 100)
        let session = DashboardLine(descriptor: WidgetDescriptor(provider: provider, key: "Session", metricLabel: "Session", sample: data), data: data)
        let board = PriorityBoard.make(accounts: [DashboardAccount(provider: provider, lines: [session])], now: Date())

        let (window, host) = show(PriorityBoardList(board: board, now: Date()).frame(width: PanelMetrics.width - 2 * PanelMetrics.margin))
        defer { window.close() }
        try await waitUntil { !headings(in: host).isEmpty }
        XCTAssertEqual(headings(in: host), ["Up Next"])
    }

    /// Used Up is the least important section, so it comes last, after Running Out, Up Next, and Needs Attention.
    func testUsedUpIsAlwaysTheLastSection() async throws {
        NSApplication.shared.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        defer { NSApplication.shared.setValue(false, forKey: "accessibilityEnhancedUserInterface") }
        let now = Date()
        let claude = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
        let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")
        let cursor = Provider(id: "cursor@1", kind: .cursor, accountLabel: "Work")
        func line(_ provider: Provider, _ title: String, used: Double, resetsIn: TimeInterval) -> DashboardLine {
            var data = WidgetData(title: title, kind: .percent, used: used, limit: 100)
            data.resetsAt = now.addingTimeInterval(resetsIn)
            data.periodDurationMs = MetricPeriod.weekMs
            return DashboardLine(descriptor: WidgetDescriptor(provider: provider, key: title, metricLabel: title, sample: data), data: data)
        }
        let board = PriorityBoard.make(accounts: [
            DashboardAccount(provider: claude, lines: [line(claude, "Weekly", used: 100, resetsIn: 3600),
                                                       line(claude, "Opus", used: 95, resetsIn: 3 * 86400)]),
            DashboardAccount(provider: chatGPT, lines: [line(chatGPT, "Weekly", used: 10, resetsIn: 6 * 3600)]),
            DashboardAccount(provider: cursor, lines: []),
        ], now: now) { $0.provider.id == cursor.id ? .unavailable("Sign in again.") : .current }
        XCTAssertEqual([board.attention.count, board.upNext.count, board.notices.count, board.usedUp.count], [1, 1, 1, 1])

        let (window, host) = show(PriorityBoardList(board: board, now: now).frame(width: PanelMetrics.width - 2 * PanelMetrics.margin))
        defer { window.close() }
        try await waitUntil { headings(in: host).count >= 4 }
        XCTAssertEqual(headings(in: host), ["Running Out", "Up Next", "Needs Attention", "Used Up"])
    }

    /// A skeleton takes the space of the rows that replace it, so nothing around it moves when a reading lands.
    func testSkeletonRowsAreTheHeightOfTheRowsThatReplaceThem() {
        let claude = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
        let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "robin@example.com")
        func height(_ view: some View, width: CGFloat) -> CGFloat {
            NSHostingView(rootView: view.frame(width: width).environment(\.colorScheme, .light)).fittingSize.height
        }
        let firstLaunch = PriorityBoard.make(
            accounts: [DashboardAccount(provider: claude, lines: []), DashboardAccount(provider: chatGPT, lines: [])], now: Date()
        )
        XCTAssertEqual(height(PriorityBoardList(board: firstLaunch, now: Date()), width: PanelMetrics.width - 2 * PanelMetrics.margin), 2 * 46,
                       "one 46 pt Priority row per account, nothing else")

        let lines = ["Session", "Weekly"].map { title in
            let data = WidgetData(title: title, kind: .percent, used: 40, limit: 100)
            return DashboardLine(descriptor: WidgetDescriptor(provider: chatGPT, key: title, metricLabel: title, sample: data), data: data)
        }
        let rowWidth = PanelMetrics.width - 2 * PanelMetrics.margin - 2 * DashboardGrid.cardPadding
        let waiting = DashboardAccountRows(account: DashboardAccount(provider: chatGPT, lines: [], waitingMetricIDs: lines.map(\.id)))
        let read = DashboardAccountRows(account: DashboardAccount(provider: chatGPT, lines: lines))
        XCTAssertEqual(height(waiting, width: rowWidth), height(read, width: rowWidth))
        XCTAssertGreaterThan(height(waiting, width: rowWidth), 2 * DashboardGrid.rowHeight - 1)
    }

    private func firstButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        for child in view.subviews {
            if let button = firstButton(in: child) { return button }
        }
        return nil
    }

    /// The accessibility labels of every heading under `element`, top to bottom.
    private func headings(in element: Any) -> [String] {
        guard let node = element as? NSObject else { return [] }
        let heading = node.value(forKey: "accessibilityRole") as? String == "AXHeading" ? node.value(forKey: "accessibilityLabel") as? String : nil
        return [heading].compactMap { $0 } + (node.value(forKey: "accessibilityChildren") as? [Any] ?? []).flatMap(headings)
    }
}
