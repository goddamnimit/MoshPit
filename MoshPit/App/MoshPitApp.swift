import SwiftUI

@main
struct MoshPitApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.params)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
