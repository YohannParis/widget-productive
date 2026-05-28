import SwiftUI

// MARK: - Layout constants

private enum Layout {
    static let hPad: CGFloat       = 10
    static let labelWidth: CGFloat = 120
    static let colWidth: CGFloat   = 44
}

// MARK: - GridView

struct GridView: View {
    @Environment(GridViewModel.self) private var vm
    @State private var showAddRow = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            columnHeaders
            Divider()
            contentArea
        }
        .onAppear {
            if vm.rows.isEmpty && !vm.isLoading {
                vm.refresh()
            }
        }
        .sheet(isPresented: $showAddRow) {
            AddRowSheet()
                .environment(vm)
                .onAppear { vm.loadAvailableServices() }
        }
    }

    // MARK: Navigation bar

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button(action: vm.previousWeek) {
                Image(systemName: "chevron.left").imageScale(.small)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(vm.weekLabel)
                .font(.subheadline.weight(.semibold))

            Spacer()

            if vm.isLoading {
                ProgressView().scaleEffect(0.65).frame(width: 18, height: 18)
            } else {
                Button(action: vm.refresh) {
                    Image(systemName: "arrow.clockwise").imageScale(.small)
                }
                .buttonStyle(.plain)
            }

            Button(action: vm.nextWeek) {
                Image(systemName: "chevron.right").imageScale(.small)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Layout.hPad)
        .padding(.vertical, 8)
    }

    // MARK: Column headers (with over/under indicators)

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Layout.labelWidth)
            ForEach(Array(vm.weekDates.enumerated()), id: \.offset) { idx, date in
                let dateStr = GridViewModel.isoDate(date)
                VStack(spacing: 1) {
                    Text(dayColumnLabel(date))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    warningDot(weekdayIndex: idx, date: dateStr)
                }
                .frame(width: Layout.colWidth)
            }
        }
        .padding(.horizontal, Layout.hPad)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func warningDot(weekdayIndex: Int, date: String) -> some View {
        switch vm.dailyWarning(weekdayIndex: weekdayIndex, date: date) {
        case .over:   Circle().fill(Color.orange).frame(width: 4, height: 4)
        case .under:  Circle().fill(Color.yellow).frame(width: 4, height: 4)
        case .none:   Circle().fill(Color.clear).frame(width: 4, height: 4)
        }
    }

    // MARK: Content area

    @ViewBuilder
    private var contentArea: some View {
        if let err = vm.loadError {
            VStack(spacing: 10) {
                Text(err).font(.caption).foregroundStyle(.red)
                    .multilineTextAlignment(.center).padding(.horizontal)
                Button("Retry", action: vm.refresh).buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.rows.isEmpty {
            Text(vm.isLoading ? "Loading…" : "No entries this week.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.rows) { row in
                        rowView(row)
                        Divider().padding(.leading, Layout.labelWidth + Layout.hPad)
                    }
                    addRowButton
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Row view

    private func rowView(_ row: WeekRow) -> some View {
        HStack(spacing: 0) {
            Text(row.label)
                .font(.caption).lineLimit(2)
                .foregroundStyle(row.hasNoActiveBooking ? Color.orange : Color.primary)
                .frame(width: Layout.labelWidth, alignment: .leading)
            ForEach(Array(vm.weekDates.enumerated()), id: \.offset) { _, date in
                CellView(row: row, date: GridViewModel.isoDate(date))
                    .environment(vm)
                    .frame(width: Layout.colWidth)
            }
        }
        .padding(.horizontal, Layout.hPad)
        .padding(.vertical, 6)
    }

    // MARK: Add row button

    private var addRowButton: some View {
        Button { showAddRow = true } label: {
            Label("Add row", systemImage: "plus")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Layout.hPad)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Helpers

    private func dayColumnLabel(_ date: Date) -> String {
        let wf = DateFormatter(); wf.locale = Locale(identifier: "en_US_POSIX"); wf.dateFormat = "EEE"
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "d"
        return "\(wf.string(from: date))\n\(df.string(from: date))"
    }
}

// MARK: - CellView

private struct CellView: View {
    @Environment(GridViewModel.self) private var vm
    let row: WeekRow
    let date: String

    @State private var isEditing = false
    @State private var editText  = ""
    @FocusState private var focused: Bool

    private var minutes: Int?  { vm.cellMinutes(rowID: row.id, date: date) }
    private var editable: Bool { vm.isCellEditable(row: row, date: date) }
    private var floor: Int     { vm.lockedFloor(rowID: row.id, date: date) }

    var body: some View {
        Group {
            if isEditing {
                TextField("", text: $editText)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                let (text, dimmed) = displayLabel
                Text(text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { startEditing() }
            }
        }
        .onChange(of: isEditing) { _, editing in
            if editing { focused = true }
        }
        // Quick 4h / 8h for absence rows; approved-cell contact option for read-only cells
        .contextMenu {
            if row.isAbsence && editable {
                Button("4h") { quickSet(240) }
                Button("8h") { quickSet(480) }
            }
            if !editable {
                if let url = mailtoURL {
                    Link("Contact attendance…", destination: url)
                }
                Text("This cell is approved and read-only.")
                    .font(.caption)
            }
        }
        // Show floor constraint as tooltip so the user understands the minimum
        .help(floorTooltip)
    }

    // MARK: Helpers

    private var displayLabel: (String, Bool) {
        guard let m = minutes, m > 0 else { return ("—", true) }
        return (formatHours(m), false)
    }

    private var floorTooltip: String {
        floor > 0 ? "min \(formatHours(floor)) (approved)" : ""
    }

    private func startEditing() {
        guard editable else { return }
        editText = minutes.map { hoursString($0) } ?? ""
        isEditing = true
    }

    private func commit() {
        defer { isEditing = false }
        let parsed = parseHours(editText)
        if parsed <= 0 && floor == 0 {
            // Clear the cell — remove the edit so it falls back to prefill
            vm.editsByRowID[row.id]?.removeValue(forKey: date)
            return
        }
        vm.updateCell(rowID: row.id, date: date, minutes: max(parsed, 0))
    }

    private func quickSet(_ mins: Int) {
        vm.updateCell(rowID: row.id, date: date, minutes: mins)
    }

    private var mailtoURL: URL? {
        guard let email = Secrets.attendanceEmail(), !email.isEmpty else { return nil }
        let subject = "Time entry correction – \(date)"
        let body    = "Hi,\n\nI'd like to request a correction for my approved time entry on \(date).\n\nThank you."
        var c = URLComponents(); c.scheme = "mailto"; c.path = email
        c.queryItems = [URLQueryItem(name: "subject", value: subject),
                        URLQueryItem(name: "body",    value: body)]
        return c.url
    }
}

// MARK: - AddRowSheet

struct AddRowSheet: View {
    @Environment(GridViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var budgetServiceIDs: Set<String> {
        Set(vm.rows.compactMap(\.serviceID).filter { $0 != "__no_service__" })
    }

    private var filteredServices: [(id: String, label: String)] {
        guard !searchText.isEmpty else { return vm.availableServices }
        return vm.availableServices.filter { $0.label.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add row").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding()

            Divider()

            if vm.isLoadingServices {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TextField("Search services…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal).padding(.top, 8)

                List {
                    absenceSection
                    budgetSection
                    othersSection
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 300, height: 420)
    }

    @ViewBuilder
    private var absenceSection: some View {
        let careDayID    = try? Secrets.careDayEventID()
        let vacationID   = try? Secrets.vacationEventID()
        let showCareDay  = careDayID  != nil && !vm.rows.contains { $0.id == "a:\(careDayID!)" }
        let showVacation = vacationID != nil && !vm.rows.contains { $0.id == "a:\(vacationID!)" }

        if showCareDay || showVacation {
            Section("Absence") {
                if showCareDay  { absenceButton(eventID: careDayID!,  label: "Care Day") }
                if showVacation { absenceButton(eventID: vacationID!, label: "Vacation") }
            }
        }
    }

    @ViewBuilder
    private var budgetSection: some View {
        let pinned = filteredServices.filter {
            budgetServiceIDs.contains($0.id) && !vm.rows.contains { $0.id == "w:\($0.id)" }
        }
        if !pinned.isEmpty {
            Section("Budget bookings") {
                ForEach(pinned, id: \.id) { serviceButton($0) }
            }
        }
    }

    @ViewBuilder
    private var othersSection: some View {
        let others = filteredServices.filter {
            !budgetServiceIDs.contains($0.id) && !vm.rows.contains { $0.id == "w:\($0.id)" }
        }
        if !others.isEmpty {
            Section("All services") {
                ForEach(others, id: \.id) { serviceButton($0) }
            }
        }
    }

    private func absenceButton(eventID: String, label: String) -> some View {
        Button {
            vm.addAbsenceRow(eventID: eventID, label: label)
            dismiss()
        } label: {
            Label(label, systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func serviceButton(_ svc: (id: String, label: String)) -> some View {
        Button {
            vm.addWorkedRow(serviceID: svc.id, label: svc.label)
            dismiss()
        } label: {
            Text(svc.label).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Formatters (file-private)

private func formatHours(_ minutes: Int) -> String {
    if minutes % 60 == 0 { return "\(minutes / 60)h" }
    let h = Double(minutes) / 60.0
    let s = String(format: "%.2f", h)
    return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression) + "h"
}

/// Hours value shown in the text field during editing (no "h" suffix, clean decimal).
private func hoursString(_ minutes: Int) -> String {
    if minutes == 0 { return "" }
    if minutes % 60 == 0 { return "\(minutes / 60)" }
    let h = Double(minutes) / 60.0
    let s = String(format: "%.2f", h)
    return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
}

/// Parse "8", "4.25", "4h", "4.5h", "0" → minutes.  Returns 0 for unparseable input.
private func parseHours(_ text: String) -> Int {
    let t = text.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "h", with: "")
                .replacingOccurrences(of: "H", with: "")
    guard let h = Double(t), h >= 0 else { return 0 }
    // Round to nearest 0.25h step.
    let steps = (h / 0.25).rounded()
    return Int(steps * 0.25 * 60)
}
