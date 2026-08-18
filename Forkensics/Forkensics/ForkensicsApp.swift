import SwiftUI

@main
struct ForkensicsApp: App {
    @UIApplicationDelegateAdaptor(ForkensicsAppDelegate.self) private var appDelegate
    @StateObject private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authService)
        }
    }
}
