# Widget Productive v1 Spec

## Overview
A native macOS SwiftUI menu bar app to review, edit, and submit weekly Productive timesheets, surface absence balances, and optionally sync approved vacation to a user-selected Calendar.app calendar.

## Constants
These values should be loaded from `.env` in development and user/app settings in normal use.
- Productive org id: `PRODUCTIVE_ORG_ID`
- Productive email: `PRODUCTIVE_EMAIL`
- Productive person id: `PRODUCTIVE_PERSON_ID`
- Default service id: `PRODUCTIVE_DEFAULT_SERVICE_ID`
- Default service label: `PRODUCTIVE_DEFAULT_SERVICE_LABEL`
- Care Day event id: `PRODUCTIVE_CARE_DAY_EVENT_ID`
- Vacation event id: `PRODUCTIVE_VACATION_EVENT_ID`
- Attendance contact: `ATTENDANCE_EMAIL`

Note: the default project/service and event ids are an MVP convenience only. The
authoritative source for "what the user is planned to work on" is the user's own
**budget bookings** (see Weekly grid model). The app derives default worked rows from
budget bookings and caches the resulting project/service/event ids locally to speed up
later API calls. The `.env`/settings ids are a fallback when bookings cannot be
resolved.

## Architecture
- Native macOS app using SwiftUI
- `MenuBarExtra` menu bar UI
- Productive API client over `URLSession`
- Token stored in Keychain in production
- `.env` may prefill dev settings
- EventKit for optional calendar sync
- UserDefaults for non-secret settings and sync metadata

## Settings panel
- Productive token
- Productive org id
- Productive email
- Cached Productive person id
- Default service
- Configurable pinned rows
- Optional calendar picker, including `None`
- Reminder time — a local notification fires at this time to review/submit the week

## Productive data model
Three distinct Productive records back the grid; do not conflate them.
- `time_entries` — actual logged worked time. One entry references a person, a
  **project**, and a **service**, with a duration per day. These are the worked rows.
- `bookings` — the planning/scheduling resource, of two kinds:
  - **Budget bookings** allocate the person to a deal/budget and reference a `service`
    (the planned work). These tell the app which worked rows to show by default.
  - **Absence bookings** reference an `event` (time off / remote work). Care Day and
    Vacation are absence bookings. A booking is a date *range* (`started_on`/`ended_on`)
    with a `booking_method`/`percentage`/`total_time` for partial-day amounts; the grid
    decomposes a range into per-day cells.
- `timesheets` — the unit of submission, one **per person per day**, moving through
  `draft → submitted → approved / rejected`. There is no weekly timesheet record.

## Weekly grid model
- Server is the source of truth
- Grid supports mixed row types:
  - Worked rows (`time_entries`), display format `Project / Service`
  - Absence rows (`bookings` linked to an event), e.g. `Care Day`, `Vacation`
- Default worked rows are derived from the user's **budget bookings** for the week
  (the `.env` default service/project is only an MVP fallback)
- Pinned default rows:
  - default worked row(s) from budget bookings (fallback: `PRODUCTIVE_DEFAULT_SERVICE_LABEL`)
  - `Care Day`
- Conditional rows:
  - `Vacation`
  - Any existing server rows for the selected week
- Addable rows:
  - Any trackable service
  - Absence rows (`Care Day`, `Vacation`)
- One `time_entry` per (project, service, day). If the server already has more than one
  entry for the same project/service/day, the grid sums them for display and collapses to
  a single entry on the next write (note-level multiple entries are not preserved in v1).
  Exception: locked (approved) entries are never collapsed or deleted; they are preserved
  and set a per-cell minimum (see Editing rules)

## Prefill rules
- Week navigation supports past, current, and future weeks
- Default target is 8h Mon–Fri
- Primary prefill source is **last week's time entries**: each worked row and its per-day
  hours are carried forward into the selected week (e.g. 8h/day on one service last week
  prefills 8h/day on that service this week)
- Care Day and Vacation are **never** carried forward; absence rows reflect only the
  selected week's actual absence bookings
- Fallback when a day has no last-week value to copy (new budget booking, or first use):
  distribute that day's 8h target **evenly across the active budget bookings** for the day
  (e.g. two bookings → 4h each)
- Time entries already on the server for the selected week are the source of truth and
  take precedence over carried-forward values (carry-forward only fills empty cells)
- Holidays may fall back to Mon–Fri-only logic in v1 if holiday-calendar resolution is awkward
- Approved absences for the selected week reduce that day's worked hours; a partial
  absence auto-fills the remaining hours across the worked rows (even split), and a fully
  absent day sets worked rows to `0` (still editable)
- No 0h server entries are created

## Editing rules
- Editability follows the day's timesheet state: `draft` days are editable; `approved`
  days are read-only; a `rejected` day returns to editable
- A `submitted` (awaiting-approval) day is editable: the app transparently demotes it to
  `draft`, writes the changes, then re-submits it as part of the submit flow
- A locked (individually approved) time entry sets a **per-cell minimum** rather than
  making the cell read-only: the cell stays editable but cannot be reduced below the sum
  of its locked entries. Example: a locked 3.5h entry means that cell can be raised but
  not set below 3.5h.
- The app never modifies or deletes a locked entry. Hours above the locked floor are
  written as a separate editable entry — the one exception to one-entry-per-cell.
- Detect locked entries via per-entry approval (`approved_at` / `deal_time_approval` on
  `time_entries`); this floor is independent of, and stricter than, the day-level
  timesheet state. (Implementation: verify these fields are the right lock signal.)
- Approved vacation bookings are read-only
- Approved Care Day bookings are read-only
- Vacation and Care Day are addable from the app: adding one creates an absence booking
  on the server (it will be pending approval until a manager approves it)
- Read-only approved cells show an explanation and a `mailto:` link to `ATTENDANCE_EMAIL`
- The `mailto:` includes a prefilled subject and body with dates and context
- Over-8h and under-8h days warn but do not block submission
- Care Day and Vacation cells should support quick 4h / 8h actions (half-day / full-day)

## Submit semantics
- Single primary action: submit/update
- Before submit, refresh from server and warn if server drift is detected. Drift = a
  cell the user did not edit changed on the server since load. Show exactly which
  cells/days conflict (server vs local) and let the user reload or proceed.
- Writes use minimal diff: only create/update/delete `time_entries` (and `bookings`)
  for days that actually differ from the server. Do not delete/recreate unchanged rows.
- Reconcile worked rows via `time_entries`; reconcile absence rows via `bookings`
- Submission is per-day: ensure a daily `timesheet` exists for each workday (Mon–Fri)
  and transition it `draft → submitted`. The single submit action covers the whole
  workweek; days already `approved` are skipped.
- For a changed day that is already `submitted`, the app demotes it to `draft`, writes the
  diff, then re-submits it (transparent to the user).
- Do not auto-approve time entries or bookings
- No 0h server entries are created
- Partial failures should surface row/cell-level errors and allow retry of failed items

## Calendar sync
- Optional feature
- Uses EventKit, not AppleScript
- User picks destination calendar from Calendar.app calendars
- Sync approved vacation only
- Sync window: past 90 days + next 365 days
- One all-day spanning event per Productive vacation booking
- Keep separate bookings as separate calendar events
- Store Productive booking id to EventKit identifier mapping in UserDefaults and event notes
- Each sync reconciles the calendar to match approved vacations in the window: create
  events for newly approved bookings, and delete events whose booking is gone or no
  longer approved (only events the app created, tracked via the stored mapping)
- Calendar sync failure warns locally but does not block timesheet submission

## API endpoints used
- `GET /api/v2/people` — resolve person by email
- `GET /api/v2/services` — list trackable services
- `GET /api/v2/projects` — project display data
- `GET /api/v2/time_entries` — fetch weekly service time
- `POST/PATCH/DELETE /api/v2/time_entries` — reconcile service rows
- `GET /api/v2/bookings` — fetch budget bookings (planned work / default rows) and absence bookings
- `POST/PATCH/DELETE /api/v2/bookings` — reconcile absence rows (Vacation, Care Day)
- `GET /api/v2/entitlements` — absence balances
- `GET /api/v2/events` — absence event discovery
- `GET /api/v2/timesheets` — inspect per-day timesheet state (`draft`/`submitted`/`approved`/`rejected`)
- `POST/PATCH /api/v2/timesheets` — create/submit the per-day timesheet (transition `draft → submitted`)

## Auth
- `X-Auth-Token` header for API token
- `X-Organization-Id` header for organization id
- Token comes from Keychain in production
- `.env` may be used in development

## Out of scope for v1
- Offline editing
- Bidirectional calendar sync
- Editing approved vacation/time directly
- Full holiday-calendar/person-calendar resolution if fallback is enough
- WidgetKit companion
- Distribution/notarization work
