import Testing
import Foundation
import os
@testable import WidgetProductive

@Test func scaffoldBuilds() {
    #expect(Bool(true))
}

// MARK: - Secrets / .env parser

@Test func dotenvParserBasic() throws {
    // Write a synthetic .env to a temp file and parse it.
    let raw = """
    PRODUCTIVE_AUTH_TOKEN=tok123
    PRODUCTIVE_ORG_ID=  org456
    PRODUCTIVE_EMAIL="alice@example.com"
    # comment line
    PRODUCTIVE_PERSON_ID='789'
    EMPTY_VALUE=
    """
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_\(UUID().uuidString).env")
    try raw.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let parsed = try Secrets.Testable.parseDotenv(at: url.path)
    #expect(parsed["PRODUCTIVE_AUTH_TOKEN"] == "tok123")
    #expect(parsed["PRODUCTIVE_ORG_ID"] == "org456")
    #expect(parsed["PRODUCTIVE_EMAIL"] == "alice@example.com")
    #expect(parsed["PRODUCTIVE_PERSON_ID"] == "789")
    #expect(parsed["EMPTY_VALUE"] == "")
    #expect(parsed["# comment line"] == nil)
}

// MARK: - AnyCodable

@Test func anyCodableRoundtrip() throws {
    let json = """
    {"str":"hello","num":42,"flag":true,"nested":{"x":1.5},"arr":[1,2]}
    """
    let decoded = try JSONDecoder().decode([String: AnyCodable].self,
                                          from: Data(json.utf8))
    #expect(decoded["str"]?.string == "hello")
    #expect(decoded["num"]?.int == 42)
    #expect(decoded["flag"]?.bool == true)
}

// MARK: - JSONAPIEnvelope decoding

@Test func jsonAPIEnvelopeSingleResource() throws {
    let json = """
    {
      "data": {
        "id": "1",
        "type": "people",
        "attributes": { "name": "Alice", "email": "alice@example.com" },
        "relationships": {
          "company": { "data": { "id": "99", "type": "companies" } }
        }
      },
      "included": []
    }
    """
    let envelope = try JSONDecoder().decode(
        JSONAPIEnvelope<RawResource>.self,
        from: Data(json.utf8)
    )
    #expect(envelope.data.id == "1")
    #expect(envelope.data.type == "people")
    #expect(envelope.data.attributes?["name"]?.string == "Alice")
    let rel = envelope.data.relationships?["company"]
    if case .one(let id) = rel?.data {
        #expect(id.id == "99")
        #expect(id.type == "companies")
    } else {
        Issue.record("Expected single relationship linkage")
    }
}

@Test func jsonAPIEnvelopeArray() throws {
    let json = """
    {
      "data": [
        { "id": "1", "type": "time_entries", "attributes": { "minutes": 480 } },
        { "id": "2", "type": "time_entries", "attributes": { "minutes": 240 } }
      ]
    }
    """
    let envelope = try JSONDecoder().decode(
        JSONAPIEnvelope<[RawResource]>.self,
        from: Data(json.utf8)
    )
    #expect(envelope.data.count == 2)
    #expect(envelope.data[0].attributes?["minutes"]?.int == 480)
}

// MARK: - Model decoding from RawResource

@Test func timeEntryDecoding() throws {
    // Matches real time_entries JSON shape from probe findings.
    let json = """
    {
      "id": "147968433",
      "type": "time_entries",
      "attributes": {
        "date": "2026-06-19",
        "time": 480,
        "approved": false,
        "approved_at": null,
        "draft": false,
        "submitted": true,
        "rejected": false,
        "rejected_at": null,
        "rejected_reason": null,
        "note": null
      },
      "relationships": {
        "service": { "data": { "id": "14352141", "type": "services" } },
        "timesheet": { "meta": { "included": false } }
      }
    }
    """
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    let entry = try TimeEntry(raw: raw)
    #expect(entry.id == "147968433")
    #expect(entry.date == "2026-06-19")
    #expect(entry.minutes == 480)
    #expect(entry.approved == false)
    #expect(entry.submitted == true)
    #expect(entry.isLocked == false)
    #expect(entry.serviceID == "14352141")
}

@Test func bookingDecoding() throws {
    // Budget booking: method 2 (percentage), stage_type 2, service relationship.
    let json = """
    {
      "id": "31568136",
      "type": "bookings",
      "attributes": {
        "started_on": "2026-05-01",
        "ended_on": "2026-06-17",
        "booking_method_id": 2,
        "percentage": 100,
        "time": null,
        "total_time": 15840,
        "total_working_days": 33,
        "approved": true,
        "approved_at": "2026-05-05T15:34:03.946+02:00",
        "draft": false,
        "rejected": false,
        "canceled": false,
        "stage_type": 2,
        "note": ""
      },
      "relationships": {
        "event": { "data": null },
        "service": { "data": { "id": "14352141", "type": "services" } }
      }
    }
    """
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    let booking = try Booking(raw: raw)
    #expect(booking.id == "31568136")
    #expect(booking.bookingMethod == .percentage)
    #expect(booking.percentage == 100)
    #expect(booking.isBudget == true)
    #expect(booking.isAbsence == false)
    #expect(booking.approved == true)
    // 100% of 480 min target = 480 min
    #expect(booking.dailyMinutes(target: 480) == 480)
}

@Test func bookingPerDayDecoding() throws {
    // Absence booking: method 1 (per-day), time = 240 min (4h).
    let json = """
    {
      "id": "31929693",
      "type": "bookings",
      "attributes": {
        "started_on": "2026-01-07",
        "ended_on": "2026-01-07",
        "booking_method_id": 1,
        "percentage": null,
        "time": 240,
        "total_time": 240,
        "total_working_days": 1,
        "approved": true,
        "approved_at": "2026-05-20T22:20:55.021+02:00",
        "draft": false,
        "rejected": false,
        "canceled": false,
        "stage_type": null,
        "note": ""
      },
      "relationships": {
        "event": { "data": { "id": "181924", "type": "events" } },
        "service": { "meta": { "included": false } }
      }
    }
    """
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    let booking = try Booking(raw: raw)
    #expect(booking.bookingMethod == .perDay)
    #expect(booking.minutesPerDay == 240)
    #expect(booking.isAbsence == true)
    #expect(booking.eventID == "181924")
    #expect(booking.dailyMinutes(target: 480) == 240)
}

@Test func personDecodingWithAvailabilities() throws {
    let json = """
    {
      "id": "1244525",
      "type": "people",
      "attributes": {
        "first_name": "Yohann",
        "last_name": "Paris",
        "email": "yparis@uncharted.software",
        "availabilities": [["2025-01-01", null, [8, 8, 8, 8, 8, 0, 0], 60790]]
      },
      "relationships": {
        "holiday_calendar": { "meta": { "included": false } }
      }
    }
    """
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    let person = try Person(raw: raw)
    #expect(person.id == "1244525")
    #expect(person.displayName == "Yohann Paris")
    #expect(person.availabilities.count == 1)
    #expect(person.availabilities[0].startDate == "2025-01-01")
    #expect(person.availabilities[0].endDate == nil)
    // Mon=0 → 8h = 480 min; Sat=5 → 0h
    #expect(person.dailyTargetMinutes(weekday: 0, on: "2026-05-26") == 480)
    #expect(person.dailyTargetMinutes(weekday: 5, on: "2026-05-30") == 0)
}

@Test func entitlementDecoding() throws {
    // Values stored as String in the API ("5760.0").
    let json = """
    {
      "id": "270409",
      "type": "entitlements",
      "attributes": {
        "allocated": "5760.0",
        "used": "1200.0",
        "pending": "0.0",
        "start_date": "2026-01-01",
        "end_date": "2026-12-31",
        "note": null
      },
      "relationships": {
        "event": { "meta": { "included": false } }
      }
    }
    """
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    let ent = try Entitlement(raw: raw)
    #expect(ent.allocatedMinutes == 5760)
    #expect(ent.usedMinutes == 1200)
    #expect(ent.pendingMinutes == 0)
    #expect(ent.remainingMinutes == 4560)
}

@Test func holidayDecoding() throws {
    let json = """
    {
      "id": "765692",
      "type": "holidays",
      "attributes": { "date": "2026-05-25", "name": "Memorial Day" },
      "relationships": {
        "holiday_calendar": { "meta": { "included": false } }
      }
    }
    """
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    let holiday = try Holiday(raw: raw)
    #expect(holiday.date == "2026-05-25")
    #expect(holiday.name == "Memorial Day")
    #expect(holiday.calendarID == nil)
}

@Test func eventDecoding() throws {
    let json = """
    {
      "id": "181924",
      "type": "events",
      "attributes": {
        "name": "Care Day",
        "absence_type": "time_off",
        "archived_at": null,
        "half_day_bookings": false
      },
      "relationships": {}
    }
    """
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    let event = try Event(raw: raw)
    #expect(event.name == "Care Day")
    #expect(event.absenceType == "time_off")
    #expect(event.isArchived == false)
    #expect(event.halfDayBookings == false)
}

// MARK: - APIClient 429 backoff (stub session)

// MARK: - Prefill (Slice 2)

// Helpers: build typed models from minimal JSON without going through live API.

private func makeEntry(id: String, date: String, minutes: Int, serviceID: String?) throws -> TimeEntry {
    let relJSON: String
    if let sid = serviceID {
        relJSON = #", "relationships": {"service": {"data": {"id": "\#(sid)", "type": "services"}}}"#
    } else {
        relJSON = ""
    }
    let json = #"""
    {
      "id": "\#(id)", "type": "time_entries",
      "attributes": {
        "date": "\#(date)", "time": \#(minutes), "approved": false, "approved_at": null,
        "draft": false, "submitted": false, "rejected": false,
        "rejected_at": null, "rejected_reason": null, "note": null
      }\#(relJSON)
    }
    """#
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    return try TimeEntry(raw: raw)
}

private func makeAbsenceBooking(
    id: String,
    startedOn: String,
    endedOn: String,
    methodID: Int,
    time: Int?,           // minutes/day for method 1
    percentage: Int?,     // for method 2
    totalTime: Int,
    totalWorkingDays: Int,
    eventID: String,
    approved: Bool
) throws -> Booking {
    let timeStr = time.map { "\($0)" } ?? "null"
    let pctStr  = percentage.map { "\($0)" } ?? "null"
    let approvedAtStr = approved ? "\"2026-01-01T00:00:00.000Z\"" : "null"
    let json = #"""
    {
      "id": "\#(id)", "type": "bookings",
      "attributes": {
        "started_on": "\#(startedOn)", "ended_on": "\#(endedOn)",
        "booking_method_id": \#(methodID), "percentage": \#(pctStr), "time": \#(timeStr),
        "total_time": \#(totalTime), "total_working_days": \#(totalWorkingDays),
        "approved": \#(approved), "approved_at": \#(approvedAtStr),
        "draft": false, "rejected": false, "canceled": false, "stage_type": null, "note": ""
      },
      "relationships": {
        "event": { "data": { "id": "\#(eventID)", "type": "events" } },
        "service": { "meta": { "included": false } }
      }
    }
    """#
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    return try Booking(raw: raw)
}

private func makeBudgetBooking(
    id: String, startedOn: String, endedOn: String,
    methodID: Int, percentage: Int?, time: Int?,
    totalTime: Int, totalWorkingDays: Int,
    serviceID: String
) throws -> Booking {
    let timeStr = time.map { "\($0)" } ?? "null"
    let pctStr  = percentage.map { "\($0)" } ?? "null"
    let json = #"""
    {
      "id": "\#(id)", "type": "bookings",
      "attributes": {
        "started_on": "\#(startedOn)", "ended_on": "\#(endedOn)",
        "booking_method_id": \#(methodID), "percentage": \#(pctStr), "time": \#(timeStr),
        "total_time": \#(totalTime), "total_working_days": \#(totalWorkingDays),
        "approved": true, "approved_at": "2026-01-01T00:00:00.000Z",
        "draft": false, "rejected": false, "canceled": false, "stage_type": 2, "note": ""
      },
      "relationships": {
        "event": { "data": null },
        "service": { "data": { "id": "\#(serviceID)", "type": "services" } }
      }
    }
    """#
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    return try Booking(raw: raw)
}

private func makePerson(dailyHours: [Int] = [8, 8, 8, 8, 8, 0, 0]) throws -> Person {
    let hoursJSON = dailyHours.map { "\($0)" }.joined(separator: ",")
    let json = #"""
    {
      "id": "1", "type": "people",
      "attributes": {
        "first_name": "Test", "last_name": "User", "email": "test@example.com",
        "availabilities": [["2020-01-01", null, [\#(hoursJSON)], 1]]
      },
      "relationships": {}
    }
    """#
    let raw = try JSONDecoder().decode(RawResource.self, from: Data(json.utf8))
    return try Person(raw: raw)
}

// Week: Mon 2026-06-01 … Fri 2026-06-05
private let w = ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04", "2026-06-05"]
// Last week: Mon 2026-05-25 … Fri 2026-05-29
private let lw = ["2026-05-25", "2026-05-26", "2026-05-27", "2026-05-28", "2026-05-29"]

@Test func prefill_serverWinsOverCarryForward() throws {
    let person = try makePerson()
    // Server has 300 min on Mon for service "A"
    let serverEntry = try makeEntry(id: "e1", date: w[0], minutes: 300, serviceID: "A")
    // Last week had 480 min on Mon for service "A"
    let lwEntry = try makeEntry(id: "e2", date: lw[0], minutes: 480, serviceID: "A")
    let budget  = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "A")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [serverEntry], lastWeekEntries: [lwEntry],
        bookings: [budget], weekDates: w, lastWeekDates: lw,
        serviceNames: ["A": "Service A"], eventNames: [:], holidayDates: [], person: person
    )
    let row = try #require(rows.first { $0.id == "w:A" })
    #expect(row.minutesByDate[w[0]] == 300)   // server wins
    #expect(row.minutesByDate[w[1]] == 480)   // carry-forward on other days
}

@Test func prefill_carryForwardFromLastWeek() throws {
    let person = try makePerson()
    let lwEntry = try makeEntry(id: "e1", date: lw[2], minutes: 360, serviceID: "A")  // Wed
    let budget  = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "A")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [lwEntry],
        bookings: [budget], weekDates: w, lastWeekDates: lw,
        serviceNames: [:], eventNames: [:], holidayDates: [], person: person
    )
    let row = try #require(rows.first { $0.id == "w:A" })
    #expect(row.minutesByDate[w[2]] == 360)   // Wed carried forward
    // Mon: last week had no entries for any service → even-split fallback = 480/1 = 480
    #expect(row.minutesByDate[w[0]] == 480)
}

@Test func prefill_holidayDayHasNoEntry() throws {
    let person  = try makePerson()
    let lwEntry = try makeEntry(id: "e1", date: lw[0], minutes: 480, serviceID: "A")
    let budget  = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "A")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [lwEntry],
        bookings: [budget], weekDates: w, lastWeekDates: lw,
        serviceNames: [:], eventNames: [:], holidayDates: [w[0]], person: person
    )
    let row = try #require(rows.first { $0.id == "w:A" })
    #expect(row.minutesByDate[w[0]] == nil)   // Mon is a holiday — no entry
    #expect(row.minutesByDate[w[1]] == 480)   // Tue carries normally
}

@Test func prefill_partialApprovedAbsenceEvenSplit() throws {
    let person = try makePerson()   // 480 min/day
    // Approved half-day absence on Mon (240 min)
    let absence = try makeAbsenceBooking(
        id: "ab1", startedOn: w[0], endedOn: w[0],
        methodID: 1, time: 240, percentage: nil,
        totalTime: 240, totalWorkingDays: 1,
        eventID: "ev1", approved: true
    )
    let budgetA = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "A")
    let budgetB = try makeBudgetBooking(id: "b2", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "B")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [],
        bookings: [absence, budgetA, budgetB], weekDates: w, lastWeekDates: lw,
        serviceNames: ["A": "A", "B": "B"], eventNames: ["ev1": "Care Day"],
        holidayDates: [], person: person
    )
    let rowA = try #require(rows.first { $0.id == "w:A" })
    let rowB = try #require(rows.first { $0.id == "w:B" })
    // remaining = 480 - 240 = 240; split = 240 / 2 = 120 each
    #expect(rowA.minutesByDate[w[0]] == 120)
    #expect(rowB.minutesByDate[w[0]] == 120)
}

@Test func prefill_fullApprovedAbsenceNoWorkedPrefill() throws {
    let person = try makePerson()   // 480 min/day
    // Approved full-day absence on Mon
    let absence = try makeAbsenceBooking(
        id: "ab1", startedOn: w[0], endedOn: w[0],
        methodID: 2, time: nil, percentage: 100,
        totalTime: 480, totalWorkingDays: 1,
        eventID: "ev1", approved: true
    )
    let budget = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                       methodID: 2, percentage: 100, time: nil,
                                       totalTime: 2400, totalWorkingDays: 5, serviceID: "A")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [],
        bookings: [absence, budget], weekDates: w, lastWeekDates: lw,
        serviceNames: ["A": "A"], eventNames: ["ev1": "Vacation"],
        holidayDates: [], person: person
    )
    let workedRow = rows.first { $0.id == "w:A" }
    // Mon fully absent → no worked entry; other days even-split from no-carry fallback (one budget svc)
    #expect(workedRow?.minutesByDate[w[0]] == nil)
}

@Test func prefill_carriedRowWithoutBookingFlagged() throws {
    let person  = try makePerson()
    // Last week had entries for service "A", but this week has no budget booking for it.
    let lwEntry = try makeEntry(id: "e1", date: lw[0], minutes: 480, serviceID: "A")
    // Budget booking exists only for service "B" this week.
    let budgetB = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "B")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [lwEntry],
        bookings: [budgetB], weekDates: w, lastWeekDates: lw,
        serviceNames: ["A": "A", "B": "B"], eventNames: [:], holidayDates: [], person: person
    )
    let rowA = try #require(rows.first { $0.id == "w:A" })
    #expect(rowA.hasNoActiveBooking == true)
    let rowB = try #require(rows.first { $0.id == "w:B" })
    #expect(rowB.hasNoActiveBooking == false)
}

@Test func prefill_noZeroMinuteCells() throws {
    let person = try makePerson(dailyHours: [0, 0, 0, 0, 0, 0, 0])   // 0h every day
    let lwEntry = try makeEntry(id: "e1", date: lw[0], minutes: 480, serviceID: "A")
    let budget  = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 0, totalWorkingDays: 5, serviceID: "A")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [lwEntry],
        bookings: [budget], weekDates: w, lastWeekDates: lw,
        serviceNames: [:], eventNames: [:], holidayDates: [], person: person
    )
    // Absence-path even-split with remaining=0 should produce no cells.
    for row in rows where row.id == "w:A" {
        for mins in row.minutesByDate.values {
            #expect(mins > 0)
        }
    }
}

@Test func prefill_unapprovedAbsenceDoesNotReduceTarget() throws {
    let person = try makePerson()   // 480 min/day
    // Pending (unapproved) absence — should show in absence row but NOT reduce worked target.
    let pendingAbsence = try makeAbsenceBooking(
        id: "ab1", startedOn: w[0], endedOn: w[0],
        methodID: 1, time: 240, percentage: nil,
        totalTime: 240, totalWorkingDays: 1,
        eventID: "ev1", approved: false
    )
    let budget = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                       methodID: 2, percentage: 100, time: nil,
                                       totalTime: 2400, totalWorkingDays: 5, serviceID: "A")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [],
        bookings: [pendingAbsence, budget], weekDates: w, lastWeekDates: lw,
        serviceNames: ["A": "A"], eventNames: ["ev1": "Care Day"],
        holidayDates: [], person: person
    )
    let workedRow = try #require(rows.first { $0.id == "w:A" })
    // Unapproved absence does not reduce target → even-split of full 480 min = 480 (one service)
    #expect(workedRow.minutesByDate[w[0]] == 480)
    // Absence row still shows the pending booking.
    let absenceRow = try #require(rows.first { $0.id == "a:ev1" })
    #expect(absenceRow.minutesByDate[w[0]] == 240)
}

@Test func prefill_evenSplitFallbackWhenNoLastWeek() throws {
    let person  = try makePerson()   // 480 min/day
    let budgetA = try makeBudgetBooking(id: "b1", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "A")
    let budgetB = try makeBudgetBooking(id: "b2", startedOn: w[0], endedOn: w[4],
                                        methodID: 2, percentage: 100, time: nil,
                                        totalTime: 2400, totalWorkingDays: 5, serviceID: "B")
    let rows = GridViewModel.buildRowsWithPrefill(
        entries: [], lastWeekEntries: [],   // no last-week data
        bookings: [budgetA, budgetB], weekDates: w, lastWeekDates: lw,
        serviceNames: ["A": "A", "B": "B"], eventNames: [:], holidayDates: [], person: person
    )
    let rowA = try #require(rows.first { $0.id == "w:A" })
    let rowB = try #require(rows.first { $0.id == "w:B" })
    // 480 / 2 = 240 each
    #expect(rowA.minutesByDate[w[0]] == 240)
    #expect(rowB.minutesByDate[w[0]] == 240)
}

// MARK: - APIClient 429 backoff (stub session)

@Test func apiClient429Backoff() async throws {
    let counter = OSAllocatedUnfairLock(initialState: 0)
    let session = StubURLSession { _ in
        let n = counter.withLock { state -> Int in state += 1; return state }
        if n < 3 {
            let resp = HTTPURLResponse(
                url: URL(string: "https://api.productive.io/api/v2/people")!,
                statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": "0"]  // 0s so test runs fast
            )!
            return (Data(), resp)
        }
        let body = #"{"data":[]}"#
        let resp = HTTPURLResponse(
            url: URL(string: "https://api.productive.io/api/v2/people")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data(body.utf8), resp)
    }

    let client = APIClient(
        session: session.urlSession,
        getAuthToken: { "tok" },
        getOrgID: { "org" }
    )
    let data = try await client.getRaw(path: "/people")
    let finalCount = counter.withLock { $0 }
    #expect(finalCount == 3)
    #expect(!data.isEmpty)
}
