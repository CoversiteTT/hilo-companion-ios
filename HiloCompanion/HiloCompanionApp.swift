import SwiftUI

@main
struct HiloCompanionApp: App {
    @StateObject private var bluetooth = HiloBluetooth()

    var body: some Scene {
        WindowGroup {
            Dashboard(bluetooth: bluetooth)
                .tint(.accentColor)
        }
    }
}
