import SwiftUI

@main
struct HeadphoneEQApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("BridgeEQ") {
            ContentView().environmentObject(model)
                .frame(minWidth: BridgeEQLayout.windowWidth,
                       idealWidth: BridgeEQLayout.windowWidth,
                       maxWidth: BridgeEQLayout.windowWidth, minHeight: 300)
        }
        .defaultSize(width: BridgeEQLayout.windowWidth, height: 480)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) { } }

        Window("EQ Curve", id: "eq-curve") {
            EQCurveView()
                .environmentObject(model)
                .frame(minWidth: 620, minHeight: 380)
        }
        .defaultSize(width: 800, height: 500)
    }
}
