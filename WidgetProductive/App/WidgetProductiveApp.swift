import SwiftUI

@main
struct WidgetProductiveApp: App {
    var body: some Scene {
        MenuBarExtra("Widget Productive", systemImage: "clock") {
            PopoverRootView()
                .frame(width: 360, height: 420)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PopoverRootView: View {
    var body: some View {
        VStack {
            Text("Widget Productive")
                .font(.headline)
            Text("Scaffold — weekly grid lands in Slice 1.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}
