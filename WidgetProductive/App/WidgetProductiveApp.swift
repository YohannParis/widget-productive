import SwiftUI

@main
struct WidgetProductiveApp: App {
    @State private var gridVM = GridViewModel()

    var body: some Scene {
        MenuBarExtra("Widget Productive", systemImage: "clock") {
            GridView()
                .environment(gridVM)
                .frame(width: 360, height: 420)
        }
        .menuBarExtraStyle(.window)
    }
}
