import SwiftUI

@main
struct HeadphoneEQApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .frame(minWidth: 840, minHeight: 520)
        }
        .defaultSize(width: 980, height: 680)
        .commands { CommandGroup(replacing: .newItem) { } }

        Window("EQ Curve", id: "eq-curve") {
            EQCurveView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 380)
        }
        .defaultSize(width: 800, height: 500)
    }
}
