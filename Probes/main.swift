// Slice 0.5 — Live API probe. Answers the four open-verification questions from SPEC.md.
// Run: xcodebuild run -scheme ProductiveProbe  (or build + run the executable directly)
// Output: JSON files in Probes/findings/, printed summary to stdout.
// NOT shipped — this file is excluded from the WidgetProductive app target.

import Foundation

// MARK: - Entry point

let probe = Probe()
await probe.run()

// MARK: - Probe

struct Probe {
    let client: APIClient
    let findingsDir: URL

    init() {
        self.client = APIClient()
        // Write findings next to this source file.
        let src = URL(filePath: #filePath).deletingLastPathComponent()
        self.findingsDir = src.appending(path: "findings")
    }

    func run() async {
        print("=== Widget Productive API Probe ===\n")

        do {
            // 1. Resolve person
            let personID = try await resolvePerson()
            print("Person ID: \(personID)\n")

            // 2. Fetch time entries for current week
            let (start, end) = currentWeekRange()
            await probeTimeEntries(personID: personID, start: start, end: end)

            // 3. Probe timesheets
            await probeTimesheets(personID: personID, start: start, end: end)

            // 4. Probe bookings (budget + absence)
            await probeBookings(personID: personID, start: start, end: end)

            // 5. Probe capacity / person schedule
            await probePerson(personID: personID)

            // 6. Probe entitlements
            await probeEntitlements(personID: personID)

            // 7. Probe holidays
            await probeHolidays(personID: personID)

            // 8. Probe events
            await probeEvents()

            print("\nFindings written to: \(findingsDir.path(percentEncoded: false))")
        } catch {
            print("FATAL: \(error)")
            exit(1)
        }
    }

    // MARK: - Person resolution

    func resolvePerson() async throws -> String {
        let email = try Secrets.email()
        let orgID = try Secrets.orgID()
        print("Resolving person for email: \(email), org: \(orgID)")

        let data = try await client.getRaw(
            path: "/people",
            query: [URLQueryItem(name: "filter[email]", value: email)]
        )
        write(data, to: "people.json")

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let dataArr = json?["data"] as? [[String: Any]] ?? []
        guard let first = dataArr.first,
              let id = first["id"] as? String else {
            throw ProbeError.personNotFound(email)
        }
        return id
    }

    // MARK: - Time entries

    func probeTimeEntries(personID: String, start: String, end: String) async {
        print("--- Time entries (\(start) – \(end)) ---")
        // First try with date_from/date_to range filters
        var succeeded = false
        await probeEndpoint(
            path: "/time_entries",
            query: [
                URLQueryItem(name: "filter[person_id]", value: personID),
                URLQueryItem(name: "filter[date_from]", value: start),
                URLQueryItem(name: "filter[date_to]", value: end),
                URLQueryItem(name: "include", value: "service,project"),
                URLQueryItem(name: "page[size]", value: "200")
            ],
            filename: "time_entries.json",
            summary: { json in
                succeeded = true
                let entries = (json["data"] as? [[String: Any]]) ?? []
                print("  \(entries.count) time entries (filter: date_from/date_to)")
                for e in entries.prefix(3) {
                    let attrs = e["attributes"] as? [String: Any]
                    let approvedAt       = attrs?["approved_at"]
                    let dealTimeApproval = attrs?["deal_time_approval"]
                    let date             = attrs?["date"] ?? "?"
                    let minutes          = attrs?["time"] ?? attrs?["minutes"] ?? "?"
                    print("  entry \(e["id"] ?? "?") date=\(date) minutes=\(minutes) approved_at=\(String(describing: approvedAt)) deal_time_approval=\(String(describing: dealTimeApproval))")
                }
            }
        )
        // Fallback: no date filter — get any recent entries for shape inspection
        if !succeeded {
            print("  (date_from/date_to failed, retrying without date filter)")
            await probeEndpoint(
                path: "/time_entries",
                query: [
                    URLQueryItem(name: "filter[person_id]", value: personID),
                    URLQueryItem(name: "include", value: "service,project"),
                    URLQueryItem(name: "page[size]", value: "5")
                ],
                filename: "time_entries.json",
                summary: { json in
                    let entries = (json["data"] as? [[String: Any]]) ?? []
                    print("  \(entries.count) time entries (no date filter)")
                    for e in entries.prefix(3) {
                        let attrs = e["attributes"] as? [String: Any]
                        print("  entry \(e["id"] ?? "?") attrs-keys=\(Array((attrs ?? [:]).keys).sorted())")
                        if let attrs { print("  -> \(attrs)") }
                    }
                }
            )
        }
    }

    // MARK: - Timesheets

    func probeTimesheets(personID: String, start: String, end: String) async {
        print("--- Timesheets (\(start) – \(end)) ---")
        var succeeded = false
        await probeEndpoint(
            path: "/timesheets",
            query: [
                URLQueryItem(name: "filter[person_id]", value: personID),
                URLQueryItem(name: "filter[date_from]", value: start),
                URLQueryItem(name: "filter[date_to]", value: end),
                URLQueryItem(name: "page[size]", value: "200")
            ],
            filename: "timesheets.json",
            summary: { json in
                succeeded = true
                let sheets = (json["data"] as? [[String: Any]]) ?? []
                print("  \(sheets.count) timesheets (filter: date_from/date_to)")
                for s in sheets {
                    let attrs = s["attributes"] as? [String: Any]
                    print("  timesheet \(s["id"] ?? "?") attrs-keys=\(Array((attrs ?? [:]).keys).sorted())")
                    if let attrs { print("  -> \(attrs)") }
                }
            }
        )
        if !succeeded {
            print("  (date_from/date_to failed, retrying without date filter)")
            await probeEndpoint(
                path: "/timesheets",
                query: [
                    URLQueryItem(name: "filter[person_id]", value: personID),
                    URLQueryItem(name: "page[size]", value: "5")
                ],
                filename: "timesheets.json",
                summary: { json in
                    let sheets = (json["data"] as? [[String: Any]]) ?? []
                    print("  \(sheets.count) timesheets (no date filter)")
                    for s in sheets {
                        let attrs = s["attributes"] as? [String: Any]
                        print("  timesheet \(s["id"] ?? "?") attrs-keys=\(Array((attrs ?? [:]).keys).sorted())")
                        if let attrs { print("  -> \(attrs)") }
                    }
                }
            )
        }
    }

    // MARK: - Bookings

    func probeBookings(personID: String, start: String, end: String) async {
        print("--- Bookings (\(start) – \(end)) ---")
        var succeeded = false
        await probeEndpoint(
            path: "/bookings",
            query: [
                URLQueryItem(name: "filter[person_id]", value: personID),
                URLQueryItem(name: "filter[date_from]", value: start),
                URLQueryItem(name: "filter[date_to]", value: end),
                URLQueryItem(name: "include", value: "event,service"),
                URLQueryItem(name: "page[size]", value: "200")
            ],
            filename: "bookings.json",
            summary: { json in
                succeeded = true
                let bookings = (json["data"] as? [[String: Any]]) ?? []
                print("  \(bookings.count) bookings (filter: date_from/date_to)")
                for b in bookings.prefix(5) {
                    let attrs = b["attributes"] as? [String: Any]
                    print("  booking \(b["id"] ?? "?") booking_method=\(attrs?["booking_method"] ?? "?") percentage=\(attrs?["percentage"] ?? "?") total_time=\(attrs?["total_time"] ?? "?")")
                }
            }
        )
        if !succeeded {
            print("  (date_from/date_to failed, retrying without date filter)")
            await probeEndpoint(
                path: "/bookings",
                query: [
                    URLQueryItem(name: "filter[person_id]", value: personID),
                    URLQueryItem(name: "include", value: "event,service"),
                    URLQueryItem(name: "page[size]", value: "10")
                ],
                filename: "bookings.json",
                summary: { json in
                    let bookings = (json["data"] as? [[String: Any]]) ?? []
                    print("  \(bookings.count) bookings (no date filter)")
                    for b in bookings.prefix(5) {
                        let attrs = b["attributes"] as? [String: Any]
                        print("  booking \(b["id"] ?? "?") attrs-keys=\(Array((attrs ?? [:]).keys).sorted())")
                        if let attrs { print("  -> \(attrs)") }
                    }
                }
            )
        }
    }

    // MARK: - Person / capacity

    func probePerson(personID: String) async {
        print("--- Person \(personID) (capacity / schedule) ---")
        // No include — working_time_schedule is not a supported include on /people
        await probeEndpoint(
            path: "/people/\(personID)",
            query: [],
            filename: "person.json",
            summary: { json in
                let person = json["data"] as? [String: Any]
                let attrs = person?["attributes"] as? [String: Any]
                print("  person attrs-keys: \(Array((attrs ?? [:]).keys).sorted())")
                let capacityKeys = (attrs ?? [:]).keys.filter {
                    $0.contains("capacity") || $0.contains("hour") || $0.contains("schedule")
                    || $0.contains("availab") || $0.contains("work")
                }
                print("  capacity/schedule-related keys: \(capacityKeys.sorted())")
                if let attrs { print("  -> \(attrs)") }
            }
        )
    }

    // MARK: - Entitlements

    func probeEntitlements(personID: String) async {
        print("--- Entitlements ---")
        await probeEndpoint(
            path: "/entitlements",
            query: [
                URLQueryItem(name: "filter[person_id]", value: personID),
                URLQueryItem(name: "page[size]", value: "200")
            ],
            filename: "entitlements.json",
            summary: { json in
                let items = (json["data"] as? [[String: Any]]) ?? []
                print("  \(items.count) entitlements")
                for e in items {
                    let attrs = e["attributes"] as? [String: Any]
                    print("  entitlement \(e["id"] ?? "?") attrs=\(attrs ?? [:])")
                }
            }
        )
    }

    // MARK: - Holidays

    func probeHolidays(personID: String) async {
        print("--- Holidays ---")
        // First get the person's holiday_calendar_id
        let personData = readFinding("person.json")
        var calendarID: String? = nil
        if let data = personData,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let person = json["data"] as? [String: Any],
           let attrs = person["attributes"] as? [String: Any] {
            calendarID = attrs["holiday_calendar_id"] as? String
                      ?? (attrs["relationships"] as? [String: Any])?["holiday_calendar"] as? String
        }
        print("  holiday_calendar_id: \(calendarID ?? "not found in person attrs")")

        await probeEndpoint(
            path: "/holidays",
            query: [URLQueryItem(name: "page[size]", value: "200")],
            filename: "holidays.json",
            summary: { json in
                let items = (json["data"] as? [[String: Any]]) ?? []
                print("  \(items.count) holidays (all calendars)")
                for h in items.prefix(3) {
                    let attrs = h["attributes"] as? [String: Any]
                    print("  holiday \(h["id"] ?? "?") \(attrs ?? [:])")
                }
            }
        )
    }

    // MARK: - Events

    func probeEvents() async {
        print("--- Events (absence event types) ---")
        await probeEndpoint(
            path: "/events",
            query: [URLQueryItem(name: "page[size]", value: "200")],
            filename: "events.json",
            summary: { json in
                let items = (json["data"] as? [[String: Any]]) ?? []
                print("  \(items.count) events")
                for e in items {
                    let attrs = e["attributes"] as? [String: Any]
                    print("  event \(e["id"] ?? "?") name=\(attrs?["name"] ?? "?")")
                }
            }
        )
    }

    // MARK: - Helpers

    func probeEndpoint(
        path: String,
        query: [URLQueryItem],
        filename: String,
        summary: ([String: Any]) -> Void
    ) async {
        do {
            let data = try await client.getRaw(path: path, query: query)
            write(data, to: filename)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                summary(json)
            }
        } catch {
            print("  ERROR \(path): \(error)")
        }
        print()
    }

    func write(_ data: Data, to filename: String) {
        let url = findingsDir.appending(path: filename)
        // Pretty-print JSON
        if let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? pretty.write(to: url)
        } else {
            try? data.write(to: url)
        }
    }

    func readFinding(_ filename: String) -> Data? {
        let url = findingsDir.appending(path: filename)
        return try? Data(contentsOf: url)
    }

    func currentWeekRange() -> (start: String, end: String) {
        var cal = Calendar(identifier: .iso8601)
        cal.locale = Locale(identifier: "en_US_POSIX")
        let now = Date()
        let monday = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let friday = cal.date(byAdding: .day, value: 4, to: monday)!
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate]
        return (fmt.string(from: monday), fmt.string(from: friday))
    }
}

// MARK: - Error

enum ProbeError: Error {
    case personNotFound(String)
}
