# Widget Productive — Implementation Plan

Implementation plan for [SPEC.md](./SPEC.md), structured for multiple agents working in
parallel. Each slice is a vertical slice; SPEC is the source of truth for behavior — this
doc only sequences the work and assigns ownership boundaries.

## How to use this plan
- Pick an unblocked slice (all `Depends-on` slices merged).
- `Deliverable` lists the files/modules you own — stay inside them to avoid collisions.
- Satisfy every `Acceptance` bullet before marking done; they are verifiable, not "it works".
- `SPEC` anchors point to the section that defines the behavior. Read it; don't re-derive.

## Proposed module layout
Claim a namespace by slice. Agents must not create files outside their slice's namespace
without coordinating.

```
WidgetProductive/
  App/            # @main, MenuBarExtra shell, app state, menu-bar icon + tooltip
  Secrets/        # build-config switch: .env loader (DEBUG) + Keychain (RELEASE)
  API/            # URLSession client, JSON:API decode, auth headers, 429/backoff
  Models/         # JSON:API record types: TimeEntry, Booking, Timesheet, Person, etc.
  Grid/           # weekly grid view model + views, prefill, editing, drift, submit
  Settings/       # Settings panel UI, reminder notification
  CalendarSync/   # EventKit sync engine
  Probes/         # throwaway API discovery (Slice 0.5), not shipped
```

## Dependency graph
```
0 scaffold ──┬─ 0a shell
             ├─ 0b API client core ─── 0.5 probes ─── 1 read-only grid ─┬─ 2 prefill ─ 3 editing ─ 4 submit
             ├─ 0c secrets ──────────────────────────── 5 settings              │
             └─ 0d models                                                        └─ 6 calendar sync
```
Parallelizable once 0 lands: 0a/0b/0c/0d. After 0c: 5 (settings) can start.
After 1: 6 (calendar sync) is independent of 2–4 and runs in parallel.

---

## Slice 0 — Scaffold & foundations
Sub-slices 0a–0d run in parallel after the Xcode project exists. One agent creates the
empty project first; the rest fan out.

### 0a — App shell ✓
- **Depends-on:** project created
- **Deliverable:** `App/` — `@main` app, `MenuBarExtra(style: .window)` with a placeholder
  popover, app-level state container (`@Observable`).
- **Acceptance:** app launches, menu-bar item appears, popover opens/closes.
- **SPEC:** App shell & UX; Architecture.

### 0b — API client core ✓
- **Depends-on:** project created
- **Deliverable:** `API/` — `URLSession` client, JSON:API request/response decoding,
  `X-Auth-Token` + `X-Organization-Id` headers, **sequential write queue with 429 backoff**.
- **Acceptance:** can issue an authenticated `GET /people`, decode JSON:API
  resource + `included`; a forced 429 triggers backoff/retry (unit test with a stub).
- **SPEC:** Architecture; Auth; API endpoints used.

### 0c — Secrets layer ✓
- **Depends-on:** project created
- **Deliverable:** `Secrets/` — build-config switch: `.env` parser in DEBUG, Keychain
  read/write in RELEASE; non-secret settings in UserDefaults.
- **Acceptance:** DEBUG build reads token/org/email/person from `.env`; RELEASE path stores
  and retrieves a token from Keychain. No secrets logged.
- **SPEC:** Architecture; Constants; Auth.

### 0d — Models ✓
- **Depends-on:** project created
- **Deliverable:** `Models/` — Codable JSON:API types: `Person`, `Service`, `Project`,
  `TimeEntry`, `Booking` (budget + absence), `Event`, `Timesheet`, `Entitlement`, `Holiday`.
  Keep the three backing records distinct (time_entries / bookings / timesheets).
- **Acceptance:** types decode the sample payloads captured in 0.5; relationships resolve.
- **SPEC:** Productive data model; API endpoints used.

---

## Slice 0.5 — API probes (discovery) ✓
- **Depends-on:** 0b, 0c
- **Deliverable:** `Probes/` throwaway scripts/CLI + a written **findings doc** answering
  the four open-verification questions against the **live API**, with captured sample
  payloads handed to 0d.
- **Acceptance:** documented answers for: (1) per-entry **lock signal** (`approved_at` vs
  `deal_time_approval`) verified on a real approved entry; (2) **timesheet** create/transition
  flow + state field name; (3) **capacity** exposure for daily target + percentage decomposition;
  (4) **floor × drift × minimal-diff** interaction on the two-entries-per-cell case.
- **SPEC:** Open verification.

**Findings (2026-05-28):**
1. **Lock signal** — `approved_at` confirmed. No `deal_time_approval`. `isLocked = approved_at != null`.
2. **Timesheet state** — Not resolved. Probe returned only `date` + `created_at`; field name open for Slice 4.
3. **Capacity** — `availabilities` on Person: `[[start_date, end_date|null, [h_mon..h_sun], id]]`. `hours[weekday] * 60` = daily target minutes.
4. **Booking method** — `booking_method_id` int (1=per-day via `time` field, 2=percentage via `percentage` field).
5. **Date filter gap** — `filter[date][gte/lte]` and `filter[date_from/date_to]` both rejected on `/time_entries`, `/timesheets`, `/bookings`. Correct param names unknown; **first action of Slice 1**.

---

## Slice 1 — Read-only live grid ✓
- **Depends-on:** 0a, 0d, 0.5
- **Deliverable:** `Grid/` — week navigation (past/current/future), fetch current week's
  `time_entries` + `bookings`, render Mon–Fri grid read-only. Worked rows `Project / Service`,
  absence rows `Care Day` / `Vacation`. Fetch on popover open + manual refresh (no polling).
- **Acceptance:** real account's current-week entries and bookings render correctly across
  worked + absence rows; weekends absent; refresh re-fetches.
- **SPEC:** Weekly grid model; App shell & UX; Productive data model.

**Findings (2026-05-28):**
- Date range filter: `filter[after]` + `filter[before]` (confirmed for time_entries/bookings;
  timesheets uses fallback per-day `filter[date]` on 400).
- Sendable chain: `AnyCodable: @unchecked Sendable` + explicit conformances on `ResourceIdentifier`,
  `RelationshipLinkage`, `RelationshipEntry`, `RawResource`, `JSONAPIEnvelope` (conditional on D).
- `GridViewModel` is `@MainActor @Observable`; sequential awaits avoid cross-actor Sendability
  issues without sacrificing correctness for Slice 1.
- Timesheet state field name still unconfirmed; `Timesheet.isEditable` handles nil status.

## Slice 2 — Prefill & target resolution ✓
- **Depends-on:** 1
- **Deliverable:** `Grid/` — hybrid daily target from capacity (fallback 8h); holiday
  resolution via `holiday_calendar_id` (0h, no entry); last-week carry-forward (worked rows
  only, flag rows with no active booking); even-split fallback across active budget bookings;
  absence decomposition honoring `booking_method`; absences reduce worked hours. Server
  entries win over carry-forward.
- **Acceptance:** new week prefills from last week; holiday day shows 0h target; partial
  absence auto-fills remainder; carried row without booking is flagged; no 0h entries created.
- **SPEC:** Prefill rules.

**Findings (2026-05-28):**
- Only *approved* absences reduce the worked-hours target; pending absences still render an
  absence row but do not affect the remaining capacity split.
- Even-split fallback applies per-day: if no service has a last-week entry for a given weekday,
  that day falls through to even-split (not carry). A day with carry entries for some services
  but not others → services without a last-week entry on that day get nothing (not even-split).
- `buildRowsWithPrefill` is `nonisolated static` (pure function) to allow sync unit tests.
- Holiday filter (`filter[holiday_calendar_id]`) is unverified; fetch is wrapped in `try?`
  (same non-fatal pattern as timesheet range filter). Will confirm against live API.
- Flagged rows (`hasNoActiveBooking == true`) render in orange in the grid label.

## Slice 3 — Editing
- **Depends-on:** 2
- **Deliverable:** `Grid/` — decimal-hours input in 0.25h steps (stored as minutes);
  editability by per-day timesheet state; **per-cell approval floor** (clamp-up + inline note,
  never modify locked entry, overflow as separate entry); `+ Add row` (budget services pinned,
  searchable all-services, Care Day / Vacation); quick 4h/8h for absence cells; over/under-8h
  warnings; read-only approved cells with `mailto:` to attendance contact.
- **Acceptance:** entering below a locked floor clamps up with note; adding Care Day/Vacation
  creates a pending absence booking; approved cells read-only with working mailto.
- **SPEC:** Editing rules; App shell & UX (Add rows, Time input).

## Slice 4 — Submit
- **Depends-on:** 3
- **Deliverable:** `Grid/` — pre-submit drift refresh with **per-cell baseline** conflict view
  (Reload / Proceed); minimal-diff reconciliation (worked via `time_entries`, absence via
  `bookings`); write order **bookings → time_entries → timesheets**, sequential w/ 429 backoff;
  per-day timesheet ensure + `draft → submitted`; submitted-day demote→write→resubmit; skip
  approved days; best-effort with row/cell-level failure surfacing + retry (no rollback).
- **Acceptance:** changing one cell writes only that diff; drift on an unedited cell surfaces
  in conflict view; whole-week submit transitions each workday's timesheet; a mid-sequence
  failure leaves that day `draft` and is retryable; no 0h entries created.
- **SPEC:** Submit semantics; Editing rules.

## Slice 5 — Settings & menu-bar state
- **Depends-on:** 0c (settings UI); 1 (icon state); independent of 2–4 otherwise
- **Deliverable:** `Settings/` + `App/` — Settings panel (token, org id, email, cached
  person id, default service, pinned rows, calendar picker incl. `None`); menu-bar icon state
  (plain / dot / warning tint) reflecting current-week submission; **tooltip** showing
  `/entitlements` balances; auth setup/connect screen on missing/401 token.
- **Acceptance:** unsubmitted weekday shows dot, rejected shows warning, fully submitted plain;
  tooltip shows balances; missing token replaces popover with connect screen.
- **SPEC:** Settings panel; App shell & UX (icon, tooltip, auth).

### 5a — Reminder notification (leaf)
- **Depends-on:** 5 settings (for weekday+time config)
- **Deliverable:** `Settings/` — local notification (default Fri 10:00), deep-links to current
  week's popover, **suppressed when the week is fully submitted**.
- **Acceptance:** notification fires at configured time, opens the week; suppressed when all
  weekdays submitted.
- **SPEC:** Settings panel (Reminder).

## Slice 6 — Calendar sync
- **Depends-on:** 1 (needs approved-vacation booking data); independent of 2–5
- **Deliverable:** `CalendarSync/` — EventKit engine; destination calendar picker; sync
  **approved vacation only** over past 90d + next 365d; one all-day spanning event per booking
  titled `Vacation`; booking-id↔EventKit-id mapping in UserDefaults + event notes; reconcile
  (create new, delete gone/unapproved — only app-created); calendar-change migration; failure
  warns locally, never blocks submit.
- **Acceptance:** approved vacations appear as `Vacation` events; un-approving/removing a
  booking deletes its event; changing calendar moves app-created events; sync failure does not
  block timesheet submit.
- **SPEC:** Calendar sync.

---

## Cross-cutting conventions
- **Server is source of truth** on every grid load; the derived-id cache is a lookup
  shortcut only (SPEC: Constants, Weekly grid model).
- Never modify/delete a **locked** (individually approved) entry (SPEC: Editing rules).
- **No 0h server entries** ever (SPEC: Prefill, Submit).
- All writes go through the single sequential 429-aware queue in `API/` (SPEC: Architecture).
- Out of scope for v1: see SPEC "Out of scope".
