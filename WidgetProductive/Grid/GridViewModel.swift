import Foundation

// MARK: - WeekRow

struct WeekRow: Identifiable {
    enum Kind: Equatable {
        case worked(serviceID: String, label: String)
        case absence(eventID: String, label: String)
    }

    let kind: Kind
    var minutesByDate: [String: Int] = [:]
    /// True when this row was carried from last week but has no active budget booking this week.
    var hasNoActiveBooking: Bool = false
    /// Per-cell sum of individually-approved (locked) entry minutes. Sets a floor the user can't go below.
    var lockedFloorByDate: [String: Int] = [:]
    /// Dates where the absence booking is approved — those cells are read-only.
    var approvedAbsenceDates: Set<String> = []
    /// True when the row was added locally this session (not yet on the server).
    var isLocallyAdded: Bool = false

    var id: String {
        switch kind {
        case .worked(let sid, _):  return "w:\(sid)"
        case .absence(let eid, _): return "a:\(eid)"
        }
    }

    var label: String {
        switch kind {
        case .worked(_, let l):  return l
        case .absence(_, let l): return l
        }
    }

    var isAbsence: Bool {
        if case .absence = kind { return true }
        return false
    }

    var serviceID: String? {
        if case .worked(let sid, _) = kind { return sid }
        return nil
    }

    var eventID: String? {
        if case .absence(let eid, _) = kind { return eid }
        return nil
    }
}

// MARK: - GridError

enum GridError: LocalizedError {
    case personNotFound(String)

    var errorDescription: String? {
        switch self {
        case .personNotFound(let email): "No person found for email: \(email)"
        }
    }
}

// MARK: - GridViewModel

@MainActor
@Observable
final class GridViewModel {

    // MARK: State
    var weekOffset: Int = 0
    var weekDates: [Date] = []
    var rows: [WeekRow] = []
    var timesheetsByDate: [String: Timesheet] = [:]
    var person: Person? = nil
    var isLoading = false
    var loadError: String? = nil

    // MARK: Edit state (Slice 3)
    /// User edits keyed by rowID → date → desired total minutes.
    /// Key is present only when the user has touched a cell; absence means "use prefill/server value".
    var editsByRowID: [String: [String: Int]] = [:]

    /// Services available for Add Row. Populated on first open of the add-row panel.
    var availableServices: [(id: String, label: String)] = []
    var isLoadingServices = false

    private let api = APIClient()

    init() {
        weekDates = Self.weekDates(offset: 0)
    }

    // MARK: Week navigation

    var weekLabel: String {
        guard weekDates.count == 5 else { return "" }
        let cal = Calendar(identifier: .iso8601)
        let firstComps = cal.dateComponents([.month, .day], from: weekDates[0])
        let lastComps  = cal.dateComponents([.month, .day, .year], from: weekDates[4])
        let mf = DateFormatter()
        mf.locale = Locale(identifier: "en_US_POSIX")
        mf.dateFormat = "MMM"
        let firstMonth = mf.string(from: weekDates[0])
        let lastMonth  = mf.string(from: weekDates[4])
        let year = lastComps.year ?? 0
        if firstComps.month == lastComps.month {
            return "\(firstMonth) \(firstComps.day!)–\(lastComps.day!), \(year)"
        }
        return "\(firstMonth) \(firstComps.day!)–\(lastMonth) \(lastComps.day!), \(year)"
    }

    func previousWeek() {
        weekOffset -= 1
        weekDates = Self.weekDates(offset: weekOffset)
        Task { await load() }
    }

    func nextWeek() {
        weekOffset += 1
        weekDates = Self.weekDates(offset: weekOffset)
        Task { await load() }
    }

    func refresh() {
        Task { await load() }
    }

    // MARK: Load

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let personID = try await resolvePersonID()

            let dateStrings = weekDates.map(Self.isoDate)
            let afterDate  = Self.isoDate(Self.shift(weekDates[0], by: -1))
            let beforeDate = Self.isoDate(Self.shift(weekDates[4], by:  1))

            let pEnv = try await api.get(path: "/people/\(personID)", as: RawResource.self)

            let eEnv = try await api.get(
                path: "/time_entries",
                query: [
                    .init(name: "filter[person_id]", value: personID),
                    .init(name: "filter[after]",     value: afterDate),
                    .init(name: "filter[before]",    value: beforeDate),
                    .init(name: "include",           value: "service"),
                    .init(name: "page[size]",        value: "200"),
                ],
                as: [RawResource].self
            )

            let bEnv = try await api.get(
                path: "/bookings",
                query: [
                    .init(name: "filter[person_id]", value: personID),
                    .init(name: "filter[after]",     value: afterDate),
                    .init(name: "filter[before]",    value: beforeDate),
                    .init(name: "include",           value: "event,service"),
                    .init(name: "page[size]",        value: "200"),
                ],
                as: [RawResource].self
            )

            let timesheets = await fetchTimesheets(
                personID: personID,
                weekDates: dateStrings,
                afterDate: afterDate,
                beforeDate: beforeDate
            )

            let person   = try Person(raw: pEnv.data)
            let entries  = try eEnv.data.map { try TimeEntry(raw: $0) }
            let bookings = try bEnv.data.map { try Booking(raw: $0) }

            var serviceNames: [String: String] = [:]
            for r in ((eEnv.included ?? []) + (bEnv.included ?? [])) where r.type == "services" {
                serviceNames[r.id] = r.attributes?["name"]?.string ?? r.id
            }
            var eventNames: [String: String] = [:]
            for r in (bEnv.included ?? []) where r.type == "events" {
                eventNames[r.id] = r.attributes?["name"]?.string ?? r.id
            }

            // Last-week carry-forward (non-fatal)
            let lastWeekDateObjs = Self.weekDates(offset: weekOffset - 1)
            let lastWeekDateStrs = lastWeekDateObjs.map(Self.isoDate)
            let lastAfterDate    = Self.isoDate(Self.shift(lastWeekDateObjs[0], by: -1))
            let lastBeforeDate   = Self.isoDate(Self.shift(lastWeekDateObjs[4], by:  1))

            let lwEnv = try? await api.get(
                path: "/time_entries",
                query: [
                    .init(name: "filter[person_id]", value: personID),
                    .init(name: "filter[after]",     value: lastAfterDate),
                    .init(name: "filter[before]",    value: lastBeforeDate),
                    .init(name: "include",           value: "service"),
                    .init(name: "page[size]",        value: "200"),
                ],
                as: [RawResource].self
            )
            let lastWeekEntries = (try? lwEnv?.data.map { try TimeEntry(raw: $0) }) ?? []
            for r in (lwEnv?.included ?? []) where r.type == "services" {
                if serviceNames[r.id] == nil {
                    serviceNames[r.id] = r.attributes?["name"]?.string ?? r.id
                }
            }

            // Holidays (non-fatal; filter param unverified — swallow all errors)
            let holidayDates = await fetchHolidayDates(
                calendarID: person.holidayCalendarID,
                afterDate: afterDate,
                beforeDate: beforeDate
            )

            self.person = person
            self.editsByRowID = [:]
            self.rows = Self.buildRowsWithPrefill(
                entries: entries,
                lastWeekEntries: lastWeekEntries,
                bookings: bookings,
                weekDates: dateStrings,
                lastWeekDates: lastWeekDateStrs,
                serviceNames: serviceNames,
                eventNames: eventNames,
                holidayDates: holidayDates,
                person: person
            )
            self.timesheetsByDate = Dictionary(
                uniqueKeysWithValues: timesheets.filter { !$0.date.isEmpty }.map { ($0.date, $0) }
            )
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Cell editing (Slice 3)

    /// Displayed value for a cell: user edit if present, otherwise server/prefill value.
    func cellMinutes(rowID: String, date: String) -> Int? {
        if let edited = editsByRowID[rowID]?[date] { return edited }
        return rows.first { $0.id == rowID }?.minutesByDate[date]
    }

    /// Locked floor for the cell (sum of individually approved entries). Zero if none.
    func lockedFloor(rowID: String, date: String) -> Int {
        rows.first { $0.id == rowID }?.lockedFloorByDate[date] ?? 0
    }

    /// True when the cell can be edited by the user.
    /// Approved-timesheet days and approved-absence cells are read-only; everything else is editable.
    func isCellEditable(row: WeekRow, date: String) -> Bool {
        // Approved timesheet day → all cells read-only.
        if timesheetsByDate[date]?.status == .approved { return false }
        // Approved absence cells are read-only.
        if row.isAbsence && row.approvedAbsenceDates.contains(date) { return false }
        return true
    }

    /// Set a cell's desired total minutes, clamping to the locked floor.
    /// Returns the clamped value actually stored.
    @discardableResult
    func updateCell(rowID: String, date: String, minutes: Int) -> Int {
        let floor  = lockedFloor(rowID: rowID, date: date)
        let clamped = max(floor, minutes)
        editsByRowID[rowID, default: [:]][date] = clamped
        return clamped
    }

    // MARK: Daily totals & warnings (Slice 3)

    enum DayWarning: Equatable {
        case none, under, over
    }

    /// Sum of all cell values (worked rows only) for a given date.
    func dailyTotalMinutes(date: String) -> Int {
        rows
            .filter { !$0.isAbsence }
            .reduce(0) { sum, row in sum + (cellMinutes(rowID: row.id, date: date) ?? 0) }
    }

    /// Over/under warning for a given date relative to the daily capacity target.
    func dailyWarning(weekdayIndex: Int, date: String) -> DayWarning {
        guard let p = person else { return .none }
        let target = p.dailyTargetMinutes(weekday: weekdayIndex, on: date)
        guard target > 0 else { return .none }
        let total  = dailyTotalMinutes(date: date)
        if total == 0  { return .none }    // nothing entered yet — not a warning
        if total > target  { return .over }
        if total < target  { return .under }
        return .none
    }

    // MARK: Add Row (Slice 3 — stages locally; Slice 4 writes to server)

    func addWorkedRow(serviceID: String, label: String) {
        let id = "w:\(serviceID)"
        guard !rows.contains(where: { $0.id == id }) else { return }
        var row = WeekRow(kind: .worked(serviceID: serviceID, label: label))
        row.isLocallyAdded = true
        rows.append(row)
    }

    func addAbsenceRow(eventID: String, label: String) {
        let id = "a:\(eventID)"
        guard !rows.contains(where: { $0.id == id }) else { return }
        var row = WeekRow(kind: .absence(eventID: eventID, label: label))
        row.isLocallyAdded = true
        rows.append(row)
    }

    /// Load the service list for the Add Row panel (lazy; no-op if already loaded).
    func loadAvailableServices() {
        guard availableServices.isEmpty, !isLoadingServices else { return }
        isLoadingServices = true
        Task {
            defer { isLoadingServices = false }
            guard let env = try? await api.get(
                path: "/services",
                query: [
                    .init(name: "filter[time_tracking_enabled]", value: "true"),
                    .init(name: "page[size]", value: "200"),
                ],
                as: [RawResource].self
            ) else { return }
            let services = (try? env.data.map { try Service(raw: $0) }) ?? []
            availableServices = services.map { (id: $0.id, label: $0.name) }
                .sorted { $0.label < $1.label }
        }
    }

    // MARK: Person resolution

    private func resolvePersonID() async throws -> String {
        if let pid = try Secrets.personID() { return pid }
        let email = try Secrets.email()
        let env = try await api.get(
            path: "/people",
            query: [URLQueryItem(name: "filter[email]", value: email)],
            as: [RawResource].self
        )
        guard let first = env.data.first else { throw GridError.personNotFound(email) }
        return first.id
    }

    // MARK: Timesheet fetch with fallback

    private func fetchTimesheets(
        personID: String,
        weekDates: [String],
        afterDate: String,
        beforeDate: String
    ) async -> [Timesheet] {
        let weekSet = Set(weekDates)

        do {
            let env = try await api.get(
                path: "/timesheets",
                query: [
                    .init(name: "filter[person_id]", value: personID),
                    .init(name: "filter[after]",     value: afterDate),
                    .init(name: "filter[before]",    value: beforeDate),
                    .init(name: "page[size]",        value: "10"),
                ],
                as: [RawResource].self
            )
            return env.data.compactMap { try? Timesheet(raw: $0) }
                .filter { weekSet.contains($0.date) }
        } catch APIError.http(let code, _) where code == 400 {
            // Range filter not supported — fall through to per-day requests.
        } catch {
            return []
        }

        var result: [Timesheet] = []
        for dateStr in weekDates {
            if let env = try? await api.get(
                path: "/timesheets",
                query: [
                    .init(name: "filter[person_id]", value: personID),
                    .init(name: "filter[date]",      value: dateStr),
                    .init(name: "page[size]",        value: "1"),
                ],
                as: [RawResource].self
            ) {
                result += env.data.compactMap { try? Timesheet(raw: $0) }
            }
        }
        return result
    }

    // MARK: Holiday fetch (non-fatal)

    private func fetchHolidayDates(
        calendarID: String?,
        afterDate: String,
        beforeDate: String
    ) async -> Set<String> {
        guard let cid = calendarID, !cid.isEmpty else { return [] }
        guard let env = try? await api.get(
            path: "/holidays",
            query: [
                .init(name: "filter[holiday_calendar_id]", value: cid),
                .init(name: "filter[after]",               value: afterDate),
                .init(name: "filter[before]",              value: beforeDate),
                .init(name: "page[size]",                  value: "50"),
            ],
            as: [RawResource].self
        ) else { return [] }
        let holidays = (try? env.data.map { try Holiday(raw: $0) }) ?? []
        return Set(holidays.map(\.date))
    }

    // MARK: Row assembly with prefill

    // nonisolated: pure function, no actor state; internal so tests can call it directly.
    nonisolated static func buildRowsWithPrefill(
        entries: [TimeEntry],
        lastWeekEntries: [TimeEntry],
        bookings: [Booking],
        weekDates: [String],
        lastWeekDates: [String],
        serviceNames: [String: String],
        eventNames: [String: String],
        holidayDates: Set<String>,
        person: Person
    ) -> [WeekRow] {
        let weekSet     = Set(weekDates)
        let lastWeekSet = Set(lastWeekDates)

        // 1. Absence rows + approved-absence reduction per date.
        //    All absence bookings render a row; only *approved* ones reduce the worked target.
        var absenceMinutesByDate: [String: Int] = [:]
        var absenceMap: [String: WeekRow] = [:]

        for booking in bookings where booking.isAbsence {
            guard let eid = booking.eventID else { continue }
            if absenceMap[eid] == nil {
                absenceMap[eid] = WeekRow(kind: .absence(eventID: eid, label: eventNames[eid] ?? eid))
            }
            for (idx, dateStr) in weekDates.enumerated() {
                guard dateStr >= booking.startedOn, dateStr <= booking.endedOn else { continue }
                let target = person.dailyTargetMinutes(weekday: idx, on: dateStr)
                let mins = booking.dailyMinutes(target: target)
                guard mins > 0 else { continue }
                absenceMap[eid]!.minutesByDate[dateStr, default: 0] += mins
                if booking.isApprovedAbsence {
                    absenceMinutesByDate[dateStr, default: 0] += mins
                    absenceMap[eid]!.approvedAbsenceDates.insert(dateStr)
                }
            }
        }

        // 2. Active budget booking services (active on at least one selected-week day).
        var activeBudgetServiceIDs: Set<String> = []
        for bk in bookings where bk.isBudget {
            guard let sid = bk.serviceID else { continue }
            for dateStr in weekDates where dateStr >= bk.startedOn && dateStr <= bk.endedOn {
                activeBudgetServiceIDs.insert(sid)
                break
            }
        }

        // 3. Server entries for the selected week: serviceID → [date: totalMinutes].
        //    Also collect locked (individually approved) floor per (service, date).
        var serverIndex: [String: [String: Int]] = [:]
        var lockedFloorIndex: [String: [String: Int]] = [:]
        for entry in entries where weekSet.contains(entry.date) {
            let sid = entry.serviceID ?? "__no_service__"
            serverIndex[sid, default: [:]][entry.date, default: 0] += entry.minutes
            if entry.isLocked {
                lockedFloorIndex[sid, default: [:]][entry.date, default: 0] += entry.minutes
            }
        }

        // 4. Last-week entries: serviceID → [weekdayIndex: totalMinutes].
        var lastWeekIndex: [String: [Int: Int]] = [:]
        for entry in lastWeekEntries where lastWeekSet.contains(entry.date) {
            guard let sid = entry.serviceID, entry.minutes > 0 else { continue }
            if let idx = lastWeekDates.firstIndex(of: entry.date) {
                lastWeekIndex[sid, default: [:]][idx, default: 0] += entry.minutes
            }
        }

        // 5. All worked service IDs (server + active budget + last-week carry).
        var allWorkedServiceIDs: Set<String> = Set(serverIndex.keys).subtracting(["__no_service__"])
        allWorkedServiceIDs.formUnion(activeBudgetServiceIDs)
        allWorkedServiceIDs.formUnion(Set(lastWeekIndex.keys))

        // 6. Build each worked row with prefill.
        var workedMap: [String: WeekRow] = [:]

        for sid in allWorkedServiceIDs {
            var row = WeekRow(kind: .worked(serviceID: sid, label: serviceNames[sid] ?? sid))

            for (idx, dateStr) in weekDates.enumerated() {
                // Server entry always wins.
                if let serverMins = serverIndex[sid]?[dateStr] {
                    if serverMins > 0 { row.minutesByDate[dateStr] = serverMins }
                    continue
                }

                // Holiday → no entry.
                if holidayDates.contains(dateStr) { continue }

                let dailyTarget = person.dailyTargetMinutes(weekday: idx, on: dateStr)
                let absenceMins = absenceMinutesByDate[dateStr] ?? 0
                let remaining   = max(0, dailyTarget - absenceMins)
                guard remaining > 0 else { continue }

                if absenceMins > 0 {
                    // Partial approved absence: even-split remaining across active budget services.
                    guard activeBudgetServiceIDs.contains(sid),
                          !activeBudgetServiceIDs.isEmpty else { continue }
                    let split = remaining / activeBudgetServiceIDs.count
                    if split > 0 { row.minutesByDate[dateStr] = split }
                } else {
                    // No absence: carry-forward if last week has any entries for this weekday.
                    let anyCarry = lastWeekIndex.values.contains { $0[idx, default: 0] > 0 }
                    if anyCarry {
                        if let lw = lastWeekIndex[sid]?[idx], lw > 0 {
                            row.minutesByDate[dateStr] = lw
                        }
                        // Services with no last-week entry on this weekday get nothing on carry days.
                    } else {
                        // Even-split fallback across active budget booking services.
                        guard activeBudgetServiceIDs.contains(sid),
                              !activeBudgetServiceIDs.isEmpty else { continue }
                        let split = remaining / activeBudgetServiceIDs.count
                        if split > 0 { row.minutesByDate[dateStr] = split }
                    }
                }
            }

            let hasServerData = serverIndex[sid] != nil
            let isActive      = activeBudgetServiceIDs.contains(sid)
            let wasCarried    = lastWeekIndex[sid] != nil

            if hasServerData || isActive || wasCarried {
                row.hasNoActiveBooking = !isActive && wasCarried
                row.lockedFloorByDate  = lockedFloorIndex[sid] ?? [:]
                workedMap[sid] = row
            }
        }

        // Pass through any entries with no service (edge case, no prefill).
        if let noSvcDates = serverIndex["__no_service__"] {
            var row = WeekRow(kind: .worked(serviceID: "__no_service__", label: "Unknown service"))
            for (dateStr, mins) in noSvcDates where mins > 0 {
                row.minutesByDate[dateStr] = mins
            }
            if !row.minutesByDate.isEmpty { workedMap["__no_service__"] = row }
        }

        return workedMap.values.sorted { $0.label < $1.label }
             + absenceMap.values.sorted { $0.label < $1.label }
    }

    // MARK: Date helpers

    static func weekDates(offset: Int) -> [Date] {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        let monday = cal.dateInterval(of: .weekOfYear, for: Date())!.start
        let weekStart = cal.date(byAdding: .weekOfYear, value: offset, to: monday)!
        return (0..<5).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    static func isoDate(_ date: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        return fmt.string(from: date)
    }

    private static func shift(_ date: Date, by days: Int) -> Date {
        Calendar(identifier: .iso8601).date(byAdding: .day, value: days, to: date)!
    }
}
