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
- Reminder time

## Weekly grid model
- Server is the source of truth
- Grid supports mixed row types:
  - Service rows (`time_entries`)
  - Absence rows (`bookings`)
- Pinned default rows:
  - configured default service row (`PRODUCTIVE_DEFAULT_SERVICE_LABEL`)
  - `Care Day`
- Conditional rows:
  - `Vacation`
  - Any existing server rows for the selected week
- Addable rows:
  - Any trackable service
  - Configured absence rows
- Display format is `Project / Service` for service rows

## Prefill rules
- Week navigation supports past, current, and future weeks
- Default target is 8h Mon–Fri
- Holidays may fall back to Mon–Fri-only logic in v1 if holiday-calendar resolution is awkward
- Existing time entries reduce default service fill
- Approved absences reduce default service fill
- Partial absence auto-fills remaining default service hours
- Fully absent day sets the default service row to `0`, but remains editable
- No 0h server entries are created

## Editing rules
- Submitted but unapproved time entries are editable
- Approved time entries are read-only
- Approved vacation bookings are read-only
- Approved Care Day bookings are read-only
- Read-only approved cells show an explanation and a `mailto:` link to `ATTENDANCE_EMAIL`
- The `mailto:` includes a prefilled subject and body with dates and context
- Over-8h and under-8h days warn but do not block submission
- Care Day and Vacation cells should support quick 4h / 8h actions

## Submit semantics
- Single primary action: submit/update
- Before submit, refresh from server and warn if server drift is detected
- Submit uses minimal diff, not delete/recreate
- Reconcile service rows via `time_entries`
- Reconcile absence rows via `bookings`
- Ensure weekly `timesheet` record exists for the week
- Do not auto-approve time entries
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
- Calendar sync failure warns locally but does not block timesheet submission

## API endpoints used
- `GET /api/v2/people` — resolve person by email
- `GET /api/v2/services` — list trackable services
- `GET /api/v2/projects` — project display data
- `GET /api/v2/time_entries` — fetch weekly service time
- `POST/PATCH/DELETE /api/v2/time_entries` — reconcile service rows
- `GET /api/v2/bookings` — fetch absence bookings
- `POST/PATCH/DELETE /api/v2/bookings` — reconcile absence rows
- `GET /api/v2/entitlements` — absence balances
- `GET /api/v2/events` — absence event discovery
- `GET /api/v2/timesheets` — inspect week submission record
- `POST /api/v2/timesheets` — create week submission record if needed

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
