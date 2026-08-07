import SwiftUI

@main
struct ForkensicsApp: App {
    @StateObject private var dataService = MockDataService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataService)
        }
    }
}
