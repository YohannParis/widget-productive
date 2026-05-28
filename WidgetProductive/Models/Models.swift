import Foundation

// MARK: - ModelError

enum ModelError: Error {
    case typeMismatch(expected: String, got: String)
}

// MARK: - Relationship extraction helper

private extension Optional where Wrapped == RelationshipLinkage {
    var oneID: String? {
        guard case .one(let r) = self else { return nil }
        return r.id
    }
}

// MARK: - TimeEntry

struct TimeEntry: Identifiable {
    let id: String
    let date: String          // "YYYY-MM-DD"
    let minutes: Int          // API field: "time"
    let approved: Bool
    let approvedAt: String?   // ISO8601; nil = not individually approved (not locked)
    let draft: Bool
    let submitted: Bool
    let rejected: Bool
    let rejectedAt: String?
    let rejectedReason: String?
    let note: String?
    let serviceID: String?
    // Project resolved via included service in Slice 1 (no direct relationship on time_entries).

    /// Locked entries set a per-cell floor that can never be reduced.
    var isLocked: Bool { approved || approvedAt != nil }

    init(raw: RawResource) throws {
        guard raw.type == "time_entries" else {
            throw ModelError.typeMismatch(expected: "time_entries", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id             = raw.id
        date           = a["date"]?.string ?? ""
        minutes        = a["time"]?.int ?? 0
        approved       = a["approved"]?.bool ?? false
        approvedAt     = a["approved_at"]?.string
        draft          = a["draft"]?.bool ?? false
        submitted      = a["submitted"]?.bool ?? false
        rejected       = a["rejected"]?.bool ?? false
        rejectedAt     = a["rejected_at"]?.string
        rejectedReason = a["rejected_reason"]?.string
        note           = a["note"]?.string
        serviceID      = raw.relationships?["service"]?.data.oneID
    }
}

// MARK: - Booking

enum BookingMethod: Int {
    case perDay     = 1  // "time" (minutes/day) gives the per-day amount
    case percentage = 2  // "percentage" × daily capacity target
    // Unknown methods fall back to totalTime / totalWorkingDays.
}

struct Booking: Identifiable {
    let id: String
    let startedOn: String          // "YYYY-MM-DD"
    let endedOn: String            // "YYYY-MM-DD"
    let bookingMethodID: Int
    let bookingMethod: BookingMethod?
    let percentage: Double?        // method 2: e.g. 100 = full day
    let minutesPerDay: Int?        // method 1: API field "time" (minutes per day)
    let totalTime: Int             // total minutes across all days
    let totalWorkingDays: Int
    let approved: Bool
    let approvedAt: String?
    let draft: Bool
    let rejected: Bool
    let canceled: Bool
    let note: String?
    let stageType: Int?            // 2 = budget (work) booking; nil/other = absence
    let eventID: String?           // absence bookings only
    let serviceID: String?         // budget bookings only

    var isAbsence: Bool        { eventID != nil }
    var isBudget: Bool         { stageType == 2 && serviceID != nil }
    var isApprovedAbsence: Bool { isAbsence && approved }

    /// Minutes to log for one day given that day's capacity target (in minutes).
    func dailyMinutes(target: Int) -> Int {
        switch bookingMethod {
        case .perDay:
            return minutesPerDay ?? 0
        case .percentage:
            return Int(Double(target) * (percentage ?? 100) / 100.0)
        case nil:
            guard totalWorkingDays > 0 else { return 0 }
            return totalTime / totalWorkingDays
        }
    }

    init(raw: RawResource) throws {
        guard raw.type == "bookings" else {
            throw ModelError.typeMismatch(expected: "bookings", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id               = raw.id
        startedOn        = a["started_on"]?.string ?? ""
        endedOn          = a["ended_on"]?.string ?? ""
        bookingMethodID  = a["booking_method_id"]?.int ?? 0
        bookingMethod    = BookingMethod(rawValue: bookingMethodID)
        // percentage: JSON integer (e.g. 100) — check both int and double paths.
        let pctRaw       = a["percentage"]
        percentage       = pctRaw?.double ?? pctRaw?.int.map { Double($0) }
        minutesPerDay    = a["time"]?.int
        totalTime        = a["total_time"]?.int ?? 0
        totalWorkingDays = a["total_working_days"]?.int ?? 0
        approved         = a["approved"]?.bool ?? false
        approvedAt       = a["approved_at"]?.string
        draft            = a["draft"]?.bool ?? false
        rejected         = a["rejected"]?.bool ?? false
        canceled         = a["canceled"]?.bool ?? false
        note             = a["note"]?.string
        stageType        = a["stage_type"]?.int
        eventID          = raw.relationships?["event"]?.data.oneID
        serviceID        = raw.relationships?["service"]?.data.oneID
    }
}

// MARK: - Timesheet

// Probe only revealed "date" + "created_at" attributes — state field name ("status" / "state")
// is unconfirmed and will be verified against a live approved/submitted timesheet in Slice 4.
enum TimesheetStatus: String {
    case draft, submitted, approved, rejected
}

struct Timesheet: Identifiable {
    let id: String
    let date: String
    let status: TimesheetStatus?

    var isEditable: Bool {
        switch status {
        case .draft, .rejected, nil: return true
        case .submitted, .approved:  return false
        }
    }

    init(raw: RawResource) throws {
        guard raw.type == "timesheets" else {
            throw ModelError.typeMismatch(expected: "timesheets", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id     = raw.id
        date   = a["date"]?.string ?? ""
        status = (a["status"]?.string ?? a["state"]?.string)
                    .flatMap(TimesheetStatus.init(rawValue:))
    }
}

// MARK: - Person / Availability

struct Availability {
    let startDate: String   // "YYYY-MM-DD"
    let endDate: String?    // nil = ongoing
    /// Hours per weekday, Mon–Sun (7 entries; 14 for biweekly schedules).
    let dailyHours: [Int]

    func targetMinutes(weekday: Int) -> Int {
        guard !dailyHours.isEmpty else { return 480 }
        return dailyHours[weekday % dailyHours.count] * 60
    }
}

struct Person: Identifiable {
    let id: String
    let firstName: String
    let lastName: String
    let email: String
    let availabilities: [Availability]
    /// Resolved from relationships.holiday_calendar (requires include= in the request).
    let holidayCalendarID: String?

    var displayName: String { "\(firstName) \(lastName)" }

    /// Daily capacity target in minutes for the given weekday (0 = Monday) on the given date.
    func dailyTargetMinutes(weekday: Int, on date: String) -> Int {
        let active = availabilities.first { a in
            a.startDate <= date && (a.endDate == nil || a.endDate! >= date)
        } ?? availabilities.first
        return active?.targetMinutes(weekday: weekday) ?? 480
    }

    init(raw: RawResource) throws {
        guard raw.type == "people" else {
            throw ModelError.typeMismatch(expected: "people", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id                = raw.id
        firstName         = a["first_name"]?.string ?? ""
        lastName          = a["last_name"]?.string ?? ""
        email             = a["email"]?.string ?? ""
        holidayCalendarID = raw.relationships?["holiday_calendar"]?.data.oneID

        // availabilities: [[start_date, end_date|null, [h_mon..h_sun...], schedule_id], ...]
        if let outer = a["availabilities"]?.value as? [AnyCodable] {
            availabilities = outer.compactMap { entry -> Availability? in
                guard let arr = entry.value as? [AnyCodable], arr.count >= 3 else { return nil }
                let start = arr[0].string ?? ""
                let end   = arr[1].isNull ? nil : arr[1].string
                let hours: [Int]
                if let hoursArr = arr[2].value as? [AnyCodable] {
                    hours = hoursArr.compactMap(\.int)
                } else {
                    hours = []
                }
                return Availability(startDate: start, endDate: end, dailyHours: hours)
            }
        } else {
            availabilities = []
        }
    }
}

// MARK: - Service

struct Service: Identifiable {
    let id: String
    let name: String
    let timeTrackingEnabled: Bool

    init(raw: RawResource) throws {
        guard raw.type == "services" else {
            throw ModelError.typeMismatch(expected: "services", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id                  = raw.id
        name                = a["name"]?.string ?? ""
        timeTrackingEnabled = a["time_tracking_enabled"]?.bool ?? false
    }
}

// MARK: - Project

struct Project: Identifiable {
    let id: String
    let name: String

    init(raw: RawResource) throws {
        guard raw.type == "projects" else {
            throw ModelError.typeMismatch(expected: "projects", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id   = raw.id
        name = a["name"]?.string ?? ""
    }
}

// MARK: - Event (absence event types)

struct Event: Identifiable {
    let id: String
    let name: String
    let absenceType: String     // e.g. "time_off"
    let archivedAt: String?
    let halfDayBookings: Bool

    var isArchived: Bool { archivedAt != nil }

    init(raw: RawResource) throws {
        guard raw.type == "events" else {
            throw ModelError.typeMismatch(expected: "events", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id              = raw.id
        name            = a["name"]?.string ?? ""
        absenceType     = a["absence_type"]?.string ?? ""
        archivedAt      = a["archived_at"]?.string
        halfDayBookings = a["half_day_bookings"]?.bool ?? false
    }
}

// MARK: - Entitlement

struct Entitlement: Identifiable {
    let id: String
    /// API returns as String "5760.0" (minutes).
    let allocatedMinutes: Int
    let usedMinutes: Int
    let pendingMinutes: Int
    let startDate: String
    let endDate: String
    let note: String?
    let eventID: String?

    var remainingMinutes: Int { allocatedMinutes - usedMinutes - pendingMinutes }

    init(raw: RawResource) throws {
        guard raw.type == "entitlements" else {
            throw ModelError.typeMismatch(expected: "entitlements", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id        = raw.id
        startDate = a["start_date"]?.string ?? ""
        endDate   = a["end_date"]?.string ?? ""
        note      = a["note"]?.string
        eventID   = raw.relationships?["event"]?.data.oneID

        func parseMinutes(_ key: String) -> Int {
            if let s = a[key]?.string, let d = Double(s) { return Int(d) }
            if let d = a[key]?.double { return Int(d) }
            return a[key]?.int ?? 0
        }
        allocatedMinutes = parseMinutes("allocated")
        usedMinutes      = parseMinutes("used")
        pendingMinutes   = parseMinutes("pending")
    }
}

// MARK: - Holiday

struct Holiday: Identifiable {
    let id: String
    let date: String   // "YYYY-MM-DD"
    let name: String
    let calendarID: String?  // from relationships.holiday_calendar (requires include=)

    init(raw: RawResource) throws {
        guard raw.type == "holidays" else {
            throw ModelError.typeMismatch(expected: "holidays", got: raw.type)
        }
        let a = raw.attributes ?? [:]
        id         = raw.id
        date       = a["date"]?.string ?? ""
        name       = a["name"]?.string ?? ""
        calendarID = raw.relationships?["holiday_calendar"]?.data.oneID
    }
}
