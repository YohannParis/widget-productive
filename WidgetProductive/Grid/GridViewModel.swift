import Foundation

// MARK: - WeekRow

struct WeekRow: Identifiable {
    enum Kind: Equatable {
        case worked(serviceID: String, label: String)
        case absence(eventID: String, label: String)
    }

    let kind: Kind
    var minutesByDate: [String: Int] = [:]

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
            // Shift by ±1 day so the filter is inclusive regardless of API semantics.
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

            // Timesheets: try after/before first; 400 means that filter isn't supported —
            // fall back to one request per weekday using filter[date].
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

            self.person = person
            self.rows = Self.buildRows(
                entries: entries,
                bookings: bookings,
                weekDates: dateStrings,
                serviceNames: serviceNames,
                eventNames: eventNames,
                person: person
            )
            self.timesheetsByDate = Dictionary(
                uniqueKeysWithValues: timesheets.filter { !$0.date.isEmpty }.map { ($0.date, $0) }
            )
        } catch {
            loadError = error.localizedDescription
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

        // Attempt 1: range filter (may return 400 if unsupported).
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
            let result = env.data.compactMap { try? Timesheet(raw: $0) }
                .filter { weekSet.contains($0.date) }
            return result
        } catch APIError.http(let code, _) where code == 400 {
            // Range filter not supported — fall through to per-day requests.
        } catch {
            return []  // other errors: non-fatal, return empty
        }

        // Attempt 2: one request per weekday using filter[date].
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

    // MARK: Row assembly

    private static func buildRows(
        entries: [TimeEntry],
        bookings: [Booking],
        weekDates: [String],
        serviceNames: [String: String],
        eventNames: [String: String],
        person: Person
    ) -> [WeekRow] {
        let weekSet = Set(weekDates)
        var workedMap: [String: WeekRow] = [:]

        for entry in entries where weekSet.contains(entry.date) {
            let sid = entry.serviceID ?? "__no_service__"
            if workedMap[sid] == nil {
                let name = serviceNames[sid] ?? sid
                workedMap[sid] = WeekRow(kind: .worked(serviceID: sid, label: name))
            }
            workedMap[sid]!.minutesByDate[entry.date, default: 0] += entry.minutes
        }

        var absenceMap: [String: WeekRow] = [:]
        for booking in bookings where booking.isAbsence {
            guard let eid = booking.eventID else { continue }
            if absenceMap[eid] == nil {
                let name = eventNames[eid] ?? eid
                absenceMap[eid] = WeekRow(kind: .absence(eventID: eid, label: name))
            }
            for (idx, dateStr) in weekDates.enumerated() {
                guard dateStr >= booking.startedOn, dateStr <= booking.endedOn else { continue }
                let target = person.dailyTargetMinutes(weekday: idx, on: dateStr)
                absenceMap[eid]!.minutesByDate[dateStr, default: 0] += booking.dailyMinutes(target: target)
            }
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
