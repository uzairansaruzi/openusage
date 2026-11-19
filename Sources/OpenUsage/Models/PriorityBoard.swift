import Foundation

/// A limit on the board and why it is there.
struct PriorityItem: Identifiable {
    enum Reason: Equatable {
        /// Listed for what's left, the same rule that colors its bar.
        case low(WidgetData.MeterSeverity, remaining: Double, runway: TimeInterval?)
        /// Listed with plenty left because it would run out before it resets at the current pace.
        case burningFast(runway: TimeInterval)
        case usedUp(resetsAt: Date?)
        case emptyBalance
        /// Listed with over half left because it resets within a day, the same rule as the Use It or Lose It alert.
        case useItOrLoseIt(resetsAt: Date)
        /// Every other limit, listed with plenty left by when it resets.
        case upNext(resetsAt: Date?)

        enum Section { case runningOut, usedUp, upNext }

        /// Nil only for a line with no reading or no limit. `burningFast` is nil while Settings leaves limits
        /// burning fast off the list.
        init?(_ line: DashboardLine, now: Date, burningFast: BurningFast?) {
            let data = line.data
            if line.descriptor.balance(in: data)?.number == 0 {
                self = .emptyBalance
                return
            }
            guard data.hasData, data.isBounded else { return nil }
            if data.meterState(now: now) == .spent {
                self = .usedUp(resetsAt: data.resetsAt)
                return
            }
            if data.severity != .normal {
                self = .low(data.severity, remaining: data.remainingFraction, runway: data.runway(now: now))
                return
            }
            if burningFast?.contains(line, now: now) == true, let runway = data.runway(now: now) {
                self = .burningFast(runway: runway)
                return
            }
            if PaceNotificationLogic.isUnusedNearReset(data, now: now), let resetsAt = data.resetsAt {
                self = .useItOrLoseIt(resetsAt: resetsAt)
                return
            }
            self = .upNext(resetsAt: data.resetsAt)
        }

        var severity: WidgetData.MeterSeverity {
            switch self {
            case .low(let severity, _, _): severity
            case .burningFast, .useItOrLoseIt, .upNext: .normal
            case .usedUp, .emptyBalance: .critical
            }
        }

        fileprivate var section: Section {
            switch self {
            case .low, .burningFast: .runningOut
            case .usedUp, .emptyBalance: .usedUp
            case .useItOrLoseIt, .upNext: .upNext
            }
        }

        /// Sorts ascending: what runs out soonest first, then what has no pace to tell by, by what's left. Up Next
        /// goes by reset, soonest first.
        fileprivate var rank: (tier: Int, closeness: Double) {
            switch self {
            case .low(_, _, let runway?), .burningFast(let runway): (0, runway)
            case .low(_, let remaining, nil): (1, remaining)
            case .usedUp(let resetsAt): (2, resetsAt?.timeIntervalSinceReferenceDate ?? .infinity)
            case .emptyBalance: (2, .infinity)
            case .useItOrLoseIt(let resetsAt): (3, resetsAt.timeIntervalSinceReferenceDate)
            case .upNext(let resetsAt): (3, resetsAt?.timeIntervalSinceReferenceDate ?? .infinity)
            }
        }
    }

    let provider: Provider
    let line: DashboardLine
    let reason: Reason
    /// The user pinned it, or for a unified limit any account's copy of it. A pinned item stays under Pinned unless it's used up.
    let isPinned: Bool

    var id: String { line.id }
    var data: WidgetData { line.data }

    /// The line under the amount of a limit listed only for burning fast, in place of its reset. A limit still
    /// listed while its pace eases would run out after its reset, so it shows the reset instead.
    func runOutText(now: Date) -> String? {
        guard case .burningFast(let runway) = reason, let resetsAt = data.resetsAt,
              runway < resetsAt.timeIntervalSince(now), let duration = Formatters.duration(from: now, to: now.addingTimeInterval(runway))
        else { return nil }
        return "Out in \(duration)"
    }

    /// The line under the amount of a limit listed under Up Next, in place of its reset.
    func resetsInText(now: Date) -> String? {
        let resetsAt: Date? = switch reason {
        case .useItOrLoseIt(let resetsAt): resetsAt
        case .upNext(let resetsAt): resetsAt
        default: nil
        }
        guard let resetsAt, let duration = Formatters.duration(from: now, to: resetsAt) else { return nil }
        return "Resets in \(duration)"
    }

    /// The trailing text of a Used Up row: the time until it resets, or for a balance, which has no reset, its amount.
    func usedUpNote(now: Date) -> String? {
        guard case .emptyBalance = reason else { return data.compactResetText(now: now) }
        return data.unboundedDetail
    }
}

/// A metric the user pinned to the top of Priority, listed there until it's used up.
struct PinnedMetric: Identifiable {
    let provider: Provider
    let line: DashboardLine
    /// Why Running Out would list it, or that it's about to reset unused, if it weren't pinned. Its row shows the
    /// same state there. Nil for a limit that would only be up next.
    var item: PriorityItem?

    var id: String { line.id }
    var data: WidgetData { line.data }
}

/// The limits that need the user, most urgent first, for the menu bar and the Priority tab.
struct PriorityBoard {
    enum Summary: Equatable {
        case waitingForUsage
        case noReportedLimits
        case unavailable
        case listed
    }

    enum ReadStatus {
        case waiting, current, unavailable(String)
    }

    struct AccountNotice: Identifiable {
        let provider: Provider
        let message: String
        var id: String { provider.id }
    }

    /// In dashboard order. A pinned metric that's used up is listed only under Used Up, and comes back here
    /// once it resets.
    let pinned: [PinnedMetric]
    /// Every limit running out, pinned or not, most urgent first. The menu bar shows these.
    let runningOut: [PriorityItem]
    /// The Running Out section: what's running out and isn't pinned.
    let attention: [PriorityItem]
    let usedUp: [PriorityItem]
    /// Every unpinned limit not running out or used up, soonest reset first.
    let upNext: [PriorityItem]
    /// The part of Up Next with over half left that resets within a day. The menu bar shows these only with
    /// Always Show In Menu Bar on.
    let useItOrLoseIt: [PriorityItem]
    let notices: [AccountNotice]
    /// Accounts with no first reading yet, in dashboard order. Each shows as a skeleton row under the rest.
    let waiting: [Provider]
    let summary: Summary

    /// Multiple running-low limits can change places as their windows age, even without a new reading, and a
    /// limit burning fast can slow off the list.
    func requiresRankingClock(at now: Date) -> Bool {
        if runningOut.contains(where: { if case .burningFast = $0.reason { true } else { false } }) { return true }
        return runningOut.count > 1 && runningOut.contains { item in
            guard let reset = item.data.resetsAt, let period = item.data.periodDurationMs else { return false }
            return reset > now && period > 0
        }
    }

    /// `accounts` is in the user's saved order, which breaks every tie. `burningFast` is nil while Settings
    /// leaves limits burning fast off the list.
    static func make(
        accounts: [DashboardAccount], pinned pinnedIDs: Set<String> = [], burningFast: BurningFast? = nil, now: Date,
        status: (DashboardAccount) -> ReadStatus = { $0.lines.contains(where: \.data.hasData) ? .current : .waiting }
    ) -> PriorityBoard {
        let lines = accounts.flatMap { account in account.lines.map { (account.provider, $0) } }
        let readings = lines.map { provider, line in
            let isPinned = line.metricIDs.contains(where: pinnedIDs.contains)
            let item = PriorityItem.Reason(line, now: now, burningFast: burningFast).map {
                PriorityItem(provider: provider, line: line, reason: $0, isPinned: isPinned)
            }
            // A pin that would only be up next shows as a plain limit.
            let pinItem = item.flatMap { item -> PriorityItem? in if case .upNext = item.reason { nil } else { item } }
            return (pin: isPinned ? PinnedMetric(provider: provider, line: line, item: pinItem) : nil, item: item)
        }
        let ranked = readings.compactMap(\.item).enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element.reason.rank, rhs.element.reason.rank)
            return (left.tier, left.closeness, lhs.offset) < (right.tier, right.closeness, rhs.offset)
        }.map(\.element)

        var waiting: [Provider] = []
        var notices: [AccountNotice] = []
        // A unified account reads through each account it stands for, so each still says when it needs the user.
        for account in accounts.flatMap({ $0.members.isEmpty ? [$0] : $0.members }) {
            switch status(account) {
            case .waiting: waiting.append(account.provider)
            case .unavailable(let message): notices.append(AccountNotice(provider: account.provider, message: message))
            case .current: break
            }
        }
        // Every limit with a reading is ranked, pinned or not, so an empty list means nothing has reported one.
        let summary: Summary = if !ranked.isEmpty {
            .listed
        } else if !notices.isEmpty {
            .unavailable
        } else if accounts.isEmpty || !waiting.isEmpty {
            .waitingForUsage
        } else {
            .noReportedLimits
        }
        let runningOut = ranked.filter { $0.reason.section == .runningOut }
        let upNext = ranked.filter { $0.reason.section == .upNext && !$0.isPinned }
        return PriorityBoard(
            pinned: readings.compactMap(\.pin).filter { $0.item?.reason.section != .usedUp },
            runningOut: runningOut,
            attention: runningOut.filter { !$0.isPinned },
            usedUp: ranked.filter { $0.reason.section == .usedUp },
            upNext: upNext,
            useItOrLoseIt: upNext.filter { if case .useItOrLoseIt = $0.reason { true } else { false } },
            notices: notices, waiting: waiting, summary: summary
        )
    }

    /// Whether the tab lists anything, pinned or not, worth copying as a picture.
    var hasRows: Bool { summary == .listed || !pinned.isEmpty }
}

extension WidgetDataStore {
    func priorityBoard(in groups: [ProviderMetrics], pinned: Set<String> = [], now: Date, hidingEmails: Bool = false) -> PriorityBoard {
        let accounts = accounts(in: groups)
        return PriorityBoard.make(
            accounts: hidingEmails ? accounts.map(\.hidingEmail) : accounts, pinned: pinned, burningFast: burningFast, now: now
        ) { account in
            if let message = self.problem(for: account.id) {
                // A provider's notice can itself contain account details. Share only the status.
                return .unavailable(hidingEmails ? "Current usage unavailable." : message)
            }
            return self.snapshots[account.id] == nil ? .waiting : .current
        }
    }
}
