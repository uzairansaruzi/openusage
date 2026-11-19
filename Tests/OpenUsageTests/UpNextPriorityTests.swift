import XCTest
@testable import OpenUsage

@MainActor
final class UpNextPriorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3600

    private let personal = Provider(id: "claude@1", kind: .claude, accountLabel: "Personal")
    private let chatGPT = Provider(id: "codex@1", kind: .codex, accountLabel: "ChatGPT")

    private func limit(
        _ title: String, used: Double, resetsIn: TimeInterval, periodMs: Int = MetricPeriod.weekMs, kind: MetricKind = .percent
    ) -> WidgetData {
        var data = WidgetData(title: title, kind: kind, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(resetsIn)
        data.periodDurationMs = periodMs
        return data
    }

    private func account(_ provider: Provider, _ lines: WidgetData...) -> DashboardAccount {
        DashboardAccount(provider: provider, lines: lines.map { data in
            DashboardLine(
                descriptor: WidgetDescriptor(provider: provider, key: data.title, metricLabel: data.title, sample: data),
                data: data
            )
        })
    }

    private func ids(_ items: [PriorityItem]) -> [String] { items.map(\.id) }

    func testListsEveryOtherLimitSoonestResetFirstAndMarksTheOnesAboutToResetUnused() {
        let accounts = [
            account(personal,
                    limit("Weekly", used: 30, resetsIn: 18 * hour),
                    limit("Session", used: 10, resetsIn: 2 * hour, periodMs: MetricPeriod.sessionMs),
                    limit("Daily", used: 10, resetsIn: 3 * hour, periodMs: MetricPeriod.dayMs),
                    limit("Half", used: 50, resetsIn: 4 * hour),
                    limit("Later", used: 10, resetsIn: 25 * hour)),
            account(chatGPT,
                    limit("Weekly", used: 20, resetsIn: 6 * hour),
                    limit("Key Limit", used: 10, resetsIn: 5 * hour, periodMs: MetricPeriod.monthMs, kind: .dollars)),
        ]

        let board = PriorityBoard.make(accounts: accounts, burningFast: BurningFast(), now: now)

        XCTAssertEqual(ids(board.upNext), ["claude@1.Session", "claude@1.Daily", "claude@1.Half", "codex@1.Key Limit",
                                           "codex@1.Weekly", "claude@1.Weekly", "claude@1.Later"], "soonest reset first")
        XCTAssertEqual(board.upNext.map { $0.resetsInText(now: now) },
                       ["Resets in 2h", "Resets in 3h", "Resets in 4h", "Resets in 5h", "Resets in 6h", "Resets in 18h", "Resets in 1d 1h"])
        XCTAssertEqual(Set(board.upNext.map(\.reason.severity)), [.normal], "the ring keeps meaning what's left")
        XCTAssertEqual(ids(board.useItOrLoseIt), ["codex@1.Weekly", "claude@1.Weekly"],
                       "sessions, daily windows, exactly half left, over a day out, and dollar caps aren't about to reset unused")
        XCTAssertTrue(board.attention.isEmpty, "nothing here is running out")
        XCTAssertEqual(board.summary, .listed)
        XCTAssertTrue(MenuBarContentBuilder.build(board: board, limit: .upToFive).isEmpty, "the menu bar is for running out")
    }

    func testUpNextLeavesOutWhatAnotherSectionListsAndPutsALimitWithNoResetLast() {
        var noReset = WidgetData(title: "Monthly", kind: .percent, used: 10, limit: 100)
        noReset.periodDurationMs = MetricPeriod.monthMs
        let accounts = [account(personal, noReset, limit("Low", used: 90, resetsIn: 3 * hour), limit("Spent", used: 100, resetsIn: hour),
                                limit("Pinned", used: 10, resetsIn: 40 * hour), limit("Weekly", used: 10, resetsIn: 30 * hour))]
        let board = PriorityBoard.make(accounts: accounts, pinned: ["claude@1.Pinned"], now: now)

        XCTAssertEqual(ids(board.upNext), ["claude@1.Weekly", "claude@1.Monthly"])
        XCTAssertEqual(ids(board.attention), ["claude@1.Low"])
        XCTAssertEqual(ids(board.usedUp), ["claude@1.Spent"])
        XCTAssertNil(board.pinned.first?.item, "a pin that would only be up next shows as a plain limit")
    }

    func testListsExactlyWhatTheAlertWouldFireFor() {
        for periodMs in [MetricPeriod.sessionMs, MetricPeriod.dayMs, MetricPeriod.weekMs, MetricPeriod.monthMs] {
            for kind in [MetricKind.percent, .dollars] {
                for used in [0.0, 30, 49, 49.6, 50, 51] {
                    for resetsIn in [-hour, 1, hour, 24 * hour, 24 * hour + 1] {
                        let data = limit("Weekly", used: used, resetsIn: resetsIn, periodMs: periodMs, kind: kind)
                        let board = PriorityBoard.make(accounts: [account(personal, data)], now: now)
                        XCTAssertEqual(!board.useItOrLoseIt.isEmpty, PaceNotificationLogic.isUnusedNearReset(data, now: now),
                                       "\(kind) \(periodMs)ms window, \(used) used, resets in \(resetsIn)s")
                    }
                }
            }
        }
    }

    func testAPinnedLimitAboutToResetUnusedStaysPinned() {
        let accounts = [account(personal, limit("Weekly", used: 30, resetsIn: 18 * hour))]
        let board = PriorityBoard.make(accounts: accounts, pinned: ["claude@1.Weekly"], now: now)
        XCTAssertEqual(board.pinned.map(\.id), ["claude@1.Weekly"])
        XCTAssertEqual(board.pinned.first?.item?.resetsInText(now: now), "Resets in 18h")
        XCTAssertTrue(board.upNext.isEmpty)
    }
}
