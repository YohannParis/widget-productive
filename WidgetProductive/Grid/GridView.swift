import SwiftUI

// MARK: - Layout constants

private enum Layout {
    static let hPad: CGFloat      = 10
    static let labelWidth: CGFloat = 120
    static let colWidth: CGFloat   = 44
}

// MARK: - GridView

struct GridView: View {
    @Environment(GridViewModel.self) private var vm

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
    }

    // MARK: Navigation bar

    private var navigationBar: some View {
        HStack(spacing: 6) {
            Button(action: vm.previousWeek) {
                Image(systemName: "chevron.left")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)

            Spacer()

            Text(vm.weekLabel)
                .font(.subheadline.weight(.semibold))

            Spacer()

            if vm.isLoading {
                ProgressView()
                    .scaleEffect(0.65)
                    .frame(width: 18, height: 18)
            } else {
                Button(action: vm.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
            }

            Button(action: vm.nextWeek) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Layout.hPad)
        .padding(.vertical, 8)
    }

    // MARK: Column headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: Layout.labelWidth)
            ForEach(vm.weekDates, id: \.timeIntervalSinceReferenceDate) { date in
                Text(dayColumnLabel(date))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: Layout.colWidth)
            }
        }
        .padding(.horizontal, Layout.hPad)
        .padding(.vertical, 4)
    }

    // MARK: Content area

    @ViewBuilder
    private var contentArea: some View {
        if let err = vm.loadError {
            VStack(spacing: 10) {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry", action: vm.refresh)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.rows.isEmpty {
            Text(vm.isLoading ? "Loading…" : "No entries this week.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(vm.rows) { row in
                        rowView(row)
                        Divider()
                            .padding(.leading, Layout.labelWidth + Layout.hPad)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: Row view

    private func rowView(_ row: WeekRow) -> some View {
        HStack(spacing: 0) {
            Text(row.label)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(row.hasNoActiveBooking ? Color.orange : Color.primary)
                .frame(width: Layout.labelWidth, alignment: .leading)
            ForEach(vm.weekDates, id: \.timeIntervalSinceReferenceDate) { date in
                let dateStr = GridViewModel.isoDate(date)
                cellLabel(minutes: row.minutesByDate[dateStr])
                    .frame(width: Layout.colWidth)
            }
        }
        .padding(.horizontal, Layout.hPad)
        .padding(.vertical, 6)
    }

    // MARK: Cell label

    private func cellLabel(minutes: Int?) -> some View {
        let (text, dimmed): (String, Bool) = {
            guard let m = minutes, m > 0 else { return ("—", true) }
            return (formatHours(m), false)
        }()
        return Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(dimmed ? Color.secondary : Color.primary)
            .multilineTextAlignment(.center)
    }

    // MARK: Helpers

    private func dayColumnLabel(_ date: Date) -> String {
        let wf = DateFormatter()
        wf.locale = Locale(identifier: "en_US_POSIX")
        wf.dateFormat = "EEE"
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "d"
        return "\(wf.string(from: date))\n\(df.string(from: date))"
    }

    private func formatHours(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        let h = Double(minutes) / 60.0
        // Trim trailing zeros from 2 decimal places (handles 0.25/0.5/0.75 steps cleanly).
        let s = String(format: "%.2f", h)
        let trimmed = s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return "\(trimmed)h"
    }
}
