import SwiftUI

@main
struct HeadphoneEQApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .frame(minWidth: 820, minHeight: 600)
        }
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
